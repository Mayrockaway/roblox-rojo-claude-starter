--!strict
-- BoatDockService: owns the shared 8-slot dock at workspace.dOCKS.BoatSpawn{1..8}.
-- Responsibilities:
--   * Spawn an IdleBoat_<userId> at a free slot when a player joins (after plot+skin resolve).
--   * Despawn when player leaves (free slot).
--   * CheckoutBoat / CheckinBoat handoff for OilShipmentService: idle boat becomes
--     ActiveShipmentBoat for the voyage; at voyage end the boat is destroyed and a
--     10-second cooldown runs before a fresh idle boat respawns at the same slot.
--   * 3-second cooldown on skin swap (rejected while sailing).
--   * Owner-only DeckSeat: non-owner occupants are ejected.
-- All state is in-memory; nothing persists across server restart.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CharacterTeleport = require(script.Parent.Parent.Utils.CharacterTeleport)
local ShipSkinCatalog = require(Shared:WaitForChild("Config"):WaitForChild("ShipSkinCatalog"))
local ShipRig = require(Shared:WaitForChild("Utils"):WaitForChild("ShipRig"))

local BoatDockService = {}

local SLOT_COUNT = 8
local DESTROY_COOLDOWN_SECONDS = 10
local SKIN_SWAP_COOLDOWN_SECONDS = 3
local IDLE_Y_OFFSET = 0 -- DockAnchor lands exactly on the slot part's red square
local DEBUG_DOCK_SPAWN = true

--- Pier / spawn geometry under `dOCKS` (excluding `dOCKS.Boats`). `OilShipmentService` voyage hull uses
--- `ShipmentShip`; those parts do not collide with `MarinaDock`, but still collide with `Default` (character).
local MARINA_DOCK_GROUP = "MarinaDock"

--- `Workspace.Map.MapDecor` props (buoys, etc.): voyage hulls (`ShipmentShip`) ignore them; characters still collide.
local MAP_DECOR_GROUP = "MapDecor"

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

function BoatDockService:Init(remoteService, oilStateService)
	self._remoteService = remoteService
	self._oilStateService = oilStateService
	self._connections = {} :: { RBXScriptConnection }
	self._slotsByIndex = {} :: { [number]: BasePart }
	self._slotOwner = {} :: { [number]: number? }        -- slotIndex -> userId
	self._slotByUser = {} :: { [number]: number? }       -- userId -> slotIndex
	self._boatsByUser = {} :: { [number]: Model? }       -- userId -> current boat Model
	self._stateByUser = {} :: { [number]: BoatState }
	self._cooldownEnds = {} :: { [number]: number? }     -- userId -> os.clock() timestamp

	-- Collision: voyage hulls (`ShipmentShip` in OilShipmentService) ignore each other and ignore dock meshes.
	pcall(function()
		PhysicsService:RegisterCollisionGroup("ShipmentShip")
	end)
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable("ShipmentShip", "ShipmentShip", false)
	end)
	applyMarinaDockCollisionRules()
	applyMapDecorVersusShipmentShipRules()
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

-- Keep the owner attached to the seat; eject anyone else.
function BoatDockService:_enforceOwnerOnlySeat(seat: Seat, ownerUserId: number)
	seat:SetAttribute("OwnerUserId", ownerUserId)
	local conn
	conn = seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		local occupant = seat.Occupant
		if not occupant then return end
		local char = occupant.Parent
		local player = char and Players:GetPlayerFromCharacter(char) or nil
		if player and player.UserId == ownerUserId then return end
		-- Non-owner: eject.
		pcall(function()
			occupant.Sit = false
		end)
	end)
	table.insert(self._connections, conn)
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

	-- Anchor every BasePart (static idle; no constraints, no welds, no collision-group).
	for _, d in ipairs(boat:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = true
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
		self:_enforceOwnerOnlySeat(seat, userId)
	end

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
		pcall(function() boat:Destroy() end)
	end
	self._boatsByUser[userId] = nil
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
	-- Transition to sailing.
	self._stateByUser[userId] = "sailing"
	boat:SetAttribute("IsIdleBob", false)   -- stop client bob
	boat.Name = "ActiveShipmentBoat"
	boat:SetAttribute("ShipmentId", shipmentId)
	self:_pushSnapshot(userId)
	return boat, nil
end

function BoatDockService:CheckinBoat(userId: number, opts: { destroyed: boolean? }?)
	-- Always destroy the checked-out model. If the player left during the voyage,
	-- the slot is already freed; this just drops the model and no-ops the respawn.
	self:_destroyBoat(userId)

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
--- Does NOT re-seat — the target player owns the DeckSeat. Caller lands a few
--- studs above the seat and can walk around the deck. Returns `(false, err)`
--- if the target isn't actively sailing.
function BoatDockService:TeleportSpectatorToBoat(caller: Player, targetUserId: number): (boolean, string?)
	if self._stateByUser[targetUserId] ~= "sailing" then
		return false, "TARGET_NOT_SAILING"
	end
	local boat = self._boatsByUser[targetUserId]
	if not boat then
		return false, "TARGET_BOAT_MISSING"
	end
	local seat = findSeatForBoat(boat)
	if not seat then
		return false, "SEAT_MISSING"
	end
	local character = caller.Character
	if not character then
		return false, "NO_CHARACTER"
	end
	-- Drop caller ~3 studs above the deck seat without re-seating them.
	CharacterTeleport.teleportWithUnseat(
		character,
		seat.CFrame + Vector3.new(0, 3, 0),
		string.format("BoatDock:TeleportSpectatorToBoat target=%d", targetUserId)
	)
	return true, nil
end

function BoatDockService:TeleportOwnerToSeat(player: Player): (boolean, string?)
	local boat = self._boatsByUser[player.UserId]
	local st = self._stateByUser[player.UserId]
	if st == "cooldown" or st == "swapping" then
		return false, "BOAT_COOLDOWN"
	end
	if not boat then
		return false, "BOAT_MISSING"
	end
	local seat = findSeatForBoat(boat)
	if not seat then
		return false, "SEAT_MISSING"
	end
	local character = player.Character
	if not character then return false, "NO_CHARACTER" end
	CharacterTeleport.teleportWithUnseat(character, seat.CFrame + Vector3.new(0, 3, 0), "BoatDock:TeleportOwnerToSeat")
	local hum = character:FindFirstChildOfClass("Humanoid")
	if hum then
		pcall(function() seat:Sit(hum) end)
	end
	return true, nil
end

--- Lifecycle ---

function BoatDockService:_onPlayerAdded(player: Player)
	local userId = player.UserId
	print(string.format("[BoatDockService] PlayerAdded user=%d name=%s", userId, player.Name))
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
		local boat = self:_spawnIdleBoat(userId, slotIndex, skinId)
		print(string.format("[BoatDockService] spawned user=%d slot=%d skin=%s boat=%s",
			userId, slotIndex, skinId, tostring(boat ~= nil)))
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
