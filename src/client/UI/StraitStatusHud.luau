--!strict
-- Strait HUD pill: maps engine strait state → Open / Restricted / Closed (color + copy on `StraitStatusButton`).
-- Engine states come from `StraitConfig` / `marketState.straitState` (same strings as server snapshot `state`).
-- Studio often paints the pill on child `HudBtnVisual` (opaque) while the `GuiButton` shell stays dark — theme both.
-- Runtime: per-glyph `UIStroke` under `StraitText`. **Restricted** = softer rim breathe; **Closed** = yellow/black caution-tape rim + stronger breathe.

export type UiBracket = "Open" | "Restricted" | "Closed"

export type RimAnimTier = "restricted" | "closed"

local RunService = game:GetService("RunService")

local StraitStatusHud = {}

local HAZARD_RIM_AURA_NAME = "StraitHazardRimAura"
local LEGACY_RIM_AURA_NAME = "StraitClosedHazardAura"

local CAUTION_YELLOW = Color3.fromRGB(255, 214, 58)
local CAUTION_BLACK = Color3.fromRGB(12, 12, 14)

local rimAnimConn: RBXScriptConnection? = nil
local rimAnimStrk: UIStroke? = nil
local rimAnimBaseThickness = 2.0
local rimAnimBaseTransparency = 0.0
local rimAnimTier: RimAnimTier? = nil
local rimUsingRuntimeAura = false

local TEXT_STROKE_NAME = "StraitTextGlyphStroke"
local DEFAULT_TEXT_STROKE_THICKNESS = 1.75
local DEFAULT_TEXT_STROKE_TRANSPARENCY = 0.28

local SHIMMER_GRADIENT_NAME = "StraitStateShimmerGrad"

local function engineStateToBracket(engine: string): UiBracket
	if engine == "Open" then
		return "Open"
	elseif engine == "Restricted" then
		return "Restricted"
	elseif engine == "Closed" then
		return "Closed"
	end
	if engine == "Tense" or engine == "Dangerous" then
		return "Restricted"
	end
	if engine == "Crisis" then
		return "Closed"
	end
	return "Open"
end

-- Brighter tier fills; **Closed** fill is deep red (not pink). Rim colors are static reference when not animating Open.
local THEME: {
	[UiBracket]: {
		fill: Color3,
		stroke: Color3,
		text: Color3,
		line: string,
	},
} = {
	Open = {
		fill = Color3.fromRGB(72, 168, 118),
		stroke = Color3.fromRGB(198, 255, 215),
		text = Color3.fromRGB(255, 255, 255),
		line = "Strait: Open",
	},
	Restricted = {
		fill = Color3.fromRGB(218, 118, 38),
		stroke = Color3.fromRGB(255, 214, 150),
		text = Color3.fromRGB(255, 255, 255),
		line = "Strait: Restricted",
	},
	Closed = {
		fill = Color3.fromRGB(176, 18, 32),
		stroke = Color3.fromRGB(255, 200, 200),
		text = Color3.fromRGB(255, 255, 255),
		line = "Strait: Closed",
	},
}

local function stripLegacySheen(host: Instance)
	local g = host:FindFirstChild(SHIMMER_GRADIENT_NAME)
	if g then
		g:Destroy()
	end
end

local function destroyHazardRimAuraUnder(inst: Instance?)
	if not inst then
		return
	end
	local a = inst:FindFirstChild(HAZARD_RIM_AURA_NAME)
	if a then
		a:Destroy()
	end
	local legacy = inst:FindFirstChild(LEGACY_RIM_AURA_NAME)
	if legacy then
		legacy:Destroy()
	end
end

local function stopRimAnim(btn: GuiButton?)
	if rimAnimConn then
		rimAnimConn:Disconnect()
		rimAnimConn = nil
	end
	if rimAnimStrk and rimAnimStrk.Parent then
		if rimUsingRuntimeAura then
			rimAnimStrk:Destroy()
		else
			rimAnimStrk.Thickness = rimAnimBaseThickness
			rimAnimStrk.Transparency = rimAnimBaseTransparency
		end
	end
	rimAnimStrk = nil
	rimAnimTier = nil
	rimUsingRuntimeAura = false
	if btn then
		local vis = btn:FindFirstChild("HudBtnVisual")
		destroyHazardRimAuraUnder(vis)
		destroyHazardRimAuraUnder(btn)
	end
end

local function ensureHazardRim(btn: GuiButton, vis: Instance?, rimColor: Color3): UIStroke?
	local strk: UIStroke? = nil
	if vis then
		local s = vis:FindFirstChildOfClass("UIStroke")
		if s and s:IsA("UIStroke") then
			strk = s
		end
	end
	if not strk then
		for _, ch in ipairs(btn:GetChildren()) do
			if ch:IsA("UIStroke") then
				strk = ch
				break
			end
		end
	end
	if strk then
		return strk
	end
	local host: Instance = if vis then vis else btn
	local aura = Instance.new("UIStroke")
	aura.Name = HAZARD_RIM_AURA_NAME
	aura.Parent = host
	aura.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	aura.LineJoinMode = Enum.LineJoinMode.Round
	aura.Thickness = 2.2
	aura.Color = rimColor
	aura.Transparency = 0.08
	return aura
end

local function startRimAnim(strk: UIStroke?, rimColor: Color3, tier: RimAnimTier)
	if not strk then
		return
	end
	if rimAnimConn and rimAnimStrk == strk and rimAnimTier == tier then
		return
	end
	stopRimAnim(nil)
	rimAnimStrk = strk
	rimAnimTier = tier
	rimUsingRuntimeAura = strk.Name == HAZARD_RIM_AURA_NAME or strk.Name == LEGACY_RIM_AURA_NAME
	rimAnimBaseThickness = strk.Thickness
	rimAnimBaseTransparency = strk.Transparency
	if tier == "closed" then
		strk.Color = CAUTION_YELLOW
	else
		strk.Color = rimColor
	end
	local t0 = os.clock()
	rimAnimConn = RunService.Heartbeat:Connect(function()
		if not strk.Parent then
			if rimAnimConn then
				rimAnimConn:Disconnect()
				rimAnimConn = nil
			end
			rimAnimStrk = nil
			rimAnimTier = nil
			return
		end
		local w = os.clock() - t0
		if tier == "closed" then
			-- Caution tape: hard yellow / black flip + strong rim breathe
			local tape = math.sin(w * 8.6)
			strk.Color = (if tape >= 0 then CAUTION_YELLOW else CAUTION_BLACK) :: Color3
			local breathe = 0.5 + 0.5 * math.sin(w * 5.05)
			strk.Thickness = rimAnimBaseThickness + breathe * 2.55
			strk.Transparency = math.clamp(rimAnimBaseTransparency + (1 - breathe) * 0.11, 0, 0.42)
		else
			-- Restricted: same idea, gentler — slower breathe, smaller thickness swing, umber↔amber (not harsh tape)
			local breathe = 0.5 + 0.5 * math.sin(w * 2.12)
			local band = 0.5 + 0.5 * math.sin(w * 3.05)
			local dark = Color3.fromRGB(42, 36, 32)
			local warm = Color3.fromRGB(255, 186, 72)
			strk.Color = dark:Lerp(warm, band)
			strk.Thickness = rimAnimBaseThickness + breathe * 1.08
			strk.Transparency = math.clamp(rimAnimBaseTransparency + (1 - breathe) * 0.055, 0, 0.34)
		end
	end)
end

local function findStraitStatusButton(playerGui: PlayerGui): GuiButton?
	local hud = playerGui:FindFirstChild("HUD")
	if not (hud and hud:IsA("ScreenGui")) then
		return nil
	end
	local canvas = hud:FindFirstChild("Canvas")
	local top = canvas and canvas:FindFirstChild("TopRow")
	if top then
		local b = top:FindFirstChild("StraitStatusButton", true)
		if b and b:IsA("GuiButton") then
			return b
		end
	end
	local b = hud:FindFirstChild("StraitStatusButton", true)
	if b and b:IsA("GuiButton") then
		return b
	end
	return nil
end

local function applyPillTheme(
	btn: GuiButton,
	fill: Color3,
	strokeColor: Color3,
	fillTransparency: number,
	freezeRimColor: boolean?
): UIStroke?
	btn.BackgroundColor3 = fill
	btn.BackgroundTransparency = fillTransparency

	local vis = btn:FindFirstChild("HudBtnVisual")
	if vis and vis:IsA("GuiObject") then
		stripLegacySheen(vis)
		vis.BackgroundColor3 = fill
		vis.BackgroundTransparency = fillTransparency
		if vis:IsA("ImageLabel") then
			(vis :: ImageLabel).ImageColor3 = fill
		elseif vis:IsA("ImageButton") then
			(vis :: ImageButton).ImageColor3 = fill
		end
	end
	stripLegacySheen(btn)

	local strk: UIStroke? = nil
	if vis then
		strk = vis:FindFirstChildOfClass("UIStroke")
	end
	if not strk then
		for _, ch in ipairs(btn:GetChildren()) do
			if ch:IsA("UIStroke") then
				strk = ch
				break
			end
		end
	end
	if strk and not freezeRimColor then
		strk.Color = strokeColor
	end
	return strk
end

local function ensureStraitTextStroke(label: TextLabel, tierFill: Color3): UIStroke?
	local outline = tierFill:Lerp(Color3.new(0, 0, 0), 0.72)
	local existing = label:FindFirstChildOfClass("UIStroke")
	if existing and existing:IsA("UIStroke") then
		existing.Color = outline
		return existing
	end
	local ours = label:FindFirstChild(TEXT_STROKE_NAME)
	if ours and ours:IsA("UIStroke") then
		ours.Color = outline
		return ours
	end
	local s = Instance.new("UIStroke")
	s.Name = TEXT_STROKE_NAME
	s.Parent = label
	s.Thickness = DEFAULT_TEXT_STROKE_THICKNESS
	s.Transparency = DEFAULT_TEXT_STROKE_TRANSPARENCY
	s.LineJoinMode = Enum.LineJoinMode.Round
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	s.Color = outline
	return s
end

function StraitStatusHud.refresh(playerGui: PlayerGui, engineState: string)
	local btn = findStraitStatusButton(playerGui)
	if not btn then
		stopRimAnim(nil)
		return
	end
	local bracket = engineStateToBracket(engineState)
	local t = THEME[bracket]

	if bracket == "Open" then
		stopRimAnim(btn)
	end

	local vis = btn:FindFirstChild("HudBtnVisual")
	local freezeRim = bracket == "Closed" or bracket == "Restricted"
	local rimStroke = applyPillTheme(btn, t.fill, t.stroke, 0.02, freezeRim)

	local label = btn:FindFirstChild("StraitText", true)
	if label and label:IsA("TextLabel") then
		label.Text = t.line
		label.TextColor3 = t.text
		ensureStraitTextStroke(label, t.fill)
	elseif btn:IsA("TextButton") then
		btn.Text = t.line
		btn.TextColor3 = t.text
	end

	if bracket == "Closed" then
		local rim = rimStroke or ensureHazardRim(btn, vis, t.stroke)
		startRimAnim(rim, t.stroke, "closed")
	elseif bracket == "Restricted" then
		local rim = rimStroke or ensureHazardRim(btn, vis, t.stroke)
		startRimAnim(rim, t.stroke, "restricted")
	else
		destroyHazardRimAuraUnder(vis)
		destroyHazardRimAuraUnder(btn)
	end
end

return StraitStatusHud
