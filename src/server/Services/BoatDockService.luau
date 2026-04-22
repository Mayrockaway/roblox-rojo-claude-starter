--!strict
-- BoatDockService: owns the shared 8-slot dock at workspace.dOCKS.BoatSpawn{1..8}.
-- Responsibilities:
--   * Spawn an IdleBoat_<userId> at a free slot when a player joins (after plot+skin resolve).
--   * Despawn when player leaves (free slot).
--   * CheckoutBoat / CheckinBoat handoff for OilShipmentService: idle boat becomes
--     ActiveShipmentBoat for the voyage; successful deliveries respawn immediately
--     at the dock, while destroyed boats still use the cooldown penalty path.
--   * 3-second cooldown on skin swap (rejected while sailing).
--   * DeckSeat remains as authored rig geometry only; it is neutralized so players are never seated by the boat.
-- All state is in-memory; nothing persists across server restart.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CharacterTeleport = require(script.Parent.Parent.Utils.CharacterTeleport)
local BoatCollisionContract = require(script.Parent.Parent.Utils.BoatCollisionContract)
local ShipSkinCatalog = require(Shared:WaitForChild("Config"):WaitForChild("ShipSkinCatalog"))
local ShipRig = require(Shared:WaitForChild("Utils"):WaitForChild("ShipRig"))
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))
local Telemetry = require(Shared:WaitForChild("Telemetry"))

local BoatDockService = {}

local SLOT_COUNT = 8
local DESTROY_COOLDOWN_SECONDS = 1
local SKIN_SWAP_COOLDOWN_SECONDS = 3
local IDLE_Y_OFFSET = 0 -- DockAnchor lands exactly on the slot part's red square
local DEBUG_DOCK_SPAWN = false

--- Pier / spawn geometry under `dOCKS` (excluding `dOCKS.Boats`). `OilShipmentService` voyage hull uses
--- `ShipmentShip`; those parts do not collide with `MarinaDock`, but still collide with `Default` (character).
local MARINA_DOCK_GROUP = "MarinaDock"

--- `Workspace.Map.MapDecor` props (buoys, etc.): voyage hulls (`ShipmentShip`) ignore them; characters still collide.
local MAP_DECOR_GROUP = "MapDecor"

--- Idle / docked-boat hull group. `IdleBoat ↔ everything-relevant = false`.
--- See `BoatCollisionContract` doc block for the full pair matrix.
local IDLE_BOAT_GROUP = BoatCollisionContract.IdleGroup

local function getDocksRoot(): Instance?
	return Workspace:FindFirstChild("dOCKS")
		or Workspace:FindFirstChild("Docks")
		or Workspace:FindFirstChild("DOCKS")
		or Workspace:FindFirstChild("dOCKS", true)
end

local function applyMarinaDockCollisionRules()
	pcall(function()
		PhysicsService:RegisterCollisionGroup(MARINA_DOCK_GROUP)
	end)
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable("ShipmentShip", MARINA_DOCK_GROUP, false)
	end)
	-- Characters stay on deck (ShipmentShip vs Default); explicit no-ops are unnecessary but document intent.
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(MARINA_DOCK_GROUP, "Default", true)
	end)
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(MARINA_DOCK_GROUP, "Players", true)
	end)
end

local function applyMapDecorVersusShipmentShipRules()
	pcall(function()
		PhysicsService:RegisterCollisionGroup(MAP_DECOR_GROUP)
	end)
	-- Voyage boats only use `ShipmentShip`; idle boats stay Default and still collide with decor.
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable("ShipmentShip", MAP_DECOR_GROUP, false)
	end)
	-- Players / characters remain able to touch MapDecor geometry (walk, physics).
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(MAP_DECOR_GROUP, "Default", true)
	end)
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(MAP_DECOR_GROUP, "Players", true)
	end)
end

--- Register `IdleBoat` and turn off every collision pair that could let a
--- parked / docked boat shove a character or another boat. See the doc
--- block in `BoatCollisionContract` for rationale on each pair.
---
--- Idempotent: safe to call from both `BoatDockService:Init` and
--- `OilShipmentService:Init` (whichever runs first registers; the other
--- just re-asserts the matrix). Pair writes that reference a group not
--- yet registered (e.g. `PlayerInStraitEvent` registered in
--- `OilShipmentService:Init`) are wrapped in `pcall` so a startup-order
--- race never breaks the dock spawner.
local function applyIdleBoatCollisionRules()
	pcall(function()
		PhysicsService:RegisterCollisionGroup(IDLE_BOAT_GROUP)
	end)
	pcall(function()
		PhysicsService:RegisterCollisionGroup("ShipmentShip")
	end)
	pcall(function()
		PhysicsService:RegisterCollisionGroup(MARINA_DOCK_GROUP)
	end)
	pcall(function()
		PhysicsService:RegisterCollisionGroup(MAP_DECOR_GROUP)
	end)
	-- Characters clip through docked boats — keeps the owner from being
	-- shoulder-checked off their own voyage boat as it sails past a
	-- docked neighbor (the gameplay reason for splitting the group at all).
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(IDLE_BOAT_GROUP, "Default", false)
	end)
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(IDLE_BOAT_GROUP, "Players", false)
	end)
	-- Voyage hulls clip through docked boats (the "massive hangups" path).
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(IDLE_BOAT_GROUP, "ShipmentShip", false)
	end)
	-- Parked boats never push each other.
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(IDLE_BOAT_GROUP, IDLE_BOAT_GROUP, false)
	end)
	-- Pier / world decor: docked boats already sit on / next to these and
	-- shouldn't fight the static geometry.
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(IDLE_BOAT_GROUP, MARINA_DOCK_GROUP, false)
	end)
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(IDLE_BOAT_GROUP, MAP_DECOR_GROUP, false)
	end)
	-- Strait-event flow temporarily reassigns the owner character into
	-- `PlayerInStraitEvent` (registered by `OilShipmentService:Init`). Mirror
	-- the no-collide rule so a freeze cinematic that ends near the dock
	-- doesn't suddenly re-collide the player with a parked hull.
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(IDLE_BOAT_GROUP, "PlayerInStraitEvent", false)
	end)
	-- Cosmetic strait-event NPCs (Coast Guard / Pirate ships, officers)
	-- already no-collide with the world; cover the docked-boat case too
	-- so a returning voyage cinematic near the dock doesn't snag.
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(IDLE_BOAT_GROUP, "StraitWaypointFxNpc", false)
	end)
end

function BoatDockService:_tagMapDecorFolder(mapDecor: Instance)
	local function tagIfDecorPart(inst: Instance)
		if not inst:IsA("BasePart") then
			return
		end
		pcall(function()
			(inst :: BasePart).CollisionGroup = MAP_DECOR_GROUP
		end)
	end
	for _, d in ipairs(mapDecor:GetDescendants()) do
		tagIfDecorPart(d)
	end
	local decorConn = mapDecor.DescendantAdded:Connect(function(inst)
		task.defer(function()
			if inst.Parent == nil then
				return
			end
			tagIfDecorPart(inst)
		end)
	end)
	table.insert(self._connections, decorConn)
end

function BoatDockService:_tagMarinaDockParts(docksRoot: Instance)
	local boatsFolder = docksRoot:FindFirstChild("Boats")
	local function tagIfDockPart(inst: Instance)
		if not inst:IsA("BasePart") then
			return
		end
		if boatsFolder and inst:IsDescendantOf(boatsFolder) then
			return
		end
		pcall(function()
			(inst :: BasePart).CollisionGroup = MARINA_DOCK_GROUP
		end)
	end
	for _, d in ipairs(docksRoot:GetDescendants()) do
		tagIfDockPart(d)
	end
	local dockDescendantConn = docksRoot.DescendantAdded:Connect(function(inst)
		task.defer(function()
			if inst.Parent == nil then
				return
			end
			tagIfDockPart(inst)
		end)
	end)
	table.insert(self._connections, dockDescendantConn)
end

export type BoatState = "idle" | "sailing" | "cooldown" | "swapping"

--- Lazy-cached lookup for the `TeleportHomeApplied` `RemoteEvent`. Populated on first
--- ship-teleport (well after `RemoteService:Init()` has built the `Remotes` folder), then
--- reused for every subsequent fire so the hot path is a field read, not a folder lookup.
--- See `RemoteNames.TeleportHomeApplied` doc block for why ship teleports need the snap.
function BoatDockService:_getCameraSnapEvent(): RemoteEvent?
	if self._cameraSnapEvent and self._cameraSnapEvent.Parent then
		return self._cameraSnapEvent
	end
	if not self._remoteService then
		return nil
	end
	local ok, ev = pcall(function()
		return self._remoteService:GetEvent(RemoteNames.TeleportHomeApplied)
	end)
	if ok and ev then
		self._cameraSnapEvent = ev
		return ev
	end
	return nil
end

function BoatDockService:Init(remoteService, oilStateService)
	self._remoteService = remoteService
	self._oilStateService = oilStateService
	self._connections = {} :: { RBXScriptConnection }
	self._cameraSnapEvent = nil :: RemoteEvent?
	self._slotsByIndex = {} :: { [number]: BasePart }
	self._slotOwner = {} :: { [number]: number? }        -- slotIndex -> userId
	self._slotByUser = {} :: { [number]: number? }       -- userId -> slotIndex
	self._boatsByUser = {} :: { [number]: Model? }       -- userId -> current boat Model
	self._stateByUser = {} :: { [number]: BoatState }
	self._cooldownEnds = {} :: { [number]: number? }     -- userId -> os.clock() timestamp
	self._onBoatBecameIdleCallback = nil :: ((userId: number) -> ())?

	-- Collision: voyage hulls (`ShipmentShip` in OilShipmentService) ignore each other and ignore dock meshes.
	pcall(function()
		PhysicsService:RegisterCollisionGroup("ShipmentShip")
	end)
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable("ShipmentShip", "ShipmentShip", false)
	end)
	applyMarinaDockCollisionRules()
	applyMapDecorVersusShipmentShipRules()
	-- Idle / docked boats live in their own group so they no-collide with
	-- characters, voyage hulls, and each other. See doc block in
	-- `BoatCollisionContract` for the full pair matrix and the gameplay
	-- reason ("don't knock the owner off their own boat as it sails past
	-- a docked neighbor; don't let voyage hulls hang on parked boats").
	applyIdleBoatCollisionRules()
	local docksRoot = getDocksRoot()
	if docksRoot then
		self:_tagMarinaDockParts(docksRoot)
	else
		warn("[BoatDockService] No workspace.dOCKS — MarinaDock tagging skipped.")
	end

	local map = Workspace:FindFirstChild("Map") or Workspace:FindFirstChild("map")
	local mapDecor = map and (map:FindFirstChild("MapDecor") or map:FindFirstChild("mapdecor"))
	if mapDecor then
		self:_tagMapDecorFolder(mapDecor)
	else
		warn("[BoatDockService] No Workspace.Map.MapDecor — MapDecor collision tagging skipped.")
	end

	self:_discoverSlots()
end

function BoatDockService:_discoverSlots()
	local docks = getDocksRoot()
	if not docks then
		warn("[BoatDockService] workspace.dOCKS not found — idle boats will not spawn.")
		return
	end
	for i = 1, SLOT_COUNT do
		local folder = docks:FindFirstChild("BoatSpawn" .. i)
		local spawnPart = folder and folder:FindFirstChild("Spawn")
		if spawnPart and spawnPart:IsA("BasePart") then
			self._slotsByIndex[i] = spawnPart
		else
			warn(string.format("[BoatDockService] Missing workspace.dOCKS.BoatSpawn%d.Spawn (BasePart)", i))
		end
	end
end

function BoatDockService:_findFreeSlot(): number?
	for i = 1, SLOT_COUNT do
		if self._slotsByIndex[i] and not self._slotOwner[i] then
			return i
		end
	end
	return nil
end

local function rigForBoatModel(boat: Model): ShipRig.RigDef
	local templateName = boat:GetAttribute("ShipTemplateName")
	if typeof(templateName) == "string" and templateName ~= "" then
		return ShipSkinCatalog.GetRigForTemplate(templateName)
	end
	local skinId = boat:GetAttribute("ShipSkinId")
	if typeof(skinId) == "string" and skinId ~= "" then
		return ShipSkinCatalog.GetRigForSkin(skinId)
	end
	return ShipSkinCatalog.GetRigForTemplate("Tanker")
end

local function findSeatForBoat(boat: Model): Seat?
	local rig = rigForBoatModel(boat)
	local seat = ShipRig.FindSeat(boat, rig.deckSeatName)
	if seat then
		return seat
	end
	return ShipRig.FindSeat(boat, "DeckSeat")
end

local function resolveOwnerStandCFrame(boat: Model): CFrame?
	local rig = rigForBoatModel(boat)
	local seat = findSeatForBoat(boat)
	local deckAnchor = ShipRig.FindAttachment(boat, rig.deckAnchorName)
	local barrelStackRoot = ShipRig.FindBasePart(boat, rig.barrelStackRootName)
	local frontMarker = ShipRig.FindBasePart(boat, rig.frontMarkerName)
	local dockAnchor = ShipRig.FindAttachment(boat, rig.dockAnchorName)

	local anchorPos: Vector3?
	if deckAnchor then
		anchorPos = deckAnchor.WorldPosition
	elseif seat then
		anchorPos = seat.Position
	elseif barrelStackRoot then
		anchorPos = barrelStackRoot.Position
	end
	if not anchorPos then
		return nil
	end

	local waterlineY = anchorPos.Y
	local deckY = ShipRig.ResolveDeckWorldY(boat, rig, waterlineY)

	local forward = Vector3.new(0, 0, -1)
	if frontMarker and dockAnchor then
		local bow = frontMarker.Position - dockAnchor.WorldPosition
		local flatBow = Vector3.new(bow.X, 0, bow.Z)
		if flatBow.Magnitude > 0.01 then
			forward = flatBow.Unit
		end
	elseif boat.PrimaryPart then
		local flatLook = Vector3.new(boat.PrimaryPart.CFrame.LookVector.X, 0, boat.PrimaryPart.CFrame.LookVector.Z)
		if flatLook.Magnitude > 0.01 then
			forward = flatLook.Unit
		end
	end

	local right = Vector3.new(-forward.Z, 0, forward.X)
	local standPos = Vector3.new(anchorPos.X, deckY + 4, anchorPos.Z) + forward * rig.standForwardOffset + right * rig.standRightOffset
	if seat and (Vector3.new(standPos.X, seat.Position.Y, standPos.Z) - seat.Position).Magnitude < 6 then
		standPos += right * 4
	end
	return CFrame.lookAt(standPos, standPos + forward)
end

local function resolveBoatSupportStandCFrame(boat: Model, desiredCFrame: CFrame): CFrame
	local desiredPos = desiredCFrame.Position
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.IgnoreWater = true

	local include = {}
	for _, d in ipairs(boat:GetDescendants()) do
		if d:IsA("BasePart") and d.CanQuery then
			table.insert(include, d)
		end
	end
	params.FilterDescendantsInstances = include

	if #include == 0 then
		if RunService:IsStudio() then
			print(string.format(
				"[BoatTeleportSupport] boat=%s miss=no-queryable-parts targetY=%.2f",
				boat:GetFullName(),
				desiredPos.Y
			))
		end
		return desiredCFrame
	end

	-- Clamp the support search to a thin band around the rig's intended deck Y.
	-- Starting only `SLACK_ABOVE` studs above `desiredPos.Y` means a roof / cabin /
	-- mast above the rig's deck can never be picked as "support" — the ray either
	-- finds the deck just below the target or misses (in which case we use
	-- `desiredCFrame` directly via the early-return below). This is universal
	-- across every ship skin: no per-ship CanQuery / DeckAnchor authoring needed.
	local SLACK_ABOVE = 2
	local SEARCH_BELOW = 12
	local origin = Vector3.new(desiredPos.X, desiredPos.Y + SLACK_ABOVE, desiredPos.Z)
	local castDistance = SLACK_ABOVE + SEARCH_BELOW
	local result = Workspace:Raycast(origin, Vector3.new(0, -castDistance, 0), params)
	if not result or not result.Instance or not result.Instance:IsA("BasePart") then
		if RunService:IsStudio() then
			print(string.format(
				"[BoatTeleportSupport] boat=%s miss=no-hit originY=%.2f castDistance=%.2f targetY=%.2f",
				boat:GetFullName(),
				origin.Y,
				castDistance,
				desiredPos.Y
			))
		end
		return desiredCFrame
	end

	local supportPart = result.Instance
	if not supportPart.CanCollide then
		if RunService:IsStudio() then
			print(string.format(
				"[BoatTeleportSupport] boat=%s miss=non-collide-hit part=%s hitY=%.2f targetY=%.2f",
				boat:GetFullName(),
				supportPart:GetFullName(),
				result.Position.Y,
				desiredPos.Y
			))
		end
		return desiredCFrame
	end

	--- Clamp the snap to **never go BELOW** `desiredPos.Y`. The raycast is
	--- only a refinement to push the stand position UP when something sits
	--- on top of the rig-authored deck height (barrel stack, cabin step,
	--- etc.). Roblox raycasts skip any part whose **interior the ray
	--- originates inside** — when `desiredPos.Y` (already `DeckTopAnchor.Y +
	--- 4`) sits inside the deck slab on a thick-deck skin, or the deck
	--- barely overlaps `desiredPos.Y` after physics settle, the ray punches
	--- through the deck and hits the **next collidable surface below**
	--- (interior hull, ballast, ship floor under the deck). Snapping to
	--- `that hit + 4` would drop the player **inside** / **under** the ship.
	--- Trust `desiredPos.Y` as the lower bound — the rig anchor is the
	--- authoritative stand height — and only let the support snap raise it.
	---
	--- `EXTRA_CLEARANCE`: boats are unanchored and bob with wave physics.
	--- The CFrame resolved here is sampled **once** before `PivotTo`; if the
	--- boat rises between the sample and the engine actually placing the
	--- character (1+ physics step), the HRP can end up clipped INSIDE the
	--- deck slab and Roblox resolves the overlap by ejecting them UNDER the
	--- ship. Spawning a few studs higher gives gravity room to drop them
	--- onto the deck cleanly without ever overlapping it.
	---
	--- 4 (not 2): on the Tanker template, `DeckTopAnchor` sits only ~0.12
	--- studs above the deck slab's top face — within Roblox's "ray skips a
	--- part whose interior the ray originates inside" tolerance. Any small
	--- downward bob during dispatch (the boat un-anchors + welds + applies
	--- AlignPosition all in one frame in `_setupShip`) put the cast origin
	--- inside the slab, the cast missed the deck entirely (no other
	--- collidable part in the 14-stud band on Tanker), and the player was
	--- placed clipping the slab → ejected DOWN through the hull and into
	--- the water. Doubling the clearance lifts the placement well clear of
	--- the slab so gravity always drops onto, never inside, the deck.
	--- Pairs with the `RunService.Heartbeat:Wait()` in
	--- `OilShipmentService:_runShipment` (boat is settled by the time the
	--- raycast even runs). The follow-up safety re-snap in
	--- `teleportCharacterToBoatDeck` still covers worse cases.
	local EXTRA_CLEARANCE = 4
	local snapY = math.max(result.Position.Y + 4, desiredPos.Y) + EXTRA_CLEARANCE
	local snappedPos = Vector3.new(desiredPos.X, snapY, desiredPos.Z)
	if RunService:IsStudio() then
		print(string.format(
			"[BoatTeleportSupport] boat=%s support=%s hitY=%.2f targetY=%.2f snappedY=%.2f%s",
			boat:GetFullName(),
			supportPart:GetFullName(),
			result.Position.Y,
			desiredPos.Y,
			snappedPos.Y,
			if (result.Position.Y + 4) < desiredPos.Y then " [clamped-up-to-target]" else ""
		))
	end
	return CFrame.lookAt(snappedPos, snappedPos + desiredCFrame.LookVector)
end

--- Optional `snapPlayer` + `snapEvent`: fired post-teleport with the **actual** support CFrame
--- the character was placed at. Required because `PivotTo` doesn't re-align the default follow
--- camera's yaw — without this the player ends up facing the back of their own head when they
--- land on the deck. Same camera-snap protocol as the Home / Town / Warehouse teleports
--- (`RemoteNames.TeleportHomeApplied` → `HudTeleportRouter.snapCameraBehindCharacter`).
local function teleportCharacterToBoatDeck(
	character: Model,
	boat: Model,
	targetCFrame: CFrame,
	logLabel: string,
	snapPlayer: Player?,
	snapEvent: RemoteEvent?
)
	local seat = findSeatForBoat(boat)
	local hum = character:FindFirstChildOfClass("Humanoid")
	local seatWasDisabled = false

	if seat then
		local ok, disabled = pcall(function()
			return seat.Disabled
		end)
		if ok and disabled == false then
			pcall(function()
				seat.Disabled = true
			end)
			seatWasDisabled = true
		end
	end

	local supportCFrame = resolveBoatSupportStandCFrame(boat, targetCFrame)
	CharacterTeleport.teleportWithUnseat(character, supportCFrame, logLabel)

	--- Post-teleport safety re-snap: an unanchored boat may have bobbed UP
	--- in the 1+ physics steps between when we sampled `targetCFrame` and
	--- when `PivotTo` actually landed the character. Re-sample the deck Y
	--- after the next physics step and, if the HRP is now at or below the
	--- live deck surface (i.e. the character is clipped inside / under the
	--- deck), pivot upward by enough to put feet cleanly above the deck.
	--- The clearance constant matches `EXTRA_CLEARANCE` in
	--- `resolveBoatSupportStandCFrame` so first-try and re-snap agree on
	--- the same target standing height.
	task.delay(0.08, function()
		if not character.Parent or not boat.Parent then
			return
		end
		local hrp = character:FindFirstChild("HumanoidRootPart")
		if not hrp or not hrp:IsA("BasePart") then
			return
		end
		local rig = rigForBoatModel(boat)
		local liveDeckY = ShipRig.ResolveDeckWorldY(boat, rig, supportCFrame.Position.Y)
		--- HRP center sits ~2 studs above feet (R15) — the player is "on the
		--- deck" when HRP.Y >= liveDeckY + 3. Anything lower means feet have
		--- clipped below the deck top. `+0.25` slack absorbs jitter from a
		--- boat that's still settling.
		if hrp.Position.Y >= liveDeckY + 3 - 0.25 then
			return
		end
		local correctedY = liveDeckY + 3 + 2 -- live deck + feet offset + safety
		local correctedPos = Vector3.new(hrp.Position.X, correctedY, hrp.Position.Z)
		local correctedCFrame = CFrame.lookAt(
			correctedPos,
			correctedPos + supportCFrame.LookVector
		)
		CharacterTeleport.teleportWithUnseat(
			character,
			correctedCFrame,
			(logLabel or "") .. ":SafetyResnap"
		)
		if snapPlayer and snapEvent then
			pcall(function()
				snapEvent:FireClient(snapPlayer, correctedCFrame)
			end)
		end
		if RunService:IsStudio() then
			warn(string.format(
				"[BoatTeleportSupport] safety re-snap boat=%s prevY=%.2f liveDeckY=%.2f -> correctedY=%.2f",
				boat:GetFullName(),
				hrp.Position.Y,
				liveDeckY,
				correctedY
			))
		end
	end)

	if snapPlayer and snapEvent then
		--- Wrap in pcall: a missing `Remotes` folder during a fresh boot or a player
		--- leaving between resolve and fire shouldn't cancel the boat-side teardown.
		pcall(function()
			snapEvent:FireClient(snapPlayer, supportCFrame)
		end)
	end

	if hum and seat then
		task.delay(0.15, function()
			if hum.Parent == character and hum.SeatPart == seat then
				CharacterTeleport.unseatIfSitting(character)
				hum.Sit = false
			end
		end)
	end

	if seat and seatWasDisabled then
		task.delay(1.0, function()
			if seat.Parent then
				pcall(function()
					seat.Disabled = false
				end)
			end
		end)
	end
end

local function getDockWaterSurfaceY(): number?
	local map = Workspace:FindFirstChild("Map")
	local oceanRoot = map and map:FindFirstChild("Ocean")
	local strait = oceanRoot and oceanRoot:FindFirstChild("StraitHormuz")
	local ocean = strait and strait:FindFirstChild("Ocean")
	if ocean and ocean:IsA("BasePart") then
		return ocean.Position.Y + ocean.Size.Y * 0.5
	end
	return nil
end

function BoatDockService:_resolveTemplate(skinId: string): (Instance?, string, ShipRig.RigDef)
	local assetsFolder = ReplicatedStorage:FindFirstChild("Assets")
	local fallbackRig = ShipSkinCatalog.GetRigForTemplate("Tanker")
	if not assetsFolder then
		return nil, "Tanker", fallbackRig
	end
	local skin = ShipSkinCatalog.GetSkin(skinId)
	local templateName = skin and skin.templateName or "Tanker"
	local rig = ShipSkinCatalog.GetRigForTemplate(templateName)
	local tpl = templateName and assetsFolder:FindFirstChild(templateName)
	if not (tpl and (tpl:IsA("Model") or tpl:IsA("BasePart"))) then
		warn(string.format(
			"[BoatDockService] Missing template '%s' for skin=%s; falling back to Tanker.",
			tostring(templateName),
			tostring(skinId)
		))
		templateName = "Tanker"
		rig = ShipSkinCatalog.GetRigForTemplate(templateName)
		tpl = assetsFolder:FindFirstChild("Tanker") -- fallback
	end
	return tpl, templateName, rig
end

function BoatDockService:_ensureBoatsFolder(): Folder
	local docks = getDocksRoot()
	if not docks then
		local placeholder = Instance.new("Folder")
		placeholder.Name = "dOCKS"
		placeholder.Parent = Workspace
		docks = placeholder
	end
	local boats = docks:FindFirstChild("Boats")
	if not boats then
		boats = Instance.new("Folder")
		boats.Name = "Boats"
		boats.Parent = docks
	end
	return boats :: Folder
end

local function neutralizeSeat(seat: Seat)
	seat.Disabled = true
	seat.CanTouch = false
	seat.CanQuery = false
	seat.CanCollide = false
	seat.Massless = true
	seat:SetAttribute("SeatGameplayDisabled", true)
end

-- Boat-wide collision contract (helper neutralization + collision-group tagging)
-- now lives in `BoatCollisionContract`. Both this service (idle dock spawn,
-- checkout re-tag) and `OilShipmentService._setupShip` (voyage hull) MUST
-- funnel through `BoatCollisionContract.Apply` so the universal rule stays
-- consistent.
--
-- `mode` selects the group:
--   * "idle"   → `IdleBoat`     (parked / docked; no collide with chars / voyages / each other)
--   * "voyage" → `ShipmentShip` (active voyage; characters can stand on the deck)
local function applyBoatCollisionContract(root: Instance, mode: BoatCollisionContract.ApplyMode)
	BoatCollisionContract.Apply(root, mode)
end

local function logRemainingInvisibleBoatColliders(root: Instance)
	if not RunService:IsStudio() then
		return
	end
	local seat = root:FindFirstChild("DeckSeat", true)
	local centerPart = if seat and seat:IsA("BasePart")
		then seat
		else root:FindFirstChild("BarrelStackRoot", true)
	local center = if centerPart and centerPart:IsA("BasePart")
		then centerPart.Position
		else nil
	if not center then
		return
	end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart")
			and d.Transparency >= 0.95
			and (d.CanCollide or d.CanTouch)
			and (d.Position - center).Magnitude <= 30
		then
			warn(string.format(
				"[BoatDockService][InvisibleCollider] part=%s dist=%.2f collide=%s touch=%s query=%s size=(%.2f,%.2f,%.2f)",
				d:GetFullName(),
				(d.Position - center).Magnitude,
				tostring(d.CanCollide),
				tostring(d.CanTouch),
				tostring(d.CanQuery),
				d.Size.X,
				d.Size.Y,
				d.Size.Z
			))
		end
	end
end

local function stripBoatBoardPrompt(root: Instance)
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("ProximityPrompt") and d.Name == "BoardPrompt" then
			d:Destroy()
		end
	end
end

local function addPlayerFlag(root: Instance, ownerUserId: number, rig: any)
	if not root:IsA("Model") then
		return
	end
	local flag = ShipRig.FindBasePart(root, rig.playerFlagName) or ShipRig.FindBasePart(root, "PlayerFlag")
	if not flag then
		return
	end

	for _, existing in ipairs(flag:GetChildren()) do
		if (existing:IsA("Decal") and existing.Name == "PlayerHead") or existing.Name == "FlagNameGui" then
			existing:Destroy()
		end
	end

	local thumbUrl = string.format("rbxthumb://type=AvatarHeadShot&id=%d&w=420&h=420", ownerUserId)
	for _, face in ipairs({ Enum.NormalId.Front, Enum.NormalId.Back, Enum.NormalId.Left, Enum.NormalId.Right }) do
		local decal = Instance.new("Decal")
		decal.Name = "PlayerHead"
		decal.Texture = thumbUrl
		decal.Face = face
		decal.Parent = flag
	end

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

function BoatDockService:_spawnIdleBoat(userId: number, slotIndex: number, skinId: string): Model?
	local slotPart = self._slotsByIndex[slotIndex]
	if not slotPart then return nil end
	local tpl, templateName, rig = self:_resolveTemplate(skinId)
	if not tpl then
		warn(string.format("[BoatDockService] No boat template resolvable for user=%d skin=%s", userId, tostring(skinId)))
		return nil
	end

	local function cloneTemplateAsModel(templateInst: Instance): Model
		local clone = templateInst:Clone()
		if clone:IsA("Model") then
			return clone
		end
		local wrap = Instance.new("Model")
		wrap.Name = templateInst.Name
		clone.Parent = wrap
		return wrap
	end

	local boat = cloneTemplateAsModel(tpl :: Instance)
	boat.Name = "IdleBoat_" .. tostring(userId)
	boat:SetAttribute("ShipSkinId", skinId)
	boat:SetAttribute("ShipTemplateName", templateName)

	local rigOk, rigErrors, rigWarnings = ShipRig.ValidateCore(boat, rig)
	for _, warningMsg in ipairs(rigWarnings) do
		warn(string.format(
			"[BoatDockService] Rig warning user=%d skin=%s template=%s: %s",
			userId,
			tostring(skinId),
			tostring(templateName),
			warningMsg
		))
	end
	if not rigOk then
		warn(string.format(
			"[BoatDockService] Rig invalid user=%d skin=%s template=%s: %s",
			userId,
			tostring(skinId),
			tostring(templateName),
			table.concat(rigErrors, " | ")
		))

		if templateName ~= "Tanker" then
			local assetsFolder = ReplicatedStorage:FindFirstChild("Assets")
			local tankerTemplate = assetsFolder and assetsFolder:FindFirstChild("Tanker")
			if tankerTemplate and (tankerTemplate:IsA("Model") or tankerTemplate:IsA("BasePart")) then
				pcall(function()
					boat:Destroy()
				end)
				templateName = "Tanker"
				rig = ShipSkinCatalog.GetRigForTemplate(templateName)
				boat = cloneTemplateAsModel(tankerTemplate)
				boat.Name = "IdleBoat_" .. tostring(userId)
				boat:SetAttribute("ShipSkinId", skinId)
				boat:SetAttribute("ShipTemplateName", templateName)

				rigOk, rigErrors, rigWarnings = ShipRig.ValidateCore(boat, rig)
				for _, warningMsg in ipairs(rigWarnings) do
					warn(string.format(
						"[BoatDockService] Rig warning (fallback) user=%d skin=%s template=%s: %s",
						userId,
						tostring(skinId),
						tostring(templateName),
						warningMsg
					))
				end
			end
		end

		if not rigOk then
			warn(string.format(
				"[BoatDockService] Cannot spawn idle boat user=%d skin=%s; rig errors after fallback: %s",
				userId,
				tostring(skinId),
				table.concat(rigErrors, " | ")
			))
			pcall(function()
				boat:Destroy()
			end)
			return nil
		end
	end

	-- Idle boat: anchor every BasePart (static; no constraints, no welds).
	-- IMPORTANT: do NOT force `CanCollide = true` here. The previous version
	-- did that and silently re-enabled artist-disabled parts (e.g. 60+ tiny
	-- `Ball` decorations on the Whale rig, both `SaddlePad` MeshParts, the
	-- `SprayPoint`, and on the Ducky template the duck-body invisible cube
	-- + raft-pillar block-vs-cylinder mismatch). Authored `CanCollide` is the
	-- source of truth; the `BoatCollisionContract.Apply` call below handles
	-- the helper neutralization + `ShipmentShip` group tagging uniformly.
	for _, d in ipairs(boat:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanTouch = true
			d.CanQuery = true
		end
	end

	-- Pose the ship so:
	--   (a) DockAnchor Attachment lands on the slot's red square (+ IDLE_Y_OFFSET),
	--   (b) FRONT_MARKER direction aligns with the slot's LookVec (out to sea).
	boat:PivotTo(CFrame.new())

	local dockAnchor = ShipRig.FindAttachment(boat, rig.dockAnchorName)
	local frontMarker = ShipRig.FindBasePart(boat, rig.frontMarkerName)

	local anchorLocal: Vector3 = dockAnchor and dockAnchor.WorldPosition or Vector3.zero
	local slotForward = slotPart.CFrame.LookVector
	slotForward = Vector3.new(slotForward.X, 0, slotForward.Z)
	if slotForward.Magnitude < 0.01 then
		slotForward = Vector3.new(0, 0, -1)
	else
		slotForward = slotForward.Unit
	end

	local baseCFrame: CFrame
	if frontMarker then
		local fmLocal = frontMarker.Position
		local shipForwardLocal = Vector3.new(fmLocal.X - anchorLocal.X, 0, fmLocal.Z - anchorLocal.Z)
		if shipForwardLocal.Magnitude < 0.01 then
			shipForwardLocal = Vector3.new(0, 0, -1)
		else
			shipForwardLocal = shipForwardLocal.Unit
		end
		local currentYaw = math.atan2(shipForwardLocal.X, shipForwardLocal.Z)
		local targetYaw = math.atan2(slotForward.X, slotForward.Z) + math.pi
		local yawDelta = targetYaw - currentYaw
		local rotation = CFrame.Angles(0, yawDelta, 0)
		local rotatedAnchor = rotation * anchorLocal
		local targetPos = slotPart.Position + Vector3.new(0, IDLE_Y_OFFSET, 0)
		local shipOriginPos = targetPos - Vector3.new(rotatedAnchor.X, rotatedAnchor.Y, rotatedAnchor.Z)
		baseCFrame = CFrame.new(shipOriginPos) * rotation
	else
		local rotation = CFrame.Angles(0, math.pi / 2, 0)
		local rotatedAnchor = rotation * anchorLocal
		local targetPos = slotPart.Position + Vector3.new(0, IDLE_Y_OFFSET, 0)
		local shipOriginPos = targetPos - Vector3.new(rotatedAnchor.X, rotatedAnchor.Y, rotatedAnchor.Z)
		baseCFrame = CFrame.new(shipOriginPos) * rotation
	end

	boat:PivotTo(baseCFrame)

	-- Normalize docked vertical placement: align authored WaterlineAnchor to ocean surface.
	local waterlinePart = boat:FindFirstChild("WaterlineAnchor", true)
	local waterSurfaceY = getDockWaterSurfaceY()
	if waterlinePart and waterlinePart:IsA("BasePart") and waterSurfaceY then
		local deltaY = waterSurfaceY - waterlinePart.Position.Y
		if math.abs(deltaY) > 0.001 then
			baseCFrame += Vector3.new(0, deltaY, 0)
			boat:PivotTo(baseCFrame)
		end
	end

	if DEBUG_DOCK_SPAWN then
		local dockAfter = ShipRig.FindAttachment(boat, rig.dockAnchorName)
		local wl = boat:FindFirstChild("WaterlineAnchor", true)
		local waterlinePart = if wl and wl:IsA("BasePart") then wl else nil
		local seatAfter = ShipRig.FindSeat(boat, rig.deckSeatName)
		local pivotPos = boat:GetPivot().Position
		local dockY = if dockAfter then dockAfter.WorldPosition.Y else math.huge
		local slotY = slotPart.Position.Y + IDLE_Y_OFFSET
		local wlY = if waterlinePart then waterlinePart.Position.Y else math.huge
		local seatY = if seatAfter then seatAfter.Position.Y else math.huge
		local waterSurfaceYDebug = getDockWaterSurfaceY()
		warn(string.format(
			"[BoatDockService][DockDebug] user=%d slot=%d skin=%s template=%s pivotY=%.2f slotY=%.2f dockY=%.2f dockDelta=%.2f wlY=%s wlToSlot=%s wlToWater=%s waterY=%s seatY=%s",
			userId,
			slotIndex,
			tostring(skinId),
			tostring(templateName),
			pivotPos.Y,
			slotY,
			dockY,
			dockY - slotY,
			if waterlinePart then string.format("%.2f", wlY) else "nil",
			if waterlinePart then string.format("%.2f", wlY - slotY) else "nil",
			if waterlinePart and waterSurfaceYDebug then string.format("%.2f", wlY - waterSurfaceYDebug) else "nil",
			if waterSurfaceYDebug then string.format("%.2f", waterSurfaceYDebug) else "nil",
			if seatAfter then string.format("%.2f", seatY) else "nil"
		))
	end

	-- Attributes the client rocking script + voyage handoff read.
	boat:SetAttribute("OwnerUserId", userId)
	boat:SetAttribute("SlotIndex", slotIndex)
	boat:SetAttribute("IsIdleBob", true)
	boat:SetAttribute("DockCFrame", baseCFrame)

	local seat = findSeatForBoat(boat)
	if seat then
		neutralizeSeat(seat)
	end
	-- Idle dock spawn: tag every part `IdleBoat` so characters and voyage
	-- hulls clip through the parked boat. Re-tagged to `ShipmentShip` in
	-- `CheckoutBoat` (and again, idempotently, in `OilShipmentService:_setupShip`).
	applyBoatCollisionContract(boat, "idle")
	addPlayerFlag(boat, userId, rig)
	logRemainingInvisibleBoatColliders(boat)
	stripBoatBoardPrompt(boat)

	boat.Parent = self:_ensureBoatsFolder()

	self._boatsByUser[userId] = boat
	self._slotOwner[slotIndex] = userId
	self._slotByUser[userId] = slotIndex
	self._stateByUser[userId] = "idle"
	self._cooldownEnds[userId] = nil
	self:_pushSnapshot(userId)
	return boat
end

function BoatDockService:_destroyBoat(userId: number)
	local boat = self._boatsByUser[userId]
	if boat then
		-- Explicitly destroy every descendant BasePart first, then the model.
		-- Complex templates (e.g. Ducky with nested DanceFloor ManualWelds,
		-- JetEngine sub-models, BoatGroundDUck UnionOperations) can leave
		-- orphaned frozen parts if the top-level `Model:Destroy()` doesn't
		-- fully propagate through deeply-nested weld chains. Belt-and-
		-- suspenders: kill each part, then the model.
		pcall(function()
			for _, desc in ipairs(boat:GetDescendants()) do
				if desc:IsA("BasePart") then
					desc:Destroy()
				end
			end
			boat:Destroy()
		end)
	end
	self._boatsByUser[userId] = nil
end

function BoatDockService:SetOnBoatBecameIdleCallback(fn: (userId: number) -> ())
	self._onBoatBecameIdleCallback = fn
end

function BoatDockService:_fireBoatBecameIdle(userId: number)
	if self._onBoatBecameIdleCallback then
		task.defer(self._onBoatBecameIdleCallback, userId)
	end
end

function BoatDockService:_pushSnapshot(userId: number)
	-- Broadcast state via the existing OilState snapshot so the HUD can countdown.
	if self._oilStateService and self._oilStateService.PushState then
		self._oilStateService:PushState(userId)
	end
end

function BoatDockService:_getSkinId(userId: number): string
	local state = self._oilStateService and self._oilStateService:GetState(userId)
	local sid = state and state.shipSkinId
	if typeof(sid) == "string" and ShipSkinCatalog.Skins[sid] then
		return sid
	end
	return "DefaultTanker"
end

--- Public queries ---

function BoatDockService:GetBoat(userId: number): Model?
	return self._boatsByUser[userId]
end

function BoatDockService:GetSlotIndex(userId: number): number?
	return self._slotByUser[userId]
end

function BoatDockService:GetState(userId: number): BoatState?
	return self._stateByUser[userId]
end

function BoatDockService:IsIdle(userId: number): boolean
	return self._stateByUser[userId] == "idle" and self._boatsByUser[userId] ~= nil
end

function BoatDockService:GetCooldownEndsAt(userId: number): number?
	return self._cooldownEnds[userId]
end

--- Voyage handoff ---

function BoatDockService:CheckoutBoat(userId: number, shipmentId: string): (Model?, string?)
	local state = self._stateByUser[userId]
	if state == "cooldown" then
		return nil, "BOAT_COOLDOWN"
	elseif state == "swapping" then
		return nil, "BOAT_SWAPPING"
	elseif state == "sailing" then
		return nil, "BOAT_ALREADY_CHECKED_OUT"
	end
	local boat = self._boatsByUser[userId]
	if not boat then
		return nil, "BOAT_MISSING"
	end
	-- Telemetry §6.7 `dock_idle_to_active`. Captures the moment the
	-- player's slot transitions from idle (bobbing) to a live voyage.
	-- Fired before we mutate `_stateByUser` so analytics records the
	-- idle dwell-time (`os.clock() - _idleSinceClock`) on the slice the
	-- player just left, not on the new sailing slice.
	pcall(function()
		local plr = Players:GetPlayerByUserId(userId)
		Telemetry.Track(plr, "dock_idle_to_active", {
			shipmentId = shipmentId,
			slotIndex = self._slotByUser[userId],
		})
	end)
	-- Transition to sailing.
	self._stateByUser[userId] = "sailing"
	boat:SetAttribute("IsIdleBob", false)   -- stop client bob
	boat.Name = "ActiveShipmentBoat"
	boat:SetAttribute("ShipmentId", shipmentId)
	-- Re-tag from `IdleBoat` (set in `_spawnIdleBoat`) to `ShipmentShip`
	-- now that this hull is becoming a voyage boat — the owner needs to
	-- be able to stand on the deck. `_setupShip` below also re-applies
	-- after un-anchoring (idempotent), and that pass also covers any
	-- (rare) case where a controller poked CanCollide between spawn
	-- and checkout.
	applyBoatCollisionContract(boat, "voyage")
	logRemainingInvisibleBoatColliders(boat)
	stripBoatBoardPrompt(boat)
	self:_pushSnapshot(userId)
	return boat, nil
end

function BoatDockService:CheckinBoat(userId: number, opts: { destroyed: boolean? }?)
	-- Always destroy the checked-out model. If the player left during the voyage,
	-- the slot is already freed; this just drops the model and no-ops the respawn.
	self:_destroyBoat(userId)
	local wasDestroyed = opts ~= nil and opts.destroyed == true

	local player = Players:GetPlayerByUserId(userId)
	if not player then
		-- Player left during voyage. Clean up tables entirely; slot was already freed on PlayerRemoving.
		self._stateByUser[userId] = nil
		self._cooldownEnds[userId] = nil
		self._slotByUser[userId] = nil
		return
	end

	local slotIndex = self._slotByUser[userId]
	if not slotIndex then
		-- Slot somehow freed while still sailing (e.g. PlayerRemoving then re-join rare race);
		-- try a fresh free slot.
		slotIndex = self:_findFreeSlot()
		if slotIndex then self._slotByUser[userId] = slotIndex end
	end

	if not wasDestroyed then
		self._cooldownEnds[userId] = nil
		if not slotIndex then
			self._stateByUser[userId] = nil
			self:_pushSnapshot(userId)
			return
		end
		self._slotOwner[slotIndex] = userId
		self:_spawnIdleBoat(userId, slotIndex, self:_getSkinId(userId))
		self:_fireBoatBecameIdle(userId)
		return
	end

	self._stateByUser[userId] = "cooldown"
	local endsAt = os.clock() + DESTROY_COOLDOWN_SECONDS
	self._cooldownEnds[userId] = endsAt
	self:_pushSnapshot(userId)

	task.delay(DESTROY_COOLDOWN_SECONDS, function()
		-- Bail if player left or state mutated during the wait.
		if not Players:GetPlayerByUserId(userId) then return end
		if self._stateByUser[userId] ~= "cooldown" then return end
		if self._cooldownEnds[userId] ~= endsAt then return end
		self._cooldownEnds[userId] = nil
		local idx = self._slotByUser[userId]
		if not idx then
			idx = self:_findFreeSlot()
			if idx then self._slotByUser[userId] = idx end
		end
		if not idx then
			self._stateByUser[userId] = nil
			return
		end
		self._slotOwner[idx] = userId
		self:_spawnIdleBoat(userId, idx, self:_getSkinId(userId))
		self:_fireBoatBecameIdle(userId)
	end)
end

--- Skin swap ---

function BoatDockService:CanSwapSkin(userId: number): boolean
	local st = self._stateByUser[userId]
	return st == "idle" or st == nil
end

function BoatDockService:RequestSkinSwap(userId: number, newSkinId: string)
	local st = self._stateByUser[userId]
	if st ~= "idle" then
		-- Sailing, cooling down, or already swapping — skin will apply at next natural respawn.
		return
	end
	local slotIndex = self._slotByUser[userId]
	if not slotIndex then return end

	self:_destroyBoat(userId)
	self._stateByUser[userId] = "swapping"
	local endsAt = os.clock() + SKIN_SWAP_COOLDOWN_SECONDS
	self._cooldownEnds[userId] = endsAt
	self:_pushSnapshot(userId)

	task.delay(SKIN_SWAP_COOLDOWN_SECONDS, function()
		if not Players:GetPlayerByUserId(userId) then return end
		if self._stateByUser[userId] ~= "swapping" then return end
		if self._cooldownEnds[userId] ~= endsAt then return end
		self._cooldownEnds[userId] = nil
		local idx = self._slotByUser[userId]
		if not idx then return end
		self:_spawnIdleBoat(userId, idx, newSkinId)
	end)
end

--- Owner teleport ---

--- Teleport `caller` onto the DECK of `targetUserId`'s active voyage boat.
--- Boats no longer use seats — `resolveOwnerStandCFrame` walks the rig anchors
--- (deckAnchor → seat → barrelStackRoot) and we only fall back to a literal
--- seat as a last resort. Caller lands standing on the deck. Returns
--- `(false, err)` if the target isn't actively sailing or no anchor at all
--- can be resolved.
function BoatDockService:TeleportSpectatorToBoat(caller: Player, targetUserId: number): (boolean, string?)
	if self._stateByUser[targetUserId] ~= "sailing" then
		return false, "TARGET_NOT_SAILING"
	end
	local boat = self._boatsByUser[targetUserId]
	if not boat then
		return false, "TARGET_BOAT_MISSING"
	end
	local character = caller.Character
	if not character then
		return false, "NO_CHARACTER"
	end
	local standCFrame = resolveOwnerStandCFrame(boat)
	if not standCFrame then
		local seat = findSeatForBoat(boat)
		if not seat then
			return false, "DECK_ANCHOR_MISSING"
		end
		standCFrame = seat.CFrame + Vector3.new(4, 4, -5)
	end
	teleportCharacterToBoatDeck(
		character,
		boat,
		standCFrame,
		string.format("BoatDock:TeleportSpectatorToBoat target=%d", targetUserId),
		caller,
		self:_getCameraSnapEvent()
	)
	return true, nil
end

--- Boats no longer have seats; this teleports the owner STANDING onto the
--- deck. Name kept for compatibility (FtueService, OilShipmentService,
--- HudTeleportRouter, etc. all call `TeleportOwnerToSeat`). Resolution
--- order: `resolveOwnerStandCFrame` (deckAnchor → seat → barrelStackRoot) →
--- literal seat fallback (only if a Tanker template still has one).
function BoatDockService:TeleportOwnerToSeat(player: Player): (boolean, string?)
	local boat = self._boatsByUser[player.UserId]
	local st = self._stateByUser[player.UserId]
	if st == "cooldown" or st == "swapping" then
		return false, "BOAT_COOLDOWN"
	end
	if not boat then
		return false, "BOAT_MISSING"
	end
	local character = player.Character
	if not character then return false, "NO_CHARACTER" end
	local hum = character:FindFirstChildOfClass("Humanoid")
	if hum and (hum.Health <= 0 or hum:GetState() == Enum.HumanoidStateType.Dead) then
		return false, "CHAR_DEAD"
	end
	local standCFrame = resolveOwnerStandCFrame(boat)
	if not standCFrame then
		local seat = findSeatForBoat(boat)
		if not seat then
			return false, "DECK_ANCHOR_MISSING"
		end
		standCFrame = seat.CFrame + Vector3.new(4, 4, -5)
	end
	teleportCharacterToBoatDeck(
		character,
		boat,
		standCFrame,
		"BoatDock:TeleportOwnerToBoat",
		player,
		self:_getCameraSnapEvent()
	)
	return true, nil
end

--- Lifecycle ---

function BoatDockService:_onPlayerAdded(player: Player)
	local userId = player.UserId
	task.spawn(function()
		local deadline = os.clock() + 20
		while os.clock() < deadline do
			local state = self._oilStateService and self._oilStateService:GetState(userId)
			if state then break end
			task.wait(0.25)
		end
		if not Players:GetPlayerByUserId(userId) then return end
		local slotIndex = self:_findFreeSlot()
		if not slotIndex then
			warn(string.format("[BoatDockService] No free dock slot for user=%d", userId))
			return
		end
		self._slotOwner[slotIndex] = userId
		self._slotByUser[userId] = slotIndex
		local skinId = self:_getSkinId(userId)
		self:_spawnIdleBoat(userId, slotIndex, skinId)
	end)
end

function BoatDockService:_onPlayerRemoving(player: Player)
	local userId = player.UserId
	-- Free the slot immediately so a re-joiner can use it.
	local slotIndex = self._slotByUser[userId]
	if slotIndex then
		self._slotOwner[slotIndex] = nil
	end
	self._slotByUser[userId] = nil

	local st = self._stateByUser[userId]
	if st == "sailing" then
		-- Voyage owns the model; it will destroy at CheckinBoat. Just drop table refs.
		self._boatsByUser[userId] = nil
		self._stateByUser[userId] = nil
		self._cooldownEnds[userId] = nil
		return
	end
	-- idle | cooldown | swapping — destroy now (if a boat is present).
	self:_destroyBoat(userId)
	self._stateByUser[userId] = nil
	self._cooldownEnds[userId] = nil
end

function BoatDockService:Start()
	table.insert(self._connections, Players.PlayerAdded:Connect(function(p)
		self:_onPlayerAdded(p)
	end))
	table.insert(self._connections, Players.PlayerRemoving:Connect(function(p)
		self:_onPlayerRemoving(p)
	end))
	-- Catch players already present (studio restart scenarios).
	for _, p in ipairs(Players:GetPlayers()) do
		self:_onPlayerAdded(p)
	end

	-- Expose self to OilStateService for snapshot + skin-change callback.
	if self._oilStateService then
		if self._oilStateService.SetBoatDockService then
			self._oilStateService:SetBoatDockService(self)
		end
		if self._oilStateService.SetSkinChangedHandler then
			self._oilStateService:SetSkinChangedHandler(function(userId, newSkinId)
				self:RequestSkinSwap(userId, newSkinId)
			end)
		end
	end
end

function BoatDockService:Stop()
	for _, c in ipairs(self._connections) do
		pcall(function() c:Disconnect() end)
	end
	self._connections = {}
	for userId, _ in pairs(self._boatsByUser) do
		self:_destroyBoat(userId)
	end
	self._slotsByIndex = {}
	self._slotOwner = {}
	self._slotByUser = {}
	self._boatsByUser = {}
	self._stateByUser = {}
	self._cooldownEnds = {}
end

return BoatDockService
