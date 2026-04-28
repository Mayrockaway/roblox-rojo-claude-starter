--[[
	Run once via Roblox Studio MCP `execute_luau` with StarterGui open.
	Bakes unified Robux buy chrome into `StarterGui.RobuxShop` (purple fill,
	left Robux icon, UICorner, UIStroke, horizontal layout + left-aligned price text).
	Update `ROBUX_ICON_ASSET` if your Creator asset replaces the glyph.
]]
local ROBUX_BTN_FILL = Color3.fromRGB(115, 62, 205)
local ROBUX_BTN_STROKE = Color3.fromRGB(200, 165, 255)
local ROBUX_BTN_TEXT = Color3.fromRGB(250, 246, 255)
local ROBUX_BTN_PRICE_MAX_TEXT = 17
local ROBUX_ICON_ASSET = "rbxassetid://10845616801"

local CHROME_PAD_NAME = "RobuxShopChromePadding"
local CHROME_LAYOUT_NAME = "RobuxShopChromeLayout"
local CHROME_ICON_NAME = "RobuxIcon"
local CHROME_STROKE_NAME = "RobuxShopChromeStroke"

local StarterGui = game:GetService("StarterGui")
local shop = StarterGui:FindFirstChild("RobuxShop")
if not shop or not shop:IsA("ScreenGui") then
	return "RobuxShop ScreenGui missing under StarterGui"
end

local function findBuyLabel(buy)
	for _, child in ipairs(buy:GetChildren()) do
		if child:IsA("TextLabel") then
			return child
		end
	end
	for _, d in ipairs(buy:GetDescendants()) do
		if d:IsA("TextLabel") then
			return d
		end
	end
	return nil
end

local function applyChrome(buy)
	for _, ch in ipairs(buy:GetChildren()) do
		if ch:IsA("UICorner") and ch.Name ~= "RobuxShopChromeCorner" then
			ch:Destroy()
		end
	end
	buy.Image = ""
	buy.ImageTransparency = 1
	buy.BorderSizePixel = 0
	buy.BackgroundColor3 = ROBUX_BTN_FILL

	local pad = buy:FindFirstChild(CHROME_PAD_NAME)
	if not (pad and pad:IsA("UIPadding")) then
		if pad then
			pad:Destroy()
		end
		pad = Instance.new("UIPadding")
		pad.Name = CHROME_PAD_NAME
		pad.Parent = buy
	end
	pad.PaddingLeft = UDim.new(0.035, 2)
	pad.PaddingRight = UDim.new(0.035, 2)
	pad.PaddingTop = UDim.new(0.08, 0)
	pad.PaddingBottom = UDim.new(0.08, 0)

	local lay = buy:FindFirstChild(CHROME_LAYOUT_NAME)
	if not (lay and lay:IsA("UIListLayout")) then
		if lay then
			lay:Destroy()
		end
		lay = Instance.new("UIListLayout")
		lay.Name = CHROME_LAYOUT_NAME
		lay.Parent = buy
	end
	lay.FillDirection = Enum.FillDirection.Horizontal
	lay.VerticalAlignment = Enum.VerticalAlignment.Center
	lay.HorizontalAlignment = Enum.HorizontalAlignment.Left
	lay.SortOrder = Enum.SortOrder.LayoutOrder
	lay.Padding = UDim.new(0.024, 0)

	local stroke = buy:FindFirstChild(CHROME_STROKE_NAME)
	if not (stroke and stroke:IsA("UIStroke")) then
		if stroke then
			stroke:Destroy()
		end
		stroke = Instance.new("UIStroke")
		stroke.Name = CHROME_STROKE_NAME
		stroke.Parent = buy
	end
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Thickness = math.max(1, math.ceil(buy.AbsoluteSize.Y > 2 and buy.AbsoluteSize.Y or 28) * 0.03)
	stroke.Color = ROBUX_BTN_STROKE
	stroke.Transparency = 0.12

	local icon = buy:FindFirstChild(CHROME_ICON_NAME)
	if not (icon and icon:IsA("ImageLabel")) then
		if icon then
			icon:Destroy()
		end
		icon = Instance.new("ImageLabel")
		icon.Name = CHROME_ICON_NAME
		icon.BackgroundTransparency = 1
		icon.Parent = buy
	end
	icon.LayoutOrder = 1
	icon.Image = ROBUX_ICON_ASSET
	icon.ScaleType = Enum.ScaleType.Fit
	icon.ImageColor3 = ROBUX_BTN_TEXT
	icon.Visible = true
	icon.Size = UDim2.new(0.12, 0, 0.62, 0)
	if icon:FindFirstChildOfClass("UIAspectRatioConstraint") == nil then
		local ar = Instance.new("UIAspectRatioConstraint")
		ar.AspectRatio = 1
		ar.AspectType = Enum.AspectType.FitWithinMaxSize
		ar.Parent = icon
	end

	local label = findBuyLabel(buy)
	if label then
		label.LayoutOrder = 2
		label.BackgroundTransparency = 1
		label.TextColor3 = ROBUX_BTN_TEXT
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextYAlignment = Enum.TextYAlignment.Center
		label.TextScaled = true
		label.TextWrapped = false
		label.Size = UDim2.new(0.78, 0, 0.86, 0)
		local utc = label:FindFirstChildOfClass("UITextSizeConstraint")
		if not utc then
			utc = Instance.new("UITextSizeConstraint")
			utc.Parent = label
		end
		utc.MinTextSize = 7
		utc.MaxTextSize = ROBUX_BTN_PRICE_MAX_TEXT
	end

	local corner = buy:FindFirstChild("RobuxShopChromeCorner")
	if not (corner and corner:IsA("UICorner")) then
		if corner then
			corner:Destroy()
		end
		corner = Instance.new("UICorner")
		corner.Name = "RobuxShopChromeCorner"
		corner.Parent = buy
	end
	corner.CornerRadius = UDim.new(0.22, 0)
end

local count = 0
for _, d in ipairs(shop:GetDescendants()) do
	if d:IsA("ImageButton") and (d.Name == "Buy" or d.Name == "EquipBest") then
		local ok, err = pcall(applyChrome, d)
		if ok then
			count += 1
		else
			warn("Robux chrome failed for ", d:GetFullName(), err)
		end
	end
end

return string.format("RobuxShop: normalized chrome on %d buy buttons — Save Studio to persist.", count)
