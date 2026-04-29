--!strict

local Debris = game:GetService("Debris")
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
local ShipStats = require(Shared:WaitForChild("Config"):WaitForChild("ShipStats"))
local ShipUpgradeConfig = require(Shared:WaitForChild("Config"):WaitForChild("ShipUpgradeConfig"))
local BoatCatalog = require(Shared:WaitForChild("Config"):WaitForChild("BoatCatalog"))
local FtueConfig = require(Shared:WaitForChild("Config"):WaitForChild("FtueConfig"))
local QualityConfig = require(Shared:WaitForChild("Config"):WaitForChild("QualityConfig"))
local StraitEventCatalog = require(Shared:WaitForChild("Config"):WaitForChild("StraitEvents"):WaitForChild("Catalog"))
local ManifestIncidentTitle = require(Shared:WaitForChild("Config"):WaitForChild("StraitEvents"):WaitForChild("ManifestIncidentTitle"))
local StraitEventConfig = require(Shared:WaitForChild("Config"):WaitForChild("StraitEventConfig"))
local HitContractConfig = require(Shared:WaitForChild("Config"):WaitForChild("HitContractConfig"))
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))
local ParticleFxScale = require(Shared:WaitForChild("ParticleFxScale"))
local ShipRig = require(Shared:WaitForChild("Utils"):WaitForChild("ShipRig"))
local CharacterTeleport = require(script.Parent.Parent.Utils.CharacterTeleport)
local BarrelStacking = require(script.Parent.Parent.Utils.BarrelStacking)
local BoatCollisionContract = require(script.Parent.Parent.Utils.BoatCollisionContract)
local DevLog = require(Shared:WaitForChild("DevLog"))
local Telemetry = require(Shared:WaitForChild("Telemetry"))

local ServerStorage = game:GetService("ServerStorage")

local function removeHeavenAccessories(character: Model)
	for _, child in ipairs(character:GetChildren()) do
		if child:IsA("Accessory") and child:GetAttribute("HeavenAccessory") == true then
			child:Destroy()
		end
	end
end

local OilShipmentService = {}

-- Per-server, UserId-keyed flags for "first per server lifetime" funnel
-- gating. `Telemetry.SetSession`/`SessionGet` were not shipped in PR 3, so
-- each owner service tracks its own first-* sentinel locally; on rejoin to
-- the same server we won't double-fire, which is the desired idempotency.
local _firstDispatchedByUserId: { [number]: boolean } = {}
local _firstDeliveredByUserId: { [number]: boolean } = {}
-- Player-hired pirate contract loss fraction. Sourced from `HitContractConfig`
-- so the broker pitch label on the client and the server math here can never
-- drift. Random PirateRaid strait events use a separate per-event fraction in
-- `StraitEvents/Catalog.luau` (currently `looseBarrelLossFraction = 0.25`).
local FORCED_CONTRACT_PIRATE_LOSS_FRACTION = HitContractConfig.StealRatio

local TIER_ORDER = {
	"Premium",
	"Refined",
	"Crude",
}

-- Barrels lost to spillage: take from cheaper tiers first.
local BARREL_LOSS_TIER_ORDER = {
	"Crude",
	"Refined",
	"Premium",
}

--- HUD / manifest snapshot tier key order (matches `ActiveManifestPanel` loaded rows).
local MANIFEST_HUD_TIER_ORDER = {
	"Crude",
	"Refined",
	"Premium",
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

--- Smallest squared horizontal distance from `spawnWorld` to any waypoint
--- on the lane polyline (`lane.positions`). Used at dispatch so, among
--- lanes tied on `_laneVoyageCounts`, we prefer the route geometry closest
--- to the boat's dock slot — cuts down on long diagonal cuts across pier
--- / marina volume before the hull merges onto the authored lane.
local function laneSpawnDistanceSqXZ(spawnWorld: Vector3, lane: any): number
	local positions = lane and (lane :: any).positions
	if typeof(positions) ~= "table" then
		return math.huge
	end
	local best = math.huge
	local sx, sz = spawnWorld.X, spawnWorld.Z
	for _, p in ipairs(positions) do
		if typeof(p) == "Vector3" then
			local dx = p.X - sx
			local dz = p.Z - sz
			local d = dx * dx + dz * dz
			if d < best then
				best = d
			end
		end
	end
	return best
end

--- Option A (carrot): max arc length the lead target may sit ahead of measured hull progress.
--- `RouteProgress01`: max of bow FRONT_MARKER and commanded `s_lead` point vs finish (XZ),
--- `1 - dist(pos, finish) / dist(dock, finish)`, monotonic. Strait logic still uses `s_hull`.
local VOYAGE_MAX_LEAD_STUDS = 55
--- Hull arc length within this of path end counts as arrived.
local VOYAGE_COMPLETE_ARC_EPS_STUDS = 12
--- If wall-clock exceeds `travelSeconds * this`, stuck failsafe may snap to finish.
local VOYAGE_FAILSAFE_MAX_WALL_MULT = 2.15
--- If hull arc gains less than `VOYAGE_FAILSAFE_STUCK_PROGRESS_STUDS` in this many seconds, snap.
local VOYAGE_FAILSAFE_STUCK_SECONDS = 22
local VOYAGE_FAILSAFE_STUCK_PROGRESS_STUDS = 2.5

--- Closest point on polyline to `p`; returns arc length from `path[1]` along the path.
local function projectWorldPosToArcLength(path: { Vector3 }, segDists: { number }, p: Vector3): number
	if #path < 2 then
		return 0
	end
	local bestS = 0
	local bestD2 = math.huge
	for i = 2, #path do
		local a = path[i - 1]
		local b = path[i]
		local ab = b - a
		local lab2 = ab:Dot(ab)
		local t = if lab2 > 1e-9 then math.clamp((p - a):Dot(ab) / lab2, 0, 1) else 0
		local closest = a + ab * t
		local d2 = (p - closest).Magnitude ^ 2
		local s = segDists[i - 1] + (closest - a).Magnitude
		if d2 < bestD2 then
			bestD2 = d2
			bestS = s
		end
	end
	return math.clamp(bestS, 0, segDists[#path])
end

--- Point and horizontal travel direction at arc length `dist` along the polyline.
local function positionAndTangentAtArcLength(path: { Vector3 }, segDists: { number }, dist: number): (Vector3, Vector3)
	local maxD = segDists[#path]
	dist = math.clamp(dist, 0, maxD)
	for i = 2, #path do
		if segDists[i] >= dist then
			local segLen = segDists[i] - segDists[i - 1]
			local segAlpha = if segLen > 1e-6 then (dist - segDists[i - 1]) / segLen else 0
			local segStart = path[i - 1]
			local segEnd = path[i]
			local pos = segStart:Lerp(segEnd, segAlpha)
			local flat = Vector3.new(segEnd.X - segStart.X, 0, segEnd.Z - segStart.Z)
			if flat.Magnitude < 1e-3 then
				return pos, Vector3.new(0, 0, -1)
			end
			return pos, flat.Unit
		end
	end
	local last = #path
	if last >= 2 then
		local seg = path[last] - path[last - 1]
		local flat = Vector3.new(seg.X, 0, seg.Z)
		if flat.Magnitude < 1e-3 then
			return path[last], Vector3.new(0, 0, -1)
		end
		return path[last], flat.Unit
	end
	return path[1], Vector3.new(0, 0, -1)
end

local function getBoatPathSampleWorldPosition(boat: Model): Vector3
	local wl = boat:FindFirstChild("WaterlineAnchor", true)
	if wl and wl:IsA("BasePart") then
		-- Sanity check: if WaterlineAnchor is more than 20 studs from the
		-- model pivot it's likely not welded to the assembly and stuck at
		-- the dock spawn position. Fall through to pivot in that case so
		-- the hull projection stays in sync with the actual boat position.
		local pivotPos = boat:GetPivot().Position
		local wlDist = (wl.Position - pivotPos).Magnitude
		if wlDist < 20 then
			return wl.Position
		end
	end
	return boat:GetPivot().Position
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
			return BoatCatalog.GetRigForTemplate(templateName)
		end
		local boatId = boat:GetAttribute("BoatId")
		if typeof(boatId) == "string" and boatId ~= "" then
			return BoatCatalog.GetRigForBoat(boatId)
		end
	end
	return BoatCatalog.GetRigForTemplate("Tanker")
end

local function findBoatSeat(boat: Instance): Seat?
	if not boat:IsA("Model") then
		return nil
	end
	local rig = resolveRigForBoatInstance(boat)
	return ShipRig.FindSeat(boat, rig.deckSeatName) or ShipRig.FindSeat(boat, "DeckSeat")
end

-- Helper-part detection (FRONT_MARKER, WaterlineAnchor, etc., plus the
-- transparency fallback — see `BoatCollisionContract`) lives in that module so
-- the voyage hull and the dock-spawner agree on what counts as a "helper".

local function findBarrelStackRoot(boat: Instance): BasePart?
	if not boat:IsA("Model") then
		return nil
	end
	local rig = resolveRigForBoatInstance(boat)
	return ShipRig.FindBasePart(boat, rig.barrelStackRootName) or ShipRig.FindBasePart(boat, "BarrelStackRoot")
end

local function resolveShipBarrelStackBaseCf(boat: Instance, stackRoot: BasePart): CFrame
	local origin = stackRoot.Position + Vector3.new(0, 12, 0)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	local include = {}
	if boat:IsA("Model") then
		for _, d in ipairs(boat:GetDescendants()) do
			if d:IsA("BasePart") and d ~= stackRoot then
				table.insert(include, d)
			end
		end
	end
	params.FilterDescendantsInstances = include
	params.IgnoreWater = true
	local result = if #include > 0
		then Workspace:Raycast(origin, Vector3.new(0, -48, 0), params)
		else nil
	local basePos = if result then result.Position else (stackRoot.Position - Vector3.new(0, stackRoot.Size.Y * 0.5, 0))
	return CFrame.new(basePos) * stackRoot.CFrame.Rotation
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

local function getDeckBarrelWorldPosition(inst: Instance): Vector3?
	local function getMotionPart(target: Instance): BasePart?
		if target:IsA("BasePart") then
			return target
		end
		if target:IsA("Model") then
			if target.PrimaryPart then
				return target.PrimaryPart
			end
			for _, d in ipairs(target:GetDescendants()) do
				if d:IsA("BasePart") then
					return d
				end
			end
		end
		return nil
	end

	local motionPart = getMotionPart(inst)
	if motionPart then
		return motionPart.Position
	end
	if inst:IsA("Model") then
		return inst:GetPivot().Position
	end
	if inst:IsA("BasePart") then
		return inst.Position
	end
	return nil
end

local function getDeckBarrelWorldCFrame(inst: Instance): CFrame?
	local function getMotionPart(target: Instance): BasePart?
		if target:IsA("BasePart") then
			return target
		end
		if target:IsA("Model") then
			if target.PrimaryPart then
				return target.PrimaryPart
			end
			for _, d in ipairs(target:GetDescendants()) do
				if d:IsA("BasePart") then
					return d
				end
			end
		end
		return nil
	end

	local motionPart = getMotionPart(inst)
	if motionPart then
		return motionPart.CFrame
	end
	if inst:IsA("Model") then
		return inst:GetPivot()
	end
	if inst:IsA("BasePart") then
		return inst.CFrame
	end
	return nil
end

local function serializeVector3(v: Vector3): { [string]: number }
	return {
		x = v.X,
		y = v.Y,
		z = v.Z,
	}
end

local function serializeCFrame(cf: CFrame): { number }
	return { cf:GetComponents() }
end

local function collectDeckBarrelRoots(boat: Instance): { Instance }
	local barrels = {}
	for _, d in ipairs(boat:GetDescendants()) do
		if d.Name == "DeckBarrel" and (d:IsA("Model") or d:IsA("BasePart")) and d.Parent then
			table.insert(barrels, d)
		end
	end
	table.sort(barrels, function(a, b)
		local ap = getDeckBarrelWorldPosition(a) or Vector3.zero
		local bp = getDeckBarrelWorldPosition(b) or Vector3.zero
		return ap.Y > bp.Y
	end)
	return barrels
end

local function snapshotDeckBarrelVisual(inst: Instance): { [string]: any }?
	local position = getDeckBarrelWorldPosition(inst)
	local cf = getDeckBarrelWorldCFrame(inst)
	if not position or not cf then
		return nil
	end
	local tierAttr = inst:GetAttribute("OilTier")
	local templateAttr = inst:GetAttribute("TemplateName")
	return {
		position = serializeVector3(position),
		cframe = serializeCFrame(cf),
		tier = if typeof(tierAttr) == "string" then tierAttr else nil,
		templateName = if typeof(templateAttr) == "string" then templateAttr else nil,
	}
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
	self._laneVoyageCounts = {} :: { number }

	local assetsFolder = ReplicatedStorage:FindFirstChild("Assets")
	self._boatTemplate = assetsFolder and assetsFolder:FindFirstChild("Tanker") or nil
	self._activeShips = {} -- per-ship runtime state keyed by shipmentId
	self._activeShipmentByOwner = {} :: { [number]: string }
	self._shipmentContexts = {} :: { [string]: { [string]: any } }
	self._hitContractService = nil
	self._ftueService = nil :: any
	self._leaderboardService = nil :: any

	-- Collision: `ShipmentShip` hull (see `_setupShip`) ignores other ships and `MarinaDock` pier geometry
	-- (registered/tagged in `BoatDockService:Init`); still collides with `Default` so players walk decks.
	local ok, _ = pcall(function()
		PhysicsService:RegisterCollisionGroup("ShipmentShip")
	end)
	if ok then
		pcall(function()
			PhysicsService:CollisionGroupSetCollidable("ShipmentShip", "ShipmentShip", false)
		end)
	end

	-- Cosmetic strait-event NPCs (Coast Guard / Pirate ships + officers / pirates spawned on the
	-- client by `StraitWaypointWorldFx`) MUST NOT collide with the player or anything else. They
	-- are visual props animated via `PivotTo`; any residual `CanCollide=true` on body parts would
	-- physics-eject the player from the NPC's volume each step (observed: HRP being shoved
	-- ~20 studs/s toward officers parked in inspection zones, even with per-frame `CanCollide=false`
	-- sweeps, because the engine has at least one contact frame per Heartbeat to apply the eject).
	--
	-- IMPORTANT: `PhysicsService:RegisterCollisionGroup` and `:CollisionGroupSetCollidable` are
	-- SERVER-only writes — they silently no-op on the client. Registering here from the server
	-- causes Roblox to replicate the group + collidable matrix to every client, so when the
	-- StraitWaypointWorldFx client code tags cloned NPC parts with this group, the engine
	-- enforces the no-collide rule regardless of `CanCollide` state.
	local STRAIT_FX_NPC_GROUP = "StraitWaypointFxNpc"
	local function safeRegister(name: string)
		pcall(function()
			PhysicsService:RegisterCollisionGroup(name)
		end)
	end
	-- Idempotent registers: BoatDockService may not have initialized yet, but
	-- `CollisionGroupSetCollidable` requires both groups to exist.
	safeRegister(STRAIT_FX_NPC_GROUP)
	safeRegister("ShipmentShip")
	safeRegister("MarinaDock")
	safeRegister("MapDecor")
	safeRegister(BoatCollisionContract.IdleGroup)
	-- Voyage hull + deck cargo (`ShipmentShip`) must ignore pier and strait
	-- decor the same way. `BoatDockService:Init` also sets these pairs; repeat
	-- here so unit tests / alternate init order cannot leave barrels on
	-- `Default` colliding with untagged geometry before the dock service runs.
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable("ShipmentShip", "MarinaDock", false)
	end)
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable("ShipmentShip", "MapDecor", false)
	end)
	local function noCollidePair(other: string)
		pcall(function()
			PhysicsService:CollisionGroupSetCollidable(STRAIT_FX_NPC_GROUP, other, false)
		end)
	end
	noCollidePair("Default")
	noCollidePair("Players")
	noCollidePair("ShipmentShip")
	noCollidePair(BoatCollisionContract.IdleGroup)
	noCollidePair("MarinaDock")
	noCollidePair("MapDecor")
	noCollidePair(STRAIT_FX_NPC_GROUP)

	-- Owner character collision group while on a voyage. Group name is
	-- legacy ("PlayerInStraitEvent") — it originally only covered the
	-- strait-event freeze cinematic to defend against residual pushes
	-- from cosmetic NPC ships / officers / pirates whose own group tagging
	-- on the client could race or fail. The same isolation now applies for
	-- the **entire voyage** (apply at dispatch in `_runShipment` after
	-- `TeleportOwnerToSeat`, restore at completion / total loss): the
	-- product rule is "while sailing, the player should only collide with
	-- the boat deck they're standing on (and other players' decks they
	-- might board) — never with docks, MapDecor props, parked boats, or
	-- cosmetic NPCs the engine spawns into the lane".
	--
	-- IMPORTANT: server-side writes to `BasePart.CollisionGroup` are
	-- authoritative and replicate to every client, so the no-collide
	-- rules below are enforced at the engine level regardless of whether
	-- the cosmetic-NPC parts are correctly tagged on the client.
	local PLAYER_IN_STRAIT_EVENT_GROUP = "PlayerInStraitEvent"
	safeRegister(PLAYER_IN_STRAIT_EVENT_GROUP)
	-- Cosmetic strait-event NPCs (Coast Guard officers, pirate ships, etc.)
	-- never push the voyaging player.
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(PLAYER_IN_STRAIT_EVENT_GROUP, STRAIT_FX_NPC_GROUP, false)
	end)
	-- Parked / docked boats: voyaging players walk THROUGH them. Without
	-- this, a returning voyage that anchors near a parked hull would shove
	-- the player off the deck. `BoatDockService:Init` also writes this
	-- pair (via `applyIdleBoatCollisionRules`); we re-assert here in case
	-- this Init runs before BoatDockService and `PLAYER_IN_STRAIT_EVENT_GROUP`
	-- wasn't yet registered when that earlier write happened.
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(PLAYER_IN_STRAIT_EVENT_GROUP, BoatCollisionContract.IdleGroup, false)
	end)
	-- Pier geometry (`MarinaDock`): the voyaging player must never clip on
	-- the dock that the ship sails past on departure / docks against on
	-- return. Static dock collision while on the deck would yank the
	-- character off the moving hull; while waiting at dispatch / dock
	-- approach the dock collider catching the character heel-first would
	-- knock them off the boat into the water.
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(PLAYER_IN_STRAIT_EVENT_GROUP, "MarinaDock", false)
	end)
	-- Map decor (`MapDecor`): buoys, lane markers, ambient world props
	-- in the strait route. The hull already ignores them
	-- (`ShipmentShip ↔ MapDecor = false`); the voyaging player must too,
	-- otherwise a low-floating decor part that brushes the deck would
	-- punt them.
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(PLAYER_IN_STRAIT_EVENT_GROUP, "MapDecor", false)
	end)
	self._playerInStraitEventGroup = PLAYER_IN_STRAIT_EVENT_GROUP

	-- Per-userId map of `CharacterAdded` connections wired up while a
	-- voyage is active. Currently only used as a defensive cleanup hook
	-- (we do NOT auto-reapply the voyage group on respawn — a player who
	-- dies mid-voyage typically respawns at warehouse / plot, where the
	-- `Default` group is correct). See `_applyOwnerOnVoyageCollisionGroup`.
	self._voyageCharRespawnConnByUserId = {} :: { [number]: RBXScriptConnection? }

	-- Verification: confirm registration + the critical no-collide pair so
	-- we can tell from a log whether the engine has the rule before any
	-- strait event fires. `pcall` because some Studio reload paths can race.
	pcall(function()
		local fxRegistered = PhysicsService:IsCollisionGroupRegistered(STRAIT_FX_NPC_GROUP)
		local pieRegistered = PhysicsService:IsCollisionGroupRegistered(PLAYER_IN_STRAIT_EVENT_GROUP)
		local idleRegistered = PhysicsService:IsCollisionGroupRegistered(BoatCollisionContract.IdleGroup)
		local fxVsDefault = PhysicsService:CollisionGroupsAreCollidable(STRAIT_FX_NPC_GROUP, "Default")
		local pieVsFx = PhysicsService:CollisionGroupsAreCollidable(PLAYER_IN_STRAIT_EVENT_GROUP, STRAIT_FX_NPC_GROUP)
		local pieVsMarinaDock = PhysicsService:CollisionGroupsAreCollidable(PLAYER_IN_STRAIT_EVENT_GROUP, "MarinaDock")
		local pieVsMapDecor = PhysicsService:CollisionGroupsAreCollidable(PLAYER_IN_STRAIT_EVENT_GROUP, "MapDecor")
		local pieVsShipmentShip = PhysicsService:CollisionGroupsAreCollidable(PLAYER_IN_STRAIT_EVENT_GROUP, "ShipmentShip")
		local idleVsDefault = PhysicsService:CollisionGroupsAreCollidable(BoatCollisionContract.IdleGroup, "Default")
		local idleVsShipmentShip = PhysicsService:CollisionGroupsAreCollidable(BoatCollisionContract.IdleGroup, "ShipmentShip")
		local shipVsShip = PhysicsService:CollisionGroupsAreCollidable("ShipmentShip", "ShipmentShip")
		if RunService:IsStudio() then
			print(string.format(
				"[OilShipmentService] CollisionGroups: %s registered=%s, %s registered=%s, %s registered=%s, fxVsDefault collidable=%s, pieVsFx collidable=%s, pieVsMarinaDock collidable=%s, pieVsMapDecor collidable=%s, pieVsShipmentShip collidable=%s, idleVsDefault collidable=%s, idleVsShipmentShip collidable=%s, shipVsShip collidable=%s",
				STRAIT_FX_NPC_GROUP, tostring(fxRegistered),
				PLAYER_IN_STRAIT_EVENT_GROUP, tostring(pieRegistered),
				BoatCollisionContract.IdleGroup, tostring(idleRegistered),
				tostring(fxVsDefault), tostring(pieVsFx),
				tostring(pieVsMarinaDock), tostring(pieVsMapDecor),
				tostring(pieVsShipmentShip),
				tostring(idleVsDefault), tostring(idleVsShipmentShip),
				tostring(shipVsShip)
			))
		end
	end)

	-- Discover strait lane waypoints
	self:_discoverLanes()
end

function OilShipmentService:SetHitContractService(hitContractService)
	self._hitContractService = hitContractService
end

function OilShipmentService:SetFtueService(ftueService: any)
	self._ftueService = ftueService
end

function OilShipmentService:SetLeaderboardService(leaderboardService: any)
	self._leaderboardService = leaderboardService
end

--- Inject the run-upgrade service that owns "Security Personnel" inventory.
--- Setter (not constructor arg) so older tests / call sites that don't know
--- about run-upgrades still load. When unset, `_handleDispatch` simply skips
--- the consume step and shipments roll events as usual.
function OilShipmentService:SetSecurityPersonnelService(securityPersonnelService: any)
	self._securityPersonnelService = securityPersonnelService
end

--- Inject `CargoHaulerService` so `_handleDispatch` can call
--- `:TryConsumeForDispatch(userId)` and apply the barrel-doubling multiplier
--- when the player ticked the Cargo Hauler toggle on this dispatch. Wired
--- from `init.server.luau` after both services exist; until then the
--- service is `nil` and the hook is a no-op (the shipment dispatches with
--- the player's selected manifest unchanged).
function OilShipmentService:SetCargoHaulerService(cargoHaulerService: any)
	self._cargoHaulerService = cargoHaulerService
end

function OilShipmentService:SetAutoShipService(autoShipService: any)
	self._autoShipService = autoShipService
end

--- Set by `init.server` after `GlobalEventService` is constructed. Optional
--- — without it `_handleDispatch` skips the Express Convoy stat boost and
--- `_handleStraitWaypointTrigger` skips any `ForceStraitEvent` override
--- (effective behavior is "no global events", same as the rotation being idle).
---
--- Two hook sites depend on this:
---   * `_handleDispatch` reads `GetShipStatsBoost()` AFTER `ShipStats.Resolve`
---     so the boost layers on top of the player's upgrade levels (a maxed
---     ship gets +50% capacity, not "reset to L1 then boost"). The
---     resulting `travelSeconds` is clamped against the maxed-stats
---     minimum to avoid pathological 0-second voyages from a future
---     misconfigured `speedMul`.
---   * `_handleStraitWaypointTrigger` reads `GetForcedStraitEventId()`
---     AFTER the eventImmunity (Security Personnel) and FTUE-suppress
---     short-circuits, AND after the bracket allow-list / occurrence
---     roll — so a force only replaces the *event picked*, not
---     *whether* an event fires. Players who own Security Personnel still
---     get full deflection.
function OilShipmentService:SetGlobalEventService(globalEventService: any)
	self._globalEventService = globalEventService
end

function OilShipmentService:SetOilHeavenPlotService(oilHeavenPlotService: any)
	self._oilHeavenPlotService = oilHeavenPlotService
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
		self._laneVoyageCounts = {}
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

	self._laneVoyageCounts = {}
	-- Per-lane "last reserved" wall clock, used as the primary tie-break
	-- among lanes with equal `_laneVoyageCounts`. Stamped in
	-- `_reserveLaneSlot`. Initialized to 0 so on a fresh server every
	-- lane is equally "stale" (and the secondary RNG tie-break in
	-- `_pickLaneLeastLoaded` decides). See picker doc-comment for tie-break
	-- order (load → spawn proximity → LRU → RNG).
	self._laneLastReservedClock = {} :: { [number]: number }
	for i = 1, #self._lanes do
		self._laneVoyageCounts[i] = 0
		self._laneLastReservedClock[i] = 0
	end

	if RunService:IsStudio() then
		print(string.format("[OilShipmentService] Discovered %d lanes", #self._lanes))
	end
end

--- Pick the lane to assign this voyage to.
---
--- Priority order (strict — never skip an earlier criterion for a later one):
---   1. **Smallest `_laneVoyageCounts`** — fewest active voyages on the lane.
---      With N lanes and ≤ N concurrent voyages this still guarantees one
---      voyage per lane when possible.
---   2. **Closest route to spawn** — when `spawnWorld` is provided (boat
---      pivot at the dock slot when checkout completes), smallest horizontal
---      (XZ) distance from that point to **any** waypoint on the lane
---      polyline. Reduces long diagonal cuts across docks / piers before the
---      hull joins the authored strait route.
---   3. **Smallest `_laneLastReservedClock`** — least-recently reserved among
---      remaining ties (round-robin spread when counts and distance tie).
---   4. **Seeded RNG** — final tie-break (`serverTime*1000 + ownerUserId` at
---      the call site) so boot-time ties don't always pick lane 1.
---
--- When `spawnWorld` is `nil`, step 2 is skipped (LRU then RNG among min-count
--- lanes only) for backwards-compatible tests.
---
--- Returns the lane table + 1-based index, or `nil, nil` when no lanes
--- were discovered (caller falls back to a straight-line voyage).
function OilShipmentService:_pickLaneLeastLoaded(seed: number, spawnWorld: Vector3?): (any, number?)
	if #self._lanes == 0 then
		return nil, nil
	end
	local counts = self._laneVoyageCounts
	local lastReserved = self._laneLastReservedClock or {}

	local minCount = math.huge
	for i = 1, #self._lanes do
		local c = if counts[i] ~= nil then counts[i] :: number else 0
		if c < minCount then
			minCount = c
		end
	end

	local afterCount: { number } = {}
	for i = 1, #self._lanes do
		local c = if counts[i] ~= nil then counts[i] :: number else 0
		if c == minCount then
			table.insert(afterCount, i)
		end
	end

	local narrowed = afterCount
	if spawnWorld then
		local minDistSq = math.huge
		for _, i in ipairs(afterCount) do
			local d = laneSpawnDistanceSqXZ(spawnWorld, self._lanes[i])
			if d < minDistSq then
				minDistSq = d
			end
		end
		local DIST_EPS_SQ = 1e-2 -- ~0.1 stud XZ — float noise on identical routes
		local afterDist: { number } = {}
		for _, i in ipairs(afterCount) do
			if laneSpawnDistanceSqXZ(spawnWorld, self._lanes[i]) <= minDistSq + DIST_EPS_SQ then
				table.insert(afterDist, i)
			end
		end
		narrowed = afterDist
	end

	local minClock = math.huge
	for _, i in ipairs(narrowed) do
		local clk = if lastReserved[i] ~= nil then lastReserved[i] :: number else 0
		if clk < minClock then
			minClock = clk
		end
	end
	local candidates: { number } = {}
	for _, i in ipairs(narrowed) do
		local clk = if lastReserved[i] ~= nil then lastReserved[i] :: number else 0
		if clk == minClock then
			table.insert(candidates, i)
		end
	end

	local pickIdx: number
	if #candidates == 1 then
		pickIdx = candidates[1]
	else
		local rng = Random.new(seed)
		pickIdx = candidates[rng:NextInteger(1, #candidates)]
	end
	return self._lanes[pickIdx], pickIdx
end

function OilShipmentService:_reserveLaneSlot(laneIndex: number)
	local n = #self._lanes
	if laneIndex < 1 or laneIndex > n then
		return
	end
	self._laneVoyageCounts[laneIndex] = (self._laneVoyageCounts[laneIndex] or 0) + 1
	-- Stamp the last-reserved clock so the next picker call treats this
	-- lane as "freshly used" and prefers any lane with an older clock
	-- among ties on count. See picker doc-comment.
	if self._laneLastReservedClock then
		self._laneLastReservedClock[laneIndex] = workspace:GetServerTimeNow()
	end
end

function OilShipmentService:_releaseLaneSlotForShipment(shipment: { [string]: any })
	local idxAny = shipment.laneIndex
	if typeof(idxAny) ~= "number" then
		return
	end
	local idx = math.floor(idxAny)
	if idx < 1 or idx > #self._lanes then
		shipment.laneIndex = nil
		return
	end
	local c = (self._laneVoyageCounts[idx] or 0) - 1
	self._laneVoyageCounts[idx] = math.max(0, c)
	shipment.laneIndex = nil
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
	table.insert(self._connections, teleportToShip.OnServerEvent:Connect(function(player, payload)
		self:_handleTeleportToShip(player, payload)
	end))

	local teleportHome = self._remoteService:GetEvent(RemoteNames.RequestTeleportHome)
	table.insert(self._connections, teleportHome.OnServerEvent:Connect(function(player)
		self:_handleTeleportHome(player)
	end))

	local teleportDocks = self._remoteService:GetEvent(RemoteNames.RequestTeleportToDocks)
	table.insert(self._connections, teleportDocks.OnServerEvent:Connect(function(player)
		self:_handleTeleportToDocks(player)
	end))

	local teleportHire = self._remoteService:GetEvent(RemoteNames.RequestTeleportToHire)
	table.insert(self._connections, teleportHire.OnServerEvent:Connect(function(player)
		self:_handleTeleportToHire(player)
	end))

	local teleportOilHeaven = self._remoteService:GetEvent(RemoteNames.RequestTeleportToOilHeaven)
	table.insert(self._connections, teleportOilHeaven.OnServerEvent:Connect(function(player)
		self:_handleTeleportToOilHeaven(player)
	end))

	-- Interactive pirate raid: client reports which pirates were slapped
	local pirateRaidResult = self._remoteService:GetEvent(RemoteNames.PirateRaidInteractiveResult)
	table.insert(self._connections, pirateRaidResult.OnServerEvent:Connect(function(player, payload)
		self:_handlePirateRaidInteractiveResult(player, payload)
	end))

	-- Clean up module-level userId tables on leave
	table.insert(self._connections, Players.PlayerRemoving:Connect(function(player)
		_firstDispatchedByUserId[player.UserId] = nil
		_firstDeliveredByUserId[player.UserId] = nil
	end))
end

function OilShipmentService:_handleTeleportToShip(player: Player, payload: any?)
	if not player.Character then
		warn("[TeleportToShip] No character")
		return
	end
	if not self._boatDockService then
		warn("[TeleportToShip] BoatDockService unavailable")
		return
	end

	-- Spectate another player's active voyage: `{ targetUserId = <uid> }`.
	-- Default / self-target routes to the owner's own ship (idle or sailing).
	local targetUserId: number? = nil
	if typeof(payload) == "table" and typeof(payload.targetUserId) == "number" then
		targetUserId = math.floor(payload.targetUserId)
	end
	if targetUserId == nil or targetUserId == player.UserId then
		local ok, err = self._boatDockService:TeleportOwnerToSeat(player)
		if ok then
			if character then removeHeavenAccessories(character) end
			player:SetAttribute(Constants.CurrentWorldAttribute, Constants.WorldMain)
		else
			self:_sendActionResult(player, false, "ERR_BOAT_UNAVAILABLE", "Your ship is not available right now.", { reason = err })
		end
		return
	end

	local ok, err = self._boatDockService:TeleportSpectatorToBoat(player, targetUserId)
	if ok then
		if character then removeHeavenAccessories(character) end
		player:SetAttribute(Constants.CurrentWorldAttribute, Constants.WorldMain)
	end
	if not ok then
		local msg = "That ship is not available right now."
		if err == "TARGET_NOT_SAILING" then
			msg = "That player isn't sailing right now."
		end
		self:_sendActionResult(player, false, "ERR_BOAT_UNAVAILABLE", msg, { reason = err, targetUserId = targetUserId })
	end
end

local function isHumanoidDead(humanoid: Humanoid?): boolean
	return humanoid == nil
		or humanoid.Health <= 0
		or humanoid:GetState() == Enum.HumanoidStateType.Dead
end

function OilShipmentService:_queueDebugBoardingRetry(player: Player, shipmentId: string, initialDelaySec: number?)
	task.spawn(function()
		if initialDelaySec and initialDelaySec > 0 then
			task.wait(initialDelaySec)
		end

		local startingCharacter = player.Character
		for _ = 1, 20 do
			if not player.Parent then
				return
			end
			if self._activeShipmentByOwner[player.UserId] ~= shipmentId then
				return
			end

			local character = player.Character
			if not character or character ~= startingCharacter then
				return
			end

			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if humanoid and (humanoid.SeatPart or isHumanoidDead(humanoid)) then
				return
			end

			self:_handleTeleportToShip(player)
			task.wait(0.5)
		end
	end)
end

--- Server → one-client camera-snap helper. Called after **every** server-driven teleport
--- that changes the character's facing direction (Home / Town / Hire / Ship / Warehouse,
--- and the voyage post-finish fallbacks). Without this signal the default follow camera
--- keeps its previous yaw because `PivotTo` doesn't re-align it on a live character, so
--- the player ends up staring at the back of their own head. `HudTeleportRouter` consumes
--- `TeleportHomeApplied.OnClientEvent` and runs `snapCameraBehindCharacter(targetCFrame)`.
---
--- Wrapped in a pcall to harden against a missing `Remotes` folder during a fresh
--- server boot (the snap is cosmetic — a missed fire is never gameplay-blocking).
function OilShipmentService:_fireCameraSnap(player: Player, targetCFrame: CFrame)
	if not (self._remoteService and player and player.Parent) then
		return
	end
	pcall(function()
		self._remoteService:GetEvent(RemoteNames.TeleportHomeApplied):FireClient(player, targetCFrame)
	end)
end

function OilShipmentService:_handleTeleportHome(player: Player)
	local character = player.Character
	if not character then return end

	local plot = self._plotService:GetOwnedPlot(player.UserId)
	if not plot then return end
	local claimPad = plot:FindFirstChild("ClaimPad")
	if claimPad and claimPad:IsA("BasePart") then
		--- Use the pad's full CFrame (not just `.Position`) so the character lands facing whichever
		--- way the ClaimPad is authored to face — currently 180° so the player ends up looking at
		--- the Delivery Man. `CFrame + Vector3` translates in world space without touching the
		--- pad's LookVector.
		local targetCFrame = claimPad.CFrame + Vector3.new(0, 5, 0)
		removeHeavenAccessories(character)
		CharacterTeleport.teleportWithUnseat(character, targetCFrame, "RequestTeleportHome")
		player:SetAttribute(Constants.CurrentWorldAttribute, Constants.WorldMain)
		self:_fireCameraSnap(player, targetCFrame)
	end
end

function OilShipmentService:_handleTeleportToOilHeaven(player: Player)
	local character = player.Character
	if not character then return end

	local unlocked = player:GetAttribute(Constants.OilHeavenUnlockedAttribute)
	if not unlocked then
		self:_sendActionResult(player, false, "ERR_OIL_HEAVEN_LOCKED", "Oil Heaven is not yet unlocked.")
		return
	end

	if not self._oilHeavenPlotService then
		warn("[OilShipmentService] OilHeavenPlotService not injected")
		return
	end

	local plot = self._oilHeavenPlotService:GetAssignedPlot(player.UserId)
	if not plot then
		self:_sendActionResult(player, false, "ERR_OIL_HEAVEN_NO_PLOT", "No Oil Heaven plot assigned.")
		return
	end

	local spawnCFrame = self._oilHeavenPlotService:GetSpawnCFrame(player.UserId)
	if not spawnCFrame then return end

	CharacterTeleport.teleportWithUnseat(character, spawnCFrame, "RequestTeleportToOilHeaven")
	player:SetAttribute(Constants.CurrentWorldAttribute, Constants.WorldOilHeaven)
	self:_fireCameraSnap(player, spawnCFrame)

	-- Equip angel wings + halo
	local humanoid = character:FindFirstChildWhichIsA("Humanoid")
	local accessoryFolder = ServerStorage:FindFirstChild("HeavenAccessories")
	if humanoid and accessoryFolder then
		for _, acc in ipairs(accessoryFolder:GetChildren()) do
			if acc:IsA("Accessory") then
				local clone = acc:Clone()
				clone:SetAttribute("HeavenAccessory", true)
				humanoid:AddAccessory(clone)
			end
		end
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

	local function notifyFtueIfTownLeg()
		if not (self._ftueService and FtueConfig.Enabled and self._oilStateService) then
			return
		end
		local st = self._oilStateService:GetState(player.UserId)
		if st and (st :: any).ftueStep == FtueConfig.Step.WaitDocksShipUpgrade then
			(self._ftueService :: any):OnFtueDocksTownTeleportSuccess(player)
		end
	end

	local cf = getDocksTeleportCFrame()
	if cf then
		-- Face away from the authored forward (e.g. into the shop) — 180° yaw in target-local space.
		local targetCFrame = cf * CFrame.Angles(0, math.pi, 0)
		removeHeavenAccessories(character)
		CharacterTeleport.teleportWithUnseat(character, targetCFrame, "RequestTeleportToDocks")
		player:SetAttribute(Constants.CurrentWorldAttribute, Constants.WorldMain)
		notifyFtueIfTownLeg()
		self:_fireCameraSnap(player, targetCFrame)
		return
	end

	local plot = self._plotService:GetOwnedPlot(player.UserId)
	if not plot then
		return
	end
	local boatSpawn = plot:FindFirstChild("BoatSpawn")
	if boatSpawn and boatSpawn:IsA("BasePart") then
		--- Preserve the `BoatSpawn` rotation (was discarded by `CFrame.new(<position>)` —
		--- same bug shape as the Home teleport). Use `CFrame.Rotation + Vector3` so the
		--- LookVector is whatever the pad is authored to face, then lift Y.
		local targetCFrame = boatSpawn.CFrame.Rotation + (boatSpawn.Position + Vector3.new(0, 5, 0))
		removeHeavenAccessories(character)
		CharacterTeleport.teleportWithUnseat(character, targetCFrame, "RequestTeleportToDocks:fallback")
		player:SetAttribute(Constants.CurrentWorldAttribute, Constants.WorldMain)
		notifyFtueIfTownLeg()
		self:_fireCameraSnap(player, targetCFrame)
	end
end

--- `Workspace.HireTeleportTarget`: Attachment / BasePart / Model pivot. No fallback —
--- if the authored target is missing we drop the request rather than dumping the player on
--- their plot, since "Hire" is a deliberately authored destination.
local function getHireTeleportCFrame(): CFrame?
	local target = Workspace:FindFirstChild("HireTeleportTarget", true)
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

function OilShipmentService:_handleTeleportToHire(player: Player)
	local character = player.Character
	if not character then
		return
	end
	local cf = getHireTeleportCFrame()
	if not cf then
		warn("[TeleportToHire] Workspace.HireTeleportTarget not found.")
		return
	end
	-- Face away from the authored forward (180° yaw in target-local space) — the Hire NPC
	-- is in front of the authored target, so flipping puts the player nose-to-nose with them.
	local targetCFrame = cf * CFrame.Angles(0, math.pi, 0)
	removeHeavenAccessories(character)
	CharacterTeleport.teleportWithUnseat(character, targetCFrame, "RequestTeleportToHire")
	player:SetAttribute(Constants.CurrentWorldAttribute, Constants.WorldMain)
	self:_fireCameraSnap(player, targetCFrame)
end

function OilShipmentService:Stop()
	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	self._connections = {}
	self._activeShipmentByOwner = {}
	self._shipmentContexts = {}
end

--- Per-rebirth cancellation entry point. Drops the user's active shipment
--- (if any) from `_activeShipmentByOwner` / `_shipmentContexts` /
--- `_activeShips` so any in-flight `task.delay` callbacks find no entry on
--- wake-up and short-circuit (every read site already nil-checks). The
--- player's wiped state has `activeShipmentCount = 0` so the HUD reflects
--- the cancellation immediately. Lane reservations for cancelled shipments
--- are not explicitly released — they expire on the lane TTL and don't
--- block other players. The visible boat model in workspace lingers until
--- its own movement task finishes; cosmetic only, no payload delivery.
function OilShipmentService:CancelShipmentsForUser(userId: number)
	local shipmentId = self._activeShipmentByOwner[userId]
	if not shipmentId then
		return
	end
	self._activeShipmentByOwner[userId] = nil
	self._shipmentContexts[shipmentId] = nil
	self._activeShips[shipmentId] = nil
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

function OilShipmentService:GetBoatCatalogForClient()
	return BoatCatalog.ListForClient()
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

	local boatId = (typeof(state.equippedBoatId) == "string" and BoatCatalog.Boats[state.equippedBoatId] and state.equippedBoatId)
		or "Tier1Boat"
	-- Boat progression refactor (Step 2/4): stats are derived from the
	-- equipped boat's catalog entry. The legacy per-player
	-- `shipSpeedLevel` / `shipCapacityLevel` profile fields and the
	-- `TryUpgradeShipSpeed` / `TryUpgradeShipCapacity` paths were
	-- deleted by Step 4. `speedL` / `capL` extracted here mirror the
	-- boat-baked levels so the shipment payload, telemetry, and
	-- downstream FX have a single coherent source of truth.
	local speedL, capL = ShipStats.LevelsForBoat(boatId)
	local stats = ShipStats.Resolve(speedL, capL)
	-- Apply server-wide global event boosts (Express Convoy, future events).
	-- Layered AFTER stat resolution so the boost composes with the player's
	-- equipped boat (e.g. a maxed boat + Express Convoy = ~150% capacity of
	-- the boat's max, half travel time). Clamp `travelSeconds` to a fraction
	-- of the theoretically fastest voyage so a future misconfigured
	-- `speedMul` (e.g. 100) can't produce a 0.1s voyage that breaks lane
	-- traversal animation. The clamp uses `MaxSpeedLevel` directly because
	-- it represents a global hypothetical floor, not the equipped boat's
	-- specific stats.
	if self._globalEventService then
		local boost = self._globalEventService:GetShipStatsBoost()
		if boost then
			local speedMul = tonumber(boost.speedMul) or 1
			local capacityMul = tonumber(boost.capacityMul) or 1
			if speedMul > 0 and speedMul ~= 1 then
				local minTravel = ShipStats.Resolve(ShipUpgradeConfig.MaxSpeedLevel, ShipUpgradeConfig.MaxCapacityLevel).travelSeconds * 0.4
				stats.travelSeconds = math.max(minTravel, stats.travelSeconds / speedMul)
			end
			if capacityMul > 0 and capacityMul ~= 1 then
				stats.capacity = math.floor(stats.capacity * capacityMul + 0.5)
			end
		end
	end
	if self._oilStateService then
		local heavenBonuses = self._oilStateService:GetOilHeavenBonusTotals(player.UserId)
		local shipSpeedPct = heavenBonuses.shipSpeedPct or 0
		if shipSpeedPct > 0 then
			stats.travelSeconds = math.max(1, stats.travelSeconds / (1 + (shipSpeedPct / 100)))
		end
	end
	local travelSeconds = stats.travelSeconds
	local tutorialEscort = false
	local ftueStepNow = (state :: any).ftueStep
	if
		FtueConfig.Enabled == true
		and (state.ftueEscortShipmentRemaining or 0) > 0
		and ftueStepNow == FtueConfig.Step.WaitPlotShipment
	then
		tutorialEscort = true
		-- Tutorial escort: project the boat to `MaxSpeedLevel` (its natural
		-- top-tier travel time, currently `30 s`) and divide by **4** so
		-- the new player crosses the strait at **4× the max-tier speed**
		-- (~7.5 s base voyage). The `_runShipment` failsafe used to
		-- force-warp the boat to the warehouse mid-strait at high speeds;
		-- the matching guard below
		-- (`if isTutorialEscort then hardWall = false; stuckNoMove = false`)
		-- now hard-disables both wall checks for tutorial dispatches, so
		-- the failsafe can never force-warp the protected voyage. The
		-- showcase event pauses (Coast Guard freeze, Mines barrage) still
		-- play their full duration since they're fired by lane waypoint
		-- and `task.wait`/`voyageClock` shifts inside each helper.
		-- Capacity level doesn't affect `travelSeconds`, so we pass
		-- `MaxCapacityLevel` purely for symmetry. The hull `MaxVelocity`
		-- override below must scale with this divisor — at 4× carrot
		-- speed (~133 studs/s on a ~1000-stud path) the hull cap has to
		-- be raised in lockstep or the boat just rides the cap.
		local maxStats = ShipStats.Resolve(ShipUpgradeConfig.MaxSpeedLevel, ShipUpgradeConfig.MaxCapacityLevel)
		travelSeconds = maxStats.travelSeconds / 4
		local tutSkin = FtueConfig.FtueTutorialShipmentSkinId
		if typeof(tutSkin) == "string" and BoatCatalog.Boats[tutSkin] then
			boatId = tutSkin
			-- Refresh `speedL` / `capL` to mirror the swapped tutorial
			-- boat so the shipment payload below stays internally
			-- consistent (boat id and recorded levels match).
			speedL, capL = ShipStats.LevelsForBoat(boatId)
		end
		state.ftueEscortShipmentRemaining = 0
		self._oilStateService:_markDirty(player.UserId)
	end

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

	-- Dispatch fee is computed from the player's selected manifest
	-- (`normalizedManifest`) BEFORE the Cargo Hauler block below doubles
	-- `shipment.manifest`. This is intentional: the player only pays the
	-- fee on what they loaded — the Cargo Hauler's grant is "free" extra
	-- barrels added on top, not a tier of selectable cargo. The frozen
	-- fee is stored on `shipment.dispatchFee` and every downstream read
	-- (telemetry, action-result payload, _handleDelivery, recovery
	-- snapshots) uses the stored value rather than recomputing from
	-- the (now-doubled) `shipment.manifest` — so the fee can never
	-- accidentally double when Cargo Hauler is active.
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
		boatId = boatId,
		shipSpeedLevel = speedL,
		shipCapacityLevel = capL,
		manifest = normalizedManifest,
		dispatchManifestOil = dispatchManifestOil,
		totalLoaded = totalRequested,
		dispatchFee = dispatchFee,
		travelSeconds = travelSeconds,
		eventRisk = stats.eventRisk,
		ftueTutorialSuppressStraitIncidents = tutorialEscort,
		--- When the FTUE escort dispatch is active, stamp the configured
		--- showcase table (lane-waypoint → event id) so
		--- `_handleStraitWaypointTrigger` can route the protected voyage's
		--- waypoint triggers into harmless VFX/SFX showcases. `nil` (not
		--- the escort dispatch) keeps the normal "fully suppress" path.
		ftueTutorialShowcasesByLaneWaypoint = if tutorialEscort
			then (FtueConfig.FtueTutorialShowcasesByLaneWaypoint or {}) :: { [number]: string }
			else nil,
	}

	-- Run-upgrade hooks. Security Personnel is opt-in: the client sends
	-- `useSecurityPersonnel = true` in the dispatch payload when the player
	-- explicitly toggled it on. AutoShip always skips (no auto-consume).
	local wantSecurity = typeof(payload) == "table" and payload.useSecurityPersonnel == true
	if wantSecurity and self._securityPersonnelService and self._securityPersonnelService:TryConsumeForDispatch(player.UserId) then
		(shipment :: any).eventImmunity = true
		pcall(function()
			local remaining = 0
			if typeof(self._securityPersonnelService.GetOwnedCount) == "function" then
				remaining = self._securityPersonnelService:GetOwnedCount(player.UserId)
			end
			Telemetry.Track(player, "security_personnel_consumed", {
				shipmentId = shipment.shipmentId,
				remainingOwned = remaining,
			})
		end)
	end

	-- Cargo Hauler: same opt-in shape as Security Personnel — client sends
	-- `useCargoHauler = true` when the player explicitly toggled it on for
	-- this dispatch. On consume, multiply every tier of `shipment.manifest`
	-- AND `shipment.totalLoaded` by the service's multiplier (currently ×2).
	-- The doubled manifest propagates naturally:
	--   * `_handleDelivery` reads `shipment.manifest[tier]` per-tier when
	--     crediting the warehouse → delivery doubles.
	--   * The market payout is computed off the delivered barrels → payout
	--     doubles in lockstep.
	--   * Pirate-steal math is `% of manifest`, so absolute barrels stolen
	--     also doubles. Designed-for: a bigger haul means a juicier target.
	-- `dispatchManifestOil` is left untouched because it's the HUD oil-unit
	-- preview tied to what the player physically loaded (their inventory
	-- only debited 1× — the 2nd × is the Cargo Hauler's grant). Stamping a
	-- `cargoHauled` flag lets downstream code (telemetry, future shipment
	-- review screens) tell a normal voyage from a doubled one.
	local wantCargoHauler = typeof(payload) == "table" and payload.useCargoHauler == true
	if wantCargoHauler and self._cargoHaulerService and self._cargoHaulerService:TryConsumeForDispatch(player.UserId) then
		local mult = 2
		if typeof(self._cargoHaulerService.GetMultiplier) == "function" then
			local m = self._cargoHaulerService:GetMultiplier()
			if typeof(m) == "number" and m > 0 then
				mult = m
			end
		end
		local doubledManifest: { [string]: number } = {}
		for tier, amount in pairs(shipment.manifest) do
			doubledManifest[tier] = (typeof(amount) == "number" and amount or 0) * mult
		end
		shipment.manifest = doubledManifest
		shipment.totalLoaded = shipment.totalLoaded * mult
		;(shipment :: any).cargoHauled = true
		;(shipment :: any).cargoHaulerMultiplier = mult
		pcall(function()
			local remaining = 0
			if typeof(self._cargoHaulerService.GetOwnedCount) == "function" then
				remaining = self._cargoHaulerService:GetOwnedCount(player.UserId)
			end
			Telemetry.Track(player, "cargo_hauler_consumed", {
				shipmentId = shipment.shipmentId,
				multiplier = mult,
				barrelsBefore = totalRequested,
				barrelsAfter = shipment.totalLoaded,
				remainingOwned = remaining,
			})
		end)
	end

	self:_sendActionResult(player, true, "OK", "Shipment dispatched.", {
		shipmentId = shipment.shipmentId,
		boatId = boatId,
		totalLoaded = shipment.totalLoaded,
	})

	-- Wrap telemetry in pcall so a Telemetry bug can never block the
	-- dispatch path (manifest is already consumed, fee already deducted).
	pcall(function()
		Telemetry.Economy(
			player,
			"Sink",
			dispatchFee,
			"cash",
			"dispatch_fee",
			tostring(shipment.shipmentId)
		)
		local autoShipFlag = (typeof(payload) == "table" and payload.autoShip == true) or false
		Telemetry.Track(player, "shipment_dispatched", {
			shipmentId = shipment.shipmentId,
			manifestBarrels = totalRequested,
			manifestByTier = normalizedManifest,
			dispatchFee = dispatchFee,
			shipSpeedLevel = speedL,
			shipCapacityLevel = capL,
			boatId = boatId,
			straitEngineStateAtDispatch = self:_getStraitEngineState(),
			autoShip = autoShipFlag,
			securityPersonnelActive = (shipment :: any).eventImmunity == true,
		})
		if not _firstDispatchedByUserId[player.UserId] then
			_firstDispatchedByUserId[player.UserId] = true
			local secondsSinceJoin: number? = nil
			local session = Telemetry._getSession(player)
			if session then
				secondsSinceJoin = math.floor(os.clock() - session.joinedAtClock)
			end
			Telemetry.Track(player, "shipment_first_dispatched", {
				secondsSinceJoin = secondsSinceJoin,
			})
			Telemetry.Funnel(player, "first_run", 2, "first_dispatch")
		end
	end)

	if self._ftueService and FtueConfig.Enabled then
		local stD = self._oilStateService:GetState(player.UserId)
		if stD and (stD :: any).ftueStep == FtueConfig.Step.WaitPlotShipment then
			(self._ftueService :: any):OnDispatchShipmentSuccess(player.UserId)
		end
	end

	task.spawn(function()
		self:_runShipment(shipment)
	end)
end

--- Server-initiated dispatch for AutoShipService. Uses the exact same
--- validation and voyage code path as client-initiated `_handleDispatch`.
--- Returns true if a shipment was successfully dispatched.
function OilShipmentService:DispatchForAutoShip(player: Player, manifest: { [string]: number }): boolean
	local state = self._oilStateService:GetState(player.UserId)
	local before = state and (state.activeShipmentCount or 0) or 0
	self:_handleDispatch(player, { manifest = manifest })
	local stateAfter = self._oilStateService:GetState(player.UserId)
	local after = stateAfter and (stateAfter.activeShipmentCount or 0) or 0
	return after > before
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
	-- Pick a lane and build the full path: dock (boat's current slot) → lane waypoints.
	-- Pass boat pivot XZ so `_pickLaneLeastLoaded` can prefer the physically
	-- closest authored route among lanes tied on voyage count (reduces
	-- awkward pier clips before the hull joins the lane).
	local seed = math.floor(workspace:GetServerTimeNow() * 1000) + ownerUserId
	local boatPivotForLanePick = boat:GetPivot().Position
	local lane, laneIndex = self:_pickLaneLeastLoaded(seed, boatPivotForLanePick)
	if not lane then
		warn("[OilShipmentService] No lanes available, falling back to straight line.")
		local startPos = boat:GetPivot().Position
		local endPos = startPos + Vector3.new(0, 0, -140)
		lane = { name = "Fallback", positions = { startPos, endPos } }
	else
		(shipment :: any).laneIndex = laneIndex
		self:_reserveLaneSlot(laneIndex :: number)
	end

	-- Dock spawn position XZ = boat's current pivot (sits at its dock slot). Y must be
	-- the actual water surface — boat model pivots can be anywhere in the model (Ship3
	-- pivot is up near the sail at Y~33), not at the waterline. Using pivot Y directly
	-- would make the voyage path float at pivot height.
	local boatPivotPos = boatPivotForLanePick
	local oceanPart = workspace:FindFirstChild("Map")
		and workspace.Map:FindFirstChild("Ocean")
		and workspace.Map.Ocean:FindFirstChild("StraitHormuz")
		and workspace.Map.Ocean.StraitHormuz:FindFirstChild("Ocean")
	local waterSurfaceY = if oceanPart and oceanPart:IsA("BasePart")
		then oceanPart.Position.Y + oceanPart.Size.Y * 0.5
		else boatPivotPos.Y
	local dockSpawnPos = Vector3.new(boatPivotPos.X, waterSurfaceY, boatPivotPos.Z)

	local path = self:_buildPath(dockSpawnPos, lane)
	local totalPathLen = self:_computePathLength(path)
	if totalPathLen < 1 then totalPathLen = 1 end

	local startRaised = path[1]
	local initDir = #path >= 2 and (path[2] - path[1]) or Vector3.new(0, 0, -1)

	-- If the owner used Teleport to Ship and is still attached to the boat seat, clear `SeatWeld` before
	-- `boat:PivotTo` and hull `WeldConstraint`s in `_setupShip`. Otherwise the seat↔HRP weld can
	-- drag the seat (or fight the new welds) and the ship/seat end up in the wrong place — see
	-- `CharacterTeleport` module comment.
	local ownerBeforeSetup = Players:GetPlayerByUserId(ownerUserId)
	if ownerBeforeSetup and ownerBeforeSetup.Character then
		local hum = ownerBeforeSetup.Character:FindFirstChildOfClass("Humanoid")
		if hum and hum.SeatPart and hum.SeatPart:IsDescendantOf(boat) then
			CharacterTeleport.unseatIfSitting(ownerBeforeSetup.Character)
		end
	end

	-- Setup physics-driven ship
	self:_setupShip(shipment.shipmentId, boat, startRaised, initDir)

	-- Tutorial escort speed override. The `AlignPosition` constraint that
	-- drives the hull is created in `_setupShip` with **two** speed-related
	-- knobs that together cap how fast the boat can actually go:
	--
	--   * `MaxVelocity = 60`        — hard cap on the velocity the constraint
	--                                  may apply to the hull assembly.
	--   * `Responsiveness = 5`      — proportional gain. The constraint's
	--                                  output velocity in steady state is
	--                                  roughly `Responsiveness × (gap to
	--                                  carrot)`. The carrot itself is
	--                                  capped to sit at most
	--                                  `VOYAGE_MAX_LEAD_STUDS = 55` studs
	--                                  ahead of the hull, so the
	--                                  controller's effective ceiling is
	--                                  `min(MaxVelocity, Responsiveness × 55)`.
	--
	-- With the original 60/5 pair, the hull tops out at ~60 studs/s. The
	-- old FTUE override only bumped `MaxVelocity` to 240, leaving the
	-- controller's *output* ceiling at `5 × 55 = 275` — fine on paper, but
	-- the practical observation was that 3×, 4×, and 8× tutorial divisors
	-- all felt identical, meaning the carrot speed at `/4` was already
	-- exceeding the binding cap. Raise *both* knobs together so the hull
	-- can actually track the much-faster carrot:
	--
	--   * `MaxVelocity = 500`       — generous headroom above 4× max-tier
	--                                  carrot speed for any reasonable
	--                                  lane path length.
	--   * `Responsiveness = 8`      — matches the documented "boat blasts
	--                                  from 0 to cruise speed inside a
	--                                  single physics step" config (see
	--                                  `FREEZE_RESUME_RAMP_SECONDS`
	--                                  doc-comment). The freeze-resume
	--                                  ramp already protects the player
	--                                  character from being slid off the
	--                                  deck at high acceleration, so we
	--                                  no longer need the conservative
	--                                  `R = 5` here.
	--
	-- Non-tutorial dispatches keep the original 60/5 pair so player
	-- upgrade speed levels still drive perceived progression.
	if (shipment :: any).ftueTutorialSuppressStraitIncidents == true then
		local shipState = self._activeShips[shipment.shipmentId]
		if shipState and shipState.alignPos then
			shipState.alignPos.MaxVelocity = 500
			shipState.alignPos.Responsiveness = 8
			if RunService:IsStudio() then
				local nominalSpeed = totalPathLen / shipment.travelSeconds
				warn(string.format(
					"[FtueEscort] applied speed override: MaxVelocity=%.0f Responsiveness=%.1f | pathLen=%.0f travelSeconds=%.2f nominalCarrotSpeed=%.1f studs/s | controller_output_ceiling=min(MaxVelocity, R*%d)=%.1f",
					shipState.alignPos.MaxVelocity,
					shipState.alignPos.Responsiveness,
					totalPathLen,
					shipment.travelSeconds,
					nominalSpeed,
					VOYAGE_MAX_LEAD_STUDS,
					math.min(shipState.alignPos.MaxVelocity, shipState.alignPos.Responsiveness * VOYAGE_MAX_LEAD_STUDS)
				))
			end
		end
	end

	-- Yield one physics step before anything downstream (barrel load,
	-- security personnel mount, owner teleport) reads hull geometry.
	-- `_setupShip` un-anchors every part, builds new `WeldConstraint`s,
	-- attaches `AlignPosition`/`AlignOrientation`, and assigns
	-- `root.CFrame = …` all in the same frame. Roblox needs at least
	-- one Heartbeat for those new welds to merge into a single
	-- assembly and for `AlignPosition` to actually drive the hull —
	-- without this wait, `BoatDockService.resolveBoatSupportStandCFrame`
	-- can sample a deck that's mid-bob, the support raycast can miss
	-- the slab (tight `DeckTopAnchor` clearance on Tanker, ~0.12 studs
	-- above slab top), and the player gets ejected DOWN through the
	-- deck after `PivotTo`. One frame (~16 ms) is invisible against the
	-- 1.2s `dockHoldBeforeVoyage` below.
	RunService.Heartbeat:Wait()

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
		boat:SetAttribute("BoatId", shipment.boatId)
		-- HUD: arc-length progress along lane polyline (see voyage loop: s_hull / totalPathLen).
		boat:SetAttribute("RouteProgress01", 0)
	end

	-- Add player flag to the ship
	self:_addPlayerFlag(boat, ownerUserId)

	-- If this voyage was armed with the Security Personnel run-upgrade
	-- (`TryConsumeForDispatch` set `eventImmunity = true` back in
	-- `_handleDispatch`), spawn the visual guard on the boat's authored
	-- `NPC_POSITION` anchor. The guard is the player-facing confirmation
	-- that immunity is live this run; the actual event short-circuit is
	-- driven entirely by the `eventImmunity` flag the strait waypoint
	-- handler already reads (see line ~2666 / 1330). Mounting *after*
	-- `_addPlayerFlag` keeps the SP outside `_setupShip`'s welding pass
	-- (it's anchored, not welded) and leaves a clean parent (`boat`) so
	-- `BoatDockService:_destroyBoat` cleans it up automatically when the
	-- voyage ends — `_teardownShip` below also calls `UnmountForShipment`
	-- explicitly to drop the per-frame heartbeat before the destroy.
	if (shipment :: any).eventImmunity == true and self._securityPersonnelService then
		pcall(function()
			self._securityPersonnelService:MountForShipment(shipment.shipmentId, boat)
		end)
	end

	local dockHoldBeforeVoyage = 1.2
	local tNow = workspace:GetServerTimeNow()
	local shipLabel = BoatCatalog.GetBoat(shipment.boatId).displayName
	self:_emitShipmentEvent("ShipmentStarted", {
		ownerUserId = ownerUserId,
		shipmentId = shipment.shipmentId,
		boatId = shipment.boatId,
		shipDisplayName = shipLabel,
		boatTypeId = shipLabel,
		loaded = shipment.totalLoaded,
		dispatchFee = shipment.dispatchFee,
		voyageStartTime = tNow + dockHoldBeforeVoyage,
		-- ETA hint only (progress is distance-based; voyages can run longer if stuck or shorter if fast).
		voyageEndTime = tNow + dockHoldBeforeVoyage + shipment.travelSeconds * 1.5,
	})
	self:_emitManifestHudSnapshot(shipment, nil)

	-- Stack loaded barrels visually on the ship deck
	self:_loadBarrelsOnDeck(boat, shipment.manifest)

	-- Auto-teleport owner onto the ship deck (Ship Oil click is a one-click dispatch).
	-- Skip when AutoShip is active — the player stays on their plot.
	local autoShipActive = self._autoShipService and self._autoShipService:IsActive(ownerUserId)
	if not autoShipActive then
		local ownerPlayer = Players:GetPlayerByUserId(ownerUserId)
		if ownerPlayer then
			pcall(function()
				self._boatDockService:TeleportOwnerToSeat(ownerPlayer)
			end)
			-- Owner is now standing on the ship deck. Reassign their
			-- character to the voyage collision group (`PlayerInStraitEvent`
			-- — see `Init` for the pair-rule matrix) so they don't clip on
			-- docks, MapDecor, parked boats, or cosmetic NPCs while sailing.
			-- Restored at voyage end in `_handleOwnerAfterSuccessfulShipmentFinish`
			-- and the `voyageAborted` branch below. Skipped when AutoShip is
			-- active because the player never boards.
			pcall(function()
				self:_applyOwnerOnVoyageCollisionGroup(ownerPlayer)
			end)
		end
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

	-- Telemetry §6.3 `shipment_voyage_started`. Fires once per voyage AFTER
	-- path build so `pathLength`, `laneIndex`, and `straitTriggerSlots`
	-- match the actual route. Owner may have left mid-spawn; pass the
	-- player handle if still online so per-player rate limit attributes
	-- correctly, otherwise fall through with `nil`.
	pcall(function()
		local ownerForTelemetry = Players:GetPlayerByUserId(ownerUserId)
		Telemetry.Track(ownerForTelemetry, "shipment_voyage_started", {
			shipmentId = shipment.shipmentId,
			pathLength = totalPathLen,
			laneIndex = laneIndex,
			straitTriggerSlots = #triggerSlots,
		})
	end)

	if self:_straitDebugLogEnabled() then
		if #triggerSlots == 0 then
			warn(
				string.format(
					"[StraitShipment DEBUG] shipment %s: NO strait trigger slots (need lane waypoints %s on path). Path has %d vertices.",
					shipment.shipmentId,
					(function()
						local parts = {}
						for _, n in ipairs(StraitEventConfig.GetAllLaneWaypointTriggers()) do
							table.insert(parts, tostring(n))
						end
						return table.concat(parts, ",")
					end)(),
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

	-- Distance-based progress (hull projected onto path) + lead "carrot" capped ahead of hull (Option A).
	local s_lead = 0.0
	local s_hull_prev = 0.0
	local routeHudMonotone = 0.0
	local voyageWallStart = workspace:GetServerTimeNow()
	local lastDt = 1 / 60
	local lastProgressClock = os.clock()
	local peakProgress = 0.0
	local leadReachedEndClock: number? = nil

	while true do
		local dt = lastDt
		if dt > 0.15 then
			dt = 0.15
		elseif dt < 1 / 240 then
			dt = 1 / 240
		end

		local voyageAborted = false

		-- Check for external destruction (nuke, airstrike)
		if ctx and ctx._forceDestroyed then
			voyageAborted = true
		end

		if ctx and not voyageAborted then
			local forcedLost = false
			-- Suppress on FTUE tutorial AND when Security Personnel has been
			-- consumed for this dispatch — the upgrade promises "complete
			-- run immunity to all events", which by intent includes contract
			-- pirate hits queued against this player.
			local suppressForcedHits = (shipment :: any).ftueTutorialSuppressStraitIncidents == true
				or (shipment :: any).eventImmunity == true
			if not suppressForcedHits then
				forcedLost = self:_maybeProcessForcedPirateHit(shipment, ownerUserId, voyageClock, boat, ctx)
			end
			if forcedLost then
				voyageAborted = true
			end
			-- Check for expired interactive pirate raid (AFK/disconnect timeout)
			self:_checkPendingInteractiveRaidTimeout(shipment, ctx)
		end

		local s_hull = s_hull_prev
		if not voyageAborted then
			local samplePos = if boat:IsA("Model") then getBoatPathSampleWorldPosition(boat) else boat:GetPivot().Position
			local s_raw = projectWorldPosToArcLength(path, segDists, samplePos)
			s_hull = math.max(s_hull_prev, math.min(s_raw, totalPathLen))

			if s_hull > peakProgress + 0.25 then
				peakProgress = s_hull
				lastProgressClock = os.clock()
			end

			local nominalSpeed = totalPathLen / voyageTime
			s_lead = math.min(s_lead + nominalSpeed * dt, totalPathLen, s_hull + VOYAGE_MAX_LEAD_STUDS)
			s_lead = math.max(s_lead, s_hull)

			local hullAlongPos = select(1, positionAndTangentAtArcLength(path, segDists, s_hull))
			local currentPos, nextTan = positionAndTangentAtArcLength(path, segDists, s_lead)
			if boat:IsA("Model") then
				-- Polyline distance 0→1 (not Euclidean dock→finish — winding strait paths need arc length).
				local denom = totalPathLen
				local hull01 = if denom > 1e-4 then math.clamp(s_hull / denom, 0, 1) else 0
				local lead01 = if denom > 1e-4 then math.clamp(s_lead / denom, 0, 1) else 0
				routeHudMonotone = math.max(routeHudMonotone, hull01, lead01)
				boat:SetAttribute("RouteProgress01", clamp01(routeHudMonotone))
			end
			if ctx then
				ctx.lastWorldPosition = hullAlongPos
			end
			local flatDir = Vector3.new(nextTan.X, 0, nextTan.Z)
			if flatDir.Magnitude < 1e-3 then
				flatDir = Vector3.new(0, 0, -1)
			else
				flatDir = flatDir.Unit
			end
			local raisedPos = Vector3.new(currentPos.X, currentPos.Y, currentPos.Z)
			self:_updateShipPosition(shipment.shipmentId, boat, raisedPos, flatDir)

			-- Boost AlignPosition responsiveness in the final stretch so the
			-- ship doesn't decelerate to a crawl from the exponential approach.
			local remaining = totalPathLen - s_hull
			local shipState = self._activeShips[shipment.shipmentId]
			if shipState and shipState.alignPos and remaining < 80 then
				shipState.alignPos.Responsiveness = 10
			end

			local prevArc = s_hull_prev
			for _, slot in ipairs(triggerSlots) do
				local laneN = slot.laneWaypointIndex
				if not firedAtLaneWaypoint[laneN] and prevArc < slot.distance and s_hull >= slot.distance then
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
					local lost = self:_handleStraitWaypointTrigger(shipment, ownerUserId, laneN, hullAlongPos, voyageClock, boat)
					if ctx then
						ctx.eventInProgress = false
					end
					-- Reset stuck timer after any strait event freeze (pirate raids, CG inspections, etc.)
					lastProgressClock = os.clock()
					if lost then
						voyageAborted = true
						break
					end
				end
			end

			s_hull_prev = s_hull
		end

		if voyageAborted then
			if ctx and ctx.pendingForcedPirateHit and self._hitContractService and typeof(self._hitContractService.RefundContract) == "function" then
				self._hitContractService:RefundContract(ctx.pendingForcedPirateHit.contractId, "victim_destroyed_before_raid")
			end
			if boardConnection then
				boardConnection:Disconnect()
			end
			self:_unseatPlayersFromBoat(boat)
			-- Total loss: restore the owner's collision group BEFORE the boat
			-- is destroyed and the death / respawn flow takes over. Symmetric
			-- with the success path; safe even if the owner has gone offline
			-- or the apply was skipped (AutoShip).
			pcall(function()
				self:_restoreOwnerOnVoyageCollisionGroup(ownerUserId)
			end)
			self:_teardownShip(shipment.shipmentId)
			self._boatDockService:CheckinBoat(ownerUserId, { destroyed = true })
			self:_finishShipmentWithoutPayout(shipment, "Strait event: total loss")
			self._activeShipmentByOwner[ownerUserId] = nil
			self._shipmentContexts[shipment.shipmentId] = nil
			return
		end

		if not voyageAborted then
			local arrived = s_hull >= totalPathLen - VOYAGE_COMPLETE_ARC_EPS_STUDS

			-- Lead-carrot arrival: when s_lead has been at the path end for 3s
			-- the boat is physically close enough even if the hull projection
			-- hasn't crossed the 12-stud threshold. Safe: s_lead can only reach
			-- the end when s_hull is within VOYAGE_MAX_LEAD_STUDS (55) studs.
			if s_lead >= totalPathLen - 1 then
				if not leadReachedEndClock then
					leadReachedEndClock = os.clock()
				end
				if os.clock() - leadReachedEndClock > 3 then
					arrived = true
				end
			end

			-- Use voyage clock (freeze-adjusted) for the hard wall, not raw wall time.
			-- Raw wall time includes freeze pauses (pirate raids, CG inspections),
			-- which are already accounted for in voyageClock.startTime offsets.
			local wallElapsed = workspace:GetServerTimeNow() - voyageClock.startTime
			local hardWall = wallElapsed > voyageTime * VOYAGE_FAILSAFE_MAX_WALL_MULT
			local stuckNoMove = (os.clock() - lastProgressClock) > VOYAGE_FAILSAFE_STUCK_SECONDS
				and s_hull < totalPathLen - VOYAGE_COMPLETE_ARC_EPS_STUDS
			-- Tutorial protected voyages opt out of BOTH failsafe checks. The
			-- boosted base speed + showcase event pauses (Coast Guard freeze
			-- + Mines barrage) can flip one of these flags while the boat is
			-- still mid-strait, and the existing recovery (force-warp the
			-- boat to the warehouse end + early-break the voyage) reads to
			-- the new player as the boat suddenly teleporting to the end.
			-- Natural-arrival detection (`s_hull >= totalPathLen - eps`) and
			-- lead-carrot arrival both still end the voyage cleanly when
			-- the boat actually reaches the dock. If a tutorial voyage
			-- genuinely hangs, the player can rejoin and the FTUE rejoin
			-- restore puts them on solid ground — better UX than a visual
			-- snap to the warehouse on the very first run.
			local isTutorialEscort = (shipment :: any).ftueTutorialSuppressStraitIncidents == true
			if isTutorialEscort then
				hardWall = false
				stuckNoMove = false
			end
			if (hardWall or stuckNoMove) and not arrived then
				local endPos, endTan = positionAndTangentAtArcLength(path, segDists, totalPathLen)
				local flatE = Vector3.new(endTan.X, 0, endTan.Z)
				if flatE.Magnitude < 1e-3 then
					flatE = Vector3.new(0, 0, -1)
				else
					flatE = flatE.Unit
				end
				if boat:IsA("Model") then
					boat:SetAttribute("RouteProgress01", 1)
				end
				self:_updateShipPosition(shipment.shipmentId, boat, Vector3.new(endPos.X, endPos.Y, endPos.Z), flatE)
			end
			if arrived or hardWall or stuckNoMove then
				warn(string.format(
					"[VoyageEnd] shipment=%s arrived=%s hardWall=%s stuckNoMove=%s wallElapsed=%.1f voyageTime=%.1f s_hull=%.1f totalPath=%.1f stuckSec=%.1f",
					shipment.shipmentId,
					tostring(arrived), tostring(hardWall), tostring(stuckNoMove),
					wallElapsed, voyageTime, s_hull, totalPathLen,
					os.clock() - lastProgressClock
				))
				self:_emitShipmentEvent("ShipmentVoyageComplete", {
					ownerUserId = ownerUserId,
					shipmentId = shipment.shipmentId,
				})
				break
			end
		end

		lastDt = task.wait() -- run every frame (~30fps) for smooth movement
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

	-- Wrap in pcall so a Telemetry bug can never disrupt the warehouse
	-- delivery / shipment teardown that follows.
	pcall(function()
		local ownerPlayer = Players:GetPlayerByUserId(ownerUserId)
		if not ownerPlayer then
			return
		end
		local voyageSeconds: number? = nil
		if typeof(voyageWallStart) == "number" then
			voyageSeconds = workspace:GetServerTimeNow() - voyageWallStart
		end
		Telemetry.Track(ownerPlayer, "shipment_completed", {
			shipmentId = shipment.shipmentId,
			barrelsDelivered = totalDelivered,
			barrelsLost = shipment.totalLoaded - totalDelivered,
			deliveredByTier = deliveredManifest,
			voyageSeconds = voyageSeconds,
			boatId = shipment.boatId,
		})
		if not _firstDeliveredByUserId[ownerUserId] then
			_firstDeliveredByUserId[ownerUserId] = true
			Telemetry.Funnel(ownerPlayer, "first_run", 3, "first_delivered")
		end
	end)

	if self._ftueService and FtueConfig.Enabled and totalDelivered > 0 then
		(self._ftueService :: any):OnShipmentDeliveredToWarehouse(ownerUserId, totalDelivered)
	end

	local shipLabelR = BoatCatalog.GetBoat(shipment.boatId).displayName
	self:_emitShipmentEvent("ShipmentResolved", {
		ownerUserId = ownerUserId,
		shipmentId = shipment.shipmentId,
		boatId = shipment.boatId,
		shipDisplayName = shipLabelR,
		boatTypeId = shipLabelR,
		loaded = shipment.totalLoaded,
		delivered = totalDelivered,
		lost = shipment.totalLoaded - totalDelivered,
		dispatchFee = shipment.dispatchFee,
		deliveredByTier = deliveredManifest,
	})

	local lb = self._leaderboardService
	if lb and typeof((lb :: any).OnStraitVoyageSuccess) == "function" then
		(lb :: any):OnStraitVoyageSuccess(ownerUserId, totalDelivered)
	else
		warn(string.format(
			"[OilShipmentService] Leaderboard hook skipped (no service or method) — userId=%d delivered=%d",
			ownerUserId,
			totalDelivered
		))
	end

	-- Owner on strait / ocean -> warehouse spawn; on StartBeach / FinishBeach footprint -> stay; at home plot -> no-op
	if boardConnection then
		boardConnection:Disconnect()
	end
	self:_handleOwnerAfterSuccessfulShipmentFinish(boat, ownerUserId)
	self:_teleportGuestsHomeAfterShipmentFinish(boat, ownerUserId)
	self:_teardownShip(shipment.shipmentId)
	self._boatDockService:CheckinBoat(ownerUserId, { destroyed = false })
	if ctx and ctx.pendingForcedPirateHit and self._hitContractService and typeof(self._hitContractService.RefundContract) == "function" then
		self._hitContractService:RefundContract(ctx.pendingForcedPirateHit.contractId, "victim_completed_before_raid")
	end
	self:_releaseLaneSlotForShipment(shipment :: any)
	self._activeShipmentByOwner[ownerUserId] = nil
	self._shipmentContexts[shipment.shipmentId] = nil
end

--- Successful voyage: sample **HumanoidRootPart** before unseat. Warehouse if over **`Map.Ocean`** footprint (not over **`StartBeach`** / **`FinishBeach`** anywhere under **`Map`**). Seated-on-ship fallback: **ClaimPad** if warehouse unavailable.
--- **FTUE override:** if the player just advanced to **`WaitWarehouseSell`** via this delivery, force-teleport to
--- their warehouse regardless of where they are (on plot, in town, on the boat) so the next leg's pointers line up.
function OilShipmentService:_handleOwnerAfterSuccessfulShipmentFinish(boat: Instance, ownerUserId: number)
	-- Restore the voyage collision group BEFORE any post-voyage teleport.
	-- Done unconditionally up front (even when the player has gone offline
	-- or the character is missing) so the per-userId connection slot is
	-- always cleared and the next dispatch starts from a clean slate.
	-- The restore helper no-ops on un-stamped parts and on offline players,
	-- so this is safe even when the apply at dispatch was skipped (e.g.
	-- AutoShip).
	pcall(function()
		self:_restoreOwnerOnVoyageCollisionGroup(ownerUserId)
	end)
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

	if FtueConfig.Enabled and self._warehouseService and self._oilStateService then
		local stFtue = self._oilStateService:GetState(ownerUserId)
		local fs = stFtue and (stFtue :: any).ftueStep
		if fs == FtueConfig.Step.WaitWarehouseSell or fs == FtueConfig.Step.WaitShipment then
			if self._warehouseService:TryTeleportPlayerToWarehouse(player) then
				return
			end
		end
	end

	if self._warehouseService and self:_postStraitWarehouseTeleportByMapPosition(samplePos) then
		if self._warehouseService:TryTeleportPlayerToWarehouse(player) then
			return
		end
	end

	if wasSeatedOnThisBoat then
		local plot = self._plotService:GetOwnedPlot(player.UserId)
		local claimPad = plot and plot:FindFirstChild("ClaimPad")
		if claimPad and claimPad:IsA("BasePart") then
			-- Preserve the pad's authored rotation (was discarded by `CFrame.new(<position>)` —
			-- same bug shape as the Home / Town / Warehouse teleports). Lift Y by 5 in world.
			local targetCFrame = claimPad.CFrame + Vector3.new(0, 5, 0)
			CharacterTeleport.teleportWithUnseat(character, targetCFrame, "ShipmentFinish:claimPad")
			self:_fireCameraSnap(player, targetCFrame)
		end
	end
end

--- Non-owners on deck / seat when the voyage completes: send them to **their** ClaimPad (not strait warehouse).
--- Owner delivery uses `_handleOwnerAfterSuccessfulShipmentFinish`; without this, guests fall through when the boat is checked in.
function OilShipmentService:_teleportGuestsHomeAfterShipmentFinish(boat: Instance, ownerUserId: number)
	if not (boat and boat:IsA("Model")) then
		return
	end
	local boatModel = boat :: Model
	local boatCF, boatSize = boatModel:GetBoundingBox()
	local halfX = boatSize.X * 0.5 + 2
	local halfY = boatSize.Y * 0.5 + 6
	local halfZ = boatSize.Z * 0.5 + 2

	for _, player in ipairs(Players:GetPlayers()) do
		if player.UserId == ownerUserId then
			continue
		end
		local character = player.Character
		if not character then
			continue
		end
		local hrp = character:FindFirstChild("HumanoidRootPart")
		if not (hrp and hrp:IsA("BasePart")) then
			continue
		end

		local hum = character:FindFirstChildOfClass("Humanoid")
		local seatedOnBoat = hum ~= nil and hum.SeatPart ~= nil and hum.SeatPart:IsDescendantOf(boatModel)
		local rel = boatCF:PointToObjectSpace(hrp.Position)
		local onDeck = math.abs(rel.X) <= halfX
			and math.abs(rel.Y) <= halfY
			and math.abs(rel.Z) <= halfZ

		if not (seatedOnBoat or onDeck) then
			continue
		end

		local plot = self._plotService:GetOwnedPlot(player.UserId)
		local claimPad = plot and plot:FindFirstChild("ClaimPad")
		if not (claimPad and claimPad:IsA("BasePart")) then
			continue
		end

		-- Preserve guest's claim-pad rotation (same bug shape as the Home teleport).
		local targetCFrame = claimPad.CFrame + Vector3.new(0, 5, 0)
		CharacterTeleport.teleportWithUnseat(
			character,
			targetCFrame,
			"ShipmentFinish:guestHome"
		)
		self:_fireCameraSnap(player, targetCFrame)
	end
end

--- Strait total loss, etc.: teleport everyone on the boat (seated OR just
--- standing on the deck) to their home ClaimPad. Seated-only detection was
--- insufficient — owners routinely walk around the deck mid-voyage, and a
--- spectator teleported in via the crowd-marker click is never seated.
function OilShipmentService:_unseatPlayersFromBoat(boat: Instance)
	DevLog.log(string.format("[ShipDestroy] _unseatPlayersFromBoat fired for boat=%s", tostring(boat and boat.Name)))
	if not (boat and boat:IsA("Model")) then
		return
	end

	local boatCF, boatSize = (boat :: Model):GetBoundingBox()
	-- Pad the AABB so characters standing on the railing / at the edge still qualify.
	local halfX = boatSize.X * 0.5 + 2
	local halfY = boatSize.Y * 0.5 + 6
	local halfZ = boatSize.Z * 0.5 + 2

	local teleportedAny = false
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		if not character then
			continue
		end
		local hrp = character:FindFirstChild("HumanoidRootPart")
		if not (hrp and hrp:IsA("BasePart")) then
			continue
		end

		local hum = character:FindFirstChildOfClass("Humanoid")
		local seatedOnBoat = hum ~= nil and hum.SeatPart ~= nil and hum.SeatPart:IsDescendantOf(boat)
		local rel = boatCF:PointToObjectSpace(hrp.Position)
		local onDeck = math.abs(rel.X) <= halfX
			and math.abs(rel.Y) <= halfY
			and math.abs(rel.Z) <= halfZ

		if not (seatedOnBoat or onDeck) then
			continue
		end

		local plot = self._plotService:GetOwnedPlot(player.UserId)
		local claimPad = plot and plot:FindFirstChild("ClaimPad")
		if not (claimPad and claimPad:IsA("BasePart")) then
			DevLog.log(string.format("[ShipDestroy] no ClaimPad for %s; skipping teleport", player.Name))
			if seatedOnBoat and hum and hum.SeatPart then
				hum.SeatPart:Sit(nil)
			end
			continue
		end

		if seatedOnBoat and hum and hum.SeatPart then
			local seat = hum.SeatPart
			seat:Sit(nil)
			hum.Sit = false
			local weld = seat:FindFirstChild("SeatWeld")
			if weld and weld:IsA("Weld") then
				weld:Destroy()
			end
		end

		-- Keep the break-apart death effect, but do it on a cloned corpse so the live
		-- player character doesn't get stranded in a broken replication/camera state.
		local originalArchivable = character.Archivable
		character.Archivable = true
		local corpse = character:Clone()
		character.Archivable = originalArchivable
		corpse.Name = string.format("%s_ShipwreckCorpse", player.Name)
		corpse:PivotTo(character:GetPivot())
		corpse.Parent = workspace
		Debris:AddItem(corpse, 8)

		for _, inst in ipairs(corpse:GetDescendants()) do
			if inst:IsA("Script") or inst:IsA("LocalScript") then
				inst:Destroy()
			elseif inst:IsA("Humanoid") then
				inst:Destroy()
			end
		end

		local rng = Random.new()
		for _, joint in ipairs(corpse:GetDescendants()) do
			if joint:IsA("Motor6D") or joint:IsA("Weld") or joint:IsA("WeldConstraint") or joint:IsA("BallSocketConstraint") then
				joint:Destroy()
			end
		end
		for _, part in ipairs(corpse:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Anchored = false
				part.CanCollide = true
				local flingPower = self._nukeActive and 200 or 120
				part.AssemblyLinearVelocity = Vector3.new(
					rng:NextNumber(-flingPower, flingPower),
					rng:NextNumber(80, flingPower * 1.5),
					rng:NextNumber(-flingPower, flingPower)
				)
				part.AssemblyAngularVelocity = Vector3.new(
					rng:NextNumber(-12, 12),
					rng:NextNumber(-12, 12),
					rng:NextNumber(-12, 12)
				)
			end
		end

		-- Immediately reload the real player character so they actually despawn/respawn.
		-- The corpse clone above carries the break-apart visuals.
		local respawnDelay = self._nukeActive and 3 or 0.5
		task.delay(respawnDelay, function()
			if not (player.Parent and claimPad.Parent) then
				return
			end

			local characterAddedConn: RBXScriptConnection? = nil
			characterAddedConn = player.CharacterAdded:Connect(function(newChar)
				if characterAddedConn then
					characterAddedConn:Disconnect()
					characterAddedConn = nil
				end
				task.defer(function()
					if not (newChar.Parent and claimPad.Parent) then
						return
					end
					-- Preserve the pad's authored rotation across the post-destroy respawn so the
					-- player lands facing the Delivery Man (was world-Z under the position-only
					-- `CFrame.new`). NOTE: this fires from a `CharacterAdded` callback, which is
					-- the same surface as `PlotService:_teleportCharacterToOwnedPlot` — the camera
					-- snap may race the client UI bootstrap on extreme cases, but in the normal
					-- destroy → respawn flow `HudTeleportRouter` is already up and the snap lands.
					local targetCFrame = claimPad.CFrame + Vector3.new(0, 5, 0)
					CharacterTeleport.teleportWithUnseat(
						newChar,
						targetCFrame,
						"ShipDestroy:RespawnToClaimPad"
					)
					self:_fireCameraSnap(player, targetCFrame)
				end)
			end)

			player:LoadCharacter()
			task.delay(5, function()
				if characterAddedConn then
					characterAddedConn:Disconnect()
				end
			end)
		end)

		DevLog.log(string.format("[ShipDestroy] spawned corpse clone + queued respawn for %s in %.1fs (seated=%s onDeck=%s)",
			player.Name, respawnDelay, tostring(seatedOnBoat), tostring(onDeck)))
		teleportedAny = true
	end

	if not teleportedAny then
		DevLog.log("[ShipDestroy] no players on or near the boat; nobody teleported")
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

function OilShipmentService:_snapshotLostDeckBarrels(
	boat: Instance?,
	removedByTier: { [string]: number }?,
	maxCount: number?
): { [number]: { [string]: any } }
	local out = {}
	if not boat then
		return out
	end

	local wantedByTier: { [string]: number } = {}
	local wantedTotal = 0
	if typeof(removedByTier) == "table" then
		for _, tier in ipairs(BARREL_LOSS_TIER_ORDER) do
			local count = math.max(0, math.floor(tonumber(removedByTier[tier]) or 0))
			if count > 0 then
				wantedByTier[tier] = count
				wantedTotal += count
			end
		end
	end
	if maxCount and maxCount > 0 then
		wantedTotal = math.min(wantedTotal, math.floor(maxCount))
	end
	if wantedTotal <= 0 then
		return out
	end

	local fallback = {}
	for _, barrel in ipairs(collectDeckBarrelRoots(boat)) do
		local snapshot = snapshotDeckBarrelVisual(barrel)
		if snapshot then
			local tier = snapshot.tier
			if typeof(tier) == "string" and (wantedByTier[tier] or 0) > 0 then
				table.insert(out, snapshot)
				wantedByTier[tier] -= 1
			else
				table.insert(fallback, snapshot)
			end
			if #out >= wantedTotal then
				return out
			end
		end
	end

	for _, snapshot in ipairs(fallback) do
		table.insert(out, snapshot)
		if #out >= wantedTotal then
			break
		end
	end

	return out
end

--- Hard cap on visible deck barrels regardless of how big the actual
--- cargo manifest is. Decouples ship rig visuals from `ShipUpgradeConfig`
--- cargo capacity so a fully maxed ship (`L10 = 500 barrels`) doesn't
--- spawn a 500-barrel skyscraper that lags out nearby clients and clips
--- through the deck silhouette. The deck still *represents* the manifest
--- proportionally — tier slices below scale each tier's spawn count
--- against this total — so a "mostly Premium" load still looks mostly
--- Premium even when scaled down.
local MAX_VISUAL_BARRELS_ON_DECK = 50

function OilShipmentService:_loadBarrelsOnDeck(boat: Instance, manifest)
	local stackRoot = findBarrelStackRoot(boat)
	if not stackRoot then return end
	local stackBaseCf = resolveShipBarrelStackBaseCf(boat, stackRoot)
	local shipRoot = if boat:IsA("Model") then boat.PrimaryPart else nil
	if not shipRoot then
		shipRoot = stackRoot
	end

	local assetsFolder = ReplicatedStorage:FindFirstChild("Assets")
	if not assetsFolder then return end

	local tierTemplates = (OilConfig.Barrels and OilConfig.Barrels.TierTemplates) or {}

	local tierWidths = {}
	for tier, templateName in pairs(tierTemplates) do
		local template = assetsFolder:FindFirstChild(templateName)
		if template then
			local info = BarrelStacking.ResolveStackInfo(template)
			tierWidths[tier] = info.footprintDiameter + 0.5
		else
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

	local nextContactByColumn = {} -- key = "col_row", value = next BottomContact world cframe

	local barrelIndex = 0

	-- Resolve per-tier visible counts. If the manifest already fits inside
	-- `MAX_VISUAL_BARRELS_ON_DECK`, show every barrel 1:1. Otherwise scale
	-- each tier proportionally so visual mix matches the manifest mix
	-- (e.g. a 80% Premium / 20% Crude load stays 80/20 on deck), then
	-- drop any rounding overshoot in `BARREL_LOSS_TIER_ORDER` order
	-- (Crude → Refined → Premium) so the most-prestige barrels stay
	-- visible if a count needs to be trimmed by 1.
	local visualCountByTier: { [string]: number } = {}
	local totalManifestBarrels = 0
	for _, tier in ipairs(TIER_ORDER) do
		totalManifestBarrels += manifest[tier] or 0
	end
	if totalManifestBarrels <= MAX_VISUAL_BARRELS_ON_DECK then
		for _, tier in ipairs(TIER_ORDER) do
			visualCountByTier[tier] = manifest[tier] or 0
		end
	else
		local visualScale = MAX_VISUAL_BARRELS_ON_DECK / totalManifestBarrels
		local visualTotal = 0
		for _, tier in ipairs(TIER_ORDER) do
			local raw = (manifest[tier] or 0) * visualScale
			local rounded = math.floor(raw + 0.5)
			visualCountByTier[tier] = rounded
			visualTotal += rounded
		end
		local overshoot = visualTotal - MAX_VISUAL_BARRELS_ON_DECK
		while overshoot > 0 do
			local trimmedThisPass = false
			for _, tier in ipairs(BARREL_LOSS_TIER_ORDER) do
				if (visualCountByTier[tier] or 0) > 0 then
					visualCountByTier[tier] -= 1
					overshoot -= 1
					trimmedThisPass = true
					if overshoot <= 0 then
						break
					end
				end
			end
			if not trimmedThisPass then
				break
			end
		end
	end

	for _, tier in ipairs(TIER_ORDER) do
		local count = visualCountByTier[tier] or 0
		local templateName = tierTemplates[tier]
		local template = templateName and assetsFolder:FindFirstChild(templateName)

		for _ = 1, count do
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
			barrel:SetAttribute("OilTier", tier)
			if templateName then
				barrel:SetAttribute("TemplateName", templateName)
			end
			if barrel:IsA("Model") and not barrel.PrimaryPart then
				for _, d in ipairs(barrel:GetDescendants()) do
					if d:IsA("BasePart") then
						barrel.PrimaryPart = d
						break
					end
				end
			end

			local col = barrelIndex % COLUMNS
			local row = math.floor(barrelIndex / COLUMNS) % COLUMNS
			local colKey = col .. "_" .. row
			local contactCf = nextContactByColumn[colKey]
			if not contactCf then
				contactCf = stackBaseCf
					* CFrame.new((col - 1) * SPACING, 0, (row - 1) * SPACING)
			end
			local stackInfo = BarrelStacking.PlaceInstanceOnContact(barrel, contactCf)

			barrel.Parent = boat

			-- Position from the authored stack root, but weld directly to the ship root so
			-- barrel models always travel with the moving boat assembly. Barrels are
			-- cargo (not helpers) — players walk on them while on deck — so we DO
			-- want CanCollide = true here. Tag them in the `ShipmentShip` group too
			-- so a barrel that pokes past the gunwale doesn't snag on `MarinaDock`
			-- pier geometry or `MapDecor` buoys (matches the universal boat rule
			-- in `BoatCollisionContract`).
			for _, part in ipairs(barrel:IsA("Model") and barrel:GetDescendants() or {barrel}) do
				if part:IsA("BasePart") then
					part.Anchored = false
					part.Massless = true
					part.CanCollide = true
					part.Transparency = 0.3
					pcall(function()
						(part :: BasePart).CollisionGroup = BoatCollisionContract.CollisionGroup
					end)
					local wc = Instance.new("WeldConstraint")
					wc.Part0 = shipRoot
					wc.Part1 = part
					wc.Parent = shipRoot
				end
			end
			nextContactByColumn[colKey] =
				BarrelStacking.GetContactCFrame(barrel, "Top")
				or (contactCf * CFrame.new(0, stackInfo.stackStep, 0))
			barrelIndex += 1
		end
	end

	-- Re-assert `ShipmentShip` on every deck cargo part (covers template defaults,
	-- late-welded descendants, and any init-order gap vs `MarinaDock` / `MapDecor`).
	BoatCollisionContract.TagDeckCargoAsShipmentHull(boat)
end

function OilShipmentService:_addPlayerFlag(boat: Instance, ownerUserId: number)
	-- Find the pre-placed PlayerFlag in the cloned template and apply the player's face to it.
	-- No new parts created — the flag + pole are already positioned in the template by the user.
	local flag = findPlayerFlagPart(boat)
	if not flag then return end

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
	self:_releaseLaneSlotForShipment(shipment :: any)
	self._oilStateService:DecrementShipmentCount(shipment.ownerUserId)
	self._oilStateService:PushState(shipment.ownerUserId)
	local shipLabelF = BoatCatalog.GetBoat(shipment.boatId).displayName
	self:_emitShipmentEvent("ShipmentResolved", {
		ownerUserId = shipment.ownerUserId,
		shipmentId = shipment.shipmentId,
		boatId = shipment.boatId,
		shipDisplayName = shipLabelF,
		boatTypeId = shipLabelF,
		loaded = shipment.totalLoaded,
		delivered = 0,
		lost = shipment.totalLoaded,
		dispatchFee = shipment.dispatchFee,
		failureReason = reason,
	})
	pcall(function()
		local ownerForTelemetry = Players:GetPlayerByUserId(shipment.ownerUserId)
		Telemetry.Track(ownerForTelemetry, "shipment_total_loss", {
			shipmentId = shipment.shipmentId,
			reason = reason,
			barrelsLost = shipment.totalLoaded,
			eventId = (shipment :: any).lastStraitEventId,
		})
	end)
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
	if not RunService:IsStudio() then
		return false
	end
	return d.LogWaypointTriggers or d.VerboseStraitWaypointLogsInStudio ~= false
end

--- Dry-run barrel loss: returns the count and per-tier breakdown that WOULD be lost
--- without modifying the manifest. Used by interactive pirate raids to pre-compute potential loss.
function OilShipmentService:_computeLooseBarrelLoss(shipment, fraction: number, minFloor: number?): (number, { [string]: number })
	local removedByTier: { [string]: number } = {}
	if fraction <= 0 and (minFloor or 0) <= 0 then
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
	if minFloor and minFloor > toRemove then
		toRemove = minFloor
	end
	if toRemove > onShip then
		toRemove = onShip
	end
	if toRemove <= 0 then
		return 0, removedByTier
	end
	local removed = 0
	for _, tier in ipairs(BARREL_LOSS_TIER_ORDER) do
		local have = manifest[tier] or 0
		if have > 0 then
			local take = math.min(have, toRemove - removed)
			if take > 0 then
				removed += take
				removedByTier[tier] = (removedByTier[tier] or 0) + take
			end
		end
		if removed >= toRemove then
			break
		end
	end
	return removed, removedByTier
end

-- Returns oil units removed (sum) and per-tier oil removed. Loss = max(minFloor, ceil(manifestSum * fraction)),
-- clamped to manifest total. `minFloor` is used by tornado to guarantee a minimum hit on small manifests.
function OilShipmentService:_applyLooseBarrelLoss(shipment, fraction: number, minFloor: number?): (number, { [string]: number })
	local removedByTier: { [string]: number } = {}
	if fraction <= 0 and (minFloor or 0) <= 0 then
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
	if minFloor and minFloor > toRemove then
		toRemove = minFloor
	end
	if toRemove > onShip then
		toRemove = onShip
	end
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
	-- Slots are the *union* of every bracket's allow-list — the per-bracket
	-- gate happens at roll time in `_handleStraitWaypointTrigger`, so a strait
	-- bracket flip mid-voyage still fires the right waypoints from that point on.
	for _, laneN in ipairs(StraitEventConfig.GetAllLaneWaypointTriggers()) do
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

function OilShipmentService:_emitPirateHitAlert(userId: number, message: string, extra: { [string]: any }?)
	local player = Players:GetPlayerByUserId(userId)
	if not player then
		return
	end
	local ev = self._remoteService:GetEvent(RemoteNames.PirateHitAlert)
	local payload: { [string]: any } = { message = message }
	if typeof(extra) == "table" then
		-- Forward-compat: ship structured fields alongside the rendered string
		-- (e.g. `stolenByTier`, `barrelsStolen`, `contractId`) so a future hit-
		-- history panel can read them without us needing a new RemoteEvent or
		-- a wire-format bump. Today only `PirateHireClient` consumes
		-- `payload.message`; extra keys are inert.
		for k, v in pairs(extra) do
			if payload[k] == nil then
				payload[k] = v
			end
		end
	end
	ev:FireClient(player, payload)
end

--- Format a `stolenByTier` map ({ Crude=3, Premium=2 }) into a stable, readable
--- breakdown string ("3 Crude, 2 Premium"). Order follows `QualityConfig.TierOrder`
--- (Premium → Refined → Crude — the same order manifests use everywhere else)
--- so the broker alert reads consistently with the cargo HUD. Returns "" when
--- nothing was stolen so callers can fall back to the legacy total-only line.
function OilShipmentService:_formatStolenBreakdown(stolenByTier: { [string]: number }?): string
	if typeof(stolenByTier) ~= "table" then
		return ""
	end
	local parts: { string } = {}
	for _, tier in ipairs(QualityConfig.TierOrder) do
		local raw = (stolenByTier :: { [string]: any })[tier]
		local n = math.floor(tonumber(raw) or 0)
		if n > 0 then
			table.insert(parts, string.format("%d %s", n, QualityConfig.hudShortLabel(tier)))
		end
	end
	if #parts == 0 then
		return ""
	end
	return table.concat(parts, ", ")
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
	local skinFx = BoatCatalog.GetBoat(shipment.boatId).fxParticleScale
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

	-- Per-tier breakdown for the contractor: "3 Crude, 2 Premium". When zero
	-- barrels were on deck we fall back to the legacy total-only line so the
	-- contractor still hears that the hit *resolved*, just paid out nothing.
	local breakdown = self:_formatStolenBreakdown(stolenByTier)
	local contractorMessage = if breakdown ~= ""
		then string.format("Your hit landed. You received %d barrels: %s.", barrelsStolen, breakdown)
		else string.format("Your hit landed. Pirates stole %d barrels.", barrelsStolen)

	-- Look up the contractor's name for the victim's banner text. Prefer
	-- `DisplayName` (matches what the victim sees over the contractor's head /
	-- in chat); fall back to `Name`, then a generic label if the contractor has
	-- already left the server before the hit resolves.
	local contractorPlayer = Players:GetPlayerByUserId(contractorUserId)
	local contractorDisplayName = "another captain"
	if contractorPlayer then
		local dn = contractorPlayer.DisplayName
		if typeof(dn) == "string" and dn ~= "" then
			contractorDisplayName = dn
		else
			contractorDisplayName = contractorPlayer.Name
		end
	end
	-- Steal percent string (e.g. "50%") sourced from `HitContractConfig` so the
	-- victim banner copy and the broker pitch label can never drift apart.
	local stealPercent = HitContractConfig.formatStealPercent()
	local victimMessage = string.format(
		"You got raided by %s and lost %s of your barrels to them!",
		contractorDisplayName,
		stealPercent
	)

	self:_emitPirateHitAlert(ownerUserId, victimMessage, {
		kind = "victim",
		stolenByTier = stolenByTier,
		barrelsStolen = barrelsStolen,
		contractId = contractId,
		contractorUserId = contractorUserId,
		contractorDisplayName = contractorDisplayName,
	})
	-- `kind = "contractor"` tells `PirateHireClient` to use the gold locked-status
	-- treatment + `UiSfx.playPirateHitContract()` instead of the default red status.
	self:_emitPirateHitAlert(contractorUserId, contractorMessage, {
		kind = "contractor",
		stolenByTier = stolenByTier,
		barrelsStolen = barrelsStolen,
		contractId = contractId,
	})

	if barrelsStolen > 0 then
		self:_deliverContractStolenOil(contractorUserId, stolenByTier)
	end

	-- Telemetry §6.3 — fire BOTH sides of the contract hit. Victim side
	-- (`shipment_pirate_hit`) accounts for cargo loss; contractor side
	-- (`shipment_pirate_hit_payout`) accounts for the stolen oil that
	-- routed into their warehouse via `_deliverContractStolenOil` above.
	pcall(function()
		local victimPlayer = Players:GetPlayerByUserId(ownerUserId)
		Telemetry.Track(victimPlayer, "shipment_pirate_hit", {
			shipmentId = shipment.shipmentId,
			contractorUserId = contractorUserId,
			stolenByTier = stolenByTier,
			stolenTotal = barrelsStolen,
		})
		local contractorPlayerForTelemetry = Players:GetPlayerByUserId(contractorUserId)
		Telemetry.Track(contractorPlayerForTelemetry, "shipment_pirate_hit_payout", {
			contractId = contractId,
			victimUserId = ownerUserId,
			stolenByTier = stolenByTier,
			stolenTotal = barrelsStolen,
		})
	end)

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

--- Handle the client's interactive pirate raid result. Validates the payload,
--- computes proportional barrel loss based on how many pirates the player slapped,
--- and applies the final deduction.
function OilShipmentService:_handlePirateRaidInteractiveResult(player: Player, payload: { [string]: any })
	if typeof(payload) ~= "table" then
		return
	end
	local raidToken = payload.raidToken
	if typeof(raidToken) ~= "string" then
		return
	end
	local slappedIds = payload.slappedPirateIds
	if typeof(slappedIds) ~= "table" then
		return
	end

	-- Find the matching shipment context by raidToken
	local matchShipmentId: string? = nil
	local matchCtx: { [string]: any }? = nil
	for sid, ctx in pairs(self._shipmentContexts) do
		local pending = ctx.pendingInteractiveRaid
		if pending and pending.raidToken == raidToken then
			-- Verify player is the owner via _activeShipmentByOwner
			if self._activeShipmentByOwner[player.UserId] == sid then
				matchShipmentId = sid
				matchCtx = ctx
			end
			break
		end
	end

	if not matchCtx or not matchShipmentId then
		if RunService:IsStudio() then
			warn("[PirateRaidDebug][Server] Interactive result rejected: no matching pending raid for token", raidToken)
		end
		return
	end

	local pending = matchCtx.pendingInteractiveRaid
	if not pending then
		return
	end

	local pirateCount = pending.pirateCount

	-- Validate slapped pirate IDs: unique integers in [1, pirateCount]
	local validSlapped: { [number]: boolean } = {}
	local slappedCount = 0
	for _, id in ipairs(slappedIds) do
		local idx = tonumber(id)
		if idx and idx >= 1 and idx <= pirateCount and idx == math.floor(idx) and not validSlapped[idx] then
			validSlapped[idx] = true
			slappedCount += 1
		end
	end
	slappedCount = math.min(slappedCount, pirateCount)

	-- Store the result on the pending raid. The voyage-loop timeout checker
	-- (_checkPendingInteractiveRaidTimeout) will see .clientResult and apply
	-- proportional loss instead of full loss, because it has the shipment object.
	pending.clientResult = {
		slappedCount = slappedCount,
	}
	pending.resumeAfterResultAt = workspace:GetServerTimeNow() + (tonumber(pending.resumeDelaySeconds) or 0)
	-- Mark as resolved so timeout applies the result immediately on next tick
	pending.expiresAt = 0

	if RunService:IsStudio() then
		print(string.format(
			"[PirateRaidDebug][Server] Interactive result received: slapped=%d/%d — queued for voyage loop to apply",
			slappedCount, pirateCount
		))
	end
end

--- Check for expired interactive pirate raids in the voyage loop. If the client
--- never reports (AFK/disconnect), apply full barrel loss after the timeout.
--- Checks the pending interactive raid on this shipment's context.
--- Called each frame from the voyage loop. Handles two cases:
--- 1. Client sent result (.clientResult set) — apply proportional loss
--- 2. Timeout expired — apply full loss (AFK/disconnect)
function OilShipmentService:_checkPendingInteractiveRaidTimeout(shipment, ctx: { [string]: any }?)
	-- pendingInteractiveRaid lives on the voyage context now
	local ctxToUse = ctx
	if not ctxToUse then
		-- Fallback: look up by shipmentId
		ctxToUse = self._shipmentContexts[shipment.shipmentId]
	end
	if not ctxToUse then
		return
	end
	local pending = ctxToUse.pendingInteractiveRaid
	if not pending then
		return
	end
	if workspace:GetServerTimeNow() < pending.expiresAt then
		return
	end

	ctxToUse.pendingInteractiveRaid = nil

	-- Determine loss fraction based on whether client reported
	local lossFrac = pending.resolvedLossFrac
	local clientResult = pending.clientResult
	if clientResult then
		-- Proportional: only un-slapped pirates steal
		local slappedCount = clientResult.slappedCount or 0
		local pirateCount = pending.pirateCount or 1
		local unsaved = pirateCount - slappedCount
		lossFrac = pending.resolvedLossFrac * (unsaved / pirateCount)
		if RunService:IsStudio() then
			print(string.format("[PirateRaidDebug][Server] Interactive result applied: slapped=%d/%d adjustedFrac=%.3f",
				slappedCount, pirateCount, lossFrac))
		end
	else
		if RunService:IsStudio() then
			warn("[PirateRaidDebug][Server] Interactive raid TIMEOUT — full loss")
		end
	end

	local barrelsStolen = 0
	local stolenByTier: { [string]: number } = {}
	if lossFrac > 0 then
		barrelsStolen, stolenByTier = self:_applyLooseBarrelLoss(shipment, lossFrac)
	end
	if barrelsStolen > 0 then
		self:_emitManifestHudSnapshot(shipment, {
			title = ManifestIncidentTitle.fromEventId(pending.defId),
			eventId = pending.defId,
			totalLoss = false,
			lossOilByTier = stolenByTier,
		})
	end
	if RunService:IsStudio() then
		print(string.format("[PirateRaidDebug][Server] Barrel loss applied: %d barrels stolen", barrelsStolen))
	end
end

--- Pause a shipment ship for a cinematic strait event (CoastGuard inspection,
--- PirateRaid boarding) WITHOUT yanking the player off the deck.
---
--- The naive "snap-anchor" approach (`rootPart.Anchored = true` mid-voyage)
--- zeros the boat's `AssemblyLinearVelocity` instantly. The player character
--- standing on the deck is a separate physics assembly though — it keeps the
--- prior deck velocity and slides forward across the deck (reported as
--- "dragged toward the front of the ship by an invisible force"). Letting
--- `AlignPosition` brake the boat over a short window first gives the
--- Humanoid floor-velocity tracker time to follow the deck to a stop, after
--- which anchoring is safe. We also re-pin the AlignPosition target to the
--- final root position so the unanchor moment doesn't yank the boat forward
--- toward a now-stale target before `_updateShipPosition` resumes.
---
--- DIAGNOSTIC (April 2026): user reports a CONTINUOUS pull on their character
--- during CG / PirateRaid events even though the boat is visibly anchored,
--- and the pull is TOWARD the cosmetic NPC ship — not the bow. This is
--- inconsistent with inertia. The brake-then-anchor logic below stays, but
--- we additionally periodically snapshot the owner character's physics
--- (HRP velocity, SeatPart, attached BodyMovers/Constraints, FloorMaterial)
--- during the freeze so we can identify whatever is actually pulling them.
--- Toggle via `Constants.StraitEventsDebug.LogFreezeCharacterSnapshot`.
local FREEZE_BRAKE_SECONDS = 0.35
local FREEZE_SNAPSHOT_INTERVAL_SECONDS = 0.5
local FREEZE_EARLY_EXIT_POLL_SECONDS = 0.1

--- After the cinematic freeze ends and the boat un-anchors, eases
--- `alignPos.Position` from the boat's current resting position out to the
--- voyage path target over this window. Without the ramp, the next
--- `_updateShipPosition` call snaps the AlignPosition target straight to
--- `s_lead` (often 30-60 studs ahead, since the lead carrot keeps creeping
--- during the time-shifted voyage clock). With Responsiveness=8 and
--- MaxVelocity=200, the boat blasts from 0 to cruise speed inside a single
--- physics step. The player's character (a separate physics assembly
--- standing on the deck) doesn't accelerate with it: the Humanoid
--- floor-velocity tracker only copies platform velocity into HRP on the
--- *next* simulation step, so for ~1-2 frames the deck slides forward
--- underneath the player and they end up shoved toward the stern. Ramping
--- `alignPos.Position` lets the boat accelerate gradually so the floor
--- mechanic can follow without dropping the player.
local FREEZE_RESUME_RAMP_SECONDS = 1.0

local function describePhysicsHazardsOn(inst: Instance, label: string): { string }
	local lines: { string } = {}
	local function add(s: string)
		table.insert(lines, s)
	end
	local hrpVel: Vector3? = nil
	local hrpFloorMat: Enum.Material? = nil
	local seatPartName: string? = nil
	local hrp: BasePart? = nil
	for _, d in ipairs(inst:GetDescendants()) do
		if d:IsA("BasePart") and d.Name == "HumanoidRootPart" then
			hrp = d :: BasePart
			hrpVel = (d :: BasePart).AssemblyLinearVelocity
		end
		if d:IsA("Humanoid") then
			local h = d :: Humanoid
			hrpFloorMat = h.FloorMaterial
			if h.SeatPart then
				seatPartName = h.SeatPart:GetFullName()
			end
		end
	end
	add(string.format(
		"  [%s] HRP=%s vel=%s floor=%s seatPart=%s",
		label,
		hrp and hrp:GetFullName() or "nil",
		hrpVel and string.format("(%.1f,%.1f,%.1f) |%.1f|", hrpVel.X, hrpVel.Y, hrpVel.Z, hrpVel.Magnitude) or "nil",
		hrpFloorMat and tostring(hrpFloorMat.Name) or "nil",
		seatPartName or "nil"
	))
	for _, d in ipairs(inst:GetDescendants()) do
		if d:IsA("BodyMover") then
			add(string.format("  [%s] BodyMover %s '%s' parent=%s", label, d.ClassName, d.Name, d.Parent and d.Parent:GetFullName() or "nil"))
		elseif d:IsA("Constraint") then
			-- Strip-and-flag movement / force-applying constraints (we keep welds + motors)
			local cn = d.ClassName
			if cn == "AlignPosition" or cn == "AlignOrientation"
				or cn == "LinearVelocity" or cn == "AngularVelocity"
				or cn == "VectorForce" or cn == "Torque" or cn == "LineForce"
				or cn == "RopeConstraint" or cn == "SpringConstraint" or cn == "RodConstraint" then
				add(string.format("  [%s] Constraint %s '%s' parent=%s", label, cn, d.Name, d.Parent and d.Parent:GetFullName() or "nil"))
			end
		elseif d:IsA("Weld") then
			-- Legacy welds added at runtime are suspicious if they connect to something OUTSIDE the character.
			local w = d :: Weld
			local p0, p1 = w.Part0, w.Part1
			if p0 and p1 then
				local p0Outside = not p0:IsDescendantOf(inst)
				local p1Outside = not p1:IsDescendantOf(inst)
				if p0Outside or p1Outside then
					add(string.format(
						"  [%s] EXTERNAL WELD '%s' Part0=%s Part1=%s",
						label,
						d.Name,
						p0 and p0:GetFullName() or "nil",
						p1 and p1:GetFullName() or "nil"
					))
				end
			end
		end
	end
	return lines
end

--- Reassigns every `BasePart` under `char` to the supplied collision group,
--- stamping the previous group on each part as an attribute so we can put
--- it back exactly. Idempotent: a second call won't double-stamp the
--- attribute, and `restorePlayerCharacterCollisionGroup` no-ops on parts
--- without the stamp.
---
--- Server-side writes to `BasePart.CollisionGroup` are authoritative and
--- replicate to all clients (including the client simulating its own
--- character), so the no-collide rule we register in `Init` against the
--- cosmetic-NPC group takes effect at the engine level — even if the
--- client-side cosmetic group tagging in `StraitWaypointWorldFx`
--- (`applyStraitNpcGhostParts`) misses a part on a given Heartbeat sweep.
local PLAYER_PRIOR_GROUP_ATTR = "PriorCollisionGroupForStraitEvent"

local function applyPlayerCharacterCollisionGroup(char: Model?, group: string)
	if not char then return end
	for _, d in ipairs(char:GetDescendants()) do
		if d:IsA("BasePart") then
			-- Don't re-stamp if already swapped (e.g. respawn mid-freeze
			-- after we already stamped a new char).
			if d:GetAttribute(PLAYER_PRIOR_GROUP_ATTR) == nil then
				d:SetAttribute(PLAYER_PRIOR_GROUP_ATTR, d.CollisionGroup)
			end
			d.CollisionGroup = group
		end
	end
end

local function restorePlayerCharacterCollisionGroup(char: Model?)
	if not char then return end
	for _, d in ipairs(char:GetDescendants()) do
		if d:IsA("BasePart") then
			local prior = d:GetAttribute(PLAYER_PRIOR_GROUP_ATTR)
			if typeof(prior) == "string" then
				d.CollisionGroup = prior
				d:SetAttribute(PLAYER_PRIOR_GROUP_ATTR, nil)
			end
		end
	end
end

--- Apply the voyage collision group (`PlayerInStraitEvent`) to the owner's
--- current character. Called from `_runShipment` after `TeleportOwnerToSeat`
--- so the owner walks the deck normally but ignores docks, MapDecor props,
--- parked boats, and cosmetic strait-event NPCs for the entire voyage. The
--- pair-rule matrix is registered in `Init`; this method only stamps the
--- group on character parts.
---
--- We deliberately DO NOT auto-reapply on respawn. A player who dies
--- mid-voyage typically respawns at warehouse / plot, not back on the
--- deck — re-tagging that land character with `PlayerInStraitEvent` would
--- make them clip THROUGH the dock pier on land, which is wrong. We just
--- track a placeholder connection slot so the cleanup symmetry in
--- `_restoreOwnerOnVoyageCollisionGroup` can disconnect it without a
--- nil check on every call site.
---
--- Idempotent: a second call won't double-stamp the prior-group attribute
--- (see `applyPlayerCharacterCollisionGroup`). Safe to call from both
--- `_runShipment` and `_freezeShipForStraitEventCinematic` — the latter
--- is now redundant (voyage-wide application covers it) but kept as a
--- belt-and-suspenders write in case `_runShipment` skipped the apply
--- (e.g. owner offline at dispatch).
function OilShipmentService:_applyOwnerOnVoyageCollisionGroup(player: Player)
	local pieGroup = self._playerInStraitEventGroup
	if not pieGroup then return end
	local char = player and player.Character
	if not char then return end
	applyPlayerCharacterCollisionGroup(char, pieGroup)
	-- Slot the connection table even though we don't currently wire a
	-- `CharacterAdded` re-apply. Keeps `_restoreOwnerOnVoyageCollisionGroup`
	-- unconditional and prevents a future "wire respawn re-apply" patch
	-- from leaking connections if it forgets to disconnect on cleanup.
	if self._voyageCharRespawnConnByUserId then
		self._voyageCharRespawnConnByUserId[player.UserId] = nil
	end
end

--- Restore the owner character's prior collision group at voyage end.
--- Called from `_handleOwnerAfterSuccessfulShipmentFinish` (success) and
--- from the `voyageAborted` branch in `_runShipment` (total loss). Safe
--- to call when no apply ever happened (the per-part attribute check
--- inside `restorePlayerCharacterCollisionGroup` no-ops on un-stamped
--- parts) and when the player has gone offline.
function OilShipmentService:_restoreOwnerOnVoyageCollisionGroup(userId: number)
	local conn = self._voyageCharRespawnConnByUserId and self._voyageCharRespawnConnByUserId[userId]
	if conn then
		conn:Disconnect()
	end
	if self._voyageCharRespawnConnByUserId then
		self._voyageCharRespawnConnByUserId[userId] = nil
	end
	local player = Players:GetPlayerByUserId(userId)
	if player then
		restorePlayerCharacterCollisionGroup(player.Character)
	end
end

function OilShipmentService:_freezeShipForStraitEventCinematic(
	shipmentId: string,
	durationSec: number,
	shouldEndEarly: (() -> boolean)?
): number
	local freezeStartedAt = os.clock()
	local shipState = self._activeShips[shipmentId]
	local rootPart: BasePart? = shipState and shipState.root
	local alignPos = shipState and shipState.alignPos
	local wasAnchored = rootPart and rootPart.Anchored

	-- Find the owner player + character (for diagnostic snapshots).
	local ownerUserId = self._ownerUserIdByShipmentId and self._ownerUserIdByShipmentId[shipmentId]
	if not ownerUserId then
		for uid, sid in pairs(self._activeShipmentByOwner or {}) do
			if sid == shipmentId then ownerUserId = uid; break end
		end
	end
	local ownerPlayer: Player? = nil
	if typeof(ownerUserId) == "number" then
		ownerPlayer = Players:GetPlayerByUserId(ownerUserId)
	end
	local ownerChar: Model? = ownerPlayer and ownerPlayer.Character or nil

	local dbg = Constants.StraitEventsDebug
	local snapshotEnabled = dbg and dbg.LogFreezeCharacterSnapshot == true

	if snapshotEnabled then
		print(string.format(
			"[FreezeShip] >>> ENTER shipment=%s owner=%s rootPos=%s rootVel=%s alreadyAnchored=%s",
			tostring(shipmentId),
			ownerPlayer and (ownerPlayer.Name .. "/" .. tostring(ownerUserId)) or "nil",
			rootPart and string.format("(%.1f,%.1f,%.1f)", rootPart.Position.X, rootPart.Position.Y, rootPart.Position.Z) or "nil",
			rootPart and string.format("(%.1f,%.1f,%.1f) |%.1f|", rootPart.AssemblyLinearVelocity.X, rootPart.AssemblyLinearVelocity.Y, rootPart.AssemblyLinearVelocity.Z, rootPart.AssemblyLinearVelocity.Magnitude) or "nil",
			tostring(wasAnchored)
		))
		if ownerChar then
			for _, l in ipairs(describePhysicsHazardsOn(ownerChar, "PRE-BRAKE")) do
				print(l)
			end
		end
	end

	if rootPart and not wasAnchored then
		if alignPos then
			alignPos.Position = rootPart.Position
		end
		task.wait(FREEZE_BRAKE_SECONDS)
	end

	if rootPart then
		rootPart.Anchored = true
	end

	-- Voyage collision group (`PlayerInStraitEvent`) is now applied for
	-- the entire voyage in `_runShipment` after `TeleportOwnerToSeat` and
	-- restored at voyage completion / total loss — see
	-- `_applyOwnerOnVoyageCollisionGroup`. The cinematic used to do its
	-- own apply / restore here because the group only existed for the
	-- freeze window, but voyage-wide application covers it (and a
	-- restore at cinematic end would now incorrectly drop the group
	-- mid-voyage, re-colliding the player with docks / MapDecor).
	-- Re-assert the group as a belt-and-suspenders write in case the
	-- voyage-start apply was skipped (e.g. owner went offline at
	-- dispatch then reconnected mid-voyage). Idempotent.
	local pieGroup = self._playerInStraitEventGroup
	ownerChar = ownerPlayer and ownerPlayer.Character or nil
	if pieGroup and ownerChar then
		applyPlayerCharacterCollisionGroup(ownerChar, pieGroup)
	end

	if snapshotEnabled and ownerChar then
		for _, l in ipairs(describePhysicsHazardsOn(ownerChar, "POST-ANCHOR")) do
			print(l)
		end
	end

	-- Periodic snapshot of the owner character during the cinematic hold.
	-- Lets us see if anything attaches mid-event (e.g. seat capture, weld
	-- from a sweeping NPC ship part, runtime BodyMover) that would explain
	-- a continuous pull toward the cosmetic NPC ship.
	local function shouldBreakHold(): boolean
		if not shouldEndEarly then
			return false
		end
		local ok, result = pcall(shouldEndEarly)
		return ok and result == true
	end

	local holdSec = math.max(0, durationSec - FREEZE_BRAKE_SECONDS)
	if snapshotEnabled and ownerChar and holdSec > 0 then
		local elapsed = 0
		while elapsed < holdSec do
			if shouldBreakHold() then
				break
			end
			local step = math.min(FREEZE_SNAPSHOT_INTERVAL_SECONDS, holdSec - elapsed)
			task.wait(step)
			elapsed += step
			-- Re-resolve character (may have respawned)
			ownerChar = ownerPlayer and ownerPlayer.Character or nil
			if ownerChar then
				for _, l in ipairs(describePhysicsHazardsOn(ownerChar, string.format("HOLD t=%.1fs", elapsed))) do
					print(l)
				end
			end
		end
	else
		local elapsed = 0
		while elapsed < holdSec do
			if shouldBreakHold() then
				break
			end
			local step = math.min(FREEZE_EARLY_EXIT_POLL_SECONDS, holdSec - elapsed)
			task.wait(step)
			elapsed += step
		end
	end

	if rootPart and not wasAnchored then
		if alignPos then
			alignPos.Position = rootPart.Position
		end
		rootPart.Anchored = false
		--- Stamp the resume-ramp window so `_updateShipPosition` eases the
		--- AlignPosition target out from the boat's current resting position
		--- instead of snapping straight to the voyage `s_lead`. See
		--- `FREEZE_RESUME_RAMP_SECONDS` doc-comment for why this prevents
		--- the player from being slid toward the stern at resume.
		local shipState = self._activeShips[shipmentId]
		if shipState then
			shipState.resumeRampStartClock = os.clock()
			shipState.resumeRampStartPos = rootPart.Position
		end
	end

	-- DO NOT restore the voyage collision group here. The player is still
	-- on a voyage at this point (the cinematic is a sub-phase of the
	-- voyage, not the end of it). Restoring back to `Default` would
	-- re-collide them with docks, MapDecor, and parked boats for the
	-- remainder of the trip. The voyage-end handlers
	-- (`_handleOwnerAfterSuccessfulShipmentFinish` and the
	-- `voyageAborted` branch of `_runShipment`) own the restore.

	if snapshotEnabled then
		print(string.format("[FreezeShip] <<< EXIT shipment=%s", tostring(shipmentId)))
		if ownerPlayer and ownerPlayer.Character then
			for _, l in ipairs(describePhysicsHazardsOn(ownerPlayer.Character, "POST-UNANCHOR")) do
				print(l)
			end
		end
	end
	return os.clock() - freezeStartedAt
end

--- FTUE tutorial mine showcase: surfaces mines around the boat with every
--- outcome forced to `didHit = false` so the player sees the threat
--- without any cargo loss. Mirrors the `def.mineEvent` block inside
--- `_handleStraitWaypointTrigger` but skips total-loss / barrel-loss paths.
--- Caller advances `voyageClock.startTime` so the stuck detector in
--- `_runShipment` does not count this wait against voyage time.
function OilShipmentService:_runFtueTutorialMineShowcase(
	shipment,
	ownerUserId: number,
	worldPosition: Vector3,
	voyageClock: { startTime: number },
	boat: Instance
)
	local def = StraitEventCatalog.GetById("MineStrike")
	if not def then
		return
	end
	local mc = StraitEventCatalog.MineConfig
	local mineCount = mc.MineCount or 15
	local skinFx = BoatCatalog.GetBoat(shipment.boatId).fxParticleScale
	local particleFxScale = ParticleFxScale.ComputePayloadScale(boat, skinFx)
	local rng = Random.new()
	local playtestTitle = StraitEventCatalog.GetPlaytestTitle(def)

	-- Spread mines wide around the boat (no near-hit override) so every
	-- mine is in the safe surfacing ring. The regular mine path picks one
	-- of the first three mines and pulls it in front of the ship on a hit;
	-- we skip that branch entirely.
	local minePositions = {}
	local radiusMin = mc.SpawnRadiusMin or 30
	local radiusMax = mc.SpawnRadiusMax or 120
	for mi = 1, mineCount do
		local angle = (mi / mineCount) * math.pi * 2 + rng:NextNumber(-0.4, 0.4)
		local dist = rng:NextNumber(radiusMin, radiusMax)
		local offset = Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist)
		table.insert(minePositions, {
			x = worldPosition.X + offset.X,
			y = worldPosition.Y,
			z = worldPosition.Z + offset.Z,
		})
	end

	self:_emitShipmentEvent("MineStrikeEvent", {
		ownerUserId = ownerUserId,
		shipmentId = shipment.shipmentId,
		eventId = def.id,
		displayName = def.displayName,
		playtestTitle = playtestTitle,
		severity = "Medium",
		didHit = false,
		minePositions = minePositions,
		riseSeconds = mc.RiseSeconds,
		worldPosition = { x = worldPosition.X, y = worldPosition.Y, z = worldPosition.Z },
		particleFxScale = particleFxScale,
	})

	local totalPause = (mc.RiseSeconds or 0) + (mc.PauseAfterSurface or 0) + 1
	task.wait(totalPause)
	voyageClock.startTime += totalPause

	pcall(function()
		local ownerForTelemetry = Players:GetPlayerByUserId(ownerUserId)
		Telemetry.Track(ownerForTelemetry, "ftue_tutorial_strait_showcase_fired", {
			shipmentId = shipment.shipmentId,
			eventId = "MineStrike",
		})
	end)
end

--- FTUE tutorial coast-guard showcase: fires the inspection cinematic and
--- freezes the boat for `SequenceDuration`, identical to the normal coast
--- guard path which already has no barrel-loss logic — we just bypass the
--- occurrence / bracket roll so the protected voyage runs it on cue.
function OilShipmentService:_runFtueTutorialCoastGuardShowcase(
	shipment,
	ownerUserId: number,
	worldPosition: Vector3,
	voyageClock: { startTime: number },
	boat: Instance
)
	local def = StraitEventCatalog.GetById("CoastGuardInspection")
	if not def then
		return
	end
	local cfg = StraitEventCatalog.CoastGuardInspectionConfig
	local skinFx = BoatCatalog.GetBoat(shipment.boatId).fxParticleScale
	local particleFxScale = ParticleFxScale.ComputePayloadScale(boat, skinFx)
	local rng = Random.new()
	local playtestTitle = StraitEventCatalog.GetPlaytestTitle(def)
	local approachSide = rng:NextNumber() < 0.5 and 1 or -1

	self:_emitShipmentEvent("CoastGuardInspectionEvent", {
		ownerUserId = ownerUserId,
		shipmentId = shipment.shipmentId,
		eventId = def.id,
		displayName = def.displayName,
		playtestTitle = playtestTitle,
		severity = "Low",
		approachSide = approachSide,
		worldPosition = { x = worldPosition.X, y = worldPosition.Y, z = worldPosition.Z },
		particleFxScale = particleFxScale,
	})
	self:_freezeShipForStraitEventCinematic(shipment.shipmentId, cfg.SequenceDuration)
	voyageClock.startTime += cfg.SequenceDuration

	pcall(function()
		local ownerForTelemetry = Players:GetPlayerByUserId(ownerUserId)
		Telemetry.Track(ownerForTelemetry, "ftue_tutorial_strait_showcase_fired", {
			shipmentId = shipment.shipmentId,
			eventId = "CoastGuardInspection",
		})
	end)
end

--- FTUE tutorial storm showcase: fires the thunderstorm cinematic VFX/SFX
--- with no delay roll and no barrel loss. Mirrors the `def.stormEvent`
--- block in `_handleStraitWaypointTrigger` but skips the `didDelay` /
--- `didBarrelLoss` rolls and the `_applyLooseBarrelLoss` call so the
--- protected voyage just sees rain + lightning + thunder. The base
--- sequence duration is the same as the normal storm so the audio
--- timing reads identically. Caller advances `voyageClock.startTime`
--- so the stuck detector in `_runShipment` doesn't count this wait
--- against voyage time.
function OilShipmentService:_runFtueTutorialStormShowcase(
	shipment,
	ownerUserId: number,
	laneWaypointIndex: number,
	worldPosition: Vector3,
	voyageClock: { startTime: number },
	boat: Instance
)
	local def = StraitEventCatalog.GetById("Storm")
	if not def then
		return
	end
	local sc = StraitEventCatalog.StormConfig
	local baseSequenceSeconds = math.max(0, tonumber(sc.BaseSequenceSeconds) or 0)
	local skinFx = BoatCatalog.GetBoat(shipment.boatId).fxParticleScale
	local particleFxScale = ParticleFxScale.ComputePayloadScale(boat, skinFx)
	local playtestTitle = StraitEventCatalog.GetPlaytestTitle(def)

	self:_emitShipmentEvent("StormEvent", {
		ownerUserId = ownerUserId,
		shipmentId = shipment.shipmentId,
		eventId = def.id,
		displayName = def.displayName,
		playtestTitle = playtestTitle,
		severity = "Medium",
		laneWaypointIndex = laneWaypointIndex,
		worldPosition = { x = worldPosition.X, y = worldPosition.Y, z = worldPosition.Z },
		didDelay = false,
		delaySeconds = 0,
		didBarrelLoss = false,
		barrelsLost = 0,
		lostDeckBarrels = {},
		barrelLossFraction = 0,
		sequenceSeconds = baseSequenceSeconds,
		particleFxScale = particleFxScale,
	})

	if baseSequenceSeconds > 0 then
		task.wait(baseSequenceSeconds)
		voyageClock.startTime += baseSequenceSeconds
	end

	pcall(function()
		local ownerForTelemetry = Players:GetPlayerByUserId(ownerUserId)
		Telemetry.Track(ownerForTelemetry, "ftue_tutorial_strait_showcase_fired", {
			shipmentId = shipment.shipmentId,
			eventId = "Storm",
		})
	end)
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
	if (shipment :: any).ftueTutorialSuppressStraitIncidents == true then
		-- Tutorial showcase: at configured waypoints, fire harmless
		-- VFX/SFX-only versions of strait events so the player sees the
		-- threat fantasy without losing any cargo. Every other waypoint
		-- stays fully suppressed.
		local showcases = (shipment :: any).ftueTutorialShowcasesByLaneWaypoint
		if typeof(showcases) == "table" then
			local eventId = showcases[laneWaypointIndex]
			if eventId == "MineStrike" then
				self:_runFtueTutorialMineShowcase(shipment, ownerUserId, worldPosition, voyageClock, boat)
			elseif eventId == "CoastGuardInspection" then
				self:_runFtueTutorialCoastGuardShowcase(shipment, ownerUserId, worldPosition, voyageClock, boat)
			elseif eventId == "Storm" then
				self:_runFtueTutorialStormShowcase(shipment, ownerUserId, laneWaypointIndex, worldPosition, voyageClock, boat)
			end
		end
		return false
	end
	-- Run-upgrade: Security Personnel deflects every strait incident on this
	-- voyage. Stamped at dispatch by `_handleDispatch` after consuming one
	-- inventory stack via `SecurityPersonnelService:TryConsumeForDispatch`.
	-- Short-circuit BEFORE rolling occurrence so debug overrides
	-- (`ForceOccurrenceAtWaypoint`) also respect the immunity — design intent
	-- is "this shipment is untouchable", not "events still fire but get
	-- absorbed", so QA toggles shouldn't bypass it either.
	if (shipment :: any).eventImmunity == true then
		pcall(function()
			local ownerForTelemetry = Players:GetPlayerByUserId(ownerUserId)
			Telemetry.Track(ownerForTelemetry, "security_personnel_deflected", {
				shipmentId = shipment.shipmentId,
				laneWaypointIndex = laneWaypointIndex,
				eventIdThatWouldHaveFired = nil,
				severity = nil,
			})
		end)
		return false
	end
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

	-- Server-wide global event override (`ForceStraitEvent` when present in
	-- the catalog). Resolved BEFORE the bracket allow-list and occurrence-chance
	-- gates because the design intent is "spike this event's frequency for
	-- the duration" — gating it through the per-bracket sparse roll would
	-- make a forced strait event essentially invisible during `Open` strait
	-- (3 trigger waypoints × 25% = ~0.75 events/voyage, most short voyages
	-- see zero). Treat an active force the same way as the dev
	-- `ForceOccurrenceAtWaypoint` flag: every reachable waypoint fires.
	--
	-- We DO still respect:
	--   * `(shipment :: any).eventImmunity` (Security Personnel) above — a
	--     defended run still sees no strait incident during a global force,
	--     which is the design intent (defensive purchases still work).
	--   * `ftueTutorialSuppressStraitIncidents` above — tutorial escort
	--     shipments stay clean.
	--
	-- Severity for the override pulls from the engine bracket so impact
	-- still scales naturally (Open = Low pirates, Closed = Medium/High);
	-- this matches what `dbg.ForcePirateRaid` produces today (a Medium
	-- severity by default), but bracket-derived severity is more honest
	-- because the player's voyage is still in that strait state.
	local globalForcedStraitEventId: string? = nil
	if self._globalEventService then
		local forcedId = self._globalEventService:GetForcedStraitEventId()
		if typeof(forcedId) == "string" and forcedId ~= "" then
			globalForcedStraitEventId = forcedId
		end
	end

	-- Per-bracket allow-list gate: a waypoint that isn't enabled for the
	-- *current* bracket short-circuits before rolling occurrence. Debug
	-- `ForceOccurrenceAtWaypoint` still fires every reachable waypoint
	-- regardless of bracket so QA can validate any slot. An active global
	-- An active global ForceStraitEvent bypasses for the same reason — the
	-- event must be felt across the whole voyage.
	local triggerEnabled = StraitEventConfig.IsTriggerEnabledForBracket(bracket, laneWaypointIndex)
	if not triggerEnabled and not dbg.ForceOccurrenceAtWaypoint and not globalForcedStraitEventId then
		if log then
			print(
				string.format(
					"  [StraitShipment DEBUG] shipment=%s laneWP=%d → SKIP (laneWP not enabled for bracket %s; bracket allow-list = %s)",
					shipment.shipmentId,
					laneWaypointIndex,
					bracket,
					(function()
						local parts = {}
						for _, n in ipairs(StraitEventConfig.LaneWaypointTriggers[bracket] or {}) do
							table.insert(parts, tostring(n))
						end
						return "{" .. table.concat(parts, ",") .. "}"
					end)()
				)
			)
		end
		return false
	end

	local occurrenceChance = StraitEventConfig.GetOccurrenceChance(bracket)
	local rng = Random.new()
	local rollOcc = rng:NextNumber()
	local occurrenceHit = dbg.ForceOccurrenceAtWaypoint
		or (globalForcedStraitEventId ~= nil)
		or rollOcc < occurrenceChance

	if log then
		print(
			string.format(
				"  [StraitShipment DEBUG] shipment=%s laneWP=%d\n    strait ENGINE state: %s\n    event BRACKET (for odds/severity): %s (from engine would be: %s)%s\n    occurrence: P(hit)=%.0f%%  roll=%.4f  forceAllCrossings=%s  globalForceEvent=%s  → %s",
				shipment.shipmentId,
				laneWaypointIndex,
				engineState,
				bracket,
				bracketFromEngine,
				bracketNote == "" and "" or "\n    " .. bracketNote,
				occurrenceChance * 100,
				rollOcc,
				tostring(dbg.ForceOccurrenceAtWaypoint),
				tostring(globalForcedStraitEventId or "<none>"),
				occurrenceHit and "HIT (will roll severity)" or "MISS (no strait event this waypoint)"
			)
		)
	end

	-- Telemetry §6.3 `strait_waypoint_evaluated` — fires every crossing
	-- (sample 0.1 in `TelemetryConfig`). Captures bracket + occurrence
	-- decision so downstream queries can compute "P(event | bracket)" from
	-- the actual roll distribution rather than the configured chance.
	pcall(function()
		local ownerForTelemetry = Players:GetPlayerByUserId(ownerUserId)
		Telemetry.Track(ownerForTelemetry, "strait_waypoint_evaluated", {
			shipmentId = shipment.shipmentId,
			pathIndex = laneWaypointIndex,
			bracket = bracket,
			occurred = occurrenceHit,
		})
	end)

	if not occurrenceHit then
		return false
	end

	local severity = StraitEventConfig.RollSeverity(bracket, rng)
	local def = StraitEventCatalog.PickRandom(severity, rng)

	-- Apply the global event override now that occurrence has been forced.
	-- Severity stays bracket-derived so the gameplay impact still scales
	-- with the current strait state. If the forced id is missing from the catalog
	-- we fall back to the rolled `def` so the event still feels alive
	-- rather than silently no-op'ing.
	if globalForcedStraitEventId then
		local override = StraitEventCatalog.GetById(globalForcedStraitEventId)
		if override then
			def = override
			if log then
				print(string.format(
					"  [StraitShipment DEBUG] global event override → def=%s severity=%s (bracket=%s)",
					tostring(def.id), severity, bracket
				))
			end
		elseif log then
			warn(string.format(
				"  [StraitShipment DEBUG] global event force id %q not found in StraitEventCatalog — keeping rolled %s",
				globalForcedStraitEventId, tostring(def and def.id or "<nil>")
			))
		end
	end

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

	-- Telemetry §6.3 `strait_event_fired` — fires once per realised event
	-- (after all overrides resolve to a concrete `def`). `barrelsLost`
	-- isn't known yet (each event-type branch computes loss separately);
	-- analytics can join against `shipment_completed` /
	-- `shipment_total_loss` for the actual outcome.
	(shipment :: any).lastStraitEventId = def.id
	pcall(function()
		local ownerForTelemetry = Players:GetPlayerByUserId(ownerUserId)
		Telemetry.Track(ownerForTelemetry, "strait_event_fired", {
			shipmentId = shipment.shipmentId,
			eventId = def.id,
			displayName = def.displayName,
			severity = severity,
			bracket = bracket,
			priceMultiplierFactor = def.priceMultiplierFactor,
			pauseSeconds = def.pauseSeconds,
			totalLoss = def.totalLoss == true,
		})
	end)

	local playtestTitle = StraitEventCatalog.GetPlaytestTitle(def)

	local skinFx = BoatCatalog.GetBoat(shipment.boatId).fxParticleScale
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
		-- Freeze the boat during the event so it doesn't drift/tilt. Brakes
		-- via AlignPosition before anchoring so the player character on the
		-- deck doesn't slide forward from inertia — see
		-- `_freezeShipForStraitEventCinematic` doc-comment.
		self:_freezeShipForStraitEventCinematic(shipment.shipmentId, cfg.SequenceDuration)
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
		-- Delay the "total loss" HUD message until AFTER the kraken SFX finishes (~6s)
		task.wait(6)
		self:_emitTotalLossManifestHud(shipment, def.id)
		task.wait(cfg.SequenceDuration - 6)
		return true -- total loss
	end

	-- Special pirate raid handling: visual boarding + barrel stealing sequence
	if def.pirateEvent then
		local pc = StraitEventCatalog.PirateRaidConfig

		-- Roll potential barrel loss fraction (not applied yet for interactive mode)
		local resolvedLossFrac = def.looseBarrelLossFraction
		if def.looseBarrelLossFractionMin and def.looseBarrelLossFractionMax then
			resolvedLossFrac = rng:NextNumber(def.looseBarrelLossFractionMin, def.looseBarrelLossFractionMax)
		end
		resolvedLossFrac = resolvedLossFrac or 0

		-- Pick approach side (perpendicular to ship heading)
		local approachSide = rng:NextNumber() < 0.5 and 1 or -1

		-- Determine pirate count (same formula as client)
		local pirateCount = math.clamp(math.ceil(resolvedLossFrac * 20), 1, 5)

		-- Interactive mode: defer barrel loss until player reports slap results
		local useInteractive = pc.InteractiveEnabled == true and resolvedLossFrac > 0
		-- Need the owner player online to interact
		local ownerPlayer: Player? = nil
		if useInteractive then
			for _, p in ipairs(Players:GetPlayers()) do
				if p.UserId == ownerUserId then
					ownerPlayer = p
					break
				end
			end
			if not ownerPlayer then
				useInteractive = false
			end
		end

		if useInteractive then
			-- INTERACTIVE PATH: deferred barrel loss
			local raidToken = HttpService:GenerateGUID(false)
			-- Snapshot barrels for client animation (max possible loss)
			local maxBarrels, maxStolenByTier = self:_computeLooseBarrelLoss(shipment, resolvedLossFrac)
			local stolenDeckBarrels = self:_snapshotLostDeckBarrels(boat, maxStolenByTier, maxBarrels)

			-- Store pending interactive raid on the voyage context (not shipment — ctx is accessible from voyage loop)
			local interactionWindow = (tonumber(pc.InteractionWindowSeconds) or 9)
			local serverTimeout = interactionWindow + (tonumber(pc.ServerTimeoutBufferSeconds) or 3)
			-- Freeze for full sequence so ship stays still during the fight
			local freezeDuration = pc.SequenceDuration
			local voyageCtx = self._shipmentContexts[shipment.shipmentId]
			if voyageCtx then
				voyageCtx.pendingInteractiveRaid = {
					raidToken = raidToken,
					pirateCount = pirateCount,
					resolvedLossFrac = resolvedLossFrac,
					expiresAt = workspace:GetServerTimeNow() + serverTimeout + pc.ApproachSeconds + pc.BoardingSeconds,
					resumeDelaySeconds = math.max(0.2, (tonumber(pc.EscapeSeconds) or 4) - 1.25),
					shipmentId = shipment.shipmentId,
					defId = def.id,
				}
			end

			-- Fire interactive pirate raid event to all clients
			self:_emitShipmentEvent("PirateRaidEvent", {
				ownerUserId = ownerUserId,
				shipmentId = shipment.shipmentId,
				eventId = def.id,
				displayName = def.displayName,
				playtestTitle = playtestTitle,
				severity = severity,
				-- Interactive fields
				interactive = true,
				raidToken = raidToken,
				pirateCount = pirateCount,
				potentialBarrelsStolen = maxBarrels,
				totalLoaded = shipment.totalLoaded,
				stolenDeckBarrels = stolenDeckBarrels,
				approachSide = approachSide,
				interactionWindowSeconds = interactionWindow,
				worldPosition = { x = worldPosition.X, y = worldPosition.Y, z = worldPosition.Z },
				particleFxScale = particleFxScale,
			})

			if RunService:IsStudio() then
				print(string.format(
					"[PirateRaidDebug][Server] INTERACTIVE shipment=%s potentialLoss=%d pirateCount=%d token=%s timeout=%.1fs",
					shipment.shipmentId, maxBarrels, pirateCount, raidToken, serverTimeout
				))
			end
			if log then
				print(string.format("  [StraitShipment DEBUG] INTERACTIVE PIRATE RAID: %d potential barrels, %d pirates, side=%d, freeze %ds",
					maxBarrels, pirateCount, approachSide, math.ceil(freezeDuration)))
			end

			local freezeElapsed = self:_freezeShipForStraitEventCinematic(shipment.shipmentId, freezeDuration, function()
				local currentCtx = self._shipmentContexts[shipment.shipmentId]
				local pending = currentCtx and currentCtx.pendingInteractiveRaid
				return pending ~= nil
					and pending.clientResult ~= nil
					and workspace:GetServerTimeNow() >= (tonumber(pending.resumeAfterResultAt) or 0)
			end)
			voyageClock.startTime += math.min(freezeDuration, freezeElapsed)
			return false
		else
			-- LEGACY PATH: immediate barrel loss (non-interactive or no owner online)
			local barrelsStolen = 0
			local stolenByTier: { [string]: number } = {}
			local stolenDeckBarrels = {}
			if resolvedLossFrac > 0 then
				barrelsStolen, stolenByTier = self:_applyLooseBarrelLoss(shipment, resolvedLossFrac)
				stolenDeckBarrels = self:_snapshotLostDeckBarrels(boat, stolenByTier, barrelsStolen)
			end
			if barrelsStolen > 0 then
				self:_emitManifestHudSnapshot(shipment, {
					title = ManifestIncidentTitle.fromEventId(def.id),
					eventId = def.id,
					totalLoss = false,
					lossOilByTier = stolenByTier,
				})
			end

			self:_emitShipmentEvent("PirateRaidEvent", {
				ownerUserId = ownerUserId,
				shipmentId = shipment.shipmentId,
				eventId = def.id,
				displayName = def.displayName,
				playtestTitle = playtestTitle,
				severity = severity,
				barrelsStolen = barrelsStolen,
				totalLoaded = shipment.totalLoaded,
				stolenDeckBarrels = stolenDeckBarrels,
				approachSide = approachSide,
				worldPosition = { x = worldPosition.X, y = worldPosition.Y, z = worldPosition.Z },
				particleFxScale = particleFxScale,
			})
			if RunService:IsStudio() then
				print(string.format(
					"[PirateRaidDebug][Server] LEGACY shipment=%s barrelsStolen=%d snapshotCount=%d approachSide=%d",
					shipment.shipmentId, barrelsStolen, #stolenDeckBarrels, approachSide
				))
			end
			if log then
				print(string.format("  [StraitShipment DEBUG] PIRATE RAID: %d barrels stolen, side=%d, pausing %ds",
					barrelsStolen, approachSide, pc.SequenceDuration))
			end

			self:_freezeShipForStraitEventCinematic(shipment.shipmentId, pc.SequenceDuration)
			voyageClock.startTime += pc.SequenceDuration
			return false
		end
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
		local lostDeckBarrels = {}
		if didBarrelLoss then
			local lossMin = clamp01(tonumber(sc.BarrelLossFractionMin) or 0)
			local lossMax = math.max(lossMin, clamp01(tonumber(sc.BarrelLossFractionMax) or lossMin))
			barrelLossFraction = clamp01(rng:NextNumber(lossMin, lossMax))
			barrelsLost, stormLossByTier = self:_applyLooseBarrelLoss(shipment, barrelLossFraction)
			didBarrelLoss = barrelsLost > 0
			lostDeckBarrels = self:_snapshotLostDeckBarrels(boat, stormLossByTier, barrelsLost)
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
			lostDeckBarrels = lostDeckBarrels,
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
		-- High Winds (Low severity) uses a softer config with a BarrelLossChance gate;
		-- full Tornado (High severity) always strips barrels with no gate.
		local tc = if def.id == "HighWinds" and StraitEventCatalog.HighWindsConfig
			then StraitEventCatalog.HighWindsConfig
			else StraitEventCatalog.TornadoConfig
		local baseSequenceSeconds = math.max(0, tonumber(tc.BaseSequenceSeconds) or 0)

		local didDelay = rng:NextNumber() < clamp01(tonumber(tc.DelayChance) or 0)
		local delaySeconds = 0
		if didDelay then
			local delayMin = math.max(0, tonumber(tc.DelaySecondsMin) or 0)
			local delayMax = math.max(delayMin, tonumber(tc.DelaySecondsMax) or delayMin)
			delaySeconds = rng:NextNumber(delayMin, delayMax)
		end

		-- High Winds has a BarrelLossChance gate (50% chance of no loss at all).
		-- Full Tornado always rolls a fraction + enforces a minimum barrel floor.
		local skipLoss = tc.BarrelLossChance and rng:NextNumber() >= clamp01(tonumber(tc.BarrelLossChance) or 1)
		local lossMin = clamp01(tonumber(tc.BarrelLossFractionMin) or 0)
		local lossMax = math.max(lossMin, clamp01(tonumber(tc.BarrelLossFractionMax) or lossMin))
		local barrelLossFraction = if skipLoss then 0 else clamp01(rng:NextNumber(lossMin, lossMax))
		local minFloor = if skipLoss then 0 else math.max(0, tonumber(tc.MinBarrelsLost) or 0)
		local barrelsLost, tornadoLossByTier = self:_applyLooseBarrelLoss(shipment, barrelLossFraction, minFloor)
		local didBarrelLoss = barrelsLost > 0
		local lostDeckBarrels = self:_snapshotLostDeckBarrels(boat, tornadoLossByTier, barrelsLost)
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
			lostDeckBarrels = lostDeckBarrels,
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
	local resolvedWpLossFrac = def.looseBarrelLossFraction
	if def.looseBarrelLossFractionMin and def.looseBarrelLossFractionMax then
		resolvedWpLossFrac = rng:NextNumber(def.looseBarrelLossFractionMin, def.looseBarrelLossFractionMax)
	end
	if resolvedWpLossFrac and resolvedWpLossFrac > 0 then
		barrelsLost, waypointLossByTier = self:_applyLooseBarrelLoss(shipment, resolvedWpLossFrac)
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
	-- 1. Find root part (largest volume BasePart). Kept as the welded
	-- assembly's root so the assembly mass / inertia remain consistent
	-- with how voyages have always behaved.
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
	-- Skip welding "Paddle" parts too — they'll be assembled into wheels below
	-- and connected to root via a HingeConstraint motor so they spin while sailing.
	--
	-- CanCollide is RESPECTED here (no force-true) — see `BoatCollisionContract`
	-- for the rationale. The contract apply below handles helper neutralization
	-- and ShipmentShip group tagging uniformly with the dock spawner.
	for _, d in ipairs(boatModel:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = false
			d.CanTouch = true
			d.CanQuery = true
			if d == root then
				d.Massless = false
			elseif d:GetAttribute("IsDoor") then
				-- Door panel: don't weld, let hinge control it
				d.Massless = true
			-- Paddle parts: welded to root like everything else (we'll do paddle spin
			-- via a separate non-intrusive system later — previous rig broke movement).
			else
				d.Massless = true
				local wc = Instance.new("WeldConstraint")
				wc.Part0 = root
				wc.Part1 = d
				wc.Parent = root
			end
		end
	end

	-- Universal boat-collision rule: helpers neutralized (invisible, no collision),
	-- every other BasePart tagged `ShipmentShip` (voyage hull) so it ignores
	-- other ships, docked boats (`IdleBoat`), MarinaDock pier, and MapDecor
	-- props, while still colliding with characters (`Default`) — the owner
	-- needs to stand on the deck. `BoatDockService:CheckoutBoat` already
	-- re-tagged from `IdleBoat` → `ShipmentShip`; this pass is idempotent
	-- and covers any descendants added between checkout and now (e.g. the
	-- newly-built `ShipAtt` Attachment, though attachments aren't tagged).
	BoatCollisionContract.Apply(boatModel, "voyage")

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
	-- MaxVelocity controls how fast the hull can accelerate toward the carrot,
	-- NOT the actual ship speed (which is carrot speed = pathLen / travelSeconds).
	-- Lower values = gentler acceleration = player doesn't get pushed off deck.
	-- 60 studs/s is well above any carrot speed (fastest boat ~92 studs/s) so
	-- the hull still tracks smoothly; it just can't jerk forward violently.
	alignPos.MaxVelocity = 60
	alignPos.Responsiveness = 5
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

	-- Per-ship waterline correction: authored ships have waterline at different Ys,
	-- so a fixed +8 Y offset from _runShipment over-raises smaller ships. Compute
	-- the waterline-to-root offset from the authored model and store it so the
	-- voyage update can keep the WaterlineAnchor at sea level.
	local waterlineAnchorPart = boatModel:FindFirstChild("WaterlineAnchor", true)
	local waterlineToRootY = 0
	if waterlineAnchorPart and waterlineAnchorPart:IsA("BasePart") then
		-- Welded → offset is fixed at setup time.
		waterlineToRootY = waterlineAnchorPart.Position.Y - root.Position.Y
	end

	-- Snap root.Y so WaterlineAnchor ends at startPosition.Y (treat startPosition.Y
	-- as the desired water surface Y for this voyage).
	local correctedStartY = startPosition.Y - waterlineToRootY
	root.CFrame = CFrame.new(Vector3.new(startPosition.X, correctedStartY, startPosition.Z)) * initRotation
	alignPos.Position = Vector3.new(startPosition.X, correctedStartY, startPosition.Z)

	-- DIAGNOSTIC: verify waterline landed where we asked.
	local wlNowY = waterlineAnchorPart and waterlineAnchorPart.Position.Y or math.huge
	if RunService:IsStudio() then
		print(string.format(
			"[ShipSetup] skin=%s template=%s wlToRootY=%.2f startY_req=%.2f rootY=%.2f wlY=%.2f (delta-from-target=%.2f)",
			tostring(boatModel:GetAttribute("BoatId")),
			tostring(boatModel:GetAttribute("ShipTemplateName")),
			waterlineToRootY,
			startPosition.Y,
			root.Position.Y,
			wlNowY,
			wlNowY - startPosition.Y
		))
	end

	-- Store default yaw + bow-convention mode so _updateShipPosition matches.
	boatModel:SetAttribute("DefaultYaw", defaultYaw)
	boatModel:SetAttribute("BowAtan2Mode", (frontMarker and dockAnchor) and "xz" or "legacy")
	boatModel:SetAttribute("WaterlineToRootY", waterlineToRootY)

	boatModel.PrimaryPart = root

	-- 6. Store runtime state (including baseRotation for update function)
	self._activeShips[shipmentId] = {
		root = root,
		alignPos = alignPos,
		alignOri = alignOri,
		lastForward = bowDir,
		baseRotation = baseRotation,
		waterlineToRootY = waterlineToRootY,
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
		targetYaw = math.atan2(flatDir.X, flatDir.Z)
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

	-- Correct target Y so the per-ship WaterlineAnchor (not root center) aligns
	-- with the path water Y.
	local wlOffset = state.waterlineToRootY or 0
	local correctedTarget = Vector3.new(targetPosition.X, targetPosition.Y - wlOffset, targetPosition.Z)

	--- Resume-ramp ease: while we're inside the post-freeze window, lerp
	--- `alignPos.Position` from the boat's resting position out to the real
	--- voyage target so the boat accelerates gradually instead of jumping
	--- to cruise speed in one physics step. See `FREEZE_RESUME_RAMP_SECONDS`
	--- doc-comment in this file for why this exists. The ramp is cleared
	--- once it completes so the normal target-tracking behavior resumes.
	local rampStart = state.resumeRampStartClock
	if rampStart then
		local elapsed = os.clock() - rampStart
		if elapsed < FREEZE_RESUME_RAMP_SECONDS then
			local startPos = state.resumeRampStartPos or state.root.Position
			local t = math.clamp(elapsed / FREEZE_RESUME_RAMP_SECONDS, 0, 1)
			--- Smoothstep keeps the early frames especially gentle (where
			--- the floor-velocity tracker most needs to catch up) and then
			--- accelerates into the full target.
			local smooth = t * t * (3 - 2 * t)
			state.alignPos.Position = startPos:Lerp(correctedTarget, smooth)
		else
			state.alignPos.Position = correctedTarget
			state.resumeRampStartClock = nil
			state.resumeRampStartPos = nil
		end
	else
		state.alignPos.Position = correctedTarget
	end
	state.alignOri.CFrame = CFrame.Angles(0, yawDelta, 0) * state.baseRotation

	-- Throttled diagnostic: 1 log/sec (Studio only) — was extremely noisy on live.
	local now = os.clock()
	if RunService:IsStudio() and (state.lastDiagnosticT or 0) + 1.0 < now then
		state.lastDiagnosticT = now
		local wlPart = boatModel:FindFirstChild("WaterlineAnchor", true)
		local rootPos = state.root.Position
		local rootVel = state.root.AssemblyLinearVelocity
		local mass = state.root.AssemblyMass
		local distToTarget = (rootPos - correctedTarget).Magnitude
		local alignPosPos = state.alignPos.Position
		print(string.format(
			"[ShipUpdate] tgt=(%.1f,%.1f,%.1f) alignPos.Position=(%.1f,%.1f,%.1f) rootPos=(%.1f,%.1f,%.1f) dist=%.2f vel=%.1f assemblyRoot=%s mass=%.0f netOwner=%s",
			targetPosition.X, targetPosition.Y, targetPosition.Z,
			alignPosPos.X, alignPosPos.Y, alignPosPos.Z,
			rootPos.X, rootPos.Y, rootPos.Z,
			distToTarget,
			rootVel.Magnitude,
			tostring(state.root.AssemblyRootPart and state.root.AssemblyRootPart:GetFullName() or "nil"),
			mass,
			tostring(state.root:GetNetworkOwner())
		))
		if wlPart and wlPart:IsA("BasePart") then
			print(string.format("[ShipUpdate]   waterlineY=%.2f (target=%.2f delta=%.2f)",
				wlPart.Position.Y, targetPosition.Y, wlPart.Position.Y - targetPosition.Y))
		end
	end
end

-- Drops this shipment's voyage state (constraint refs, connections). Does NOT destroy the
-- boat model — BoatDockService:CheckinBoat is responsible for the model + cooldown lifecycle.
function OilShipmentService:_teardownShip(shipmentId: string)
	-- Drop the per-frame Heartbeat that tracks the Security Personnel
	-- guard to the moving hull. Safe to call when no mount exists (the
	-- service no-ops). MUST run before `BoatDockService:CheckinBoat`
	-- destroys the boat, otherwise the heartbeat spends one frame
	-- referencing a destroyed `boat.Parent` before bailing itself.
	if self._securityPersonnelService then
		pcall(function()
			self._securityPersonnelService:UnmountForShipment(shipmentId)
		end)
	end
	local state = self._activeShips[shipmentId]
	if not state then return end
	for _, conn in ipairs(state.connections) do
		pcall(function() conn:Disconnect() end)
	end
	-- Explicitly destroy the physics constraints so parts don't drift between
	-- teardown and the `_destroyBoat` call that follows. Without this, the
	-- AlignPosition/AlignOrientation are still alive but the state table is
	-- gone — if anything yields before Destroy, parts freeze in place.
	pcall(function()
		if state.alignPos then state.alignPos:Destroy() end
	end)
	pcall(function()
		if state.alignOri then state.alignOri:Destroy() end
	end)
	self._activeShips[shipmentId] = nil
end

-- `_createFallbackBoat` was deleted by Step 4 of the boat-progression
-- refactor — it was unreferenced (last caller removed long before; see
-- `_spawnBoat` for the live `BoatCatalog` clone-with-warn path).

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

--- Debug-dispatch helpers (`DebugDispatchMissile` through
--- `DebugDispatchUSShipSlap`) all share the same per-shipment shape:
--- pull the player's equipped skin, derive `(speedL, capL)` from the
--- boat's catalog entry via `ShipStats.LevelsForBoat(boatId)` (Step 2/4
--- of the boat-progression refactor — stats are baked per-boat in
--- `BoatCatalog`; per-player upgrade ladders are gone), then
--- resolve and dispatch. Keep the shape uniform across all 7 helpers so
--- live and debug shipments stay byte-for-byte comparable in
--- telemetry / FX.
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

	local manifest = { Crude = 30, Refined = 0, Premium = 0 }
	local st = self._oilStateService:GetState(userId)
	local boatId = if st and typeof(st.equippedBoatId) == "string" and BoatCatalog.Boats[st.equippedBoatId] then st.equippedBoatId else "Tier1Boat"
	local speedL, capL = ShipStats.LevelsForBoat(boatId)
	local stats = ShipStats.Resolve(speedL, capL)

	local shipment = {
		shipmentId = HttpService:GenerateGUID(false),
		ownerUserId = userId,
		boatId = boatId,
		shipSpeedLevel = speedL,
		shipCapacityLevel = capL,
		manifest = manifest,
		totalLoaded = 30,
		dispatchFee = 0,
		travelSeconds = stats.travelSeconds,
		eventRisk = 0,
	}

	if RunService:IsStudio() then
		print(string.format("[DebugDispatch] Launching missile test ship for %s (shipmentId=%s)", player.Name, shipment.shipmentId))
	end

	task.spawn(function()
		self:_runShipment(shipment)
		-- Restore debug flags after voyage completes
		dbg.ForceOccurrenceAtWaypoint = prevForceOcc
		dbg.ForceMissileStrike = prevForceMissile
	end)

	-- Teleport player to ship after a brief delay for it to spawn
	self:_queueDebugBoardingRetry(player, shipment.shipmentId, 2)
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

	local manifest = { Crude = 30, Refined = 0, Premium = 0 }
	local st = self._oilStateService:GetState(userId)
	local boatId = if st and typeof(st.equippedBoatId) == "string" and BoatCatalog.Boats[st.equippedBoatId] then st.equippedBoatId else "Tier1Boat"
	local speedL, capL = ShipStats.LevelsForBoat(boatId)
	local stats = ShipStats.Resolve(speedL, capL)

	local shipment = {
		shipmentId = HttpService:GenerateGUID(false),
		ownerUserId = userId,
		boatId = boatId,
		shipSpeedLevel = speedL,
		shipCapacityLevel = capL,
		manifest = manifest,
		totalLoaded = 30,
		dispatchFee = 0,
		travelSeconds = stats.travelSeconds,
		eventRisk = 0,
	}

	if RunService:IsStudio() then
		print(string.format("[DebugDispatch] Launching mine test ship for %s (shipmentId=%s)", player.Name, shipment.shipmentId))
	end

	task.spawn(function()
		self:_runShipment(shipment)
		dbg.ForceOccurrenceAtWaypoint = prevForceOcc
		dbg.ForceMineStrike = prevForceMine
	end)

	self:_queueDebugBoardingRetry(player, shipment.shipmentId, 2)
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

	local manifest = { Crude = 25, Refined = 5, Premium = 0 }
	local st = self._oilStateService:GetState(userId)
	local boatId = if st and typeof(st.equippedBoatId) == "string" and BoatCatalog.Boats[st.equippedBoatId] then st.equippedBoatId else "Tier1Boat"
	local speedL, capL = ShipStats.LevelsForBoat(boatId)
	local stats = ShipStats.Resolve(speedL, capL)

	local shipment = {
		shipmentId = HttpService:GenerateGUID(false),
		ownerUserId = userId,
		boatId = boatId,
		shipSpeedLevel = speedL,
		shipCapacityLevel = capL,
		manifest = manifest,
		totalLoaded = 30,
		dispatchFee = 0,
		travelSeconds = stats.travelSeconds,
		eventRisk = 0,
	}

	if RunService:IsStudio() then
		print(string.format("[DebugDispatch] Launching pirate test ship for %s (shipmentId=%s)", player.Name, shipment.shipmentId))
	end

	task.spawn(function()
		self:_runShipment(shipment)
		dbg.ForceOccurrenceAtWaypoint = prevForceOcc
		dbg.ForcePirateRaid = prevForcePirate
	end)

	self:_queueDebugBoardingRetry(player, shipment.shipmentId)
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
	local boatId = if st and typeof(st.equippedBoatId) == "string" and BoatCatalog.Boats[st.equippedBoatId] then st.equippedBoatId else "Tier1Boat"
	local speedL, capL = ShipStats.LevelsForBoat(boatId)
	local stats = ShipStats.Resolve(speedL, capL)

	local shipment = {
		shipmentId = HttpService:GenerateGUID(false),
		ownerUserId = userId,
		boatId = boatId,
		shipSpeedLevel = speedL,
		shipCapacityLevel = capL,
		manifest = { Crude = 28, Refined = 6, Premium = 2 },
		totalLoaded = 36,
		dispatchFee = 0,
		travelSeconds = stats.travelSeconds,
		eventRisk = 0,
	}

	if RunService:IsStudio() then
		print(string.format("[DebugDispatch] Launching storm test ship for %s (shipmentId=%s)", player.Name, shipment.shipmentId))
	end

	task.spawn(function()
		self:_runShipment(shipment)
		dbg.ForceOccurrenceAtWaypoint = prevForceOcc
		dbg.ForceStorm = prevForceStorm
	end)

	self:_queueDebugBoardingRetry(player, shipment.shipmentId)
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
	local boatId = if st and typeof(st.equippedBoatId) == "string" and BoatCatalog.Boats[st.equippedBoatId] then st.equippedBoatId else "Tier1Boat"
	local speedL, capL = ShipStats.LevelsForBoat(boatId)
	local stats = ShipStats.Resolve(speedL, capL)

	local shipment = {
		shipmentId = HttpService:GenerateGUID(false),
		ownerUserId = userId,
		boatId = boatId,
		shipSpeedLevel = speedL,
		shipCapacityLevel = capL,
		manifest = { Crude = 32, Refined = 8, Premium = 4 },
		totalLoaded = 44,
		dispatchFee = 0,
		travelSeconds = stats.travelSeconds,
		eventRisk = 0,
	}

	if RunService:IsStudio() then
		print(string.format("[DebugDispatch] Launching tornado test ship for %s (shipmentId=%s)", player.Name, shipment.shipmentId))
	end

	task.spawn(function()
		self:_runShipment(shipment)
		dbg.ForceOccurrenceAtWaypoint = prevForceOcc
		dbg.ForceTornado = prevForceTornado
	end)

	self:_queueDebugBoardingRetry(player, shipment.shipmentId)
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
	local boatId = if st and typeof(st.equippedBoatId) == "string" and BoatCatalog.Boats[st.equippedBoatId] then st.equippedBoatId else "Tier1Boat"
	local speedL, capL = ShipStats.LevelsForBoat(boatId)
	local stats = ShipStats.Resolve(speedL, capL)

	local shipment = {
		shipmentId = HttpService:GenerateGUID(false),
		ownerUserId = userId,
		boatId = boatId,
		shipSpeedLevel = speedL,
		shipCapacityLevel = capL,
		manifest = { Crude = 25, Refined = 5, Premium = 0 },
		totalLoaded = 30,
		dispatchFee = 0,
		travelSeconds = stats.travelSeconds,
		eventRisk = 0,
	}

	if RunService:IsStudio() then
		print(string.format("[DebugDispatch] Launching coast guard inspection test ship for %s (shipmentId=%s)", player.Name, shipment.shipmentId))
	end

	task.spawn(function()
		self:_runShipment(shipment)
		dbg.ForceOccurrenceAtWaypoint = prevForceOcc
		dbg.ForceCoastGuardInspection = prevForceCoastGuard
	end)

	self:_queueDebugBoardingRetry(player, shipment.shipmentId)
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
	local boatId = if st and typeof(st.equippedBoatId) == "string" and BoatCatalog.Boats[st.equippedBoatId] then st.equippedBoatId else "Tier1Boat"
	local speedL, capL = ShipStats.LevelsForBoat(boatId)
	local stats = ShipStats.Resolve(speedL, capL)

	local shipment = {
		shipmentId = HttpService:GenerateGUID(false),
		ownerUserId = userId,
		boatId = boatId,
		shipSpeedLevel = speedL,
		shipCapacityLevel = capL,
		manifest = { Crude = 25, Refined = 5, Premium = 0 },
		totalLoaded = 30,
		dispatchFee = 0,
		travelSeconds = stats.travelSeconds,
		eventRisk = 0,
	}

	if RunService:IsStudio() then
		print(string.format("[DebugDispatch] Launching US ship slap test for %s (shipmentId=%s)", player.Name, shipment.shipmentId))
	end

	task.spawn(function()
		self:_runShipment(shipment)
		dbg.ForceOccurrenceAtWaypoint = prevForceOcc
		dbg.ForceUSShipSlap = prevForceSlap
	end)

	self:_queueDebugBoardingRetry(player, shipment.shipmentId)
end

-- =================== PUBLIC HELPERS (for ArmyGeneralService) ===================

function OilShipmentService:HasActiveShipment(userId: number): boolean
	return self._activeShipmentByOwner[userId] ~= nil
end

function OilShipmentService:GetActiveShipmentForUser(userId: number)
	local shipmentId = self._activeShipmentByOwner[userId]
	if not shipmentId then return nil end
	return self._shipmentContexts[shipmentId]
end

function OilShipmentService:GetAllActiveShipments()
	return self._shipmentContexts
end

function OilShipmentService:GetActiveBoat(shipmentId: string): Instance?
	-- Find the ActiveShipmentBoat model in workspace with matching ShipmentId attribute
	for _, d in ipairs(workspace:GetDescendants()) do
		if d:IsA("Model") and d.Name == "ActiveShipmentBoat" and d:GetAttribute("ShipmentId") == shipmentId then
			return d
		end
	end
	return nil
end

function OilShipmentService:ForceDestroyShipment(shipmentId: string, reason: string)
	local ctx = self._shipmentContexts[shipmentId]
	if not ctx then return end
	-- Set a flag that the voyage loop checks to abort
	ctx._forceDestroyed = true
	ctx._forceDestroyReason = reason or "External destruction"
end

return OilShipmentService
