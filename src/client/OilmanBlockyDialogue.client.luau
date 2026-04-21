--!strict
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local clientFolder = player:WaitForChild("PlayerScripts"):WaitForChild("Client")
local getClientRemotes = require(clientFolder:WaitForChild("GetClientRemotes")) :: () -> any
local ClientRemotes = getClientRemotes()
--- Free the cursor from `LockCenter` while this dialogue is open. See
--- `src/client/UI/HudMousePolicy.luau` — required for any runtime-built dialog whose
--- ScreenGui isn't bound through `HudPanelRouter`.
local HudMousePolicy = require(clientFolder:WaitForChild("UI"):WaitForChild("HudMousePolicy"))
local oilmanSellRemote = ClientRemotes.requestOilmanSell
local oilStateUpdate = ClientRemotes.oilStateUpdate

-- Oilman buys at a FIXED discount price, not market price
local OILMAN_PRICES = { Crude = 5, Refined = 8, Premium = 12 }

local COLOR_IDLE = Color3.fromRGB(255, 255, 255)
local COLOR_HOVER = Color3.fromRGB(255, 205, 80)
local COLOR_DIM = Color3.fromRGB(210, 210, 210)
local COLOR_GRAY = Color3.fromRGB(100, 100, 100)
local COLOR_GOLD = Color3.fromRGB(255, 170, 60)
local oilmanGuiOpen = false
local currentOilByTier = {}
local AUTO_CLOSE_DIST = 12

oilStateUpdate.OnClientEvent:Connect(function(data)
	if typeof(data) == "table" and typeof(data.oilByTier) == "table" then
		currentOilByTier = data.oilByTier
	end
end)

local function blockyLine(name, text, order, isButton, parent)
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

local function closeOilmanGui()
	local existing = playerGui:FindFirstChild("OilmanBlockyGui")
	if existing then existing:Destroy() end
	oilmanGuiOpen = false
end

local function sellOil(quantities, shouldClose)
	local rid = HttpService:GenerateGUID(false)
	if oilmanSellRemote then oilmanSellRemote:FireServer({quantities = quantities, requestId = rid}) end
	if shouldClose then
		-- Show farewell message briefly then close
		local gui = playerGui:FindFirstChild("OilmanBlockyGui")
		if gui then
			local root = gui:FindFirstChild("Root")
			if root then
				for _, c in ipairs(root:GetChildren()) do
					if c:IsA("TextButton") or c:IsA("TextLabel") then c.Visible = false end
				end
				local farewell = Instance.new("TextLabel")
				farewell.Name = "Farewell"
				farewell.Size = UDim2.new(1, 0, 0, 50)
				farewell.BackgroundTransparency = 1
				farewell.Text = "Good doing business with you!"
				farewell.Font = Enum.Font.LuckiestGuy
				farewell.TextSize = 36
				farewell.TextColor3 = COLOR_GOLD
				farewell.TextStrokeTransparency = 0
				farewell.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
				farewell.TextXAlignment = Enum.TextXAlignment.Left
				farewell.Parent = root
			end
		end
		task.delay(1.5, closeOilmanGui)
	else
		-- Show quick confirmation without closing
		local gui = playerGui:FindFirstChild("OilmanBlockyGui")
		if gui then
			local root = gui:FindFirstChild("Root")
			local header = root and root:FindFirstChild("Header")
			if header then
				header.Text = "Good doing business with you!"
				header.TextSize = 28
				task.delay(1.5, function()
					if header.Parent then
						header.Text = "Sell Oil:"
						header.TextSize = 38
					end
				end)
			end
		end
	end
end

local function openOilmanGui()
	closeOilmanGui()
	oilmanGuiOpen = true
	local screen = Instance.new("ScreenGui")
	screen.Name = "OilmanBlockyGui"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 60
	screen.Parent = playerGui
	HudMousePolicy.RegisterScreenGui(screen)

	-- Auto-close when walking away or pressing E
	local oilmanModel = Workspace:FindFirstChild("Oilman")
	local autoCloseConn
	autoCloseConn = RunService.Heartbeat:Connect(function()
		if not screen.Parent then
			if autoCloseConn then autoCloseConn:Disconnect() end
			return
		end
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if hrp and oilmanModel then
			local oilmanPos = oilmanModel:GetPivot().Position
			if (hrp.Position - oilmanPos).Magnitude > AUTO_CLOSE_DIST then
				closeOilmanGui()
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

	local header = blockyLine("Header", "Oilman Jack:", 1, false, root)
	header.Size = UDim2.new(1, 0, 0, 50); header.TextSize = 44
	local sellBtn = blockyLine("SellButton", "Sell your oil (at a discount)", 2, true, root)
	local msgBtn = blockyLine("MessageButton", "Message", 3, true, root)
	local backBtn = blockyLine("BackButton", "back", 4, true, root)
	backBtn.TextSize = 28; backBtn.TextColor3 = COLOR_DIM
	backBtn.MouseLeave:Connect(function() backBtn.TextColor3 = COLOR_DIM end)
	backBtn.MouseButton1Click:Connect(closeOilmanGui)

	msgBtn.MouseButton1Click:Connect(function()
		local quotes = {"Oil prices are crazy right now!", "You look like you struck gold!", "I buy oil, you get cash. Simple.", "Careful out on the strait!", "Business is booming!"}
		header.Text = quotes[math.random(1, #quotes)]; header.TextSize = 28
		task.delay(2, function() if header.Parent then header.Text = "Oilman Jack:"; header.TextSize = 44 end end)
	end)

	sellBtn.MouseButton1Click:Connect(function()
		header.Text = "Sell Oil:"; header.TextSize = 38
		sellBtn.Visible = false; msgBtn.Visible = false; backBtn.Visible = false
		for _, c in ipairs(root:GetChildren()) do if c.Name:find("Sell_") then c:Destroy() end end

		local OIL_COLORS = {
			Crude = Color3.fromRGB(200, 200, 200),
			Refined = Color3.fromRGB(240, 200, 70),
			Premium = Color3.fromRGB(255, 150, 200),
		}
		local COLOR_MONEY = Color3.fromRGB(80, 220, 80)
		local tiers = {{key="Crude",label="Crude"},{key="Refined",label="Refined"},{key="Premium",label="Premium"}}
		local order = 5
		for _, tier in ipairs(tiers) do
			local amt = math.floor(currentOilByTier[tier.key] or 0)
			local price = OILMAN_PRICES[tier.key] or 5
			-- Oil type header colored by oil spray color
			local tierHeader = blockyLine("Sell_h_" .. tier.key, string.format("%s (%d)", tier.label, amt), order, false, root)
			tierHeader.TextSize = 24; tierHeader.Size = UDim2.new(1, 0, 0, 30)
			tierHeader.TextColor3 = OIL_COLORS[tier.key] or COLOR_IDLE
			if amt <= 0 then tierHeader.TextColor3 = COLOR_GRAY end
			order += 1

			if amt >= 1 then
				local b1 = blockyLine("Sell_1_" .. tier.key, "  Sell 1x", order, true, root)
				b1.TextSize = 22; b1.Size = UDim2.new(1, 0, 0, 28)
				-- Add green money label
				local m1 = Instance.new("TextLabel")
				m1.Size = UDim2.new(0.4, 0, 1, 0); m1.Position = UDim2.new(0.6, 0, 0, 0)
				m1.BackgroundTransparency = 1; m1.Text = string.format("$%d", price)
				m1.Font = Enum.Font.LuckiestGuy; m1.TextSize = 22; m1.TextColor3 = COLOR_MONEY
				m1.TextStrokeTransparency = 0; m1.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
				m1.TextXAlignment = Enum.TextXAlignment.Right; m1.Parent = b1
				b1.MouseButton1Click:Connect(function() sellOil({[tier.key] = 1}, false) end)
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
				b5.MouseButton1Click:Connect(function() sellOil({[tier.key] = 5}, false) end)
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
				ba.MouseButton1Click:Connect(function() sellOil({[tier.key] = amt}, false) end)
				order += 1
			end
		end

		local sellAll = blockyLine("Sell_Everything", "Sell Everything", order, true, root)
		sellAll.TextSize = 28; sellAll.TextColor3 = COLOR_GOLD
		sellAll.MouseLeave:Connect(function() sellAll.TextColor3 = COLOR_GOLD end)
		sellAll.MouseButton1Click:Connect(function()
			local quantities = {}
			for _, tier in ipairs(tiers) do
				local amt = math.floor(currentOilByTier[tier.key] or 0)
				if amt > 0 then quantities[tier.key] = amt end
			end
			sellOil(quantities, true)
		end)
		order += 1

		local sellBack = blockyLine("Sell_Back", "back", order, true, root)
		sellBack.TextSize = 24; sellBack.TextColor3 = COLOR_DIM
		sellBack.MouseLeave:Connect(function() sellBack.TextColor3 = COLOR_DIM end)
		sellBack.MouseButton1Click:Connect(function() closeOilmanGui(); openOilmanGui() end)
	end)
end

local function wireOilmanPrompt(prompt)
	prompt.Triggered:Connect(function(triggeringPlayer)
		if triggeringPlayer ~= player then return end
		if oilmanGuiOpen then closeOilmanGui() else openOilmanGui() end
	end)
end

local oilman = Workspace:FindFirstChild("Oilman")
if oilman then
	for _, d in ipairs(oilman:GetDescendants()) do
		if d:IsA("ProximityPrompt") and d.Name == "OilmanDialoguePrompt" then wireOilmanPrompt(d) end
	end
	oilman.DescendantAdded:Connect(function(d)
		if d:IsA("ProximityPrompt") and d.Name == "OilmanDialoguePrompt" then wireOilmanPrompt(d) end
	end)
else
	Workspace.ChildAdded:Connect(function(child)
		if child.Name == "Oilman" then
			task.defer(function()
				for _, d in ipairs(child:GetDescendants()) do
					if d:IsA("ProximityPrompt") and d.Name == "OilmanDialoguePrompt" then wireOilmanPrompt(d) end
				end
				child.DescendantAdded:Connect(function(d)
					if d:IsA("ProximityPrompt") and d.Name == "OilmanDialoguePrompt" then wireOilmanPrompt(d) end
				end)
			end)
		end
	end)
end
