--!strict
--[[
	AutoShipController — client-side HUD chrome for the AutoShip GamePass.

	Mirrors `EarningsGamepassController` for the rainbow active-state animation.
	Owns the full click flow (NOT wired through HudPanelRouter):
	  * Not owned → prompt Robux purchase
	  * Owned, inactive → show priority picker (Most Valuable / Least Valuable)
	  * Owned, active → toggle off

	Listens to:
	  * `GamePassEffectsUpdate` for ownership
	  * `AutoShipStateUpdate` for enabled/priority/stoppedReason
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local getClientRemotes = require(script.Parent.Parent:WaitForChild("GetClientRemotes")) :: () -> any

local AutoShipController = {}

local DEFAULT_LABEL_TEXT = "Auto Ship"
local ACTIVE_LABEL_TEXT = "AUTO ACTIVE"

local PULSE_PERIOD_SECONDS = 1.4
local PULSE_MIN_THICKNESS = 2
local PULSE_MAX_THICKNESS = 6
local ROTATION_PERIOD_SECONDS = 6.0

local started = false
local heartbeatConn: RBXScriptConnection? = nil
local effectsConn: RBXScriptConnection? = nil
local stateConn: RBXScriptConnection? = nil
local clickConn: RBXScriptConnection? = nil
local ownsAutoShip = false
local autoShipActive = false
local label: TextLabel? = nil
local stroke: UIStroke? = nil
local gradient: UIGradient? = nil
local pulseStartClock = 0
local pickerGui: ScreenGui? = nil

local function findAutoShipButton(playerGui: PlayerGui): ImageButton?
	local hud = playerGui:FindFirstChild("HUD")
	if not (hud and hud:IsA("ScreenGui")) then return nil end
	local canvas = hud:FindFirstChild("Canvas")
	if not (canvas and canvas:IsA("Frame")) then return nil end
	local btn = canvas:FindFirstChild("AutoShipButton")
	if btn and btn:IsA("ImageButton") then return btn :: ImageButton end
	return nil
end

local function refreshChrome()
	local isActive = ownsAutoShip and autoShipActive
	if stroke then
		stroke.Enabled = isActive
		if not isActive then stroke.Thickness = PULSE_MIN_THICKNESS end
	end
	if gradient and not isActive then
		gradient.Rotation = 0
	end
	if label then
		label.Text = if isActive then ACTIVE_LABEL_TEXT else DEFAULT_LABEL_TEXT
	end
	if isActive then
		pulseStartClock = os.clock()
	end
end

local function onHeartbeat()
	if not (ownsAutoShip and autoShipActive) then return end
	local s = stroke
	local g = gradient
	if not s or not g then return end
	local elapsed = os.clock() - pulseStartClock
	local phase = (elapsed % PULSE_PERIOD_SECONDS) / PULSE_PERIOD_SECONDS
	local sineWave = (math.sin(phase * math.pi * 2 - math.pi / 2) + 1) / 2
	s.Thickness = PULSE_MIN_THICKNESS + (PULSE_MAX_THICKNESS - PULSE_MIN_THICKNESS) * sineWave
	g.Rotation = (elapsed / ROTATION_PERIOD_SECONDS) * 360 % 360
end

local function destroyPicker()
	if pickerGui and pickerGui.Parent then
		pickerGui:Destroy()
	end
	pickerGui = nil
end

local function showPriorityPicker(playerGui: PlayerGui, remotes: any)
	destroyPicker()

	local sg = Instance.new("ScreenGui")
	sg.Name = "AutoShipPickerGui"
	sg.DisplayOrder = 100
	sg.IgnoreGuiInset = true
	sg.Parent = playerGui
	pickerGui = sg

	-- Dim overlay
	local overlay = Instance.new("TextButton")
	overlay.Name = "Overlay"
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundColor3 = Color3.new(0, 0, 0)
	overlay.BackgroundTransparency = 0.5
	overlay.BorderSizePixel = 0
	overlay.Text = ""
	overlay.AutoButtonColor = false
	overlay.Parent = sg
	overlay.Activated:Connect(destroyPicker)

	-- Center frame
	local frame = Instance.new("Frame")
	frame.Name = "PickerFrame"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.Size = UDim2.fromOffset(360, 200)
	frame.BackgroundColor3 = Color3.fromRGB(20, 30, 45)
	frame.BorderSizePixel = 0
	frame.Parent = sg
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = frame

	-- Title
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, 0, 0, 40)
	title.Position = UDim2.fromOffset(0, 10)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 20
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.Text = "AutoShip — Choose Priority"
	title.Parent = frame

	local function makeButton(name: string, text: string, priority: string, posY: number, color: Color3)
		local btn = Instance.new("TextButton")
		btn.Name = name
		btn.AnchorPoint = Vector2.new(0.5, 0)
		btn.Position = UDim2.new(0.5, 0, 0, posY)
		btn.Size = UDim2.new(0.85, 0, 0, 48)
		btn.BackgroundColor3 = color
		btn.BorderSizePixel = 0
		btn.Font = Enum.Font.GothamBold
		btn.TextSize = 18
		btn.TextColor3 = Color3.fromRGB(255, 255, 255)
		btn.Text = text
		btn.AutoButtonColor = true
		btn.Parent = frame
		local btnCorner = Instance.new("UICorner")
		btnCorner.CornerRadius = UDim.new(0, 8)
		btnCorner.Parent = btn
		btn.Activated:Connect(function()
			destroyPicker()
			remotes.requestSetAutoShip:FireServer({ enabled = true, priority = priority })
		end)
	end

	makeButton("MostValuable", "Most Valuable First (Premium)", "MostValuable", 60, Color3.fromRGB(180, 140, 40))
	makeButton("LeastValuable", "Least Valuable First (Crude)", "LeastValuable", 120, Color3.fromRGB(80, 130, 180))

	-- Auto-close after 10 seconds
	task.delay(10, destroyPicker)
end

local function showStopToast(playerGui: PlayerGui, reason: string)
	local msg
	if reason == "NO_OIL" then
		msg = "AutoShip stopped: no oil available."
	elseif reason == "WAREHOUSE_FULL" then
		msg = "AutoShip stopped: warehouse is full."
	elseif reason == "DISPATCH_FAILED" then
		msg = "AutoShip stopped: dispatch failed."
	else
		msg = "AutoShip stopped."
	end

	local sg = Instance.new("ScreenGui")
	sg.Name = "AutoShipToast"
	sg.DisplayOrder = 99
	sg.IgnoreGuiInset = true
	sg.Parent = playerGui

	local toast = Instance.new("TextLabel")
	toast.AnchorPoint = Vector2.new(0.5, 0)
	toast.Position = UDim2.new(0.5, 0, 0, 60)
	toast.Size = UDim2.fromOffset(400, 50)
	toast.BackgroundColor3 = Color3.fromRGB(180, 40, 40)
	toast.BackgroundTransparency = 0.15
	toast.BorderSizePixel = 0
	toast.Font = Enum.Font.GothamBold
	toast.TextSize = 18
	toast.TextColor3 = Color3.fromRGB(255, 255, 255)
	toast.Text = msg
	toast.Parent = sg
	local toastCorner = Instance.new("UICorner")
	toastCorner.CornerRadius = UDim.new(0, 10)
	toastCorner.Parent = toast

	task.delay(4, function()
		if sg and sg.Parent then sg:Destroy() end
	end)
end

local function attachToButton(btn: ImageButton)
	label = nil
	for _, d in ipairs(btn:GetDescendants()) do
		if d:IsA("TextLabel") then
			label = d :: TextLabel
			break
		end
	end

	local s = btn:FindFirstChild("ActiveStroke")
	if s and s:IsA("UIStroke") then
		stroke = s :: UIStroke
	else
		stroke = nil
	end

	gradient = nil
	if stroke then
		local g = stroke:FindFirstChild("RainbowGradient")
		if g and g:IsA("UIGradient") then gradient = g :: UIGradient end
	end

	if not stroke then
		warn("[AutoShipController] AutoShipButton.ActiveStroke missing — author it via MCP.")
	end

	refreshChrome()
end

local function disconnectAll()
	if heartbeatConn then heartbeatConn:Disconnect(); heartbeatConn = nil end
	if effectsConn then effectsConn:Disconnect(); effectsConn = nil end
	if stateConn then stateConn:Disconnect(); stateConn = nil end
	if clickConn then clickConn:Disconnect(); clickConn = nil end
end

function AutoShipController.start(playerGui: PlayerGui)
	if started then return end
	started = true

	task.spawn(function()
		local btn: ImageButton? = nil
		for _ = 1, 240 do
			btn = findAutoShipButton(playerGui)
			if btn then break end
			task.wait(0.25)
		end
		if not btn then
			started = false
			return
		end

		attachToButton(btn :: ImageButton)

		;(btn :: ImageButton).ChildAdded:Connect(function()
			attachToButton(btn :: ImageButton)
		end)

		local remotes = getClientRemotes()

		-- Click handler: 3-mode
		if clickConn then clickConn:Disconnect() end
		clickConn = (btn :: ImageButton).Activated:Connect(function()
			if not ownsAutoShip then
				remotes.requestPromptRobuxPurchase:FireServer({ itemId = "gamepass.auto_ship" })
				return
			end
			if autoShipActive then
				remotes.requestSetAutoShip:FireServer({ enabled = false })
				return
			end
			showPriorityPicker(playerGui, remotes)
		end)

		-- GamePass ownership listener
		if effectsConn then effectsConn:Disconnect() end
		effectsConn = remotes.gamePassEffectsUpdate.OnClientEvent:Connect(function(payload: any)
			if typeof(payload) ~= "table" then return end
			local effects = (payload :: any).effects
			if typeof(effects) ~= "table" then return end
			local nextOwns = effects.AutoShip == true
			if nextOwns ~= ownsAutoShip then
				ownsAutoShip = nextOwns
				refreshChrome()
			end
		end)

		-- AutoShip state listener
		if stateConn then stateConn:Disconnect() end
		stateConn = remotes.autoShipStateUpdate.OnClientEvent:Connect(function(payload: any)
			if typeof(payload) ~= "table" then return end
			local wasActive = autoShipActive
			autoShipActive = payload.enabled == true
			if wasActive ~= autoShipActive then
				refreshChrome()
			end
			if typeof(payload.stoppedReason) == "string" and payload.stoppedReason ~= "" then
				showStopToast(playerGui, payload.stoppedReason)
			end
		end)

		if heartbeatConn then heartbeatConn:Disconnect() end
		heartbeatConn = RunService.Heartbeat:Connect(onHeartbeat)
	end)
end

function AutoShipController.stop()
	disconnectAll()
	destroyPicker()
	if stroke then stroke.Enabled = false; stroke.Thickness = PULSE_MIN_THICKNESS end
	if gradient then gradient.Rotation = 0 end
	if label then label.Text = DEFAULT_LABEL_TEXT end
	ownsAutoShip = false
	autoShipActive = false
	started = false
end

Players.PlayerRemoving:Connect(function(p)
	if p == Players.LocalPlayer then
		AutoShipController.stop()
	end
end)

return AutoShipController
