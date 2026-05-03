--!strict
--- One-time first-join prompt: "Standard" or "Lite" performance mode.
--- Shown once, saves choice, never appears again.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local PerformanceMode = require(script.Parent.Parent:WaitForChild("PerformanceMode"))

local LocalPlayer = Players.LocalPlayer
local DISPLAY_ORDER = 999990

local PerformanceModePrompt = {}

local function createButton(parent: Frame, text: string, desc: string, color: Color3, layoutOrder: number): TextButton
	local btn = Instance.new("TextButton")
	btn.Name = text
	btn.Size = UDim2.new(0.42, 0, 0, 90)
	btn.BackgroundColor3 = color
	btn.BorderSizePixel = 0
	btn.Font = Enum.Font.GothamBold
	btn.TextSize = 20
	btn.TextColor3 = Color3.new(1, 1, 1)
	btn.Text = text
	btn.AutoButtonColor = true
	btn.LayoutOrder = layoutOrder
	btn.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = btn

	local descLabel = Instance.new("TextLabel")
	descLabel.Name = "Desc"
	descLabel.Size = UDim2.new(1, -16, 0, 30)
	descLabel.Position = UDim2.new(0, 8, 1, -36)
	descLabel.BackgroundTransparency = 1
	descLabel.Font = Enum.Font.Gotham
	descLabel.TextSize = 13
	descLabel.TextColor3 = Color3.new(1, 1, 1)
	descLabel.TextTransparency = 0.3
	descLabel.Text = desc
	descLabel.TextWrapped = true
	descLabel.Parent = btn

	return btn
end

function PerformanceModePrompt.show(): string
	local playerGui = LocalPlayer:WaitForChild("PlayerGui") :: PlayerGui

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "PerformanceModePrompt"
	screenGui.DisplayOrder = DISPLAY_ORDER
	screenGui.IgnoreGuiInset = true
	screenGui.ResetOnSpawn = false

	-- Dimmer
	local dimmer = Instance.new("Frame")
	dimmer.Name = "Dimmer"
	dimmer.Size = UDim2.fromScale(1, 1)
	dimmer.BackgroundColor3 = Color3.new(0, 0, 0)
	dimmer.BackgroundTransparency = 0.4
	dimmer.BorderSizePixel = 0
	dimmer.ZIndex = 1
	dimmer.Parent = screenGui

	-- Card
	local card = Instance.new("Frame")
	card.Name = "Card"
	card.Size = UDim2.new(0, 360, 0, 240)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
	card.BorderSizePixel = 0
	card.ZIndex = 2
	card.Parent = screenGui

	local cardCorner = Instance.new("UICorner")
	cardCorner.CornerRadius = UDim.new(0, 12)
	cardCorner.Parent = card

	-- Title
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, -24, 0, 32)
	title.Position = UDim2.new(0, 12, 0, 18)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 22
	title.TextColor3 = Color3.new(1, 1, 1)
	title.Text = "Choose Your Experience"
	title.ZIndex = 3
	title.Parent = card

	-- Subtitle
	local subtitle = Instance.new("TextLabel")
	subtitle.Name = "Subtitle"
	subtitle.Size = UDim2.new(1, -24, 0, 24)
	subtitle.Position = UDim2.new(0, 12, 0, 52)
	subtitle.BackgroundTransparency = 1
	subtitle.Font = Enum.Font.Gotham
	subtitle.TextSize = 14
	subtitle.TextColor3 = Color3.fromRGB(180, 180, 180)
	subtitle.Text = "You can change this anytime in Settings."
	subtitle.ZIndex = 3
	subtitle.Parent = card

	-- Buttons container
	local buttonsFrame = Instance.new("Frame")
	buttonsFrame.Name = "Buttons"
	buttonsFrame.Size = UDim2.new(1, -32, 0, 100)
	buttonsFrame.Position = UDim2.new(0, 16, 0, 100)
	buttonsFrame.BackgroundTransparency = 1
	buttonsFrame.ZIndex = 3
	buttonsFrame.Parent = card

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Padding = UDim.new(0, 16)
	layout.Parent = buttonsFrame

	local standardBtn = createButton(
		buttonsFrame,
		"Standard",
		"Full visual quality",
		Color3.fromRGB(50, 120, 200),
		1
	)
	standardBtn.ZIndex = 4

	local liteBtn = createButton(
		buttonsFrame,
		"Lite",
		"Smoother performance",
		Color3.fromRGB(40, 170, 80),
		2
	)
	liteBtn.ZIndex = 4

	-- Set ZIndex on desc labels
	for _, btn in {standardBtn, liteBtn} do
		for _, child in btn:GetChildren() do
			if child:IsA("TextLabel") then
				child.ZIndex = 5
			end
		end
	end

	-- Fade in
	card.BackgroundTransparency = 1
	title.TextTransparency = 1
	subtitle.TextTransparency = 1
	dimmer.BackgroundTransparency = 1
	standardBtn.BackgroundTransparency = 1
	standardBtn.TextTransparency = 1
	liteBtn.BackgroundTransparency = 1
	liteBtn.TextTransparency = 1

	screenGui.Parent = playerGui

	local fadeIn = TweenService:Create(dimmer, TweenInfo.new(0.3, Enum.EasingStyle.Quad), { BackgroundTransparency = 0.4 })
	local cardFade = TweenService:Create(card, TweenInfo.new(0.3, Enum.EasingStyle.Quad), { BackgroundTransparency = 0 })
	local titleFade = TweenService:Create(title, TweenInfo.new(0.3, Enum.EasingStyle.Quad), { TextTransparency = 0 })
	local subFade = TweenService:Create(subtitle, TweenInfo.new(0.3, Enum.EasingStyle.Quad), { TextTransparency = 0 })
	local stdFade = TweenService:Create(standardBtn, TweenInfo.new(0.3, Enum.EasingStyle.Quad), { BackgroundTransparency = 0, TextTransparency = 0 })
	local liteFade = TweenService:Create(liteBtn, TweenInfo.new(0.3, Enum.EasingStyle.Quad), { BackgroundTransparency = 0, TextTransparency = 0 })
	fadeIn:Play()
	cardFade:Play()
	titleFade:Play()
	subFade:Play()
	stdFade:Play()
	liteFade:Play()

	-- Wait for choice
	local chosen: string? = nil
	local conn1 = standardBtn.Activated:Connect(function()
		chosen = "standard"
	end)
	local conn2 = liteBtn.Activated:Connect(function()
		chosen = "lite"
	end)

	while chosen == nil do
		task.wait()
	end

	conn1:Disconnect()
	conn2:Disconnect()

	-- Fade out
	local fadeOut = TweenService:Create(dimmer, TweenInfo.new(0.2, Enum.EasingStyle.Quad), { BackgroundTransparency = 1 })
	local cardOut = TweenService:Create(card, TweenInfo.new(0.2, Enum.EasingStyle.Quad), { BackgroundTransparency = 1 })
	fadeOut:Play()
	cardOut:Play()
	fadeOut.Completed:Wait()
	screenGui:Destroy()

	return chosen :: string
end

return PerformanceModePrompt
