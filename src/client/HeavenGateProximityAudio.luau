--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local LocalPlayer = Players.LocalPlayer

local AUDIO_MARKER_NAME = "OTS_HeavenGateAudioEmitter"
local SOUND_ID = "rbxassetid://105341153226678"
local MAX_VOLUME = 1.6
local START_DISTANCE = 26
local FULL_VOLUME_DISTANCE = 6

local HeavenGateProximityAudio = {}

local started = false
local loopSound: Sound? = nil
local lastScanClock = 0
local cachedMainGateCenter: Vector3? = nil
local cachedSkyGateCenter: Vector3? = nil

local function getCharacterRoot(): BasePart?
	local character = LocalPlayer.Character
	if not character then
		return nil
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp
	end
	return nil
end

local function resolveGateCenter(container: Instance?): Vector3?
	if container == nil then
		return nil
	end
	local marker = container:FindFirstChild(AUDIO_MARKER_NAME, true)
	if marker and marker:IsA("BasePart") then
		return marker.Position
	end
	if container:IsA("Model") then
		local cf = container:GetPivot()
		return cf.Position
	end
	if container:IsA("BasePart") then
		return container.Position
	end
	return nil
end

local function findNearestMainGateCenter(rootPos: Vector3): Vector3?
	local map = Workspace:FindFirstChild("Map")
	local plots = map and map:FindFirstChild("Plots")
	if plots == nil then
		return nil
	end
	local bestCenter = nil
	local bestDistance = math.huge
	for _, plot in ipairs(plots:GetChildren()) do
		if plot:IsA("Model") then
			local gateRoot = plot:FindFirstChild("heavengate")
			local gates = gateRoot and (gateRoot:FindFirstChild("Gates") or gateRoot)
			local center = resolveGateCenter(gates)
			if center then
				local distance = (rootPos - center).Magnitude
				if distance < bestDistance then
					bestDistance = distance
					bestCenter = center
				end
			end
		end
	end
	return bestCenter
end

local function findNearestSkyGateCenter(rootPos: Vector3): Vector3?
	local bestCenter = nil
	local bestDistance = math.huge
	for _, child in ipairs(Workspace:GetChildren()) do
		if child:IsA("Model") and string.match(child.Name, "^OilHeavenPlot_%d%d$") then
			local landing = child:FindFirstChild("LandingPlotHeaven")
			local gateRoot = landing and landing:FindFirstChild("ANGELGATE")
			local center = resolveGateCenter(gateRoot)
			if center then
				local distance = (rootPos - center).Magnitude
				if distance < bestDistance then
					bestDistance = distance
					bestCenter = center
				end
			end
		end
	end
	return bestCenter
end

local function refreshGateCenters(nowClock: number, rootPos: Vector3)
	if nowClock - lastScanClock < 0.4 then
		return
	end
	lastScanClock = nowClock
	cachedMainGateCenter = findNearestMainGateCenter(rootPos)
	cachedSkyGateCenter = findNearestSkyGateCenter(rootPos)
end

local function ensureLoopSound(): Sound
	if loopSound and loopSound.Parent then
		return loopSound
	end

	local sound = Instance.new("Sound")
	sound.Name = "HeavenGateProximityLoop"
	sound.SoundId = SOUND_ID
	sound.Looped = true
	sound.Volume = 0
	sound.Parent = SoundService
	sound:Play()
	loopSound = sound
	return sound
end

local function volumeFromDistance(distance: number): number
	if distance >= START_DISTANCE then
		return 0
	end
	if distance <= FULL_VOLUME_DISTANCE then
		return MAX_VOLUME
	end
	local alpha = 1 - ((distance - FULL_VOLUME_DISTANCE) / (START_DISTANCE - FULL_VOLUME_DISTANCE))
	alpha = math.clamp(alpha, 0, 1)
	return MAX_VOLUME * alpha
end

local function computeTargetVolume(nowClock: number): number
	local root = getCharacterRoot()
	if root == nil then
		return 0
	end

	refreshGateCenters(nowClock, root.Position)

	local bestDistance = math.huge
	if cachedMainGateCenter then
		bestDistance = math.min(bestDistance, (root.Position - cachedMainGateCenter).Magnitude)
	end
	if cachedSkyGateCenter then
		bestDistance = math.min(bestDistance, (root.Position - cachedSkyGateCenter).Magnitude)
	end

	if bestDistance == math.huge then
		return 0
	end
	return volumeFromDistance(bestDistance)
end

function HeavenGateProximityAudio.start()
	if started then
		return
	end
	started = true

	RunService.Heartbeat:Connect(function(dt: number)
		local sound = ensureLoopSound()
		local targetVolume = computeTargetVolume(os.clock())
		local blend = math.clamp(dt * 10, 0, 1)
		sound.Volume = sound.Volume + (targetVolume - sound.Volume) * blend
	end)
end

return HeavenGateProximityAudio
