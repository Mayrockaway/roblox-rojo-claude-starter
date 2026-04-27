--!strict
-- 7-day daily reward calendar (`StarterGui.Daily` modal). Server-authoritative
-- via `DailyRewardCalendarService`; this controller paints the four per-slot
-- states from `DailyRewardUpdate` snapshots and forwards CLAIM clicks.
--
-- Per-slot states:
--   * Claimed   — slot index ≤ claimedCount. Grey icon + grey button +
--                 "CLAIMED" text. Inactive.
--   * Available — slot index == claimedCount + 1 AND secondsUntilNext == 0.
--                 Green button gradient + "CLAIM" text. Click fires
--                 `RequestClaimDailyReward`. Only ONE slot is ever in this
--                 state at a time (the next unclaimed slot).
--   * Pending   — slot index == claimedCount + 1 AND secondsUntilNext > 0.
--                 Default-dark button + countdown text (HH:MM:SS). Inactive.
--   * Locked    — slot index > claimedCount + 1. Default-dark button +
--                 "LOCKED" text. Inactive.
--
-- The countdown ticks locally between server pushes; the server snapshot
-- arrives once on join + once per successful claim, so any drift is bounded
-- to a single 12h window (and a fresh push lands the moment the player
-- claims again).
--
-- HudPanelRouter integration is unchanged: `bind` + `screenName` keep this
-- panel in the modal-exclusivity group. The state wiring runs once at
-- startup via `M.start(playerGui)` (called from `init.client.luau`); it does
-- NOT depend on the panel being open — the snapshot listener stays live so
-- the next time the player opens the panel the visuals are already correct
-- without a re-fetch round-trip.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DailyRewardCalendarConfig = require(Shared:WaitForChild("Config"):WaitForChild("DailyRewardCalendarConfig"))

local HudPanelBase = require(script.Parent.Parent.HudPanelBase)
local HudPanelTypes = require(script.Parent.Parent.HudPanelTypes)

--- `getClientRemotes` lives at `PlayerScripts.Client.GetClientRemotes`. This
--- file is `PlayerScripts.Client.UI.HudPanels.DailyPanel`, so walk up two
--- levels to find it. (Same pattern as `FreeDailyDrillController`, which
--- walks up one level from `UI/`.)
local getClientRemotes = require(script.Parent.Parent.Parent:WaitForChild("GetClientRemotes")) :: () -> any

--- Shared "kaching" jingle module (`PlayerScripts.Client.UiSfx`). Used by
--- monetization toasts, the FTUE plot-shipment grant, and now this panel —
--- one canonical sound asset (`ReplicatedStorage.Assets.SFX.Kaching`) so the
--- audio bed stays consistent across reward feedback.
local UiSfx = require(script.Parent.Parent.Parent:WaitForChild("UiSfx")) :: {
	playKaching: () -> (),
}

local SCREEN_NAME = "Daily"

local AVAILABLE_TEXT = "CLAIM"
local CLAIMED_TEXT = "CLAIMED"
local LOCKED_TEXT = "LOCKED"

--- Per-state chrome. Each entry is the styling for one of the four slot
--- states. Pulled out as a table (rather than four sets of constants
--- scattered through `setSlotState`) so a designer iterating on color can
--- adjust everything for a given state in one place.
---
--- Color philosophy: each state maps to a saturated, traffic-light-style
--- background so a player can scan the panel and read the streak position
--- without parsing text — bright green = ready, gold = waiting, neutral
--- grey = locked, dark grey = spent. Locked switched from "default Studio
--- gradient" to an explicit neutral grey so the unclaimed-but-not-next
--- slots still pop a tiny bit instead of blending into the panel.
local STATE_STYLE: { [string]: {
	gradient: ColorSequence?,
	strokeColor: Color3,
	strokeThickness: number?,
	textColor: Color3,
	imageColor: Color3,
} } = {
	available = {
		--- Vivid emerald — punched up from the previous mid-saturation green
		--- so the "go" cue reads from across the screen.
		gradient = ColorSequence.new(
			Color3.fromRGB(46, 230, 96),
			Color3.fromRGB(14, 168, 60)
		),
		strokeColor = Color3.fromRGB(190, 255, 200),
		strokeThickness = 3,
		textColor = Color3.fromRGB(255, 255, 255),
		imageColor = Color3.fromRGB(255, 255, 255),
	},
	pending = {
		--- True gold (not amber). Higher saturation so the timer pill reads
		--- as a "treasure-imminent" cue rather than a muted warning tone.
		gradient = ColorSequence.new(
			Color3.fromRGB(255, 214, 56),
			Color3.fromRGB(214, 158, 0)
		),
		strokeColor = Color3.fromRGB(255, 230, 130),
		strokeThickness = 3,
		textColor = Color3.fromRGB(255, 255, 255),
		imageColor = Color3.fromRGB(255, 255, 255),
	},
	locked = {
		--- Neutral medium grey (no blue tint, no Studio default fall-through)
		--- so locked slots read as "not yet" without competing with the gold
		--- pending or green available pills.
		gradient = ColorSequence.new(
			Color3.fromRGB(140, 145, 152),
			Color3.fromRGB(95, 100, 108)
		),
		strokeColor = Color3.fromRGB(100, 105, 115),
		strokeThickness = 2,
		textColor = Color3.fromRGB(220, 222, 228),
		imageColor = Color3.fromRGB(255, 255, 255),
	},
	claimed = {
		--- Darker than locked so already-claimed slots feel "spent" rather
		--- than "waiting" — the player can scan the panel and immediately see
		--- the streak position from the dark→bright→dim gradient pattern.
		gradient = ColorSequence.new(
			Color3.fromRGB(60, 60, 65),
			Color3.fromRGB(38, 38, 42)
		),
		strokeColor = Color3.fromRGB(90, 90, 95),
		strokeThickness = 1.5,
		textColor = Color3.fromRGB(140, 140, 148),
		--- Greyed icon tint for Claimed slots — visually "spent".
		imageColor = Color3.fromRGB(110, 110, 110),
	},
}

--- Press-bounce: short squash + spring-back on the claim button itself.
--- Two tweens chained so the spring overshoots cleanly. Total ~0.20s — long
--- enough to register as feedback, short enough to not delay the visual
--- state transition that follows on the next server snapshot.
local PRESS_DOWN_INFO = TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_UP_INFO = TweenInfo.new(0.13, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local PRESS_DOWN_SCALE = 0.92

--- Hover lift: small scale-up while the cursor is over an Available slot so
--- the player can see which one is interactive when there are multiple
--- panels open / partial obscuring. Runs on its OWN `UIScale` (`HoverScale`)
--- separate from the `PressScale` used by `playPressBounce` — Roblox
--- multiplies stacked UIScales, so the two animations compose cleanly
--- (hover holds at 1.05 while a press squash plays 1→0.92→1, net visible
--- scale follows the press but always returns to the hovered rest of 1.05).
local HOVER_UP_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local HOVER_DOWN_INFO = TweenInfo.new(0.10, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local HOVER_LIFTED_SCALE = 1.05

--- Reveal pulse: when a slot transitions to Claimed (its index just landed
--- on the snapshot's `claimedCount`), scale-pulse the icon so the player
--- gets a satisfying visual on top of the kaching jingle. For Slot 2 this
--- coincides with the boat-icon swap, doubling as the "you rolled X"
--- reveal — no popup needed.
local REVEAL_UP_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local REVEAL_DOWN_INFO = TweenInfo.new(0.30, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local REVEAL_PEAK_SCALE = 1.30

local DailyPanel = {}

local function formatHMS(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	local h = math.floor(s / 3600)
	local m = math.floor((s % 3600) / 60)
	local sec = s % 60
	return string.format("%02d:%02d:%02d", h, m, sec)
end

--- Disable click-blocking on every descendant of the Claim button so the
--- `Activated` event fires when the player taps the inner pill / text /
--- gradient. Mirrors `FreeDailyDrillController`'s `passthroughBuyDecorations`
--- equivalent and `EquipmentShopPanel`'s `passthroughBuyDecorations`.
local function passthroughClicks(btn: GuiButton)
	for _, d in ipairs(btn:GetDescendants()) do
		if d:IsA("GuiObject") then
			d.Active = false
		end
	end
	btn.Active = true
end

type RewardRefs = {
	frame: Instance,
	button: GuiButton?,
	main: Instance?,
	textLabel: TextLabel?,
	gradient: UIGradient?,
	image: ImageLabel?,
	imageScale: UIScale?,
	stroke: UIStroke?,
	pressScale: UIScale?,
	hoverScale: UIScale?,
	defaultGradient: ColorSequence?,
	defaultImageColor: Color3?,
	defaultImageAsset: string?,
	defaultTextColor: Color3?,
}

--- Find or create the press / hover `UIScale`s on the button. Two separate
--- objects (named "PressScale" and "HoverScale") so the two animations
--- compose without fighting — Roblox multiplies stacked UIScales, so a
--- press squash mid-hover lands at 0.92 × 1.05 ≈ 0.966 then resolves back
--- to the held hover rest of 1.05 once the press tween completes. We create
--- the missing one if Studio authoring didn't ship them, so the controller
--- works without a manual GUI edit. Idempotent: `FindFirstChild` by name
--- returns the same object across re-runs.
local function ensureNamedScale(parent: GuiObject, name: string): UIScale
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("UIScale") then
		return existing
	end
	local scale = Instance.new("UIScale")
	scale.Name = name
	scale.Scale = 1
	scale.Parent = parent
	return scale
end

--- Find or create a black, scale-aware `UIStroke` on a TextLabel so the
--- CLAIM / timer / LOCKED / CLAIMED text reads cleanly against any state
--- gradient (the green and gold are bright enough that white text without
--- an outline blows out). `ApplyStrokeMode = Contextual` keeps the stroke
--- INSIDE the text bounding box (no layout shift); `LineJoinMode = Round`
--- keeps tight font corners from spiking.
---
--- Auto-thickness: tied to `AbsoluteSize.Y` of the TextLabel via a
--- `GetPropertyChangedSignal` connection so the stroke stays proportional
--- when the panel resizes (Studio rescale, viewport change, panel grow).
--- 15% of font height reads bold against the bright Available green and
--- the gold Pending pill where a thinner stroke vanishes — adjust the
--- ratio below if a designer wants a more / less aggressive outline.
local TEXT_STROKE_RATIO = 0.15
local TEXT_STROKE_MIN_PX = 2
local TEXT_STROKE_MAX_PX = 6

local function ensureTextStroke(textLabel: TextLabel): UIStroke
	local existing = textLabel:FindFirstChild("ChromeStroke")
	local stroke: UIStroke
	if existing and existing:IsA("UIStroke") then
		stroke = existing
	else
		stroke = Instance.new("UIStroke")
		stroke.Name = "ChromeStroke"
		stroke.Parent = textLabel
	end
	stroke.Color = Color3.fromRGB(0, 0, 0)
	stroke.Transparency = 0
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	stroke.LineJoinMode = Enum.LineJoinMode.Round

	local function recompute()
		local px = textLabel.AbsoluteSize.Y * TEXT_STROKE_RATIO
		stroke.Thickness = math.clamp(px, TEXT_STROKE_MIN_PX, TEXT_STROKE_MAX_PX)
	end
	recompute()
	textLabel:GetPropertyChangedSignal("AbsoluteSize"):Connect(recompute)
	return stroke
end

local function findRewardRefs(container: Instance, total: number): { [number]: RewardRefs }
	local out: { [number]: RewardRefs } = {}
	for i = 1, total do
		local r = container:FindFirstChild("Reward" .. i)
		if not r then continue end
		local btn = r:FindFirstChild("Button")
		local main = btn and btn:FindFirstChild("Main")
		local backing = btn and btn:FindFirstChild("Backing")
		local textLbl = main and main:FindFirstChild("TextLabel")
		local grad = main and main:FindFirstChildOfClass("UIGradient")
		local img = r:FindFirstChild("ImageLabel")
		--- The visible outline for the per-state "chrome" is the stroke on
		--- `Button.Backing` (Studio authoring; see `StarterGui.Daily…
		--- Reward1.Button.Backing.UIStroke`). We tint that per state. The
		--- standalone outer-frame stroke on `RewardN.UIStroke` is left alone
		--- so the panel's overall border treatment stays consistent.
		local stroke = backing and backing:FindFirstChildOfClass("UIStroke")
		local pressScale: UIScale? = nil
		local hoverScale: UIScale? = nil
		if btn and btn:IsA("GuiButton") then
			pressScale = ensureNamedScale(btn, "PressScale")
			hoverScale = ensureNamedScale(btn, "HoverScale")
		end
		--- Reveal pulse target lives on the icon itself, not the frame, so
		--- the surrounding "CLAIMED" pill chrome stays put and only the icon
		--- jumps. Studio authoring doesn't ship a UIScale on the icon —
		--- we add one named "RevealScale" the first time `start()` runs.
		local imageScale: UIScale? = nil
		if img and img:IsA("ImageLabel") then
			imageScale = ensureNamedScale(img, "RevealScale")
		end

		--- IMPORTANT: `UIGradient` is multiplicative with `BackgroundColor3`
		--- (visible RGB = bg.RGB × gradient.RGB). Studio authoring ships
		--- `Main.BackgroundColor3 ≈ (0.05, 0.10, 0.16)` (very dark navy), so
		--- a vivid green gradient gets multiplied down to near-black and
		--- the per-state chrome looks like it's not changing at all. Force
		--- the BG to white at init so the gradient ColorSequence we set per
		--- state shows pure — the cached `defaultGradient` (also dark) keeps
		--- the original dark-pill aesthetic for slots whose state has
		--- `style.gradient = nil` (not used today; all four states now have
		--- explicit gradients).
		if main and main:IsA("Frame") then
			main.BackgroundColor3 = Color3.new(1, 1, 1)
		end

		--- Black, scale-aware text stroke for the per-state label
		--- (CLAIM / timer / LOCKED / CLAIMED). The bright green and gold
		--- gradients drown out white text without an outline; the stroke
		--- restores legibility on every state. Auto-rescales with the
		--- TextLabel's `AbsoluteSize.Y` so the panel-grow / viewport change
		--- doesn't leave the outline as a hairline.
		--- Also bump the TextLabel itself to fill ~92% × 88% of the button
		--- (Studio default authoring is 0.52 × 0.62 which leaves the text
		--- tiny against the now-larger panel — this gives the per-state
		--- label real visual weight, and a bigger TextScaled label means
		--- a thicker auto-stroke too, compounding the legibility win).
		if textLbl and textLbl:IsA("TextLabel") then
			textLbl.Size = UDim2.new(0.92, 0, 0.88, 0)
			ensureTextStroke(textLbl)
		end
		out[i] = {
			frame = r,
			button = (btn :: any),
			main = main,
			textLabel = (textLbl :: any),
			gradient = (grad :: any),
			image = (img :: any),
			imageScale = imageScale,
			stroke = (stroke :: any),
			pressScale = pressScale,
			hoverScale = hoverScale,
			defaultGradient = grad and (grad :: UIGradient).Color or nil,
			defaultImageColor = img and (img :: ImageLabel).ImageColor3 or nil,
			defaultImageAsset = img and (img :: ImageLabel).Image or nil,
			defaultTextColor = textLbl and (textLbl :: TextLabel).TextColor3 or nil,
		}
	end
	return out
end

--- Squash + spring bounce on the press UIScale. Two chained tweens: down
--- to 0.92 (Quad-Out), then up to 1.0 with `Back` easing for the slight
--- overshoot. Operates on a dedicated `PressScale` so the held hover lift
--- (`HoverScale = 1.05`) doesn't get clobbered.
local function playPressBounce(scale: UIScale)
	scale.Scale = 1
	local downTween = TweenService:Create(scale, PRESS_DOWN_INFO, { Scale = PRESS_DOWN_SCALE })
	downTween:Play()
	downTween.Completed:Connect(function(state)
		if state ~= Enum.PlaybackState.Completed then
			return
		end
		TweenService:Create(scale, PRESS_UP_INFO, { Scale = 1 }):Play()
	end)
end

--- Tween the hover scale to a target. Used by `MouseEnter` / `MouseLeave`
--- on Available slots and by `setSlotState` to snap the hover back to 1.0
--- when a slot transitions out of Available (so a hovered slot that just
--- got claimed doesn't stay lifted while the cursor is still over it).
local function tweenHover(scale: UIScale, target: number, info: TweenInfo)
	TweenService:Create(scale, info, { Scale = target }):Play()
end

--- Reveal pulse: scale up to 1.30 with a Back-Out overshoot, then settle
--- back to 1.0 with a slower Quad-Out. Plays once per slot on the snapshot
--- where its index just got claimed. For Slot 2 the icon swap to the
--- rolled boat happens BEFORE the pulse fires (same snapshot tick), so the
--- pulse highlights the new icon — that IS the reveal.
local function playRevealPulse(scale: UIScale)
	scale.Scale = 1
	local upTween = TweenService:Create(scale, REVEAL_UP_INFO, { Scale = REVEAL_PEAK_SCALE })
	upTween:Play()
	upTween.Completed:Connect(function(state)
		if state ~= Enum.PlaybackState.Completed then
			return
		end
		TweenService:Create(scale, REVEAL_DOWN_INFO, { Scale = 1 }):Play()
	end)
end

--- HUD `DailyButton` claimable-state highlight. Returns a `setClaimable`
--- closure the caller drives from snapshot + 1Hz tick. While the player has
--- a reward ready to claim:
---   * the button slowly pulses (UIScale 1↔1.1, sin-loop) to draw the eye
---   * a bright-red exclamation badge appears in the top-right corner
--- When no reward is claimable (cooldown active, or all slots claimed),
--- the pulse cancels back to scale 1 and the badge hides. Both helpers
--- live on dedicated children (`ClaimablePulse` UIScale, `ClaimableBadge`
--- Frame) so they don't fight any other HUD authoring or animations.
local CLAIMABLE_PULSE_INFO = TweenInfo.new(
	0.7,                            -- one-way duration
	Enum.EasingStyle.Sine,
	Enum.EasingDirection.InOut,
	-1,                             -- repeat forever
	true,                           -- reverse (so it pulses 1→1.1→1→...)
	0
)
local CLAIMABLE_PULSE_PEAK = 1.10
local BADGE_BG_COLOR = Color3.fromRGB(220, 40, 40)
local BADGE_TEXT_COLOR = Color3.fromRGB(255, 255, 255)

local function ensureClaimableBadge(parent: GuiObject): Frame
	local existing = parent:FindFirstChild("ClaimableBadge")
	if existing and existing:IsA("Frame") then
		return existing
	end
	local badge = Instance.new("Frame")
	badge.Name = "ClaimableBadge"
	badge.AnchorPoint = Vector2.new(1, 0)
	badge.Position = UDim2.new(1, 4, 0, -4)
	badge.Size = UDim2.new(0.42, 0, 0.42, 0)
	badge.BackgroundColor3 = BADGE_BG_COLOR
	badge.BorderSizePixel = 0
	badge.ZIndex = (parent :: any).ZIndex + 5
	badge.Visible = false

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = badge

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(255, 255, 255)
	stroke.Thickness = 2
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = badge

	--- Lock the badge to a 1:1 aspect ratio so the circle stays round
	--- regardless of parent button shape.
	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectRatio = 1
	aspect.Parent = badge

	local label = Instance.new("TextLabel")
	label.Name = "BadgeLabel"
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.new(0.5, 0, 0.5, 0)
	label.Size = UDim2.new(0.85, 0, 0.85, 0)
	label.BackgroundTransparency = 1
	label.Text = "!"
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextColor3 = BADGE_TEXT_COLOR
	label.ZIndex = badge.ZIndex + 1
	local labelStroke = Instance.new("UIStroke")
	labelStroke.Color = Color3.fromRGB(0, 0, 0)
	labelStroke.Thickness = 2
	labelStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	labelStroke.Parent = label
	label.Parent = badge

	badge.Parent = parent
	return badge
end

type ClaimableHighlight = {
	setClaimable: (boolean) -> (),
}

local function setupHudClaimableHighlight(playerGui: PlayerGui): ClaimableHighlight?
	local hud = playerGui:FindFirstChild("HUD")
	local canvas = hud and hud:FindFirstChild("Canvas")
	local buttons = canvas and canvas:FindFirstChild("Buttons")
	local btn = buttons and buttons:FindFirstChild("DailyButton")
	if not (btn and btn:IsA("GuiObject")) then
		warn("[DailyPanel] HUD.Canvas.Buttons.DailyButton not found — claimable highlight disabled")
		return nil
	end

	local pulseScale = ensureNamedScale(btn, "ClaimablePulse")
	local badge = ensureClaimableBadge(btn)

	local pulseTween: Tween? = nil
	local lastClaimable = false

	local function setClaimable(isClaimable: boolean)
		if isClaimable == lastClaimable then
			return
		end
		lastClaimable = isClaimable
		if isClaimable then
			--- Snap to rest first so the loop starts from a clean state on
			--- every transition (matters if the player rapidly claims and
			--- the next slot becomes available within the same frame).
			pulseScale.Scale = 1
			if pulseTween then
				pulseTween:Cancel()
			end
			pulseTween = TweenService:Create(pulseScale, CLAIMABLE_PULSE_INFO, { Scale = CLAIMABLE_PULSE_PEAK })
			pulseTween:Play()
			badge.Visible = true
		else
			if pulseTween then
				pulseTween:Cancel()
				pulseTween = nil
			end
			pulseScale.Scale = 1
			badge.Visible = false
		end
	end

	--- Initial state: assume not-claimable until the first server snapshot
	--- arrives. The snapshot listener will flip it to claimable within the
	--- 3s `task.defer + task.wait(3)` push window in the service.
	setClaimable(false)
	return { setClaimable = setClaimable }
end

function DailyPanel.start(playerGui: PlayerGui)
	local Remotes = getClientRemotes()
	if not Remotes then
		warn("[DailyPanel] could not resolve ClientRemotes")
		return
	end

	--- Shell + content authored in Studio (`StarterGui.Daily`). Wait for the
	--- ScreenGui to replicate; the shell is small (≪1KB) so this lands fast.
	local screen = playerGui:WaitForChild(SCREEN_NAME, 30) :: ScreenGui?
	if not screen then
		warn("[DailyPanel] PlayerGui." .. SCREEN_NAME .. " never appeared")
		return
	end
	local canvas = screen:WaitForChild("Canvas", 10)
	local container = canvas and canvas:FindFirstChild("Container")
	local main = container and container:FindFirstChild("Main")
	local rewardStrip = main and main:FindFirstChild("Container")
	if not rewardStrip then
		warn("[DailyPanel] Daily.Canvas.Container.Main.Container not found")
		return
	end

	local total = DailyRewardCalendarConfig.TotalRewards
	local rewards = findRewardRefs(rewardStrip, total)

	--- HUD `DailyButton` claimable-state highlight (pulse + red exclamation
	--- badge). `setupHudClaimableHighlight` returns `nil` if the button
	--- can't be resolved (e.g., HUD ScreenGui not loaded yet) — every
	--- update site below is `claimableHighlight and ...` guarded so a
	--- missing button is a soft no-op.
	local claimableHighlight = setupHudClaimableHighlight(playerGui)

	--- Cooldown duration is included in every server push (from config) so
	--- this controller doesn't need to keep its own copy in sync. Initialize
	--- with the local config value so we have something sensible before the
	--- first push lands.
	local cooldownSeconds = DailyRewardCalendarConfig.CooldownSeconds
	local claimedCount = 0
	--- `secondsAtPush` + `pushedAt` is the local-tick baseline — same trick
	--- as `FreeDailyDrillController`. The server pushes
	--- `secondsUntilNext` once per snapshot; we tick it down locally so the
	--- displayed countdown is smooth without a 1Hz remote.
	local secondsAtPush = 0
	local pushedAt = os.clock()

	local function localSecondsLeft(): number
		if claimedCount >= total then
			return 0
		end
		return math.max(0, secondsAtPush - (os.clock() - pushedAt))
	end

	local function setSlotState(i: number, state: string, text: string)
		local r = rewards[i]
		if not r then return end
		local style = STATE_STYLE[state]
		if r.textLabel then
			r.textLabel.Text = text
			if style then
				r.textLabel.TextColor3 = style.textColor
			elseif r.defaultTextColor then
				r.textLabel.TextColor3 = r.defaultTextColor
			end
		end
		if r.gradient and r.defaultGradient then
			--- `style.gradient == nil` means "restore Studio-authored
			--- gradient" (used for Locked so the designer's muted palette
			--- shows through). Other states override.
			r.gradient.Color = (style and style.gradient) or r.defaultGradient
		end
		if r.image and r.defaultImageColor then
			if style then
				r.image.ImageColor3 = style.imageColor
			else
				r.image.ImageColor3 = r.defaultImageColor
			end
		end
		if r.stroke and style then
			r.stroke.Color = style.strokeColor
			if style.strokeThickness then
				r.stroke.Thickness = style.strokeThickness
			end
		end
		if r.button then
			--- AutoButtonColor + Active gate the click. Only the Available
			--- slot is interactive; the others paint as static visuals.
			r.button.AutoButtonColor = (state == "available")
			r.button.Active = (state == "available")
		end
		--- Snap the hover scale back to rest if the slot just transitioned
		--- out of Available — a slot the cursor was hovering on at the
		--- moment of claim shouldn't stay lifted at 1.05 forever. The
		--- MouseEnter/Leave handlers below also gate on the live state, so
		--- a fresh hover post-transition won't lift it again until it
		--- becomes Available next time.
		if r.hoverScale and state ~= "available" then
			r.hoverScale.Scale = 1
		end
	end

	local function repaint()
		local nextIdx = claimedCount + 1
		local secLeft = localSecondsLeft()
		for i = 1, total do
			if i <= claimedCount then
				setSlotState(i, "claimed", CLAIMED_TEXT)
			elseif i == nextIdx then
				if secLeft <= 0 then
					setSlotState(i, "available", AVAILABLE_TEXT)
				else
					setSlotState(i, "pending", formatHMS(secLeft))
				end
			else
				setSlotState(i, "locked", LOCKED_TEXT)
			end
		end
		--- Drive the HUD button highlight from the same condition that
		--- decides "Available" inside the panel. Idempotent (the helper
		--- short-circuits on no-op transitions), so calling on every
		--- repaint is cheap.
		if claimableHighlight then
			local isClaimable = (claimedCount < total) and (secLeft <= 0)
			claimableHighlight.setClaimable(isClaimable)
		end
	end

	--- Wire each Reward's button. We use a per-slot click handler (rather
	--- than a shared one that figures out the slot from the click target)
	--- because the slot index is fixed per-frame; this keeps the click path
	--- branch-free. The handler enforces the same gate the server does
	--- (`i == claimedCount + 1` AND timer elapsed) so a stale click at the
	--- exact moment of state transition is rejected client-side too.
	--- Helper: is slot `i` currently in the Available state? Used by the
	--- hover handlers so a `MouseEnter` on a slot that's pending / locked /
	--- claimed doesn't lift it. Cheap (mirrors the same condition as the
	--- repaint loop).
	local function isSlotAvailable(slotIndex: number): boolean
		if slotIndex ~= claimedCount + 1 then
			return false
		end
		return localSecondsLeft() <= 0
	end

	for i = 1, total do
		local r = rewards[i]
		if r and r.button then
			passthroughClicks(r.button)

			--- Hover lift on Available slots. Gated each frame on the live
			--- `isSlotAvailable(i)` so a slot that becomes locked / pending
			--- under the cursor doesn't stay lifted, and a slot the cursor
			--- was already hovering when it BECAME available smoothly lifts
			--- on the next `MouseEnter` (or stays at rest until the cursor
			--- leaves and re-enters — acceptable, the transition itself
			--- gives the visual cue).
			r.button.MouseEnter:Connect(function()
				if not r.hoverScale then return end
				if not isSlotAvailable(i) then return end
				tweenHover(r.hoverScale, HOVER_LIFTED_SCALE, HOVER_UP_INFO)
			end)
			r.button.MouseLeave:Connect(function()
				if not r.hoverScale then return end
				tweenHover(r.hoverScale, 1, HOVER_DOWN_INFO)
			end)

			r.button.Activated:Connect(function()
				if not isSlotAvailable(i) then
					return
				end
				--- Press feedback fires even before the server confirms — the
				--- user sees the squash on tap, then the slot transitions to
				--- Claimed once the snapshot arrives. Server rejection
				--- (rate-limited / cooldown race) leaves the bounce as a
				--- harmless visual; the state stays Available so they can
				--- retry.
				if r.pressScale then
					playPressBounce(r.pressScale)
				end
				Remotes.requestClaimDailyReward:FireServer()
			end)
		end
	end

	--- Server → client snapshot. Reset the countdown baseline on every
	--- payload so we don't drift across the 12h window.
	Remotes.dailyRewardUpdate.OnClientEvent:Connect(function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		--- Snapshot the previous count BEFORE we mutate so we can detect a
		--- successful claim (count went up) and play the kaching jingle. The
		--- server is the source of truth for "did the grant land", so playing
		--- on the snapshot increment (rather than on click) means we never
		--- play the jingle on a rejected claim.
		local prevClaimed = claimedCount
		if typeof(payload.claimedCount) == "number" then
			claimedCount = math.max(0, math.min(total, math.floor(payload.claimedCount)))
		end
		if typeof(payload.secondsUntilNext) == "number" then
			secondsAtPush = math.max(0, payload.secondsUntilNext)
			pushedAt = os.clock()
		end
		if typeof(payload.cooldownSeconds) == "number" and payload.cooldownSeconds > 0 then
			cooldownSeconds = payload.cooldownSeconds
		end
		--- `payload.totalRewards` intentionally NOT bound to a runtime
		--- variable — slot count is baked into the GUI authoring (`Reward1`..
		--- `RewardN`) and into `DailyRewardCalendarConfig.TotalRewards` at
		--- module require time. If the two ever diverge, the rendering loop
		--- silently truncates to whatever frames exist; warn so we notice.
		if typeof(payload.totalRewards) == "number" and payload.totalRewards ~= total then
			warn(string.format(
				"[DailyPanel] server totalRewards=%d disagrees with client config TotalRewards=%d",
				payload.totalRewards, total
			))
		end
		--- Slot 2 random-boat reveal: paint the rolled hull's icon over the
		--- placeholder before `repaint()` runs the Claimed greying pass, so
		--- the swap and the grey-out land in the same frame and the reveal
		--- pulse below highlights the new icon (not the placeholder).
		--- Server only sets `slot2BoatIcon` after slot 2 is claimed, so this
		--- branch is safely a no-op for fresh / pre-D2-claim profiles.
		local slot2Refs = rewards[2]
		if slot2Refs and slot2Refs.image and typeof(payload.slot2BoatIcon) == "string" and payload.slot2BoatIcon ~= "" then
			slot2Refs.image.Image = payload.slot2BoatIcon
		end
		repaint()
		--- Kaching on confirmed redemption. Guarded on `claimedCount > prev`
		--- so the initial join snapshot (prev = 0, count = 0..N from
		--- persisted state) doesn't audibly "claim" every saved slot at once.
		--- Only the post-claim push (where count strictly increases) plays
		--- the jingle. Same guard drives the reveal pulse on the just-
		--- claimed slot's icon — for Slot 2 this lands right after the icon
		--- swap above, so the pulse celebrates the rolled boat.
		if claimedCount > prevClaimed then
			UiSfx.playKaching()
			local justClaimed = prevClaimed + 1
			if justClaimed >= 1 and justClaimed <= total then
				local jr = rewards[justClaimed]
				if jr and jr.imageScale then
					playRevealPulse(jr.imageScale)
				end
			end
		end
	end)

	--- 1Hz countdown tick. Cheap (a small string/property write per slot,
	--- and only the pending slot's text actually changes). Repaint also
	--- handles the "timer just hit zero, flip to Available" transition
	--- without needing a separate timer.
	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt)
		accumulator += dt
		if accumulator < 1.0 then
			return
		end
		accumulator = 0
		if not screen.Parent then
			return
		end
		repaint()
	end)

	repaint()
end

function DailyPanel.bind(playerGui: PlayerGui): HudPanelTypes.HudPanelController?
	return HudPanelBase.tryBind(playerGui, SCREEN_NAME)
end

function DailyPanel.screenName(): string
	return SCREEN_NAME
end

return DailyPanel
