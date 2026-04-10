--!strict

local HttpService = game:GetService("HttpService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local MessagingService = game:GetService("MessagingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local StraitConfig = require(Shared:WaitForChild("Config"):WaitForChild("StraitConfig"))
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))

local StraitStateService = {}

function StraitStateService:Init(remoteService, telemetryService)
	self._remoteService = remoteService
	self._telemetryService = telemetryService
	self._rng = Random.new()
	self._running = false
	self._connections = {}
	self._jobId = game.JobId ~= "" and game.JobId or HttpService:GenerateGUID(false)

	self._state = StraitConfig.InitialState
	self._version = 1
	self._nextRollAt = workspace:GetServerTimeNow() + self:_sampleRollDelaySeconds()
	self._forcedClosedUntil = nil
	self._isLeader = false
	self._useCloudSync = not RunService:IsStudio()

	if self._useCloudSync then
		local okMap, mapOrErr = pcall(function()
			return MemoryStoreService:GetSortedMap(Constants.StraitMemoryStoreMap)
		end)
		if okMap then
			self._stateMap = mapOrErr
		else
			self._stateMap = nil
			warn("[StraitStateService] MemoryStore unavailable. Falling back to local state:", mapOrErr)
		end
	else
		self._stateMap = nil
	end
end

function StraitStateService:Start()
	if self._running then
		return
	end
	self._running = true
	self:_subscribeMessaging()

	task.spawn(function()
		while self._running do
			self:_tickLeadership()
			task.wait(Constants.StraitLeaderHeartbeatSeconds)
		end
	end)

	task.spawn(function()
		while self._running do
			self:_syncFromStore()
			task.wait(Constants.StraitFollowerPollSeconds)
		end
	end)

	self:_broadcast()
	self:_wireDevStraitUi()
end

function StraitStateService:Stop()
	self._running = false
	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	self._connections = {}
end

function StraitStateService:GetCurrentState()
	return self._state
end

function StraitStateService:GetSnapshot()
	local stateRecord = StraitConfig.States[self._state]
	return {
		state = self._state,
		version = self._version,
		priceMultiplier = stateRecord.priceMultiplier,
		baseSuccessChance = stateRecord.baseSuccessChance,
		nextRollAt = self._nextRollAt,
		isLeader = self._isLeader,
		forcedClosedUntil = self._forcedClosedUntil,
	}
end

function StraitStateService:ForceCloseForDuration(seconds: number)
	local now = workspace:GetServerTimeNow()
	self._forcedClosedUntil = math.max(now + seconds, self._forcedClosedUntil or 0)
	self._state = "Closed"
	self._version += 1
	self._nextRollAt = math.max(self._nextRollAt, self._forcedClosedUntil)
	self:_publishState()
	self:_broadcast()
	self._telemetryService:Track("strait_forced_close", {
		untilTimestamp = self._forcedClosedUntil,
	})
end

function StraitStateService:_tickLeadership()
	local now = os.time()
	if self._stateMap == nil then
		self._isLeader = true
		self:_leaderTick()
		return
	end

	local lock = nil
	local ok, result = pcall(function()
		return self._stateMap:UpdateAsync(Constants.StraitLeaderLockKey, function(old)
			local current = old
			if typeof(current) ~= "table" then
				current = nil
			end
			if current == nil or (current.expiresAt or 0) < now or current.serverId == self._jobId then
				return {
					serverId = self._jobId,
					expiresAt = now + Constants.StraitLeaderLockSeconds,
				}
			end
			return current
		end, Constants.StraitLeaderLockSeconds + 2)
	end)
	if ok then
		lock = result
	end

	if typeof(lock) == "table" and lock.serverId == self._jobId then
		self._isLeader = true
		self:_leaderTick()
	else
		self._isLeader = false
	end
end

function StraitStateService:_leaderTick()
	local now = workspace:GetServerTimeNow()
	if self._forcedClosedUntil ~= nil and now < self._forcedClosedUntil then
		self._state = "Closed"
		self._nextRollAt = self._forcedClosedUntil
		self:_publishState()
		self:_broadcast()
		return
	end

	if self._forcedClosedUntil ~= nil and now >= self._forcedClosedUntil then
		self._forcedClosedUntil = nil
		self._nextRollAt = now + self:_sampleRollDelaySeconds()
	end

	if now >= self._nextRollAt then
		self:_rollState()
		self._version += 1
		self._nextRollAt = now + self:_sampleRollDelaySeconds()
		self:_publishState()
		self:_broadcast()
	end
end

function StraitStateService:_publishState()
	if self._stateMap ~= nil then
		local payload = self:GetSnapshot()
		pcall(function()
			self._stateMap:SetAsync(Constants.StraitStateKey, payload, 90)
		end)
	end
	if self._useCloudSync then
		pcall(function()
			MessagingService:PublishAsync(Constants.StraitMessagingTopic, self:GetSnapshot())
		end)
	end
end

function StraitStateService:_syncFromStore()
	if self._isLeader or self._stateMap == nil then
		return
	end
	local ok, snapshot = pcall(function()
		return self._stateMap:GetAsync(Constants.StraitStateKey)
	end)
	if ok and typeof(snapshot) == "table" then
		self:_applySnapshot(snapshot)
	end
end

function StraitStateService:_subscribeMessaging()
	if not self._useCloudSync then
		return
	end
	local ok, subscriptionOrErr = pcall(function()
		return MessagingService:SubscribeAsync(Constants.StraitMessagingTopic, function(message)
			if not self._running then
				return
			end
			local data = message.Data
			if typeof(data) == "table" then
				self:_applySnapshot(data)
			end
		end)
	end)
	if ok then
		table.insert(self._connections, subscriptionOrErr)
	else
		warn("[StraitStateService] Messaging subscription unavailable:", subscriptionOrErr)
	end
end

function StraitStateService:_applySnapshot(snapshot)
	if typeof(snapshot.version) ~= "number" then
		return
	end
	if snapshot.version < self._version then
		return
	end

	local state = snapshot.state
	if typeof(state) ~= "string" or StraitConfig.States[state] == nil then
		return
	end

	self._state = state
	self._version = snapshot.version
	self._nextRollAt = tonumber(snapshot.nextRollAt) or (workspace:GetServerTimeNow() + self:_sampleRollDelaySeconds())
	self._forcedClosedUntil = snapshot.forcedClosedUntil
	self:_broadcast()
end

function StraitStateService:_sampleRollDelaySeconds(): number
	local jitter = StraitConfig.RollJitterSeconds
	local base = StraitConfig.RollIntervalSeconds
	local delta = self._rng:NextInteger(-jitter, jitter)
	return math.max(20, base + delta)
end

function StraitStateService:_rollState()
	local order = StraitConfig.StateOrder
	local idx = self._rng:NextInteger(1, #order)
	self._state = order[idx]
end

function StraitStateService:_broadcast()
	local event = self._remoteService:GetEvent(RemoteNames.GlobalStateUpdate)
	event:FireAllClients(self:GetSnapshot())
end

-- UI "Open" / "Restricted" / "Closed" → engine state (Restricted → Dangerous as the mid-tier representative).
function StraitStateService:_bracketLabelToEngineState(bracket: string): string?
	local b = string.lower(string.gsub(bracket, "%s+", ""))
	if b == "open" then
		return "Open"
	elseif b == "closed" then
		return "Closed"
	elseif b == "restricted" then
		return "Dangerous"
	end
	return nil
end

function StraitStateService:_applyDevEngineState(engineState: string)
	if StraitConfig.States[engineState] == nil then
		return
	end
	self._forcedClosedUntil = nil
	self._state = engineState
	self._version += 1
	self._nextRollAt = workspace:GetServerTimeNow() + Constants.StraitDevStateHoldSeconds
	self:_publishState()
	self:_broadcast()
	if RunService:IsStudio() or Constants.StraitDevUiEnabled then
		print(string.format("[StraitStateService] Dev UI → engine state %s (auto-roll delayed %ds)", engineState, Constants.StraitDevStateHoldSeconds))
	end
end

function StraitStateService:_wireDevStraitUi()
	local remote = self._remoteService:GetEvent(RemoteNames.RequestDevSetStraitBracket)
	table.insert(self._connections, remote.OnServerEvent:Connect(function(_player: Player, payload)
		if not (RunService:IsStudio() or Constants.StraitDevUiEnabled) then
			return
		end
		if typeof(payload) ~= "table" then
			return
		end
		local bracket = payload.bracket
		if typeof(bracket) ~= "string" then
			return
		end
		local engineState = self:_bracketLabelToEngineState(bracket)
		if not engineState then
			return
		end
		self:_applyDevEngineState(engineState)
	end))
end

return StraitStateService
