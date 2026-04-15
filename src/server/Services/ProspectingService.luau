--!strict
-- ProspectingService
-- Single-use prospector tool: placed on a 1x1 tile, sinks in, after duration reveals oil/no-oil
-- for every tile in the 5x5 chunk the placed tile belongs to.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))
local ConsumeShopEquipmentTool = require(script.Parent.Parent.Utils.ConsumeShopEquipmentTool)
local NotifyShopToolConsumedSafe = require(script.Parent.Parent.Utils.NotifyShopToolConsumedSafe)

local ProspectingService = {}

function ProspectingService:Init(remoteService, oilStateService)
	self._remoteService = remoteService
	self._oilStateService = oilStateService
	self._connections = {}
	self._pending = {}
	self._progressEvent = remoteService:GetEvent(RemoteNames.ProspectProgressUpdate)
end

local function pendingKey(userId: number, prospectId: number): string
	return tostring(userId) .. ":" .. tostring(prospectId)
end

function ProspectingService:_fireProspectCompleted(userId: number, done: any)
	self._progressEvent:FireAllClients({
		kind = "completed",
		ownerUserId = userId,
		prospectId = done.prospectId,
		chunkId = done.chunkId,
		position = { x = done.position.X, y = done.position.Y, z = done.position.Z },
	})
end

function ProspectingService:_scheduleProspectCompletion(userId: number, prospectId: number, delaySeconds: number)
	local key = pendingKey(userId, prospectId)
	if self._pending[key] then
		return
	end
	local entry = { userId = userId, prospectId = prospectId, cancelled = false }
	self._pending[key] = entry
	local function finish()
		if entry.cancelled then
			return
		end
		self._pending[key] = nil
		local doneOk, done = self._oilStateService:CompleteProspect(userId, prospectId)
		if not doneOk or not done then
			return
		end
		self:_fireProspectCompleted(userId, done)
		self._oilStateService:PushState(userId)
	end
	if delaySeconds <= 0 then
		task.defer(finish)
	else
		task.delay(delaySeconds, finish)
	end
end

function ProspectingService:ReplayCompletedProspects(userId: number, completions: { any })
	for _, done in ipairs(completions) do
		if typeof(done) == "table" then
			self:_fireProspectCompleted(userId, done)
		end
	end
end

function ProspectingService:ResumePendingProspects(userId: number)
	local state = self._oilStateService:GetState(userId)
	if not state or not state.activeProspectors then
		return
	end
	local now = workspace:GetServerTimeNow()
	for prospectId, active in pairs(state.activeProspectors) do
		if typeof(prospectId) == "number" and typeof(active) == "table" then
			local endTime = (active :: any).endTime
			if typeof(endTime) == "number" then
				local remain = math.max(0, endTime - now)
				self:_scheduleProspectCompletion(userId, prospectId, remain)
			end
		end
	end
end

function ProspectingService:Start()
	local startEvent = self._remoteService:GetEvent(RemoteNames.RequestProspect)

	table.insert(self._connections, startEvent.OnServerEvent:Connect(function(player, payload)
		self:_handleStartProspect(player, payload)
	end))

	table.insert(self._connections, Players.PlayerRemoving:Connect(function(player)
		for key, entry in pairs(self._pending) do
			if entry.userId == player.UserId then
				entry.cancelled = true
				self._pending[key] = nil
			end
		end
	end))
end

function ProspectingService:Stop()
	for _, c in ipairs(self._connections) do
		c:Disconnect()
	end
	self._connections = {}
	for key, entry in pairs(self._pending) do
		entry.cancelled = true
		self._pending[key] = nil
	end
end

function ProspectingService:_handleStartProspect(player: Player, payload: any)
	local userId = player.UserId
	local ok, code, message, data = self._oilStateService:TryStartProspect(userId, payload)
	if not ok then
		self._remoteService:GetEvent(RemoteNames.OilActionResult):FireClient(player, {
			action = "Prospect", ok = false, code = code, message = message,
		})
		return
	end

	self._progressEvent:FireAllClients({
		kind = "started",
		ownerUserId = userId,
		prospectId = data.prospectId,
		chunkId = data.chunkId,
		tileKey = data.tileKey,
		template = data.template,
		position = data.position,
		duration = data.duration,
	})

	self._remoteService:GetEvent(RemoteNames.OilActionResult):FireClient(player, {
		action = "Prospect", ok = true, code = code, message = message, data = data,
	})

	local consumed, itemId = ConsumeShopEquipmentTool.consumeMatching(player, "Prospector", nil)
	if consumed and itemId then
		NotifyShopToolConsumedSafe.tryCall(self._oilStateService, userId, itemId, "ProspectingService:StartProspect")
	end

	self._oilStateService:PushState(userId)

	self:_scheduleProspectCompletion(userId, data.prospectId, data.duration)
end

return ProspectingService
