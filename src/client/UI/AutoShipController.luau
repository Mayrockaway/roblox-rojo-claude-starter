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
--- The priority picker is built ad-hoc here (NOT bound through `HudPanelRouter`).
--- Register it with `HudMousePolicy` so the cursor isn't stuck in `LockCenter` when the
--- player triggers the picker from first-person zoom.
local HudMousePolicy = require(script.Parent:WaitForChild("HudMousePolicy"))

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
local pickerConns: { RBXScriptConnection } = {}
local pickerCloseTask: thread? = nil
local ownsAutoShip = false
local autoShipActive = false
--- The priority the server most recently echoed back ("MostValuable" |
--- "LeastValuable" | nil). Drives the green "EQUIPPED" overlay on the
--- matching picker button when the picker re-opens, so the player can
--- see at a glance which mode they're currently in without having to
--- read the button text. Authored under each button as
--- `EquippedOverlay` (Visible = false in Studio rest state).
local currentPriority: string? = nil
-- The first `gamePassEffectsUpdate` after join establishes the baseline
-- ownership; only effect updates AFTER that count as "the player just
-- bought it" and trigger the post-purchase priority picker auto-open.
-- Without this guard, a returning owner would get the picker shoved in
-- their face every login.
local seenInitialEffectsUpdate = false
local label: TextLabel? = nil
local stroke: UIStroke? = nil
local gradient: UIGradient? = nil
local pulseStartClock = 0

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

--- The picker UI (`StarterGui.AutoShipPriorityGui`) is authored in Studio
--- per `ui-architecture.mdc` (Canvas → DimOverlay + PanelHost → Card →
--- Body → Banner / Subtitle / ButtonStack with `MostValuableButton` and
--- `LeastValuableButton`). This controller only flips
--- `ScreenGui.Enabled` and binds the four interactive elements
--- (`DimOverlay`, `Banner.CloseButton`, `MostValuableButton`,
--- `LeastValuableButton`) — that's the §6 "clicks + visibility on
--- Studio-authored UI" allowance. Visuals (chrome, padding, fonts,
--- button styling) live in Studio Properties and stay editable without
--- touching code.
local function findPickerGui(playerGui: PlayerGui): ScreenGui?
	local g = playerGui:FindFirstChild("AutoShipPriorityGui")
	if g and g:IsA("ScreenGui") then return g :: ScreenGui end
	return nil
end

local function isPickerOpen(playerGui: PlayerGui): boolean
	local g = findPickerGui(playerGui)
	return g ~= nil and g.Enabled == true
end

local pickerRegisteredWithMousePolicy = false
local function ensurePickerMousePolicy(g: ScreenGui)
	if pickerRegisteredWithMousePolicy then return end
	HudMousePolicy.RegisterScreenGui(g)
	pickerRegisteredWithMousePolicy = true
end

local function disconnectPickerConns()
	for _, conn in ipairs(pickerConns) do
		pcall(function() conn:Disconnect() end)
	end
	table.clear(pickerConns)
end

local function hidePicker(playerGui: PlayerGui)
	local g = findPickerGui(playerGui)
	if g then g.Enabled = false end
	disconnectPickerConns()
	if pickerCloseTask then
		task.cancel(pickerCloseTask)
		pickerCloseTask = nil
	end
end

local function showPriorityPicker(playerGui: PlayerGui, remotes: any)
	local g = findPickerGui(playerGui)
	if not g then
		warn("[AutoShipController] AutoShipPriorityGui missing in PlayerGui — author it via MCP (mirrors ShipOilInstantSellGui chrome).")
		return
	end

	-- Re-bind from scratch so re-opening doesn't accumulate listeners on
	-- the same Studio-authored buttons.
	disconnectPickerConns()
	if pickerCloseTask then
		task.cancel(pickerCloseTask)
		pickerCloseTask = nil
	end

	local canvas = g:FindFirstChild("Canvas")
	local dim = canvas and canvas:FindFirstChild("DimOverlay")
	local panelHost = canvas and canvas:FindFirstChild("PanelHost")
	local card = panelHost and panelHost:FindFirstChild("Card")
	local body = card and card:FindFirstChild("Body")
	local banner = body and body:FindFirstChild("Banner")
	local closeBtn = banner and banner:FindFirstChild("CloseButton")
	local stack = body and body:FindFirstChild("ButtonStack")
	local mostBtn = stack and stack:FindFirstChild("MostValuableButton")
	local leastBtn = stack and stack:FindFirstChild("LeastValuableButton")

	-- Reflect the currently-equipped priority on the picker. The
	-- `EquippedOverlay` is a Studio-authored child on each button (dark
	-- scrim + green "EQUIPPED" label) — controller only flips Visible
	-- per `ui-architecture.mdc` §6 (visibility on Studio templates is
	-- explicitly allowed runtime behavior). When AutoShip is disabled,
	-- both overlays stay hidden.
	local function setOverlayVisible(btn: Instance?, visible: boolean)
		if not btn then return end
		local overlay = (btn :: any):FindFirstChild("EquippedOverlay")
		if overlay and overlay:IsA("GuiObject") then
			overlay.Visible = visible
		end
	end
	setOverlayVisible(mostBtn, autoShipActive and currentPriority == "MostValuable")
	setOverlayVisible(leastBtn, autoShipActive and currentPriority == "LeastValuable")

	local function close()
		hidePicker(playerGui)
	end

	if dim and dim:IsA("GuiButton") then
		table.insert(pickerConns, dim.Activated:Connect(close))
	end
	if closeBtn and closeBtn:IsA("GuiButton") then
		table.insert(pickerConns, closeBtn.Activated:Connect(close))
	end
	-- Tap-equipped-to-toggle-off: clicking the priority button that
	-- already shows the green `EquippedOverlay` disables AutoShip; the
	-- chrome (button rainbow stroke + EquippedOverlay) follows from
	-- `AutoShipStateUpdate` and clears naturally on the next state push.
	-- Clicking the OTHER priority simply switches mid-run (server
	-- replaces the entry and re-dispatches when the boat is idle).
	local function onPick(priority: string)
		close()
		if autoShipActive and currentPriority == priority then
			remotes.requestSetAutoShip:FireServer({ enabled = false })
		else
			remotes.requestSetAutoShip:FireServer({ enabled = true, priority = priority })
		end
	end
	if mostBtn and mostBtn:IsA("GuiButton") then
		table.insert(pickerConns, mostBtn.Activated:Connect(function()
			onPick("MostValuable")
		end))
	end
	if leastBtn and leastBtn:IsA("GuiButton") then
		table.insert(pickerConns, leastBtn.Activated:Connect(function()
			onPick("LeastValuable")
		end))
	end

	ensurePickerMousePolicy(g)
	g.Enabled = true

	-- Auto-close after 15 s in case the player walks away from the modal.
	pickerCloseTask = task.delay(15, function()
		if findPickerGui(playerGui) == g and g.Enabled then
			close()
		end
	end)
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

		-- HUD click handler. Three states:
		--   1. Picker open  → dismiss the picker (toggle behavior; same
		--      semantic as DimOverlay / CloseButton / HUD-button-while-open).
		--   2. Don't own    → prompt the Robux purchase.
		--   3. Own (any active state) → open the priority picker. The
		--      picker is the single surface for both first-time priority
		--      choice AND switching priority while AutoShip is active —
		--      the green `EquippedOverlay` on the matching button shows
		--      what's currently equipped. We do NOT toggle AutoShip off
		--      here; disable lives inside the picker UI (or the player
		--      can let it stop naturally on NO_OIL / WAREHOUSE_FULL).
		if clickConn then clickConn:Disconnect() end
		clickConn = (btn :: ImageButton).Activated:Connect(function()
			if isPickerOpen(playerGui) then
				hidePicker(playerGui)
				return
			end
			if not ownsAutoShip then
				remotes.requestPromptRobuxPurchase:FireServer({ itemId = "gamepass.auto_ship" })
				return
			end
			showPriorityPicker(playerGui, remotes)
		end)

		-- GamePass ownership listener.
		--
		-- The ONLY signal the client gets that the Robux purchase prompt
		-- resolved successfully is the next `gamePassEffectsUpdate` push
		-- from `MonetizationService:_pushGamePassEffectsToClient` (fired
		-- from its `PromptGamePassPurchaseFinished` listener). So the
		-- post-purchase "pick least or most valuable" menu is opened
		-- here on the false → true ownership transition — but ONLY
		-- after the baseline effects update has already landed, so an
		-- existing owner doesn't get the picker shoved at them on every
		-- spawn.
		if effectsConn then effectsConn:Disconnect() end
		effectsConn = remotes.gamePassEffectsUpdate.OnClientEvent:Connect(function(payload: any)
			if typeof(payload) ~= "table" then return end
			local effects = (payload :: any).effects
			if typeof(effects) ~= "table" then return end
			local nextOwns = effects.AutoShip == true
			local justPurchased = seenInitialEffectsUpdate
				and (not ownsAutoShip)
				and nextOwns
				and (not autoShipActive)
			if nextOwns ~= ownsAutoShip then
				ownsAutoShip = nextOwns
				refreshChrome()
			end
			if not seenInitialEffectsUpdate then
				seenInitialEffectsUpdate = true
			end
			if justPurchased then
				showPriorityPicker(playerGui, remotes)
			end
		end)

		-- AutoShip state listener
		if stateConn then stateConn:Disconnect() end
		stateConn = remotes.autoShipStateUpdate.OnClientEvent:Connect(function(payload: any)
			if typeof(payload) ~= "table" then return end
			local wasActive = autoShipActive
			autoShipActive = payload.enabled == true
			if autoShipActive then
				if typeof(payload.priority) == "string" then
					currentPriority = payload.priority
				end
			else
				currentPriority = nil
			end
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
	disconnectPickerConns()
	if pickerCloseTask then
		task.cancel(pickerCloseTask)
		pickerCloseTask = nil
	end
	local lp = Players.LocalPlayer
	if lp then
		local pg = lp:FindFirstChildOfClass("PlayerGui")
		if pg then
			local g = findPickerGui(pg)
			if g then g.Enabled = false end
		end
	end
	if stroke then stroke.Enabled = false; stroke.Thickness = PULSE_MIN_THICKNESS end
	if gradient then gradient.Rotation = 0 end
	if label then label.Text = DEFAULT_LABEL_TEXT end
	ownsAutoShip = false
	autoShipActive = false
	currentPriority = nil
	seenInitialEffectsUpdate = false
	started = false
end

Players.PlayerRemoving:Connect(function(p)
	if p == Players.LocalPlayer then
		AutoShipController.stop()
	end
end)

return AutoShipController
