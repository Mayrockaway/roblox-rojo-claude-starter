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

local BoatDockService = {}

local SLOT_COUNT = 8
local DESTROY_COOLDOWN_SECONDS = 10
local SKIN_SWAP_COOLDOWN_SECONDS = 3
local IDLE_Y_OFFSET = 0 -- DockAnchor lands exactly on the slot part's red square

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

	-- Collision group: ships don't collide with each other (idempotent).
	pcall(function()
		PhysicsService:RegisterCollisionGroup("ShipmentShip")
	end)
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable("ShipmentShip", "ShipmentShip", false)
	end)

	self:_discoverSlots()
end

function BoatDockService:_discoverSlots()
	local docks = Workspace:FindFirstChild("dOCKS")
		or Workspace:FindFirstChild("Docks")
		or Workspace:FindFirstChild("DOCKS")
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

function BoatDockService:_resolveTemplate(skinId: string): Instance?
	local assetsFolder = ReplicatedStorage:FindFirstChild("Assets")
	if not assetsFolder then return nil end
	local skin = ShipSkinCatalog.GetSkin(skinId)
	local templateName = skin and skin.templateName or nil
	local tpl = templateName and assetsFolder:FindFirstChild(templateName)
	if not (tpl and (tpl:IsA("Model") or tpl:IsA("BasePart"))) then
		tpl = assetsFolder:FindFirstChild("Tanker") -- fallback
	end
	return tpl
end

function BoatDockService:_ensureBoatsFolder(): Folder
	local docks = Workspace:FindFirstChild("dOCKS")
		or Workspace:FindFirstChild("Docks")
		or Workspace:FindFirstChild("DOCKS")
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
	local tpl = self:_resolveTemplate(skinId)
	if not tpl then
		warn(string.format("[BoatDockService] No boat template resolvable for user=%d skin=%s", userId, tostring(skinId)))
		return nil
	end

	local boat = (tpl :: Instance):Clone()
	if not boat:IsA("Model") then
		-- Wrap a lone Part into a Model for uniformity.
		local wrap = Instance.new("Model")
		wrap.Name = tpl.Name
		boat.Parent = wrap
		boat = wrap
	end
	boat.Name = "IdleBoat_" .. tostring(userId)

	-- Anchor every BasePart (static idle — no constraints, no welds, no collision-group).
	for _, d in ipairs(boat:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = true
		end
	end

	-- Pose the ship so:
	--   (a) DockAnchor Attachment lands on the slot's red square (+ IDLE_Y_OFFSET),
	--   (b) FRONT_MARKER direction aligns with the slot's LookVec (out to sea).
	-- Each skin's internal axes can be arbitrary — we infer ship-forward from
	-- (FRONT_MARKER.pos - DockAnchor.pos) rather than hardcoding a rotation.
	boat:PivotTo(CFrame.new())

	local dockAnchor: Attachment? = nil
	local frontMarker: BasePart? = nil
	for _, d in ipairs(boat:GetDescendants()) do
		if d:IsA("Attachment") and d.Name == "DockAnchor" then
			dockAnchor = d
		elseif d:IsA("BasePart") and d.Name == "FRONT_MARKER" then
			frontMarker = d
		end
	end

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
		-- Yaw that rotates shipForwardLocal onto slotForward, plus 180° flip so the
		-- DockAnchor (stern) sits at the slot with the bow pointing AWAY from the dock.
		local currentYaw = math.atan2(shipForwardLocal.X, shipForwardLocal.Z)
		local targetYaw = math.atan2(slotForward.X, slotForward.Z) + math.pi
		local yawDelta = targetYaw - currentYaw
		local rotation = CFrame.Angles(0, yawDelta, 0)
		local rotatedAnchor = rotation * anchorLocal
		local targetPos = slotPart.Position + Vector3.new(0, IDLE_Y_OFFSET, 0)
		local shipOriginPos = targetPos - Vector3.new(rotatedAnchor.X, rotatedAnchor.Y, rotatedAnchor.Z)
		baseCFrame = CFrame.new(shipOriginPos) * rotation
	else
		-- Fallback: fixed 90° yaw (Tanker-only behavior) + translate so anchor ~ slot center.
		local rotation = CFrame.Angles(0, math.pi / 2, 0)
		local rotatedAnchor = rotation * anchorLocal
		local targetPos = slotPart.Position + Vector3.new(0, IDLE_Y_OFFSET, 0)
		local shipOriginPos = targetPos - Vector3.new(rotatedAnchor.X, rotatedAnchor.Y, rotatedAnchor.Z)
		baseCFrame = CFrame.new(shipOriginPos) * rotation
	end

	boat:PivotTo(baseCFrame)

	-- Attributes the client rocking script + voyage handoff read.
	boat:SetAttribute("OwnerUserId", userId)
	boat:SetAttribute("SlotIndex", slotIndex)
	boat:SetAttribute("IsIdleBob", true)
	boat:SetAttribute("DockCFrame", baseCFrame)

	-- Find DeckSeat and enforce owner-only.
	local seat = boat:FindFirstChild("DeckSeat", true)
	if seat and seat:IsA("Seat") then
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

function BoatDockService:TeleportOwnerToSeat(player: Player): (boolean, string?)
	local boat = self._boatsByUser[player.UserId]
	local st = self._stateByUser[player.UserId]
	if st == "cooldown" or st == "swapping" then
		return false, "BOAT_COOLDOWN"
	end
	if not boat then
		return false, "BOAT_MISSING"
	end
	local seat = boat:FindFirstChild("DeckSeat", true)
	if not (seat and seat:IsA("Seat")) then
		return false, "SEAT_MISSING"
	end
	local character = player.Character
	if not character then return false, "NO_CHARACTER" end
	CharacterTeleport.unseatIfSitting(character)
	character:PivotTo(seat.CFrame + Vector3.new(0, 3, 0))
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
