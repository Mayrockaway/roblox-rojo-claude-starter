--!strict
-- Hover feedback on **`HUD` → `StraitStatusPanel` → `StraitControlCta`** (`ImageButton`).
-- Tweens **`UIScale.Scale`** only (authored `Size` / `Position` unchanged per `ui-architecture.mdc` §6).

local TweenService = game:GetService("TweenService")

local HOVER_SCALE = 1.18
local TWEEN_IN = TweenInfo.new(0.24, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local TWEEN_OUT = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local wiredTo: GuiButton? = nil
local enterConn: RBXScriptConnection? = nil
local leaveConn: RBXScriptConnection? = nil
local activeTween: Tween? = nil

local function cancelTween()
	if activeTween then
		activeTween:Cancel()
		activeTween = nil
	end
end

local function disconnectAll()
	cancelTween()
	if enterConn then
		enterConn:Disconnect()
		enterConn = nil
	end
	if leaveConn then
		leaveConn:Disconnect()
		leaveConn = nil
	end
	wiredTo = nil
end

local function findStraitControlCta(playerGui: PlayerGui): GuiButton?
	local hud = playerGui:FindFirstChild("HUD")
	if not (hud and hud:IsA("ScreenGui")) then
		return nil
	end
	local canvas = hud:FindFirstChild("Canvas")
	local top = canvas and canvas:FindFirstChild("TopRow")
	local panel = top and top:FindFirstChild("StraitStatusPanel")
	if not panel then
		return nil
	end
	local a = panel:FindFirstChild("StraitControlCta", true)
	local b = panel:FindFirstChild("StraitControlCTA", true)
	local c = a or b
	if c and c:IsA("GuiButton") then
		return c
	end
	return nil
end

local function ensureHoverScale(cta: GuiButton): UIScale
	local s = cta:FindFirstChild("StraitCtaHoverScale")
	if s and s:IsA("UIScale") then
		return s
	end
	local u = Instance.new("UIScale")
	u.Name = "StraitCtaHoverScale"
	u.Scale = 1
	u.Parent = cta
	return u
end

local StraitControlCtaHover = {}

function StraitControlCtaHover.bind(playerGui: PlayerGui): boolean
	local cta = findStraitControlCta(playerGui)
	if not cta then
		return false
	end
	if wiredTo == cta then
		return true
	end
	disconnectAll()
	wiredTo = cta
	local sc = ensureHoverScale(cta)

	local function tweenTo(scale: number, info: TweenInfo)
		cancelTween()
		activeTween = TweenService:Create(sc, info, { Scale = scale })
		activeTween:Play()
	end

	enterConn = cta.MouseEnter:Connect(function()
		tweenTo(HOVER_SCALE, TWEEN_IN)
	end)
	leaveConn = cta.MouseLeave:Connect(function()
		tweenTo(1, TWEEN_OUT)
	end)

	return true
end

return StraitControlCtaHover
