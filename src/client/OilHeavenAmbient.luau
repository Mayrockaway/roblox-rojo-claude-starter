--!strict
--- Client-side ambient controller for Oil Heaven. Watches the `CurrentWorld`
--- player attribute and crossfades between normal BGM and Oil Heaven BGM
--- when the player teleports to/from the sky island.

local Players = game:GetService("Players")
local SoundService = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local ContentProvider = game:GetService("ContentProvider")
local Workspace = game:GetService("Workspace")

local HeavenPillarFloat = require(script.Parent:WaitForChild("HeavenPillarFloat"))
local OilHeavenWings = require(script.Parent:WaitForChild("OilHeavenWings"))
local getClientRemotes = require(script.Parent:WaitForChild("GetClientRemotes")) :: () -> any

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local OilHeavenConfig = require(Shared:WaitForChild("Config"):WaitForChild("OilHeavenConfig"))

local LocalPlayer = Players.LocalPlayer

local HEAVEN_BGM_NAME = "OTS_HeavenBGM"
local MAIN_BGM_NAME = "OTS_ClientBGM"
local HEAVEN_SKY_NAME = "OTS_HeavenSky"
local FADE_DURATION = 1.0

local HEAVEN_SKY_PROPS = {
	SkyboxBk = "http://www.roblox.com/asset?id=58372690",
	SkyboxDn = "http://www.roblox.com/asset?id=58372722",
	SkyboxFt = "http://www.roblox.com/asset?id=58372742",
	SkyboxLf = "http://www.roblox.com/asset?id=58372777",
	SkyboxRt = "http://www.roblox.com/asset?id=58372794",
	SkyboxUp = "http://www.roblox.com/asset?id=58372812",
	CelestialBodiesShown = true,
	MoonAngularSize = 11,
	SunAngularSize = 21,
	StarCount = 3000,
	MoonTextureId = "rbxasset://sky/moon.jpg",
	SunTextureId = "rbxasset://sky/sun.jpg",
}

--- Lighting overrides applied while in OilHeaven. The project's
--- `OutdoorAmbient = (221, 255, 225)` + neon-white clouds + bright skybox
--- combine to wash out the scene; these values knock the overall exposure
--- down to a more readable level without changing the heavenly aesthetic.
--- Restored on exit so the main world keeps its authored look.
local HEAVEN_LIGHTING_OVERRIDES = {
	Brightness = 0.9,
	ExposureCompensation = -0.25,
	OutdoorAmbient = Color3.fromRGB(155, 165, 180),
	EnvironmentDiffuseScale = 0.85,
}

local OilHeavenAmbient = {}

local heavenSound: Sound? = nil
local currentWorld: string = Constants.WorldMain
local savedSkies: { Sky } = {}
local savedLighting: { [string]: any } = {}
local heavenVisualActive = false
local boundsLoopToken = 0
local preloadStarted = false

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

--- Snapshot current Lighting properties + apply OilHeaven overrides. The
--- snapshot lives across the whole heaven session and is restored verbatim
--- on exit. Idempotent — re-entering heaven without exiting won't double-
--- snapshot (we only save on the first transition into heaven).
local function snapshotAndApplyLighting()
	if next(savedLighting) ~= nil then
		-- Already snapshotted — re-apply the overrides in case something
		-- else (a strait event, a boat skin tween, etc.) clobbered them.
		for prop, value in pairs(HEAVEN_LIGHTING_OVERRIDES) do
			(Lighting :: any)[prop] = value
		end
		return
	end
	for prop, _ in pairs(HEAVEN_LIGHTING_OVERRIDES) do
		savedLighting[prop] = (Lighting :: any)[prop]
	end
	for prop, value in pairs(HEAVEN_LIGHTING_OVERRIDES) do
		(Lighting :: any)[prop] = value
	end
end

local function restoreLighting()
	if next(savedLighting) == nil then
		return
	end
	for prop, value in pairs(savedLighting) do
		(Lighting :: any)[prop] = value
	end
	table.clear(savedLighting)
end

local function snapshotAndClearCurrentSkies()
	table.clear(savedSkies)
	for _, child in ipairs(Lighting:GetChildren()) do
		if child:IsA("Sky") then
			table.insert(savedSkies, child:Clone())
			child:Destroy()
		end
	end
end

local function createHeavenSky(): Sky
	local sky = Instance.new("Sky")
	sky.Name = HEAVEN_SKY_NAME
	for prop, value in pairs(HEAVEN_SKY_PROPS) do
		(sky :: any)[prop] = value
	end
	return sky
end

local function preloadHeavenVisuals()
	if preloadStarted then
		return
	end
	preloadStarted = true

	task.spawn(function()
		local contentIds = {
			HEAVEN_SKY_PROPS.SkyboxBk,
			HEAVEN_SKY_PROPS.SkyboxDn,
			HEAVEN_SKY_PROPS.SkyboxFt,
			HEAVEN_SKY_PROPS.SkyboxLf,
			HEAVEN_SKY_PROPS.SkyboxRt,
			HEAVEN_SKY_PROPS.SkyboxUp,
			OilHeavenConfig.HeavenBgmSoundId,
		}

		local ok, err = pcall(function()
			ContentProvider:PreloadAsync(contentIds)
		end)
		if not ok then
			warn("[OilHeavenAmbient] Failed to preload Heaven visuals:", err)
		end
	end)
end

local function ensureHeavenSky()
	local existing = Lighting:FindFirstChild(HEAVEN_SKY_NAME)
	if existing and existing:IsA("Sky") then
		return
	end

	snapshotAndClearCurrentSkies()
	createHeavenSky().Parent = Lighting
end

local function restoreSavedSkies()
	for _, child in ipairs(Lighting:GetChildren()) do
		if child:IsA("Sky") then
			child:Destroy()
		end
	end

	for _, template in ipairs(savedSkies) do
		template:Clone().Parent = Lighting
	end
end

local function transitionToHeaven()
	if heavenVisualActive then return end
	heavenVisualActive = true
	local mainBgm = getMainBgm()
	local heavenBgm = getOrCreateHeavenBgm()
	ensureHeavenSky()
	snapshotAndApplyLighting()
	-- Wings track the same bounds state as visuals + BGM. Activating here
	-- (instead of in OilHeavenWings on world-attribute change) means falling
	-- off the cloud edge cleanly removes wings — the bounds loop sees HRP
	-- outside, calls transitionToMain, wings cleanup runs.
	OilHeavenWings.activate()

	-- Fade out main BGM
	if mainBgm and mainBgm:IsA("Sound") and mainBgm.Playing then
		fadeSound(mainBgm, 0, FADE_DURATION, true)
	end

	-- Fade in heaven BGM
	heavenBgm.Volume = 0
	heavenBgm.Playing = true
	fadeSound(heavenBgm, OilHeavenConfig.HeavenBgmVolume, FADE_DURATION)

	HeavenPillarFloat.start()
end

local function transitionToMain()
	if not heavenVisualActive then return end
	heavenVisualActive = false
	local mainBgm = getMainBgm()
	local heavenBgm = SoundService:FindFirstChild(HEAVEN_BGM_NAME) :: Sound?
	restoreSavedSkies()
	restoreLighting()
	OilHeavenWings.cleanup()
	-- Tell the server to strip the angel-wings + halo accessories so they
	-- don't linger visually after the player has fallen out of bounds.
	-- Explicit teleport-out paths (HUD Home button, ANGELGATE return prompt)
	-- already remove accessories server-side; this fires for the falling-
	-- off-the-edge case where no teleport remote runs. Idempotent on the
	-- server (removeHeavenAccessories iterates and destroys; if there are
	-- none to destroy it's a no-op). pcall'd so a remote-load failure
	-- doesn't break the visual transition.
	pcall(function()
		local remotes = getClientRemotes()
		if remotes and remotes.requestRemoveHeavenAccessories then
			remotes.requestRemoveHeavenAccessories:FireServer()
		end
	end)

	-- Fade out heaven BGM
	if heavenBgm and heavenBgm:IsA("Sound") and heavenBgm.Playing then
		fadeSound(heavenBgm, 0, FADE_DURATION, true)
	end

	HeavenPillarFloat.stop()

	-- Fade in main BGM
	if mainBgm and mainBgm:IsA("Sound") then
		mainBgm.Playing = true
		fadeSound(mainBgm, 0.07, FADE_DURATION)
	end
end

local function getSkyBoxBounds()
	local skyBox = Workspace:FindFirstChild("SkyBox")
	if not skyBox then return nil end

	local floor = skyBox:FindFirstChild("Floor")
	local ceiling = skyBox:FindFirstChild("Ceiling")
	local wallPosX = skyBox:FindFirstChild("WallPosX")
	local wallNegX = skyBox:FindFirstChild("WallNegX")
	local wallPosZ = skyBox:FindFirstChild("WallPosZ")
	local wallNegZ = skyBox:FindFirstChild("WallNegZ")
	if not (floor and ceiling and wallPosX and wallNegX and wallPosZ and wallNegZ) then
		return nil
	end

	if not (floor:IsA("BasePart") and ceiling:IsA("BasePart") and wallPosX:IsA("BasePart")
		and wallNegX:IsA("BasePart") and wallPosZ:IsA("BasePart") and wallNegZ:IsA("BasePart"))
	then
		return nil
	end

	return {
		minX = wallNegX.Position.X,
		maxX = wallPosX.Position.X,
		minY = floor.Position.Y,
		maxY = ceiling.Position.Y,
		minZ = wallNegZ.Position.Z,
		maxZ = wallPosZ.Position.Z,
	}
end

local function isInsideHeavenSkyBox(): boolean
	local character = LocalPlayer.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then
		return false
	end

	local bounds = getSkyBoxBounds()
	if not bounds then
		return false
	end

	local pos = hrp.Position
	return pos.X >= bounds.minX and pos.X <= bounds.maxX
		and pos.Y >= bounds.minY and pos.Y <= bounds.maxY
		and pos.Z >= bounds.minZ and pos.Z <= bounds.maxZ
end

local function startBoundsVisualLoop()
	boundsLoopToken += 1
	local myToken = boundsLoopToken

	task.spawn(function()
		while boundsLoopToken == myToken and currentWorld == Constants.WorldOilHeaven do
			if isInsideHeavenSkyBox() then
				transitionToHeaven()
			else
				transitionToMain()
			end
			task.wait(0.15)
		end
	end)
end

function OilHeavenAmbient.start()
	preloadHeavenVisuals()

	local function onWorldChanged()
		local world = LocalPlayer:GetAttribute(Constants.CurrentWorldAttribute)
		if typeof(world) ~= "string" then
			world = Constants.WorldMain
		end

		if world == currentWorld then return end
		currentWorld = world

		if world == Constants.WorldOilHeaven then
			startBoundsVisualLoop()
		else
			boundsLoopToken += 1
			transitionToMain()
		end
	end

	LocalPlayer:GetAttributeChangedSignal(Constants.CurrentWorldAttribute):Connect(onWorldChanged)
	LocalPlayer.CharacterAdded:Connect(function()
		if currentWorld == Constants.WorldOilHeaven then
			startBoundsVisualLoop()
		end
	end)
	-- Check initial state (in case attribute was set before this module loaded)
	onWorldChanged()
end

return OilHeavenAmbient
