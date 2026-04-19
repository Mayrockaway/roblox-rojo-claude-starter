--!strict
-- DeliveryManDialogue: blocky LuckiestGuy dialogue for the DeliveryMan NPC.
-- Options: Ship Oil (opens shipping manifest) or Sell Oil Locally (inline Oilman-style sell menu).

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local ProximityPromptService = game:GetService("ProximityPromptService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Resolve HudPanelRouter for opening panels
local playerScripts = player:WaitForChild("PlayerScripts")
local clientFolder = playerScripts:WaitForChild("Client", 30)
local uiFolder = clientFolder and clientFolder:WaitForChild("UI", 10)
local HudPanelRouter = uiFolder and require(uiFolder:WaitForChild("HudPanelRouter"))

-- Remotes for local sell
local getClientRemotes = require(clientFolder:WaitForChild("GetClientRemotes")) :: () -> any
local ClientRemotes = getClientRemotes()
local oilmanSellRemote = ClientRemotes.requestOilmanSell
local oilStateUpdate = ClientRemotes.oilStateUpdate

local OILMAN_PRICES = { HeavyCrude = 5, LightSweet = 8, PremiumRefined = 12 }
local currentOilByTier: { [string]: number } = {}

oilStateUpdate.OnClientEvent:Connect(function(data)
	if typeof(data) == "table" and typeof(data.oilByTier) == "table" then
		currentOilByTier = data.oilByTier
	end
end)

local COLOR_IDLE = Color3.fromRGB(255, 255, 255)
local COLOR_HOVER = Color3.fromRGB(255, 205, 80)
local COLOR_DIM = Color3.fromRGB(210, 210, 210)
local COLOR_GRAY = Color3.fromRGB(100, 100, 100)
local COLOR_GOLD = Color3.fromRGB(255, 170, 60)
local COLOR_MONEY = Color3.fromRGB(80, 220, 80)
local AUTO_CLOSE_DIST = 12

local OIL_COLORS = {
	HeavyCrude = Color3.fromRGB(200, 200, 200),
	LightSweet = Color3.fromRGB(240, 200, 70),
	PremiumRefined = Color3.fromRGB(255, 150, 200),
}

local dialogueOpen = false

local function closeDialogue()
	dialogueOpen = false
	local gui = playerGui:FindFirstChild("DeliveryManGui")
	if gui then gui:Destroy() end
end

local function blockyLine(name: string, text: string, order: number, isButton: boolean, parent: Instance)
	local obj
	if isButton then
		obj = Instance.new("TextButton")
		obj.AutoButtonColor = false
		obj.Active = true
		obj.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		obj.BackgroundTransparency = 0.99
		obj.MouseEnter:Connect(function() obj.TextColor3 = COLOR_HOVER; obj.BackgroundTransparency = 0.35 end)
		obj.MouseLeave:Connect(function() obj.TextColor3 = COLOR_IDLE; obj.BackgroundTransparency = 0.99 end)
		local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 6); c.Parent = obj
	else
		obj = Instance.new("TextLabel")
		obj.BackgroundTransparency = 1
	end
	obj.Name = name; obj.Text = text; obj.Size = UDim2.new(1, 0, 0, 42); obj.LayoutOrder = order
	obj.BorderSizePixel = 0; obj.Font = Enum.Font.LuckiestGuy; obj.TextSize = 34
	obj.TextColor3 = COLOR_IDLE; obj.TextStrokeTransparency = 0; obj.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	obj.TextXAlignment = Enum.TextXAlignment.Left; obj.TextYAlignment = Enum.TextYAlignment.Center
	if parent then obj.Parent = parent end
	return obj
end

local function sellOil(quantities: { [string]: number }, shouldClose: boolean)
	local rid = HttpService:GenerateGUID(false)
	if oilmanSellRemote then oilmanSellRemote:FireServer({ quantities = quantities, requestId = rid }) end
	if shouldClose then
		local gui = playerGui:FindFirstChild("DeliveryManGui")
		if gui then
			local root = gui:FindFirstChild("Root")
			if root then
				for _, c in ipairs(root:GetChildren()) do
					if c:IsA("TextButton") or c:IsA("TextLabel") then c.Visible = false end
				end
				local farewell = Instance.new("TextLabel")
				farewell.Name = "Farewell"; farewell.Size = UDim2.new(1, 0, 0, 50)
				farewell.BackgroundTransparency = 1; farewell.Text = "Good doing business!"
				farewell.Font = Enum.Font.LuckiestGuy; farewell.TextSize = 36
				farewell.TextColor3 = COLOR_GOLD; farewell.TextStrokeTransparency = 0
				farewell.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
				farewell.TextXAlignment = Enum.TextXAlignment.Left; farewell.Parent = root
			end
		end
		task.delay(1.5, closeDialogue)
	end
end

local function openDialogue(npcModel: Instance)
	if dialogueOpen then return end
	closeDialogue()
	dialogueOpen = true

	local screen = Instance.new("ScreenGui")
	screen.Name = "DeliveryManGui"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 60
	screen.Parent = playerGui

	local autoCloseConn: RBXScriptConnection? = nil
	autoCloseConn = RunService.Heartbeat:Connect(function()
		if not screen.Parent then
			if autoCloseConn then autoCloseConn:Disconnect() end
			return
		end
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if hrp and npcModel and npcModel.Parent then
			local npcPos = npcModel:GetPivot().Position
			if (hrp.Position - npcPos).Magnitude > AUTO_CLOSE_DIST then
				closeDialogue()
				if autoCloseConn then autoCloseConn:Disconnect() end
			end
		end
	end)

	local root = Instance.new("Frame")
	root.Name = "Root"; root.BackgroundTransparency = 1; root.BorderSizePixel = 0; root.Active = false
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Position = UDim2.fromScale(0.68, 0.55)
	root.Size = UDim2.fromOffset(520, 420)
	root.Parent = screen

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = root

	local header = blockyLine("Header", "Delivery Man:", 1, false, root)
	header.Size = UDim2.new(1, 0, 0, 50); header.TextSize = 44

	local shipBtn = blockyLine("ShipOil", "Ship Oil", 2, true, root)
	local sellBtn = blockyLine("SellLocal", "Sell Oil Locally", 3, true, root)
	local backBtn = blockyLine("Back", "back", 4, true, root)
	backBtn.TextSize = 28; backBtn.TextColor3 = COLOR_DIM
	backBtn.MouseLeave:Connect(function() backBtn.TextColor3 = COLOR_DIM end)

	shipBtn.MouseButton1Click:Connect(function()
		closeDialogue()
		if HudPanelRouter then
			HudPanelRouter.openScreen("ShipOilPanelGui")
		end
	end)

	sellBtn.MouseButton1Click:Connect(function()
		-- Replace main options with Oilman-style sell menu
		header.Text = "Sell Oil (Discount):"; header.TextSize = 38
		shipBtn.Visible = false; sellBtn.Visible = false; backBtn.Visible = false
		for _, c in ipairs(root:GetChildren()) do if c.Name:find("Sell_") then c:Destroy() end end

		local tiers = {
			{ key = "HeavyCrude", label = "Heavy Crude" },
			{ key = "LightSweet", label = "Light Sweet" },
			{ key = "PremiumRefined", label = "Premium" },
		}
		local order = 5
		for _, tier in ipairs(tiers) do
			local amt = math.floor(currentOilByTier[tier.key] or 0)
			local price = OILMAN_PRICES[tier.key] or 5

			local tierHeader = blockyLine("Sell_h_" .. tier.key, string.format("%s (%d)", tier.label, amt), order, false, root)
			tierHeader.TextSize = 24; tierHeader.Size = UDim2.new(1, 0, 0, 30)
			tierHeader.TextColor3 = OIL_COLORS[tier.key] or COLOR_IDLE
			if amt <= 0 then tierHeader.TextColor3 = COLOR_GRAY end
			order += 1

			if amt >= 1 then
				local b1 = blockyLine("Sell_1_" .. tier.key, "  Sell 1x", order, true, root)
				b1.TextSize = 22; b1.Size = UDim2.new(1, 0, 0, 28)
				local m1 = Instance.new("TextLabel")
				m1.Size = UDim2.new(0.4, 0, 1, 0); m1.Position = UDim2.new(0.6, 0, 0, 0)
				m1.BackgroundTransparency = 1; m1.Text = string.format("$%d", price)
				m1.Font = Enum.Font.LuckiestGuy; m1.TextSize = 22; m1.TextColor3 = COLOR_MONEY
				m1.TextStrokeTransparency = 0; m1.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
				m1.TextXAlignment = Enum.TextXAlignment.Right; m1.Parent = b1
				b1.MouseButton1Click:Connect(function() sellOil({ [tier.key] = 1 }, false) end)
				order += 1
			end
			if amt >= 5 then
				local b5 = blockyLine("Sell_5_" .. tier.key, "  Sell 5x", order, true, root)
				b5.TextSize = 22; b5.Size = UDim2.new(1, 0, 0, 28)
				local m5 = Instance.new("TextLabel")
				m5.Size = UDim2.new(0.4, 0, 1, 0); m5.Position = UDim2.new(0.6, 0, 0, 0)
				m5.BackgroundTransparency = 1; m5.Text = string.format("$%d", price * 5)
				m5.Font = Enum.Font.LuckiestGuy; m5.TextSize = 22; m5.TextColor3 = COLOR_MONEY
				m5.TextStrokeTransparency = 0; m5.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
				m5.TextXAlignment = Enum.TextXAlignment.Right; m5.Parent = b5
				b5.MouseButton1Click:Connect(function() sellOil({ [tier.key] = 5 }, false) end)
				order += 1
			end
			if amt > 0 then
				local ba = blockyLine("Sell_a_" .. tier.key, string.format("  Sell All %d", amt), order, true, root)
				ba.TextSize = 22; ba.Size = UDim2.new(1, 0, 0, 28)
				local ma = Instance.new("TextLabel")
				ma.Size = UDim2.new(0.4, 0, 1, 0); ma.Position = UDim2.new(0.6, 0, 0, 0)
				ma.BackgroundTransparency = 1; ma.Text = string.format("$%d", price * amt)
				ma.Font = Enum.Font.LuckiestGuy; ma.TextSize = 22; ma.TextColor3 = COLOR_MONEY
				ma.TextStrokeTransparency = 0; ma.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
				ma.TextXAlignment = Enum.TextXAlignment.Right; ma.Parent = ba
				ba.MouseButton1Click:Connect(function() sellOil({ [tier.key] = amt }, false) end)
				order += 1
			end
		end

		-- Sell Everything button
		local totalAmt = 0
		local totalValue = 0
		local allQuantities = {}
		for _, tier in ipairs(tiers) do
			local amt = math.floor(currentOilByTier[tier.key] or 0)
			if amt > 0 then
				allQuantities[tier.key] = amt
				totalAmt += amt
				totalValue += amt * (OILMAN_PRICES[tier.key] or 5)
			end
		end
		if totalAmt > 0 then
			local sellAll = blockyLine("Sell_Everything", "Sell Everything", order, true, root)
			sellAll.TextSize = 28; sellAll.Size = UDim2.new(1, 0, 0, 36)
			local mAll = Instance.new("TextLabel")
			mAll.Size = UDim2.new(0.4, 0, 1, 0); mAll.Position = UDim2.new(0.6, 0, 0, 0)
			mAll.BackgroundTransparency = 1; mAll.Text = string.format("$%d", totalValue)
			mAll.Font = Enum.Font.LuckiestGuy; mAll.TextSize = 24; mAll.TextColor3 = COLOR_MONEY
			mAll.TextStrokeTransparency = 0; mAll.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
			mAll.TextXAlignment = Enum.TextXAlignment.Right; mAll.Parent = sellAll
			sellAll.MouseButton1Click:Connect(function() sellOil(allQuantities, true) end)
			order += 1
		end

		-- Back button to return to main menu
		local sellBack = blockyLine("Sell_Back", "back", order, true, root)
		sellBack.TextSize = 24; sellBack.TextColor3 = COLOR_DIM
		sellBack.MouseLeave:Connect(function() sellBack.TextColor3 = COLOR_DIM end)
		sellBack.MouseButton1Click:Connect(function()
			closeDialogue()
			openDialogue(npcModel)
		end)
	end)

	backBtn.MouseButton1Click:Connect(function()
		closeDialogue()
	end)
end

-- Floating "Ship Oil" marker — client-side only, on player's own plot
task.spawn(function()
	-- Wait for plot assignment
	local markerGui: BillboardGui? = nil
	local markerAdornee: BasePart? = nil

	local function tryCreateMarker()
		-- Clean old
		if markerGui and markerGui.Parent then markerGui:Destroy() end
		markerGui = nil

		-- Find our own plot's PlotDispatch
		local plotId = player:GetAttribute("PlotId")
		if not plotId then return end
		local map = Workspace:FindFirstChild("Map")
		local plots = map and map:FindFirstChild("Plots")
		if not plots then return end
		for _, plot in ipairs(plots:GetChildren()) do
			local id = plot:GetAttribute("PlotId") or tonumber(plot.Name:match("%d+"))
			if id == plotId then
				local dispatch = plot:FindFirstChild("PlotDispatch")
				if not dispatch then continue end
				local sc = dispatch:FindFirstChild("StarterCharacter", true)
				local head = sc and sc:FindFirstChild("Head")
				if not head then continue end

				local bb = Instance.new("BillboardGui")
				bb.Name = "ShipOilMarkerGui"
				bb.Size = UDim2.fromOffset(200, 110)
				bb.StudsOffset = Vector3.new(0, 10, 0)
				bb.AlwaysOnTop = true
				bb.LightInfluence = 0
				bb.Adornee = head
				bb.Parent = playerGui

				-- Arrow: ▼ character
				local arrow = Instance.new("TextLabel")
				arrow.Name = "Arrow"
				arrow.Size = UDim2.new(1, 0, 0.5, 0)
				arrow.Position = UDim2.fromScale(0, 0.5)
				arrow.BackgroundTransparency = 1
				arrow.Font = Enum.Font.LuckiestGuy
				arrow.TextSize = 52
				arrow.Text = "▼"
				arrow.TextColor3 = Color3.fromRGB(50, 220, 80)
				arrow.TextTransparency = 0.4
				arrow.TextStrokeTransparency = 0.6
				arrow.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
				arrow.Parent = bb

				-- "Ship Oil" text
				local label = Instance.new("TextLabel")
				label.Name = "Text"
				label.Size = UDim2.new(1, 0, 0.5, 0)
				label.Position = UDim2.fromScale(0, 0)
				label.BackgroundTransparency = 1
				label.Font = Enum.Font.LuckiestGuy
				label.TextSize = 32
				label.Text = "Ship Oil"
				label.TextColor3 = Color3.fromRGB(50, 220, 80)
				label.TextTransparency = 0.4
				label.TextStrokeTransparency = 0.6
				label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
				label.Parent = bb

				markerGui = bb
				markerAdornee = head
				break
			end
		end
	end

	-- Create on plot assignment
	player:GetAttributeChangedSignal("PlotId"):Connect(tryCreateMarker)
	task.delay(3, tryCreateMarker) -- initial delay for plot to load

	-- Bob animation via StudsOffset
	local t = 0
	RunService.Heartbeat:Connect(function(dt)
		t = t + dt
		if markerGui and markerGui.Parent then
			local offset = math.sin(t * 2) * 0.8
			markerGui.StudsOffset = Vector3.new(0, 10 + offset, 0)
		end
	end)
end)

-- Listen for any DeliveryManPrompt triggered
ProximityPromptService.PromptTriggered:Connect(function(prompt, trigPlayer)
	if trigPlayer ~= player then return end
	if prompt.Name ~= "DeliveryManPrompt" then return end
	local npcModel = prompt:FindFirstAncestorWhichIsA("Model")
	openDialogue(npcModel or prompt.Parent)
end)
