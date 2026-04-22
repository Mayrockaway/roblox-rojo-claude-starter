--!strict
-- Top HUD **`OilPricePanel`**: spot **`basePrice`** + strip **`PriceIndicator`** mood vs **global** spot band (**`globalBaseMin`–`globalBaseMax`**) from `PricingConfig` (all strait bands combined).
-- **`OilPriceInfoPanelGui`**: each row’s **`Marker`** + **`PriceValue`** use the same **global** band × tier multiplier — “all possible” tier $/bbl for any strait, not the current strait only.
-- Runtime: **`Text`**, **`TextColor3`**, **`BackgroundColor3`**, **`UIStroke.Color`**; **`UIScale`** tweens on **`OilPricePanel`** for micro price updates vs strait changes (see `ui-architecture` §6 — no runtime layout hacks on authored shells).
-- Clears legacy **`_OilPriceHistoryTicks`** if present.

local TweenService = game:GetService("TweenService")

export type MarketSnapshot = {
	basePrice: number?,
	prices: { [string]: number }?,
	trend: string?,
	straitState: string?,
	nextChangeAt: number?,
	globalBaseMin: number?,
	globalBaseMax: number?,
	typeMultipliers: { [string]: number }?,
}

local TIER_ROWS: { { row: string, tier: string } } = {
	{ row = "CrudeRow", tier = "Crude" },
	{ row = "RefinedRow", tier = "Refined" },
	{ row = "PremiumRow", tier = "Premium" },
}

local DEFAULT_TYPE_MULS: { [string]: number } = {
	Crude = 0.8,
	Refined = 1.4,
	Premium = 2.0,
}

local COL_GOOD = Color3.fromRGB(72, 175, 98)
local COL_MID = Color3.fromRGB(224, 188, 72)
local COL_BAD = Color3.fromRGB(205, 72, 72)
local COL_UNKNOWN = Color3.fromRGB(150, 150, 155)

-- Top-HUD mood background (`OilPricePanel.MoodBackground`) intentionally uses
-- the **strait status palette** (open / choppy / closed → green / orange / red)
-- instead of the per-row indicator palette above so the player reads the same
-- color language across both panels at a glance. See `StraitStatusHud.luau`.
local MOOD_BG_GOOD = Color3.fromRGB(72, 168, 118)
local MOOD_BG_MID = Color3.fromRGB(218, 118, 38)
local MOOD_BG_BAD = Color3.fromRGB(176, 18, 32)
local MOOD_BG_UNKNOWN = Color3.fromRGB(60, 60, 64)

-- Direction arrows on `Row.PriceIndicator.Arrow`. Studio authors the
-- ImageLabel layout/size as a 1:1 fill of the existing placeholder; runtime
-- only swaps `.Image` on price-tick. Keeping the asset IDs here (and not on
-- the authored ImageLabel beyond a default) keeps the source-of-truth for
-- "which way did the market move" in code where the up/down decision lives.
local ARROW_IMG_UP = "rbxassetid://115035977128519"
local ARROW_IMG_DOWN = "rbxassetid://100037273574272"

-- Perpetual idle bob applied to the `Arrow` ImageLabel inside
-- `PriceIndicator`. Pixels each direction (so total travel = 2× amp) and one
-- bob direction takes BOB_TIME seconds; reverses + repeats forever via the
-- TweenInfo flags so we only kick off ONE tween per arrow instance and let
-- the engine handle the loop. The bob lives on `Position.Y.Offset` instead
-- of a child `UIScale` so it actually translates the icon (scale would just
-- pulse it in place); offset is small enough that even when the parent
-- `PriceIndicator` clips, the arrow only loses ~`ARROW_BOB_AMP_PX` px at the
-- top/bottom of its travel and reads as a gentle hover.
local ARROW_BOB_AMP_PX = 4
local ARROW_BOB_TIME = 0.85

local LEGACY_HISTORY_FOLDER = "_OilPriceHistoryTicks"

local ANIM_SCALE_NAME = "OilPricePanelAnimScale"

local lastSnapshotBase: number? = nil
local lastSnapshotStrait: string? = nil
local lastStraitPulseAt = 0.0
local activeScaleTween: Tween? = nil
-- Persist the last direction icon shown so a quiet snapshot (price unchanged)
-- doesn't blank the arrow back to a default — the icon stays at whichever way
-- the market last moved until the next non-zero delta.
local lastArrowImage: string? = nil

-- Bob state: bound to a single `Arrow` ImageLabel + the Studio-authored
-- base Position we snapshot on first bind. We only ever run ONE perpetual
-- tween at a time; rebinding (canvas swap, instance destroyed) cancels the
-- previous tween before starting a fresh one so the engine doesn't keep a
-- handle on a dead instance.
local bobBoundArrow: ImageLabel? = nil
local bobBasePosition: UDim2? = nil
local arrowBobTween: Tween? = nil

local OilPriceHud = {}

local function findOilPricePanel(canvas: Frame): Frame?
	local topRow = canvas:FindFirstChild("TopRow")
	local panel = topRow and topRow:FindFirstChild("OilPricePanel")
	if panel and panel:IsA("Frame") then
		return panel
	end
	return nil
end

local function getOrCreateAnimScale(panel: GuiObject): UIScale
	local s = panel:FindFirstChild(ANIM_SCALE_NAME)
	if s and s:IsA("UIScale") then
		return s
	end
	local sc = Instance.new("UIScale")
	sc.Name = ANIM_SCALE_NAME
	sc.Scale = 1
	sc.Parent = panel
	return sc
end

local function cancelOilPricePanelScaleTween()
	if activeScaleTween then
		activeScaleTween:Cancel()
		activeScaleTween = nil
	end
end

local function playOilPricePanelJitter(panel: Frame)
	cancelOilPricePanelScaleTween()
	local sc = getOrCreateAnimScale(panel)
	sc.Scale = 1
	local up = TweenService:Create(sc, TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Scale = 1.045,
	})
	activeScaleTween = up
	up.Completed:Connect(function(playback: Enum.PlaybackState)
		if playback == Enum.PlaybackState.Cancelled then
			return
		end
		local down = TweenService:Create(sc, TweenInfo.new(0.38, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Scale = 1,
		})
		activeScaleTween = down
		down.Completed:Connect(function(pb: Enum.PlaybackState)
			if pb ~= Enum.PlaybackState.Cancelled then
				activeScaleTween = nil
			end
		end)
		down:Play()
	end)
	up:Play()
end

local function playOilPricePanelStraitPulse(panel: Frame)
	cancelOilPricePanelScaleTween()
	lastStraitPulseAt = os.clock()
	local sc = getOrCreateAnimScale(panel)
	sc.Scale = 1
	local punch = TweenService:Create(sc, TweenInfo.new(0.48, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Scale = 1.14,
	})
	activeScaleTween = punch
	punch.Completed:Connect(function(playback: Enum.PlaybackState)
		if playback == Enum.PlaybackState.Cancelled then
			return
		end
		local settle = TweenService:Create(sc, TweenInfo.new(0.78, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out), {
			Scale = 1,
		})
		activeScaleTween = settle
		settle.Completed:Connect(function(pb: Enum.PlaybackState)
			if pb ~= Enum.PlaybackState.Cancelled then
				activeScaleTween = nil
			end
		end)
		settle:Play()
	end)
	punch:Play()
end

local function findHudCanvas(playerGui: PlayerGui): Frame?
	local hud = playerGui:FindFirstChild("HUD")
	if not (hud and hud:IsA("ScreenGui")) then
		hud = playerGui:FindFirstChild("HUD", true)
	end
	if not (hud and hud:IsA("ScreenGui")) then
		return nil
	end
	local canvas = hud:FindFirstChild("Canvas")
	if canvas and canvas:IsA("Frame") then
		return canvas
	end
	return nil
end

local function formatStripSpotLine(basePrice: number): string
	if basePrice <= 0 then
		return "Oil: —/bbl"
	end
	return string.format("Oil: $%d/bbl", math.floor(basePrice))
end

local function tierMultiplier(snapshot: MarketSnapshot, tier: string): number
	local tm = snapshot.typeMultipliers
	if typeof(tm) == "table" then
		local m = (tm :: { [string]: any })[tier]
		if typeof(m) == "number" and m > 0 then
			return m
		end
	end
	return DEFAULT_TYPE_MULS[tier] or 1
end

-- 0 = global band low (bad for sellers), 1 = global band high (good).
local function normalizedInBand(value: number, bandMin: number, bandMax: number): number
	local vmin = math.floor(bandMin)
	local vmax = math.floor(bandMax)
	if vmax < vmin then
		vmin, vmax = vmax, vmin
	end
	local v = math.floor(value)
	local span = math.max(1, vmax - vmin)
	return math.clamp((v - vmin) / span, 0, 1)
end

local function moodFromNormalizedT(t: number): Color3
	if t >= 0.61 then
		return COL_GOOD
	elseif t <= 0.39 then
		return COL_BAD
	end
	return COL_MID
end

local function moodColorFromBaseGlobal(base: number, gMin: number, gMax: number): Color3
	return moodFromNormalizedT(normalizedInBand(base, gMin, gMax))
end

-- Same band-band lookup as `moodColorFromBaseGlobal` but returns the strait-
-- status palette so the panel **background** reads with the same green /
-- orange / red language as the top-of-HUD strait status banner.
local function moodBackgroundColorFromBaseGlobal(base: number, gMin: number, gMax: number): Color3
	if base <= 0 then
		return MOOD_BG_UNKNOWN
	end
	local t = normalizedInBand(base, gMin, gMax)
	if t >= 0.61 then
		return MOOD_BG_GOOD
	elseif t <= 0.39 then
		return MOOD_BG_BAD
	end
	return MOOD_BG_MID
end

local function applyMoodBackground(button: GuiButton, color: Color3)
	-- Mood color lands on the **`OilPriceButton`** itself — Studio owns
	-- everything else about the button (size, corner, stroke, padding,
	-- the inner `PriceText` label); runtime only flips `BackgroundColor3`
	-- to good / average / bad mood (per `ui-architecture` §6, "default
	-- visuals + colors on dynamic elements" exception).
	if button.BackgroundColor3 ~= color then
		button.BackgroundColor3 = color
	end
end

local function findArrowLabel(indicator: GuiObject): ImageLabel?
	-- Canonical Studio path is `Row.PriceIndicator.Arrow` (ImageLabel) —
	-- author the layout/size in Studio so phone/desktop both fill the
	-- placeholder identically. If `Arrow` is missing (legacy panel build),
	-- the runtime simply skips the direction icon — no fallback creation,
	-- so authoring drift surfaces visibly instead of silently fabricating
	-- an off-spec icon (per `ui-architecture` §3 / §11).
	local arrow = indicator:FindFirstChild("Arrow")
	if arrow and arrow:IsA("ImageLabel") then
		return arrow
	end
	return nil
end

--- Kick off (or rebind) the perpetual vertical bob on the price-indicator
--- arrow. Idempotent on the same instance — calling again with the same
--- arrow is a no-op so `applyPriceArrow` can hit this every snapshot
--- without restarting the loop. Cancels and restarts on a different /
--- replaced arrow (canvas rebuild, Studio re-author). The base Position is
--- snapshotted on first bind so the bob travels symmetrically around
--- whatever Studio authored, not around the post-tween offset position.
local function ensureArrowBobbing(arrow: ImageLabel)
	if bobBoundArrow == arrow and arrowBobTween and arrow.Parent ~= nil then
		return
	end
	if arrowBobTween then
		arrowBobTween:Cancel()
		arrowBobTween = nil
	end
	-- Restore the previous arrow's Position to its captured base if it
	-- still exists (defensive: the bob tween was mid-cycle on cancel and
	-- would otherwise leave the icon parked off-center).
	if bobBoundArrow and bobBoundArrow ~= arrow and bobBoundArrow.Parent ~= nil and bobBasePosition then
		bobBoundArrow.Position = bobBasePosition
	end
	bobBoundArrow = arrow
	bobBasePosition = arrow.Position
	-- Start the loop at the top of the bob (- amp on Y) so the arrow
	-- immediately drifts downward into the base position rather than
	-- snapping to a side at t=0; the reversing + RepeatCount=-1 flags then
	-- carry it back and forth forever in a single engine-managed tween.
	arrow.Position = UDim2.new(
		bobBasePosition.X.Scale,
		bobBasePosition.X.Offset,
		bobBasePosition.Y.Scale,
		bobBasePosition.Y.Offset - ARROW_BOB_AMP_PX
	)
	local target = UDim2.new(
		bobBasePosition.X.Scale,
		bobBasePosition.X.Offset,
		bobBasePosition.Y.Scale,
		bobBasePosition.Y.Offset + ARROW_BOB_AMP_PX
	)
	local info = TweenInfo.new(
		ARROW_BOB_TIME,
		Enum.EasingStyle.Sine,
		Enum.EasingDirection.InOut,
		-1, -- forever
		true, -- reverses
		0
	)
	local tween = TweenService:Create(arrow, info, { Position = target })
	arrowBobTween = tween
	tween:Play()
end

--- Update the up/down arrow icon based on price delta. Equal price →
--- preserve last-shown arrow so a quiet tick doesn't visually reset.
--- First-ever snapshot (`prevBase == nil`) leaves whatever Studio authored.
local function applyPriceArrow(indicator: GuiObject, base: number, prevBase: number?)
	local arrow = findArrowLabel(indicator)
	if not arrow then
		return
	end
	-- Bob is purely visual / decorative; bind it on every refresh so a
	-- canvas rebuild (HUD reauth, scaffolds re-running) reattaches without
	-- the panel having to know to reseed us. Idempotent on the same arrow.
	ensureArrowBobbing(arrow)
	if prevBase == nil then
		-- Seed from the authored Image so the persisted "last shown" state
		-- matches what the player currently sees (otherwise the next
		-- equal-price tick would be tracked as "no last image").
		lastArrowImage = arrow.Image
		return
	end
	local desired: string?
	if base > prevBase then
		desired = ARROW_IMG_UP
	elseif base < prevBase then
		desired = ARROW_IMG_DOWN
	else
		desired = lastArrowImage
	end
	if desired and arrow.Image ~= desired then
		arrow.Image = desired
	end
	if desired then
		lastArrowImage = desired
	end
end

local function findOilPriceStrip(canvas: Frame): (TextLabel?, GuiObject?, GuiButton?)
	local topRow = canvas:FindFirstChild("TopRow")
	local panel = topRow and topRow:FindFirstChild("OilPricePanel")
	local row = panel and panel:FindFirstChild("Row")
	if not (row and row:IsA("Instance")) then
		return nil, nil, nil
	end
	local btn = row:FindFirstChild("OilPriceButton")
	local priceText: TextLabel? = nil
	local btnObj: GuiButton? = nil
	if btn and btn:IsA("GuiButton") then
		btnObj = btn :: GuiButton
		local pt = btn:FindFirstChild("PriceText")
		if pt and pt:IsA("TextLabel") then
			priceText = pt
		end
	end
	local indicator = row:FindFirstChild("PriceIndicator")
	local indObj: GuiObject? = nil
	if indicator and indicator:IsA("GuiObject") then
		indObj = indicator :: GuiObject
	end
	return priceText, indObj, btnObj
end

local function findPriceValueLabel(row: Instance): TextLabel?
	local rh = row:FindFirstChild("RowHeader")
	if rh then
		local pv = rh:FindFirstChild("PriceValue")
		if pv and pv:IsA("TextLabel") then
			return pv
		end
	end
	local deep = row:FindFirstChild("PriceValue", true)
	if deep and deep:IsA("TextLabel") then
		return deep
	end
	return nil
end

local function clearLegacyHistoryTicks(trackHost: Instance)
	local f = trackHost:FindFirstChild(LEGACY_HISTORY_FOLDER)
	if f then
		f:Destroy()
	end
end

local function wireTierRow(row: Instance, tier: string, snapshot: MarketSnapshot, prices: { [string]: number })
	local gmin = math.floor(tonumber(snapshot.globalBaseMin) or 8)
	local gmax = math.floor(tonumber(snapshot.globalBaseMax) or 80)
	local mult = tierMultiplier(snapshot, tier)
	local tierMin = math.floor(gmin * mult)
	local tierMax = math.floor(gmax * mult)
	local tierPrice = math.max(0, math.floor(tonumber(prices[tier]) or 0))

	local tNorm = 0.5
	local mood = COL_UNKNOWN
	if tierPrice > 0 then
		tNorm = normalizedInBand(tierPrice, tierMin, tierMax)
		mood = moodFromNormalizedT(tNorm)
	end

	local pv = findPriceValueLabel(row)
	if pv then
		if tierPrice > 0 then
			pv.Text = string.format("$%d/bbl", tierPrice)
			pv.TextColor3 = mood
		else
			pv.Text = "—"
			pv.TextColor3 = COL_UNKNOWN
		end
	end

	local trackHost = row:FindFirstChild("TrackHost")
	if not (trackHost and trackHost:IsA("GuiObject")) then
		return
	end
	clearLegacyHistoryTicks(trackHost)

	local marker = trackHost:FindFirstChild("Marker")
	if marker and marker:IsA("GuiObject") then
		marker.AnchorPoint = Vector2.new(0.5, 0.5)
		local xScale = if tierPrice > 0 then math.clamp(tNorm, 0.02, 0.98) else 0.5
		marker.Position = UDim2.new(xScale, 0, 0.5, 0)
		if marker:IsA("Frame") then
			marker.BackgroundColor3 = mood
		end
		local mstk = marker:FindFirstChildOfClass("UIStroke")
		if mstk then
			mstk.Color = mood:Lerp(Color3.new(0, 0, 0), 0.28)
		end
	end

	local trackFill = trackHost:FindFirstChild("TrackFill")
	if trackFill and trackFill:IsA("GuiObject") then
		local fstk = trackFill:FindFirstChildOfClass("UIStroke")
		if fstk then
			fstk.Color = mood
			fstk.Transparency = if tierPrice > 0 then 0.12 else 0.45
		end
	end
end

local function refreshInfoPanel(playerGui: PlayerGui, snapshot: MarketSnapshot)
	local gui = playerGui:FindFirstChild("OilPriceInfoPanelGui", true)
	if not (gui and gui:IsA("ScreenGui")) then
		return
	end
	local prices = snapshot.prices
	if typeof(prices) ~= "table" then
		prices = {}
	end
	for _, entry in ipairs(TIER_ROWS) do
		local row = gui:FindFirstChild(entry.row, true)
		if row and row:IsA("Instance") then
			wireTierRow(row, entry.tier, snapshot, prices :: { [string]: number })
		end
	end
end

function OilPriceHud.refresh(playerGui: PlayerGui, snapshot: MarketSnapshot)
	local canvas = findHudCanvas(playerGui)
	if not canvas then
		return
	end
	local priceText, indicator, oilPriceButton = findOilPriceStrip(canvas)
	local panel = findOilPricePanel(canvas)
	local prices = snapshot.prices
	if typeof(prices) ~= "table" then
		prices = {}
	end
	local base = math.max(0, math.floor(tonumber(snapshot.basePrice) or 0))
	local strait = tostring(snapshot.straitState or "Open")

	local prevBase = lastSnapshotBase
	local prevStrait = lastSnapshotStrait

	if priceText then
		priceText.Text = formatStripSpotLine(base)
	end
	local gmin = tonumber(snapshot.globalBaseMin) or 8
	local gmax = tonumber(snapshot.globalBaseMax) or 80
	if oilPriceButton then
		-- Background mood (strait-status palette: green / orange / red)
		-- lands directly on the `OilPriceButton` itself — gated on price
		-- quality vs the **global** band, same band-rule as the per-row
		-- Marker / PriceValue tints below — one read for the player
		-- ("market is bad / average / good") regardless of which panel
		-- they look at.
		applyMoodBackground(oilPriceButton, moodBackgroundColorFromBaseGlobal(base, gmin, gmax))
	end
	if indicator then
		-- Direction icon (up / down arrow) is gated on the price **delta**
		-- vs the previous snapshot. Equal-price tick keeps the last-shown
		-- arrow so a quiet market doesn't visually flicker. Old behavior
		-- here tinted the indicator dot to mood color — that role moved
		-- to `MoodBackground` above so the indicator is now purely a
		-- "which way did the market just move" cue.
		applyPriceArrow(indicator, base, prevBase)
	end
	refreshInfoPanel(playerGui, snapshot)

	if panel then
		local straitChanged = prevStrait ~= nil and strait ~= prevStrait
		local baseChanged = prevBase ~= nil and base ~= prevBase
		local suppressJitter = (os.clock() - lastStraitPulseAt) < 1.95
		if straitChanged then
			playOilPricePanelStraitPulse(panel)
		elseif baseChanged and not suppressJitter then
			playOilPricePanelJitter(panel)
		end
	end

	lastSnapshotBase = base
	lastSnapshotStrait = strait
end

return OilPriceHud
