--!strict
-- VeinCrateOpener: full-screen crate opening UI with spinning card carousel.
-- Matches the reference image exactly: dark overlay, title, red pointer, 4 visible cards,
-- horizontal scroll deceleration, winner highlight.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local VeinCrateConfig = require(Shared:WaitForChild("Config"):WaitForChild("VeinCrateConfig"))

local VeinCrateOpener = {}

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local CARD_WIDTH = 220
local CARD_HEIGHT = 280
local CARD_GAP = 8
local VISIBLE_CARDS = 4
local STRIP_WIDTH = (CARD_WIDTH + CARD_GAP) * VISIBLE_CARDS
local SPIN_DURATION = 4
local HOLD_DURATION = 2

-- ═══════════════════════════════════════════════════════════
-- Build a single card Frame
-- ═══════════════════════════════════════════════════════════

local function createCard(veinType: VeinCrateConfig.VeinTypeDef, parent: Instance): Frame
	local bgColor = VeinCrateConfig.GetRarityColor(veinType.rarity)

	local card = Instance.new("Frame")
	card.Name = "Card_" .. veinType.id
	card.Size = UDim2.fromOffset(CARD_WIDTH, CARD_HEIGHT)
	card.BackgroundColor3 = bgColor
	card.BorderSizePixel = 0

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = card

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = Color3.fromRGB(0, 0, 0)
	stroke.Parent = card

	-- Vein image (centered, 60% of card height)
	local img = Instance.new("ImageLabel")
	img.Name = "VeinImage"
	img.Size = UDim2.new(0.85, 0, 0.45, 0)
	img.Position = UDim2.new(0.075, 0, 0.2, 0)
	img.BackgroundTransparency = 1
	img.Image = veinType.imageId
	img.ScaleType = Enum.ScaleType.Fit
	img.Parent = card

	-- Name at top
	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "NameLabel"
	nameLabel.Size = UDim2.new(0.9, 0, 0, 22)
	nameLabel.Position = UDim2.new(0.05, 0, 0.03, 0)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextSize = 18
	nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	nameLabel.TextStrokeTransparency = 0
	nameLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	nameLabel.Text = veinType.displayName
	nameLabel.TextScaled = false
	nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
	nameLabel.Parent = card

	-- Barrels per second (yellow)
	local bpsLabel = Instance.new("TextLabel")
	bpsLabel.Name = "BpsLabel"
	bpsLabel.Size = UDim2.new(0.9, 0, 0, 20)
	bpsLabel.Position = UDim2.new(0.05, 0, 0.15, 0)
	bpsLabel.BackgroundTransparency = 1
	bpsLabel.Font = Enum.Font.GothamBold
	bpsLabel.TextSize = 16
	bpsLabel.TextColor3 = Color3.fromRGB(255, 255, 0)
	bpsLabel.TextStrokeTransparency = 0
	bpsLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	bpsLabel.Text = tostring(veinType.barrelsPerSecond) .. " barrels/s"
	bpsLabel.Parent = card

	-- Shiny label (optional)
	if veinType.shiny then
		local shinyLabel = Instance.new("TextLabel")
		shinyLabel.Name = "ShinyLabel"
		shinyLabel.Size = UDim2.new(0.9, 0, 0, 18)
		shinyLabel.Position = UDim2.new(0.05, 0, 0.68, 0)
		shinyLabel.BackgroundTransparency = 1
		shinyLabel.Font = Enum.Font.GothamBold
		shinyLabel.TextSize = 16
		shinyLabel.TextColor3 = Color3.fromRGB(255, 255, 0)
		shinyLabel.TextStrokeTransparency = 0
		shinyLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
		shinyLabel.Text = "Shiny"
		shinyLabel.Parent = card
	end

	-- Rarity label at bottom
	local rarityLabel = Instance.new("TextLabel")
	rarityLabel.Name = "RarityLabel"
	rarityLabel.Size = UDim2.new(0.9, 0, 0, 30)
	rarityLabel.Position = UDim2.new(0.05, 0, 0.85, 0)
	rarityLabel.BackgroundTransparency = 1
	rarityLabel.Font = Enum.Font.GothamBold
	rarityLabel.TextSize = 24
	rarityLabel.TextColor3 = Color3.fromRGB(255, 255, 0)
	rarityLabel.TextStrokeTransparency = 0
	rarityLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	rarityLabel.Text = veinType.rarity
	rarityLabel.Parent = card

	card.Parent = parent
	return card
end

-- ═══════════════════════════════════════════════════════════
-- Open the crate UI
-- ═══════════════════════════════════════════════════════════

function VeinCrateOpener.Open(winnerId: string, groundType: string, callback: (() -> ())?)
	-- Close any existing
	local existing = playerGui:FindFirstChild("VeinCrateGui")
	if existing then existing:Destroy() end

	local winnerDef = VeinCrateConfig.GetById(winnerId)
	if not winnerDef then
		warn("[VeinCrateOpener] Unknown vein type: " .. tostring(winnerId))
		if callback then callback() end
		return
	end

	local pool = VeinCrateConfig.GetAllForGround(groundType)
	if #pool == 0 then
		if callback then callback() end
		return
	end

	-- Build the GUI
	local gui = Instance.new("ScreenGui")
	gui.Name = "VeinCrateGui"
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 200
	gui.ResetOnSpawn = false
	gui.Parent = playerGui

	-- Dark overlay
	local overlay = Instance.new("Frame")
	overlay.Name = "Overlay"
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	overlay.BackgroundTransparency = 0.4
	overlay.BorderSizePixel = 0
	overlay.Parent = gui

	-- Title
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, 0, 0, 60)
	title.Position = UDim2.new(0, 0, 0.15, 0)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 48
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.TextStrokeTransparency = 0
	title.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	title.Text = "Opening Crate"
	title.Parent = overlay

	-- Red pointer triangle (using a rotated Frame)
	local pointerContainer = Instance.new("Frame")
	pointerContainer.Name = "Pointer"
	pointerContainer.Size = UDim2.fromOffset(40, 30)
	pointerContainer.AnchorPoint = Vector2.new(0.5, 0)
	pointerContainer.Position = UDim2.new(0.5, 0, 0.15, 65)
	pointerContainer.BackgroundTransparency = 1
	pointerContainer.Parent = overlay

	local pointerTri = Instance.new("Frame")
	pointerTri.Size = UDim2.fromOffset(30, 30)
	pointerTri.AnchorPoint = Vector2.new(0.5, 0)
	pointerTri.Position = UDim2.new(0.5, 0, 0, 0)
	pointerTri.BackgroundColor3 = Color3.fromRGB(255, 0, 0)
	pointerTri.Rotation = 45
	pointerTri.BorderSizePixel = 0
	pointerTri.Parent = pointerContainer

	-- Card strip container (clips content)
	local stripContainer = Instance.new("Frame")
	stripContainer.Name = "StripContainer"
	stripContainer.Size = UDim2.fromOffset(STRIP_WIDTH, CARD_HEIGHT)
	stripContainer.AnchorPoint = Vector2.new(0.5, 0)
	stripContainer.Position = UDim2.new(0.5, 0, 0.15, 105)
	stripContainer.BackgroundTransparency = 1
	stripContainer.ClipsDescendants = true
	stripContainer.Parent = overlay

	-- Inner strip (holds all cards, scrolls horizontally)
	local strip = Instance.new("Frame")
	strip.Name = "Strip"
	strip.BackgroundTransparency = 1
	strip.Parent = stripContainer

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, CARD_GAP)
	layout.Parent = strip

	-- Build card sequence: repeat pool enough times for the spin + place winner at landing spot
	-- We need enough cards for ~4 seconds of fast scrolling
	-- At peak speed we skip ~20 cards/sec = ~80 cards, plus the visible 4
	local TOTAL_CARDS = 60
	local WINNER_INDEX = TOTAL_CARDS - 2 -- winner lands near the end, under the pointer (2nd visible slot)

	local cards = {}
	for i = 1, TOTAL_CARDS do
		local vt
		if i == WINNER_INDEX then
			vt = winnerDef
		else
			vt = pool[((i - 1) % #pool) + 1]
		end
		local card = createCard(vt, strip)
		card.LayoutOrder = i
		table.insert(cards, { frame = card, def = vt })
	end

	-- Size the strip to fit all cards
	local totalWidth = TOTAL_CARDS * (CARD_WIDTH + CARD_GAP)
	strip.Size = UDim2.fromOffset(totalWidth, CARD_HEIGHT)

	-- Starting position: show first 4 cards
	strip.Position = UDim2.fromOffset(0, 0)

	-- Target X: winner card should be centered under the pointer (2nd slot = center-left)
	-- Pointer is at center of stripContainer. Winner card center should align with pointer.
	local winnerCardLeft = (WINNER_INDEX - 1) * (CARD_WIDTH + CARD_GAP)
	local targetX = -(winnerCardLeft - STRIP_WIDTH / 2 + CARD_WIDTH / 2)

	-- Animate the spin
	task.spawn(function()
		local t0 = os.clock()
		local startX = 0
		local distance = math.abs(targetX - startX)

		while true do
			local elapsed = os.clock() - t0
			if elapsed >= SPIN_DURATION then break end

			-- Ease-out cubic: fast start, slow end
			local alpha = elapsed / SPIN_DURATION
			local eased = 1 - (1 - alpha) ^ 3

			local x = startX + (targetX - startX) * eased
			strip.Position = UDim2.fromOffset(math.floor(x), 0)
			task.wait()
		end

		-- Snap to exact target
		strip.Position = UDim2.fromOffset(math.floor(targetX), 0)

		-- Highlight winner card
		local winnerCard = cards[WINNER_INDEX]
		if winnerCard then
			local glow = Instance.new("UIStroke")
			glow.Thickness = 5
			glow.Color = Color3.fromRGB(255, 255, 0)
			glow.Parent = winnerCard.frame

			-- Pulse the winner card
			local pulseTween = TweenService:Create(
				winnerCard.frame,
				TweenInfo.new(0.3, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, 2, true),
				{ Size = UDim2.fromOffset(CARD_WIDTH + 10, CARD_HEIGHT + 10) }
			)
			pulseTween:Play()
		end

		-- Hold for a moment
		task.wait(HOLD_DURATION)

		-- Fade out
		local fadeTween = TweenService:Create(
			overlay,
			TweenInfo.new(0.5),
			{ BackgroundTransparency = 1 }
		)
		fadeTween:Play()

		for _, child in ipairs(overlay:GetChildren()) do
			if child:IsA("TextLabel") then
				TweenService:Create(child, TweenInfo.new(0.5), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
			end
		end

		task.wait(0.6)
		gui:Destroy()

		if callback then
			callback()
		end
	end)
end

return VeinCrateOpener
