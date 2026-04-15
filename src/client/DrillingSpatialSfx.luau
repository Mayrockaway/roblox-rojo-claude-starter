--!strict
-- Spatial drill loop: each client parents a local Sound clone onto the replicated ActiveDrill_*
-- model so audio follows the client-driven sink animation and attenuates with distance.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local ROLLOFF_MAX = 140
local ROLLOFF_MIN = 5
local EMITTER_SIZE = 14

local activeBySession: { [string]: Sound } = {}

local function sessionKey(ownerUserId: number, drillId: number): string
	return tostring(ownerUserId) .. ":" .. tostring(drillId)
end

local function findPlotForOwner(ownerUserId: number): Model?
	local map = Workspace:FindFirstChild("Map")
	local plots = map and map:FindFirstChild("Plots")
	if not plots then
		return nil
	end
	for _, p in ipairs(plots:GetChildren()) do
		if p:IsA("Model") and p:GetAttribute("OwnerUserId") == ownerUserId then
			return p
		end
	end
	return nil
end

local function findActiveDrillModel(ownerUserId: number, drillId: number): Instance?
	local plot = findPlotForOwner(ownerUserId)
	if not plot then
		return nil
	end
	local vis = plot:FindFirstChild("OilVisuals")
	local folder = vis and vis:FindFirstChild("ActiveDrills")
	if not folder then
		return nil
	end
	local name = "ActiveDrill_" .. tostring(drillId)
	return folder:FindFirstChild(name)
end

local function waitActiveDrillModel(ownerUserId: number, drillId: number, timeoutSec: number): Instance?
	local deadline = os.clock() + timeoutSec
	while os.clock() < deadline do
		local m = findActiveDrillModel(ownerUserId, drillId)
		if m then
			return m
		end
		task.wait(0.08)
	end
	return nil
end

local function findDrillingTemplate(): Sound?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local rsSfx = assets and assets:FindFirstChild("SFX")
	if rsSfx then
		for _, c in ipairs(rsSfx:GetChildren()) do
			if c:IsA("Sound") and string.lower(c.Name) == "drilling" then
				return c
			end
		end
	end
	local wsSfx = Workspace:FindFirstChild("SFX")
	if wsSfx then
		for _, c in ipairs(wsSfx:GetChildren()) do
			if c:IsA("Sound") and string.lower(c.Name) == "drilling" then
				return c
			end
		end
	end
	return nil
end

-- Sound may parent to BasePart or Attachment for 3D playback.
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

local function stopSession(ownerUserId: number, drillId: number)
	local key = sessionKey(ownerUserId, drillId)
	local s = activeBySession[key]
	if s then
		activeBySession[key] = nil
		s:Stop()
		s:Destroy()
	end
end

local function startSession(ownerUserId: number, drillId: number)
	local key = sessionKey(ownerUserId, drillId)
	stopSession(ownerUserId, drillId)

	local template = findDrillingTemplate()
	if not template then
		warn("[DrillingSpatialSfx] No Drilling sound template (ReplicatedStorage.Assets.SFX.Drilling or Workspace.SFX).")
		return
	end

	local model = waitActiveDrillModel(ownerUserId, drillId, 6)
	if not model then
		warn("[DrillingSpatialSfx] ActiveDrill model not found for", ownerUserId, drillId)
		return
	end

	-- Parts can arrive a frame (or more) after the Model replicates; empty fallback Models exist until a template is fixed.
	local host = waitSpatialHost(model, 8)
	if not host then
		local n = model:IsA("Model") and #model:GetDescendants() or 0
		warn("[DrillingSpatialSfx] No BasePart/Attachment host on active drill after wait:", model:GetFullName(), "descendants=", n)
		return
	end

	local snd = template:Clone()
	snd.Name = "DrillingSpatialSfx"
	snd.Looped = true
	snd.Playing = false
	snd.RollOffMode = Enum.RollOffMode.InverseTapered
	snd.RollOffMaxDistance = ROLLOFF_MAX
	snd.RollOffMinDistance = ROLLOFF_MIN
	snd.EmitterSize = EMITTER_SIZE
	snd.Parent = host
	snd:Play()
	activeBySession[key] = snd

	snd.AncestryChanged:Connect(function()
		if snd.Parent == nil and activeBySession[key] == snd then
			activeBySession[key] = nil
		end
	end)
end

local DrillingSpatialSfx = {}

function DrillingSpatialSfx.start(drillProgressUpdate: RemoteEvent)
	drillProgressUpdate.OnClientEvent:Connect(function(data: any)
		if typeof(data) ~= "table" then
			return
		end
		local kind = data.kind
		local ownerUserId = tonumber(data.ownerUserId)
		local drillId = tonumber(data.drillId)
		if not ownerUserId or not drillId then
			return
		end
		if kind == "started" then
			task.spawn(startSession, ownerUserId, drillId)
		elseif kind == "completed" then
			stopSession(ownerUserId, drillId)
		end
	end)
end

return DrillingSpatialSfx
