--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

print("[OilEmpire] CLIENT_BOOT_V2")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))
local QualityConfig = require(Shared:WaitForChild("Config"):WaitForChild("QualityConfig"))

local remotesFolder = Shared:FindFirstChild("Remotes")
while remotesFolder == nil do
	task.wait(0.1)
	remotesFolder = Shared:FindFirstChild("Remotes")
end
local requestInitialState = remotesFolder:WaitForChild(RemoteNames.RequestInitialState) :: RemoteFunction
local requestShipment = remotesFolder:WaitForChild(RemoteNames.RequestShipment) :: RemoteEvent
local requestUpgrade = remotesFolder:WaitForChild(RemoteNames.RequestUpgrade) :: RemoteEvent
local requestLocalSell = remotesFolder:WaitForChild(RemoteNames.RequestLocalSell) :: RemoteEvent
local requestAdminForceClose = remotesFolder:WaitForChild(RemoteNames.RequestAdminForceClose) :: RemoteEvent
local globalStateUpdate = remotesFolder:WaitForChild(RemoteNames.GlobalStateUpdate) :: RemoteEvent
local playerStateUpdate = remotesFolder:WaitForChild(RemoteNames.PlayerStateUpdate) :: RemoteEvent
local shipmentVisualEvent = remotesFolder:WaitForChild(RemoteNames.ShipmentVisualEvent) :: RemoteEvent
local actionResult = remotesFolder:WaitForChild(RemoteNames.ActionResult) :: RemoteEvent

local globalState = nil
local localState = nil
local upgradeCatalog = {}
local selectedSizeId = "Small"

local ui = {}
local tierInputs = {}
local upgradeButtonsById = {}

local function createLabel(parent: Instance, text: string, size: UDim2, position: UDim2, textSize: number): TextLabel
	local label = Instance.new("TextLabel")
	label.Size = size
	label.Position = position
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.fromRGB(241, 242, 238)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Font = Enum.Font.GothamSemibold
	label.TextScaled = false
	label.TextSize = textSize
	label.Text = text
	label.Parent = parent
	return label
end

local function createButton(parent: Instance, text: string, size: UDim2, position: UDim2): TextButton
	local button = Instance.new("TextButton")
	button.Size = size
	button.Position = position
	button.BackgroundColor3 = Color3.fromRGB(31, 73, 97)
	button.TextColor3 = Color3.fromRGB(250, 250, 250)
	button.Font = Enum.Font.GothamBold
	button.TextSize = 14
	button.Text = text
	button.AutoButtonColor = true
	button.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = button

	return button
end

local function createTierInput(parent: Instance, tierId: string, yScale: number)
	local label = createLabel(parent, tierId .. ":", UDim2.fromScale(0.45, 0.08), UDim2.fromScale(0.02, yScale), 13)
	label.TextColor3 = Color3.fromRGB(210, 214, 218)

	local input = Instance.new("TextBox")
	input.Size = UDim2.fromScale(0.48, 0.08)
	input.Position = UDim2.fromScale(0.50, yScale)
	input.BackgroundColor3 = Color3.fromRGB(29, 34, 42)
	input.TextColor3 = Color3.fromRGB(245, 245, 245)
	input.Font = Enum.Font.Gotham
	input.TextSize = 13
	input.TextXAlignment = Enum.TextXAlignment.Left
	input.PlaceholderText = "0"
	input.ClearTextOnFocus = false
	input.Text = "0"
	input.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 5)
	corner.Parent = input

	tierInputs[tierId] = input
end

local function parseComposition()
	local composition = {}
	local any = false
	for _, tierId in ipairs(QualityConfig.TierOrder) do
		local input = tierInputs[tierId]
		if input then
			local value = math.max(0, math.floor(tonumber(input.Text) or 0))
			if value > 0 then
				composition[tierId] = value
				any = true
			end
		end
	end
	if any then
		return composition
	end
	return nil
end

local function getSelectedShipCap(): number?
	if selectedSizeId == "Small" then
		return 10
	elseif selectedSizeId == "Medium" then
		return 30
	elseif selectedSizeId == "Large" then
		return 70
	end
	return nil
end

local function getExpectedValuePreview(): number
	if localState == nil or globalState == nil then
		return 0
	end
	local composition = parseComposition()
	local toUse = composition
	if toUse == nil then
		toUse = {}
		local remaining = getSelectedShipCap()
		if remaining == nil then
			remaining = localState.totalOil or 0
		end

		for _, tierId in ipairs(QualityConfig.TierOrder) do
			if remaining <= 0 then
				break
			end
			local owned = 0
			if localState.oilByTier and localState.oilByTier[tierId] then
				owned = localState.oilByTier[tierId]
			end
			local take = math.min(owned, remaining)
			if take > 0 then
				toUse[tierId] = take
				remaining -= take
			end
		end
	end

	local subtotal = 0
	for tierId, amount in pairs(toUse) do
		local tierInfo = QualityConfig.Tiers[tierId]
		if tierInfo then
			subtotal += amount * tierInfo.basePricePerBarrel
		end
	end
	local multiplier = globalState.priceMultiplier or 1
	return math.floor(subtotal * multiplier)
end

local function updateUi()
	if ui.cashLabel == nil then
		return
	end

	if globalState then
		ui.straitLabel.Text = ("Strait: %s | x%.2f"):format(globalState.state or "?", globalState.priceMultiplier or 1)
		local secondsLeft = math.max(0, math.floor((globalState.nextRollAt or workspace:GetServerTimeNow()) - workspace:GetServerTimeNow()))
		ui.timerLabel.Text = ("Next roll in: %ds"):format(secondsLeft)
	else
		ui.straitLabel.Text = "Strait: Loading..."
		ui.timerLabel.Text = "Next roll in: --"
	end

	if localState then
		ui.cashLabel.Text = ("Cash: $%d"):format(localState.cash or 0)
		ui.storageLabel.Text = ("Storage: %d / %d"):format(localState.totalOil or 0, localState.capacity or 0)
		ui.shipmentLabel.Text = ("Active Shipments: %d"):format(localState.activeShipmentCount or 0)
		for _, tierId in ipairs(QualityConfig.TierOrder) do
			local amount = 0
			if localState.oilByTier and localState.oilByTier[tierId] then
				amount = localState.oilByTier[tierId]
			end
			ui.tierLabels[tierId].Text = ("%s: %d"):format(tierId, amount)
		end
	else
		ui.cashLabel.Text = "Cash: --"
		ui.storageLabel.Text = "Storage: --"
		ui.shipmentLabel.Text = "Active Shipments: --"
	end

	local preview = getExpectedValuePreview()
	ui.previewLabel.Text = ("Expected Value (%s): $%d"):format(selectedSizeId, preview)

	for _, entry in ipairs(upgradeCatalog) do
		local currentLevel = 0
		if localState and localState.upgrades and localState.upgrades[entry.upgradeId] then
			currentLevel = localState.upgrades[entry.upgradeId]
		end
		local nextCost = math.floor(entry.baseCost * (entry.costGrowth ^ currentLevel))
		local button = upgradeButtonsById[entry.upgradeId]
		if button then
			button.Text = ("%s L%d ($%d)"):format(entry.displayName, currentLevel, nextCost)
		end
	end
end

local function buildUi()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "OilEmpireHUD"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = playerGui

	local root = Instance.new("Frame")
	root.Size = UDim2.fromScale(0.42, 0.88)
	root.Position = UDim2.fromScale(0.02, 0.06)
	root.BackgroundColor3 = Color3.fromRGB(18, 24, 33)
	root.BackgroundTransparency = 0.12
	root.Parent = screenGui
	local rootCorner = Instance.new("UICorner")
	rootCorner.CornerRadius = UDim.new(0, 10)
	rootCorner.Parent = root

	ui.straitLabel = createLabel(root, "Strait: ...", UDim2.fromScale(0.96, 0.06), UDim2.fromScale(0.02, 0.01), 16)
	ui.timerLabel = createLabel(root, "Next roll in: ...", UDim2.fromScale(0.96, 0.05), UDim2.fromScale(0.02, 0.07), 13)
	ui.cashLabel = createLabel(root, "Cash: ...", UDim2.fromScale(0.96, 0.05), UDim2.fromScale(0.02, 0.12), 14)
	ui.storageLabel = createLabel(root, "Storage: ...", UDim2.fromScale(0.96, 0.05), UDim2.fromScale(0.02, 0.17), 14)
	ui.shipmentLabel = createLabel(root, "Active Shipments: ...", UDim2.fromScale(0.96, 0.05), UDim2.fromScale(0.02, 0.22), 14)

	ui.tierLabels = {}
	local tierY = 0.27
	for _, tierId in ipairs(QualityConfig.TierOrder) do
		ui.tierLabels[tierId] = createLabel(root, tierId .. ": 0", UDim2.fromScale(0.96, 0.045), UDim2.fromScale(0.02, tierY), 12)
		tierY += 0.04
	end

	local compositionFrame = Instance.new("Frame")
	compositionFrame.Size = UDim2.fromScale(0.96, 0.26)
	compositionFrame.Position = UDim2.fromScale(0.02, 0.44)
	compositionFrame.BackgroundColor3 = Color3.fromRGB(27, 34, 46)
	compositionFrame.Parent = root
	local compCorner = Instance.new("UICorner")
	compCorner.CornerRadius = UDim.new(0, 8)
	compCorner.Parent = compositionFrame

	createLabel(compositionFrame, "Shipment Composer", UDim2.fromScale(0.96, 0.10), UDim2.fromScale(0.02, 0.00), 13)
	createTierInput(compositionFrame, "PremiumRefined", 0.12)
	createTierInput(compositionFrame, "LightSweet", 0.30)
	createTierInput(compositionFrame, "StandardCrude", 0.48)
	createTierInput(compositionFrame, "HeavyCrude", 0.66)

	local sizeFrame = Instance.new("Frame")
	sizeFrame.Size = UDim2.fromScale(0.96, 0.09)
	sizeFrame.Position = UDim2.fromScale(0.02, 0.71)
	sizeFrame.BackgroundTransparency = 1
	sizeFrame.Parent = root

	local sizeOptions = { "Small", "Medium", "Large", "AllIn" }
	for i, sizeId in ipairs(sizeOptions) do
		local button = createButton(sizeFrame, sizeId, UDim2.fromScale(0.23, 0.9), UDim2.fromScale((i - 1) * 0.255, 0))
		button.MouseButton1Click:Connect(function()
			selectedSizeId = sizeId
			updateUi()
		end)
	end

	local dispatchButton = createButton(root, "Dispatch Shipment", UDim2.fromScale(0.62, 0.07), UDim2.fromScale(0.02, 0.80))
	dispatchButton.MouseButton1Click:Connect(function()
		local payload = {
			sizeId = selectedSizeId,
			composition = parseComposition(),
		}
		requestShipment:FireServer(payload)
	end)

	local localSellButton = createButton(root, "Local Sell (Closed)", UDim2.fromScale(0.34, 0.07), UDim2.fromScale(0.64, 0.80))
	localSellButton.MouseButton1Click:Connect(function()
		requestLocalSell:FireServer()
	end)

	local upgradesFrame = Instance.new("Frame")
	upgradesFrame.Size = UDim2.fromScale(0.96, 0.12)
	upgradesFrame.Position = UDim2.fromScale(0.02, 0.88)
	upgradesFrame.BackgroundTransparency = 1
	upgradesFrame.Parent = root

	local upgradeIds = { "PumpRate", "StorageCapacity", "TankerDurability", "EscortBonus", "QualityBias" }
	for i, upgradeId in ipairs(upgradeIds) do
		local x = ((i - 1) % 2) * 0.50
		local y = math.floor((i - 1) / 2) * 0.5
		local button = createButton(upgradesFrame, upgradeId, UDim2.fromScale(0.48, 0.46), UDim2.fromScale(x, y))
		button.MouseButton1Click:Connect(function()
			requestUpgrade:FireServer({
				upgradeId = upgradeId,
			})
		end)
		upgradeButtonsById[upgradeId] = button
	end

	local adminButton = createButton(root, "Admin: Force Close 90s", UDim2.fromScale(0.40, 0.05), UDim2.fromScale(0.58, 0.01))
	adminButton.MouseButton1Click:Connect(function()
		requestAdminForceClose:FireServer({
			durationSeconds = 90,
		})
	end)

	ui.previewLabel = createLabel(root, "Expected Value: --", UDim2.fromScale(0.96, 0.05), UDim2.fromScale(0.02, 0.75), 14)
	ui.statusLabel = createLabel(root, "Status: Ready", UDim2.fromScale(0.96, 0.05), UDim2.fromScale(0.02, 0.85), 12)
	ui.statusLabel.TextColor3 = Color3.fromRGB(166, 224, 189)
end

buildUi()

local initial = requestInitialState:InvokeServer()
if typeof(initial) == "table" then
	globalState = initial.global
	localState = initial.player
	if typeof(initial.upgradeCatalog) == "table" then
		upgradeCatalog = initial.upgradeCatalog
	end
end
updateUi()

globalStateUpdate.OnClientEvent:Connect(function(payload)
	globalState = payload
	updateUi()
end)

playerStateUpdate.OnClientEvent:Connect(function(payload)
	localState = payload
	updateUi()
end)

shipmentVisualEvent.OnClientEvent:Connect(function(payload)
	local message = ("Shipment Event: %s"):format(payload.type or "unknown")
	if payload.type == "ShipmentResolved" then
		message = ("%s | %s | $%d"):format(payload.type, payload.outcome or "Unknown", payload.payout or 0)
	elseif payload.type == "ShipmentEvent" then
		message = ("%s | %s | HP %.2f"):format(payload.type, payload.eventId or "?", payload.hp or 0)
	end
	ui.statusLabel.TextColor3 = Color3.fromRGB(210, 224, 250)
	ui.statusLabel.Text = "Status: " .. message
end)

actionResult.OnClientEvent:Connect(function(payload)
	if payload.ok then
		ui.statusLabel.TextColor3 = Color3.fromRGB(166, 224, 189)
	else
		ui.statusLabel.TextColor3 = Color3.fromRGB(242, 133, 133)
	end
	ui.statusLabel.Text = ("Status: [%s] %s"):format(payload.code or "?", payload.message or "Action result")
	updateUi()
end)

task.spawn(function()
	while true do
		task.wait(1)
		updateUi()
	end
end)

print("[Client] Oil Empire HUD started")
