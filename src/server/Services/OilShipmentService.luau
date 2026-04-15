--!strict

local HttpService = game:GetService("HttpService")
local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local OilConfig = require(Shared:WaitForChild("Config"):WaitForChild("OilConfig"))
local BoatConfig = require(Shared:WaitForChild("Config"):WaitForChild("BoatConfig"))
local ShipStats = require(Shared:WaitForChild("Config"):WaitForChild("ShipStats"))
local ShipSkinCatalog = require(Shared:WaitForChild("Config"):WaitForChild("ShipSkinCatalog"))
local QualityConfig = require(Shared:WaitForChild("Config"):WaitForChild("QualityConfig"))
local StraitEventCatalog = require(Shared:WaitForChild("Config"):WaitForChild("StraitEvents"):WaitForChild("Catalog"))
local ManifestIncidentTitle = require(Shared:WaitForChild("Config"):WaitForChild("StraitEvents"):WaitForChild("ManifestIncidentTitle"))
local StraitEventConfig = require(Shared:WaitForChild("Config"):WaitForChild("StraitEventConfig"))
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))
local ParticleFxScale = require(Shared:WaitForChild("ParticleFxScale"))
local ShipRig = require(Shared:WaitForChild("Utils"):WaitForChild("ShipRig"))
local CharacterTeleport = require(script.Parent.Parent.Utils.CharacterTeleport)

local OilShipmentService = {}
local FORCED_CONTRACT_PIRATE_LOSS_FRACTION = 0.50

local TIER_ORDER = {
	"PremiumRefined",
	"LightSweet",
	"HeavyCrude",
}

-- Barrels lost to spillage: take from cheaper tiers first.
local BARREL_LOSS_TIER_ORDER = {
	"HeavyCrude",
	"LightSweet",
	"PremiumRefined",
}

--- HUD / manifest snapshot tier key order (matches `ActiveManifestPanel` loaded rows).
local MANIFEST_HUD_TIER_ORDER = {
	"HeavyCrude",
	"LightSweet",
	"PremiumRefined",
}

local function floorPositive(value: number): number
	return math.max(0, math.floor(value))
end

local function hudPerBarrelOilUnits(): number
	local barrelsCfg = OilConfig.Barrels
	local n = (barrelsCfg and barrelsCfg.PerBarrelOil) or 1
	return math.max(1, math.floor(n))
end

local function clamp01(value: number): number
	return math.max(0, math.min(1, value))
end

local function getFirstBasePart(instance: Instance): BasePart?
	if instance:IsA("BasePart") then
		return instance
	end
	for _, child in ipairs(instance:GetDescendants()) do
		if child:IsA("BasePart") then
			return child
		end
	end
	return nil
end

local function anchorAll(instance: Instance)
	if instance:IsA("BasePart") then
		instance.Anchored = true
		instance.CanCollide = false
		instance.CanTouch = false
		instance.CanQuery = true
	end
	for _, child in ipairs(instance:GetDescendants()) do
		if child:IsA("BasePart") then
			child.Anchored = true
			child.CanCollide = false
			child.CanTouch = false
			child.CanQuery = true
		end
	end
end

local function setInstanceCFrame(instance: Instance, cf: CFrame)
	if instance:IsA("Model") then
		instance:PivotTo(cf)
	elseif instance:IsA("BasePart") then
		instance.CFrame = cf
	end
end

local function resolveRigForBoatInstance(boat: Instance): ShipRig.RigDef
	if boat:IsA("Model") then
		local templateName = boat:GetAttribute("ShipTemplateName")
		if typeof(templateName) == "string" and templateName ~= "" then
			return ShipSkinCatalog.GetRigForTemplate(templateName)
		end
		local skinId = boat:GetAttribute("ShipSkinId")
		if typeof(skinId) == "string" and skinId ~= "" then
			return ShipSkinCatalog.GetRigForSkin(skinId)
		end
	end
	return ShipSkinCatalog.GetRigForTemplate("Tanker")
end

local function findBoatSeat(boat: Instance): Seat?
	if not boat:IsA("Model") then
		return nil
	end
	local rig = resolveRigForBoatInstance(boat)
	return ShipRig.FindSeat(boat, rig.deckSeatName) or ShipRig.FindSeat(boat, "DeckSeat")
end

local function findBarrelStackRoot(boat: Instance): BasePart?
	if not boat:IsA("Model") then
		return nil
	end
	local rig = resolveRigForBoatInstance(boat)
	return ShipRig.FindBasePart(boat, rig.barrelStackRootName) or ShipRig.FindBasePart(boat, "BarrelStackRoot")
end

local function findPlayerFlagPart(boat: Instance): BasePart?
	if not boat:IsA("Model") then
		return nil
	end
	local rig = resolveRigForBoatInstance(boat)
	return ShipRig.FindBasePart(boat, rig.playerFlagName) or ShipRig.FindBasePart(boat, "PlayerFlag")
end

-- World-space axis-aligned bounds for a rotated box (BasePart / Model:GetBoundingBox).
local function worldAxisAlignedBoundsFromOriented(cf: CFrame, size: Vector3): (Vector3, Vector3)
	local hx, hy, hz = size.X * 0.5, size.Y * 0.5, size.Z * 0.5
	local corners = {
		Vector3.new(-hx, -hy, -hz),
		Vector3.new(hx, -hy, -hz),
		Vector3.new(-hx, hy, -hz),
		Vector3.new(hx, hy, -hz),
		Vector3.new(-hx, -hy, hz),
		Vector3.new(hx, -hy, hz),
		Vector3.new(-hx, hy, hz),
		Vector3.new(hx, hy, hz),
	}
	local minX, minY, minZ = math.huge, math.huge, math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
	for _, lc in ipairs(corners) do
		local w = cf:PointToWorldSpace(lc)
		minX = math.min(minX, w.X)
		minY = math.min(minY, w.Y)
		minZ = math.min(minZ, w.Z)
		maxX = math.max(maxX, w.X)
		maxY = math.max(maxY, w.Y)
		maxZ = math.max(maxZ, w.Z)
	end
	return Vector3.new(minX, minY, minZ), Vector3.new(maxX, maxY, maxZ)
end

local function worldAxisAlignedBoundsForMapRegion(root: Instance?): (Vector3?, Vector3?)
	if root == nil then
		return nil, nil
	end
	if root:IsA("BasePart") then
		local aMin, aMax = worldAxisAlignedBoundsFromOriented(root.CFrame, root.Size)
		return aMin, aMax
	end
	if root:IsA("Model") then
		local cf, size = root:GetBoundingBox()
		return worldAxisAlignedBoundsFromOriented(cf, size)
	end
	local minV: Vector3? = nil
	local maxV: Vector3? = nil
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then
			local aMin, aMax = worldAxisAlignedBoundsFromOriented(d.CFrame, d.Size)
			if minV == nil then
				minV, maxV = aMin, aMax
			else
				minV = Vector3.new(
					math.min(minV.X, aMin.X),
					math.min(minV.Y, aMin.Y),
					math.min(minV.Z, aMin.Z)
				)
				maxV = Vector3.new(
					math.max(maxV.X, aMax.X),
					math.max(maxV.Y, aMax.Y),
					math.max(maxV.Z, aMax.Z)
				)
			end
		end
	end
	return minV, maxV
end

--- Horizontal footprint (XZ) with padding, and root must be at/above the volume's low Y (standing on deck / water / beach).
local function worldPosOverMapAabbFootprint(
	worldPos: Vector3,
	minV: Vector3,
	maxV: Vector3,
	xzPadding: number,
	ySlack: number
): boolean
	if worldPos.X < minV.X - xzPadding or worldPos.X > maxV.X + xzPadding then
		return false
	end
	if worldPos.Z < minV.Z - xzPadding or worldPos.Z > maxV.Z + xzPadding then
		return false
	end
	if worldPos.Y < minV.Y - ySlack then
		return false
	end
	return true
end

function OilShipmentService:Init(remoteService, oilStateService, plotService, warehouseService, straitStateService, boatDockService)
	self._remoteService = remoteService
	self._oilStateService = oilStateService
	self._plotService = plotService
	self._warehouseService = warehouseService
	self._straitStateService = straitStateService
	self._boatDockService = boatDockService
	self._connections = {}
	self._lanes = {}

	local assetsFolder = ReplicatedStorage:FindFirstChild("Assets")
	self._boatTemplate = assetsFolder and assetsFolder:FindFirstChild("Tanker") or nil
	self._activeShips = {} -- per-ship runtime state keyed by shipmentId
	self._activeShipmentByOwner = {} :: { [number]: string }
	self._shipmentContexts = {} :: { [string]: { [string]: any } }
	self._hitContractService = nil

	-- Collision group: ships don't collide with each other
	local ok, _ = pcall(function()
		PhysicsService:RegisterCollisionGroup("ShipmentShip")
	end)
	if ok then
		pcall(function()
			PhysicsService:CollisionGroupSetCollidable("ShipmentShip", "ShipmentShip", false)
		end)
	end

	-- Discover strait lane waypoints
	self:_discoverLanes()
end

function OilShipmentService:SetHitContractService(hitContractService)
	self._hitContractService = hitContractService
end

function OilShipmentService:_discoverLanes()
	self._lanes = {}
	local Workspace = game:GetService("Workspace")
	local map = Workspace:FindFirstChild("Map")
	local ocean = map and map:FindFirstChild("Ocean")
	-- Post–successful voyage: footprint vs `Map.Ocean` and beaches (see `_postStraitWarehouseTeleportByMapPosition`).
	-- Beaches may live under `StartPlot` / `FinishPlot` in Studio; recursive find matches that layout.
	self._postStraitMapOcean = ocean
	self._postStraitMapStartBeach = map and map:FindFirstChild("StartBeach", true)
	self._postStraitMapFinishBeach = map and map:FindFirstChild("FinishBeach", true)

	local strait = ocean and ocean:FindFirstChild("StraitHormuz")
	local routes = strait and strait:FindFirstChild("Routes")
	if not routes then
		warn("[OilShipmentService] No Routes folder found at Map.Ocean.StraitHormuz.Routes")
		return
	end

	for _, lane in ipairs(routes:GetChildren()) do
		if lane:IsA("Folder") or lane:IsA("Model") then
			local waypoints = {}
			for _, wp in ipairs(lane:GetChildren()) do
				if wp:IsA("BasePart") then
					table.insert(waypoints, wp)
				end
			end
			-- Sort numerically by name (01, 02, ..., 11, 12)
			table.sort(waypoints, function(a, b)
				local numA = tonumber(a.Name) or 0
				local numB = tonumber(b.Name) or 0
				return numA < numB
			end)
			if #waypoints >= 2 then
				local positions = {}
				for _, wp in ipairs(waypoints) do
					table.insert(positions, wp.Position)
				end
				table.insert(self._lanes, {
					name = lane.Name,
					positions = positions,
				})
			end
		end
	end

	print(string.format("[OilShipmentService] Discovered %d lanes", #self._lanes))
end

function OilShipmentService:_pickLane(seed: number)
	if #self._lanes == 0 then
		return nil
	end
	local rng = Random.new(seed)
	local idx = rng:NextInteger(1, #self._lanes)
	return self._lanes[idx]
end

function OilShipmentService:_buildPath(dockSpawnPos: Vector3, lane): { Vector3 }
	-- Full path: dock → each lane waypoint in order
	local path = { dockSpawnPos }
	for _, pos in ipairs(lane.positions) do
		table.insert(path, pos)
	end
	return path
end

function OilShipmentService:_computePathLength(path: { Vector3 }): number
	local total = 0
	for i = 2, #path do
		total += (path[i] - path[i - 1]).Magnitude
	end
	return total
end

function OilShipmentService:Start()
	local requestDispatch = self._remoteService:GetEvent(RemoteNames.RequestDispatchShipment)
	table.insert(self._connections, requestDispatch.OnServerEvent:Connect(function(player, payload)
		self:_handleDispatch(player, payload)
	end))

	local teleportToShip = self._remoteService:GetEvent(RemoteNames.RequestTeleportToShip)
	table.insert(self._connections, teleportToShip.OnServerEvent:Connect(function(player)
		self:_handleTeleportToShip(player)
	end))

	local teleportHome = self._remoteService:GetEvent(RemoteNames.RequestTeleportHome)
	table.insert(self._connections, teleportHome.OnServerEvent:Connect(function(player)
		self:_handleTeleportHome(player)
	end))

	local teleportDocks = self._remoteService:GetEvent(RemoteNames.RequestTeleportToDocks)
	table.insert(self._connections, teleportDocks.OnServerEvent:Connect(function(player)
		self:_handleTeleportToDocks(player)
	end))
end

function OilShipmentService:_handleTeleportToShip(player: Player)
	if not player.Character then
		warn("[TeleportToShip] No character")
		return
	end
	if not self._boatDockService then
		warn("[TeleportToShip] BoatDockService unavailable")
		return
	end
	local ok, err = self._boatDockService:TeleportOwnerToSeat(player)
	if not ok then
		self:_sendActionResult(player, false, "ERR_BOAT_UNAVAILABLE", "Your ship is not available right now.", { reason = err })
	end
end

function OilShipmentService:_handleTeleportHome(player: Player)
	local character = player.Character
	if not character then return end

	CharacterTeleport.unseatIfSitting(character)

	local plot = self._plotService:GetOwnedPlot(player.UserId)
	if not plot then return end
	local claimPad = plot:FindFirstChild("ClaimPad")
	if claimPad and claimPad:IsA("BasePart") then
		character:PivotTo(CFrame.new(claimPad.Position + Vector3.new(0, 5, 0)))
	end
end

--- `Workspace.DocksShop.DocksTeleportTarget` (or `Workspace.DocksTeleportTarget`): Attachment / BasePart / Model pivot.
--- Falls back to plot `BoatSpawn` if the authored target is missing.
local function getDocksTeleportCFrame(): CFrame?
	local docksShop = Workspace:FindFirstChild("DocksShop")
	local target: Instance? = if docksShop then docksShop:FindFirstChild("DocksTeleportTarget", true) else nil
	if not target then
		target = Workspace:FindFirstChild("DocksTeleportTarget", true)
	end
	if not target then
		return nil
	end
	if target:IsA("Attachment") then
		return target.WorldCFrame
	end
	if target:IsA("BasePart") then
		return target:GetPivot()
	end
	if target:IsA("Model") then
		return target:GetPivot()
	end
	return nil
end

function OilShipmentService:_handleTeleportToDocks(player: Player)
	local character = player.Character
	if not character then
		return
	end

	CharacterTeleport.unseatIfSitting(character)

	local cf = getDocksTeleportCFrame()
	if cf then
		-- Face away from the authored forward (e.g. into the shop) — 180° yaw in target-local space.
		character:PivotTo(cf * CFrame.Angles(0, math.pi, 0))
		return
	end

	local plot = self._plotService:GetOwnedPlot(player.UserId)
	if not plot then
		return
	end
	local boatSpawn = plot:FindFirstChild("BoatSpawn")
	if boatSpawn and boatSpawn:IsA("BasePart") then
		character:PivotTo(CFrame.new(boatSpawn.Position + Vector3.new(0, 5, 0)))
	end
end

function OilShipmentService:Stop()
	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	self._connections = {}
	self._activeShipmentByOwner = {}
	self._shipmentContexts = {}
end

function OilShipmentService:QueueOrTriggerForcedPirateHit(victimUserId: number, contractorUserId: number, contractId: string): (boolean, string, string?)
	local shipmentId = self._activeShipmentByOwner[victimUserId]
	if not shipmentId then
		return false, "NOT_SAILING", nil
	end
	local ctx = self._shipmentContexts[shipmentId]
	if not ctx then
		return false, "NOT_SAILING", nil
	end
	ctx.pendingForcedPirateHit = {
		contractId = contractId,
		contractorUserId = contractorUserId,
		requestedAt = workspace:GetServerTimeNow(),
	}
	return true, if ctx.eventInProgress then "QUEUED_AFTER_EVENT" else "INJECT_NOW", shipmentId
end

function OilShipmentService:QueueOrInjectForActiveShipment(victimUserId: number, contractorUserId: number, contractId: string): (boolean, string, string?)
	return self:QueueOrTriggerForcedPirateHit(victimUserId, contractorUserId, contractId)
end

function OilShipmentService:GetShipSkinCatalogForClient()
	return ShipSkinCatalog.ListForClient()
end

function OilShipmentService:_handleDispatch(player: Player, payload)
	if typeof(payload) ~= "table" then
		self:_sendActionResult(player, false, "ERR_BAD_PAYLOAD", "Bad dispatch payload.")
		return
	end

	local manifest = payload.manifest
	if typeof(manifest) ~= "table" then
		self:_sendActionResult(player, false, "ERR_BAD_PAYLOAD", "Missing manifest.")
		return
	end
	do
		local m = manifest :: { [string]: any }
		local legacyStd = floorPositive(tonumber(m.StandardCrude) or 0)
		if legacyStd > 0 then
			m.HeavyCrude = floorPositive(tonumber(m.HeavyCrude) or 0) + legacyStd
			m.StandardCrude = nil
		end
	end

	local state = self._oilStateService:GetState(player.UserId)
	if not state then
		self:_sendActionResult(player, false, "ERR_NO_STATE", "State unavailable.")
		return
	end

	-- One oil shipment at a time until it returns (count decremented on resolve / abandon).
	if (state.activeShipmentCount or 0) > 0 then
		self:_sendActionResult(player, false, "ERR_SHIPMENT_IN_PROGRESS", "Your ship is still out. Wait for it to return before dispatching again.")
		return
	end

	-- Boat must be idle in its dock slot before dispatch.
	if self._boatDockService and not self._boatDockService:IsIdle(player.UserId) then
		local cooldownEndsAt = self._boatDockService:GetCooldownEndsAt(player.UserId)
		self:_sendActionResult(player, false, "ERR_BOAT_COOLDOWN", "Your ship is not in the dock yet.", {
			cooldownEndsAt = cooldownEndsAt,
			boatState = self._boatDockService:GetState(player.UserId),
		})
		return
	end

	local skinId = (typeof(state.shipSkinId) == "string" and ShipSkinCatalog.Skins[state.shipSkinId] and state.shipSkinId)
		or "DefaultTanker"
	local speedL = math.clamp(math.floor(state.shipSpeedLevel or 1), 1, 10)
	local capL = math.clamp(math.floor(state.shipCapacityLevel or 1), 1, 25)
	local stats = ShipStats.Resolve(speedL, capL)

	local okManifest, codeManifest, messageManifest, totalRequested = self._oilStateService:CanConsumeManifest(player.UserId, manifest)
	if not okManifest then
		self:_sendActionResult(player, false, codeManifest, messageManifest)
		return
	end
	if totalRequested > stats.capacity then
		self:_sendActionResult(player, false, "ERR_BOAT_CAPACITY", "Ship capacity exceeded.")
		return
	end

	if self._warehouseService and not self._warehouseService:CanShip(player.UserId, totalRequested) then
		self:_sendActionResult(player, false, "ERR_WAREHOUSE_FULL", "Warehouse is full. Sell or upgrade.")
		return
	end

	local normalizedManifest = {}
	for _, tier in ipairs(TIER_ORDER) do
		normalizedManifest[tier] = floorPositive(tonumber(manifest[tier]) or 0)
	end

	local dispatchManifestOil: { [string]: number } = {}
	for _, tier in ipairs(MANIFEST_HUD_TIER_ORDER) do
		dispatchManifestOil[tier] = normalizedManifest[tier] or 0
	end

	local dispatchFee = ShipStats.ComputeDispatchFeeFromManifestOilUnits(normalizedManifest, hudPerBarrelOilUnits())
	if not self._oilStateService:TrySpendCash(player.UserId, dispatchFee) then
		self:_sendActionResult(player, false, "ERR_NOT_ENOUGH_CASH", "Not enough cash for dispatch fee.")
		return
	end

	if not self._oilStateService:ConsumeManifest(player.UserId, normalizedManifest) then
		self:_sendActionResult(player, false, "ERR_MANIFEST_CONSUME", "Failed to load selected barrels.")
		return
	end

	self._oilStateService:IncrementShipmentCount(player.UserId)
	self._oilStateService:PushState(player.UserId)

	local shipment = {
		shipmentId = HttpService:GenerateGUID(false),
		ownerUserId = player.UserId,
		shipSkinId = skinId,
		shipSpeedLevel = speedL,
		shipCapacityLevel = capL,
		manifest = normalizedManifest,
		dispatchManifestOil = dispatchManifestOil,
		totalLoaded = totalRequested,
		dispatchFee = dispatchFee,
		travelSeconds = stats.travelSeconds,
		eventRisk = stats.eventRisk,
	}

	self:_sendActionResult(player, true, "OK", "Shipment dispatched.", {
		shipmentId = shipment.shipmentId,
		shipSkinId = skinId,
		totalLoaded = totalRequested,
	})

	task.spawn(function()
		self:_runShipment(shipment)
	end)
end

function OilShipmentService:_runShipment(shipment)
	local ownerUserId = shipment.ownerUserId
	local plot = self._plotService:GetOwnedPlot(ownerUserId)
	if not plot then
		self:_finishShipmentWithoutPayout(shipment, "Owner plot unavailable.")
		return
	end

	if not self._boatDockService then
		self:_finishShipmentWithoutPayout(shipment, "Dock service unavailable.")
		return
	end
	local boat, checkoutErr = self._boatDockService:CheckoutBoat(ownerUserId, shipment.shipmentId)
	if not boat then
		self:_finishShipmentWithoutPayout(shipment, "Boat unavailable: " .. tostring(checkoutErr))
		return
	end
	-- Pick a lane and build the full path: dock (boat's current slot) → lane waypoints
	local seed = math.floor(workspace:GetServerTimeNow() * 1000) + ownerUserId
	local lane = self:_pickLane(seed)
	if not lane then
		warn("[OilShipmentService] No lanes available, falling back to straight line.")
		local startPos = boat:GetPivot().Position
		local endPos = startPos + Vector3.new(0, 0, -140)
		lane = { name = "Fallback", positions = { startPos, endPos } }
	end

	-- Dock spawn position = boat's current pivot (sits at its dock slot).
	local dockSpawnPos = boat:GetPivot().Position

	local path = self:_buildPath(dockSpawnPos, lane)
	local totalPathLen = self:_computePathLength(path)
	if totalPathLen < 1 then totalPathLen = 1 end

	-- Ship Y offset: raise above water surface
	local SHIP_Y_OFFSET = 8

	local startRaised = Vector3.new(path[1].X, path[1].Y + SHIP_Y_OFFSET, path[1].Z)
	local initDir = #path >= 2 and (path[2] - path[1]) or Vector3.new(0, 0, -1)

	-- Setup physics-driven ship
	self:_setupShip(shipment.shipmentId, boat, startRaised, initDir)
	self._activeShipmentByOwner[ownerUserId] = shipment.shipmentId
	self._shipmentContexts[shipment.shipmentId] = {
		ownerUserId = ownerUserId,
		shipmentId = shipment.shipmentId,
		boat = boat,
		eventInProgress = false,
		lastWorldPosition = path[1],
		pendingForcedPirateHit = nil,
	}

	if boat:IsA("Model") then
		boat:SetAttribute("ShipmentId", shipment.shipmentId)
		boat:SetAttribute("OwnerUserId", ownerUserId)
		boat:SetAttribute("ShipSkinId", shipment.shipSkinId)
		-- HUD progress bar: distance along dock→lane→finish polyline (0..1), not wall-clock.
		boat:SetAttribute("RouteProgress01", 0)
	end

	-- Add player flag to the ship
	self:_addPlayerFlag(boat, ownerUserId)

	local dockHoldBeforeVoyage = 1.2
	local tNow = workspace:GetServerTimeNow()
	local shipLabel = ShipSkinCatalog.GetSkin(shipment.shipSkinId).displayName
	self:_emitShipmentEvent("ShipmentStarted", {
		ownerUserId = ownerUserId,
		shipmentId = shipment.shipmentId,
		shipSkinId = shipment.shipSkinId,
		shipDisplayName = shipLabel,
		boatTypeId = shipLabel,
		loaded = shipment.totalLoaded,
		dispatchFee = shipment.dispatchFee,
		voyageStartTime = tNow + dockHoldBeforeVoyage,
		voyageEndTime = tNow + dockHoldBeforeVoyage + shipment.travelSeconds,
	})
	self:_emitManifestHudSnapshot(shipment, nil)

	-- Stack loaded barrels visually on the ship deck
	self:_loadBarrelsOnDeck(boat, shipment.manifest)

	-- Auto-teleport owner onto the DeckSeat (Ship Oil click is a one-click dispatch).
	local ownerPlayer = Players:GetPlayerByUserId(ownerUserId)
	if ownerPlayer then
		pcall(function()
			self._boatDockService:TeleportOwnerToSeat(ownerPlayer)
		end)
	end
	local boardConnection: RBXScriptConnection? = nil

	task.wait(dockHoldBeforeVoyage)

	-- Voyage: follow the polyline path over travelSeconds
	local voyageTime = shipment.travelSeconds
	local voyageClock = { startTime = workspace:GetServerTimeNow() }
	local ctx = self._shipmentContexts[shipment.shipmentId]
	if ctx then
		ctx.voyageClock = voyageClock
	end

	if self._hitContractService and typeof(self._hitContractService.ConsumePendingForVictim) == "function" then
		local pendingContract = self._hitContractService:ConsumePendingForVictim(ownerUserId)
		if pendingContract and ctx then
			ctx.pendingForcedPirateHit = {
				contractId = pendingContract.contractId,
				contractorUserId = pendingContract.contractorUserId,
				requestedAt = workspace:GetServerTimeNow(),
			}
			if typeof(self._hitContractService.MarkContractAttached) == "function" then
				self._hitContractService:MarkContractAttached(pendingContract.contractId, shipment.shipmentId)
			end
		end
	end

	-- Pre-compute cumulative segment distances for the polyline
	local segDists = { 0 }
	for i = 2, #path do
		segDists[i] = segDists[i - 1] + (path[i] - path[i - 1]).Magnitude
	end

	local triggerSlots = self:_buildStraitTriggerSlots(path, segDists)
	local firedAtLaneWaypoint: { [number]: boolean } = {}
	local prevTargetDist = 0.0

	if self:_straitDebugLogEnabled() then
		if #triggerSlots == 0 then
			warn(
				string.format(
					"[StraitShipment DEBUG] shipment %s: NO strait trigger slots (need lane waypoints 3,6,9 on path). Path has %d vertices.",
					shipment.shipmentId,
					#path
				)
			)
		else
			local parts = {}
			for _, s in ipairs(triggerSlots) do
				table.insert(parts, string.format("laneWP=%d@dist=%.1f", s.laneWaypointIndex, s.distance))
			end
			print(
				string.format(
					"[StraitShipment DEBUG] shipment %s userId=%d | strait triggers: %s | engineState=%s",
					shipment.shipmentId,
					ownerUserId,
					table.concat(parts, ", "),
					self:_getStraitEngineState()
				)
			)
		end
	end

	while true do
		local voyageAborted = false

		if ctx then
			local forcedLost = self:_maybeProcessForcedPirateHit(shipment, ownerUserId, voyageClock, boat, ctx)
			if forcedLost then
				voyageAborted = true
			end
		end

		local alpha = 0
		if not voyageAborted then
			local elapsed = workspace:GetServerTimeNow() - voyageClock.startTime
			alpha = clamp01(elapsed / voyageTime)

			-- Map alpha (0..1) to a position along the polyline
			local targetDist = alpha * totalPathLen
			if boat:IsA("Model") then
				boat:SetAttribute("RouteProgress01", clamp01(targetDist / totalPathLen))
			end
			local currentPos = path[#path]
			local nextPos = path[#path]
			for i = 2, #path do
				if segDists[i] >= targetDist then
					local segStart = path[i - 1]
					local segEnd = path[i]
					local segLen = segDists[i] - segDists[i - 1]
					local segAlpha = if segLen > 0 then (targetDist - segDists[i - 1]) / segLen else 0
					currentPos = segStart:Lerp(segEnd, clamp01(segAlpha))
					nextPos = segEnd
					break
				end
			end

			local raisedPos = Vector3.new(currentPos.X, currentPos.Y + SHIP_Y_OFFSET, currentPos.Z)
			local flatDir = Vector3.new(nextPos.X - currentPos.X, 0, nextPos.Z - currentPos.Z)
			if ctx then
				ctx.lastWorldPosition = currentPos
			end

			self:_updateShipPosition(shipment.shipmentId, boat, raisedPos, flatDir)

			for _, slot in ipairs(triggerSlots) do
				local laneN = slot.laneWaypointIndex
				if not firedAtLaneWaypoint[laneN] and prevTargetDist < slot.distance and targetDist >= slot.distance then
					firedAtLaneWaypoint[laneN] = true
					if self:_straitDebugLogEnabled() then
						print(
							string.format(
								"[StraitShipment DEBUG] crossing lane waypoint %d (path vertex ~%d) shipment=%s distAlongPath=%.1f engineState=%s",
								laneN,
								1 + laneN,
								shipment.shipmentId,
								slot.distance,
								self:_getStraitEngineState()
							)
						)
					end
					if ctx then
						ctx.eventInProgress = true
					end
					local lost = self:_handleStraitWaypointTrigger(shipment, ownerUserId, laneN, currentPos, voyageClock, boat)
					if ctx then
						ctx.eventInProgress = false
					end
					if lost then
						voyageAborted = true
						break
					end
				end
			end

			prevTargetDist = targetDist
		end

		if voyageAborted then
			if ctx and ctx.pendingForcedPirateHit and self._hitContractService and typeof(self._hitContractService.RefundContract) == "function" then
				self._hitContractService:RefundContract(ctx.pendingForcedPirateHit.contractId, "victim_destroyed_before_raid")
			end
			if boardConnection then
				boardConnection:Disconnect()
			end
			self:_unseatPlayersFromBoat(boat)
			self:_teardownShip(shipment.shipmentId)
			self._boatDockService:CheckinBoat(ownerUserId, { destroyed = true })
			self:_finishShipmentWithoutPayout(shipment, "Strait event: total loss")
			self._activeShipmentByOwner[ownerUserId] = nil
			self._shipmentContexts[shipment.shipmentId] = nil
			return
		end

		if alpha >= 1 then
			self:_emitShipmentEvent("ShipmentVoyageComplete", {
				ownerUserId = ownerUserId,
				shipmentId = shipment.shipmentId,
			})
			break
		end
		task.wait() -- run every frame (~30fps) for smooth movement
	end

	local deliveredManifest = {}
	local totalDelivered = 0

	for _, tier in ipairs(TIER_ORDER) do
		local loadedTier = shipment.manifest[tier] or 0
		local deliveredTier = floorPositive(loadedTier)
		deliveredManifest[tier] = deliveredTier
		totalDelivered += deliveredTier
	end

	-- Deliver barrels to warehouse (no auto-payout - player sells via Market UI)
	if self._warehouseService then
		self._warehouseService:DeliverBarrels(ownerUserId, deliveredManifest)
	end

	self._oilStateService:DecrementShipmentCount(ownerUserId)
	self._oilStateService:PushState(ownerUserId)

	local shipLabelR = ShipSkinCatalog.GetSkin(shipment.shipSkinId).displayName
	self:_emitShipmentEvent("ShipmentResolved", {
		ownerUserId = ownerUserId,
		shipmentId = shipment.shipmentId,
		shipSkinId = shipment.shipSkinId,
		shipDisplayName = shipLabelR,
		boatTypeId = shipLabelR,
		loaded = shipment.totalLoaded,
		delivered = totalDelivered,
		lost = shipment.totalLoaded - totalDelivered,
		dispatchFee = shipment.dispatchFee,
		deliveredByTier = deliveredManifest,
	})

	-- Owner on strait / ocean -> warehouse spawn; on StartBeach / FinishBeach footprint -> stay; at home plot -> no-op
	if boardConnection then
		boardConnection:Disconnect()
	end
	self:_handleOwnerAfterSuccessfulShipmentFinish(boat, ownerUserId)
	self:_teardownShip(shipment.shipmentId)
	self._boatDockService:CheckinBoat(ownerUserId, { destroyed = false })
	if ctx and ctx.pendingForcedPirateHit and self._hitContractService and typeof(self._hitContractService.RefundContract) == "function" then
		self._hitContractService:RefundContract(ctx.pendingForcedPirateHit.contractId, "victim_completed_before_raid")
	end
	self._activeShipmentByOwner[ownerUserId] = nil
	self._shipmentContexts[shipment.shipmentId] = nil
end

--- Successful voyage: sample **HumanoidRootPart** before unseat. Warehouse if over **`Map.Ocean`** footprint (not over **`StartBeach`** / **`FinishBeach`** anywhere under **`Map`**). Seated-on-ship fallback: **ClaimPad** if warehouse unavailable.
function OilShipmentService:_handleOwnerAfterSuccessfulShipmentFinish(boat: Instance, ownerUserId: number)
	local player = Players:GetPlayerByUserId(ownerUserId)
	if not player then
		return
	end
	local character = player.Character
	if not character then
		return
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then
		return
	end
	local samplePos = hrp.Position

	local hum = character:FindFirstChildOfClass("Humanoid")
	local wasSeatedOnThisBoat = hum ~= nil and hum.SeatPart ~= nil and hum.SeatPart:IsDescendantOf(boat)
	CharacterTeleport.unseatIfSitting(character)

	if self._warehouseService and self:_postStraitWarehouseTeleportByMapPosition(samplePos) then
		if self._warehouseService:TryTeleportPlayerToWarehouse(player) then
			return
		end
	end

	if wasSeatedOnThisBoat then
		local plot = self._plotService:GetOwnedPlot(player.UserId)
		local claimPad = plot and plot:FindFirstChild("ClaimPad")
		if claimPad and claimPad:IsA("BasePart") then
			character:PivotTo(CFrame.new(claimPad.Position + Vector3.new(0, 5, 0)))
		end
	end
end

--- Strait total loss, etc.: unseat from **DeckSeat** and send rider to home **ClaimPad**.
function OilShipmentService:_unseatPlayersFromBoat(boat: Instance)
	local seat = findBoatSeat(boat)
	if not seat then
		return
	end

	local occupant = seat.Occupant
	if not (occupant and occupant:IsA("Humanoid")) then
		return
	end

	seat:Sit(nil)
	task.wait(0.1)
	local character = occupant.Parent
	if not character then
		return
	end
	local player = Players:GetPlayerFromCharacter(character)
	if not player then
		return
	end

	local plot = self._plotService:GetOwnedPlot(player.UserId)
	local claimPad = plot and plot:FindFirstChild("ClaimPad")
	if claimPad and claimPad:IsA("BasePart") then
		character:PivotTo(CFrame.new(claimPad.Position + Vector3.new(0, 5, 0)))
	end
end

function OilShipmentService:_postStraitWarehouseTeleportByMapPosition(worldPos: Vector3): boolean
	local xzPad = 6
	local ySlack = 20
	local function overRegion(root: Instance?): boolean
		local minV, maxV = worldAxisAlignedBoundsForMapRegion(root)
		if not minV or not maxV then
			return false
		end
		return worldPosOverMapAabbFootprint(worldPos, minV, maxV, xzPad, ySlack)
	end
	if overRegion(self._postStraitMapStartBeach) then
		return false
	end
	if overRegion(self._postStraitMapFinishBeach) then
		return false
	end
	return overRegion(self._postStraitMapOcean)
end

function OilShipmentService:_loadBarrelsOnDeck(boat: Instance, manifest)
	local stackRoot = findBarrelStackRoot(boat)
	if not stackRoot then return end

	local assetsFolder = ReplicatedStorage:FindFirstChild("Assets")
	if not assetsFolder then return end

	local tierTemplates = {
		PremiumRefined = "Barrel_PremiumRefined",
		LightSweet = "Barrel_LightSweet",
		HeavyCrude = "Barrel_HeavyCrude",
	}

	-- Pre-measure each barrel template's actual height for proper stacking
	local tierHeights = {}
	local tierWidths = {}
	for tier, templateName in pairs(tierTemplates) do
		local template = assetsFolder:FindFirstChild(templateName)
		if template then
			local h, w
			if template:IsA("Model") then
				local _, sz = template:GetBoundingBox()
				h = sz.Y
				w = math.max(sz.X, sz.Z)
			else
				h = template.Size.Y
				w = math.max(template.Size.X, template.Size.Z)
			end
			tierHeights[tier] = h + 0.3 -- small gap
			tierWidths[tier] = w + 0.5
		else
			tierHeights[tier] = 4
			tierWidths[tier] = 3.5
		end
	end

	-- Find the max width for grid spacing
	local maxWidth = 0
	for _, w in pairs(tierWidths) do
		if w > maxWidth then maxWidth = w end
	end
	local COLUMNS = 3
	local SPACING = maxWidth

	-- Track cumulative Y per grid column so different-height barrels stack without clipping
	local columnY = {} -- key = "col_row", value = current Y height

	local barrelIndex = 0

	for _, tier in ipairs(TIER_ORDER) do
		local count = manifest[tier] or 0
		local templateName = tierTemplates[tier]
		local template = templateName and assetsFolder:FindFirstChild(templateName)
		local barrelH = tierHeights[tier] or 4

		for _ = 1, math.min(count, 10) do
			local barrel
			if template then
				barrel = template:Clone()
			else
				barrel = Instance.new("Part")
				barrel.Shape = Enum.PartType.Cylinder
				barrel.Size = Vector3.new(2.2, 2, 2)
				barrel.Material = Enum.Material.Metal
				barrel.Color = Color3.fromRGB(165, 118, 46)
				barrel.Orientation = Vector3.new(0, 0, 90)
			end

			barrel.Name = "DeckBarrel"

			local col = barrelIndex % COLUMNS
			local row = math.floor(barrelIndex / COLUMNS) % COLUMNS
			local colKey = col .. "_" .. row
			local currentY = columnY[colKey] or 0

			-- MeshPart barrels place at their center, Models at their WorldPivot (bottom).
			-- Add half-height offset for MeshParts so they sit on top of the stack, not halfway in.
			local yOffset = currentY
			if barrel:IsA("BasePart") then
				yOffset = currentY + barrel.Size.Y / 2
			end

			local offset = Vector3.new(
				(col - 1) * SPACING,
				yOffset,
				(row - 1) * SPACING
			)

			columnY[colKey] = currentY + barrelH

			-- Position relative to stackRoot
			local targetCf = stackRoot.CFrame * CFrame.new(offset)
			if barrel:IsA("Model") then
				barrel:PivotTo(targetCf)
			elseif barrel:IsA("BasePart") then
				barrel.CFrame = targetCf
			end

			barrel.Parent = boat

			-- Unanchor + weld every part to stackRoot (which is already welded to ship root)
			for _, part in ipairs(barrel:IsA("Model") and barrel:GetDescendants() or {barrel}) do
				if part:IsA("BasePart") then
					part.Anchored = false
					part.Massless = true
					part.CanCollide = true
					local wc = Instance.new("WeldConstraint")
					wc.Part0 = stackRoot
					wc.Part1 = part
					wc.Parent = stackRoot
				end
			end
			barrelIndex += 1
		end
	end
end

function OilShipmentService:_addPlayerFlag(boat: Instance, ownerUserId: number)
	-- Find the pre-placed PlayerFlag in the cloned template and apply the player's face to it.
	-- No new parts created — the flag + pole are already positioned in the template by the user.
	local flag = findPlayerFlagPart(boat)
	if not flag then return end

	-- Scale flag 3x (flag only, not pole)
	flag.Size = flag.Size * 3

	-- Player's head image on all side faces
	local thumbUrl = string.format("rbxthumb://type=AvatarHeadShot&id=%d&w=420&h=420", ownerUserId)
	for _, face in ipairs({Enum.NormalId.Front, Enum.NormalId.Back, Enum.NormalId.Left, Enum.NormalId.Right}) do
		local decal = Instance.new("Decal")
		decal.Name = "PlayerHead"
		decal.Texture = thumbUrl
		decal.Face = face
		decal.Parent = flag
	end

	-- Player name label
	local nameGui = Instance.new("SurfaceGui")
	nameGui.Name = "FlagNameGui"
	nameGui.Face = Enum.NormalId.Front
	nameGui.CanvasSize = Vector2.new(400, 100)
	nameGui.Parent = flag

	local player = Players:GetPlayerByUserId(ownerUserId)
	local nameLabel = Instance.new("TextLabel")
	nameLabel.Size = UDim2.fromScale(1, 1)
	nameLabel.Position = UDim2.fromScale(0, 0.7)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Text = player and player.Name or ("Player " .. ownerUserId)
	nameLabel.TextColor3 = Color3.fromRGB(30, 30, 35)
	nameLabel.Font = Enum.Font.GothamBlack
	nameLabel.TextScaled = true
	nameLabel.Parent = nameGui
end

function OilShipmentService:_finishShipmentWithoutPayout(shipment, reason: string)
	self._oilStateService:DecrementShipmentCount(shipment.ownerUserId)
	self._oilStateService:PushState(shipment.ownerUserId)
	local shipLabelF = ShipSkinCatalog.GetSkin(shipment.shipSkinId).displayName
	self:_emitShipmentEvent("ShipmentResolved", {
		ownerUserId = shipment.ownerUserId,
		shipmentId = shipment.shipmentId,
		shipSkinId = shipment.shipSkinId,
		shipDisplayName = shipLabelF,
		boatTypeId = shipLabelF,
		loaded = shipment.totalLoaded,
		delivered = 0,
		lost = shipment.totalLoaded,
		dispatchFee = shipment.dispatchFee,
		failureReason = reason,
	})
end

function OilShipmentService:_getStraitEngineState(): string
	if self._straitStateService and self._straitStateService.GetCurrentState then
		return self._straitStateService:GetCurrentState()
	end
	return "Open"
end

-- Server Output: strait waypoint diagnostics. Studio prints by default (Constants.StraitEventsDebug.VerboseStraitWaypointLogsInStudio).
function OilShipmentService:_straitDebugLogEnabled(): boolean
	local d = Constants.StraitEventsDebug
	if d.LogWaypointTriggers then
		return true
	end
	if RunService:IsStudio() and d.VerboseStraitWaypointLogsInStudio ~= false then
		return true
	end
	return false
end

-- Returns oil units removed (sum) and per-tier oil removed. Loss = ceil(manifestSum * fraction); min 0.
function OilShipmentService:_applyLooseBarrelLoss(shipment, fraction: number): (number, { [string]: number })
	local removedByTier: { [string]: number } = {}
	if fraction <= 0 then
		return 0, removedByTier
	end
	local manifest = shipment.manifest
	if typeof(manifest) ~= "table" then
		return 0, removedByTier
	end
	local onShip = 0
	for _, tier in ipairs(TIER_ORDER) do
		onShip += manifest[tier] or 0
	end
	if onShip <= 0 then
		return 0, removedByTier
	end
	local toRemove = math.ceil(onShip * fraction)
	if toRemove <= 0 then
		return 0, removedByTier
	end
	local removed = 0
	for _, tier in ipairs(BARREL_LOSS_TIER_ORDER) do
		local have = manifest[tier] or 0
		if have > 0 then
			local take = math.min(have, toRemove - removed)
			if take > 0 then
				manifest[tier] = have - take
				removed += take
				removedByTier[tier] = (removedByTier[tier] or 0) + take
			end
		end
		if removed >= toRemove then
			break
		end
	end
	local newTotal = 0
	for _, tier in ipairs(TIER_ORDER) do
		newTotal += manifest[tier] or 0
	end
	shipment.totalLoaded = newTotal
	return removed, removedByTier
end

function OilShipmentService:_snapshotManifestOil(shipment): { [string]: number }
	local out: { [string]: number } = {}
	local m = shipment.manifest
	if typeof(m) ~= "table" then
		return out
	end
	for _, tier in ipairs(MANIFEST_HUD_TIER_ORDER) do
		out[tier] = floorPositive(tonumber(m[tier]) or 0)
	end
	return out
end

function OilShipmentService:_zeroManifestForTotalLoss(shipment)
	local m = shipment.manifest
	if typeof(m) ~= "table" then
		return
	end
	for _, tier in ipairs(TIER_ORDER) do
		m[tier] = 0
	end
	shipment.totalLoaded = 0
end

function OilShipmentService:_emitManifestHudSnapshot(shipment, incident: any?)
	local function tierMapCopy(m: { [string]: any }): { [string]: number }
		local o: { [string]: number } = {}
		for _, tier in ipairs(MANIFEST_HUD_TIER_ORDER) do
			o[tier] = floorPositive(tonumber(m[tier]) or 0)
		end
		return o
	end
	local dispatchedRaw = shipment.dispatchManifestOil
	if typeof(dispatchedRaw) ~= "table" then
		dispatchedRaw = shipment.manifest
	end
	local dispatched = tierMapCopy(dispatchedRaw :: any)
	local remaining = tierMapCopy(shipment.manifest :: any)
	local payload: { [string]: any } = {
		ownerUserId = shipment.ownerUserId,
		shipmentId = shipment.shipmentId,
		perBarrelOil = hudPerBarrelOilUnits(),
		dispatchedOilByTier = dispatched,
		remainingOilByTier = remaining,
	}
	if incident ~= nil then
		payload.incident = incident
	end
	self:_emitShipmentEvent("ManifestHudSnapshot", payload)
end

function OilShipmentService:_emitTotalLossManifestHud(shipment, eventId: string)
	local lossOil = self:_snapshotManifestOil(shipment)
	self:_zeroManifestForTotalLoss(shipment)
	self:_emitManifestHudSnapshot(shipment, {
		title = "Total loss",
		eventId = eventId,
		totalLoss = true,
		lossOilByTier = lossOil,
	})
end

function OilShipmentService:_buildStraitTriggerSlots(path: { Vector3 }, segDists: { number })
	local slots = {}
	for _, laneN in ipairs(StraitEventConfig.LaneWaypointTriggers) do
		local pathIndex = 1 + laneN
		if pathIndex <= #path and pathIndex >= 2 then
			table.insert(slots, {
				laneWaypointIndex = laneN,
				pathIndex = pathIndex,
				distance = segDists[pathIndex],
			})
		end
	end
	table.sort(slots, function(a, b)
		return a.distance < b.distance
	end)
	return slots
end

function OilShipmentService:_emitPirateHitAlert(userId: number, message: string)
	local player = Players:GetPlayerByUserId(userId)
	if not player then
		return
	end
	local ev = self._remoteService:GetEvent(RemoteNames.PirateHitAlert)
	ev:FireClient(player, { message = message })
end

function OilShipmentService:_deliverContractStolenOil(contractorUserId: number, stolenByTier: { [string]: number })
	if not self._warehouseService then
		return
	end
	if typeof(self._warehouseService.DeliverHitBarrels) == "function" then
		self._warehouseService:DeliverHitBarrels(contractorUserId, stolenByTier)
	else
		self._warehouseService:DeliverBarrels(contractorUserId, stolenByTier)
	end
	if self._warehouseService.PushState then
		self._warehouseService:PushState(contractorUserId)
	end
end

function OilShipmentService:_executeForcedContractPirateRaid(
	shipment,
	ownerUserId: number,
	worldPosition: Vector3,
	voyageClock: { startTime: number },
	boat: Instance,
	contractorUserId: number,
	contractId: string
): boolean
	local pc = StraitEventCatalog.PirateRaidConfig
	local log = self:_straitDebugLogEnabled()
	local skinFx = ShipSkinCatalog.GetSkin(shipment.shipSkinId).fxParticleScale
	local particleFxScale = ParticleFxScale.ComputePayloadScale(boat, skinFx)

	local barrelsStolen, stolenByTier = self:_applyLooseBarrelLoss(shipment, FORCED_CONTRACT_PIRATE_LOSS_FRACTION)
	if barrelsStolen > 0 then
		self:_emitManifestHudSnapshot(shipment, {
			title = "Contract hit: pirates raided your ship",
			eventId = "ContractPirateHit",
			totalLoss = false,
			lossOilByTier = stolenByTier,
		})
	end

	local approachSide = Random.new():NextNumber() < 0.5 and 1 or -1
	self:_emitShipmentEvent("PirateRaidEvent", {
		ownerUserId = ownerUserId,
		shipmentId = shipment.shipmentId,
		eventId = "ContractPirateHit",
		displayName = "Contract Hit: Pirate Boarding",
		playtestTitle = "Contract Pirate Hit",
		severity = "High",
		barrelsStolen = barrelsStolen,
		approachSide = approachSide,
		worldPosition = { x = worldPosition.X, y = worldPosition.Y, z = worldPosition.Z },
		particleFxScale = particleFxScale,
		contractorUserId = contractorUserId,
		isContractHit = true,
	})

	self:_emitPirateHitAlert(ownerUserId, string.format("BOUNTY RAID! Pirates stole %d barrels.", barrelsStolen))
	self:_emitPirateHitAlert(contractorUserId, string.format("Your hit landed. Pirates stole %d barrels.", barrelsStolen))

	if barrelsStolen > 0 then
		self:_deliverContractStolenOil(contractorUserId, stolenByTier)
	end

	if self._hitContractService and typeof(self._hitContractService.MarkContractExecuted) == "function" then
		self._hitContractService:MarkContractExecuted(contractId)
	end

	if log then
		print(string.format(
			"[StraitShipment DEBUG] CONTRACT PIRATE RAID shipment=%s victim=%d contractor=%d stolen=%d",
			tostring(shipment.shipmentId),
			ownerUserId,
			contractorUserId,
			barrelsStolen
		))
	end

	task.wait(pc.SequenceDuration)
	voyageClock.startTime += pc.SequenceDuration
	return false
end

function OilShipmentService:_maybeProcessForcedPirateHit(
	shipment,
	ownerUserId: number,
	voyageClock: { startTime: number },
	boat: Instance,
	ctx: { [string]: any }
): boolean
	local pending = ctx.pendingForcedPirateHit
	if not pending then
		return false
	end
	if ctx.eventInProgress then
		return false
	end
	ctx.pendingForcedPirateHit = nil
	ctx.eventInProgress = true
	local pos = ctx.lastWorldPosition
	if typeof(pos) ~= "Vector3" then
		pos = boat:GetPivot().Position
	end
	local didTotalLoss = self:_executeForcedContractPirateRaid(
		shipment,
		ownerUserId,
		pos,
		voyageClock,
		boat,
		pending.contractorUserId,
		pending.contractId
	)
	ctx.eventInProgress = false
	return didTotalLoss
end

-- Returns true if shipment is a total loss (caller must cleanup boat and exit _runShipment).
function OilShipmentService:_handleStraitWaypointTrigger(
	shipment,
	ownerUserId: number,
	laneWaypointIndex: number,
	worldPosition: Vector3,
	voyageClock: { startTime: number },
	boat: Instance
): boolean
	local dbg = Constants.StraitEventsDebug
	local log = self:_straitDebugLogEnabled()
	local engineState = self:_getStraitEngineState()
	local bracketFromEngine = StraitEventConfig.PublicBracketFromEngineState(engineState)
	local bracket = bracketFromEngine
	local bracketNote = ""
	if dbg.ForceBracket then
		bracket = dbg.ForceBracket
		bracketNote = string.format("  [FORCE] event bracket overridden → %s (engine maps to %s)", tostring(dbg.ForceBracket), bracketFromEngine)
	end

	local occurrenceChance = StraitEventConfig.GetOccurrenceChance(bracket)
	local rng = Random.new()
	local rollOcc = rng:NextNumber()
	local occurrenceHit = dbg.ForceOccurrenceAtWaypoint or rollOcc < occurrenceChance

	if log then
		print(
			string.format(
				"  [StraitShipment DEBUG] shipment=%s laneWP=%d\n    strait ENGINE state: %s\n    event BRACKET (for odds/severity): %s (from engine would be: %s)%s\n    occurrence: P(hit)=%.0f%%  roll=%.4f  forceAllCrossings=%s  → %s",
				shipment.shipmentId,
				laneWaypointIndex,
				engineState,
				bracket,
				bracketFromEngine,
				bracketNote == "" and "" or "\n    " .. bracketNote,
				occurrenceChance * 100,
				rollOcc,
				tostring(dbg.ForceOccurrenceAtWaypoint),
				occurrenceHit and "HIT (will roll severity)" or "MISS (no strait event this waypoint)"
			)
		)
	end

	if not occurrenceHit then
		return false
	end

	local severity = StraitEventConfig.RollSeverity(bracket, rng)
	local def = StraitEventCatalog.PickRandom(severity, rng)

	-- Debug: force specific event types
	if dbg.ForceMissileStrike then
		def = StraitEventCatalog.GetById("MissileStrike")
		severity = "High"
	elseif dbg.ForceMineStrike then
		def = StraitEventCatalog.GetById("MineStrike")
		severity = "High"
	elseif dbg.ForcePirateRaid then
		def = StraitEventCatalog.GetById("PirateRaid")
		severity = "Medium"
	elseif dbg.ForceCoastGuardInspection then
		def = StraitEventCatalog.GetById("CoastGuardInspection")
		severity = "Low"
	elseif dbg.ForceUSShipSlap then
		def = StraitEventCatalog.GetById("USShipSlap")
		severity = "High"
	elseif dbg.ForceStorm then
		def = StraitEventCatalog.GetById("Storm")
		severity = "Medium"
	elseif dbg.ForceTornado then
		def = StraitEventCatalog.GetById("Tornado")
		severity = "High"
	end

	if not def then
		if log then
			warn(
				string.format(
					"  [StraitShipment DEBUG] laneWP=%d: occurrence HIT but catalog empty for severity=%s",
					laneWaypointIndex,
					severity
				)
			)
		end
		return false
	end

	if log then
		print(
			string.format(
				"  [StraitShipment DEBUG] ROLLED severity=%s → catalog pick: id=%s  displayName=%q  totalLoss=%s  priceMult×=%s  barrelLossFrac=%s  skipPause=%s",
				severity,
				def.id,
				def.displayName,
				tostring(def.totalLoss),
				def.priceMultiplierFactor and string.format("%.3f", def.priceMultiplierFactor) or "—",
				def.looseBarrelLossFraction and string.format("%.3f", def.looseBarrelLossFraction) or "—",
				tostring(def.skipWaypointPause == true)
			)
		)
	end

	local playtestTitle = StraitEventCatalog.GetPlaytestTitle(def)

	local skinFx = ShipSkinCatalog.GetSkin(shipment.shipSkinId).fxParticleScale
	local particleFxScale = ParticleFxScale.ComputePayloadScale(boat, skinFx)

	-- Special missile event handling: rapid barrage of missiles all around the ship
	if def.missileEvent then
		local mc = StraitEventCatalog.MissileConfig
		local missileCount = mc.MissileCount or 4
		local stagger = mc.BarrageStagger or 0.3
		local flightTime = mc.FlightSeconds or 2.5

		-- Pre-roll all missile outcomes
		local outcomes = {}
		local hasDirectHit = false
		local smallHitApplied = false
		for mi = 1, missileCount do
			local roll = rng:NextNumber()
			local outcome
			if roll < mc.HitChance then
				outcome = "hit"
				hasDirectHit = true
			elseif roll < mc.HitChance + mc.SmallHitChance then
				outcome = "smallHit"
			else
				outcome = "miss"
			end
			outcomes[mi] = outcome
		end

		-- Fire all missiles rapidly (barrage)
		for mi = 1, missileCount do
			local side = (mi % 2 == 0) and 1 or -1
			local angle = (mi / missileCount) * math.pi * 2
			local launchOffset = Vector3.new(
				math.cos(angle) * mc.LaunchDistance + rng:NextNumber(-40, 40),
				mc.LaunchHeight + rng:NextNumber(-15, 15),
				math.sin(angle) * mc.LaunchDistance + rng:NextNumber(-40, 40)
			)
			local launchPos = worldPosition + launchOffset

			local targetPos = worldPosition
			if outcomes[mi] == "miss" then
				local spread = mc.MissSpreadRadius or 40
				targetPos = worldPosition + Vector3.new(
					rng:NextNumber(-spread, spread),
					0,
					rng:NextNumber(-spread, spread)
				)
			end

			self:_emitShipmentEvent("MissileStrikeEvent", {
				ownerUserId = ownerUserId,
				shipmentId = shipment.shipmentId,
				eventId = def.id,
				displayName = def.displayName,
				playtestTitle = playtestTitle,
				severity = severity,
				outcome = outcomes[mi],
				missileIndex = mi,
				missileTotal = missileCount,
				launchPosition = { x = launchPos.X, y = launchPos.Y, z = launchPos.Z },
				targetPosition = { x = targetPos.X, y = targetPos.Y, z = targetPos.Z },
				flightSeconds = flightTime,
				worldPosition = { x = worldPosition.X, y = worldPosition.Y, z = worldPosition.Z },
				particleFxScale = particleFxScale,
			})

			if log then
				print(string.format("  [StraitShipment DEBUG] MISSILE %d/%d launched → %s", mi, missileCount, outcomes[mi]))
			end

			-- Short stagger between launches
			if mi < missileCount then
				task.wait(stagger)
			end
		end

		-- Wait for missiles to fly + impact + aftermath
		local totalPause = flightTime + (mc.BarragePauseAfter or 2.0)
		task.wait(totalPause)
		voyageClock.startTime += totalPause + (missileCount - 1) * stagger

		-- Apply outcomes: small hits first, then check for direct hit
		for mi = 1, missileCount do
			if outcomes[mi] == "smallHit" and not smallHitApplied then
				local barrelsLost, lossByTier = self:_applyLooseBarrelLoss(shipment, mc.SmallHitBarrelLossFraction)
				smallHitApplied = true
				if log then
					print(string.format("  [StraitShipment DEBUG] BARRAGE small hit applied: lost %d barrels", barrelsLost))
				end
				if barrelsLost > 0 then
					self:_emitManifestHudSnapshot(shipment, {
						title = ManifestIncidentTitle.fromEventId(def.id),
						eventId = def.id,
						totalLoss = false,
						lossOilByTier = lossByTier,
					})
				end
			end
		end

		if hasDirectHit then
			if log then
				print("  [StraitShipment DEBUG] BARRAGE: DIRECT HIT — total loss")
			end
			self:_emitTotalLossManifestHud(shipment, def.id)
			return true
		end
		return false
	end

	-- Special mine event handling: mines surface all around the boat
	if def.mineEvent then
		local mc = StraitEventCatalog.MineConfig
		local mineCount = mc.MineCount or 15
		local hitRoll = rng:NextNumber()
		local didHit = hitRoll < mc.HitChance

		-- Pre-generate mine positions spread wide around the ship
		local minePositions = {}
		local radiusMin = mc.SpawnRadiusMin or 30
		local radiusMax = mc.SpawnRadiusMax or 120
		for mi = 1, mineCount do
			local angle = (mi / mineCount) * math.pi * 2 + rng:NextNumber(-0.4, 0.4)
			local dist = rng:NextNumber(radiusMin, radiusMax)
			local offset = Vector3.new(
				math.cos(angle) * dist,
				0,
				math.sin(angle) * dist
			)
			table.insert(minePositions, {
				x = worldPosition.X + offset.X,
				y = worldPosition.Y,
				z = worldPosition.Z + offset.Z,
			})
		end

		-- If hit, place one mine directly in front of the ship (will collide)
		if didHit then
			-- Overwrite a random mine to be at ship position (direct collision)
			local hitIdx = rng:NextInteger(1, math.min(3, mineCount))
			minePositions[hitIdx] = {
				x = worldPosition.X + rng:NextNumber(-3, 3),
				y = worldPosition.Y,
				z = worldPosition.Z + rng:NextNumber(-3, 3),
			}
		end

		-- Fire mine event to all clients
		self:_emitShipmentEvent("MineStrikeEvent", {
			ownerUserId = ownerUserId,
			shipmentId = shipment.shipmentId,
			eventId = def.id,
			displayName = def.displayName,
			playtestTitle = playtestTitle,
			severity = severity,
			didHit = didHit,
			minePositions = minePositions,
			riseSeconds = mc.RiseSeconds,
			worldPosition = { x = worldPosition.X, y = worldPosition.Y, z = worldPosition.Z },
			particleFxScale = particleFxScale,
		})

		if log then
			print(string.format("  [StraitShipment DEBUG] MINES: %d surfacing, hit=%s (roll=%.3f < %.3f)", mineCount, tostring(didHit), hitRoll, mc.HitChance))
		end

		-- Wait for mines to slowly rise + ship to navigate through
		local totalPause = mc.RiseSeconds + mc.PauseAfterSurface + 1
		task.wait(totalPause)
		voyageClock.startTime += totalPause

		if didHit then
			if log then
				print("  [StraitShipment DEBUG] MINE HIT — total loss")
			end
			self:_emitTotalLossManifestHud(shipment, def.id)
			return true
		end
		return false
	end

	-- Coast guard inspection: boarding visual sequence, no barrel loss
	if def.coastGuardEvent then
		local cfg = StraitEventCatalog.CoastGuardInspectionConfig
		local approachSide = rng:NextNumber() < 0.5 and 1 or -1
		self:_emitShipmentEvent("CoastGuardInspectionEvent", {
			ownerUserId = ownerUserId,
			shipmentId = shipment.shipmentId,
			eventId = def.id,
			displayName = def.displayName,
			playtestTitle = playtestTitle,
			severity = severity,
			approachSide = approachSide,
			worldPosition = { x = worldPosition.X, y = worldPosition.Y, z = worldPosition.Z },
			particleFxScale = particleFxScale,
		})
		if log then
			print(string.format("  [StraitShipment DEBUG] COAST GUARD INSPECTION: side=%d, pausing %ds",
				approachSide, cfg.SequenceDuration))
		end
		task.wait(cfg.SequenceDuration)
		voyageClock.startTime += cfg.SequenceDuration
		return false
	end

	-- US Navy ship slap: cinematic total-loss event
	if def.usShipSlapEvent then
		local cfg = StraitEventCatalog.USShipSlapConfig
		local approachSide = rng:NextNumber() < 0.5 and 1 or -1
		self:_emitShipmentEvent("USShipSlapEvent", {
			ownerUserId = ownerUserId,
			shipmentId = shipment.shipmentId,
			eventId = def.id,
			displayName = def.displayName,
			playtestTitle = playtestTitle,
			severity = severity,
			approachSide = approachSide,
			worldPosition = { x = worldPosition.X, y = worldPosition.Y, z = worldPosition.Z },
			particleFxScale = particleFxScale,
		})
		if log then
			print(string.format("  [StraitShipment DEBUG] US SHIP SLAP: side=%d, pausing %ds then total loss",
				approachSide, cfg.SequenceDuration))
		end
		self:_emitTotalLossManifestHud(shipment, def.id)
		task.wait(cfg.SequenceDuration)
		return true -- total loss
	end

	-- Special pirate raid handling: visual boarding + barrel stealing sequence
	if def.pirateEvent then
		local pc = StraitEventCatalog.PirateRaidConfig

		-- Apply barrel loss (server-authoritative, same as normal event)
		local barrelsStolen = 0
		local stolenByTier: { [string]: number } = {}
		if def.looseBarrelLossFraction and def.looseBarrelLossFraction > 0 then
			barrelsStolen, stolenByTier = self:_applyLooseBarrelLoss(shipment, def.looseBarrelLossFraction)
		end
		if barrelsStolen > 0 then
			self:_emitManifestHudSnapshot(shipment, {
				title = ManifestIncidentTitle.fromEventId(def.id),
				eventId = def.id,
				totalLoss = false,
				lossOilByTier = stolenByTier,
			})
		end

		-- Pick approach side (perpendicular to ship heading)
		local approachSide = rng:NextNumber() < 0.5 and 1 or -1

		-- Fire pirate raid event to all clients
		self:_emitShipmentEvent("PirateRaidEvent", {
			ownerUserId = ownerUserId,
			shipmentId = shipment.shipmentId,
			eventId = def.id,
			displayName = def.displayName,
			playtestTitle = playtestTitle,
			severity = severity,
			barrelsStolen = barrelsStolen,
			approachSide = approachSide,
			worldPosition = { x = worldPosition.X, y = worldPosition.Y, z = worldPosition.Z },
			particleFxScale = particleFxScale,
		})

		if log then
			print(string.format("  [StraitShipment DEBUG] PIRATE RAID: %d barrels stolen, side=%d, pausing %ds",
				barrelsStolen, approachSide, pc.SequenceDuration))
		end

		-- Pause ship for the full cinematic sequence
		task.wait(pc.SequenceDuration)
		voyageClock.startTime += pc.SequenceDuration
		return false
	end

	if def.stormEvent then
		local sc = StraitEventCatalog.StormConfig
		local baseSequenceSeconds = math.max(0, tonumber(sc.BaseSequenceSeconds) or 0)

		local didDelay = rng:NextNumber() < clamp01(tonumber(sc.DelayChance) or 0)
		local delaySeconds = 0
		if didDelay then
			local delayMin = math.max(0, tonumber(sc.DelaySecondsMin) or 0)
			local delayMax = math.max(delayMin, tonumber(sc.DelaySecondsMax) or delayMin)
			delaySeconds = rng:NextNumber(delayMin, delayMax)
		end

		local didBarrelLoss = rng:NextNumber() < clamp01(tonumber(sc.BarrelLossChance) or 0)
		local barrelLossFraction = 0
		local barrelsLost = 0
		local stormLossByTier: { [string]: number } = {}
		if didBarrelLoss then
			local lossMin = clamp01(tonumber(sc.BarrelLossFractionMin) or 0)
			local lossMax = math.max(lossMin, clamp01(tonumber(sc.BarrelLossFractionMax) or lossMin))
			barrelLossFraction = clamp01(rng:NextNumber(lossMin, lossMax))
			barrelsLost, stormLossByTier = self:_applyLooseBarrelLoss(shipment, barrelLossFraction)
			didBarrelLoss = barrelsLost > 0
		end
		if barrelsLost > 0 then
			self:_emitManifestHudSnapshot(shipment, {
				title = ManifestIncidentTitle.fromEventId(def.id),
				eventId = def.id,
				totalLoss = false,
				lossOilByTier = stormLossByTier,
			})
		end

		local sequenceSeconds = baseSequenceSeconds + delaySeconds
		self:_emitShipmentEvent("StormEvent", {
			ownerUserId = ownerUserId,
			shipmentId = shipment.shipmentId,
			eventId = def.id,
			displayName = def.displayName,
			playtestTitle = playtestTitle,
			severity = severity,
			laneWaypointIndex = laneWaypointIndex,
			worldPosition = { x = worldPosition.X, y = worldPosition.Y, z = worldPosition.Z },
			didDelay = didDelay,
			delaySeconds = delaySeconds,
			didBarrelLoss = didBarrelLoss,
			barrelsLost = barrelsLost,
			barrelLossFraction = barrelLossFraction,
			sequenceSeconds = sequenceSeconds,
			particleFxScale = particleFxScale,
		})

		if log then
			print(string.format(
				"  [StraitShipment DEBUG] STORM: delay=%s(%.2fs) barrelLoss=%s(lost=%d frac=%.3f) seq=%.2fs",
				tostring(didDelay),
				delaySeconds,
				tostring(didBarrelLoss),
				barrelsLost,
				barrelLossFraction,
				sequenceSeconds
			))
		end

		if sequenceSeconds > 0 then
			task.wait(sequenceSeconds)
			voyageClock.startTime += sequenceSeconds
		end
		return false
	end

	if def.tornadoEvent then
		local tc = StraitEventCatalog.TornadoConfig
		local baseSequenceSeconds = math.max(0, tonumber(tc.BaseSequenceSeconds) or 0)

		local didDelay = rng:NextNumber() < clamp01(tonumber(tc.DelayChance) or 0)
		local delaySeconds = 0
		if didDelay then
			local delayMin = math.max(0, tonumber(tc.DelaySecondsMin) or 0)
			local delayMax = math.max(delayMin, tonumber(tc.DelaySecondsMax) or delayMin)
			delaySeconds = rng:NextNumber(delayMin, delayMax)
		end

		local didBarrelLoss = rng:NextNumber() < clamp01(tonumber(tc.BarrelLossChance) or 0)
		local barrelLossFraction = 0
		local barrelsLost = 0
		local tornadoLossByTier: { [string]: number } = {}
		if didBarrelLoss then
			local lossMin = clamp01(tonumber(tc.BarrelLossFractionMin) or 0)
			local lossMax = math.max(lossMin, clamp01(tonumber(tc.BarrelLossFractionMax) or lossMin))
			barrelLossFraction = clamp01(rng:NextNumber(lossMin, lossMax))
			barrelsLost, tornadoLossByTier = self:_applyLooseBarrelLoss(shipment, barrelLossFraction)
			didBarrelLoss = barrelsLost > 0
		end
		if barrelsLost > 0 then
			self:_emitManifestHudSnapshot(shipment, {
				title = ManifestIncidentTitle.fromEventId(def.id),
				eventId = def.id,
				totalLoss = false,
				lossOilByTier = tornadoLossByTier,
			})
		end

		local sequenceSeconds = baseSequenceSeconds + delaySeconds
		local shipPivotPos: Vector3? = nil
		local shipBoundsSize: Vector3? = nil
		if boat then
			local bbCf, bbSize = boat:GetBoundingBox()
			shipPivotPos = bbCf.Position
			shipBoundsSize = bbSize
		end
		self:_emitShipmentEvent("TornadoEvent", {
			ownerUserId = ownerUserId,
			shipmentId = shipment.shipmentId,
			eventId = def.id,
			displayName = def.displayName,
			playtestTitle = playtestTitle,
			severity = severity,
			laneWaypointIndex = laneWaypointIndex,
			worldPosition = { x = worldPosition.X, y = worldPosition.Y, z = worldPosition.Z },
			didDelay = didDelay,
			delaySeconds = delaySeconds,
			didBarrelLoss = didBarrelLoss,
			barrelsLost = barrelsLost,
			barrelLossFraction = barrelLossFraction,
			sequenceSeconds = sequenceSeconds,
			maxVisualBarrels = tonumber(tc.MaxVisualBarrels) or 10,
			particleFxScale = particleFxScale,
			shipPivotPosition = if shipPivotPos then { x = shipPivotPos.X, y = shipPivotPos.Y, z = shipPivotPos.Z } else nil,
			shipBoundsSize = if shipBoundsSize then { x = shipBoundsSize.X, y = shipBoundsSize.Y, z = shipBoundsSize.Z } else nil,
		})

		if log then
			print(string.format(
				"  [StraitShipment DEBUG] TORNADO: delay=%s(%.2fs) barrelLoss=%s(lost=%d frac=%.3f) seq=%.2fs",
				tostring(didDelay),
				delaySeconds,
				tostring(didBarrelLoss),
				barrelsLost,
				barrelLossFraction,
				sequenceSeconds
			))
		end

		if sequenceSeconds > 0 then
			task.wait(sequenceSeconds)
			voyageClock.startTime += sequenceSeconds
		end
		return false
	end

	if def.totalLoss then
		local animPause = StraitEventConfig.DefaultWaypointPauseSeconds
		self:_emitShipmentEvent("StraitWaypointEvent", {
			ownerUserId = ownerUserId,
			shipmentId = shipment.shipmentId,
			eventId = def.id,
			displayName = def.displayName,
			playtestTitle = playtestTitle,
			severity = severity,
			laneWaypointIndex = laneWaypointIndex,
			totalLoss = true,
			pauseSeconds = animPause,
			worldPosition = { x = worldPosition.X, y = worldPosition.Y, z = worldPosition.Z },
			particleFxScale = particleFxScale,
		})
		self:_emitTotalLossManifestHud(shipment, def.id)
		task.wait(animPause)
		if log then
			print(
				string.format(
					"  [StraitShipment DEBUG] OUTCOME: TOTAL LOSS (engine=%s bracket=%s event=%s) after %.1fs animation hold — shipment ends here.",
					engineState,
					bracket,
					def.id,
					animPause
				)
			)
		end
		return true
	end

	local barrelsLost = 0
	local waypointLossByTier: { [string]: number } = {}
	if def.looseBarrelLossFraction and def.looseBarrelLossFraction > 0 then
		barrelsLost, waypointLossByTier = self:_applyLooseBarrelLoss(shipment, def.looseBarrelLossFraction)
	end
	if barrelsLost > 0 then
		self:_emitManifestHudSnapshot(shipment, {
			title = ManifestIncidentTitle.fromEventId(def.id),
			eventId = def.id,
			totalLoss = false,
			lossOilByTier = waypointLossByTier,
		})
	end

	local pauseSeconds = 0
	if not def.skipWaypointPause then
		pauseSeconds = def.pauseSeconds or StraitEventConfig.DefaultWaypointPauseSeconds
	end

	-- Fire visuals before the hold so every client can start FX in sync with the server pause (SPEC §8.2).
	local payload: { [string]: any } = {
		ownerUserId = ownerUserId,
		shipmentId = shipment.shipmentId,
		eventId = def.id,
		displayName = def.displayName,
		playtestTitle = playtestTitle,
		severity = severity,
		laneWaypointIndex = laneWaypointIndex,
		totalLoss = false,
		pauseSeconds = pauseSeconds,
		worldPosition = { x = worldPosition.X, y = worldPosition.Y, z = worldPosition.Z },
		totalLoaded = shipment.totalLoaded,
		particleFxScale = particleFxScale,
	}
	if barrelsLost > 0 then
		payload.barrelsLost = barrelsLost
	end
	self:_emitShipmentEvent("StraitWaypointEvent", payload)

	if not def.skipWaypointPause and pauseSeconds > 0 then
		task.wait(pauseSeconds)
		voyageClock.startTime += pauseSeconds
	end
	if log then
		print(
			string.format(
				"  [StraitShipment DEBUG] OUTCOME: event applied (engine=%s bracket=%s)  barrelsLost=%d  totalLoaded=%d  pause=%.1fs  fired StraitWaypointEvent to clients",
				engineState,
				bracket,
				barrelsLost,
				shipment.totalLoaded,
				pauseSeconds
			)
		)
	end
	return false
end

-- =================== SHIP LIFECYCLE (Physics-Driven) ===================

function OilShipmentService:_setupShip(shipmentId: string, boatModel: Model, startPosition: Vector3, lookDirection: Vector3)
	-- 1. Find root part (largest volume BasePart)
	local root: BasePart? = nil
	local bestVol = 0
	for _, d in ipairs(boatModel:GetDescendants()) do
		if d:IsA("BasePart") then
			local v = d.Size.X * d.Size.Y * d.Size.Z
			if v > bestVol then
				bestVol = v
				root = d
			end
		end
	end
	if not root then
		warn("[OilShipmentService] No root part found for ship")
		return
	end

	-- 2. Build rigid assembly: unanchor all, weld non-root to root.
	-- Skip welding door parts (IsDoor attribute) — they swing via HingeConstraint.
	-- Their frames (DOOR*_Frame) DO get welded so they move with the ship.
	for _, d in ipairs(boatModel:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = false
			d.CanCollide = true
			d.CanTouch = true
			d.CanQuery = true
			if d == root then
				d.Massless = false
			elseif d:GetAttribute("IsDoor") then
				-- Door panel: don't weld, let hinge control it
				d.Massless = true
			else
				d.Massless = true
				local wc = Instance.new("WeldConstraint")
				wc.Part0 = root
				wc.Part1 = d
				wc.Parent = root
			end
			pcall(function()
				d.CollisionGroup = "ShipmentShip"
			end)
		end
	end

	-- 3. Server authority — prevents client from fighting for physics ownership
	pcall(function()
		root:SetNetworkOwner(nil)
	end)

	-- 4. Constraints
	local att = Instance.new("Attachment")
	att.Name = "ShipAtt"
	att.Parent = root

	local alignPos = Instance.new("AlignPosition")
	alignPos.Name = "ShipAlignPos"
	alignPos.Mode = Enum.PositionAlignmentMode.OneAttachment
	alignPos.Attachment0 = att
	alignPos.MaxForce = 1e9
	alignPos.MaxVelocity = 200
	alignPos.Responsiveness = 8
	alignPos.Position = startPosition
	alignPos.Parent = root

	local alignOri = Instance.new("AlignOrientation")
	alignOri.Name = "ShipAlignOri"
	alignOri.Mode = Enum.OrientationAlignmentMode.OneAttachment
	alignOri.Attachment0 = att
	alignOri.MaxTorque = 1e9
	alignOri.Responsiveness = 4
	alignOri.Parent = root

	-- 5. Initial orientation: PivotTo first to get the ship UPRIGHT at startPosition.
	-- Then capture the root's actual rotation (which keeps the ship right-side-up).
	-- Only adjust YAW on top of that base rotation.
	boatModel:PivotTo(CFrame.new(startPosition))

	-- Capture the root's "upright" rotation.
	local baseRotation = root.CFrame - root.CFrame.Position -- rotation-only CFrame

	-- Default bow direction: prefer the skin's FRONT_MARKER (bow) + DockAnchor (stern).
	-- Falls back to legacy "bow at local -X" heuristic if markers missing.
	local rig = resolveRigForBoatInstance(boatModel)
	local frontMarker = ShipRig.FindBasePart(boatModel, rig.frontMarkerName)
	local dockAnchor = ShipRig.FindAttachment(boatModel, rig.dockAnchorName)
	local defaultYaw: number
	if frontMarker and dockAnchor then
		local bowWorld = frontMarker.Position - dockAnchor.WorldPosition
		bowWorld = Vector3.new(bowWorld.X, 0, bowWorld.Z)
		if bowWorld.Magnitude < 0.01 then
			defaultYaw = math.atan2(-root.CFrame.RightVector.Z, root.CFrame.RightVector.X)
		else
			bowWorld = bowWorld.Unit
			defaultYaw = math.atan2(bowWorld.X, bowWorld.Z)
		end
	else
		local defaultBowDir = root.CFrame.RightVector -- legacy: +X after PivotTo
		defaultYaw = math.atan2(-defaultBowDir.Z, defaultBowDir.X)
	end

	-- Compute desired yaw from look direction
	local flatDir = Vector3.new(lookDirection.X, 0, lookDirection.Z)
	if flatDir.Magnitude < 0.01 then
		flatDir = Vector3.new(0, 0, -1)
	end
	local bowDir = flatDir.Unit
	-- Target yaw: bow points along travel direction. Formula matches the atan2 convention
	-- used above for defaultYaw (atan2(X, Z) for FRONT_MARKER path,
	-- atan2(-Z, X)+pi for legacy path → compensated below).
	local targetYaw: number
	if frontMarker and dockAnchor then
		targetYaw = math.atan2(bowDir.X, bowDir.Z)
	else
		targetYaw = math.atan2(-bowDir.Z, bowDir.X) + math.pi
	end
	local yawDelta = targetYaw - defaultYaw

	-- Apply: base upright rotation + yaw delta
	local initRotation = CFrame.Angles(0, yawDelta, 0) * baseRotation
	root.CFrame = CFrame.new(startPosition) * initRotation
	alignOri.CFrame = initRotation

	-- Store default yaw + bow-convention mode so _updateShipPosition matches.
	boatModel:SetAttribute("DefaultYaw", defaultYaw)
	boatModel:SetAttribute("BowAtan2Mode", (frontMarker and dockAnchor) and "xz" or "legacy")

	boatModel.PrimaryPart = root

	-- 6. Store runtime state (including baseRotation for update function)
	self._activeShips[shipmentId] = {
		root = root,
		alignPos = alignPos,
		alignOri = alignOri,
		lastForward = bowDir,
		baseRotation = baseRotation,
		connections = {},
	}
end

function OilShipmentService:_updateShipPosition(shipmentId: string, boatModel: Model, targetPosition: Vector3, targetLookDirection: Vector3)
	local state = self._activeShips[shipmentId]
	if not state then return end

	-- Flat direction (yaw only, never pitch)
	local flatDir = Vector3.new(targetLookDirection.X, 0, targetLookDirection.Z)
	if flatDir.Magnitude < 0.01 then
		flatDir = state.lastForward
	else
		flatDir = flatDir.Unit
	end
	state.lastForward = flatDir

	-- Compute yaw delta from the ship's default orientation.
	-- Match the bow convention captured at setup: FRONT_MARKER-driven ("xz") vs legacy.
	local defaultYaw = boatModel:GetAttribute("DefaultYaw") or 0
	local mode = boatModel:GetAttribute("BowAtan2Mode") or "legacy"
	local targetYaw: number
	if mode == "xz" then
		targetYaw = math.atan2(flatDir.X, flatDir.Z) + math.pi
	else
		targetYaw = math.atan2(-flatDir.Z, flatDir.X) + math.pi
	end
	local yawDelta = targetYaw - defaultYaw

	-- Capture the base upright rotation (stored at setup, preserved in root's natural orientation)
	-- Re-derive from the root's current CFrame minus the previous yaw we applied
	-- Simpler: just store baseRotation in state
	if not state.baseRotation then
		-- Fallback: read from root now (should have been stored at setup)
		state.baseRotation = CFrame.Angles(0, 0, 0)
	end

	-- Drive constraints: base upright + yaw delta
	state.alignPos.Position = targetPosition
	state.alignOri.CFrame = CFrame.Angles(0, yawDelta, 0) * state.baseRotation
end

-- Drops this shipment's voyage state (constraint refs, connections). Does NOT destroy the
-- boat model — BoatDockService:CheckinBoat is responsible for the model + cooldown lifecycle.
function OilShipmentService:_teardownShip(shipmentId: string)
	local state = self._activeShips[shipmentId]
	if not state then return end
	for _, conn in ipairs(state.connections) do
		pcall(function() conn:Disconnect() end)
	end
	self._activeShips[shipmentId] = nil
end

function OilShipmentService:_createFallbackBoat(): Model
	local model = Instance.new("Model")
	model.Name = "FallbackTanker"

	local body = Instance.new("Part")
	body.Name = "FallbackShipBody"
	body.Size = Vector3.new(14, 3, 30)
	body.Material = Enum.Material.Metal
	body.Color = Color3.fromRGB(58, 72, 88)
	body.Anchored = true
	body.CanCollide = false
	body.Parent = model

	local deck = Instance.new("Part")
	deck.Name = "Deck"
	deck.Size = Vector3.new(10, 2, 16)
	deck.Material = Enum.Material.Metal
	deck.Color = Color3.fromRGB(90, 96, 106)
	deck.Anchored = true
	deck.CanCollide = false
	deck.CFrame = body.CFrame * CFrame.new(0, 2.0, 0)
	deck.Parent = model

	model.PrimaryPart = body
	return model
end

function OilShipmentService:_emitShipmentEvent(kind: string, payload)
	local event = self._remoteService:GetEvent(RemoteNames.ShipmentVisualEvent)
	event:FireAllClients({
		type = kind,
		data = payload,
	})
end

function OilShipmentService:_sendActionResult(player: Player, ok: boolean, code: string, message: string, data)
	local event = self._remoteService:GetEvent(RemoteNames.OilActionResult)
	event:FireClient(player, {
		ok = ok,
		code = code,
		message = message,
		data = data,
	})
end

function OilShipmentService:DebugDispatchMissile(player: Player)
	local userId = player.UserId
	local plot = self._plotService:GetOwnedPlot(userId)
	if not plot then
		warn("[DebugDispatch] Player has no plot")
		return
	end

	-- Temporarily force missile strike + occurrence at every waypoint
	local dbg = Constants.StraitEventsDebug
	local prevForceOcc = dbg.ForceOccurrenceAtWaypoint
	local prevForceMissile = dbg.ForceMissileStrike
	dbg.ForceOccurrenceAtWaypoint = true
	dbg.ForceMissileStrike = true

	local manifest = { HeavyCrude = 30, LightSweet = 0, PremiumRefined = 0 }
	local st = self._oilStateService:GetState(userId)
	local speedL = if st then math.clamp(math.floor(st.shipSpeedLevel or 3), 1, 10) else 3
	local capL = if st then math.clamp(math.floor(st.shipCapacityLevel or 5), 1, 25) else 5
	local skinId = if st and typeof(st.shipSkinId) == "string" and ShipSkinCatalog.Skins[st.shipSkinId] then st.shipSkinId else "DefaultTanker"
	local stats = ShipStats.Resolve(speedL, capL)

	local shipment = {
		shipmentId = HttpService:GenerateGUID(false),
		ownerUserId = userId,
		shipSkinId = skinId,
		shipSpeedLevel = speedL,
		shipCapacityLevel = capL,
		manifest = manifest,
		totalLoaded = 30,
		dispatchFee = 0,
		travelSeconds = stats.travelSeconds,
		eventRisk = 0,
	}

	print(string.format("[DebugDispatch] Launching missile test ship for %s (shipmentId=%s)", player.Name, shipment.shipmentId))

	task.spawn(function()
		self:_runShipment(shipment)
		-- Restore debug flags after voyage completes
		dbg.ForceOccurrenceAtWaypoint = prevForceOcc
		dbg.ForceMissileStrike = prevForceMissile
	end)

	-- Teleport player to ship after a brief delay for it to spawn
	task.delay(2, function()
		self:_handleTeleportToShip(player)
	end)
end

function OilShipmentService:DebugDispatchMine(player: Player)
	local userId = player.UserId
	local plot = self._plotService:GetOwnedPlot(userId)
	if not plot then
		warn("[DebugDispatch] Player has no plot")
		return
	end

	local dbg = Constants.StraitEventsDebug
	local prevForceOcc = dbg.ForceOccurrenceAtWaypoint
	local prevForceMine = dbg.ForceMineStrike
	dbg.ForceOccurrenceAtWaypoint = true
	dbg.ForceMineStrike = true

	local manifest = { HeavyCrude = 30, LightSweet = 0, PremiumRefined = 0 }
	local st = self._oilStateService:GetState(userId)
	local speedL = if st then math.clamp(math.floor(st.shipSpeedLevel or 3), 1, 10) else 3
	local capL = if st then math.clamp(math.floor(st.shipCapacityLevel or 5), 1, 25) else 5
	local skinId = if st and typeof(st.shipSkinId) == "string" and ShipSkinCatalog.Skins[st.shipSkinId] then st.shipSkinId else "DefaultTanker"
	local stats = ShipStats.Resolve(speedL, capL)

	local shipment = {
		shipmentId = HttpService:GenerateGUID(false),
		ownerUserId = userId,
		shipSkinId = skinId,
		shipSpeedLevel = speedL,
		shipCapacityLevel = capL,
		manifest = manifest,
		totalLoaded = 30,
		dispatchFee = 0,
		travelSeconds = stats.travelSeconds,
		eventRisk = 0,
	}

	print(string.format("[DebugDispatch] Launching mine test ship for %s (shipmentId=%s)", player.Name, shipment.shipmentId))

	task.spawn(function()
		self:_runShipment(shipment)
		dbg.ForceOccurrenceAtWaypoint = prevForceOcc
		dbg.ForceMineStrike = prevForceMine
	end)

	task.delay(2, function()
		self:_handleTeleportToShip(player)
	end)
end

function OilShipmentService:DebugDispatchPirate(player: Player)
	local userId = player.UserId
	local plot = self._plotService:GetOwnedPlot(userId)
	if not plot then
		warn("[DebugDispatch] Player has no plot")
		return
	end

	local dbg = Constants.StraitEventsDebug
	local prevForceOcc = dbg.ForceOccurrenceAtWaypoint
	local prevForcePirate = dbg.ForcePirateRaid
	dbg.ForceOccurrenceAtWaypoint = true
	dbg.ForcePirateRaid = true

	local manifest = { HeavyCrude = 25, LightSweet = 5, PremiumRefined = 0 }
	local st = self._oilStateService:GetState(userId)
	local speedL = if st then math.clamp(math.floor(st.shipSpeedLevel or 3), 1, 10) else 3
	local capL = if st then math.clamp(math.floor(st.shipCapacityLevel or 5), 1, 25) else 5
	local skinId = if st and typeof(st.shipSkinId) == "string" and ShipSkinCatalog.Skins[st.shipSkinId] then st.shipSkinId else "DefaultTanker"
	local stats = ShipStats.Resolve(speedL, capL)

	local shipment = {
		shipmentId = HttpService:GenerateGUID(false),
		ownerUserId = userId,
		shipSkinId = skinId,
		shipSpeedLevel = speedL,
		shipCapacityLevel = capL,
		manifest = manifest,
		totalLoaded = 30,
		dispatchFee = 0,
		travelSeconds = stats.travelSeconds,
		eventRisk = 0,
	}

	print(string.format("[DebugDispatch] Launching pirate test ship for %s (shipmentId=%s)", player.Name, shipment.shipmentId))

	task.spawn(function()
		self:_runShipment(shipment)
		dbg.ForceOccurrenceAtWaypoint = prevForceOcc
		dbg.ForcePirateRaid = prevForcePirate
	end)

	task.spawn(function()
		for _ = 1, 20 do
			task.wait(0.5)
			self:_handleTeleportToShip(player)
			-- Check if player is now seated (teleport worked)
			local char = player.Character
			if char then
				local hum = char:FindFirstChildOfClass("Humanoid")
				if hum and hum.SeatPart then
					return
				end
			end
		end
	end)
end

function OilShipmentService:DebugDispatchStorm(player: Player)
	local userId = player.UserId
	local plot = self._plotService:GetOwnedPlot(userId)
	if not plot then
		warn("[DebugDispatch] Player has no plot")
		return
	end

	local dbg = Constants.StraitEventsDebug
	local prevForceOcc = dbg.ForceOccurrenceAtWaypoint
	local prevForceStorm = dbg.ForceStorm
	dbg.ForceOccurrenceAtWaypoint = true
	dbg.ForceStorm = true

	local st = self._oilStateService:GetState(userId)
	local speedL = if st then math.clamp(math.floor(st.shipSpeedLevel or 3), 1, 10) else 3
	local capL = if st then math.clamp(math.floor(st.shipCapacityLevel or 5), 1, 25) else 5
	local skinId = if st and typeof(st.shipSkinId) == "string" and ShipSkinCatalog.Skins[st.shipSkinId] then st.shipSkinId else "DefaultTanker"
	local stats = ShipStats.Resolve(speedL, capL)

	local shipment = {
		shipmentId = HttpService:GenerateGUID(false),
		ownerUserId = userId,
		shipSkinId = skinId,
		shipSpeedLevel = speedL,
		shipCapacityLevel = capL,
		manifest = { HeavyCrude = 28, LightSweet = 6, PremiumRefined = 2 },
		totalLoaded = 36,
		dispatchFee = 0,
		travelSeconds = stats.travelSeconds,
		eventRisk = 0,
	}

	print(string.format("[DebugDispatch] Launching storm test ship for %s (shipmentId=%s)", player.Name, shipment.shipmentId))

	task.spawn(function()
		self:_runShipment(shipment)
		dbg.ForceOccurrenceAtWaypoint = prevForceOcc
		dbg.ForceStorm = prevForceStorm
	end)

	task.spawn(function()
		for _ = 1, 20 do
			task.wait(0.5)
			self:_handleTeleportToShip(player)
			local char = player.Character
			if char then
				local hum = char:FindFirstChildOfClass("Humanoid")
				if hum and hum.SeatPart then
					return
				end
			end
		end
	end)
end

function OilShipmentService:DebugDispatchTornado(player: Player)
	local userId = player.UserId
	local plot = self._plotService:GetOwnedPlot(userId)
	if not plot then
		warn("[DebugDispatch] Player has no plot")
		return
	end

	local dbg = Constants.StraitEventsDebug
	local prevForceOcc = dbg.ForceOccurrenceAtWaypoint
	local prevForceTornado = dbg.ForceTornado
	dbg.ForceOccurrenceAtWaypoint = true
	dbg.ForceTornado = true

	local st = self._oilStateService:GetState(userId)
	local speedL = if st then math.clamp(math.floor(st.shipSpeedLevel or 3), 1, 10) else 3
	local capL = if st then math.clamp(math.floor(st.shipCapacityLevel or 5), 1, 25) else 5
	local skinId = if st and typeof(st.shipSkinId) == "string" and ShipSkinCatalog.Skins[st.shipSkinId] then st.shipSkinId else "DefaultTanker"
	local stats = ShipStats.Resolve(speedL, capL)

	local shipment = {
		shipmentId = HttpService:GenerateGUID(false),
		ownerUserId = userId,
		shipSkinId = skinId,
		shipSpeedLevel = speedL,
		shipCapacityLevel = capL,
		manifest = { HeavyCrude = 32, LightSweet = 8, PremiumRefined = 4 },
		totalLoaded = 44,
		dispatchFee = 0,
		travelSeconds = stats.travelSeconds,
		eventRisk = 0,
	}

	print(string.format("[DebugDispatch] Launching tornado test ship for %s (shipmentId=%s)", player.Name, shipment.shipmentId))

	task.spawn(function()
		self:_runShipment(shipment)
		dbg.ForceOccurrenceAtWaypoint = prevForceOcc
		dbg.ForceTornado = prevForceTornado
	end)

	task.spawn(function()
		for _ = 1, 20 do
			task.wait(0.5)
			self:_handleTeleportToShip(player)
			local char = player.Character
			if char then
				local hum = char:FindFirstChildOfClass("Humanoid")
				if hum and hum.SeatPart then
					return
				end
			end
		end
	end)
end

function OilShipmentService:DebugDispatchCoastGuard(player: Player)
	local userId = player.UserId
	local plot = self._plotService:GetOwnedPlot(userId)
	if not plot then
		warn("[DebugDispatch] Player has no plot")
		return
	end

	local dbg = Constants.StraitEventsDebug
	local prevForceOcc = dbg.ForceOccurrenceAtWaypoint
	local prevForceCoastGuard = dbg.ForceCoastGuardInspection
	dbg.ForceOccurrenceAtWaypoint = true
	dbg.ForceCoastGuardInspection = true

	local st = self._oilStateService:GetState(userId)
	local speedL = if st then math.clamp(math.floor(st.shipSpeedLevel or 3), 1, 10) else 3
	local capL = if st then math.clamp(math.floor(st.shipCapacityLevel or 5), 1, 25) else 5
	local skinId = if st and typeof(st.shipSkinId) == "string" and ShipSkinCatalog.Skins[st.shipSkinId] then st.shipSkinId else "DefaultTanker"
	local stats = ShipStats.Resolve(speedL, capL)

	local shipment = {
		shipmentId = HttpService:GenerateGUID(false),
		ownerUserId = userId,
		shipSkinId = skinId,
		shipSpeedLevel = speedL,
		shipCapacityLevel = capL,
		manifest = { HeavyCrude = 25, LightSweet = 5, PremiumRefined = 0 },
		totalLoaded = 30,
		dispatchFee = 0,
		travelSeconds = stats.travelSeconds,
		eventRisk = 0,
	}

	print(string.format("[DebugDispatch] Launching coast guard inspection test ship for %s (shipmentId=%s)", player.Name, shipment.shipmentId))

	task.spawn(function()
		self:_runShipment(shipment)
		dbg.ForceOccurrenceAtWaypoint = prevForceOcc
		dbg.ForceCoastGuardInspection = prevForceCoastGuard
	end)

	task.spawn(function()
		for _ = 1, 20 do
			task.wait(0.5)
			self:_handleTeleportToShip(player)
			local char = player.Character
			if char then
				local hum = char:FindFirstChildOfClass("Humanoid")
				if hum and hum.SeatPart then
					return
				end
			end
		end
	end)
end

function OilShipmentService:DebugDispatchUSShipSlap(player: Player)
	local userId = player.UserId
	local plot = self._plotService:GetOwnedPlot(userId)
	if not plot then
		warn("[DebugDispatch] Player has no plot")
		return
	end

	local dbg = Constants.StraitEventsDebug
	local prevForceOcc = dbg.ForceOccurrenceAtWaypoint
	local prevForceSlap = dbg.ForceUSShipSlap
	dbg.ForceOccurrenceAtWaypoint = true
	dbg.ForceUSShipSlap = true

	local st = self._oilStateService:GetState(userId)
	local speedL = if st then math.clamp(math.floor(st.shipSpeedLevel or 3), 1, 10) else 3
	local capL = if st then math.clamp(math.floor(st.shipCapacityLevel or 5), 1, 25) else 5
	local skinId = if st and typeof(st.shipSkinId) == "string" and ShipSkinCatalog.Skins[st.shipSkinId] then st.shipSkinId else "DefaultTanker"
	local stats = ShipStats.Resolve(speedL, capL)

	local shipment = {
		shipmentId = HttpService:GenerateGUID(false),
		ownerUserId = userId,
		shipSkinId = skinId,
		shipSpeedLevel = speedL,
		shipCapacityLevel = capL,
		manifest = { HeavyCrude = 25, LightSweet = 5, PremiumRefined = 0 },
		totalLoaded = 30,
		dispatchFee = 0,
		travelSeconds = stats.travelSeconds,
		eventRisk = 0,
	}

	print(string.format("[DebugDispatch] Launching US ship slap test for %s (shipmentId=%s)", player.Name, shipment.shipmentId))

	task.spawn(function()
		self:_runShipment(shipment)
		dbg.ForceOccurrenceAtWaypoint = prevForceOcc
		dbg.ForceUSShipSlap = prevForceSlap
	end)

	task.spawn(function()
		for _ = 1, 20 do
			task.wait(0.5)
			self:_handleTeleportToShip(player)
			local char = player.Character
			if char then
				local hum = char:FindFirstChildOfClass("Humanoid")
				if hum and hum.SeatPart then
					return
				end
			end
		end
	end)
end

return OilShipmentService
