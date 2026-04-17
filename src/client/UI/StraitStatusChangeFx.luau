--!strict
-- Cinematic when the strait state changes: state-colored Sky for Restricted/Closed, announcement text, horn.
-- Open: no sky swap — restore authored/default Lighting skies only.
-- Restricted / Closed: state sky stays until the next strait rotation; Open clears it and restores authored skies.

local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local StraitStatusChangeFx = {}

local COLOR_FOR_STATE: { [string]: Color3 } = {
	Open = Color3.fromRGB(70, 220, 90),
	Restricted = Color3.fromRGB(255, 210, 60),
	Closed = Color3.fromRGB(255, 60, 60),
}

local SKYBOX_SOURCE_NAME: { [string]: string } = {
	Restricted = "Sky_Restricted",
	Closed = "Sky_Closed",
}
local SKYBOX_FOLDER_NAME = "StraitSkyboxes"

local HORN_SOUND_ID = "rbxassetid://9114145977"

local SEQUENCE_DUR = 3.0
local FADE_IN_DUR = 0.4
local HOLD_DUR = 1.8
local FADE_OUT_DUR = SEQUENCE_DUR - FADE_IN_DUR - HOLD_DUR

local activeToken = 0

--- Skies pulled from Lighting while Restricted/Closed StraitSky is active (not parented).
local heldAuthorSkiesPersistent: { Instance }? = nil

local function destroyStraitSkyClone()
	local x = Lighting:FindFirstChild("StraitSky")
	if x then
		x:Destroy()
	end
end

local function pullAllSkiesFromLighting(): { Instance }
	local t = {}
	for _, c in ipairs(Lighting:GetChildren()) do
		if c:IsA("Sky") then
			c.Parent = nil
			table.insert(t, c)
		end
	end
	return t
end

local function restorePersistentHeldSkies()
	if heldAuthorSkiesPersistent then
		for _, s in ipairs(heldAuthorSkiesPersistent) do
			if s.Parent == nil then
				s.Parent = Lighting
			end
		end
		heldAuthorSkiesPersistent = nil
	end
end

local function getSkyTemplate(state: string): Sky?
	local srcName = SKYBOX_SOURCE_NAME[state]
	if not srcName then
		return nil
	end
	local folder = ReplicatedStorage:FindFirstChild(SKYBOX_FOLDER_NAME)
	if not folder then
		return nil
	end
	local source = folder:FindFirstChild(srcName)
	if source and source:IsA("Sky") then
		return source
	end
	return nil
end

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

function StraitStatusChangeFx.trigger(playerGui: PlayerGui, newState: string)
	local color = COLOR_FOR_STATE[newState] or Color3.fromRGB(200, 200, 200)

	activeToken += 1
	local myToken = activeToken

	destroyStraitSkyClone()

	if newState == "Open" then
		restorePersistentHeldSkies()
	else
		local template = getSkyTemplate(newState)
		if template then
			if heldAuthorSkiesPersistent == nil then
				heldAuthorSkiesPersistent = pullAllSkiesFromLighting()
			end
			local cloned = template:Clone()
			cloned.Name = "StraitSky"
			cloned.Parent = Lighting
		end
	end

	local sg = ensureScreenGui(playerGui)
	for _, c in ipairs(sg:GetChildren()) do
		c:Destroy()
	end

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

	local horn = Instance.new("Sound")
	horn.Name = "StraitHorn"
	horn.SoundId = HORN_SOUND_ID
	horn.Volume = 1.4
	horn.Parent = SoundService
	horn:Play()
	Debris:AddItem(horn, 6)

	TweenService:Create(label, TweenInfo.new(FADE_IN_DUR, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		TextTransparency = 0,
		TextStrokeTransparency = 0,
	}):Play()
	TweenService:Create(stroke, TweenInfo.new(FADE_IN_DUR), { Transparency = 0 }):Play()

	task.delay(FADE_IN_DUR + HOLD_DUR, function()
		if myToken ~= activeToken then
			return
		end
		TweenService:Create(label, TweenInfo.new(FADE_OUT_DUR, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			TextTransparency = 1,
			TextStrokeTransparency = 1,
		}):Play()
		TweenService:Create(stroke, TweenInfo.new(FADE_OUT_DUR), { Transparency = 1 }):Play()
	end)

	task.delay(SEQUENCE_DUR + 0.15, function()
		if myToken ~= activeToken then
			return
		end
		if label and label.Parent then
			label:Destroy()
		end
	end)
end

return StraitStatusChangeFx
