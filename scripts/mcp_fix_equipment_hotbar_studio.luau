-- Run via Studio MCP `execute_luau` (full script body). Normalizes StarterGui.HUD.Canvas equipment hotbar:
-- - Ensures **one** `EquipmentHotbar` as **direct** child of `HUD.Canvas`
-- - Reparents nested bars; removes duplicate nested frames
-- - Ensures `SlotStrip` + `SlotTemplate` + `UIListLayout` (center) + template innards
-- Then **Save** the place.

local StarterGui = game:GetService("StarterGui")
local lines = {}

local function log(msg)
	table.insert(lines, msg)
end

local hud = StarterGui:FindFirstChild("HUD")
if not (hud and hud:IsA("ScreenGui")) then
	return "ERROR: StarterGui.HUD (ScreenGui) missing."
end

local canvas = hud:FindFirstChild("Canvas")
if not (canvas and canvas:IsA("Frame")) then
	canvas = hud:FindFirstChild("Canvas", true)
end
if not (canvas and canvas:IsA("Frame")) then
	return "ERROR: HUD.Canvas (Frame) missing."
end
log("Using canvas: " .. canvas:GetFullName())

local function hasCore(hb)
	return hb:FindFirstChild("SlotStrip") ~= nil and hb:FindFirstChild("SlotTemplate") ~= nil
end

local direct = nil
for _, ch in ipairs(canvas:GetChildren()) do
	if ch.Name == "EquipmentHotbar" and ch:IsA("Frame") then
		direct = ch
		break
	end
end

local nestedBars = {}
for _, d in ipairs(hud:GetDescendants()) do
	if d.Name == "EquipmentHotbar" and d:IsA("Frame") and d.Parent ~= canvas then
		table.insert(nestedBars, d)
	end
end

local bar
if direct then
	bar = direct
	log("OK: EquipmentHotbar is already a direct child of Canvas.")
	for _, nb in ipairs(nestedBars) do
		if nb ~= bar then
			nb:Destroy()
			log("Removed duplicate nested EquipmentHotbar (was under " .. tostring(nb.Parent and nb.Parent.Name) .. ").")
		end
	end
elseif #nestedBars > 0 then
	local keeper = nil
	for _, nb in ipairs(nestedBars) do
		if hasCore(nb) then
			keeper = nb
			break
		end
	end
	if not keeper then
		keeper = nestedBars[1]
	end
	local oldPath = keeper.Parent and keeper.Parent:GetFullName() or "?"
	keeper.Parent = canvas
	bar = keeper
	log("FIXED: Reparented EquipmentHotbar from " .. oldPath .. " → " .. bar:GetFullName())
	for _, nb in ipairs(nestedBars) do
		if nb ~= bar and nb.Parent then
			nb:Destroy()
			log("Removed extra nested EquipmentHotbar duplicate.")
		end
	end
else
	return "ERROR: No EquipmentHotbar under HUD. Run scripts/mcp_author_equipment_hotbar.luau once, then re-run this fix.\n" .. table.concat(lines, "\n")
end

-- Position / size / anchor are intentionally NOT reset here. The hotbar
-- frame's exact placement depends on `HUD.Canvas.UIPadding` (top 1.2%,
-- bottom 14% currently), so a one-size canonical value would land off-screen
-- when padding changes. Author the bar position in Studio (or in
-- `mcp_author_equipment_hotbar.luau` when first creating the bar) and let
-- this script only repair *structure* (children, list layout, slot template
-- innards) without clobbering manual placement.
bar.ZIndex = 25
bar.BackgroundColor3 = Color3.fromRGB(25, 28, 35)
bar.BackgroundTransparency = 0.92

local strip = bar:FindFirstChild("SlotStrip")
if not (strip and strip:IsA("Frame")) then
	strip = Instance.new("Frame")
	strip.Name = "SlotStrip"
	strip.BackgroundTransparency = 1
	strip.Size = UDim2.fromScale(1, 1)
	strip.Parent = bar
	log("Added missing SlotStrip.")
end
local list = strip:FindFirstChildOfClass("UIListLayout")
if not list then
	list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.Parent = strip
	log("Added UIListLayout to SlotStrip.")
end
list.HorizontalAlignment = Enum.HorizontalAlignment.Center
list.VerticalAlignment = Enum.VerticalAlignment.Center
list.Padding = UDim.new(0.008, 0)

local tpl = bar:FindFirstChild("SlotTemplate")
if not (tpl and tpl:IsA("GuiObject")) then
	local f = Instance.new("Frame")
	f.Name = "SlotTemplate"
	f.Visible = false
	f.BackgroundColor3 = Color3.fromRGB(40, 40, 45)
	f.BackgroundTransparency = 0.25
	f.BorderSizePixel = 0
	f.Size = UDim2.fromOffset(56, 56)
	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectType = Enum.AspectType.FitWithinMaxSize
	aspect.AspectRatio = 1
	aspect.DominantAxis = Enum.DominantAxis.Height
	aspect.Parent = f
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.15, 0)
	corner.Parent = f
	local stroke = Instance.new("UIStroke")
	stroke.Name = "EquipStroke"
	stroke.Enabled = false
	stroke.Thickness = 2
	stroke.Color = Color3.fromRGB(255, 220, 120)
	stroke.Parent = f
	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.Size = UDim2.fromScale(0.72, 0.72)
	icon.Position = UDim2.fromScale(0.5, 0.45)
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.ScaleType = Enum.ScaleType.Fit
	icon.Parent = f
	local hotkey = Instance.new("TextLabel")
	hotkey.Name = "HotkeyLabel"
	hotkey.BackgroundTransparency = 1
	hotkey.Size = UDim2.fromScale(0.35, 0.28)
	hotkey.Position = UDim2.fromScale(0.08, 0.06)
	hotkey.Font = Enum.Font.GothamBold
	hotkey.TextColor3 = Color3.new(1, 1, 1)
	hotkey.TextScaled = true
	hotkey.Text = ""
	hotkey.Parent = f
	local htc = Instance.new("UITextSizeConstraint")
	htc.MaxTextSize = 18
	-- MinTextSize 1 so HotkeyLabel never truncates on small mobile slots.
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
	badge.Parent = f
	local btc = Instance.new("UITextSizeConstraint")
	btc.MaxTextSize = 18
	-- MinTextSize 1 so StackBadge counts (e.g. "x12") never truncate on mobile.
	btc.MinTextSize = 1
	btc.Parent = badge
	local hit = Instance.new("ImageButton")
	hit.Name = "Hit"
	hit.AutoButtonColor = false
	hit.BackgroundTransparency = 1
	hit.Size = UDim2.fromScale(1, 1)
	hit.ZIndex = 2
	hit.Parent = f
	f.Parent = bar
	tpl = f
	log("Added missing SlotTemplate subtree.")
end

-- Re-assert canonical SlotTemplate visuals even when the subtree already exists.
-- Canonical design (per gameplay request):
--   * Icon FILLS the entire slot edge-to-edge (Size 1,1 ScaleType=Fit).
--   * NameLabel sits INSIDE the slot at the bottom as TEXT ONLY (no
--     background strip), on top of the icon. TextStroke gives legibility
--     against any icon. Slot clips descendants so text stays inside the
--     rounded corners.
--   * HotkeyLabel ("1"..) and StackBadge stay overlaid on the icon corners.
-- We only touch a small allow-list of properties so colour, corner radius,
-- stroke thickness etc. that artists tweak in Studio are preserved.
if tpl and tpl:IsA("GuiObject") then
	if tpl.Visible ~= false then
		tpl.Visible = false
		log("Normalized SlotTemplate.Visible -> false (template should never render).")
	end
	if tpl.ClipsDescendants ~= true then
		tpl.ClipsDescendants = true
		log("Normalized SlotTemplate.ClipsDescendants -> true (overlay stays inside rounded corners).")
	end
	local icon = tpl:FindFirstChild("Icon")
	if icon and icon:IsA("ImageLabel") then
		local desiredIconSize = UDim2.fromScale(1, 1)
		local desiredIconPos = UDim2.fromScale(0.5, 0.5)
		local desiredAnchor = Vector2.new(0.5, 0.5)
		if icon.Size ~= desiredIconSize then
			icon.Size = desiredIconSize
			log("Normalized Icon.Size -> (1, 1) so the icon fills the entire slot.")
		end
		if icon.Position ~= desiredIconPos then
			icon.Position = desiredIconPos
			log("Normalized Icon.Position -> (0.5, 0.5).")
		end
		if icon.AnchorPoint ~= desiredAnchor then
			icon.AnchorPoint = desiredAnchor
			log("Normalized Icon.AnchorPoint -> (0.5, 0.5).")
		end
		if icon.ScaleType ~= Enum.ScaleType.Fit then
			icon.ScaleType = Enum.ScaleType.Fit
			log("Normalized Icon.ScaleType -> Fit.")
		end
	end
	local nameLabel = tpl:FindFirstChild("NameLabel")
	if nameLabel and nameLabel:IsA("TextLabel") then
		local desiredNameAnchor = Vector2.new(0.5, 1)
		local desiredNamePos = UDim2.fromScale(0.5, 1)
		local desiredNameSize = UDim2.fromScale(1, 0.22)
		if nameLabel.AnchorPoint ~= desiredNameAnchor then
			nameLabel.AnchorPoint = desiredNameAnchor
			log("Normalized NameLabel.AnchorPoint -> (0.5, 1) so it anchors to slot bottom.")
		end
		if nameLabel.Position ~= desiredNamePos then
			nameLabel.Position = desiredNamePos
			log("Normalized NameLabel.Position -> (0.5, 1).")
		end
		if nameLabel.Size ~= desiredNameSize then
			nameLabel.Size = desiredNameSize
			log("Normalized NameLabel.Size -> (1, 0.22) text-only overlay.")
		end
		if nameLabel.Visible ~= true then
			nameLabel.Visible = true
			log("Normalized NameLabel.Visible -> true.")
		end
		if nameLabel.BackgroundTransparency ~= 1 then
			nameLabel.BackgroundTransparency = 1
			log("Normalized NameLabel.BackgroundTransparency -> 1 (text only, no strip).")
		end
		if nameLabel.ZIndex < 3 then
			nameLabel.ZIndex = 3
		end
		local nstroke = nameLabel:FindFirstChild("TextStroke")
		if not (nstroke and nstroke:IsA("UIStroke")) then
			nstroke = Instance.new("UIStroke")
			nstroke.Name = "TextStroke"
			nstroke.Parent = nameLabel
			log("Added missing NameLabel TextStroke for legibility over icon.")
		end
		nstroke.Color = Color3.new(0, 0, 0)
		nstroke.Thickness = 1.5
		nstroke.Transparency = 0
		nstroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	end
end

-- Canvas bottom safe-area clearance: gives the hotbar a gap from the viewport
-- bottom on devices where Roblox does not insert its own safe-area inset
-- (Studio mobile emulation, devices with hidden touch controls).
local canvas = bar.Parent
if canvas and canvas:IsA("GuiObject") then
	local cpad = canvas:FindFirstChildOfClass("UIPadding")
	if not cpad then
		cpad = Instance.new("UIPadding")
		cpad.Parent = canvas
		log("Added missing Canvas UIPadding for safe-area clearance.")
	end
	local desiredBottom = UDim.new(0.025, 0)
	if cpad.PaddingBottom ~= desiredBottom then
		cpad.PaddingBottom = desiredBottom
		log("Normalized Canvas UIPadding.PaddingBottom -> 2.5% (safe-area clearance).")
	end
end

log("Done. **Save** the place. EquipmentHotbar should be: " .. bar:GetFullName())
return table.concat(lines, "\n")
