--!strict
-- Looping spatial ocean on the local player's ActiveShipmentBoat. Starts as soon as the
-- voyage boat exists (after ShipmentStarted); stops on ShipmentResolved or boat destroy.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local ROLLOFF_MAX = 320
local ROLLOFF_MIN = 8
local EMITTER_SIZE = 48
--- Multiplier on top of the authored `Assets.SFX.OceanWaves.Volume` (currently 0.55)
--- so we can tune voyage loudness without touching the template (which is also
--- used for any non-loop preview). 2.0 = double — bumped per playtest 2026-04.
local VOLUME_SCALE = 2.0

local player = Players.LocalPlayer

local activeShipmentId: string? = nil
local voyageThread: thread? = nil
local boatDestroyConn: RBXScriptConnection? = nil
local loopSound: Sound? = nil

local function disconnectBoatWatch()
	if boatDestroyConn then
		boatDestroyConn:Disconnect()
		boatDestroyConn = nil
	end
end

local function destroyAttachedSoundOnly()
	disconnectBoatWatch()
	if loopSound then
		loopSound:Stop()
		loopSound:Destroy()
		loopSound = nil
	end
end

local function stopWaves()
	if voyageThread then
		task.cancel(voyageThread)
		voyageThread = nil
	end
	destroyAttachedSoundOnly()
	activeShipmentId = nil
end

local function shipmentIdFromData(data: any): string?
	local sid = (data :: any).shipmentId
	if typeof(sid) == "string" and sid ~= "" then
		return sid
	end
	if sid ~= nil then
		local t = tostring(sid)
		if t ~= "" then
			return t
		end
	end
	return nil
end

local function ownerIdFromData(data: any): number?
	local u = (data :: any).ownerUserId or (data :: any).playerUserId
	if typeof(u) == "number" then
		return u
	end
	return nil
end

--- Collect ActiveShipmentBoat models under **`dOCKS.Boats`** (`BoatDockService:_ensureBoatsFolder`), not whole Workspace.
local function getDocksRootForBoats(): Instance?
	return Workspace:FindFirstChild("dOCKS")
		or Workspace:FindFirstChild("Docks")
		or Workspace:FindFirstChild("DOCKS")
		or Workspace:FindFirstChild("dOCKS", true)
end

local function collectActiveShipmentBoats(): { Model }
	local out: { Model } = {}
	local docks = getDocksRootForBoats()
	local boatsFolder = docks and docks:FindFirstChild("Boats")
	if boatsFolder and boatsFolder:IsA("Folder") then
		for _, inst in ipairs(boatsFolder:GetChildren()) do
			if inst:IsA("Model") and inst.Name == "ActiveShipmentBoat" then
				table.insert(out, inst)
			end
		end
	end
	return out
end

local function ownerMatchesBoat(boat: Model): boolean
	local ownerAttr = boat:GetAttribute("OwnerUserId")
	if typeof(ownerAttr) ~= "number" then
		return true
	end
	return ownerAttr == player.UserId
end

--- Prefer ShipmentId match (handles multiple tankers). If ShipmentId has not replicated yet,
--- fall back to OwnerUserId — only one ActiveShipmentBoat per owner during a voyage.
local function findActiveShipmentBoat(shipmentId: string): Model?
	local boats = collectActiveShipmentBoats()
	for _, boat in ipairs(boats) do
		if not ownerMatchesBoat(boat) then
			continue
		end
		local sid = boat:GetAttribute("ShipmentId")
		if sid ~= nil and tostring(sid) == shipmentId then
			return boat
		end
	end
	for _, boat in ipairs(boats) do
		local ownerAttr = boat:GetAttribute("OwnerUserId")
		if ownerAttr == player.UserId then
			return boat
		end
	end
	return nil
end

local function waitActiveShipmentBoat(shipmentId: string, timeoutSec: number): Model?
	local deadline = os.clock() + timeoutSec
	while os.clock() < deadline do
		if activeShipmentId ~= shipmentId then
			return nil
		end
		local b = findActiveShipmentBoat(shipmentId)
		if b then
			return b
		end
		task.wait(0.05)
	end
	return nil
end

local function findOceanTemplate(): Sound?
	local key = "oceanwaves"
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local rsSfx = assets and assets:FindFirstChild("SFX")
	if rsSfx then
		local direct = rsSfx:FindFirstChild("OceanWaves")
		if direct and direct:IsA("Sound") then
			return direct
		end
		for _, c in ipairs(rsSfx:GetChildren()) do
			if c:IsA("Sound") and string.lower(c.Name) == key then
				return c
			end
		end
	end
	local wsSfx = Workspace:FindFirstChild("SFX")
	if wsSfx then
		for _, c in ipairs(wsSfx:GetChildren()) do
			if c:IsA("Sound") and string.lower(c.Name) == key then
				return c
			end
		end
	end
	return nil
end

--- Owner always gets waves; spectators only when already seated on that shipment's boat (Teleport-to-ship join).
local function shouldHandleShipmentStarted(data: any): boolean
	local ownerUid = ownerIdFromData(data)
	local sid = shipmentIdFromData(data)
	if not sid then
		return false
	end
	if typeof(ownerUid) == "number" and ownerUid == player.UserId then
		return true
	end
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local seat = hum and hum.SeatPart
	if not seat then
		return false
	end
	local boat = seat:FindFirstAncestorWhichIsA("Model")
	return boat ~= nil
		and boat.Name == "ActiveShipmentBoat"
		and tostring(boat:GetAttribute("ShipmentId") or "") == sid
end

--- Just call :Play() — Roblox queues playback internally if the asset
--- isn't ready yet. The previous `Sound.Loaded:Wait()` gate looked safe
--- because we checked `IsLoaded == false` first, but `task.defer` yields
--- a frame and the asset routinely finishes loading between the
--- `IsLoaded` check and the `:Wait()` call. Once `IsLoaded == true`, the
--- `Loaded` signal will not fire again, so `:Wait()` blocked forever and
--- the voyage waves never started — see chat 2026-04 "ocean waves audio
--- isn't playing on voyage".
local function playSpatialLoop(s: Sound)
	if s.Parent then
		s:Play()
	end
end

-- Same host strategy as DrillingSpatialSfx (parts can replicate after the Model).
local function findSpatialHostOnce(model: Instance): Instance?
	if model:IsA("Model") then
		local pp = model.PrimaryPart
		if pp and pp:IsA("BasePart") then
			return pp
		end
		local part = model:FindFirstChildWhichIsA("BasePart", true)
		if part then
			return part
		end
		return model:FindFirstChildWhichIsA("Attachment", true)
	elseif model:IsA("BasePart") then
		return model
	end
	return nil
end

local function waitSpatialHost(model: Instance, timeoutSec: number): Instance?
	local deadline = os.clock() + timeoutSec
	while os.clock() < deadline do
		local host = findSpatialHostOnce(model)
		if host then
			return host
		end
		task.wait(0.05)
	end
	return nil
end

local function attachLoopToBoat(boat: Model, shipmentId: string, template: Sound)
	if activeShipmentId ~= shipmentId then
		return
	end
	destroyAttachedSoundOnly()

	local host = waitSpatialHost(boat, 12)
	if not host then
		warn("[ShipmentOceanWavesSfx] No BasePart/Attachment host on ActiveShipmentBoat after wait:", boat:GetFullName())
		activeShipmentId = nil
		return
	end

	local s = template:Clone()
	s.Name = "ShipmentOceanWavesLoop"
	s.Looped = true
	s.Playing = false
	s.Volume = template.Volume * VOLUME_SCALE
	s.RollOffMode = Enum.RollOffMode.InverseTapered
	s.RollOffMaxDistance = ROLLOFF_MAX
	s.RollOffMinDistance = ROLLOFF_MIN
	s.EmitterSize = EMITTER_SIZE
	s.Parent = host
	playSpatialLoop(s)
	loopSound = s

	boatDestroyConn = boat.Destroying:Connect(function()
		if activeShipmentId == shipmentId then
			stopWaves()
		end
	end)
end

local function runVoyageWaves(shipmentId: string, isOwner: boolean)
	if activeShipmentId ~= shipmentId then
		return
	end

	local boat = waitActiveShipmentBoat(shipmentId, 45)
	if not boat or activeShipmentId ~= shipmentId then
		if isOwner and RunService:IsStudio() then
			warn("[ShipmentOceanWavesSfx] Timed out waiting for ActiveShipmentBoat (owner). shipmentId=", shipmentId)
		end
		return
	end

	local template = findOceanTemplate()
	if not template then
		warn("[ShipmentOceanWavesSfx] No OceanWaves template (ReplicatedStorage.Assets.SFX or Workspace.SFX).")
		activeShipmentId = nil
		return
	end

	attachLoopToBoat(boat, shipmentId, template)
end

local ShipmentOceanWavesSfx = {}

function ShipmentOceanWavesSfx.onVisualPacket(kind: string, data: any)
	if kind == "ShipmentResolved" then
		local sid = shipmentIdFromData(data)
		if sid and activeShipmentId and sid ~= activeShipmentId then
			return
		end
		stopWaves()
		return
	end

	if kind == "ShipmentStarted" then
		if not shouldHandleShipmentStarted(data) then
			return
		end
		stopWaves()
		local sid = shipmentIdFromData(data)
		if not sid then
			return
		end
		local isOwner = ownerIdFromData(data) == player.UserId
		activeShipmentId = sid
		voyageThread = task.spawn(function()
			runVoyageWaves(sid, isOwner)
			voyageThread = nil
		end)
	end
end

return ShipmentOceanWavesSfx
