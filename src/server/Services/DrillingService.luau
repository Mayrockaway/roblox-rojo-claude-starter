--!strict
-- DrillingService
-- Owns the timed lifecycle of a drill operation on a tile:
--   1. TryStartDrill (via RequestStartDrill remote) stores a transient activeDrill in OilStateService.
--   2. This service schedules a completion task at (endTime).
--   3. On completion, calls OilStateService:CompleteDrill which marks the tile drilled
--      and returns metadata used to fire DrillProgressUpdate {kind="completed"} to clients.
--   4. Clients listening to DrillProgressUpdate play the matching VFX (sink animation start,
--      oil spray start, pump-placement unlock).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))
local ConsumeShopEquipmentTool = require(script.Parent.Parent.Utils.ConsumeShopEquipmentTool)
local NotifyShopToolConsumedSafe = require(script.Parent.Parent.Utils.NotifyShopToolConsumedSafe)

local DrillingService = {}

function DrillingService:Init(remoteService, oilStateService)
	self._remoteService = remoteService
	self._oilStateService = oilStateService
	self._connections = {}
	-- Pending completion tasks keyed by "userId:drillId"
	self._pendingCompletions = {}
end

local function pendingKey(userId: number, drillId: number): string
	return tostring(userId) .. ":" .. tostring(drillId)
end

function DrillingService:Start()
	local startEvent = self._remoteService:GetEvent(RemoteNames.RequestStartDrill)
	local placePumpEvent = self._remoteService:GetEvent(RemoteNames.RequestPlacePump)
	local progressEvent = self._remoteService:GetEvent(RemoteNames.DrillProgressUpdate)

	self._progressEvent = progressEvent

	table.insert(self._connections, startEvent.OnServerEvent:Connect(function(player, payload)
		self:_handleStartDrill(player, payload)
	end))

	table.insert(self._connections, placePumpEvent.OnServerEvent:Connect(function(player, payload)
		self:_handlePlacePump(player, payload)
	end))

	-- When a player leaves, cancel any pending completions for them so we don't mutate state
	-- for a gone user.
	table.insert(self._connections, Players.PlayerRemoving:Connect(function(player)
		for key, entry in pairs(self._pendingCompletions) do
			if entry.userId == player.UserId then
				entry.cancelled = true
				self._pendingCompletions[key] = nil
			end
		end
	end))
end

function DrillingService:Stop()
	for _, c in ipairs(self._connections) do c:Disconnect() end
	self._connections = {}
	for key, entry in pairs(self._pendingCompletions) do
		entry.cancelled = true
		self._pendingCompletions[key] = nil
	end
end

function DrillingService:_handleStartDrill(player: Player, payload: any)
	local userId = player.UserId
	local ok, code, message, data = self._oilStateService:TryStartDrill(userId, payload)
	if not ok then
		self._remoteService:GetEvent(RemoteNames.OilActionResult):FireClient(player, {
			action = "StartDrill", ok = false, code = code, message = message,
		})
		return
	end

	-- Broadcast "drill started" so all clients play the sink animation
	local duration = data.duration
	self._progressEvent:FireAllClients({
		kind = "started",
		ownerUserId = userId,
		drillId = data.drillId,
		chunkId = data.chunkId,
		tileKey = data.tileKey,
		tier = data.tier,
		template = data.template,
		position = data.position,
		oilType = data.oilType,
		duration = duration,
	})

	self._remoteService:GetEvent(RemoteNames.OilActionResult):FireClient(player, {
		action = "StartDrill", ok = true, code = code, message = message, data = data,
	})

	local tier = "T1"
	if typeof(payload) == "table" and typeof(payload.tier) == "string" and payload.tier ~= "" then
		tier = payload.tier
	end
	local consumed, itemId = ConsumeShopEquipmentTool.consumeMatching(player, "Drill", tier)
	if consumed and itemId then
		NotifyShopToolConsumedSafe.tryCall(self._oilStateService, userId, itemId, "DrillingService:StartDrill")
	end

	-- Push state so activeDrills + cash reflect in the client's inventory right away
	self._oilStateService:PushState(userId)

	-- Schedule the completion
	local key = pendingKey(userId, data.drillId)
	local entry = { userId = userId, drillId = data.drillId, cancelled = false }
	self._pendingCompletions[key] = entry
	task.delay(duration, function()
		if entry.cancelled then return end
		self._pendingCompletions[key] = nil
		local doneOk, done = self._oilStateService:CompleteDrill(userId, data.drillId)
		if not doneOk then return end
		self._progressEvent:FireAllClients({
			kind = "completed",
			ownerUserId = userId,
			drillId = done.drillId,
			chunkId = done.chunkId,
			tileKey = done.tileKey,
			position = { x = done.position.X, y = done.position.Y, z = done.position.Z },
			oilType = done.oilType,
			hasOil = done.hasOil,
		})
		-- Push state so tile.drilled flips on the client and activeDrills clears
		self._oilStateService:PushState(userId)
	end)
end

function DrillingService:_handlePlacePump(player: Player, payload: any)
	local userId = player.UserId
	local ok, code, message, data = self._oilStateService:TryPlacePump(userId, payload)
	self._remoteService:GetEvent(RemoteNames.OilActionResult):FireClient(player, {
		action = "PlacePump", ok = ok, code = code, message = message, data = data,
	})
	if ok then
		local tier = "T1"
		if typeof(payload) == "table" and typeof(payload.tier) == "string" and payload.tier ~= "" then
			tier = payload.tier
		end
		local consumed, itemId = ConsumeShopEquipmentTool.consumeMatching(player, "Pump", tier)
		if consumed and itemId then
			NotifyShopToolConsumedSafe.tryCall(self._oilStateService, userId, itemId, "DrillingService:PlacePump")
		end
	end
	if ok and self._progressEvent then
		-- Broadcast pump-placed so clients stop the oil spray on that tile
		self._progressEvent:FireAllClients({
			kind = "pumpPlaced",
			ownerUserId = userId,
			pumpId = data.drillId,
			tileKey = data.tileKey,
			tier = data.tier,
		})
		self._oilStateService:PushState(userId)
	end
end

return DrillingService
