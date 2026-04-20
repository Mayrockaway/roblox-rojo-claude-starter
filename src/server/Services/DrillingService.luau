--!strict
-- DrillingService
-- Owns the timed lifecycle of a drill operation on a tile:
--   1. TryStartDrill (via RequestStartDrill remote) stores an activeDrill in OilStateService (persisted).
--   2. This service schedules completion at wall-clock `endTime` (remaining delay after rejoin).
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
local REVEAL_SPRAY_SECONDS = 2.0

function DrillingService:SetFtueService(ftueService: any)
	self._ftueService = ftueService
end

function DrillingService:Init(remoteService, oilStateService)
	self._remoteService = remoteService
	self._oilStateService = oilStateService
	self._ftueService = nil :: any
	self._connections = {}
	-- Pending completion tasks keyed by "userId:drillId"
	self._pendingCompletions = {}
	self._progressEvent = remoteService:GetEvent(RemoteNames.DrillProgressUpdate)
end

local function pendingKey(userId: number, drillId: number): string
	return tostring(userId) .. ":" .. tostring(drillId)
end

function DrillingService:_fireDrillCompleted(userId: number, done: any)
	local p = done.position
	-- Support both Vector3 (.X uppercase) and plain table (.x lowercase)
	local px = (typeof(p) == "Vector3" and p.X) or (typeof(p) == "table" and (p.X or p.x)) or 0
	local py = (typeof(p) == "Vector3" and p.Y) or (typeof(p) == "table" and (p.Y or p.y)) or 0
	local pz = (typeof(p) == "Vector3" and p.Z) or (typeof(p) == "table" and (p.Z or p.z)) or 0
	self._progressEvent:FireAllClients({
		kind = "completed",
		ownerUserId = userId,
		drillId = done.drillId,
		chunkId = done.chunkId,
		tileKey = done.tileKey,
		position = { x = px, y = py, z = pz },
		oilType = done.oilType,
		hasOil = done.hasOil,
	})
end

function DrillingService:_scheduleDrillCompletion(userId: number, drillId: number, delaySeconds: number)
	local key = pendingKey(userId, drillId)
	if self._pendingCompletions[key] then
		return
	end
	local entry = { userId = userId, drillId = drillId, cancelled = false }
	self._pendingCompletions[key] = entry
	local function finish()
		if entry.cancelled then
			return
		end
		self._pendingCompletions[key] = nil
		local doneOk, done = self._oilStateService:CompleteDrill(userId, drillId)
		if not doneOk or not done then
			return
		end
		self:_fireDrillCompleted(userId, done)
		local ftue = self._ftueService
		if ftue and typeof((ftue :: any).OnFtueTutorialDrillFinished) == "function" then
			(ftue :: any):OnFtueTutorialDrillFinished(userId, done)
		end
		self._oilStateService:PushState(userId)
	end
	if delaySeconds <= 0 then
		task.defer(finish)
	else
		task.delay(delaySeconds, finish)
	end
end

--- Replay `kind=completed` for drills that finished while the player was offline (state already updated).
function DrillingService:ReplayCompletedDrills(userId: number, completions: { any })
	for _, done in ipairs(completions) do
		if typeof(done) == "table" then
			self:_fireDrillCompleted(userId, done)
		end
	end
end

--- Re-fire "completed" for tiles that were drilled but never revealed (player left before clicking shovel).
function DrillingService:ReplayUnrevealedTiles(userId: number)
	local unrevealed = self._oilStateService:GetUnrevealedTiles(userId)
	if #unrevealed == 0 then return end
	task.spawn(function()
		local Players = game:GetService("Players")
		local player = Players:GetPlayerByUserId(userId)
		if not player then return end
		if not player.Character then
			player.CharacterAdded:Wait()
		end
		task.wait(3)
		player = Players:GetPlayerByUserId(userId)
		if not player then return end
		print(string.format("[DrillingService] Replaying %d unrevealed tiles for user %d", #unrevealed, userId))
		for _, done in ipairs(unrevealed) do
			local p = done.position
			print(string.format("[DrillingService] Replay tile %s/%s pos=(%s, %s, %s)", tostring(done.chunkId), tostring(done.tileKey), tostring(p and p.x), tostring(p and p.y), tostring(p and p.z)))
			self:_fireDrillCompleted(userId, done)
		end
	end)
end

--- After profile load, schedule `task.delay` for each active drill still in progress.
function DrillingService:ResumePendingDrillDelays(userId: number)
	local state = self._oilStateService:GetState(userId)
	if not state or not state.activeDrills then
		return
	end
	local now = workspace:GetServerTimeNow()
	for drillId, active in pairs(state.activeDrills) do
		if typeof(drillId) == "number" and typeof(active) == "table" then
			local endTime = (active :: any).endTime
			if typeof(endTime) == "number" then
				local remain = math.max(0, endTime - now)
				self:_scheduleDrillCompletion(userId, drillId, remain)
			end
		end
	end
end

function DrillingService:Start()
	local startEvent = self._remoteService:GetEvent(RemoteNames.RequestStartDrill)
	local placePumpEvent = self._remoteService:GetEvent(RemoteNames.RequestPlacePump)

	table.insert(self._connections, startEvent.OnServerEvent:Connect(function(player, payload)
		self:_handleStartDrill(player, payload)
	end))

	table.insert(self._connections, placePumpEvent.OnServerEvent:Connect(function(player, payload)
		self:_handlePlacePump(player, payload)
	end))

	-- Vein reveal: player pressed E on DrillComplete model
	local revealEvent = self._remoteService:GetEvent(RemoteNames.RequestRevealTile)
	table.insert(self._connections, revealEvent.OnServerEvent:Connect(function(player, payload)
		if typeof(payload) ~= "table" then return end
		local chunkId = tostring(payload.chunkId or "")
		local tileKey = tostring(payload.tileKey or "")
		if chunkId == "" or tileKey == "" then return end

		if payload.stage == "startVisuals" then
			local ok, result = self._oilStateService:StartRevealVisuals(player.UserId, chunkId, tileKey)
			if not ok or not result then return end
			self._oilStateService:PushState(player.UserId)
			if result.hasOil ~= false then
				task.delay(REVEAL_SPRAY_SECONDS + 0.05, function()
					self._oilStateService:PushState(player.UserId)
				end)
			end
			return
		end

		local ok, result = self._oilStateService:RevealTile(player.UserId, chunkId, tileKey)
		if not ok or not result then return end

		-- Fire revealed event to owner so client plays the crate opener
		self._progressEvent:FireClient(player, {
			kind = "revealed",
			ownerUserId = player.UserId,
			chunkId = result.chunkId,
			tileKey = result.tileKey,
			oilType = result.oilType,
			hasOil = result.hasOil,
			veinResult = result.veinResult,
			veinTypeId = result.veinTypeId,
			groundType = result.groundType,
		})

		-- Push state so OilVisualService can now spawn sprays
		self._oilStateService:PushState(player.UserId)
	end))

	-- When a player leaves, cancel any pending completion tasks so we don't double-complete
	-- after OilState reload (persisted active drills get fresh delays on rejoin).
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
	for _, c in ipairs(self._connections) do
		c:Disconnect()
	end
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

	-- Push state first so ActiveDrill visuals exist before clients handle DrillProgressUpdate
	-- (spatial SFX, sink animation, etc.).
	self._oilStateService:PushState(userId)

	local duration = data.duration
	-- Broadcast "drill started" so all clients play the sink animation
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

	-- Push again so backpack reflects consumed drill tool after TryStartDrill snapshot.
	self._oilStateService:PushState(userId)

	self:_scheduleDrillCompletion(userId, data.drillId, duration)
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
		-- Pump model exists after PushState; broadcast before second push so spatial SFX can attach.
		self._oilStateService:PushState(userId)
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
