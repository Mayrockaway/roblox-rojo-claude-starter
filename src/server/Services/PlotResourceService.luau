--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local OilConfig = require(Shared:WaitForChild("Config"):WaitForChild("OilConfig"))
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))
local ShipProfileMigration = require(Shared:WaitForChild("Config"):WaitForChild("ShipProfileMigration"))

local PlotResourceService = {}

function PlotResourceService:Init(remoteService, oilStateService, plotService, oilVisualService, oilShipmentService, chunkOwnershipService)
	self._remoteService = remoteService
	self._oilStateService = oilStateService
	self._plotService = plotService
	self._oilVisualService = oilVisualService
	self._oilShipmentService = oilShipmentService
	self._chunkOwnershipService = chunkOwnershipService
	self._connections = {}
	self._requestBuckets = {}
end

function PlotResourceService:Start()
	local removeEvent = self._remoteService:GetEvent(RemoteNames.RequestRemoveDrill)
	local buyChunkEvent = self._remoteService:GetEvent(RemoteNames.RequestBuyChunk)
	local snapshotFn = self._remoteService:GetFunction(RemoteNames.RequestOilSnapshot)

	table.insert(self._connections, removeEvent.OnServerEvent:Connect(function(player, payload)
		self:_handleRemoveDrillRequest(player, payload)
	end))

	table.insert(self._connections, buyChunkEvent.OnServerEvent:Connect(function(player, payload)
		self:_handleBuyChunkRequest(player, payload)
	end))

	-- RequestClearObstacle removed (obstacle system eliminated)

	local hammerEvent = self._remoteService:GetEvent(RemoteNames.RequestHammerDestroy)
	table.insert(self._connections, hammerEvent.OnServerEvent:Connect(function(player, payload)
		self:_handleHammerDestroyRequest(player, payload)
	end))

	local pickupBarrelEvent = self._remoteService:GetEvent(RemoteNames.RequestPickupBarrel)
	table.insert(self._connections, pickupBarrelEvent.OnServerEvent:Connect(function(player, payload)
		self:_handlePickupBarrelRequest(player, payload)
	end))

	-- Resolve the boat id from the wire payload. Accepts (in priority order):
	--   1. `payload.boatId`     — the v10+ canonical key (Step 6 rename).
	--   2. `payload.skinId`     — legacy v9 key still emitted by
	--                              `requestSetSelectedBoat` from older clients.
	--   3. `payload.boatTypeId` — pre-v4 legacy key, mapped through
	--                              `ShipProfileMigration` (kept so a player
	--                              who hasn't reloaded the place since the
	--                              old boat-type API can still equip).
	-- We intentionally do NOT accept `payload.equippedBoatId` — the wire
	-- contract for the new `RequestSetEquippedBoat` remote uses `boatId`
	-- (matches `RequestUnlockBoat`); the `equippedBoatId` name is a
	-- *server* state field, not the request payload key.
	local function resolveBoatIdFromPayload(payload: any): string?
		if typeof(payload) ~= "table" then
			return nil
		end
		if typeof(payload.boatId) == "string" then
			return payload.boatId
		end
		if typeof(payload.skinId) == "string" then
			return payload.skinId
		end
		if typeof(payload.boatTypeId) == "string" then
			local mapped = ShipProfileMigration.BoatIdForLegacyBoatTypeId(payload.boatTypeId)
			if mapped then
				return mapped
			end
			return payload.boatTypeId
		end
		return nil
	end

	local setBoatEvent = self._remoteService:GetEvent(RemoteNames.RequestSetSelectedBoat)
	table.insert(self._connections, setBoatEvent.OnServerEvent:Connect(function(player, payload)
		local boatId = resolveBoatIdFromPayload(payload)
		if not boatId then
			return
		end
		local ok, _err = self._oilStateService:SetEquippedBoatId(player.UserId, boatId)
		if ok then
			self._oilStateService:PushState(player.UserId)
		end
	end))

	-- Step 6: `RequestSetShipSkin` was renamed to `RequestSetEquippedBoat`.
	-- The handler accepts the new `payload.boatId` shape (and back-compat
	-- payload shapes via `resolveBoatIdFromPayload`). The result payload
	-- echoes the canonical `boatId` so the planned boat-inventory UI can
	-- flip its "equipped" card without re-deriving it from the snapshot.
	local setEquippedBoatEvent = self._remoteService:GetEvent(RemoteNames.RequestSetEquippedBoat)
	table.insert(self._connections, setEquippedBoatEvent.OnServerEvent:Connect(function(player, payload)
		local boatId = resolveBoatIdFromPayload(payload)
		if not boatId then
			self:_sendResult(player, false, "ERR_BAD_PAYLOAD", "Missing boatId.")
			return
		end
		local ok, err = self._oilStateService:SetEquippedBoatId(player.UserId, boatId)
		if ok then
			self._oilStateService:PushState(player.UserId)
			self:_sendResult(player, true, "OK", "Equipped boat updated.", { boatId = boatId })
		else
			self:_sendResult(player, false, err, "Could not update equipped boat.")
		end
	end))

	-- `RequestUpgradeShipSpeed` / `RequestUpgradeShipCapacity` handlers
	-- were deleted by Step 4 of the boat-progression refactor. Stats are
	-- now baked per-boat in `BoatCatalog`; the equip flow
	-- (`RequestSetEquippedBoat`) and the unlock flow (`RequestUnlockBoat`,
	-- below) replace the old upgrade ladder entirely.

	-- Boat progression refactor (Step 3). Cash-unlock entry point for
	-- boats whose `BoatCatalog.Boats[boatId].unlock.kind == "cash"`.
	-- The starter and Robux paths are explicitly rejected by
	-- `OilStateService:TryUnlockBoat` with codes that tell the client
	-- which path to use instead (auto-grant on join / Robux prompt).
	-- On success the boat is added to `ownedBoatIds` but NOT
	-- equipped — the UI should follow up with `RequestSetEquippedBoat`
	-- if the player wants to swap immediately. Snapshot is pushed so the
	-- ship-select panel can flip the card to "Owned" without waiting
	-- for the next periodic sync.
	local unlockBoatEvent = self._remoteService:GetEvent(RemoteNames.RequestUnlockBoat)
	table.insert(self._connections, unlockBoatEvent.OnServerEvent:Connect(function(player, payload)
		if not self:_allow(player.UserId, "unlockBoat", 25, 10) then
			self:_sendResult(player, false, "ERR_RATE_LIMIT", "Too many unlock requests.", nil, "UnlockBoat")
			return
		end
		local boatId: string? = nil
		if typeof(payload) == "table" and typeof(payload.boatId) == "string" then
			boatId = payload.boatId
		end
		if not boatId then
			self:_sendResult(player, false, "ERR_BAD_PAYLOAD", "Missing boatId.", nil, "UnlockBoat")
			return
		end
		local ok, code, msg = self._oilStateService:TryUnlockBoat(player.UserId, boatId)
		self:_sendResult(player, ok, code, msg, { boatId = boatId }, "UnlockBoat")
		if ok then
			self._oilStateService:PushState(player.UserId)
		end
	end))

	snapshotFn.OnServerInvoke = function(player)
		-- Wait for the player's oil state to be ready. On first join the
		-- DataStore load may still be in flight when the client calls
		-- RequestOilSnapshot, which previously returned nil and left the
		-- client with $0 / no chunks. Poll up to 10s before giving up.
		local clientState = self._oilStateService:GetStateForClient(player.UserId)
		if not clientState then
			for _ = 1, 40 do
				task.wait(0.25)
				clientState = self._oilStateService:GetStateForClient(player.UserId)
				if clientState then break end
			end
		end
		return {
			state = clientState,
			config = {
				drillPlacementCost = OilConfig.DrillPlacementCost,
				drillMinSpacing = OilConfig.DrillMinSpacing,
				removeDrillHoldSeconds = OilConfig.RemoveDrillHoldSeconds,
				removeDrillRangeStuds = OilConfig.RemoveDrillRangeStuds,
				chunkUnlockBaseCost = OilConfig.ChunkUnlockBaseCost,
				chunkUnlockDistanceMultiplier = OilConfig.ChunkUnlockDistanceMultiplier,
				chunks = {
					size = OilConfig.Chunks.Size,
					rows = OilConfig.Chunks.GridRows,
					cols = OilConfig.Chunks.GridCols,
					startingCenterSize = OilConfig.Chunks.StartingCenterSize,
				},
				boatCatalog = self._oilShipmentService and self._oilShipmentService:GetBoatCatalogForClient() or {},
			},
		}
	end
end

function PlotResourceService:Stop()
	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	self._connections = {}
	self._requestBuckets = {}
end

function PlotResourceService:_handleBuyChunkRequest(player: Player, payload)
	if not self:_allow(player.UserId, "buyChunk", 20, 10) then
		self:_sendResult(player, false, "ERR_RATE_LIMIT", "Too many buy requests.", nil, "BuyChunk")
		return
	end

	if typeof(payload) ~= "table" or typeof(payload.chunkId) ~= "string" then
		self:_sendResult(player, false, "ERR_BAD_PAYLOAD", "Missing chunkId.", nil, "BuyChunk")
		return
	end

	local ok, code, message = self._oilStateService:TryBuyChunk(player.UserId, payload.chunkId)
	--- `action = "BuyChunk"` lets the central `oilActionResult` handler in
	--- `init.client.luau` play `UiSfx.playKaching()` on success without having
	--- to sniff `data.chunkId` (other action types may carry chunk-shaped data
	--- in the future).
	self:_sendResult(player, ok, code, message, { chunkId = payload.chunkId }, "BuyChunk")
	if ok then
		if self._chunkOwnershipService then
			self._chunkOwnershipService:RefreshChunk(player.UserId, payload.chunkId)
		end
		self._oilStateService:PushState(player.UserId)
	end
end

function PlotResourceService:_handleRemoveDrillRequest(player: Player, payload)
	if not self:_allow(player.UserId, "removeDrill", 20, 10) then
		self:_sendResult(player, false, "ERR_RATE_LIMIT", "Too many drill remove requests.")
		return
	end

	if typeof(payload) ~= "table" or typeof(payload.drillId) ~= "number" then
		self:_sendResult(player, false, "ERR_BAD_PAYLOAD", "Missing drillId.")
		return
	end

	if not self:_playerHasEmptyHands(player) then
		self:_sendResult(player, false, "ERR_HAND_NOT_EMPTY", "Hands must be empty to remove a drill.")
		return
	end

	if not self:_isInRemoveRangeOfDrill(player, payload.drillId) then
		self:_sendResult(player, false, "ERR_TOO_FAR", "Move closer to remove this drill.")
		return
	end

	local ok, code, message = self._oilStateService:TryRemoveDrill(player.UserId, payload.drillId)
	self:_sendResult(player, ok, code, message, { drillId = payload.drillId })
	if ok then
		self._oilStateService:PushState(player.UserId)
	end
end

function PlotResourceService:_allow(userId: number, action: string, limit: number, windowSeconds: number): boolean
	local key = tostring(userId) .. ":" .. action
	local now = workspace:GetServerTimeNow()
	local bucket = self._requestBuckets[key]
	if not bucket then
		bucket = {
			start = now,
			count = 0,
		}
		self._requestBuckets[key] = bucket
	end

	if now - bucket.start >= windowSeconds then
		bucket.start = now
		bucket.count = 0
	end

	if bucket.count >= limit then
		return false
	end
	bucket.count += 1
	return true
end

function PlotResourceService:_sendResult(player: Player, ok: boolean, code: string, message: string, data, action: string?)
	local event = self._remoteService:GetEvent(RemoteNames.OilActionResult)
	event:FireClient(player, {
		action = action,
		ok = ok,
		code = code,
		message = message,
		data = data,
	})
end

function PlotResourceService:_playerHasEmptyHands(player: Player): boolean
	local character = player.Character
	if not character then
		return false
	end
	for _, child in ipairs(character:GetChildren()) do
		if child:IsA("Tool") then
			return false
		end
	end
	return true
end

-- _handleClearObstacleRequest removed (obstacle system eliminated)

function PlotResourceService:_handleHammerDestroyRequest(player: Player, payload)
	if not self:_allow(player.UserId, "hammer", 30, 10) then
		self:_sendResult(player, false, "ERR_RATE_LIMIT", "Too many hammer requests.")
		return
	end
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not (hrp and hrp:IsA("BasePart")) then
		self:_sendResult(player, false, "ERR_NO_CHARACTER", "Character not ready.")
		return
	end
	if not self._oilStateService:IsHammerDestroyInRange(player.UserId, payload, hrp.Position) then
		self:_sendResult(player, false, "ERR_TOO_FAR", "Move closer to salvage.")
		return
	end
	local ok, code, message, data = self._oilStateService:TryHammerDestroy(player.UserId, payload)
	self:_sendResult(player, ok, code, message, data)
	if ok then
		self._oilStateService:PushState(player.UserId)
	end
end

function PlotResourceService:_handlePickupBarrelRequest(player: Player, payload)
	-- Barrel pickup disabled
	self:_sendResult(player, false, "ERR_DISABLED", "Barrel pickup is disabled.")
	do return end
	if not self:_allow(player.UserId, "pickupBarrel", 20, 10) then
		self:_sendResult(player, false, "ERR_RATE_LIMIT", "Too many pickup requests.")
		return
	end
	if typeof(payload) ~= "table" or typeof(payload.barrelName) ~= "string" then
		self:_sendResult(player, false, "ERR_BAD_PAYLOAD", "Missing barrel name.")
		return
	end

	local plot = self._plotService:GetOwnedPlot(player.UserId)
	if not plot then
		self:_sendResult(player, false, "ERR_NO_PLOT", "No plot owned.")
		return
	end

	-- Find the barrel in the OilVisuals.Barrels folder
	local visuals = plot:FindFirstChild("OilVisuals")
	local barrelsFolder = visuals and visuals:FindFirstChild("Barrels")
	if not barrelsFolder then
		self:_sendResult(player, false, "ERR_NO_BARREL", "Barrel not found.")
		return
	end

	local barrel = barrelsFolder:FindFirstChild(payload.barrelName)
	if not barrel or not barrel:GetAttribute("OnConveyor") then
		self:_sendResult(player, false, "ERR_NOT_ON_CONVEYOR", "Can only pick up barrels from conveyor.")
		return
	end

	local tier = barrel:GetAttribute("Tier")
	barrel:Destroy()

	-- Create a Tool in the player's backpack with the barrel model
	local tierTemplates = OilConfig.Barrels and OilConfig.Barrels.TierTemplates or {}
	local templateName = tierTemplates[tier]
	local assetsFolder = game:GetService("ReplicatedStorage"):FindFirstChild("Assets")
	local template = assetsFolder and templateName and assetsFolder:FindFirstChild(templateName)

	local tool = Instance.new("Tool")
	tool.Name = (tier or "Oil") .. " Barrel"
	tool.RequiresHandle = false
	tool.CanBeDropped = true

	if template then
		local visual = template:Clone()
		visual.Name = "BarrelVisual"
		for _, d in ipairs(visual:GetDescendants()) do
			if d:IsA("BasePart") then
				d.Anchored = false
				d.CanCollide = false
				d.Massless = true
			end
			if d:IsA("ProximityPrompt") then
				d:Destroy()
			end
		end
		-- Create a handle part
		local handle = Instance.new("Part")
		handle.Name = "Handle"
		handle.Size = Vector3.new(1, 1, 1)
		handle.Transparency = 1
		handle.CanCollide = false
		handle.Massless = true
		handle.Parent = tool

		if visual:IsA("Model") then
			visual.Parent = tool
		elseif visual:IsA("BasePart") then
			visual.Parent = tool
		end
	end

	local backpack = player:FindFirstChild("Backpack")
	if backpack then
		tool.Parent = backpack
	end

	self:_sendResult(player, true, "OK", "Picked up " .. (tier or "oil") .. " barrel.", { tier = tier })
end

function PlotResourceService:_isInRemoveRangeOfDrill(player: Player, drillId: number): boolean
	local drill = self._oilStateService:GetDrillById(player.UserId, drillId)
	if not drill then
		return false
	end
	local character = player.Character
	if not character then
		return false
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not (hrp and hrp:IsA("BasePart")) then
		return false
	end
	return (hrp.Position - drill.position).Magnitude <= OilConfig.RemoveDrillRangeStuds
end

return PlotResourceService
