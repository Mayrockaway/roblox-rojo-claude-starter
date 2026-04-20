--!strict
--- StraitForceLockTimer
---
--- Drives the countdown panel that sits next to **`StraitControlCta`** ("Unlock
--- Strait" CTA) on the HUD while a Robux force-open / force-close is active
--- (`MonetizationCatalog` consumables `strait_open_2min` / `strait_close_2min`).
---
--- **Single source of truth:** the visible Frame is authored in Studio under
--- `StarterGui.HUD.Canvas.StraitForceLockTimer` (scaled `UDim2`,
--- `UIAspectRatioConstraint`, `UITextSizeConstraint`, etc. per
--- `ui-architecture.mdc` / `ui-scaling-responsive.mdc`). This module **never**
--- creates that Frame; it only:
---   * toggles `Visible`
---   * sets `TimerLabel.Text` ("M:SS" via the server-broadcast `forceLock`)
---   * themes the background + label color (green = Open lock, red = Closed
---     lock) so the panel reads at a glance
---   * animates: gentle pulse via `UIScale` + brighter strobe in the last 10s
---
--- Driven entirely from server snapshots — the client's local clock is only
--- used for sub-second smoothing of the `M:SS` label between snapshot pushes
--- (snapshots only land on follower polls / leader rolls, not every frame).
--- `forceLock.untilTimestamp` is `workspace:GetServerTimeNow()`-shaped, which
--- is also what `workspace:GetServerTimeNow()` reports on the client, so no
--- clock-skew correction is needed.

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

export type ForceLock = {
	state: string,
	untilTimestamp: number,
	byUserId: number?,
	byName: string?,
	version: number,
}

local FRAME_NAME = "StraitForceLockTimer"
local LABEL_NAME = "TimerLabel"
local PULSE_SCALE_NAME = "PulseScale"

local THEME: { [string]: { fill: Color3, stroke: Color3, text: Color3, label: string } } = {
	Open = {
		fill = Color3.fromRGB(34, 130, 70),
		stroke = Color3.fromRGB(120, 230, 160),
		text = Color3.fromRGB(255, 255, 255),
		label = "OPEN",
	},
	Closed = {
		fill = Color3.fromRGB(176, 18, 32),
		stroke = Color3.fromRGB(255, 200, 200),
		text = Color3.fromRGB(255, 255, 255),
		label = "CLOSED",
	},
}

local StraitForceLockTimer = {}

local activeFrame: Frame? = nil
local activeLabel: TextLabel? = nil
local activePulseScale: UIScale? = nil
local activeLock: ForceLock? = nil
local tickConn: RBXScriptConnection? = nil
local lastShownSeconds = -1
local pulseT0 = 0

local function findFrame(playerGui: PlayerGui): Frame?
	local hud = playerGui:FindFirstChild("HUD")
	if not (hud and hud:IsA("ScreenGui")) then
		return nil
	end
	local canvas = hud:FindFirstChild("Canvas")
	if not canvas then
		return nil
	end
	local frame = canvas:FindFirstChild(FRAME_NAME)
	if frame and frame:IsA("Frame") then
		return frame
	end
	return nil
end

local function ensurePulseScale(frame: Frame): UIScale
	local existing = frame:FindFirstChild(PULSE_SCALE_NAME)
	if existing and existing:IsA("UIScale") then
		return existing
	end
	local s = Instance.new("UIScale")
	s.Name = PULSE_SCALE_NAME
	s.Scale = 1
	s.Parent = frame
	return s
end

local function findLabel(frame: Frame): TextLabel?
	-- Prefer the canonical authored name; fall back to first descendant
	-- `TextLabel` so a Studio author can rename for theming without breaking
	-- the wiring entirely (a soft contract, not a hard one).
	local direct = frame:FindFirstChild(LABEL_NAME)
	if direct and direct:IsA("TextLabel") then
		return direct
	end
	for _, d in ipairs(frame:GetDescendants()) do
		if d:IsA("TextLabel") then
			return d
		end
	end
	return nil
end

local function formatRemaining(seconds: number): string
	if seconds < 0 then
		seconds = 0
	end
	local total = math.ceil(seconds)
	local m = math.floor(total / 60)
	local s = total - m * 60
	return string.format("%d:%02d", m, s)
end

local function applyTheme(frame: Frame, label: TextLabel, lockState: string)
	local theme = THEME[lockState] or THEME.Closed
	frame.BackgroundColor3 = theme.fill
	frame.BackgroundTransparency = 0.12
	-- UIStroke on the panel (authored in Studio) — recolor to match the lock
	-- state. Falls through silently if the author removed it.
	local stroke = frame:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = theme.stroke
	end
	label.TextColor3 = theme.text
	local labelStroke = label:FindFirstChildOfClass("UIStroke")
	if labelStroke then
		labelStroke.Color = Color3.new(0, 0, 0)
	end
end

local function stopTick()
	if tickConn then
		tickConn:Disconnect()
		tickConn = nil
	end
end

local function hide()
	stopTick()
	activeLock = nil
	lastShownSeconds = -1
	if activeFrame then
		activeFrame.Visible = false
	end
	if activePulseScale then
		activePulseScale.Scale = 1
	end
end

local function startTick()
	stopTick()
	pulseT0 = os.clock()
	tickConn = RunService.Heartbeat:Connect(function()
		local lock = activeLock
		local frame = activeFrame
		local label = activeLabel
		local pulse = activePulseScale
		if not (lock and frame and label) then
			hide()
			return
		end
		local now = workspace:GetServerTimeNow()
		local remaining = lock.untilTimestamp - now
		if remaining <= 0 then
			-- Wait for the server to confirm the unlock (snapshot replay) so
			-- we don't flicker the panel back on if the server ticks late.
			label.Text = "0:00"
			if pulse then
				pulse.Scale = 1
			end
			-- Auto-hide a hair after the deadline so the player gets
			-- immediate visual feedback even if the server snapshot is
			-- delayed by network jitter; the next snapshot will overwrite if
			-- the lock somehow re-applies.
			task.delay(0.6, function()
				if activeLock == lock then
					hide()
				end
			end)
			stopTick()
			return
		end

		local shownSecond = math.ceil(remaining)
		if shownSecond ~= lastShownSeconds then
			lastShownSeconds = shownSecond
			label.Text = formatRemaining(remaining)
		end

		if pulse then
			-- Always-on gentle pulse so the panel reads as live.
			local w = os.clock() - pulseT0
			local base = 1 + 0.04 * math.sin(w * 3.2)
			-- Last 10 seconds: stronger pulse + slight strobe via Tween-free
			-- math so we don't allocate every frame.
			if remaining <= 10 then
				local urgency = 0.5 + 0.5 * math.sin(w * 12)
				base = 1 + 0.10 * math.sin(w * 8)
				label.TextTransparency = 0.0 + 0.18 * (1 - urgency)
			else
				label.TextTransparency = 0
			end
			pulse.Scale = base
		end
	end)
end

--- Apply (or clear) a force-lock snapshot. Idempotent: passing the same
--- `forceLock.version` twice is a no-op except for the per-frame label
--- refresh (which only changes when the displayed second rolls over).
function StraitForceLockTimer.refresh(playerGui: PlayerGui, forceLock: ForceLock?)
	local frame = findFrame(playerGui)
	if not frame then
		return
	end
	activeFrame = frame
	local label = findLabel(frame)
	if not label then
		warn(string.format("[StraitForceLockTimer] No TextLabel under %s — author one named %q in Studio.", frame:GetFullName(), LABEL_NAME))
		return
	end
	activeLabel = label
	activePulseScale = ensurePulseScale(frame)

	if not forceLock or typeof(forceLock.untilTimestamp) ~= "number" then
		hide()
		return
	end
	local now = workspace:GetServerTimeNow()
	if forceLock.untilTimestamp <= now then
		hide()
		return
	end

	local sameLock = activeLock and activeLock.version == forceLock.version
	activeLock = forceLock
	applyTheme(frame, label, forceLock.state)
	frame.Visible = true
	lastShownSeconds = -1

	if not sameLock then
		-- Brief opening pop on a *new* lock so the panel announces itself
		-- even if the player misses the banner. Pure scale tween — does not
		-- touch authored Size / Position (per `ui-architecture.mdc` §3).
		local scale = activePulseScale
		if scale then
			scale.Scale = 1.4
			TweenService:Create(scale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
				Scale = 1,
			}):Play()
		end
	end

	startTick()
end

return StraitForceLockTimer
