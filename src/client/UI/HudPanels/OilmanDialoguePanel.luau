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
	modalBackdrop = Color3.fromRGB(12, 14, 18),
	modalPanel = Color3.fromRGB(26, 30, 38),
	panelBorder = Color3.fromRGB(60, 68, 82),
	text = Color3.fromRGB(228, 236, 248),
	dim = Color3.fromRGB(160, 170, 190),
	accent = Color3.fromRGB(245, 170, 60),
	good = Color3.fromRGB(90, 200, 130),
	button = Color3.fromRGB(40, 46, 58),
	buttonActive = Color3.fromRGB(56, 64, 80),
	buttonDisabled = Color3.fromRGB(28, 32, 40),
	rowBg = Color3.fromRGB(32, 36, 46),
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
		;(base :: any).Font = Enum.Font.LuckiestGuy
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
	backdrop.BackgroundTransparency = 0.4
	backdrop.BorderSizePixel = 0
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.ZIndex = 1
	backdrop.Parent = screen

	local panel = Instance.new("Frame")
	panel.Name = "PanelHost"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(540, 360)
	panel.BackgroundColor3 = COLORS.modalPanel
	panel.BorderSizePixel = 0
	panel.ZIndex = 10
	panel.Parent = screen
	corner(12, panel)
	stroke(COLORS.panelBorder, 2, panel)

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 20
	title.TextColor3 = COLORS.text
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "Sell to Rodger"
	title.Position = UDim2.fromOffset(24, 16)
	title.Size = UDim2.new(1, -60, 0, 26)
	title.ZIndex = 11
	title.Parent = panel

	local subtitle = Instance.new("TextLabel")
	subtitle.Name = "Subtitle"
	subtitle.BackgroundTransparency = 1
	subtitle.Font = Enum.Font.Gotham
	subtitle.TextSize = 13
	subtitle.TextColor3 = COLORS.dim
	subtitle.TextXAlignment = Enum.TextXAlignment.Left
	subtitle.Text = "Cheap quick-cash for your local barrels."
	subtitle.Position = UDim2.fromOffset(24, 42)
	subtitle.Size = UDim2.new(1, -60, 0, 16)
	subtitle.ZIndex = 11
	subtitle.Parent = panel

	local closeBtn = Instance.new("TextButton")
	closeBtn.Name = "CloseButton"
	closeBtn.AutoButtonColor = true
	closeBtn.BackgroundColor3 = COLORS.button
	closeBtn.BorderSizePixel = 0
	closeBtn.Font = Enum.Font.GothamBold
	closeBtn.TextSize = 16
	closeBtn.TextColor3 = COLORS.text
	closeBtn.Text = "X"
	closeBtn.Size = UDim2.fromOffset(32, 32)
	closeBtn.Position = UDim2.new(1, -40, 0, 14)
	closeBtn.ZIndex = 12
	closeBtn.Parent = panel
	corner(6, closeBtn)

	-- Rows
	local rowsContainer = Instance.new("Frame")
	rowsContainer.Name = "Rows"
	rowsContainer.BackgroundTransparency = 1
	rowsContainer.Size = UDim2.new(1, -48, 0, 56 * #OilmanConfig.TierOrder + 8)
	rowsContainer.Position = UDim2.fromOffset(24, 78)
	rowsContainer.ZIndex = 11
	rowsContainer.Parent = panel

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
		b.Font = Enum.Font.GothamBold
		b.TextSize = 14
		b.TextColor3 = COLORS.text
		b.Text = text
		b.Size = UDim2.new(0, width, 1, 0)
		b.LayoutOrder = layoutOrder
		b.ZIndex = 13
		b.Parent = parent
		corner(6, b)
		return b
	end

	for i, tier in ipairs(OilmanConfig.TierOrder) do
		local row = Instance.new("Frame")
		row.Name = "Row_" .. tier
		row.BackgroundColor3 = COLORS.rowBg
		row.BorderSizePixel = 0
		row.Size = UDim2.new(1, 0, 0, 48)
		row.LayoutOrder = i
		row.ZIndex = 12
		row.Parent = rowsContainer
		corner(6, row)

		local tierLabel = Instance.new("TextLabel")
		tierLabel.Name = "TierLabel"
		tierLabel.BackgroundTransparency = 1
		tierLabel.Font = Enum.Font.GothamMedium
		tierLabel.TextSize = 14
		tierLabel.TextColor3 = COLORS.text
		tierLabel.TextXAlignment = Enum.TextXAlignment.Left
		tierLabel.Text = OilmanConfig.TierDisplayName[tier] or tier
		tierLabel.Position = UDim2.fromOffset(12, 0)
		tierLabel.Size = UDim2.new(0, 130, 1, 0)
		tierLabel.ZIndex = 13
		tierLabel.Parent = row

		local countLabel = Instance.new("TextLabel")
		countLabel.Name = "CountLabel"
		countLabel.BackgroundTransparency = 1
		countLabel.Font = Enum.Font.GothamBold
		countLabel.TextSize = 14
		countLabel.TextColor3 = COLORS.accent
		countLabel.TextXAlignment = Enum.TextXAlignment.Center
		countLabel.Text = "0 / 0"
		countLabel.Position = UDim2.fromOffset(148, 0)
		countLabel.Size = UDim2.new(0, 80, 1, 0)
		countLabel.ZIndex = 13
		countLabel.Parent = row

		local priceLabel = Instance.new("TextLabel")
		priceLabel.Name = "PriceLabel"
		priceLabel.BackgroundTransparency = 1
		priceLabel.Font = Enum.Font.Gotham
		priceLabel.TextSize = 13
		priceLabel.TextColor3 = COLORS.dim
		priceLabel.TextXAlignment = Enum.TextXAlignment.Left
		priceLabel.Text = string.format("@ $%d", OilmanConfig.pricePerBarrel(tier))
		priceLabel.Position = UDim2.fromOffset(234, 0)
		priceLabel.Size = UDim2.new(0, 60, 1, 0)
		priceLabel.ZIndex = 13
		priceLabel.Parent = row

		local steppers = Instance.new("Frame")
		steppers.Name = "Steppers"
		steppers.BackgroundTransparency = 1
		steppers.AnchorPoint = Vector2.new(1, 0.5)
		steppers.Position = UDim2.new(1, -10, 0.5, 0)
		steppers.Size = UDim2.new(0, 200, 0, 32)
		steppers.ZIndex = 13
		steppers.Parent = row

		local stepLayout = Instance.new("UIListLayout")
		stepLayout.FillDirection = Enum.FillDirection.Horizontal
		stepLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
		stepLayout.VerticalAlignment = Enum.VerticalAlignment.Center
		stepLayout.SortOrder = Enum.SortOrder.LayoutOrder
		stepLayout.Padding = UDim.new(0, 4)
		stepLayout.Parent = steppers

		newStepButton(steppers, "-10", 38, 1)
		newStepButton(steppers, "-1", 30, 2)
		newStepButton(steppers, "+1", 30, 3)
		newStepButton(steppers, "+10", 38, 4)
		local maxBtn = newStepButton(steppers, "Max", 40, 5)
		maxBtn.BackgroundColor3 = COLORS.buttonActive
	end

	-- Footer
	local footer = Instance.new("Frame")
	footer.Name = "Footer"
	footer.BackgroundTransparency = 1
	footer.AnchorPoint = Vector2.new(0, 1)
	footer.Position = UDim2.new(0, 24, 1, -16)
	footer.Size = UDim2.new(1, -48, 0, 76)
	footer.ZIndex = 12
	footer.Parent = panel

	local totalLabel = Instance.new("TextLabel")
	totalLabel.Name = "TotalLabel"
	totalLabel.BackgroundTransparency = 1
	totalLabel.Font = Enum.Font.GothamBold
	totalLabel.TextSize = 16
	totalLabel.TextColor3 = COLORS.text
	totalLabel.TextXAlignment = Enum.TextXAlignment.Left
	totalLabel.Text = "Total: 0 barrels → $0"
	totalLabel.Size = UDim2.new(1, 0, 0, 22)
	totalLabel.ZIndex = 13
	totalLabel.Parent = footer

	local backBtn = Instance.new("TextButton")
	backBtn.Name = "BackButton"
	backBtn.AutoButtonColor = true
	backBtn.BackgroundColor3 = COLORS.button
	backBtn.BorderSizePixel = 0
	backBtn.Font = Enum.Font.GothamBold
	backBtn.TextSize = 14
	backBtn.TextColor3 = COLORS.text
	backBtn.Text = "< Back"
	backBtn.Size = UDim2.fromOffset(80, 36)
	backBtn.Position = UDim2.fromOffset(0, 36)
	backBtn.ZIndex = 13
	backBtn.Parent = footer
	corner(6, backBtn)

	local maxAllBtn = Instance.new("TextButton")
	maxAllBtn.Name = "MaxAllButton"
	maxAllBtn.AutoButtonColor = true
	maxAllBtn.BackgroundColor3 = COLORS.button
	maxAllBtn.BorderSizePixel = 0
	maxAllBtn.Font = Enum.Font.GothamBold
	maxAllBtn.TextSize = 14
	maxAllBtn.TextColor3 = COLORS.text
	maxAllBtn.Text = "Max all"
	maxAllBtn.Size = UDim2.fromOffset(90, 36)
	maxAllBtn.Position = UDim2.fromOffset(88, 36)
	maxAllBtn.ZIndex = 13
	maxAllBtn.Parent = footer
	corner(6, maxAllBtn)

	local sellConfirmBtn = Instance.new("TextButton")
	sellConfirmBtn.Name = "SellConfirmButton"
	sellConfirmBtn.AutoButtonColor = true
	sellConfirmBtn.BackgroundColor3 = COLORS.good
	sellConfirmBtn.BorderSizePixel = 0
	sellConfirmBtn.Font = Enum.Font.GothamBold
	sellConfirmBtn.TextSize = 16
	sellConfirmBtn.TextColor3 = Color3.fromRGB(14, 24, 18)
	sellConfirmBtn.Text = "Sell"
	sellConfirmBtn.AnchorPoint = Vector2.new(1, 0)
	sellConfirmBtn.Size = UDim2.fromOffset(120, 36)
	sellConfirmBtn.Position = UDim2.new(1, 0, 0, 36)
	sellConfirmBtn.ZIndex = 13
	sellConfirmBtn.Parent = footer
	corner(6, sellConfirmBtn)

	return screen
end

function OilmanDialoguePanel.bind(playerGui: PlayerGui)
	-- Sell modal
	local sellScreen = playerGui:FindFirstChild(SCREEN_NAME_SELL)
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
	local rowsContainer = panel:WaitForChild("Rows") :: Frame
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
