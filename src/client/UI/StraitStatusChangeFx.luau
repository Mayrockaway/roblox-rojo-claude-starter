--!strict
-- 3-second cinematic when the strait state changes:
-- swap the Sky instance's skybox textures to the color-coded variant,
-- show giant announcement text, play horn.

local TweenService     = game:GetService("TweenService")
local SoundService     = game:GetService("SoundService")
local Lighting         = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris           = game:GetService("Debris")

local StraitStatusChangeFx = {}

local COLOR_FOR_STATE: { [string]: Color3 } = {
	Open       = Color3.fromRGB(70, 220, 90),
	Restricted = Color3.fromRGB(255, 210, 60),
	Closed     = Color3.fromRGB(255, 60, 60),
}

-- Maps strait state → child name inside ReplicatedStorage.StraitSkyboxes
local SKYBOX_SOURCE_NAME: { [string]: string } = {
	Open       = "Sky_Open",
	Restricted = "Sky_Restricted",
	Closed     = "Sky_Closed",
}
local SKYBOX_FOLDER_NAME = "StraitSkyboxes"

local HORN_SOUND_ID = "rbxassetid://9114145977"

local SEQUENCE_DUR = 3.0
local FADE_IN_DUR  = 0.4
local HOLD_DUR     = 1.8
local FADE_OUT_DUR = SEQUENCE_DUR - FADE_IN_DUR - HOLD_DUR

local activeToken = 0

local function ensureScreenGui(playerGui: PlayerGui): ScreenGui
	local existing = playerGui:FindFirstChild("StraitStatusChangeFx")
	if existing and existing:IsA("ScreenGui") then
		return existing
	end
	local sg = Instance.new("ScreenGui")
	sg.Name = "StraitStatusChangeFx"
	sg.IgnoreGuiInset = true
	sg.ResetOnSpawn = false
	sg.DisplayOrder = 500
	sg.Parent = playerGui
	return sg
end

-- Temporarily parks the real Sky aside, drops the state-colored one in,
-- returns a restore function that puts everything back the way it was.
local function applyTempSkybox(newState: string): (() -> ())?
	local srcName = SKYBOX_SOURCE_NAME[newState]
	if not srcName then return nil end
	local folder = ReplicatedStorage:FindFirstChild(SKYBOX_FOLDER_NAME)
	if not folder then return nil end
	local source = folder:FindFirstChild(srcName)
	if not source or not source:IsA("Sky") then return nil end

	-- Stash any existing Skies so we can put them back. Roblox renders whichever is parented;
	-- we take them out (don't destroy) so the game can restore its default on finish.
	local stashed = {}
	for _, c in ipairs(Lighting:GetChildren()) do
		if c:IsA("Sky") then
			table.insert(stashed, c)
			c.Parent = nil
		end
	end

	local cloned = source:Clone()
	cloned.Name = "StraitSky"
	cloned.Parent = Lighting

	return function()
		if cloned and cloned.Parent then cloned:Destroy() end
		for _, s in ipairs(stashed) do
			s.Parent = Lighting
		end
	end
end

function StraitStatusChangeFx.trigger(playerGui: PlayerGui, newState: string)
	local color = COLOR_FOR_STATE[newState] or Color3.fromRGB(200, 200, 200)

	activeToken += 1
	local myToken = activeToken

	local sg = ensureScreenGui(playerGui)
	for _, c in ipairs(sg:GetChildren()) do c:Destroy() end

	-- Announcement text (center screen, no background wash)
	local label = Instance.new("TextLabel")
	label.Name = "Announce"
	label.Size = UDim2.fromScale(0.9, 0.25)
	label.Position = UDim2.fromScale(0.05, 0.38)
	label.BackgroundTransparency = 1
	label.Text = string.format("THE STRAIT IS NOW %s", string.upper(newState))
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeColor3 = Color3.new(0, 0, 0)
	label.TextStrokeTransparency = 0
	label.TextTransparency = 1
	label.ZIndex = 2
	label.Parent = sg

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 5
	stroke.Color = color
	stroke.Transparency = 1
	stroke.Parent = label

	-- Horn
	local horn = Instance.new("Sound")
	horn.Name = "StraitHorn"
	horn.SoundId = HORN_SOUND_ID
	horn.Volume = 1.4
	horn.Parent = SoundService
	horn:Play()
	Debris:AddItem(horn, 6)

	-- Temporary skybox swap: drops in the colored Sky, returns a function to restore
	local restoreSkybox = applyTempSkybox(newState)

	-- Fade in text
	TweenService:Create(label, TweenInfo.new(FADE_IN_DUR, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ TextTransparency = 0, TextStrokeTransparency = 0 }):Play()
	TweenService:Create(stroke, TweenInfo.new(FADE_IN_DUR), { Transparency = 0 }):Play()

	-- Hold then fade out text (the skybox STAYS swapped until the next state change)
	task.delay(FADE_IN_DUR + HOLD_DUR, function()
		if myToken ~= activeToken then return end
		TweenService:Create(label, TweenInfo.new(FADE_OUT_DUR, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
		TweenService:Create(stroke, TweenInfo.new(FADE_OUT_DUR), { Transparency = 1 }):Play()
	end)

	task.delay(SEQUENCE_DUR + 0.15, function()
		if myToken ~= activeToken then return end
		if label and label.Parent then label:Destroy() end
		if restoreSkybox then restoreSkybox() end
	end)
end

return StraitStatusChangeFx
