-- Run via Roblox Studio MCP `execute_luau`.
--
-- **Behavior**
-- - If **`Workspace.DocksLeaderboard.Board`** already has **`StraitLeaderboardGui`**, only **rebuilds the GUI**
--   under the SurfaceGui (keeps **Board position/CFrame**). Use this after you move the board.
-- - Otherwise creates **Folder + Board + SurfaceGui** at a default CFrame.
--
-- **Bind contract** (matches **`LeaderboardService`**, do not rename):
--   `Root` → `Mode`, `Timer`, `CrossingsCol` / `BarrelsCol` → `Row_1`…`Row_8`
--
-- Decoration not touched by service: `TitleBar`, `Header`, column `ColHeader`, dividers.

local Workspace = game:GetService("Workspace")

-- Brown-wood / brass palette (matches docks sign aesthetic)
local COL = {
	woodTop = Color3.fromRGB(74, 50, 36),
	woodBottom = Color3.fromRGB(48, 30, 20),
	woodInk = Color3.fromRGB(36, 22, 14),
	brass = Color3.fromRGB(238, 196, 110),
	brassDeep = Color3.fromRGB(190, 145, 70),
	brassBright = Color3.fromRGB(255, 230, 165),
	parchment = Color3.fromRGB(232, 218, 196),
	rowFill = Color3.fromRGB(58, 38, 26),
	rowAlt = Color3.fromRGB(64, 42, 28),
	divider = Color3.fromRGB(160, 120, 60),
}

local function ensureFolder(parent: Instance, name: string): Folder
	local f = parent:FindFirstChild(name)
	if f and f:IsA("Folder") then
		return f
	end
	local n = Instance.new("Folder")
	n.Name = name
	n.Parent = parent
	return n
end

local function styleBoardPart(board: BasePart)
	board.Material = Enum.Material.WoodPlanks
	board.Reflectance = 0.02
	board.Color = Color3.fromRGB(60, 38, 24)
end

local function gradientVertical(inst: GuiObject, top: Color3, bottom: Color3)
	local g = inst:FindFirstChildOfClass("UIGradient") :: UIGradient?
	if not g then
		g = Instance.new("UIGradient")
		g.Parent = inst
	end
	g.Rotation = 90
	g.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, top),
		ColorSequenceKeypoint.new(1, bottom),
	})
end

local function strokeAround(inst: GuiObject, thickness: number, color: Color3, transparency: number)
	local s = inst:FindFirstChildOfClass("UIStroke") :: UIStroke?
	if not s then
		s = Instance.new("UIStroke")
		s.Parent = inst
	end
	s.Thickness = thickness
	s.Color = color
	s.Transparency = transparency
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
end

local function corner(inst: GuiObject, radius: number)
	local c = inst:FindFirstChildOfClass("UICorner") :: UICorner?
	if not c then
		c = Instance.new("UICorner")
		c.Parent = inst
	end
	c.CornerRadius = UDim.new(0, radius)
end

local function buildLeaderboardGui(sg: SurfaceGui)
	for _, ch in ipairs(sg:GetChildren()) do
		if ch:IsA("GuiObject") then
			ch:Destroy()
		end
	end

	sg.Name = "StraitLeaderboardGui"
	sg.Face = Enum.NormalId.Front
	sg.PixelsPerStud = 56
	sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	sg.AlwaysOnTop = true
	sg.LightInfluence = 0
	sg.Brightness = 1.05

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.Size = UDim2.fromScale(1, 1)
	root.Position = UDim2.fromScale(0, 0)
	root.BackgroundColor3 = COL.woodTop
	root.BackgroundTransparency = 0
	root.BorderSizePixel = 0
	root.ClipsDescendants = true
	root.Parent = sg

	gradientVertical(root, COL.woodTop, COL.woodBottom)
	corner(root, 14)
	strokeAround(root, 5, COL.brass, 0.05)

	local rootPad = Instance.new("UIPadding")
	rootPad.PaddingTop = UDim.new(0, 14)
	rootPad.PaddingBottom = UDim.new(0, 14)
	rootPad.PaddingLeft = UDim.new(0, 18)
	rootPad.PaddingRight = UDim.new(0, 18)
	rootPad.Parent = root

	local TITLE_H = 56
	local SUB_H = 22
	local HEADER_H = 30
	local LIST_TOP = TITLE_H + SUB_H + HEADER_H + 14

	local titleBar = Instance.new("Frame")
	titleBar.Name = "TitleBar"
	titleBar.Size = UDim2.new(1, 0, 0, TITLE_H)
	titleBar.Position = UDim2.fromScale(0, 0)
	titleBar.BackgroundTransparency = 1
	titleBar.Parent = root

	local title = Instance.new("TextLabel")
	title.Name = "TitleText"
	title.Size = UDim2.fromScale(1, 1)
	title.BackgroundTransparency = 1
	title.Text = "LEADERBOARD"
	title.Font = Enum.Font.FredokaOne
	title.TextScaled = true
	title.TextColor3 = COL.brass
	title.Parent = titleBar
	title.TextStrokeTransparency = 0.35
	title.TextStrokeColor3 = COL.woodInk
	local tc = Instance.new("UITextSizeConstraint")
	tc.MinTextSize = 18
	tc.MaxTextSize = 64
	tc.Parent = title
	local tGrad = Instance.new("UIGradient")
	tGrad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, COL.brassBright),
		ColorSequenceKeypoint.new(0.55, COL.brass),
		ColorSequenceKeypoint.new(1, COL.brassDeep),
	})
	tGrad.Rotation = 90
	tGrad.Parent = title

	local mode = Instance.new("TextLabel")
	mode.Name = "Mode"
	mode.Size = UDim2.new(1, 0, 0, SUB_H)
	mode.Position = UDim2.new(0, 0, 0, TITLE_H)
	mode.BackgroundTransparency = 1
	mode.Text = "THIS SERVER"
	mode.TextColor3 = COL.parchment
	mode.TextScaled = true
	mode.Font = Enum.Font.GothamBold
	mode.TextXAlignment = Enum.TextXAlignment.Left
	mode.Parent = root

	local timer = Instance.new("TextLabel")
	timer.Name = "Timer"
	timer.Size = UDim2.new(1, 0, 0, SUB_H)
	timer.Position = UDim2.new(0, 0, 0, TITLE_H)
	timer.BackgroundTransparency = 1
	timer.Text = "—"
	timer.TextColor3 = COL.parchment
	timer.TextScaled = true
	timer.Font = Enum.Font.Gotham
	timer.TextTransparency = 0.15
	timer.TextXAlignment = Enum.TextXAlignment.Right
	timer.Parent = root

	-- Column header strip ("Player Crossings" | "Player Barrels")
	local headerBar = Instance.new("Frame")
	headerBar.Name = "Header"
	headerBar.Size = UDim2.new(1, 0, 0, HEADER_H)
	headerBar.Position = UDim2.new(0, 0, 0, TITLE_H + SUB_H + 6)
	headerBar.BackgroundTransparency = 1
	headerBar.Parent = root

	local headerRule = Instance.new("Frame")
	headerRule.Name = "HeaderRule"
	headerRule.AnchorPoint = Vector2.new(0, 1)
	headerRule.Size = UDim2.new(1, 0, 0, 2)
	headerRule.Position = UDim2.new(0, 0, 1, 0)
	headerRule.BackgroundColor3 = COL.brass
	headerRule.BackgroundTransparency = 0.25
	headerRule.BorderSizePixel = 0
	headerRule.Parent = headerBar

	local function headerCell(parent: Frame, cellName: string, leftLabel: string, rightLabel: string, xScale: number, widthScale: number)
		local cell = Instance.new("Frame")
		cell.Name = cellName
		cell.AnchorPoint = Vector2.new(0, 0)
		cell.Position = UDim2.new(xScale, 0, 0, 0)
		cell.Size = UDim2.new(widthScale, 0, 1, 0)
		cell.BackgroundTransparency = 1
		cell.Parent = parent

		local lp = Instance.new("UIPadding")
		lp.PaddingLeft = UDim.new(0, 10)
		lp.PaddingRight = UDim.new(0, 10)
		lp.Parent = cell

		local left = Instance.new("TextLabel")
		left.Name = "LeftHeader"
		left.AnchorPoint = Vector2.new(0, 0.5)
		left.Position = UDim2.new(0, 0, 0.5, 0)
		left.Size = UDim2.new(0.5, -4, 1, 0)
		left.BackgroundTransparency = 1
		left.Text = leftLabel
		left.Font = Enum.Font.GothamBold
		left.TextColor3 = COL.parchment
		left.TextScaled = true
		left.TextXAlignment = Enum.TextXAlignment.Left
		left.Parent = cell

		local right = Instance.new("TextLabel")
		right.Name = "RightHeader"
		right.AnchorPoint = Vector2.new(1, 0.5)
		right.Position = UDim2.new(1, 0, 0.5, 0)
		right.Size = UDim2.new(0.5, -4, 1, 0)
		right.BackgroundTransparency = 1
		right.Text = rightLabel
		right.Font = Enum.Font.GothamBold
		right.TextColor3 = COL.brass
		right.TextScaled = true
		right.TextXAlignment = Enum.TextXAlignment.Right
		right.Parent = cell
	end

	headerCell(headerBar, "CrossingsHeader", "Player", "Successful Crossings", 0, 0.5)
	headerCell(headerBar, "BarrelsHeader", "Player", "Barrels Shipped", 0.5, 0.5)

	-- Vertical divider between the two columns
	local divider = Instance.new("Frame")
	divider.Name = "ColDivider"
	divider.AnchorPoint = Vector2.new(0.5, 0)
	divider.Position = UDim2.new(0.5, 0, 0, TITLE_H + SUB_H + 6)
	divider.Size = UDim2.new(0, 2, 1, -(TITLE_H + SUB_H + 14))
	divider.BackgroundColor3 = COL.divider
	divider.BackgroundTransparency = 0.5
	divider.BorderSizePixel = 0
	divider.Parent = root
	local dGrad = Instance.new("UIGradient")
	dGrad.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.1, 0.45),
		NumberSequenceKeypoint.new(0.9, 0.45),
		NumberSequenceKeypoint.new(1, 1),
	})
	dGrad.Rotation = 90
	dGrad.Parent = divider

	local function makeColumn(name: string, xScale: number)
		local col = Instance.new("Frame")
		col.Name = name
		col.AnchorPoint = Vector2.new(0, 0)
		col.Position = UDim2.new(xScale, xScale == 0 and 0 or 6, 0, LIST_TOP)
		col.Size = UDim2.new(0.5, xScale == 0 and -6 or -6, 1, -(LIST_TOP + 6))
		col.BackgroundTransparency = 1
		col.BorderSizePixel = 0
		col.Parent = root

		local list = Instance.new("UIListLayout")
		list.FillDirection = Enum.FillDirection.Vertical
		list.SortOrder = Enum.SortOrder.LayoutOrder
		list.Padding = UDim.new(0, 4)
		list.HorizontalAlignment = Enum.HorizontalAlignment.Center
		list.Parent = col

		for i = 1, 8 do
			local row = Instance.new("TextLabel")
			row.Name = "Row_" .. tostring(i)
			row.LayoutOrder = i
			row.Size = UDim2.new(1, 0, 0, 26)
			row.BackgroundColor3 = (i % 2 == 1) and COL.rowFill or COL.rowAlt
			row.BackgroundTransparency = 0.15
			row.BorderSizePixel = 0
			row.Text = "—"
			row.TextColor3 = COL.parchment
			row.TextScaled = true
			row.Font = Enum.Font.GothamMedium
			row.TextXAlignment = Enum.TextXAlignment.Left
			row.Parent = col
			row.TextStrokeTransparency = 0.7
			row.TextStrokeColor3 = COL.woodInk
			local p = Instance.new("UIPadding")
			p.PaddingLeft = UDim.new(0, 8)
			p.PaddingRight = UDim.new(0, 8)
			p.Parent = row
			corner(row, 4)
			local rs = Instance.new("UIStroke")
			rs.Thickness = 1
			rs.Color = COL.brassDeep
			rs.Transparency = 0.7
			rs.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
			rs.Parent = row
		end
		return col
	end

	makeColumn("CrossingsCol", 0)
	makeColumn("BarrelsCol", 0.5)
end

local dock = ensureFolder(Workspace, "DocksLeaderboard")
local existing = dock:FindFirstChild("Board")

if existing and existing:IsA("BasePart") and existing:FindFirstChild("StraitLeaderboardGui") then
	local board = existing
	styleBoardPart(board)
	local sg = board:FindFirstChild("StraitLeaderboardGui") :: SurfaceGui?
	if sg then
		sg.Adornee = board
		buildLeaderboardGui(sg)
	end
	return "OK: Restyled StraitLeaderboardGui in place — Board CFrame unchanged. Save the place."
end

if existing then
	existing:Destroy()
end

local board = Instance.new("Part")
board.Name = "Board"
board.Size = Vector3.new(15, 9.5, 0.55)
board.Anchored = true
board.CanCollide = false
styleBoardPart(board)
board.CFrame = CFrame.new(0, 12, -20) * CFrame.Angles(0, math.rad(180), 0)
board.Parent = dock

local sg = Instance.new("SurfaceGui")
sg.Parent = board
buildLeaderboardGui(sg)
sg.Adornee = board

return "OK: Created DocksLeaderboard.Board with styled GUI. Save the place."
