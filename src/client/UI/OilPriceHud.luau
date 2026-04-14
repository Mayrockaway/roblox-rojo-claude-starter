--!strict
-- Top HUD **`OilPricePanel`**: spot **`basePrice`** + strip **`PriceIndicator`** mood vs **global** spot band (**`globalBaseMin`–`globalBaseMax`**) from `PricingConfig` (all strait bands combined).
-- **`OilPriceInfoPanelGui`**: each row’s **`Marker`** + **`PriceValue`** use the same **global** band × tier multiplier — “all possible” tier $/bbl for any strait, not the current strait only.
-- Runtime: **`Text`**, **`TextColor3`**, **`Position`**, **`AnchorPoint`**, **`BackgroundColor3`**, **`UIStroke.Color`**; clears legacy **`_OilPriceHistoryTicks`** if present (see `ui-architecture` §6).

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
	{ row = "CrudeRow", tier = "HeavyCrude" },
	{ row = "LightSweetRow", tier = "LightSweet" },
	{ row = "PremiumRow", tier = "PremiumRefined" },
}

local DEFAULT_TYPE_MULS: { [string]: number } = {
	HeavyCrude = 0.8,
	LightSweet = 1.4,
	PremiumRefined = 2.0,
}

local COL_GOOD = Color3.fromRGB(72, 175, 98)
local COL_MID = Color3.fromRGB(224, 188, 72)
local COL_BAD = Color3.fromRGB(205, 72, 72)
local COL_UNKNOWN = Color3.fromRGB(150, 150, 155)

local LEGACY_HISTORY_FOLDER = "_OilPriceHistoryTicks"

local OilPriceHud = {}

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

local function applyPriceIndicatorTint(indicator: GuiObject, color: Color3)
	if indicator:IsA("ImageLabel") then
		indicator.ImageColor3 = color
		return
	elseif indicator:IsA("ImageButton") then
		indicator.ImageColor3 = color
		return
	end
	local img = indicator:FindFirstChildWhichIsA("ImageLabel", true)
	if img then
		img.ImageColor3 = color
	end
	if indicator:IsA("Frame") then
		indicator.BackgroundColor3 = color
	elseif indicator:IsA("TextButton") then
		indicator.BackgroundColor3 = color
	end
end

local function findOilPriceStrip(canvas: Frame): (TextLabel?, GuiObject?)
	local topRow = canvas:FindFirstChild("TopRow")
	local panel = topRow and topRow:FindFirstChild("OilPricePanel")
	local row = panel and panel:FindFirstChild("Row")
	if not (row and row:IsA("Instance")) then
		return nil, nil
	end
	local btn = row:FindFirstChild("OilPriceButton")
	local priceText: TextLabel? = nil
	if btn and btn:IsA("GuiButton") then
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
	return priceText, indObj
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
	local priceText, indicator = findOilPriceStrip(canvas)
	local prices = snapshot.prices
	if typeof(prices) ~= "table" then
		prices = {}
	end
	local base = math.max(0, math.floor(tonumber(snapshot.basePrice) or 0))
	if priceText then
		priceText.Text = formatStripSpotLine(base)
	end
	local gmin = tonumber(snapshot.globalBaseMin) or 8
	local gmax = tonumber(snapshot.globalBaseMax) or 80
	local mood = moodColorFromBaseGlobal(base, gmin, gmax)
	if indicator then
		applyPriceIndicatorTint(indicator, mood)
	end
	refreshInfoPanel(playerGui, snapshot)
end

return OilPriceHud
