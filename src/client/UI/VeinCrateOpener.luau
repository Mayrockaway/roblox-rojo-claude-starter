--!strict
-- VeinCrateOpener: full-screen crate opening UI with spinning card carousel.

local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local HeavenRewardConfig = require(Shared:WaitForChild("Config"):WaitForChild("HeavenRewardConfig"))
local VeinCrateConfig = require(Shared:WaitForChild("Config"):WaitForChild("VeinCrateConfig"))

local ClientAudioPreferences = require(script.Parent.Parent:WaitForChild("ClientAudioPreferences"))
--- Register the crate-opening ScreenGui with `HudMousePolicy` so the Skip button is
--- clickable when the crate triggers from first-person zoom.
local HudMousePolicy = require(script.Parent:WaitForChild("HudMousePolicy"))

--- Per-card tick (one play each time a card crosses the center pointer — naturally syncs with the
--- cubic ease-out: fast at the start, slowing toward the winner). Resolve plays once on snap.
local TICK_SOUND_ID = "rbxassetid://132417511885299"
local TICK_VOLUME = 0.15
local RESOLVE_SOUND_ID = "rbxassetid://102778985624056"
local RESOLVE_VOLUME = 0.2125

local function playOneShotSfx(soundId: string, volume: number)
	if not ClientAudioPreferences.isSfxEnabled() then
		return
	end
	local s = Instance.new("Sound")
	s.Name = "VeinCrateSfx"
	s.SoundId = soundId
	s.Volume = volume
	s.Looped = false
	s.RollOffMode = Enum.RollOffMode.Linear
	s.Parent = SoundService
	s.Ended:Once(function()
		if s.Parent then
			s:Destroy()
		end
	end)
	pcall(function()
		s.TimePosition = 0
	end)
	s:Play()
	--- Hard-cap cleanup in case `Ended` never fires (asset failed to stream).
	task.delay(3, function()
		if s.Parent then
			s:Destroy()
		end
	end)
end

local VeinCrateOpener = {}

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local _preloadDone = true

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
	-- Also preload rarity background images
	for _, rarity in ipairs(VeinCrateConfig.RarityOrder) do
		local bgId = VeinCrateConfig.RarityBackgroundAssets and VeinCrateConfig.RarityBackgroundAssets[rarity]
		if typeof(bgId) == "string" and bgId ~= "" and bgId ~= "rbxassetid://0" and not uniqueIds[bgId] then
			uniqueIds[bgId] = true
			table.insert(orderedIds, bgId)
		end
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

-- Static crate art and SFX are pre-warmed by LoadingBootstrap. The per-open
-- helper below remains as a fallback for any future dynamic pool-only media.

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
		bgImg.ZIndex = 1
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
		img.ZIndex = 2
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

	-- ── Vein count header at top ──
	local streamCount = veinType.streamCount or #veinType.streams
	local veinLabel = Instance.new("TextLabel")
	veinLabel.Name = "VeinLabel"
	veinLabel.Size = UDim2.new(0.92, 0, 0, 34)
	veinLabel.AnchorPoint = Vector2.new(0.5, 0)
	veinLabel.Position = UDim2.new(0.5, 0, 0.02, 0)
	veinLabel.BackgroundTransparency = 1
	veinLabel.Font = Enum.Font.GothamBold
	veinLabel.TextSize = 28
	veinLabel.TextStrokeTransparency = 0
	veinLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	veinLabel.ZIndex = 3
	veinLabel.Parent = card
	if streamCount >= 3 then
		veinLabel.Text = "TRIPLE VEIN!!!"
		veinLabel.TextColor3 = Color3.fromRGB(255, 170, 60)
	elseif streamCount >= 2 then
		veinLabel.Text = "DOUBLE VEIN!!"
		veinLabel.TextColor3 = Color3.fromRGB(180, 80, 255)
	else
		veinLabel.Text = "SINGLE VEIN"
		veinLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	end

	-- ── Oil stream columns (side by side, centered) ──
	local OIL_DISPLAY = { DirtOil = "Crude", GoodOil = "Refined", GoldOil = "Premium" }
	local OIL_COLOR = {
		DirtOil = Color3.fromRGB(200, 200, 200),
		GoodOil = Color3.fromRGB(240, 200, 70),
		GoldOil = Color3.fromRGB(255, 150, 200),
	}
	-- Best possible bps for color scaling (Geyser = 0.08)
	local MAX_BPS = 0.08
	-- Scale sizes based on how many streams need to fit
	local COL_FRAC = if streamCount >= 3 then 0.30 elseif streamCount >= 2 then 0.44 else 0.85
	local NAME_SIZE = if streamCount >= 3 then 18 elseif streamCount >= 2 then 24 else 30
	local RATE_SIZE = if streamCount >= 3 then 14 elseif streamCount >= 2 then 18 else 24
	local NAME_H = if streamCount >= 3 then 24 elseif streamCount >= 2 then 30 else 36
	local RATE_H = if streamCount >= 3 then 20 elseif streamCount >= 2 then 24 else 30
	local COL_GAP = if streamCount >= 3 then 4 else 8
	local COL_WIDTH = math.floor(CARD_WIDTH * COL_FRAC)
	local totalColWidth = streamCount * COL_WIDTH + (streamCount - 1) * COL_GAP
	local startX = (CARD_WIDTH - totalColWidth) / 2

	for i, stream in ipairs(veinType.streams) do
		local oilName = OIL_DISPLAY[stream.oilType] or stream.oilType
		local colX = startX + (i - 1) * (COL_WIDTH + COL_GAP)
		local bps = stream.barrelsPerSecond or 0

		-- Oil type name
		local oilNameLbl = Instance.new("TextLabel")
		oilNameLbl.Name = "OilName_" .. i
		oilNameLbl.Size = UDim2.fromOffset(COL_WIDTH, NAME_H)
		oilNameLbl.Position = UDim2.fromOffset(colX, CARD_HEIGHT * 0.14)
		oilNameLbl.BackgroundTransparency = 1
		oilNameLbl.Font = Enum.Font.GothamBold
		oilNameLbl.TextSize = NAME_SIZE
		oilNameLbl.TextColor3 = OIL_COLOR[stream.oilType] or Color3.fromRGB(255, 255, 255)
		oilNameLbl.TextStrokeTransparency = 0
		oilNameLbl.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
		oilNameLbl.Text = oilName .. " Oil"
		oilNameLbl.ZIndex = 3
		oilNameLbl.Parent = card

		-- Rate with color based on quality
		local ratio = math.clamp(bps / MAX_BPS, 0, 1)
		local rateColor
		if ratio >= 0.8 then
			rateColor = Color3.fromRGB(255, 170, 60)
		elseif ratio >= 0.5 then
			rateColor = Color3.fromRGB(80, 255, 80)
		elseif ratio >= 0.2 then
			rateColor = Color3.fromRGB(255, 255, 0)
		else
			rateColor = Color3.fromRGB(255, 255, 255)
		end

		local secsPerBarrel = if bps > 0 then 1 / bps else 999
		local rateLbl = Instance.new("TextLabel")
		rateLbl.Name = "Rate_" .. i
		rateLbl.Size = UDim2.fromOffset(COL_WIDTH, RATE_H)
		rateLbl.Position = UDim2.fromOffset(colX, CARD_HEIGHT * 0.14 + NAME_H + 2)
		rateLbl.BackgroundTransparency = 1
		rateLbl.Font = Enum.Font.GothamMedium
		rateLbl.TextSize = RATE_SIZE
		rateLbl.TextColor3 = rateColor
		rateLbl.TextStrokeTransparency = 0
		rateLbl.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
		rateLbl.Text = string.format("1 bbl / %.0fs", secsPerBarrel)
		rateLbl.ZIndex = 3
		rateLbl.Parent = card
	end

	-- ── Rarity label at bottom ──
	local rarityLabel = Instance.new("TextLabel")
	rarityLabel.Name = "RarityLabel"
	rarityLabel.Size = UDim2.new(0.92, 0, 0, 38)
	rarityLabel.AnchorPoint = Vector2.new(0.5, 1)
	rarityLabel.Position = UDim2.new(0.5, 0, 0.97, 0)
	rarityLabel.BackgroundTransparency = 1
	rarityLabel.Font = Enum.Font.GothamBold
	rarityLabel.TextSize = 30
	rarityLabel.TextColor3 = rarityStyle.text
	rarityLabel.TextStrokeTransparency = 0
	rarityLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	rarityLabel.Text = veinType.rarity
	rarityLabel.ZIndex = 3
	rarityLabel.Parent = card

	-- ── Animate vein label for Double/Triple ──
	if streamCount >= 2 then
		task.spawn(function()
			local baseRot = 0
			local amplitude = if streamCount >= 3 then 6 else 3
			local speed = if streamCount >= 3 then 8 else 5
			while veinLabel and veinLabel.Parent do
				baseRot = baseRot + speed * task.wait()
				veinLabel.Rotation = math.sin(baseRot) * amplitude
				-- Rainbow cycling for triple
				if streamCount >= 3 then
					local hue = (os.clock() * 0.5) % 1
					veinLabel.TextColor3 = Color3.fromHSV(hue, 1, 1)
				end
			end
		end)
	end

	card.Parent = parent
	return card
end

local HEAVEN_REWARD_BG_RARITY_BY_TIER = {
	T1 = "Common",
	T2 = "Rare",
	T3 = "Epic",
	T4 = "Legendary",
}

local function getHeavenRewardBackgroundAsset(rarity: string): string?
	local tier = HeavenRewardConfig.GetVisualTierForRarity(rarity)
	local backgroundRarity = HEAVEN_REWARD_BG_RARITY_BY_TIER[tier] or "Common"
	return VeinCrateConfig.RarityBackgroundAssets[backgroundRarity]
end

local function getHeavenRewardFallbackText(category: string): string
	if category == "ShipSpeed" then
		return "SPD"
	elseif category == "GoldEarnPct" then
		return "EARN"
	elseif category == "WarehouseCapacity" then
		return "CAP"
	elseif category == "LuckPct" then
		return "LUCK"
	end
	return "BONUS"
end

local function createHeavenRewardCard(reward: any, parent: Instance): Frame
	local rarity = tostring(reward.rarity or "Common")
	local rarityStyle = VeinCrateConfig.GetRarityStyle(rarity)
	local category = tostring(reward.category or "")

	local card = Instance.new("Frame")
	card.Name = "HeavenRewardCard_" .. tostring(reward.rewardId or "Reward")
	card.Size = UDim2.fromOffset(CARD_WIDTH, CARD_HEIGHT)
	card.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
	card.BorderSizePixel = 0

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 16)
	corner.Parent = card

	local bgAssetId = getHeavenRewardBackgroundAsset(rarity)
	if bgAssetId and bgAssetId ~= "" and bgAssetId ~= "rbxassetid://0" then
		local bgImg = Instance.new("ImageLabel")
		bgImg.Name = "RarityBG"
		bgImg.Size = UDim2.fromScale(1, 1)
		bgImg.BackgroundTransparency = 1
		bgImg.ZIndex = 1
		bgImg.ScaleType = Enum.ScaleType.Stretch
		bgImg.Image = bgAssetId
		bgImg.Parent = card
	end

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(0.92, 0, 0, 36)
	title.AnchorPoint = Vector2.new(0.5, 0)
	title.Position = UDim2.new(0.5, 0, 0.085, 0)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 30
	title.TextStrokeTransparency = 0
	title.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.Text = tostring(reward.title or "Heaven Bonus")
	title.ZIndex = 3
	title.Parent = card

	local subtitle = Instance.new("TextLabel")
	subtitle.Name = "Subtitle"
	subtitle.Size = UDim2.new(0.92, 0, 0, 28)
	subtitle.AnchorPoint = Vector2.new(0.5, 0)
	subtitle.Position = UDim2.new(0.5, 0, 0.215, 0)
	subtitle.BackgroundTransparency = 1
	subtitle.Font = Enum.Font.GothamMedium
	subtitle.TextSize = 22
	subtitle.TextStrokeTransparency = 0
	subtitle.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	subtitle.TextColor3 = Color3.fromRGB(235, 238, 245)
	subtitle.Text = "HEAVEN PASSIVE BONUS"
	subtitle.ZIndex = 3
	subtitle.Parent = card

	local iconAssetId = HeavenRewardConfig.GetRewardIconAsset(category, rarity)
	if typeof(iconAssetId) == "string" and iconAssetId ~= "" and iconAssetId ~= "rbxassetid://0" then
		local icon = Instance.new("ImageLabel")
		icon.Name = "Icon"
		icon.Size = UDim2.fromOffset(275, 160)
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
		icon.Position = UDim2.new(0.5, 0, 0.53, 0)
		icon.BackgroundTransparency = 1
		icon.ScaleType = Enum.ScaleType.Fit
		icon.Image = iconAssetId
		icon.ZIndex = 3
		icon.Parent = card
	else
		local icon = Instance.new("TextLabel")
		icon.Name = "Icon"
		icon.Size = UDim2.fromOffset(225, 88)
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
		icon.Position = UDim2.new(0.5, 0, 0.53, 0)
		icon.BackgroundTransparency = 1
		icon.Font = Enum.Font.GothamBlack
		icon.TextSize = 55
		icon.TextStrokeTransparency = 0
		icon.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
		icon.TextColor3 = rarityStyle.text
		icon.Text = getHeavenRewardFallbackText(category)
		icon.ZIndex = 3
		icon.Parent = card
	end

	local rewardLabel = Instance.new("TextLabel")
	rewardLabel.Name = "RewardText"
	rewardLabel.Size = UDim2.new(0.88, 0, 0.14, 0)
	rewardLabel.AnchorPoint = Vector2.new(0.5, 0)
	rewardLabel.Position = UDim2.new(0.5, 0, 0.73, 0)
	rewardLabel.BackgroundTransparency = 1
	rewardLabel.Font = Enum.Font.GothamBold
	rewardLabel.TextSize = 25
	rewardLabel.TextWrapped = true
	rewardLabel.TextStrokeTransparency = 0
	rewardLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	rewardLabel.TextColor3 = rarityStyle.text
	rewardLabel.Text = tostring(reward.displayText or "?")
	rewardLabel.ZIndex = 3
	rewardLabel.Parent = card

	local rarityLabel = Instance.new("TextLabel")
	rarityLabel.Name = "RarityLabel"
	rarityLabel.Size = UDim2.new(0.92, 0, 0, 38)
	rarityLabel.AnchorPoint = Vector2.new(0.5, 1)
	rarityLabel.Position = UDim2.new(0.5, 0, 0.97, 0)
	rarityLabel.BackgroundTransparency = 1
	rarityLabel.Font = Enum.Font.GothamBold
	rarityLabel.TextSize = 30
	rarityLabel.TextColor3 = rarityStyle.text
	rarityLabel.TextStrokeTransparency = 0
	rarityLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	rarityLabel.Text = rarity
	rarityLabel.ZIndex = 3
	rarityLabel.Parent = card

	card.Parent = parent
	return card
end

local function preloadHeavenRewards(pool: { any })
	local uniqueIds = {}
	local orderedIds = {}
	for _, reward in ipairs(pool) do
		local rarity = tostring(reward.rarity or "Common")
		local category = tostring(reward.category or "")
		local bgId = getHeavenRewardBackgroundAsset(rarity)
		if typeof(bgId) == "string" and bgId ~= "" and bgId ~= "rbxassetid://0" and not uniqueIds[bgId] then
			uniqueIds[bgId] = true
			table.insert(orderedIds, bgId)
		end
		local iconAssetId = HeavenRewardConfig.GetRewardIconAsset(category, rarity)
		if typeof(iconAssetId) == "string" and iconAssetId ~= "" and iconAssetId ~= "rbxassetid://0" and not uniqueIds[iconAssetId] then
			uniqueIds[iconAssetId] = true
			table.insert(orderedIds, iconAssetId)
		end
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

	if not _preloadDone then
		preloadSpritesForPool(pool, winnerDef, groundType)
	end

	-- ── ScreenGui ──
	local gui = Instance.new("ScreenGui")
	gui.Name = "VeinCrateGui"
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 200
	gui.ResetOnSpawn = false
	gui.Parent = playerGui
	HudMousePolicy.RegisterScreenGui(gui)

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

	-- ── Responsive scaling (Option B fit-to-viewport) ──
	-- The whole shell (title, pointer, 60-card strip, skip/next button) is
	-- authored in fixed pixel offsets totalling roughly `STRIP_WIDTH + 100`
	-- × `CENTER_TOTAL_H` ≈ 1580 × 544. On a phone the viewport can be 600
	-- px wide and the strip overflows ~2.5×, breaking the entire reveal.
	-- A `UIScale` on `centerFrame` is a render-time uniform multiplier:
	-- it shrinks every child proportionally without touching layout math
	-- or input hit-testing, so the existing spin tween, ratchet tick math
	-- (`(-x + STRIP_WIDTH/2) / PITCH`), and click handlers all keep
	-- working unchanged. Reference box = the actual `centerFrame` size; we
	-- target ~92 % viewport utilization on the limiting axis and never
	-- scale above 1 (desktop / large monitors keep the authored size).
	-- Re-bound on `ViewportSize` change so device-rotation / window-resize
	-- / Studio device emulator re-fit live without reopening the crate.
	local crateScale = Instance.new("UIScale")
	crateScale.Name = "ResponsiveScale"
	crateScale.Parent = centerFrame
	local REF_W = STRIP_WIDTH + 100
	local REF_H = CENTER_TOTAL_H
	local FIT_FRACTION = 0.92
	local function applyResponsiveScale()
		local cam = Workspace.CurrentCamera
		if not cam then return end
		local vp = cam.ViewportSize
		if vp.X <= 0 or vp.Y <= 0 then return end
		local sx = (vp.X * FIT_FRACTION) / REF_W
		local sy = (vp.Y * FIT_FRACTION) / REF_H
		crateScale.Scale = math.min(1, math.min(sx, sy))
	end
	applyResponsiveScale()
	local viewportConn: RBXScriptConnection? = nil
	local cam0 = Workspace.CurrentCamera
	if cam0 then
		viewportConn = cam0:GetPropertyChangedSignal("ViewportSize"):Connect(applyResponsiveScale)
	end
	-- Detach the camera signal when the crate GUI tears down, so the
	-- viewport listener does not outlive the UI it was driving.
	gui.AncestryChanged:Connect(function(_, parent)
		if parent == nil and viewportConn then
			viewportConn:Disconnect()
			viewportConn = nil
		end
	end)

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
	--- Text rendering moved to an inner TextLabel so we can attach a real UIStroke around the
	--- glyphs (a UIStroke parented to this TextButton outlines the rectangle, not the font).
	skipBtn.Text = ""
	skipBtn.AutoButtonColor = true
	skipBtn.ZIndex = 3
	skipBtn.Parent = centerFrame

	local skipCorner = Instance.new("UICorner")
	skipCorner.CornerRadius = UDim.new(0, 10)
	skipCorner.Parent = skipBtn

	local skipStroke = Instance.new("UIStroke")
	skipStroke.Thickness = 3
	skipStroke.Color = Color3.fromRGB(255, 80, 80)
	skipStroke.Parent = skipBtn

	local skipLabel = Instance.new("TextLabel")
	skipLabel.Name = "Label"
	skipLabel.Size = UDim2.fromScale(1, 1)
	skipLabel.BackgroundTransparency = 1
	skipLabel.Font = Enum.Font.GothamBold
	skipLabel.TextSize = 28
	skipLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	skipLabel.Text = "SKIP"
	skipLabel.ZIndex = 4
	skipLabel.Parent = skipBtn

	local skipLabelStroke = Instance.new("UIStroke")
	skipLabelStroke.Name = "TextStroke"
	skipLabelStroke.Thickness = 2
	skipLabelStroke.Color = Color3.fromRGB(0, 0, 0)
	skipLabelStroke.LineJoinMode = Enum.LineJoinMode.Round
	skipLabelStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	skipLabelStroke.Parent = skipLabel

	-- Animation state
	local skipped = false
	local dismissed = false
	--- After the spin resolves, the same button becomes "NEXT". Without this, `skipped` is still
	--- false if the player never pressed SKIP — first click wrongly sets `skipped` instead of
	--- `dismissed`, so NEXT takes two clicks.
	local awaitingDismiss = false

	skipBtn.MouseButton1Click:Connect(function()
		if awaitingDismiss then
			dismissed = true
			return
		end
		if not skipped then
			skipped = true
		end
	end)

	-- Animate the spin
	task.spawn(function()
		local t0 = os.clock()

		--- Ratchet tick: fire `TICK_SOUND_ID` each time the card under the pointer changes. The
		--- pointer sits at `STRIP_WIDTH / 2` in container space; with strip offset `X` (negative
		--- and growing more negative), the card index under it is `floor((-X + STRIP_WIDTH/2) / pitch)`.
		--- Because `X` follows the cubic ease-out, ticks come fast at first and slow toward the snap —
		--- exactly synced to the visual speed of cards flying by.
		local PITCH = CARD_WIDTH + CARD_GAP
		local lastTickIndex = -1

		while not skipped do
			local elapsed = os.clock() - t0
			if elapsed >= SPIN_DURATION then break end

			local alpha = elapsed / SPIN_DURATION
			local eased = 1 - (1 - alpha) ^ 3
			local x = (targetX) * eased
			strip.Position = UDim2.fromOffset(math.floor(x), 0)

			local idx = math.floor((-x + STRIP_WIDTH / 2) / PITCH)
			if idx ~= lastTickIndex then
				lastTickIndex = idx
				playOneShotSfx(TICK_SOUND_ID, TICK_VOLUME)
			end

			task.wait()
		end

		-- Snap to winner
		strip.Position = UDim2.fromOffset(math.floor(targetX), 0)

		--- Resolve cue — plays once on snap (also when the player presses SKIP, since the snap still
		--- happens). Slight delay so it doesn't pile on top of the final tick.
		playOneShotSfx(RESOLVE_SOUND_ID, RESOLVE_VOLUME)

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
		awaitingDismiss = true
		skipLabel.Text = "NEXT"
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

function VeinCrateOpener.OpenHeavenReward(
	winnerReward: any,
	allRewards: { any }?,
	options: { onNext: (() -> ())?, onDoubleReward: (() -> ())?, doubleButtonText: string? }?
)
	local existing = playerGui:FindFirstChild("VeinCrateGui")
	if existing then existing:Destroy() end

	if typeof(winnerReward) ~= "table" then
		warn("[VeinCrateOpener] Bad Heaven reward payload.")
		if options and options.onNext then
			options.onNext()
		end
		return
	end

	local pool = if typeof(allRewards) == "table" and #allRewards > 0 then allRewards else { winnerReward }
	preloadHeavenRewards(pool)

	local gui = Instance.new("ScreenGui")
	gui.Name = "VeinCrateGui"
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 200
	gui.ResetOnSpawn = false
	gui.Parent = playerGui
	HudMousePolicy.RegisterScreenGui(gui)

	local overlay = Instance.new("Frame")
	overlay.Name = "Overlay"
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	overlay.BackgroundTransparency = 0.35
	overlay.BorderSizePixel = 0
	overlay.Parent = gui

	local CENTER_TOTAL_H = 60 + 10 + 36 + 10 + CARD_HEIGHT + 20 + 50 + 66
	local centerFrame = Instance.new("Frame")
	centerFrame.Name = "CenterFrame"
	centerFrame.Size = UDim2.fromOffset(STRIP_WIDTH + 100, CENTER_TOTAL_H)
	centerFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	centerFrame.Position = UDim2.new(0.5, 0, 0.45, 0)
	centerFrame.BackgroundTransparency = 1
	centerFrame.Parent = overlay

	local crateScale = Instance.new("UIScale")
	crateScale.Name = "ResponsiveScale"
	crateScale.Parent = centerFrame
	local REF_W = STRIP_WIDTH + 100
	local REF_H = CENTER_TOTAL_H
	local FIT_FRACTION = 0.92
	local function applyResponsiveScale()
		local cam = Workspace.CurrentCamera
		if not cam then return end
		local vp = cam.ViewportSize
		if vp.X <= 0 or vp.Y <= 0 then return end
		local sx = (vp.X * FIT_FRACTION) / REF_W
		local sy = (vp.Y * FIT_FRACTION) / REF_H
		crateScale.Scale = math.min(1, math.min(sx, sy))
	end
	applyResponsiveScale()
	local viewportConn: RBXScriptConnection? = nil
	local cam0 = Workspace.CurrentCamera
	if cam0 then
		viewportConn = cam0:GetPropertyChangedSignal("ViewportSize"):Connect(applyResponsiveScale)
	end
	gui.AncestryChanged:Connect(function(_, parent)
		if parent == nil and viewportConn then
			viewportConn:Disconnect()
			viewportConn = nil
		end
	end)

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
	title.Text = "Heaven Reward"
	title.ZIndex = 2
	title.Parent = centerFrame

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

	local stripContainer = Instance.new("Frame")
	stripContainer.Name = "StripContainer"
	stripContainer.Size = UDim2.fromOffset(STRIP_WIDTH, CARD_HEIGHT)
	stripContainer.AnchorPoint = Vector2.new(0.5, 0)
	stripContainer.Position = UDim2.new(0.5, 0, 0, 106)
	stripContainer.BackgroundTransparency = 1
	stripContainer.ClipsDescendants = true
	stripContainer.ZIndex = 2
	stripContainer.Parent = centerFrame

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

	local TOTAL_CARDS = 60
	local WINNER_INDEX = TOTAL_CARDS - 2
	local cards = {}
	for i = 1, TOTAL_CARDS do
		local reward = if i == WINNER_INDEX then winnerReward else pool[((i - 1) % #pool) + 1]
		local card = createHeavenRewardCard(reward, strip)
		card.LayoutOrder = i
		table.insert(cards, { frame = card, def = reward })
	end

	local totalWidth = TOTAL_CARDS * (CARD_WIDTH + CARD_GAP)
	strip.Size = UDim2.fromOffset(totalWidth, CARD_HEIGHT)
	strip.Position = UDim2.fromOffset(0, 0)

	local winnerCardLeft = (WINNER_INDEX - 1) * (CARD_WIDTH + CARD_GAP)
	local targetX = -(winnerCardLeft - STRIP_WIDTH / 2 + CARD_WIDTH / 2)

	local nextBtn = Instance.new("TextButton")
	nextBtn.Name = "NextButton"
	nextBtn.Size = UDim2.fromOffset(200, 50)
	nextBtn.AnchorPoint = Vector2.new(0.5, 0)
	nextBtn.Position = UDim2.new(0.5, 0, 0, 106 + CARD_HEIGHT + 16)
	nextBtn.BackgroundColor3 = Color3.fromRGB(200, 40, 40)
	nextBtn.BorderSizePixel = 0
	nextBtn.Text = ""
	nextBtn.AutoButtonColor = true
	nextBtn.ZIndex = 3
	nextBtn.Parent = centerFrame

	local nextCorner = Instance.new("UICorner")
	nextCorner.CornerRadius = UDim.new(0, 10)
	nextCorner.Parent = nextBtn

	local nextStroke = Instance.new("UIStroke")
	nextStroke.Thickness = 3
	nextStroke.Color = Color3.fromRGB(255, 80, 80)
	nextStroke.Parent = nextBtn

	local nextLabel = Instance.new("TextLabel")
	nextLabel.Name = "Label"
	nextLabel.Size = UDim2.fromScale(1, 1)
	nextLabel.BackgroundTransparency = 1
	nextLabel.Font = Enum.Font.GothamBold
	nextLabel.TextSize = 28
	nextLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	nextLabel.Text = "SKIP"
	nextLabel.ZIndex = 4
	nextLabel.Parent = nextBtn

	local nextLabelStroke = Instance.new("UIStroke")
	nextLabelStroke.Name = "TextStroke"
	nextLabelStroke.Thickness = 2
	nextLabelStroke.Color = Color3.fromRGB(0, 0, 0)
	nextLabelStroke.LineJoinMode = Enum.LineJoinMode.Round
	nextLabelStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	nextLabelStroke.Parent = nextLabel

	local doubleBtn: TextButton? = nil
	if options and options.onDoubleReward then
		doubleBtn = Instance.new("TextButton")
		doubleBtn.Name = "DoubleRewardButton"
		doubleBtn.Size = UDim2.fromOffset(280, 50)
		doubleBtn.AnchorPoint = Vector2.new(0.5, 0)
		doubleBtn.Position = UDim2.new(0.5, 0, 0, 106 + CARD_HEIGHT + 74)
		doubleBtn.BackgroundColor3 = Color3.fromRGB(125, 83, 18)
		doubleBtn.BorderSizePixel = 0
		doubleBtn.Text = ""
		doubleBtn.AutoButtonColor = true
		doubleBtn.Visible = false
		doubleBtn.ZIndex = 3
		doubleBtn.Parent = centerFrame

		local doubleCorner = Instance.new("UICorner")
		doubleCorner.CornerRadius = UDim.new(0, 10)
		doubleCorner.Parent = doubleBtn

		local doubleStroke = Instance.new("UIStroke")
		doubleStroke.Thickness = 3
		doubleStroke.Color = Color3.fromRGB(255, 211, 109)
		doubleStroke.Parent = doubleBtn

		local doubleLabel = Instance.new("TextLabel")
		doubleLabel.Name = "Label"
		doubleLabel.Size = UDim2.fromScale(1, 1)
		doubleLabel.BackgroundTransparency = 1
		doubleLabel.Font = Enum.Font.GothamBold
		doubleLabel.TextSize = 24
		doubleLabel.TextColor3 = Color3.fromRGB(255, 245, 210)
		doubleLabel.Text = options.doubleButtonText or "2X REWARD - 100 ROBUX"
		doubleLabel.ZIndex = 4
		doubleLabel.Parent = doubleBtn

		local doubleLabelStroke = Instance.new("UIStroke")
		doubleLabelStroke.Name = "TextStroke"
		doubleLabelStroke.Thickness = 2
		doubleLabelStroke.Color = Color3.fromRGB(0, 0, 0)
		doubleLabelStroke.LineJoinMode = Enum.LineJoinMode.Round
		doubleLabelStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		doubleLabelStroke.Parent = doubleLabel
	end

	local skipped = false
	local dismissed = false
	local awaitingDismiss = false

	nextBtn.MouseButton1Click:Connect(function()
		if awaitingDismiss then
			dismissed = true
			return
		end
		if not skipped then
			skipped = true
		end
	end)

	if doubleBtn and options and options.onDoubleReward then
		doubleBtn.MouseButton1Click:Connect(function()
			options.onDoubleReward()
		end)
	end

	task.spawn(function()
		local t0 = os.clock()
		local PITCH = CARD_WIDTH + CARD_GAP
		local lastTickIndex = -1

		while not skipped do
			local elapsed = os.clock() - t0
			if elapsed >= SPIN_DURATION then break end

			local alpha = elapsed / SPIN_DURATION
			local eased = 1 - (1 - alpha) ^ 3
			local x = targetX * eased
			strip.Position = UDim2.fromOffset(math.floor(x), 0)

			local idx = math.floor((-x + STRIP_WIDTH / 2) / PITCH)
			if idx ~= lastTickIndex then
				lastTickIndex = idx
				playOneShotSfx(TICK_SOUND_ID, TICK_VOLUME)
			end

			task.wait()
		end

		strip.Position = UDim2.fromOffset(math.floor(targetX), 0)
		playOneShotSfx(RESOLVE_SOUND_ID, RESOLVE_VOLUME)

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

		awaitingDismiss = true
		nextLabel.Text = "NEXT"
		nextBtn.BackgroundColor3 = Color3.fromRGB(40, 160, 40)
		nextStroke.Color = Color3.fromRGB(80, 255, 80)
		if doubleBtn then
			doubleBtn.Visible = true
		end

		while not dismissed do
			task.wait()
		end

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

		if options and options.onNext then
			options.onNext()
		end
	end)
end

return VeinCrateOpener
