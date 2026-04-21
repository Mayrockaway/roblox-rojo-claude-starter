--!strict
-- EarningsGamepassController
--
-- Drives the active-state visual chrome on the HUD's `EarningsGamepass`
-- ImageButton (`StarterGui.HUD.Canvas.EarningsGamepass`) when the local
-- player owns the **DoubleEarnings** GamePass.
--
-- Authoring contract (see Studio + `MonetizationCatalog`):
--   * Button itself + its `CtaLabel` are authored in Studio.
--   * Child `ActiveStroke` (`UIStroke`) + `ActiveStroke.RainbowGradient`
--     (`UIGradient`) are authored once (here via MCP) and start with
--     `Enabled = false`. This controller flips them on, animates the
--     gradient rotation for the cycling rainbow border, and pulses the
--     stroke `Thickness` so the icon clearly reads as ACTIVE without
--     forcing the player to remember the boost is on. Per
--     `ui-architecture.mdc` §6, runtime `UIStroke.Enabled` /
--     `UIStroke.Thickness` and `UIGradient.Rotation` are the explicit
--     allowed visual feedback exceptions for state.
--   * The label text swaps to "2X ACTIVE" while owned (and back to the
--     authored "2X Cash" CTA when not). Same §6 allowance.
--
-- The click → prompt flow is **not** owned here — `HudPanelRouter` wires
-- `EarningsGamepass.Activated` → `RequestPromptRobuxPurchase` for
-- `gamepass.double_earnings`. This module only listens to
-- `gamePassEffectsUpdate` (server push from `MonetizationService`) and
-- toggles the visuals.
--
-- Lifecycle: `start(playerGui)` is idempotent. Re-calls during HUD
-- streaming reuse the existing connections; the button reference is
-- re-resolved each call so a Studio reorder doesn't break wiring.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local getClientRemotes = require(script.Parent.Parent:WaitForChild("GetClientRemotes")) :: () -> any

local EarningsGamepassController = {}

local DEFAULT_LABEL_TEXT = "2X Cash"
local ACTIVE_LABEL_TEXT = "2X ACTIVE"

--- Pulse parameters chosen to read as "alive" without strobing — full cycle
--- ~1.4s, thickness oscillates 2..6 px (small enough to not blow out the
--- button's authored UICorner). Rainbow rotation completes a full turn every
--- ~6s so the colours sweep visibly but don't induce motion sickness.
local PULSE_PERIOD_SECONDS = 1.4
local PULSE_MIN_THICKNESS = 2
local PULSE_MAX_THICKNESS = 6
local ROTATION_PERIOD_SECONDS = 6.0

local started = false
local heartbeatConn: RBXScriptConnection? = nil
local effectsConn: RBXScriptConnection? = nil
local ownsDoubleEarnings = false
local label: TextLabel? = nil
local stroke: UIStroke? = nil
local gradient: UIGradient? = nil
local pulseStartClock = 0

local function findEarningsButton(playerGui: PlayerGui): ImageButton?
	local hud = playerGui:FindFirstChild("HUD")
	if not (hud and hud:IsA("ScreenGui")) then
		return nil
	end
	local canvas = hud:FindFirstChild("Canvas")
	if not (canvas and canvas:IsA("Frame")) then
		return nil
	end
	local btn = canvas:FindFirstChild("EarningsGamepass")
	if btn and btn:IsA("ImageButton") then
		return btn :: ImageButton
	end
	return nil
end

local function refreshChromeForOwnership()
	local s = stroke
	local g = gradient
	if s then
		s.Enabled = ownsDoubleEarnings
		if not ownsDoubleEarnings then
			s.Thickness = PULSE_MIN_THICKNESS
		end
	end
	if g then
		-- Reset rotation to a known value so the next active toggle starts
		-- the cycle cleanly instead of resuming mid-sweep.
		if not ownsDoubleEarnings then
			g.Rotation = 0
		end
	end
	if label then
		label.Text = if ownsDoubleEarnings then ACTIVE_LABEL_TEXT else DEFAULT_LABEL_TEXT
	end
	if ownsDoubleEarnings then
		pulseStartClock = os.clock()
	end
end

local function onHeartbeat()
	if not ownsDoubleEarnings then
		return
	end
	local s = stroke
	local g = gradient
	if not s or not g then
		return
	end
	local now = os.clock()
	local elapsed = now - pulseStartClock

	-- Pulse thickness via half-sine for a smooth in-out swell.
	local phase = (elapsed % PULSE_PERIOD_SECONDS) / PULSE_PERIOD_SECONDS
	local sineWave = (math.sin(phase * math.pi * 2 - math.pi / 2) + 1) / 2
	s.Thickness = PULSE_MIN_THICKNESS + (PULSE_MAX_THICKNESS - PULSE_MIN_THICKNESS) * sineWave

	-- Rotate the rainbow continuously.
	g.Rotation = (elapsed / ROTATION_PERIOD_SECONDS) * 360 % 360
end

local function disconnectAll()
	if heartbeatConn then
		heartbeatConn:Disconnect()
		heartbeatConn = nil
	end
	if effectsConn then
		effectsConn:Disconnect()
		effectsConn = nil
	end
end

local function attachToButton(btn: ImageButton)
	-- `CtaLabel` is the only TextLabel under the button per Studio author;
	-- if a future redesign nests more, the first one wins (matches the
	-- pattern already used in `RobuxShopPanel.findBuyLabel`).
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
		if g and g:IsA("UIGradient") then
			gradient = g :: UIGradient
		end
	end

	if not stroke then
		warn("[EarningsGamepassController] EarningsGamepass.ActiveStroke missing — author it via MCP (UIStroke + RainbowGradient child).")
	end

	refreshChromeForOwnership()
end

function EarningsGamepassController.start(playerGui: PlayerGui)
	if started then
		return
	end
	started = true

	task.spawn(function()
		local btn: ImageButton? = nil
		for _ = 1, 240 do
			btn = findEarningsButton(playerGui)
			if btn then
				break
			end
			task.wait(0.25)
		end
		if not btn then
			warn("[EarningsGamepassController] EarningsGamepass not found in PlayerGui.HUD after 60s — skipping wiring.")
			started = false
			return
		end

		attachToButton(btn :: ImageButton)

		-- Re-resolve refs if Studio swaps the children (e.g. `ActiveStroke`
		-- gets re-authored). Cheap; only fires on direct child changes.
		--- Leading `;` disambiguates from the previous `attachToButton(...)` call —
		--- without it the Luau parser reads the next line as a chained
		--- `attachToButton(btn)(btn).ChildAdded:Connect(...)`, which throws
		--- `Ambiguous syntax` at module-load time and bricks the entire HUD
		--- wiring `pcall` (including `tryBindEquipmentHotbarAsync`).
		;(btn :: ImageButton).ChildAdded:Connect(function()
			attachToButton(btn :: ImageButton)
		end)

		local remotes = getClientRemotes()
		if effectsConn then
			effectsConn:Disconnect()
		end
		effectsConn = remotes.gamePassEffectsUpdate.OnClientEvent:Connect(function(payload: any)
			if typeof(payload) ~= "table" then
				return
			end
			local effects = (payload :: any).effects
			if typeof(effects) ~= "table" then
				return
			end
			local nextOwns = effects.DoubleEarnings == true
			if nextOwns ~= ownsDoubleEarnings then
				ownsDoubleEarnings = nextOwns
				refreshChromeForOwnership()
			end
		end)

		if heartbeatConn then
			heartbeatConn:Disconnect()
		end
		heartbeatConn = RunService.Heartbeat:Connect(onHeartbeat)
	end)
end

function EarningsGamepassController.stop()
	disconnectAll()
	if stroke then
		stroke.Enabled = false
		stroke.Thickness = PULSE_MIN_THICKNESS
	end
	if gradient then
		gradient.Rotation = 0
	end
	if label then
		label.Text = DEFAULT_LABEL_TEXT
	end
	ownsDoubleEarnings = false
	started = false
end

-- Auto-stop on Players.PlayerRemoving so the heartbeat doesn't keep the
-- gradient spinning during a reset / leave.
Players.PlayerRemoving:Connect(function(p)
	if p == Players.LocalPlayer then
		EarningsGamepassController.stop()
	end
end)

return EarningsGamepassController
