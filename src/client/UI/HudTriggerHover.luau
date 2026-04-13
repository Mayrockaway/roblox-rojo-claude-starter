--!strict
-- Runtime feedback on HUD modal triggers: UIScale lift + optional `HudBtnVisual` stroke emphasis.
-- `ImageButton`: slight darken/restore on `ImageColor3` (same tween as scale/stroke).
-- Tweens only instances we add or stroke thickness; no authored `Position`/`Size` changes.

local TweenService = game:GetService("TweenService")

local SCALE_CHILD = "HudRouterHoverScale"
local HOVER_SCALE = 1.06
local REST_SCALE = 1
local TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local IMAGE_HOVER_LERP = 0.14 -- toward black = darken on hover

local HudTriggerHover = {}

function HudTriggerHover.attach(btn: GuiButton)
	if btn:GetAttribute("HudTriggerHoverBound") == true then
		return
	end
	btn:SetAttribute("HudTriggerHoverBound", true)

	local sc = btn:FindFirstChild(SCALE_CHILD)
	if not sc or not sc:IsA("UIScale") then
		if sc then
			sc:Destroy()
		end
		sc = Instance.new("UIScale")
		sc.Name = SCALE_CHILD
		sc.Scale = REST_SCALE
		sc.Parent = btn
	end

	-- Left-stack shop buttons: stroke on `HudBtnVisual`. Top-row pills: often a direct-child `UIStroke`.
	local strk: UIStroke? = nil
	local vis = btn:FindFirstChild("HudBtnVisual")
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
	local baseThickness = if strk then strk.Thickness else nil
	local hoverThickness = if strk and baseThickness then math.min(baseThickness * 1.4, baseThickness + 2) else nil

	local baseImageColor: Color3? = nil
	local hoverImageColor: Color3? = nil
	if btn:IsA("ImageButton") then
		local ib = btn :: ImageButton
		baseImageColor = ib.ImageColor3
		hoverImageColor = baseImageColor:Lerp(Color3.new(0, 0, 0), IMAGE_HOVER_LERP)
	end

	local function tweenScale(s: number)
		TweenService:Create(sc, TWEEN, { Scale = s }):Play()
	end

	btn.MouseEnter:Connect(function()
		tweenScale(HOVER_SCALE)
		if strk and hoverThickness then
			TweenService:Create(strk, TWEEN, { Thickness = hoverThickness }):Play()
		end
		if btn:IsA("ImageButton") and baseImageColor and hoverImageColor then
			TweenService:Create(btn :: ImageButton, TWEEN, { ImageColor3 = hoverImageColor }):Play()
		end
	end)

	btn.MouseLeave:Connect(function()
		tweenScale(REST_SCALE)
		if strk and baseThickness then
			TweenService:Create(strk, TWEEN, { Thickness = baseThickness }):Play()
		end
		if btn:IsA("ImageButton") and baseImageColor then
			TweenService:Create(btn :: ImageButton, TWEEN, { ImageColor3 = baseImageColor }):Play()
		end
	end)
end

return HudTriggerHover
