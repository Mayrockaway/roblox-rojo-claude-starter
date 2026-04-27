--!strict
--- Client-side ambient controller for Oil Heaven. Watches the `CurrentWorld`
--- player attribute and crossfades between normal BGM and Oil Heaven BGM
--- when the player teleports to/from the sky island.

local Players = game:GetService("Players")
local SoundService = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local OilHeavenConfig = require(Shared:WaitForChild("Config"):WaitForChild("OilHeavenConfig"))

local LocalPlayer = Players.LocalPlayer

local HEAVEN_BGM_NAME = "OTS_HeavenBGM"
local MAIN_BGM_NAME = "OTS_ClientBGM"
local FADE_DURATION = 1.0

local OilHeavenAmbient = {}

local heavenSound: Sound? = nil
local currentWorld: string = Constants.WorldMain

local function getMainBgm(): Sound?
	return SoundService:FindFirstChild(MAIN_BGM_NAME) :: Sound?
end

local function getOrCreateHeavenBgm(): Sound
	local existing = SoundService:FindFirstChild(HEAVEN_BGM_NAME)
	if existing and existing:IsA("Sound") then
		return existing
	end
	local s = Instance.new("Sound")
	s.Name = HEAVEN_BGM_NAME
	s.SoundId = OilHeavenConfig.HeavenBgmSoundId
	s.Volume = 0
	s.Looped = true
	s.Playing = false
	s.Parent = SoundService
	return s
end

local function fadeSound(sound: Sound?, targetVolume: number, duration: number, thenStop: boolean?)
	if not sound or not sound.Parent then return end
	task.spawn(function()
		local startVol = sound.Volume
		local elapsed = 0
		while elapsed < duration do
			elapsed += task.wait()
			local alpha = math.min(elapsed / duration, 1)
			sound.Volume = startVol + (targetVolume - startVol) * alpha
		end
		sound.Volume = targetVolume
		if thenStop and targetVolume <= 0.001 then
			sound.Playing = false
		end
	end)
end

local function transitionToHeaven()
	local mainBgm = getMainBgm()
	local heavenBgm = getOrCreateHeavenBgm()

	-- Fade out main BGM
	if mainBgm and mainBgm:IsA("Sound") and mainBgm.Playing then
		fadeSound(mainBgm, 0, FADE_DURATION, true)
	end

	-- Fade in heaven BGM
	heavenBgm.Volume = 0
	heavenBgm.Playing = true
	fadeSound(heavenBgm, OilHeavenConfig.HeavenBgmVolume, FADE_DURATION)
end

local function transitionToMain()
	local mainBgm = getMainBgm()
	local heavenBgm = SoundService:FindFirstChild(HEAVEN_BGM_NAME) :: Sound?

	-- Fade out heaven BGM
	if heavenBgm and heavenBgm:IsA("Sound") and heavenBgm.Playing then
		fadeSound(heavenBgm, 0, FADE_DURATION, true)
	end

	-- Fade in main BGM
	if mainBgm and mainBgm:IsA("Sound") then
		mainBgm.Playing = true
		fadeSound(mainBgm, 0.07, FADE_DURATION)
	end
end

function OilHeavenAmbient.start()
	local function onWorldChanged()
		local world = LocalPlayer:GetAttribute(Constants.CurrentWorldAttribute)
		if typeof(world) ~= "string" then
			world = Constants.WorldMain
		end

		if world == currentWorld then return end
		currentWorld = world

		if world == Constants.WorldOilHeaven then
			transitionToHeaven()
		else
			transitionToMain()
		end
	end

	LocalPlayer:GetAttributeChangedSignal(Constants.CurrentWorldAttribute):Connect(onWorldChanged)
	-- Check initial state (in case attribute was set before this module loaded)
	onWorldChanged()
end

return OilHeavenAmbient
