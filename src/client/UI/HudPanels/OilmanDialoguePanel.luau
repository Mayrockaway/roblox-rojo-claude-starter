--!strict
-- Oilman NPC UX = two surfaces:
--   1) **BillboardGui** floating above Rodger's head — the dialogue choice
--      (Ask / Sell / close). Per-client; adornee = NPC head.
--   2) **ScreenGui** — the 2D sell modal with per-tier stepper sliders.
--      Only opens when the player picks "Sell your oil".
--
-- Live barrel counts come from `OilStateUpdate`. Sells fire one atomic
-- `RequestOilmanSell { quantities, requestId }`; server responds on
-- `OilActionResult` with a receipt payload.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer

local Shared = ReplicatedStorage:WaitForChild("Shared")
local OilmanConfig = require(Shared:WaitForChild("Config"):WaitForChild("OilmanConfig"))
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))

local SCREEN_NAME_SELL = "OilmanSellGui"
local SCREEN_NAME_DIALOGUE = "OilmanDialogueGui"

local OilmanDialoguePanel = {}

local COLORS = {
	bubbleBg = Color3.fromRGB(20, 24, 32),
	bubbleBorder = Color3.fromRGB(245, 170, 60),
	-- Match runtime modals (e.g. Pirate Hire): dim + panel chrome
	modalBackdrop = Color3.fromRGB(0, 0, 0),
	modalBackdropTransparency = 0.35,
	modalPanel = Color3.fromRGB(20, 25, 34),
	panelBorder = Color3.fromRGB(245, 170, 60),
	titleGold = Color3.fromRGB(248, 234, 146),
	text = Color3.fromRGB(228, 236, 248),
	info = Color3.fromRGB(223, 232, 244),
	dim = Color3.fromRGB(160, 170, 190),
	accent = Color3.fromRGB(245, 170, 60),
	good = Color3.fromRGB(90, 200, 130),
	button = Color3.fromRGB(56, 70, 92),
	buttonActive = Color3.fromRGB(72, 86, 108),
	buttonDisabled = Color3.fromRGB(36, 42, 54),
	rowBg = Color3.fromRGB(28, 34, 46),
	rowBgMuted = Color3.fromRGB(24, 29, 38),
	closeButton = Color3.fromRGB(48, 56, 70),
}

local function corner(px: number, parent: Instance)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, px)
	c.Parent = parent
	return c
end

local function stroke(color: Color3, thickness: number, parent: Instance)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness
	s.Parent = parent
	return s
end

local function waitRemote(name: string): Instance
	local folder = Shared:WaitForChild("Remotes", 60)
	return folder:WaitForChild(name, 30)
end

local function findRodgerHead(): BasePart?
	local oilman = Workspace:FindFirstChild("Oilman")
	if not oilman then return nil end
	local rig = oilman:FindFirstChild("RodgerDodger")
	if not rig then return nil end
	local head = rig:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return head
	end
	local root = rig:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return rig:FindFirstChildWhichIsA("BasePart", true)
end

local function waitRodgerHead(timeoutSec: number): BasePart?
	local deadline = os.clock() + timeoutSec
	while os.clock() < deadline do
		local head = findRodgerHead()
		if head then return head end
		task.wait(0.25)
	end
	return nil
end

--- Dialogue = ScreenGui with stacked block-text. Floats "in front of" the
--- locked camera (positioned center-right of screen) so clicks always land.
local function buildDialogueScreen(): ScreenGui
	local screen = Instance.new("ScreenGui")
	screen.Name = SCREEN_NAME_DIALOGUE
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 60
	screen.Enabled = false

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	-- Center-right of the screen — camera frames Rodger on the left, text on the right.
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Position = UDim2.fromScale(0.68, 0.55)
	root.Size = UDim2.fromOffset(500, 320)
	root.Parent = screen

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = root

	local COLOR_IDLE = Color3.fromRGB(255, 255, 255)
	local COLOR_HOVER = Color3.fromRGB(255, 205, 80) -- warm gold on hover
	-- BackgroundTransparency must be <1 on BillboardGui buttons for the full
	-- bounding-box hit region to register clicks. 0.99 is visually invisible
	-- but keeps the button hit-testable across the whole rectangle.
	local BG_IDLE = 0.99
	local BG_HOVER = 0.35

	local function newBlockyLine(name: string, text: string, layoutOrder: number, asButton: boolean): GuiObject
		local base: GuiObject
		if asButton then
			local btn = Instance.new("TextButton")
			btn.AutoButtonColor = false
			btn.Text = text
			btn.Active = true
			btn.Selectable = true
			btn.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
			btn.BackgroundTransparency = BG_IDLE
			base = btn :: any

			-- Hover: highlight with gold text + subtle dark backdrop so the
			-- player sees which option they're about to click.
			btn.MouseEnter:Connect(function()
				btn.TextColor3 = COLOR_HOVER
				btn.BackgroundTransparency = BG_HOVER
			end)
			btn.MouseLeave:Connect(function()
				btn.TextColor3 = COLOR_IDLE
				btn.BackgroundTransparency = BG_IDLE
			end)

			-- Nice squared corners for the hover fill (still reads "blocky").
			local c = Instance.new("UICorner")
			c.CornerRadius = UDim.new(0, 6)
			c.Parent = btn
		else
			local lbl = Instance.new("TextLabel")
			lbl.Text = text
			lbl.BackgroundTransparency = 1
			base = lbl :: any
		end
		base.Name = name
		base.BorderSizePixel = 0
		base.Size = UDim2.new(1, 0, 0, 42)
		base.LayoutOrder = layoutOrder
		;(base :: any).Font = Enum.Font.Merriweather
		;(base :: any).TextSize = 34
		;(base :: any).TextColor3 = COLOR_IDLE
		;(base :: any).TextStrokeTransparency = 0
		;(base :: any).TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
		;(base :: any).TextXAlignment = Enum.TextXAlignment.Center
		;(base :: any).TextYAlignment = Enum.TextYAlignment.Center
		return base
	end

	-- Header (non-clickable name line).
	local header = newBlockyLine("Header", "Oilman Jack:", 1, false)
	header.Size = UDim2.new(1, 0, 0, 50)
	;(header :: any).TextSize = 44
	;(header :: any).TextXAlignment = Enum.TextXAlignment.Left
	header.Parent = root

	-- "Message" cycles the current flavor quote into the header slot.
	local messageBtn = newBlockyLine("MessageButton", "Message", 2, true)
	;(messageBtn :: any).TextXAlignment = Enum.TextXAlignment.Left
	messageBtn.Parent = root

	-- Sell shortcut — opens the 2D stepper modal.
	local sellBtn = newBlockyLine("SellButton", "Sell Oil (at a discount)", 3, true)
	;(sellBtn :: any).TextXAlignment = Enum.TextXAlignment.Left
	sellBtn.Parent = root

	-- Close the whole dialogue.
	local backBtn = newBlockyLine("BackButton", "back", 4, true)
	;(backBtn :: any).TextSize = 28
	;(backBtn :: any).TextColor3 = Color3.fromRGB(210, 210, 210)
	;(backBtn :: any).TextXAlignment = Enum.TextXAlignment.Left
	backBtn.Parent = root

	return screen
end

--- Build the 2D sell modal (ScreenGui).
local function buildSellScreen(): ScreenGui
	local screen = Instance.new("ScreenGui")
	screen.Name = SCREEN_NAME_SELL
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 55
	screen.Enabled = false

	local backdrop = Instance.new("TextButton")
	backdrop.Name = "Backdrop"
	backdrop.Text = ""
	backdrop.AutoButtonColor = false
	backdrop.BackgroundColor3 = COLORS.modalBackdrop
	backdrop.BackgroundTransparency = COLORS.modalBackdropTransparency
	backdrop.BorderSizePixel = 0
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.ZIndex = 1
	backdrop.Parent = screen

	local panel = Instance.new("Frame")
	panel.Name = "PanelHost"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	-- Scale-first shell: fits phone + desktop; caps keep it from growing huge on ultrawide.
	panel.Size = UDim2.new(0.94, 0, 0.86, 0)
	panel.BackgroundColor3 = COLORS.modalPanel
	panel.BorderSizePixel = 0
	panel.ZIndex = 10
	panel.Parent = screen
	corner(12, panel)
	stroke(COLORS.panelBorder, 2, panel)

	local sizeCap = Instance.new("UISizeConstraint")
	sizeCap.MinSize = Vector2.new(280, 300)
	sizeCap.MaxSize = Vector2.new(620, 520)
	sizeCap.Parent = panel

	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectRatio = 1.5
	aspect.AspectType = Enum.AspectType.FitWithinMaxSize
	aspect.DominantAxis = Enum.DominantAxis.Width
	aspect.Parent = panel

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0.02, 10)
	pad.PaddingBottom = UDim.new(0.02, 10)
	pad.PaddingLeft = UDim.new(0.03, 8)
	pad.PaddingRight = UDim.new(0.03, 8)
	pad.Parent = panel

	local column = Instance.new("Frame")
	column.Name = "Column"
	column.BackgroundTransparency = 1
	column.BorderSizePixel = 0
	column.Size = UDim2.new(1, 0, 1, 0)
	column.ZIndex = 11
	column.Parent = panel

	local colLayout = Instance.new("UIListLayout")
	colLayout.FillDirection = Enum.FillDirection.Vertical
	colLayout.SortOrder = Enum.SortOrder.LayoutOrder
	colLayout.Padding = UDim.new(0, 8)
	colLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	colLayout.VerticalAlignment = Enum.VerticalAlignment.Top
	colLayout.Parent = column

	local headerBar = Instance.new("Frame")
	headerBar.Name = "HeaderBar"
	headerBar.BackgroundTransparency = 1
	headerBar.BorderSizePixel = 0
	headerBar.Size = UDim2.new(1, 0, 0, 40)
	headerBar.LayoutOrder = 1
	headerBar.ZIndex = 11
	headerBar.Parent = column

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.Merriweather
	title.TextScaled = true
	title.TextColor3 = COLORS.titleGold
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "Sell to Rodger"
	title.Size = UDim2.new(1, -44, 1, 0)
	title.Position = UDim2.fromScale(0, 0)
	title.ZIndex = 12
	title.Parent = headerBar
	local titleTsc = Instance.new("UITextSizeConstraint")
	titleTsc.MaxTextSize = 22
	titleTsc.MinTextSize = 14
	titleTsc.Parent = title

	local closeBtn = Instance.new("TextButton")
	closeBtn.Name = "CloseButton"
	closeBtn.AutoButtonColor = true
	closeBtn.BackgroundColor3 = COLORS.closeButton
	closeBtn.BorderSizePixel = 0
	closeBtn.Font = Enum.Font.Merriweather
	closeBtn.TextScaled = true
	closeBtn.TextColor3 = COLORS.text
	closeBtn.Text = "✕"
	closeBtn.Size = UDim2.new(0, 36, 0, 36)
	closeBtn.AnchorPoint = Vector2.new(1, 0)
	closeBtn.Position = UDim2.new(1, 0, 0, 0)
	closeBtn.ZIndex = 12
	closeBtn.Parent = headerBar
	corner(8, closeBtn)
	local closeTsc = Instance.new("UITextSizeConstraint")
	closeTsc.MaxTextSize = 18
	closeTsc.MinTextSize = 12
	closeTsc.Parent = closeBtn

	local subtitle = Instance.new("TextLabel")
	subtitle.Name = "Subtitle"
	subtitle.BackgroundTransparency = 1
	subtitle.Font = Enum.Font.Merriweather
	subtitle.TextSize = 14
	subtitle.TextColor3 = COLORS.info
	subtitle.TextTransparency = 0.05
	subtitle.TextXAlignment = Enum.TextXAlignment.Left
	subtitle.TextYAlignment = Enum.TextYAlignment.Top
	subtitle.TextWrapped = true
	subtitle.Text = "Cheap quick-cash for your local barrels."
	subtitle.Size = UDim2.new(1, 0, 0, 0)
	subtitle.AutomaticSize = Enum.AutomaticSize.Y
	subtitle.LayoutOrder = 2
	subtitle.ZIndex = 11
	subtitle.Parent = column
	local subTsc = Instance.new("UITextSizeConstraint")
	subTsc.MaxTextSize = 15
	subTsc.MinTextSize = 11
	subTsc.Parent = subtitle

	local rowsScroll = Instance.new("ScrollingFrame")
	rowsScroll.Name = "RowsScroll"
	rowsScroll.BackgroundColor3 = COLORS.rowBgMuted
	rowsScroll.BackgroundTransparency = 0.65
	rowsScroll.BorderSizePixel = 0
	rowsScroll.ScrollBarThickness = 6
	rowsScroll.ScrollBarImageColor3 = COLORS.accent
	rowsScroll.ScrollingDirection = Enum.ScrollingDirection.Y
	rowsScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	rowsScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	rowsScroll.Size = UDim2.new(1, 0, 0.52, 0)
	rowsScroll.LayoutOrder = 3
	rowsScroll.ZIndex = 11
	rowsScroll.ClipsDescendants = true
	rowsScroll.Parent = column
	corner(8, rowsScroll)

	local scrollPad = Instance.new("UIPadding")
	scrollPad.PaddingTop = UDim.new(0, 6)
	scrollPad.PaddingBottom = UDim.new(0, 6)
	scrollPad.PaddingLeft = UDim.new(0, 6)
	scrollPad.PaddingRight = UDim.new(0, 4)
	scrollPad.Parent = rowsScroll

	local rowsContainer = Instance.new("Frame")
	rowsContainer.Name = "Rows"
	rowsContainer.BackgroundTransparency = 1
	rowsContainer.BorderSizePixel = 0
	rowsContainer.Size = UDim2.new(1, -4, 0, 0)
	rowsContainer.AutomaticSize = Enum.AutomaticSize.Y
	rowsContainer.Position = UDim2.fromOffset(0, 0)
	rowsContainer.ZIndex = 12
	rowsContainer.Parent = rowsScroll

	local rowsLayout = Instance.new("UIListLayout")
	rowsLayout.FillDirection = Enum.FillDirection.Vertical
	rowsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rowsLayout.Padding = UDim.new(0, 8)
	rowsLayout.Parent = rowsContainer

	local function newStepButton(parent: Instance, text: string, width: number, layoutOrder: number): TextButton
		local b = Instance.new("TextButton")
		b.Name = "Step_" .. text
		b.AutoButtonColor = true
		b.BackgroundColor3 = COLORS.button
		b.BorderSizePixel = 0
		b.Font = Enum.Font.Merriweather
		b.TextScaled = true
		b.TextColor3 = COLORS.text
		b.Text = text
		b.Size = UDim2.new(0, width, 1, 0)
		b.LayoutOrder = layoutOrder
		b.ZIndex = 14
		b.Parent = parent
		corner(6, b)
		local tsc = Instance.new("UITextSizeConstraint")
		tsc.MaxTextSize = 14
		tsc.MinTextSize = 9
		tsc.Parent = b
		return b
	end

	for i, tier in ipairs(OilmanConfig.TierOrder) do
		local row = Instance.new("Frame")
		row.Name = "Row_" .. tier
		row.BackgroundColor3 = COLORS.rowBg
		row.BorderSizePixel = 0
		row.Size = UDim2.new(1, 0, 0, 52)
		row.LayoutOrder = i
		row.ZIndex = 13
		row.Parent = rowsContainer
		corner(8, row)
		stroke(Color3.fromRGB(50, 58, 72), 1, row)

		local rowInner = Instance.new("Frame")
		rowInner.Name = "RowInner"
		rowInner.BackgroundTransparency = 1
		rowInner.BorderSizePixel = 0
		rowInner.Size = UDim2.new(1, 0, 1, 0)
		rowInner.ZIndex = 13
		rowInner.Parent = row

		-- Scale-based X so labels shrink on narrow modals; steppers stay right-aligned.
		local tierLabel = Instance.new("TextLabel")
		tierLabel.Name = "TierLabel"
		tierLabel.BackgroundTransparency = 1
		tierLabel.Font = Enum.Font.Merriweather
		tierLabel.TextScaled = true
		tierLabel.TextColor3 = COLORS.text
		tierLabel.TextXAlignment = Enum.TextXAlignment.Left
		tierLabel.TextTruncate = Enum.TextTruncate.AtEnd
		tierLabel.Text = OilmanConfig.TierDisplayName[tier] or tier
		tierLabel.Position = UDim2.new(0, 8, 0, 0)
		tierLabel.Size = UDim2.new(0.34, -8, 1, 0)
		tierLabel.ZIndex = 14
		tierLabel.Parent = rowInner
		local tierTsc = Instance.new("UITextSizeConstraint")
		tierTsc.MaxTextSize = 15
		tierTsc.MinTextSize = 10
		tierTsc.Parent = tierLabel

		local countLabel = Instance.new("TextLabel")
		countLabel.Name = "CountLabel"
		countLabel.BackgroundTransparency = 1
		countLabel.Font = Enum.Font.Merriweather
		countLabel.TextScaled = true
		countLabel.TextColor3 = COLORS.accent
		countLabel.TextXAlignment = Enum.TextXAlignment.Center
		countLabel.Text = "0 / 0"
		countLabel.Position = UDim2.new(0.34, 0, 0, 0)
		countLabel.Size = UDim2.new(0.16, 0, 1, 0)
		countLabel.ZIndex = 14
		countLabel.Parent = rowInner
		local cntTsc = Instance.new("UITextSizeConstraint")
		cntTsc.MaxTextSize = 15
		cntTsc.MinTextSize = 10
		cntTsc.Parent = countLabel

		local priceLabel = Instance.new("TextLabel")
		priceLabel.Name = "PriceLabel"
		priceLabel.BackgroundTransparency = 1
		priceLabel.Font = Enum.Font.Merriweather
		priceLabel.TextScaled = true
		priceLabel.TextColor3 = COLORS.dim
		priceLabel.TextXAlignment = Enum.TextXAlignment.Left
		priceLabel.Text = string.format("@ $%d", OilmanConfig.pricePerBarrel(tier))
		priceLabel.Position = UDim2.new(0.5, 0, 0, 0)
		priceLabel.Size = UDim2.new(0.14, 0, 1, 0)
		priceLabel.ZIndex = 14
		priceLabel.Parent = rowInner
		local priceTsc = Instance.new("UITextSizeConstraint")
		priceTsc.MaxTextSize = 13
		priceTsc.MinTextSize = 9
		priceTsc.Parent = priceLabel

		local steppers = Instance.new("Frame")
		steppers.Name = "Steppers"
		steppers.BackgroundTransparency = 1
		steppers.AnchorPoint = Vector2.new(1, 0.5)
		steppers.Position = UDim2.new(1, -6, 0.5, 0)
		steppers.Size = UDim2.new(0.34, -4, 0, 32)
		steppers.ZIndex = 14
		steppers.Parent = rowInner

		local stepLayout = Instance.new("UIListLayout")
		stepLayout.FillDirection = Enum.FillDirection.Horizontal
		stepLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
		stepLayout.VerticalAlignment = Enum.VerticalAlignment.Center
		stepLayout.SortOrder = Enum.SortOrder.LayoutOrder
		stepLayout.Padding = UDim.new(0, 3)
		stepLayout.Parent = steppers

		newStepButton(steppers, "-10", 30, 1)
		newStepButton(steppers, "-1", 26, 2)
		newStepButton(steppers, "+1", 26, 3)
		newStepButton(steppers, "+10", 30, 4)
		local maxBtn = newStepButton(steppers, "Max", 32, 5)
		maxBtn.BackgroundColor3 = COLORS.buttonActive
	end

	-- Footer
	local footer = Instance.new("Frame")
	footer.Name = "Footer"
	footer.BackgroundTransparency = 1
	footer.BorderSizePixel = 0
	footer.Size = UDim2.new(1, 0, 0, 88)
	footer.LayoutOrder = 4
	footer.ZIndex = 12
	footer.Parent = column

	local totalLabel = Instance.new("TextLabel")
	totalLabel.Name = "TotalLabel"
	totalLabel.BackgroundTransparency = 1
	totalLabel.Font = Enum.Font.Merriweather
	totalLabel.TextScaled = true
	totalLabel.TextColor3 = COLORS.info
	totalLabel.TextXAlignment = Enum.TextXAlignment.Left
	totalLabel.Text = "Total: 0 barrels → $0"
	totalLabel.Size = UDim2.new(1, 0, 0, 22)
	totalLabel.Position = UDim2.fromOffset(0, 0)
	totalLabel.ZIndex = 13
	totalLabel.Parent = footer
	local totalTsc = Instance.new("UITextSizeConstraint")
	totalTsc.MaxTextSize = 17
	totalTsc.MinTextSize = 12
	totalTsc.Parent = totalLabel

	local footerBtns = Instance.new("Frame")
	footerBtns.Name = "FooterButtons"
	footerBtns.BackgroundTransparency = 1
	footerBtns.BorderSizePixel = 0
	footerBtns.Size = UDim2.new(1, 0, 0, 40)
	footerBtns.Position = UDim2.fromOffset(0, 44)
	footerBtns.ZIndex = 13
	footerBtns.Parent = footer

	local backBtn = Instance.new("TextButton")
	backBtn.Name = "BackButton"
	backBtn.AutoButtonColor = true
	backBtn.BackgroundColor3 = COLORS.button
	backBtn.BorderSizePixel = 0
	backBtn.Font = Enum.Font.Merriweather
	backBtn.TextScaled = true
	backBtn.TextColor3 = COLORS.text
	backBtn.Text = "< Back"
	backBtn.Size = UDim2.new(0.22, 0, 1, 0)
	backBtn.Position = UDim2.fromScale(0, 0)
	backBtn.ZIndex = 14
	backBtn.Parent = footerBtns
	corner(8, backBtn)
	local backTsc = Instance.new("UITextSizeConstraint")
	backTsc.MaxTextSize = 15
	backTsc.MinTextSize = 11
	backTsc.Parent = backBtn

	local maxAllBtn = Instance.new("TextButton")
	maxAllBtn.Name = "MaxAllButton"
	maxAllBtn.AutoButtonColor = true
	maxAllBtn.BackgroundColor3 = COLORS.button
	maxAllBtn.BorderSizePixel = 0
	maxAllBtn.Font = Enum.Font.Merriweather
	maxAllBtn.TextScaled = true
	maxAllBtn.TextColor3 = COLORS.text
	maxAllBtn.Text = "Max all"
	maxAllBtn.Size = UDim2.new(0.26, 0, 1, 0)
	maxAllBtn.Position = UDim2.new(0.24, 0, 0, 0)
	maxAllBtn.ZIndex = 14
	maxAllBtn.Parent = footerBtns
	corner(8, maxAllBtn)
	local maxAllTsc = Instance.new("UITextSizeConstraint")
	maxAllTsc.MaxTextSize = 15
	maxAllTsc.MinTextSize = 11
	maxAllTsc.Parent = maxAllBtn

	local sellConfirmBtn = Instance.new("TextButton")
	sellConfirmBtn.Name = "SellConfirmButton"
	sellConfirmBtn.AutoButtonColor = true
	sellConfirmBtn.BackgroundColor3 = COLORS.good
	sellConfirmBtn.BorderSizePixel = 0
	sellConfirmBtn.Font = Enum.Font.Merriweather
	sellConfirmBtn.TextScaled = true
	sellConfirmBtn.TextColor3 = Color3.fromRGB(14, 24, 18)
	sellConfirmBtn.Text = "Sell"
	sellConfirmBtn.AnchorPoint = Vector2.new(1, 0)
	sellConfirmBtn.Size = UDim2.new(0.3, 0, 1, 0)
	sellConfirmBtn.Position = UDim2.new(1, 0, 0, 0)
	sellConfirmBtn.ZIndex = 14
	sellConfirmBtn.Parent = footerBtns
	corner(8, sellConfirmBtn)
	local sellTsc = Instance.new("UITextSizeConstraint")
	sellTsc.MaxTextSize = 17
	sellTsc.MinTextSize = 12
	sellTsc.Parent = sellConfirmBtn

	return screen
end

function OilmanDialoguePanel.bind(playerGui: PlayerGui)
	-- Sell modal (rebuild if an older layout is cached in PlayerGui)
	local sellScreen = playerGui:FindFirstChild(SCREEN_NAME_SELL)
	if sellScreen and sellScreen:IsA("ScreenGui") then
		local host = sellScreen:FindFirstChild("PanelHost")
		local hasNew = host and host:FindFirstChild("RowsScroll")
		if not hasNew then
			sellScreen:Destroy()
			sellScreen = nil
		end
	end
	if not (sellScreen and sellScreen:IsA("ScreenGui")) then
		sellScreen = buildSellScreen()
		sellScreen.Parent = playerGui
	end
	sellScreen = sellScreen :: ScreenGui

	-- Dialogue ScreenGui (replaces the old BillboardGui — clicks on BillboardGui
	-- buttons are flaky, ScreenGui clicks are rock-solid).
	local dialogueScreen = playerGui:FindFirstChild(SCREEN_NAME_DIALOGUE)
	if not (dialogueScreen and dialogueScreen:IsA("ScreenGui")) then
		dialogueScreen = buildDialogueScreen()
		dialogueScreen.Parent = playerGui
	end
	dialogueScreen = dialogueScreen :: ScreenGui

	local root = dialogueScreen:WaitForChild("Root") :: Frame
	local headerLabel = root:WaitForChild("Header") :: TextLabel
	local messageBtn = root:WaitForChild("MessageButton") :: TextButton
	local sellBtn = root:WaitForChild("SellButton") :: TextButton
	local backLineBtn = root:WaitForChild("BackButton") :: TextButton

	-- Sell modal refs
	local panel = sellScreen:WaitForChild("PanelHost") :: Frame
	local rowsScroll = panel:WaitForChild("RowsScroll") :: ScrollingFrame
	local rowsContainer = rowsScroll:WaitForChild("Rows") :: Frame
	local footer = panel:WaitForChild("Footer") :: Frame
	local totalLabel = footer:WaitForChild("TotalLabel") :: TextLabel
	local backBtn = footer:WaitForChild("BackButton") :: TextButton
	local maxAllBtn = footer:WaitForChild("MaxAllButton") :: TextButton
	local sellConfirmBtn = footer:WaitForChild("SellConfirmButton") :: TextButton
	local sellCloseBtn = panel:WaitForChild("CloseButton") :: TextButton

	-- Remotes
	local sellRemote = waitRemote(RemoteNames.RequestOilmanSell) :: RemoteEvent
	local oilStateUpdate = waitRemote(RemoteNames.OilStateUpdate) :: RemoteEvent
	local oilActionResult = waitRemote(RemoteNames.OilActionResult) :: RemoteEvent

	--- Camera lock with a held CFrame (RenderStepped keeps it pinned so the
	--- player can't rotate while in dialogue). Camera is positioned 3/4 front
	--- of Rodger, framing his upper body to the LEFT of screen so the dialogue
	--- text (anchored center-right) doesn't overlap him.
	local camera = Workspace.CurrentCamera
	local savedCameraType: Enum.CameraType? = nil
	local savedCameraSubject: Instance? = nil
	local cameraLockCF: CFrame? = nil
	local cameraLockConn: RBXScriptConnection? = nil

	local function computeCameraCF(head: BasePart): CFrame
		local targetPos = head.Position
		-- Approach from 3/4-front: use head's look direction if non-zero,
		-- else fall back to world +Z (so we're looking at his face, not back).
		local forward = Vector3.new(head.CFrame.LookVector.X, 0, head.CFrame.LookVector.Z)
		if forward.Magnitude < 0.01 then
			forward = Vector3.new(0, 0, 1)
		end
		forward = forward.Unit
		-- Camera offset: in front of him (+forward), to his right (+right), slightly up.
		local right = Vector3.new(-forward.Z, 0, forward.X) -- right-of-forward in world XZ
		local camPos = targetPos + forward * 6 + right * 3 + Vector3.new(0, 1.0, 0)
		-- Subject framing target: his chest level, shifted LEFT on screen so
		-- text block sits clean to the right. We bias the lookAt a bit left-of-head.
		local framed = targetPos + Vector3.new(0, -0.3, 0) - right * 1.5
		return CFrame.lookAt(camPos, framed)
	end

	local function engageCameraLock()
		if not camera then return end
		local head = findRodgerHead()
		if not (head and head:IsA("BasePart")) then
			return
		end
		savedCameraType = camera.CameraType
		savedCameraSubject = camera.CameraSubject
		cameraLockCF = computeCameraCF(head)
		camera.CameraType = Enum.CameraType.Scriptable
		camera.CFrame = cameraLockCF
		-- Pin the camera every frame so default control code can't shift it.
		if cameraLockConn then cameraLockConn:Disconnect() end
		cameraLockConn = RunService.RenderStepped:Connect(function()
			if cameraLockCF then
				camera.CFrame = cameraLockCF
			end
		end)
	end
	local function releaseCameraLock()
		if cameraLockConn then
			cameraLockConn:Disconnect()
			cameraLockConn = nil
		end
		cameraLockCF = nil
		if not camera then return end
		if savedCameraType then
			camera.CameraType = savedCameraType
		end
		if savedCameraSubject then
			camera.CameraSubject = savedCameraSubject
		end
		savedCameraType = nil
		savedCameraSubject = nil
	end

	--- Freeze character so the player can't walk / jump during dialogue.
	--- Restore original values on release.
	local savedWalkSpeed: number? = nil
	local savedJumpPower: number? = nil
	local function freezeCharacter()
		local character = player.Character
		if not character then return end
		local hum = character:FindFirstChildOfClass("Humanoid")
		if not hum then return end
		savedWalkSpeed = hum.WalkSpeed
		savedJumpPower = hum.JumpPower
		hum.WalkSpeed = 0
		hum.JumpPower = 0
	end
	local function unfreezeCharacter()
		local character = player.Character
		local hum = character and character:FindFirstChildOfClass("Humanoid")
		if hum then
			if savedWalkSpeed then hum.WalkSpeed = savedWalkSpeed end
			if savedJumpPower then hum.JumpPower = savedJumpPower end
		end
		savedWalkSpeed = nil
		savedJumpPower = nil
	end

	--- Disable / re-enable the NPC's ProximityPrompt so E doesn't re-open the
	--- dialogue while it's already open.
	local function setPromptEnabled(state: boolean)
		local oilmanFolder = Workspace:FindFirstChild("Oilman")
		if not oilmanFolder then return end
		for _, d in ipairs(oilmanFolder:GetDescendants()) do
			if d:IsA("ProximityPrompt") and d.Name == "OilmanDialoguePrompt" then
				d.Enabled = state
			end
		end
	end

	-- State
	local tierMax: { [string]: number } = {}
	local tierValue: { [string]: number } = {}
	for _, tier in ipairs(OilmanConfig.TierOrder) do
		tierMax[tier] = 0
		tierValue[tier] = 0
	end

	-- "Message" swaps the header to the current quote for a few seconds, then
	-- restores the name line. Each click rotates to the next line.
	local askIndex = 0
	local HEADER_DEFAULT = "Oilman Jack:"
	local QUOTE_HOLD_SECONDS = 3.5
	local quoteSession = 0
	local function cycleQuote()
		local lines = OilmanConfig.QuestionLines
		if #lines == 0 then
			headerLabel.Text = "..."
			return
		end
		askIndex = (askIndex % #lines) + 1
		headerLabel.Text = lines[askIndex]
		quoteSession += 1
		local mySession = quoteSession
		task.delay(QUOTE_HOLD_SECONDS, function()
			if quoteSession == mySession and dialogueScreen.Enabled then
				headerLabel.Text = HEADER_DEFAULT
			end
		end)
	end

	local function clampValue(tier: string)
		local maxN = tierMax[tier] or 0
		local v = tierValue[tier] or 0
		if v < 0 then v = 0 end
		if v > maxN then v = maxN end
		tierValue[tier] = v
	end

	local function refreshRow(tier: string)
		local entry = rowsContainer:FindFirstChild("Row_" .. tier) :: Frame?
		if not entry then return end
		local countLabel = entry:FindFirstChild("CountLabel") :: TextLabel
		local steppers = entry:FindFirstChild("Steppers") :: Frame
		if not (countLabel and steppers) then return end
		clampValue(tier)
		local maxN = tierMax[tier] or 0
		local v = tierValue[tier] or 0
		countLabel.Text = string.format("%d / %d", v, maxN)
		local enabled = maxN > 0
		for _, child in ipairs(steppers:GetChildren()) do
			if child:IsA("TextButton") then
				(child :: TextButton).AutoButtonColor = enabled
				;(child :: TextButton).Active = enabled
				;(child :: TextButton).TextTransparency = enabled and 0 or 0.5
			end
		end
		entry.BackgroundTransparency = enabled and 0 or 0.5
	end

	local function refreshTotal()
		local totalB, totalPay = 0, 0
		for _, tier in ipairs(OilmanConfig.TierOrder) do
			local v = tierValue[tier] or 0
			totalB += v
			totalPay += v * OilmanConfig.pricePerBarrel(tier)
		end
		totalLabel.Text = string.format("Total: %d barrels → $%d", totalB, totalPay)
		local canSell = totalB > 0
		sellConfirmBtn.AutoButtonColor = canSell
		sellConfirmBtn.Active = canSell
		sellConfirmBtn.BackgroundColor3 = canSell and COLORS.good or COLORS.buttonDisabled
	end

	local function refreshAll()
		for _, tier in ipairs(OilmanConfig.TierOrder) do
			refreshRow(tier)
		end
		refreshTotal()
	end

	-- Wire sell-modal steppers
	for _, tier in ipairs(OilmanConfig.TierOrder) do
		local row = rowsContainer:FindFirstChild("Row_" .. tier) :: Frame?
		if not row then continue end
		local steppers = row:FindFirstChild("Steppers") :: Frame
		if not steppers then continue end
		local function adjust(delta: number)
			tierValue[tier] = (tierValue[tier] or 0) + delta
			refreshRow(tier)
			refreshTotal()
		end
		;(steppers:FindFirstChild("Step_-10") :: TextButton).Activated:Connect(function() adjust(-10) end)
		;(steppers:FindFirstChild("Step_-1") :: TextButton).Activated:Connect(function() adjust(-1) end)
		;(steppers:FindFirstChild("Step_+1") :: TextButton).Activated:Connect(function() adjust(1) end)
		;(steppers:FindFirstChild("Step_+10") :: TextButton).Activated:Connect(function() adjust(10) end)
		;(steppers:FindFirstChild("Step_Max") :: TextButton).Activated:Connect(function()
			tierValue[tier] = tierMax[tier] or 0
			refreshRow(tier); refreshTotal()
		end)
	end

	maxAllBtn.Activated:Connect(function()
		for _, tier in ipairs(OilmanConfig.TierOrder) do
			tierValue[tier] = tierMax[tier] or 0
		end
		refreshAll()
	end)

	-- Close handlers
	local function closeAll()
		dialogueScreen.Enabled = false
		sellScreen.Enabled = false
		headerLabel.Text = HEADER_DEFAULT
		releaseCameraLock()
		unfreezeCharacter()
		setPromptEnabled(true)
	end
	backLineBtn.Activated:Connect(closeAll)
	sellCloseBtn.Activated:Connect(closeAll)

	-- Press E while the dialogue is open to close (matches the prompt's key so
	-- the same button opens + closes naturally).
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		if input.KeyCode ~= Enum.KeyCode.E then return end
		if dialogueScreen.Enabled or sellScreen.Enabled then
			closeAll()
		end
	end)

	-- Dialogue → sell modal transition
	sellBtn.Activated:Connect(function()
		for _, tier in ipairs(OilmanConfig.TierOrder) do
			tierValue[tier] = 0
		end
		dialogueScreen.Enabled = false
		sellScreen.Enabled = true
		refreshAll()
	end)

	-- Sell modal → back to dialogue
	backBtn.Activated:Connect(function()
		sellScreen.Enabled = false
		dialogueScreen.Enabled = true
	end)

	-- "Message" cycles the quote in the header slot
	messageBtn.Activated:Connect(cycleQuote)

	-- Commit sell
	sellConfirmBtn.Activated:Connect(function()
		local quantities = {}
		local total = 0
		for _, tier in ipairs(OilmanConfig.TierOrder) do
			local v = tierValue[tier] or 0
			if v > 0 then
				quantities[tier] = v
				total += v
			end
		end
		if total <= 0 then return end
		sellRemote:FireServer({
			quantities = quantities,
			requestId = HttpService:GenerateGUID(false),
		})
	end)

	-- Live stock updates
	oilStateUpdate.OnClientEvent:Connect(function(snap: any)
		if typeof(snap) ~= "table" or typeof(snap.oilByTier) ~= "table" then
			return
		end
		for _, tier in ipairs(OilmanConfig.TierOrder) do
			local raw = tonumber(snap.oilByTier[tier]) or 0
			tierMax[tier] = math.max(0, math.floor(raw))
			if (tierValue[tier] or 0) > tierMax[tier] then
				tierValue[tier] = tierMax[tier]
			end
		end
		if sellScreen.Enabled then
			refreshAll()
		end
	end)

	-- Sell receipt → bounce back to dialogue with a receipt line in the header.
	oilActionResult.OnClientEvent:Connect(function(msg: any)
		if typeof(msg) ~= "table" or typeof(msg.data) ~= "table" then return end
		local data = msg.data
		if typeof(data.lines) == "table"
			and typeof(data.totalBarrels) == "number"
			and typeof(data.totalPayout) == "number" then
			headerLabel.Text = string.format("Sold %d for $%d. Pleasure.", data.totalBarrels, data.totalPayout)
			quoteSession += 1
			local mySession = quoteSession
			task.delay(QUOTE_HOLD_SECONDS, function()
				if quoteSession == mySession and dialogueScreen.Enabled then
					headerLabel.Text = HEADER_DEFAULT
				end
			end)
			for _, tier in ipairs(OilmanConfig.TierOrder) do
				tierValue[tier] = 0
			end
			sellScreen.Enabled = false
			dialogueScreen.Enabled = true
		end
	end)

	return {
		ScreenName = SCREEN_NAME_SELL,
		Open = function()
			headerLabel.Text = HEADER_DEFAULT
			askIndex = 0
			quoteSession += 1
			sellScreen.Enabled = false
			dialogueScreen.Enabled = true
			engageCameraLock()
			freezeCharacter()
			setPromptEnabled(false)
		end,
		Close = closeAll,
		IsOpen = function()
			return dialogueScreen.Enabled or sellScreen.Enabled
		end,
	}
end

function OilmanDialoguePanel.screenName(): string
	return SCREEN_NAME_SELL
end

return OilmanDialoguePanel
