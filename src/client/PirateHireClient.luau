--!strict
-- Pirate Broker NPC dialogue (`pirateHireOpenEvent`), result/feedback (`pirateHireResultEvent`),
-- per-recipient hit alert (`pirateHitAlertEvent`). Owns the runtime `PirateHireGui` ScreenGui:
-- ephemeral, instanced on demand from a proximity prompt, auto-closes when the player walks away
-- from the `Workspace.PirateHire` model. Wired from `init.client` with `setStatus`.
--
-- StraitEventPlaytestBanner is required as a sibling under `script.Parent.UI` (same pattern as
-- `ShipmentVisualClient`), so the banner does not need to be threaded through deps.

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local StraitEventPlaytestBanner = require(script.Parent:WaitForChild("UI"):WaitForChild("StraitEventPlaytestBanner"))

export type PirateHireDeps = {
	player: Player,
	playerGui: PlayerGui,
	setStatus: (message: string, ok: boolean?) -> (),
}

export type PirateHireRemotes = {
	requestPirateHireTargets: RemoteFunction,
	requestPirateHireAction: RemoteEvent,
	pirateHireOpenEvent: RemoteEvent,
	pirateHireResultEvent: RemoteEvent,
	pirateHitAlertEvent: RemoteEvent,
}

local PIRATE_AUTO_CLOSE_DIST = 12
local COLOR_PIRATE_IDLE = Color3.fromRGB(255, 255, 255)
local COLOR_PIRATE_HOVER = Color3.fromRGB(255, 205, 80)
local COLOR_PIRATE_DIM = Color3.fromRGB(210, 210, 210)
local COLOR_PIRATE_MONEY = Color3.fromRGB(80, 220, 80)
local COLOR_PIRATE_RED = Color3.fromRGB(255, 80, 80)

local PirateHireClient = {}

function PirateHireClient.connect(deps: PirateHireDeps, remotes: PirateHireRemotes)
	local player = deps.player
	local playerGui = deps.playerGui
	local setStatus = deps.setStatus

	local requestPirateHireTargets = remotes.requestPirateHireTargets
	local requestPirateHireAction = remotes.requestPirateHireAction
	local pirateHireOpenEvent = remotes.pirateHireOpenEvent
	local pirateHireResultEvent = remotes.pirateHireResultEvent
	local pirateHitAlertEvent = remotes.pirateHitAlertEvent

	local uiState = {
		screen = nil :: ScreenGui?,
		header = nil :: TextLabel?,
		selectedVictimUserId = nil :: number?,
		hitCost = 5000,
		freeHitTokens = 0,
	}

	local function closeUi()
		local s = uiState.screen
		if s and s.Parent then
			s:Destroy()
		end
		uiState.screen = nil
		uiState.header = nil
		uiState.selectedVictimUserId = nil
	end

	local function blockyLine(name, text, order, isButton, parent)
		local obj
		if isButton then
			obj = Instance.new("TextButton")
			obj.AutoButtonColor = false
			obj.Active = true
			obj.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
			obj.BackgroundTransparency = 0.99
			obj.MouseEnter:Connect(function() obj.TextColor3 = COLOR_PIRATE_HOVER; obj.BackgroundTransparency = 0.35 end)
			obj.MouseLeave:Connect(function() obj.TextColor3 = COLOR_PIRATE_IDLE; obj.BackgroundTransparency = 0.99 end)
			local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 6); c.Parent = obj
		else
			obj = Instance.new("TextLabel")
			obj.BackgroundTransparency = 1
		end
		obj.Name = name; obj.Text = text; obj.Size = UDim2.new(1, 0, 0, 42); obj.LayoutOrder = order
		obj.BorderSizePixel = 0; obj.Font = Enum.Font.LuckiestGuy; obj.TextSize = 34
		obj.TextColor3 = COLOR_PIRATE_IDLE; obj.TextStrokeTransparency = 0; obj.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
		obj.TextXAlignment = Enum.TextXAlignment.Left; obj.TextYAlignment = Enum.TextYAlignment.Center
		if parent then obj.Parent = parent end
		return obj
	end

	-- Replaces the broken `updatePirateHireInfo` reference in legacy code: if the broker
	-- panel is still open when a result arrives, briefly flash the message in the header
	-- and restore the broker label after a short delay.
	local function flashHeader(message: string)
		local header = uiState.header
		if not header or not header.Parent then return end
		header.Text = message
		header.TextSize = 28
		task.delay(2, function()
			if header.Parent and uiState.header == header then
				header.Text = "Pirate Broker:"
				header.TextSize = 44
			end
		end)
	end

	local openUi
	openUi = function(payload: any)
		closeUi()

		if typeof(payload) == "table" then
			uiState.hitCost = math.max(0, math.floor(tonumber(payload.hitCost) or uiState.hitCost))
			uiState.freeHitTokens = math.max(0, math.floor(tonumber(payload.freeHitTokens) or 0))
		end

		local screen = Instance.new("ScreenGui")
		screen.Name = "PirateHireGui"
		screen.ResetOnSpawn = false
		screen.IgnoreGuiInset = true
		screen.DisplayOrder = 60
		screen.Parent = playerGui
		uiState.screen = screen

		local pirateModel = Workspace:FindFirstChild("PirateHire") or Workspace:FindFirstChild("PirateHire", true)
		local autoCloseConn
		autoCloseConn = RunService.Heartbeat:Connect(function()
			if not screen.Parent then
				if autoCloseConn then autoCloseConn:Disconnect() end
				return
			end
			local char = player.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			if hrp and pirateModel then
				local piratePos = pirateModel:GetPivot().Position
				if ((hrp :: BasePart).Position - piratePos).Magnitude > PIRATE_AUTO_CLOSE_DIST then
					closeUi()
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

		local header = blockyLine("Header", "Pirate Broker:", 1, false, root)
		header.Size = UDim2.new(1, 0, 0, 50); header.TextSize = 44
		uiState.header = header

		local askBtn = blockyLine("AskButton", "Ask a question", 2, true, root)
		local hireBtn = blockyLine("HireButton", string.format("Hire a hit ($%d)", uiState.hitCost), 3, true, root)
		if uiState.freeHitTokens > 0 then
			local freeLabel = blockyLine("FreeTokens", string.format("  Free tokens: %d", uiState.freeHitTokens), 4, false, root)
			freeLabel.TextSize = 22; freeLabel.Size = UDim2.new(1, 0, 0, 28); freeLabel.TextColor3 = COLOR_PIRATE_MONEY
		end
		local backBtn = blockyLine("BackButton", "back", 10, true, root)
		backBtn.TextSize = 28; backBtn.TextColor3 = COLOR_PIRATE_DIM
		backBtn.MouseLeave:Connect(function() backBtn.TextColor3 = COLOR_PIRATE_DIM end)
		backBtn.MouseButton1Click:Connect(closeUi)

		askBtn.MouseButton1Click:Connect(function()
			requestPirateHireAction:FireServer({ action = "ask" })
			local quotes = {"Arrr, the seas be rough today!", "I know every ship in these waters.", "Gold talks, sailor.", "Need someone sunk? I know a crew.", "The strait takes what it wants!"}
			header.Text = quotes[math.random(1, #quotes)]; header.TextSize = 28
			task.delay(2, function() if header.Parent then header.Text = "Pirate Broker:"; header.TextSize = 44 end end)
		end)

		hireBtn.MouseButton1Click:Connect(function()
			header.Text = "Pick a target:"; header.TextSize = 38
			askBtn.Visible = false; hireBtn.Visible = false; backBtn.Visible = false
			for _, c in ipairs(root:GetChildren()) do if c.Name:find("Target_") or c.Name == "FreeTokens" or c.Name == "NoTargets" or c.Name == "HireBack" then c:Destroy() end end

			local ok, result = pcall(function()
				return requestPirateHireTargets:InvokeServer()
			end)
			if not ok or typeof(result) ~= "table" then
				local errLabel = blockyLine("NoTargets", "Could not fetch targets", 5, false, root)
				errLabel.TextSize = 22; errLabel.Size = UDim2.new(1, 0, 0, 28); errLabel.TextColor3 = COLOR_PIRATE_RED
			else
				uiState.freeHitTokens = math.max(0, math.floor(tonumber((result :: any).freeHitTokens) or 0))
				uiState.hitCost = math.max(0, math.floor(tonumber((result :: any).hitCost) or uiState.hitCost))
				local targets = (result :: any).targets
				local order = 5
				if typeof(targets) == "table" and #targets > 0 then
					for _, target in ipairs(targets) do
						if typeof(target) == "table" then
							local userId = tonumber(target.userId)
							if userId then
								local dn = tostring(target.displayName or target.name or ("User " .. tostring(userId)))
								local label = string.format("%s", dn)
								local tBtn = blockyLine("Target_" .. tostring(userId), label, order, true, root)
								tBtn.TextSize = 26; tBtn.Size = UDim2.new(1, 0, 0, 34)
								local costLabel = Instance.new("TextLabel")
								costLabel.Size = UDim2.new(0.4, 0, 1, 0); costLabel.Position = UDim2.new(0.6, 0, 0, 0)
								costLabel.BackgroundTransparency = 1; costLabel.Text = string.format("$%d", uiState.hitCost)
								costLabel.Font = Enum.Font.LuckiestGuy; costLabel.TextSize = 22; costLabel.TextColor3 = COLOR_PIRATE_MONEY
								costLabel.TextStrokeTransparency = 0; costLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
								costLabel.TextXAlignment = Enum.TextXAlignment.Right; costLabel.Parent = tBtn
								tBtn.MouseButton1Click:Connect(function()
									requestPirateHireAction:FireServer({ action = "hire", victimUserId = userId })
									header.Text = "Pirates dispatched!"; header.TextSize = 32
									task.delay(1.5, closeUi)
								end)
								order += 1
							end
						end
					end
				else
					local noTargets = blockyLine("NoTargets", "No ships on the strait", 5, false, root)
					noTargets.TextSize = 22; noTargets.Size = UDim2.new(1, 0, 0, 28); noTargets.TextColor3 = COLOR_PIRATE_DIM
				end
			end

			local hireBack = blockyLine("HireBack", "back", 99, true, root)
			hireBack.TextSize = 24; hireBack.TextColor3 = COLOR_PIRATE_DIM
			hireBack.MouseLeave:Connect(function() hireBack.TextColor3 = COLOR_PIRATE_DIM end)
			hireBack.MouseButton1Click:Connect(function() closeUi(); openUi(payload) end)
		end)
	end

	pirateHireOpenEvent.OnClientEvent:Connect(function(payload)
		openUi(payload)
	end)

	pirateHireResultEvent.OnClientEvent:Connect(function(payload)
		if typeof(payload) ~= "table" then
			return
		end
		local ok = payload.ok == true
		local message = tostring(payload.message or "")
		if message ~= "" then
			setStatus(message, ok)
			flashHeader(message)
		end
		local data = payload.data
		if typeof(data) == "table" then
			local tokens = tonumber((data :: any).freeHitTokens)
			if tokens then
				uiState.freeHitTokens = math.max(0, math.floor(tokens))
			end
		end
	end)

	-- Server uses FireClient per recipient; banner only reaches impacted players.
	pirateHitAlertEvent.OnClientEvent:Connect(function(payload)
		if typeof(payload) ~= "table" then
			return
		end
		local message = tostring(payload.message or "Pirate hit event.")
		setStatus(message, false)
		StraitEventPlaytestBanner.show(playerGui, "Pirate Hit")
	end)
end

return PirateHireClient
