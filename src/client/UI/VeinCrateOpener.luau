--!strict
-- VeinCrateOpener: full-screen crate opening UI with spinning card carousel.

local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local VeinCrateConfig = require(Shared:WaitForChild("Config"):WaitForChild("VeinCrateConfig"))

local VeinCrateOpener = {}

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local CARD_WIDTH = 358
local CARD_HEIGHT = 358
local CARD_GAP = 12
local VISIBLE_CARDS = 4
local STRIP_WIDTH = (CARD_WIDTH + CARD_GAP) * VISIBLE_CARDS
local SPIN_DURATION = 5.5
local HOLD_DURATION = 2
local function preloadSpritesForPool(pool, winnerDef, groundType: string)
	local uniqueIds = {}
	local orderedIds = {}
	local function collect(def)
		local sprite = VeinCrateConfig.GetDisplaySprite(def, groundType)
		local imageId = sprite and sprite.imageId
		if typeof(imageId) == "string" and imageId ~= "" and imageId ~= "rbxassetid://0" and not uniqueIds[imageId] then
			uniqueIds[imageId] = true
			table.insert(orderedIds, imageId)
		end
	end
	collect(winnerDef)
	for _, def in ipairs(pool) do
		collect(def)
	end
	if #orderedIds == 0 then
		return
	end
	local preloadTargets = {}
	for _, imageId in ipairs(orderedIds) do
		local preloadImg = Instance.new("ImageLabel")
		preloadImg.Image = imageId
		table.insert(preloadTargets, preloadImg)
	end
	ContentProvider:PreloadAsync(preloadTargets)
	for _, preloadImg in ipairs(preloadTargets) do
		preloadImg:Destroy()
	end
end

-- ═══════════════════════════════════════════════════════════
-- Build a single card — the sprite IS the card, no extra FX
-- ═══════════════════════════════════════════════════════════

local function createCard(veinType: VeinCrateConfig.VeinTypeDef, groundType: string, parent: Instance): Frame
	local rarityStyle = VeinCrateConfig.GetRarityStyle(veinType.rarity)
	local displaySprite = VeinCrateConfig.GetDisplaySprite(veinType, groundType)

	-- Card frame — dark background peeks through at the sprite's rounded corners
	local card = Instance.new("Frame")
	card.Name = "Card_" .. veinType.id
	card.Size = UDim2.fromOffset(CARD_WIDTH, CARD_HEIGHT)
	card.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
	card.BorderSizePixel = 0

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 16)
	corner.Parent = card

	-- Layer 1: Rarity background image (gradient + rays + sparkles baked in)
	local bgAssetId = VeinCrateConfig.RarityBackgroundAssets[veinType.rarity]
	if bgAssetId and bgAssetId ~= "" and bgAssetId ~= "rbxassetid://0" then
		local bgImg = Instance.new("ImageLabel")
		bgImg.Name = "RarityBG"
		bgImg.Size = UDim2.fromScale(1, 1)
		bgImg.Position = UDim2.fromScale(0, 0)
		bgImg.BackgroundTransparency = 1
		bgImg.ZIndex = 0
		bgImg.ScaleType = Enum.ScaleType.Stretch
		bgImg.Image = bgAssetId
		bgImg.Parent = card
	end

	-- Layer 2: Item icon (transparent background)
	if displaySprite then
		local img = Instance.new("ImageLabel")
		img.Name = "VeinImage"
		img.Size = UDim2.fromScale(1, 1)
		img.Position = UDim2.fromScale(0, 0)
		img.BackgroundTransparency = 1
		img.ZIndex = 1
		img.ScaleType = Enum.ScaleType.Stretch
		img.Image = displaySprite.imageId
		img.Parent = card
	else
		local placeholder = Instance.new("TextLabel")
		placeholder.Name = "IconPlaceholder"
		placeholder.Size = UDim2.new(0.82, 0, 0.34, 0)
		placeholder.AnchorPoint = Vector2.new(0.5, 0.5)
		placeholder.Position = UDim2.new(0.5, 0, 0.5, 0)
		placeholder.BackgroundTransparency = 1
		placeholder.Font = Enum.Font.GothamBold
		placeholder.TextSize = 24
		placeholder.TextWrapped = true
		placeholder.TextColor3 = Color3.fromRGB(255, 255, 255)
		placeholder.TextStrokeTransparency = 0
		placeholder.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
		placeholder.Text = VeinCrateConfig.GetSignatureLabel(veinType)
		placeholder.ZIndex = 2
		placeholder.Parent = card
	end

	-- ── Text: Name at top ──
	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "NameLabel"
	nameLabel.Size = UDim2.new(0.92, 0, 0, 28)
	nameLabel.AnchorPoint = Vector2.new(0.5, 0)
	nameLabel.Position = UDim2.new(0.5, 0, 0.02, 0)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextSize = 22
	nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	nameLabel.TextStrokeTransparency = 0
	nameLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	nameLabel.Text = veinType.displayName
	nameLabel.ZIndex = 3
	nameLabel.TextScaled = false
	nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
	nameLabel.Parent = card

	-- ── Oil type summary below name ──
	-- e.g. "Crude Dribble + Refined Stream"
	local OIL_DISPLAY = { DirtOil = "Crude", GoodOil = "Refined", GoldOil = "Premium" }
	local streamParts = {}
	for _, stream in ipairs(veinType.streams) do
		local oilName = OIL_DISPLAY[stream.oilType] or stream.oilType
		local burstName = stream.burstType or "?"
		table.insert(streamParts, oilName .. " " .. burstName)
	end
	local oilSummary = table.concat(streamParts, " + ")

	local oilLabel = Instance.new("TextLabel")
	oilLabel.Name = "OilLabel"
	oilLabel.Size = UDim2.new(0.92, 0, 0, 22)
	oilLabel.AnchorPoint = Vector2.new(0.5, 0)
	oilLabel.Position = UDim2.new(0.5, 0, 0.10, 0)
	oilLabel.BackgroundTransparency = 1
	oilLabel.Font = Enum.Font.GothamMedium
	oilLabel.TextSize = 16
	oilLabel.TextColor3 = Color3.fromRGB(220, 220, 220)
	oilLabel.TextStrokeTransparency = 0
	oilLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	oilLabel.Text = oilSummary
	oilLabel.ZIndex = 3
	oilLabel.TextScaled = false
	oilLabel.TextTruncate = Enum.TextTruncate.AtEnd
	oilLabel.Parent = card

	-- ── Production rate ──
	local bpsLabel = Instance.new("TextLabel")
	bpsLabel.Name = "BpsLabel"
	bpsLabel.Size = UDim2.new(0.92, 0, 0, 22)
	bpsLabel.AnchorPoint = Vector2.new(0.5, 0)
	bpsLabel.Position = UDim2.new(0.5, 0, 0.17, 0)
	bpsLabel.BackgroundTransparency = 1
	bpsLabel.Font = Enum.Font.GothamBold
	bpsLabel.TextSize = 18
	bpsLabel.TextColor3 = Color3.fromRGB(255, 255, 0)
	bpsLabel.TextStrokeTransparency = 0
	bpsLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	bpsLabel.Text = string.format("%.4g bbl/s", veinType.barrelsPerSecond)
	bpsLabel.ZIndex = 3
	bpsLabel.Parent = card

	-- ── Rarity label at bottom ──
	local rarityLabel = Instance.new("TextLabel")
	rarityLabel.Name = "RarityLabel"
	rarityLabel.Size = UDim2.new(0.92, 0, 0, 32)
	rarityLabel.AnchorPoint = Vector2.new(0.5, 1)
	rarityLabel.Position = UDim2.new(0.5, 0, 0.97, 0)
	rarityLabel.BackgroundTransparency = 1
	rarityLabel.Font = Enum.Font.GothamBold
	rarityLabel.TextSize = 26
	rarityLabel.TextColor3 = rarityStyle.text
	rarityLabel.TextStrokeTransparency = 0
	rarityLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	rarityLabel.Text = veinType.rarity
	rarityLabel.ZIndex = 3
	rarityLabel.Parent = card

	card.Parent = parent
	return card
end

-- ═══════════════════════════════════════════════════════════
-- Open the crate UI
-- ═══════════════════════════════════════════════════════════

function VeinCrateOpener.Open(winnerId: string, groundType: string, callback: (() -> ())?)
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

	preloadSpritesForPool(pool, winnerDef, groundType)

	-- ── ScreenGui ──
	local gui = Instance.new("ScreenGui")
	gui.Name = "VeinCrateGui"
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 200
	gui.ResetOnSpawn = false
	gui.Parent = playerGui

	-- ── Dark overlay ──
	local overlay = Instance.new("Frame")
	overlay.Name = "Overlay"
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	overlay.BackgroundTransparency = 0.35
	overlay.BorderSizePixel = 0
	overlay.Parent = gui

	-- ── Center container (slightly above center) ──
	local CENTER_TOTAL_H = 60 + 10 + 36 + 10 + CARD_HEIGHT + 20 + 50
	local centerFrame = Instance.new("Frame")
	centerFrame.Name = "CenterFrame"
	centerFrame.Size = UDim2.fromOffset(STRIP_WIDTH + 100, CENTER_TOTAL_H)
	centerFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	centerFrame.Position = UDim2.new(0.5, 0, 0.45, 0)
	centerFrame.BackgroundTransparency = 1
	centerFrame.Parent = overlay

	-- ── Title ──
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, 0, 0, 60)
	title.AnchorPoint = Vector2.new(0.5, 0)
	title.Position = UDim2.new(0.5, 0, 0, 0)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 52
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.TextStrokeTransparency = 0
	title.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	title.Text = "Opening Crate"
	title.ZIndex = 2
	title.Parent = centerFrame

	-- ── Red pointer triangle ──
	local pointerContainer = Instance.new("Frame")
	pointerContainer.Name = "Pointer"
	pointerContainer.Size = UDim2.fromOffset(50, 40)
	pointerContainer.AnchorPoint = Vector2.new(0.5, 0)
	pointerContainer.Position = UDim2.new(0.5, 0, 0, 70)
	pointerContainer.BackgroundTransparency = 1
	pointerContainer.ZIndex = 5
	pointerContainer.Parent = centerFrame

	local pointerTri = Instance.new("Frame")
	pointerTri.Size = UDim2.fromOffset(36, 36)
	pointerTri.AnchorPoint = Vector2.new(0.5, 0)
	pointerTri.Position = UDim2.new(0.5, 0, 0, 0)
	pointerTri.BackgroundColor3 = Color3.fromRGB(220, 20, 20)
	pointerTri.Rotation = 45
	pointerTri.BorderSizePixel = 0
	pointerTri.ZIndex = 5
	pointerTri.Parent = pointerContainer

	local pointerCorner = Instance.new("UICorner")
	pointerCorner.CornerRadius = UDim.new(0, 4)
	pointerCorner.Parent = pointerTri

	-- ── Card strip container ──
	local stripContainer = Instance.new("Frame")
	stripContainer.Name = "StripContainer"
	stripContainer.Size = UDim2.fromOffset(STRIP_WIDTH, CARD_HEIGHT)
	stripContainer.AnchorPoint = Vector2.new(0.5, 0)
	stripContainer.Position = UDim2.new(0.5, 0, 0, 106)
	stripContainer.BackgroundTransparency = 1
	stripContainer.ClipsDescendants = true
	stripContainer.ZIndex = 2
	stripContainer.Parent = centerFrame

	-- Inner scrolling strip
	local strip = Instance.new("Frame")
	strip.Name = "Strip"
	strip.BackgroundTransparency = 1
	strip.ZIndex = 2
	strip.Parent = stripContainer

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, CARD_GAP)
	layout.Parent = strip

	-- Build card sequence
	local TOTAL_CARDS = 60
	local WINNER_INDEX = TOTAL_CARDS - 2

	local cards = {}
	for i = 1, TOTAL_CARDS do
		local vt
		if i == WINNER_INDEX then
			vt = winnerDef
		else
			vt = pool[((i - 1) % #pool) + 1]
		end
		local card = createCard(vt, groundType, strip)
		card.LayoutOrder = i
		table.insert(cards, { frame = card, def = vt })
	end

	local totalWidth = TOTAL_CARDS * (CARD_WIDTH + CARD_GAP)
	strip.Size = UDim2.fromOffset(totalWidth, CARD_HEIGHT)
	strip.Position = UDim2.fromOffset(0, 0)

	-- Target: winner card centered under pointer
	local winnerCardLeft = (WINNER_INDEX - 1) * (CARD_WIDTH + CARD_GAP)
	local targetX = -(winnerCardLeft - STRIP_WIDTH / 2 + CARD_WIDTH / 2)

	-- ── Skip button (during spin) ──
	local skipBtn = Instance.new("TextButton")
	skipBtn.Name = "SkipButton"
	skipBtn.Size = UDim2.fromOffset(200, 50)
	skipBtn.AnchorPoint = Vector2.new(0.5, 0)
	skipBtn.Position = UDim2.new(0.5, 0, 0, 106 + CARD_HEIGHT + 16)
	skipBtn.BackgroundColor3 = Color3.fromRGB(200, 40, 40)
	skipBtn.BorderSizePixel = 0
	skipBtn.Font = Enum.Font.GothamBold
	skipBtn.TextSize = 28
	skipBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	skipBtn.TextStrokeTransparency = 0
	skipBtn.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	skipBtn.Text = "SKIP"
	skipBtn.ZIndex = 3
	skipBtn.Parent = centerFrame

	local skipCorner = Instance.new("UICorner")
	skipCorner.CornerRadius = UDim.new(0, 10)
	skipCorner.Parent = skipBtn

	local skipStroke = Instance.new("UIStroke")
	skipStroke.Thickness = 3
	skipStroke.Color = Color3.fromRGB(255, 80, 80)
	skipStroke.Parent = skipBtn

	-- Animation state
	local skipped = false
	local dismissed = false

	skipBtn.MouseButton1Click:Connect(function()
		if not skipped then
			skipped = true
		else
			dismissed = true
		end
	end)

	-- Animate the spin
	task.spawn(function()
		local t0 = os.clock()

		while not skipped do
			local elapsed = os.clock() - t0
			if elapsed >= SPIN_DURATION then break end

			local alpha = elapsed / SPIN_DURATION
			local eased = 1 - (1 - alpha) ^ 3
			local x = (targetX) * eased
			strip.Position = UDim2.fromOffset(math.floor(x), 0)
			task.wait()
		end

		-- Snap to winner
		strip.Position = UDim2.fromOffset(math.floor(targetX), 0)

		-- Highlight winner card
		local winnerCard = cards[WINNER_INDEX]
		if winnerCard then
			local glow = Instance.new("UIStroke")
			glow.Thickness = 6
			glow.Color = Color3.fromRGB(255, 255, 0)
			glow.Parent = winnerCard.frame

			local pulseTween = TweenService:Create(
				winnerCard.frame,
				TweenInfo.new(0.3, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, 2, true),
				{ Size = UDim2.fromOffset(CARD_WIDTH + 14, CARD_HEIGHT + 14) }
			)
			pulseTween:Play()
		end

		-- Change button to NEXT — player must click to dismiss
		skipBtn.Text = "NEXT"
		skipBtn.BackgroundColor3 = Color3.fromRGB(40, 160, 40)
		skipStroke.Color = Color3.fromRGB(80, 255, 80)

		-- Wait for player to click NEXT
		while not dismissed do
			task.wait()
		end

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
