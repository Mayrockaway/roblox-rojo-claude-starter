-- Run via Roblox Studio MCP `execute_luau` (optional). Authors **`StarterGui.HUD.Canvas.ActiveManifestPanel`**
-- incidents list as **`IncidentsSection.SectionBody.IncidentsScroll`** (ScrollingFrame) + **`UIListLayout`**.
-- **`ActiveManifestController`** also creates this at runtime if missing — this script is for WYSIWYG / Save parity.
--
-- Before: `SectionBody` (Frame) with `IncidentRow_1` … `IncidentRow_3` (optional).
-- After: `SectionBody` (Frame) → `IncidentsScroll` (ScrollingFrame, fills body) → `IncidentRow_1` (+ delete extra concrete rows if desired).

local StarterGui = game:GetService("StarterGui")

local hud = StarterGui:FindFirstChild("HUD", true)
if not (hud and hud:IsA("ScreenGui")) then
	return "ERROR: StarterGui.HUD (ScreenGui) missing."
end
local canvas = hud:FindFirstChild("Canvas")
if not (canvas and canvas:IsA("Frame")) then
	return "ERROR: HUD.Canvas missing."
end
local panel = canvas:FindFirstChild("ActiveManifestPanel")
if not (panel and panel:IsA("Frame")) then
	return "ERROR: ActiveManifestPanel missing under HUD.Canvas."
end
local inc = panel:FindFirstChild("IncidentsSection")
if not (inc and inc:IsA("Frame")) then
	return "ERROR: IncidentsSection missing."
end
local body = inc:FindFirstChild("SectionBody")
if not body then
	return "ERROR: SectionBody missing."
end
if body:IsA("ScrollingFrame") then
	return "OK: SectionBody is already a ScrollingFrame — no change."
end
if not body:IsA("Frame") then
	return "ERROR: SectionBody must be Frame or ScrollingFrame."
end
local existing = body:FindFirstChild("IncidentsScroll")
if existing and existing:IsA("ScrollingFrame") then
	return "OK: IncidentsScroll already exists."
end

local scroll = Instance.new("ScrollingFrame")
scroll.Name = "IncidentsScroll"
scroll.BackgroundTransparency = 1
scroll.BorderSizePixel = 0
scroll.ScrollBarThickness = 4
scroll.ScrollBarImageTransparency = 0.35
scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
scroll.ClipsDescendants = true
scroll.ScrollingDirection = Enum.ScrollingDirection.Y
scroll.AnchorPoint = Vector2.new(0, 0)
scroll.Position = UDim2.new(0, 0, 0, 0)
scroll.Size = UDim2.new(1, 0, 1, 0)
scroll.ZIndex = body.ZIndex
scroll.Parent = body

local lay = Instance.new("UIListLayout")
lay.Name = "IncidentsListLayout"
lay.FillDirection = Enum.FillDirection.Vertical
lay.HorizontalAlignment = Enum.HorizontalAlignment.Center
lay.VerticalAlignment = Enum.VerticalAlignment.Top
lay.SortOrder = Enum.SortOrder.LayoutOrder
lay.Parent = scroll

for _, name in ipairs({ "IncidentRow_1", "IncidentRow_2", "IncidentRow_3" }) do
	local r = body:FindFirstChild(name)
	if r then
		r.Parent = scroll
	end
end

return "Created IncidentsScroll under IncidentsSection.SectionBody; reparented IncidentRow_* into it. Save the place."
