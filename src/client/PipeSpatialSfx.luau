--!strict
-- One-shot spatial pipe place: local Sound clone on replicated `OilVisuals.Pipes.Pipe_<cellKey>`.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local ROLLOFF_MAX = 140
local ROLLOFF_MIN = 5
local EMITTER_SIZE = 14

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

local function findPipeModel(ownerUserId: number, cellKey: string): Instance?
	local plot = findPlotForOwner(ownerUserId)
	if not plot then
		return nil
	end
	local vis = plot:FindFirstChild("OilVisuals")
	local folder = vis and vis:FindFirstChild("Pipes")
	if not folder then
		return nil
	end
	return folder:FindFirstChild("Pipe_" .. cellKey)
end

local function waitPipeModel(ownerUserId: number, cellKey: string, timeoutSec: number): Instance?
	local deadline = os.clock() + timeoutSec
	while os.clock() < deadline do
		local m = findPipeModel(ownerUserId, cellKey)
		if m then
			return m
		end
		task.wait(0.08)
	end
	return nil
end

local function findPipeTemplate(): Sound?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local rsSfx = assets and assets:FindFirstChild("SFX")
	if rsSfx then
		for _, c in ipairs(rsSfx:GetChildren()) do
			if c:IsA("Sound") and string.lower(c.Name) == "pipe" then
				return c
			end
		end
	end
	local wsSfx = Workspace:FindFirstChild("SFX")
	if wsSfx then
		for _, c in ipairs(wsSfx:GetChildren()) do
			if c:IsA("Sound") and string.lower(c.Name) == "pipe" then
				return c
			end
		end
	end
	return nil
end

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

local function playOnce(ownerUserId: number, cellKey: string)
	local template = findPipeTemplate()
	if not template then
		warn("[PipeSpatialSfx] No Pipe sound template (ReplicatedStorage.Assets.SFX.Pipe or Workspace.SFX).")
		return
	end

	local model = waitPipeModel(ownerUserId, cellKey, 6)
	if not model then
		warn("[PipeSpatialSfx] Pipe model not found:", ownerUserId, cellKey)
		return
	end

	local host = waitSpatialHost(model, 8)
	if not host then
		local n = model:IsA("Model") and #model:GetDescendants() or 0
		warn("[PipeSpatialSfx] No BasePart/Attachment host on pipe:", model:GetFullName(), "descendants=", n)
		return
	end

	local snd = template:Clone()
	snd.Name = "PipePlaceSpatialSfx"
	snd.Looped = false
	snd.Playing = false
	snd.RollOffMode = Enum.RollOffMode.InverseTapered
	snd.RollOffMaxDistance = ROLLOFF_MAX
	snd.RollOffMinDistance = ROLLOFF_MIN
	snd.EmitterSize = EMITTER_SIZE
	snd.Parent = host
	snd.Ended:Once(function()
		snd:Destroy()
	end)
	snd:Play()
end

local PipeSpatialSfx = {}

function PipeSpatialSfx.start(pipePlacedFx: RemoteEvent)
	pipePlacedFx.OnClientEvent:Connect(function(data: any)
		if typeof(data) ~= "table" then
			return
		end
		local ownerUserId = tonumber(data.ownerUserId)
		local cellKey = data.cellKey
		if not ownerUserId or typeof(cellKey) ~= "string" or cellKey == "" then
			return
		end
		task.spawn(playOnce, ownerUserId, cellKey)
	end)
end

return PipeSpatialSfx
