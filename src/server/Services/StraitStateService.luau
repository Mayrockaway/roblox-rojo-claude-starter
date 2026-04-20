--!strict

local HttpService = game:GetService("HttpService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local MessagingService = game:GetService("MessagingService")
local Players = game:GetService("Players")
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
	self._onStateChangedCallbacks = {}
	self._version = 1
	self._nextRollAt = workspace:GetServerTimeNow() + self:_sampleRollDelaySeconds()
	-- Generalised force lock for both Robux purchases (Open / Closed) and
	-- legacy admin force-close. `version` increments per *new* lock so clients
	-- can detect "a new attribution arrived, fire the announcement banner"
	-- vs. "the snapshot is the same lock arriving on a follower poll".
	self._forceLock = nil :: { state: string, untilTimestamp: number, byUserId: number?, byName: string?, version: number }?
	self._forceLockSeq = 0
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

--- Every server session starts with engine strait **Open**, publishes that snapshot (MemoryStore / Messaging when enabled), and bumps `version` past any stale cross-server snapshot.
function StraitStateService:_forceStraitOpenAtLaunch()
	self._forceLock = nil
	self._state = "Open"
	local maxVer = self._version
	if self._stateMap ~= nil then
		local ok, snap = pcall(function()
			return self._stateMap:GetAsync(Constants.StraitStateKey)
		end)
		if ok and typeof(snap) == "table" and typeof(snap.version) == "number" then
			maxVer = math.max(maxVer, snap.version)
		end
	end
	self._version = maxVer + 1
	self._nextRollAt = workspace:GetServerTimeNow() + self:_sampleRollDelaySeconds()
	self:_publishState()
	self:_broadcast()
end

function StraitStateService:Start()
	if self._running then
		return
	end
	self._running = true

	self:_forceStraitOpenAtLaunch()

	self:_subscribeMessaging()

	-- `FireAllClients` during boot often runs before any client exists; push authoritative snapshot per joiner.
	table.insert(self._connections, Players.PlayerAdded:Connect(function(player)
		task.defer(function()
			if not self._running or not player.Parent then
				return
			end
			self:_pushSnapshotToPlayer(player)
		end)
	end))
	for _, p in ipairs(Players:GetPlayers()) do
		task.defer(function()
			if not self._running or not p.Parent then
				return
			end
			self:_pushSnapshotToPlayer(p)
		end)
	end

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
	-- Backwards compat: `forcedClosedUntil` keeps existing readers (UI legacy /
	-- diagnostics) happy; `forceLock` is the canonical generalised field.
	local lock = self._forceLock
	local forcedClosedUntil: number? = nil
	if lock and lock.state == "Closed" then
		forcedClosedUntil = lock.untilTimestamp
	end
	return {
		state = self._state,
		version = self._version,
		priceMultiplier = stateRecord.priceMultiplier,
		baseSuccessChance = stateRecord.baseSuccessChance,
		nextRollAt = self._nextRollAt,
		isLeader = self._isLeader,
		forcedClosedUntil = forcedClosedUntil,
		forceLock = lock,
	}
end

function StraitStateService:OnStateChanged(callback)
	table.insert(self._onStateChangedCallbacks, callback)
end

--- Public API: force the strait into `state` ("Open" or "Closed") for `seconds`,
--- attributed to `byPlayer` (optional; nil = system / admin / dev).
---
--- Conflict policy: if a force lock is already active (any state, any owner)
--- this returns `false` and does not mutate state. Callers (e.g.
--- `MonetizationService` consumable handler) should propagate the false back
--- so `ProcessReceipt` returns `NotProcessedYet` and Roblox auto-refunds the
--- second buyer in the same window. Doing the refund this way (instead of
--- queueing) keeps the marketed product semantics honest: "you bought 2 min,
--- you got 2 min" is always true for the lock owner, and a contender who
--- couldn't override doesn't lose Robux.
---
--- Idempotency: caller-side dedup is not required; on success the
--- `forceLock.version` increments so client banners only fire once even on
--- snapshot replay.
function StraitStateService:ForceStateForDuration(state: string, seconds: number, byPlayer: Player?): boolean
	if state ~= "Open" and state ~= "Closed" then
		return false
	end
	if typeof(seconds) ~= "number" or seconds <= 0 then
		return false
	end
	local now = workspace:GetServerTimeNow()
	if self._forceLock and (self._forceLock.untilTimestamp or 0) > now then
		return false
	end

	self._forceLockSeq += 1
	local untilTs = now + seconds
	self._forceLock = {
		state = state,
		untilTimestamp = untilTs,
		byUserId = byPlayer and byPlayer.UserId or nil,
		byName = byPlayer and byPlayer.DisplayName or nil,
		version = self._forceLockSeq,
	}
	self._state = state
	self._version += 1
	-- Defer next organic roll until after the lock expires.
	self._nextRollAt = math.max(self._nextRollAt, untilTs)
	self:_publishState()
	self:_broadcast()
	if self._telemetryService then
		self._telemetryService:Track("strait_force_lock", {
			state = state,
			byUserId = byPlayer and byPlayer.UserId or nil,
			durationSeconds = seconds,
			untilTimestamp = untilTs,
		})
	end
	return true
end

--- Back-compat shim for legacy `AdminService:_onRequestForceClose`. Same lock
--- semantics as `ForceStateForDuration("Closed", seconds, nil)`.
function StraitStateService:ForceCloseForDuration(seconds: number): boolean
	return self:ForceStateForDuration("Closed", seconds, nil)
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
	local lock = self._forceLock
	if lock and now < lock.untilTimestamp then
		self._state = lock.state
		self._nextRollAt = lock.untilTimestamp
		self:_publishState()
		self:_broadcast()
		return
	end

	if lock and now >= lock.untilTimestamp then
		self._forceLock = nil
		-- Bump version so followers and clients clear their lock UI immediately
		-- on the next snapshot, and the timer panel hides as soon as the
		-- broadcast lands rather than waiting for the next roll.
		self._version += 1
		self._nextRollAt = now + self:_sampleRollDelaySeconds()
		self:_publishState()
		self:_broadcast()
	end

	if now >= self._nextRollAt then
		local changed = self:_rollState()
		self._nextRollAt = now + self:_sampleRollDelaySeconds()
		if changed then
			self._version += 1
			self:_publishState()
			self:_broadcast()
		end
		-- Silent reroll when `changed == false` — same bracket, no announcement.
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
	if typeof(state) ~= "string" then
		return
	end
	-- Migrate legacy engine keys from MemoryStore / MessagingService replays
	if state == "Tense" or state == "Dangerous" then
		state = "Restricted"
	elseif state == "Crisis" then
		state = "Closed"
	end
	if StraitConfig.States[state] == nil then
		return
	end

	self._state = state
	self._version = snapshot.version
	self._nextRollAt = tonumber(snapshot.nextRollAt) or (workspace:GetServerTimeNow() + self:_sampleRollDelaySeconds())

	-- Prefer the new generalised `forceLock` envelope; fall back to the
	-- legacy `forcedClosedUntil` so a freshly-deployed server can still ingest
	-- snapshots written by an older sibling mid-rollout.
	local incomingLock = snapshot.forceLock
	if typeof(incomingLock) == "table"
		and typeof(incomingLock.state) == "string"
		and typeof(incomingLock.untilTimestamp) == "number"
	then
		self._forceLock = {
			state = incomingLock.state,
			untilTimestamp = incomingLock.untilTimestamp,
			byUserId = tonumber(incomingLock.byUserId),
			byName = typeof(incomingLock.byName) == "string" and incomingLock.byName or nil,
			version = tonumber(incomingLock.version) or (self._forceLockSeq + 1),
		}
		self._forceLockSeq = math.max(self._forceLockSeq, self._forceLock.version)
	elseif typeof(snapshot.forcedClosedUntil) == "number" and snapshot.forcedClosedUntil > workspace:GetServerTimeNow() then
		self._forceLockSeq += 1
		self._forceLock = {
			state = "Closed",
			untilTimestamp = snapshot.forcedClosedUntil,
			byUserId = nil,
			byName = nil,
			version = self._forceLockSeq,
		}
	else
		self._forceLock = nil
	end

	self:_broadcast()
end

function StraitStateService:_sampleRollDelaySeconds(): number
	local jitter = StraitConfig.RollJitterSeconds
	local base = StraitConfig.RollIntervalSeconds
	local delta = self._rng:NextInteger(-jitter, jitter)
	return math.max(20, base + delta)
end

--- Roll a new bracket. Returns `true` if the result differs from the previous
--- state, `false` if the roll landed on the same bracket (in which case
--- callers should skip version bump / broadcast so the UI stays quiet).
function StraitStateService:_rollState(): boolean
	local order = StraitConfig.StateOrder
	local idx = self._rng:NextInteger(1, #order)
	local newState = order[idx]
	if newState == self._state then
		return false
	end
	self._state = newState
	return true
end

function StraitStateService:_pushSnapshotToPlayer(player: Player)
	local event = self._remoteService:GetEvent(RemoteNames.GlobalStateUpdate)
	event:FireClient(player, self:GetSnapshot())
end

function StraitStateService:_broadcast()
	local snapshot = self:GetSnapshot()
	local event = self._remoteService:GetEvent(RemoteNames.GlobalStateUpdate)
	event:FireAllClients(snapshot)
	for _, cb in ipairs(self._onStateChangedCallbacks or {}) do
		task.spawn(cb, snapshot)
	end
end

-- Dev UI "Open" / "Restricted" / "Closed" → engine state (1:1 with public brackets).
function StraitStateService:_bracketLabelToEngineState(bracket: string): string?
	local b = string.lower(string.gsub(bracket, "%s+", ""))
	if b == "open" then
		return "Open"
	elseif b == "closed" then
		return "Closed"
	elseif b == "restricted" then
		return "Restricted"
	end
	return nil
end

function StraitStateService:_applyDevEngineState(engineState: string)
	if StraitConfig.States[engineState] == nil then
		return
	end
	-- Dev override clears any active Robux force lock — intentional, so QA can
	-- always reset state from the dev panel without waiting 2 minutes. Live
	-- (non-Studio, dev UI off) gates this whole entry point upstream.
	self._forceLock = nil
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
