-- Authoring helper: creates `StarterGui.HUD.Canvas.EquipmentHotbar` + `SlotStrip` + `SlotTemplate`
-- if missing. Run via Roblox Studio MCP `execute_luau` (or Command Bar) while editing the place.
-- Then **Save** and align [docs/features/oil-gameplay-hud/CANONICAL_STUDIO_LAYOUT.md](../docs/features/oil-gameplay-hud/CANONICAL_STUDIO_LAYOUT.md) if you tune numbers.

local StarterGui = game:GetService("StarterGui")

local hud = StarterGui:FindFirstChild("HUD")
if not (hud and hud:IsA("ScreenGui")) then
	return "HUD ScreenGui missing under StarterGui"
end
local canvas = hud:FindFirstChild("Canvas")
if not (canvas and canvas:IsA("Frame")) then
	canvas = hud:FindFirstChild("Canvas", true)
end
if not (canvas and canvas:IsA("Frame")) then
	return "HUD.Canvas Frame missing (direct or nested)"
end
if canvas:FindFirstChild("EquipmentHotbar", true) then
	return "EquipmentHotbar already exists under Canvas"
end

local hotbar = Instance.new("Frame")
hotbar.Name = "EquipmentHotbar"
-- Slight tint so the strip is visible in Studio **Edit** mode (slots still only clone in **Play**).
hotbar.BackgroundColor3 = Color3.fromRGB(25, 28, 35)
hotbar.BackgroundTransparency = 0.92
hotbar.AnchorPoint = Vector2.new(0.5, 1)
hotbar.Position = UDim2.fromScale(0.5, 1)
hotbar.Size = UDim2.fromScale(0.92, 0.1)
hotbar.ZIndex = 25
hotbar.Parent = canvas

local strip = Instance.new("Frame")
strip.Name = "SlotStrip"
strip.BackgroundTransparency = 1
strip.Size = UDim2.fromScale(1, 1)
strip.Parent = hotbar

local list = Instance.new("UIListLayout")
list.FillDirection = Enum.FillDirection.Horizontal
list.HorizontalAlignment = Enum.HorizontalAlignment.Center
list.VerticalAlignment = Enum.VerticalAlignment.Center
list.Padding = UDim.new(0.008, 0)
list.Parent = strip

local tpl = Instance.new("Frame")
tpl.Name = "SlotTemplate"
tpl.Visible = false
tpl.BackgroundColor3 = Color3.fromRGB(40, 40, 45)
tpl.BackgroundTransparency = 0.25
tpl.BorderSizePixel = 0
-- Pixel-first size: horizontal UIListLayout often gives **0 width** to scale-only slot widths.
tpl.Size = UDim2.fromOffset(56, 56)

local aspect = Instance.new("UIAspectRatioConstraint")
aspect.AspectType = Enum.AspectType.FitWithinMaxSize
aspect.AspectRatio = 1
aspect.DominantAxis = Enum.DominantAxis.Height
aspect.Parent = tpl

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0.15, 0)
corner.Parent = tpl

local stroke = Instance.new("UIStroke")
stroke.Name = "EquipStroke"
stroke.Enabled = false
stroke.Thickness = 2
stroke.Color = Color3.fromRGB(255, 220, 120)
stroke.Parent = tpl

local icon = Instance.new("ImageLabel")
icon.Name = "Icon"
icon.BackgroundTransparency = 1
icon.Size = UDim2.fromScale(1, 1)
icon.Position = UDim2.fromScale(0.5, 0.5)
icon.AnchorPoint = Vector2.new(0.5, 0.5)
icon.ScaleType = Enum.ScaleType.Fit
icon.Parent = tpl

local hotkey = Instance.new("TextLabel")
hotkey.Name = "HotkeyLabel"
hotkey.BackgroundTransparency = 1
hotkey.Size = UDim2.fromScale(0.35, 0.28)
hotkey.Position = UDim2.fromScale(0.08, 0.06)
hotkey.AnchorPoint = Vector2.new(0, 0)
hotkey.Font = Enum.Font.GothamBold
hotkey.TextColor3 = Color3.new(1, 1, 1)
hotkey.TextScaled = true
hotkey.Text = ""
hotkey.Parent = tpl
local htc = Instance.new("UITextSizeConstraint")
htc.MaxTextSize = 18
-- MinTextSize 1 so HotkeyLabel never truncates on small mobile slots; TextScaled
-- collapses tiny text gracefully even when the slot is < 30px wide.
htc.MinTextSize = 1
htc.Parent = hotkey

local badge = Instance.new("TextLabel")
badge.Name = "StackBadge"
badge.Visible = false
badge.BackgroundTransparency = 0.3
badge.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
badge.Size = UDim2.fromScale(0.42, 0.28)
badge.Position = UDim2.fromScale(0.92, 0.08)
badge.AnchorPoint = Vector2.new(1, 0)
badge.Font = Enum.Font.GothamBold
badge.TextColor3 = Color3.new(1, 1, 1)
badge.TextScaled = true
badge.Text = ""
badge.Parent = tpl
local btc = Instance.new("UITextSizeConstraint")
btc.MaxTextSize = 18
-- MinTextSize 1 so StackBadge stack counts (e.g. "x12") never truncate on
-- mobile slots; TextScaled handles the shrink.
btc.MinTextSize = 1
btc.Parent = badge

local hit = Instance.new("ImageButton")
hit.Name = "Hit"
hit.AutoButtonColor = false
hit.BackgroundTransparency = 1
hit.Size = UDim2.fromScale(1, 1)
hit.ZIndex = 2
hit.Parent = tpl

tpl.Parent = hotbar

return "Created EquipmentHotbar as a **direct** child of HUD.Canvas (bottom-centered). Save the place. If an older bar was nested under LeftStack, delete it or reparent that frame to Canvas."
