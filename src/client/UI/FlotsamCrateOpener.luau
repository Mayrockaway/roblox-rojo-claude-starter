--!strict
--- FlotsamCrateOpener: spinning card carousel for ocean crate rewards.
--- Clones the VeinCrateOpener mechanics (60 cards, cubic ease-out, tick SFX)
--- but with card art for Cash, Drill, and Oil rewards.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local FlotsamConfig = require(Shared:WaitForChild("Config"):WaitForChild("FlotsamConfig"))

local ClientAudioPreferences = require(script.Parent.Parent:WaitForChild("ClientAudioPreferences"))
local HudMousePolicy = require(script.Parent:WaitForChild("HudMousePolicy"))

local TICK_SOUND_ID = "rbxassetid://132417511885299"
local TICK_VOLUME = 0.15
local RESOLVE_SOUND_ID = "rbxassetid://102778985624056"
local RESOLVE_VOLUME = 0.2125

local CARD_WIDTH = 300
local CARD_HEIGHT = 300
local CARD_GAP = 12
local VISIBLE_CARDS = 4
local STRIP_WIDTH = (CARD_WIDTH + CARD_GAP) * VISIBLE_CARDS
local SPIN_DURATION = 5.5
local TOTAL_CARDS = 60
local WINNER_INDEX = TOTAL_CARDS - 2

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local function playOneShotSfx(soundId: string, volume: number)
	if not ClientAudioPreferences.isSfxEnabled() then return end
	local s = Instance.new("Sound")
	s.Name = "FlotsamCrateSfx"
	s.SoundId = soundId
	s.Volume = volume
	s.Looped = false
	s.Parent = SoundService
	s.Ended:Once(function()
		if s.Parent then s:Destroy() end
	end)
	s:Play()
	task.delay(3, function()
		if s.Parent then s:Destroy() end
	end)
end

--- Card background colors per crate tier.
local TIER_COLORS = {
	BaseCrate = { bg = Color3.fromRGB(90, 75, 55), accent = Color3.fromRGB(160, 140, 100) },
	["Gold Crate"] = { bg = Color3.fromRGB(180, 140, 30), accent = Color3.fromRGB(255, 220, 80) },
	["Rainbow Crate"] = { bg = Color3.fromRGB(120, 40, 180), accent = Color3.fromRGB(255, 100, 255) },
}

--- Map reward value to display rarity for visual styling.
local function getDisplayRarity(reward: any, crateTier: string): (string, Color3)
	if crateTier == "Rainbow Crate" then
		if reward.kind == "Cash" and reward.amount >= 50000 then
			return "MYTHIC", Color3.fromRGB(255, 67, 255)
		elseif reward.kind == "Drill" and reward.drillId == "drill_t6" then
			return "MYTHIC", Color3.fromRGB(255, 67, 255)
		elseif reward.kind == "Oil" and reward.oilType == "Premium" and reward.qty >= 40 then
			return "LEGENDARY", Color3.fromRGB(255, 170, 0)
		end
		return "EPIC", Color3.fromRGB(180, 80, 255)
	elseif crateTier == "Gold Crate" then
		if reward.kind == "Cash" and reward.amount >= 8000 then
			return "LEGENDARY", Color3.fromRGB(255, 170, 0)
		elseif reward.kind == "Drill" and (reward.drillId == "drill_t4") then
			return "EPIC", Color3.fromRGB(180, 80, 255)
		end
		return "RARE", Color3.fromRGB(80, 160, 255)
	else
		if reward.kind == "Cash" and reward.amount >= 4000 then
			return "RARE", Color3.fromRGB(80, 160, 255)
		elseif reward.kind == "Drill" and reward.drillId == "drill_t2" then
			return "UNCOMMON", Color3.fromRGB(80, 200, 80)
		end
		return "COMMON", Color3.fromRGB(200, 200, 200)
	end
end

local DRILL_NAMES = {
	drill_t1 = "Basic Drill",
	drill_t2 = "Standard Drill",
	drill_t3 = "Advanced Drill",
	drill_t4 = "Sundae Driller",
	drill_t5 = "Glizzy Grinder",
	drill_t6 = "Ground Pounder",
}

--- Format reward text for display on a card.
local function formatRewardText(reward: any): (string, string)
	if reward.kind == "Cash" then
		local amount = reward.amount or 0
		if amount >= 1000 then
			return "$" .. string.format("%g", amount / 1000) .. "K", "CASH"
		end
		return "$" .. tostring(amount), "CASH"
	elseif reward.kind == "Drill" then
		local name = DRILL_NAMES[reward.drillId] or "Drill"
		return tostring(reward.qty or 1) .. "x", name
	elseif reward.kind == "Oil" then
		return tostring(reward.qty or 1) .. "x", (reward.oilType or "Crude") .. " Oil"
	end
	return "???", "UNKNOWN"
end

--- Oil type display colors.
local OIL_COLORS = {
	Crude = Color3.fromRGB(140, 130, 120),
	Refined = Color3.fromRGB(220, 180, 50),
	Premium = Color3.fromRGB(255, 100, 180),
}

local CASH_ICON = "rbxassetid://81632778317714"

local DRILL_ICONS = {
	drill_t1 = "rbxassetid://128567532327549",
	drill_t2 = "rbxassetid://77096077391783",
	drill_t3 = "rbxassetid://106552715161471",
	drill_t4 = "rbxassetid://128828046005863",
	drill_t5 = "rbxassetid://108838922129381",
	drill_t6 = "rbxassetid://123358084547972",
}

local OIL_ICONS = {
	Crude = "rbxassetid://102169788803948",
	Refined = "rbxassetid://131963438621981",
	Premium = "rbxassetid://127818508063880",
}

local RARITY_BACKGROUNDS = {
	COMMON = "rbxassetid://70504909706756",
	UNCOMMON = "rbxassetid://128117062570098",
	RARE = "rbxassetid://93979855515567",
	EPIC = "rbxassetid://137994779619345",
	LEGENDARY = "rbxassetid://109246262572681",
	MYTHIC = "rbxassetid://120812474907419",
}

--- Build a single card frame.
local function createCard(reward: any, crateTier: string, parent: Instance): Frame
	local tierStyle = TIER_COLORS[crateTier] or TIER_COLORS.BaseCrate
	local rarityLabel, rarityColor = getDisplayRarity(reward, crateTier)
	local amountText, typeText = formatRewardText(reward)

	local card = Instance.new("Frame")
	card.Name = "Card"
	card.Size = UDim2.fromOffset(CARD_WIDTH, CARD_HEIGHT)
	card.BackgroundColor3 = tierStyle.bg
	card.BorderSizePixel = 0
	card.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = card

	-- Rarity background image (same as vein lootbox)
	local bgAsset = RARITY_BACKGROUNDS[rarityLabel] or RARITY_BACKGROUNDS.COMMON
	local bgImage = Instance.new("ImageLabel")
	bgImage.Name = "RarityBg"
	bgImage.Size = UDim2.fromScale(1, 1)
	bgImage.BackgroundTransparency = 1
	bgImage.Image = bgAsset
	bgImage.ScaleType = Enum.ScaleType.Stretch
	bgImage.ZIndex = 1
	bgImage.Parent = card
	Instance.new("UICorner", bgImage).CornerRadius = UDim.new(0, 12)

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = tierStyle.accent
	stroke.Transparency = 0.4
	stroke.Parent = card

	-- Icon image
	local iconId = ""
	if reward.kind == "Cash" then
		iconId = CASH_ICON
	elseif reward.kind == "Drill" then
		iconId = DRILL_ICONS[reward.drillId] or ""
	elseif reward.kind == "Oil" then
		iconId = OIL_ICONS[reward.oilType] or ""
	end

	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.Size = UDim2.fromOffset(120, 120)
	icon.Position = UDim2.new(0.5, 0, 0, 10)
	icon.AnchorPoint = Vector2.new(0.5, 0)
	icon.BackgroundTransparency = 1
	icon.Image = iconId
	icon.ScaleType = Enum.ScaleType.Fit
	icon.ZIndex = 3
	icon.Parent = card

	-- Amount text (big, bold, centered)
	local amountLabel = Instance.new("TextLabel")
	amountLabel.Name = "Amount"
	amountLabel.Size = UDim2.new(1, 0, 0, 45)
	amountLabel.Position = UDim2.new(0, 0, 0, 135)
	amountLabel.BackgroundTransparency = 1
	amountLabel.Font = Enum.Font.GothamBold
	amountLabel.TextSize = 38
	amountLabel.TextColor3 = Color3.new(1, 1, 1)
	amountLabel.TextStrokeTransparency = 0
	amountLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
	amountLabel.Text = amountText
	amountLabel.ZIndex = 4
	amountLabel.Parent = card

	-- Type text (below amount)
	local typeLabel = Instance.new("TextLabel")
	typeLabel.Name = "Type"
	typeLabel.Size = UDim2.new(1, 0, 0, 28)
	typeLabel.Position = UDim2.new(0, 0, 0, 182)
	typeLabel.BackgroundTransparency = 1
	typeLabel.Font = Enum.Font.GothamBold
	typeLabel.TextSize = 20
	typeLabel.Text = typeText
	typeLabel.TextStrokeTransparency = 0
	typeLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
	typeLabel.ZIndex = 4
	typeLabel.Parent = card

	-- Color the type text based on reward kind
	if reward.kind == "Cash" then
		typeLabel.TextColor3 = Color3.fromRGB(120, 255, 120)
	elseif reward.kind == "Drill" then
		typeLabel.TextColor3 = Color3.fromRGB(220, 220, 255)
	elseif reward.kind == "Oil" then
		typeLabel.TextColor3 = OIL_COLORS[reward.oilType] or Color3.new(1, 1, 1)
	end

	-- Rarity label at bottom with padding
	local rarityLbl = Instance.new("TextLabel")
	rarityLbl.Name = "Rarity"
	rarityLbl.Size = UDim2.new(1, 0, 0, 30)
	rarityLbl.Position = UDim2.new(0, 0, 1, -38)
	rarityLbl.BackgroundTransparency = 1
	rarityLbl.Font = Enum.Font.GothamBold
	rarityLbl.TextSize = 22
	rarityLbl.TextColor3 = rarityColor
	rarityLbl.Text = rarityLabel
	rarityLbl.TextStrokeTransparency = 0
	rarityLbl.TextStrokeColor3 = Color3.new(0, 0, 0)
	rarityLbl.ZIndex = 4
	rarityLbl.Parent = card

	return card
end

local FlotsamCrateOpener = {}

function FlotsamCrateOpener.Open(crateTier: string, winnerReward: any)
	local existing = playerGui:FindFirstChild("FlotsamCrateGui")
	if existing then existing:Destroy() end

	local pool = FlotsamConfig.Rewards[crateTier]
	if not pool or #pool == 0 then
		warn("[FlotsamCrateOpener] No reward pool for tier: " .. tostring(crateTier))
		return
	end

	-- Title per tier
	local tierInfo = nil
	for _, t in ipairs(FlotsamConfig.CrateTiers) do
		if t.templateName == crateTier then
			tierInfo = t
			break
		end
	end
	local titleText = "Opening " .. (tierInfo and tierInfo.displayName or "Crate")

	-- ScreenGui
	local gui = Instance.new("ScreenGui")
	gui.Name = "FlotsamCrateGui"
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 200
	gui.ResetOnSpawn = false
	gui.Parent = playerGui
	HudMousePolicy.RegisterScreenGui(gui)

	-- Dark overlay
	local overlay = Instance.new("Frame")
	overlay.Name = "Overlay"
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	overlay.BackgroundTransparency = 0.35
	overlay.BorderSizePixel = 0
	overlay.Parent = gui

	-- Center container
	local CENTER_TOTAL_H = 60 + 10 + 36 + 10 + CARD_HEIGHT + 20 + 50
	local centerFrame = Instance.new("Frame")
	centerFrame.Name = "CenterFrame"
	centerFrame.Size = UDim2.fromOffset(STRIP_WIDTH + 100, CENTER_TOTAL_H)
	centerFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	centerFrame.Position = UDim2.new(0.5, 0, 0.45, 0)
	centerFrame.BackgroundTransparency = 1
	centerFrame.Parent = overlay

	-- Responsive scaling
	local crateScale = Instance.new("UIScale")
	crateScale.Parent = centerFrame
	local REF_W = STRIP_WIDTH + 100
	local REF_H = CENTER_TOTAL_H
	local function applyScale()
		local cam = Workspace.CurrentCamera
		if not cam then return end
		local vp = cam.ViewportSize
		if vp.X <= 0 or vp.Y <= 0 then return end
		crateScale.Scale = math.min(1, math.min((vp.X * 0.92) / REF_W, (vp.Y * 0.92) / REF_H))
	end
	applyScale()
	local vpConn: RBXScriptConnection? = nil
	local cam0 = Workspace.CurrentCamera
	if cam0 then
		vpConn = cam0:GetPropertyChangedSignal("ViewportSize"):Connect(applyScale)
	end
	gui.AncestryChanged:Connect(function(_, parent)
		if parent == nil and vpConn then vpConn:Disconnect() end
	end)

	-- Title
	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 0, 60)
	title.AnchorPoint = Vector2.new(0.5, 0)
	title.Position = UDim2.new(0.5, 0, 0, 0)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 48
	title.TextColor3 = Color3.new(1, 1, 1)
	title.TextStrokeTransparency = 0
	title.TextStrokeColor3 = Color3.new(0, 0, 0)
	title.Text = titleText
	title.ZIndex = 2
	title.Parent = centerFrame

	-- Pointer
	local pointerContainer = Instance.new("Frame")
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
	Instance.new("UICorner", pointerTri).CornerRadius = UDim.new(0, 4)

	-- Strip container
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

	-- Build 60 cards, winner at index 58
	local cards = {}
	for i = 1, TOTAL_CARDS do
		local reward
		if i == WINNER_INDEX then
			reward = winnerReward
		else
			reward = pool[((i - 1) % #pool) + 1]
		end
		local card = createCard(reward, crateTier, strip)
		card.LayoutOrder = i
		table.insert(cards, { frame = card, reward = reward })
	end

	local totalWidth = TOTAL_CARDS * (CARD_WIDTH + CARD_GAP)
	strip.Size = UDim2.fromOffset(totalWidth, CARD_HEIGHT)
	strip.Position = UDim2.fromOffset(0, 0)

	local winnerCardLeft = (WINNER_INDEX - 1) * (CARD_WIDTH + CARD_GAP)
	local targetX = -(winnerCardLeft - STRIP_WIDTH / 2 + CARD_WIDTH / 2)

	-- Skip/Next button
	local skipBtn = Instance.new("TextButton")
	skipBtn.Name = "SkipButton"
	skipBtn.Size = UDim2.fromOffset(200, 50)
	skipBtn.AnchorPoint = Vector2.new(0.5, 0)
	skipBtn.Position = UDim2.new(0.5, 0, 0, 106 + CARD_HEIGHT + 16)
	skipBtn.BackgroundColor3 = Color3.fromRGB(200, 40, 40)
	skipBtn.BorderSizePixel = 0
	skipBtn.Text = ""
	skipBtn.AutoButtonColor = true
	skipBtn.ZIndex = 3
	skipBtn.Parent = centerFrame

	Instance.new("UICorner", skipBtn).CornerRadius = UDim.new(0, 10)

	local skipStroke = Instance.new("UIStroke")
	skipStroke.Thickness = 3
	skipStroke.Color = Color3.fromRGB(255, 80, 80)
	skipStroke.Parent = skipBtn

	local skipLabel = Instance.new("TextLabel")
	skipLabel.Size = UDim2.fromScale(1, 1)
	skipLabel.BackgroundTransparency = 1
	skipLabel.Font = Enum.Font.GothamBold
	skipLabel.TextSize = 28
	skipLabel.TextColor3 = Color3.new(1, 1, 1)
	skipLabel.Text = "SKIP"
	skipLabel.ZIndex = 4
	skipLabel.Parent = skipBtn

	local skipLabelStroke = Instance.new("UIStroke")
	skipLabelStroke.Thickness = 2
	skipLabelStroke.Color = Color3.new(0, 0, 0)
	skipLabelStroke.LineJoinMode = Enum.LineJoinMode.Round
	skipLabelStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	skipLabelStroke.Parent = skipLabel

	local skipped = false
	local dismissed = false
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

	-- Spin animation
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

		-- Snap to winner
		strip.Position = UDim2.fromOffset(math.floor(targetX), 0)
		playOneShotSfx(RESOLVE_SOUND_ID, RESOLVE_VOLUME)

		-- Highlight winner
		local winnerCard = cards[WINNER_INDEX]
		if winnerCard then
			local glow = Instance.new("UIStroke")
			glow.Thickness = 6
			glow.Color = Color3.fromRGB(255, 255, 0)
			glow.Parent = winnerCard.frame

			TweenService:Create(
				winnerCard.frame,
				TweenInfo.new(0.3, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, 2, true),
				{ Size = UDim2.fromOffset(CARD_WIDTH + 14, CARD_HEIGHT + 14) }
			):Play()
		end

		-- Switch to NEXT
		awaitingDismiss = true
		skipLabel.Text = "NEXT"
		skipBtn.BackgroundColor3 = Color3.fromRGB(40, 160, 40)
		skipStroke.Color = Color3.fromRGB(80, 255, 80)

		while not dismissed do
			task.wait()
		end

		-- Fade out
		TweenService:Create(overlay, TweenInfo.new(0.5), { BackgroundTransparency = 1 }):Play()
		task.wait(0.6)
		gui:Destroy()
	end)
end

return FlotsamCrateOpener
