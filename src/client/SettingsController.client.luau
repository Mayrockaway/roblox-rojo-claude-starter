--!strict
-- Settings Panel Controller: wires the SettingsPanelGui toggle switches and close button.
-- Prefer `SettingsPanel` + `HudPanelRouter` when present; this legacy script delegates audio to `ClientAudioPreferences`.

local Players = game:GetService("Players")

local ClientAudioPreferences = require(script.Parent:WaitForChild("ClientAudioPreferences"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

print("[SettingsController] Starting...")

-- Wait for GUIs to replicate
local hud = playerGui:WaitForChild("HUD", 30)
local settingsGui = playerGui:WaitForChild("SettingsPanelGui", 30)
if not hud then warn("[SettingsController] HUD not found!") return end
if not settingsGui then warn("[SettingsController] SettingsPanelGui not found!") return end
print("[SettingsController] Found HUD and SettingsPanelGui")

-- Find settings button in HUD
local leftStack = hud:FindFirstChild("Canvas") and hud.Canvas:FindFirstChild("LeftStack")
local settingsButton = leftStack and leftStack:FindFirstChild("SettingsButton")
if not settingsButton then warn("[SettingsController] SettingsButton not found in HUD") return end
print("[SettingsController] Found SettingsButton: " .. settingsButton.ClassName)

-- Find panel elements
local canvas = settingsGui:FindFirstChild("Canvas")
if not canvas then warn("[SettingsController] Canvas not found") return end

-- CRITICAL: Canvas.Interactable is false by default, blocking ALL input
canvas.Interactable = true
canvas.Active = true
print("[SettingsController] Set Canvas.Interactable=true, Active=true")

local mainFrame = canvas:FindFirstChild("Main")
if not mainFrame then warn("[SettingsController] Main not found") return end
mainFrame.Active = true

local closeBtn = mainFrame:FindFirstChild("Close")
print("[SettingsController] Close button: " .. tostring(closeBtn) .. " class=" .. (closeBtn and closeBtn.ClassName or "nil"))

local cg = mainFrame:FindFirstChild("CanvasGroup")
if not cg then warn("[SettingsController] CanvasGroup not found") return end

local container = cg:FindFirstChild("Container")
if not container then warn("[SettingsController] Container not found") return end

-- Start hidden
settingsGui.Enabled = false
print("[SettingsController] Panel hidden on start")

ClientAudioPreferences.init()

-- State
local panelOpen = false
local musicEnabled = ClientAudioPreferences.isMusicEnabled()
local sfxEnabled = ClientAudioPreferences.isSfxEnabled()

-- Find both tabs in section "1"
local section1 = container:FindFirstChild("1")
if not section1 then warn("[SettingsController] Section 1 not found") return end

local list = section1:FindFirstChild("List")
if not list then warn("[SettingsController] List not found in section 1") return end

-- Identify which tab is Music and which is SFX
local musicTab = nil
local sfxTab = nil

for _, tab in ipairs(list:GetChildren()) do
	if tab.Name ~= "Tab" or not tab:IsA("Frame") then continue end

	local active = tab:FindFirstChild("Active")
	if not active then continue end

	local textFrame = active:FindFirstChild("Text")
	if not textFrame then continue end

	-- Check all TextLabels for identifying text
	for _, lbl in ipairs(textFrame:GetChildren()) do
		if lbl:IsA("TextLabel") then
			if lbl.Text:find("Music") then
				musicTab = tab
				print("[SettingsController] Found Music tab")
				break
			elseif lbl.Text:find("SFX") then
				sfxTab = tab
				print("[SettingsController] Found SFX tab")
				break
			end
		end
	end
end

-- Helper: overlay a clickable button on a Frame
local function makeClickable(frame: Instance, callback: () -> ())
	-- Remove any existing overlay
	local existing = frame:FindFirstChild("ClickOverlay")
	if existing then existing:Destroy() end

	local btn = Instance.new("TextButton")
	btn.Name = "ClickOverlay"
	btn.Size = UDim2.fromScale(1, 1)
	btn.Position = UDim2.fromScale(0, 0)
	btn.BackgroundTransparency = 1
	btn.Text = ""
	btn.ZIndex = 100
	btn.Parent = frame
	btn.MouseButton1Click:Connect(callback)
	print("[SettingsController] Added ClickOverlay to " .. frame:GetFullName())
	return btn
end

-- Wire music toggle
if musicTab then
	local active = musicTab:FindFirstChild("Active")
	local inactive = musicTab:FindFirstChild("Inactive")

	local function toggleMusic()
		musicEnabled = not musicEnabled
		print("[SettingsController] Music toggled: " .. tostring(musicEnabled))

		if active then active.Visible = musicEnabled end
		if inactive then inactive.Visible = not musicEnabled end

		-- Actually mute/unmute music
		for _, d in ipairs(SoundService:GetDescendants()) do
			if d:IsA("Sound") then
				if musicEnabled then
					if not d.Playing then d:Play() end
				else
					d:Pause()
				end
			end
		end
		-- Also check workspace for BGM sounds
		for _, d in ipairs(game.Workspace:GetDescendants()) do
			if d:IsA("Sound") and (d.Name == "BGM" or d.Name:find("Music") or d.Name:find("music")) then
				if musicEnabled then
					if not d.Playing then d:Play() end
				else
					d:Pause()
				end
			end
		end
	end

	-- Make the ENTIRE tab clickable (both active and inactive states)
	makeClickable(musicTab, toggleMusic)
	if active then makeClickable(active, toggleMusic) end
	if inactive then makeClickable(inactive, toggleMusic) end
else
	warn("[SettingsController] Music tab NOT found!")
end

-- Wire SFX toggle
if sfxTab then
	local active = sfxTab:FindFirstChild("Active")
	local inactive = sfxTab:FindFirstChild("Inactive")

	local function toggleSFX()
		sfxEnabled = not sfxEnabled
		print("[SettingsController] SFX toggled: " .. tostring(sfxEnabled))

		if active then active.Visible = sfxEnabled end
		if inactive then inactive.Visible = not sfxEnabled end

		ClientAudioPreferences.setSfxEnabled(sfxEnabled)
	end

	-- Make the ENTIRE tab clickable
	makeClickable(sfxTab, toggleSFX)
	if active then makeClickable(active, toggleSFX) end
	if inactive then makeClickable(inactive, toggleSFX) end
else
	warn("[SettingsController] SFX tab NOT found!")
end

-- Wire close button
if closeBtn then
	if closeBtn:IsA("GuiButton") then
		closeBtn.MouseButton1Click:Connect(function()
			print("[SettingsController] Close clicked")
			settingsGui.Enabled = false
			panelOpen = false
		end)
		print("[SettingsController] Wired close button (GuiButton)")
	else
		-- It's not a button, overlay one
		makeClickable(closeBtn, function()
			print("[SettingsController] Close overlay clicked")
			settingsGui.Enabled = false
			panelOpen = false
		end)
		print("[SettingsController] Wired close button (overlay)")
	end
else
	warn("[SettingsController] No close button found!")
end

-- Wire settings button in HUD
if settingsButton:IsA("GuiButton") then
	settingsButton.MouseButton1Click:Connect(function()
		panelOpen = not panelOpen
		settingsGui.Enabled = panelOpen
		print("[SettingsController] Settings button clicked, panelOpen=" .. tostring(panelOpen))
	end)
	print("[SettingsController] Wired settings HUD button")
else
	warn("[SettingsController] SettingsButton is not a GuiButton: " .. settingsButton.ClassName)
end

print("[SettingsController] DONE - Music tab=" .. tostring(musicTab ~= nil) .. " SFX tab=" .. tostring(sfxTab ~= nil) .. " Close=" .. tostring(closeBtn ~= nil))
