--!strict
-- Pirate Broker NPC dialogue (`pirateHireOpenEvent`), result/feedback (`pirateHireResultEvent`),
-- per-recipient hit alert (`pirateHitAlertEvent`). Owns the runtime `PirateHireGui` ScreenGui:
-- ephemeral, instanced on demand from a proximity prompt, auto-closes when the player walks away
-- from the `Workspace.PirateHire` model. Wired from `init.client` with `setStatus`.
--
-- StraitEventPlaytestBanner is required as a sibling under `script.Parent.UI` (same pattern as
-- `ShipmentVisualClient`), so the banner does not need to be threaded through deps.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local StraitEventPlaytestBanner = require(script.Parent:WaitForChild("UI"):WaitForChild("StraitEventPlaytestBanner"))
local HitContractConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("HitContractConfig"))
local UiSfx = require(script.Parent:WaitForChild("UiSfx")) :: {
	playPirateHitContract: () -> (),
}

export type PirateHireDeps = {
	player: Player,
	playerGui: PlayerGui,
	setStatus: (message: string, ok: boolean?) -> (),
	--- Optional locked-status writer from `ClientPlotGrid.setStatusLocked`. When
	--- present, the contractor "your hit landed" alert paints in bright gold and
	--- holds the shipment hint line for `PIRATE_HIT_CONTRACTOR_HOLD_SECONDS`
	--- before any other `setStatus` call can overwrite it. Optional so callers
	--- that haven't been updated still get the legacy (red) `setStatus` fallback.
	setStatusLocked: ((message: string, color: Color3, holdSeconds: number) -> ())?,
}

export type PirateHireRemotes = {
	requestPirateHireTargets: RemoteFunction,
	requestPirateHireAction: RemoteEvent,
	pirateHireOpenEvent: RemoteEvent,
	pirateHireResultEvent: RemoteEvent,
	pirateHitAlertEvent: RemoteEvent,
}

local PIRATE_AUTO_CLOSE_DIST = 36
local COLOR_PIRATE_IDLE = Color3.fromRGB(255, 255, 255)
local COLOR_PIRATE_HOVER = Color3.fromRGB(255, 205, 80)
local COLOR_PIRATE_DIM = Color3.fromRGB(210, 210, 210)
local COLOR_PIRATE_MONEY = Color3.fromRGB(80, 220, 80)
local COLOR_PIRATE_RED = Color3.fromRGB(255, 80, 80)

--- Bright, very-readable gold for the contractor's "your hit landed" status
--- write. Picked to clear the dark `ShipmentHint` background and read at a
--- glance against neutral white drilling chatter. Distinct from
--- `COLOR_PIRATE_HOVER` (broker dialogue accent) on purpose.
local COLOR_CONTRACTOR_HIT_LANDED = Color3.fromRGB(255, 200, 60)
--- Hold the shipment hint line for this many seconds after a contractor hit
--- alert so background `setStatus` chatter (drilling progress, prospector
--- pings) can't overwrite the breakdown before it's been read.
local PIRATE_HIT_CONTRACTOR_HOLD_SECONDS = 5

--- Big punchy red used for the victim's "RAIDED!" headline + body in
--- `StraitEventPlaytestBanner`. Hot enough to read against the workspace and
--- the typical sky/ocean background; the banner adds a black stroke on top.
local COLOR_VICTIM_RAID_BANNER = Color3.fromRGB(255, 70, 70)
--- How long the victim banner stays at full opacity before it fades out. A bit
--- longer than the default banner hold (3.8s) so the longer sentence has time
--- to read.
local PIRATE_HIT_VICTIM_BANNER_HOLD_SECONDS = 5

local PirateHireClient = {}

local function resolvePirateBrokerAnchor(): BasePart?
	local pirateHireRoot = Workspace:FindFirstChild("PirateHire") or Workspace:FindFirstChild("PirateHire", true)
	if not pirateHireRoot then
		return nil
	end
	local pirateModel = pirateHireRoot:FindFirstChild("Pirate")
	if pirateModel and pirateModel:IsA("Model") then
		local head = pirateModel:FindFirstChild("Head")
		if head and head:IsA("BasePart") then
			return head
		end
		local upper = pirateModel:FindFirstChild("UpperTorso")
		if upper and upper:IsA("BasePart") then
			return upper
		end
		local torso = pirateModel:FindFirstChild("Torso")
		if torso and torso:IsA("BasePart") then
			return torso
		end
		local hrp = pirateModel:FindFirstChild("HumanoidRootPart")
		if hrp and hrp:IsA("BasePart") then
			return hrp
		end
	end
	if pirateHireRoot:IsA("Model") then
		return pirateHireRoot.PrimaryPart or pirateHireRoot:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

function PirateHireClient.connect(deps: PirateHireDeps, remotes: PirateHireRemotes)
	local player = deps.player
	local playerGui = deps.playerGui
	local setStatus = deps.setStatus
	local setStatusLocked = deps.setStatusLocked

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

		local pirateAnchor = resolvePirateBrokerAnchor()
		local autoCloseConn
		autoCloseConn = RunService.Heartbeat:Connect(function()
			if not screen.Parent then
				if autoCloseConn then autoCloseConn:Disconnect() end
				return
			end
			local char = player.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			if hrp and pirateAnchor and pirateAnchor.Parent then
				local piratePos = pirateAnchor.Position
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

		-- Static pitch label (was a clickable "Ask a question" easter-egg button
		-- that cycled flavor quotes). Replaced with a non-interactive description
		-- of what hiring actually does so the broker dialog explains itself in
		-- one read instead of needing a "click to learn more" round-trip.
		local pitchText = string.format("I'll steal %s of your target's cargo for you.", HitContractConfig.formatStealPercent())
		local pitchLabel = blockyLine("PitchLabel", pitchText, 2, false, root)
		pitchLabel.TextSize = 26
		pitchLabel.Size = UDim2.new(1, 0, 0, 60)
		pitchLabel.TextWrapped = true
		pitchLabel.TextColor3 = COLOR_PIRATE_DIM
		local hireBtn = blockyLine("HireButton", string.format("Hire a hit ($%d)", uiState.hitCost), 3, true, root)
		if uiState.freeHitTokens > 0 then
			local freeLabel = blockyLine("FreeTokens", string.format("  Free tokens: %d", uiState.freeHitTokens), 4, false, root)
			freeLabel.TextSize = 22; freeLabel.Size = UDim2.new(1, 0, 0, 28); freeLabel.TextColor3 = COLOR_PIRATE_MONEY
		end
		local backBtn = blockyLine("BackButton", "back", 10, true, root)
		backBtn.TextSize = 28; backBtn.TextColor3 = COLOR_PIRATE_DIM
		backBtn.MouseLeave:Connect(function() backBtn.TextColor3 = COLOR_PIRATE_DIM end)
		backBtn.MouseButton1Click:Connect(closeUi)

		hireBtn.MouseButton1Click:Connect(function()
			header.Text = "Pick a target:"; header.TextSize = 38
			pitchLabel.Visible = false; hireBtn.Visible = false; backBtn.Visible = false
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
	-- `payload.kind` is "contractor" (their hire just landed, payout incoming) or
	-- "victim" (they got robbed). Stamped by `OilShipmentService:_emitPirateHitAlert`
	-- callers (see `_executeForcedContractPirateRaid`).
	--
	--   * Contractor side — paint the shipment hint bright gold, lock it for
	--     `PIRATE_HIT_CONTRACTOR_HOLD_SECONDS` so the breakdown isn't clobbered
	--     by routine status chatter, play the success cue, and show the legacy
	--     "Pirate Hit" banner.
	--   * Victim side — show a dedicated red "RAIDED!" banner with the
	--     server-built sentence ("You got raided by X and lost 50% of your
	--     barrels to them!") as the subtitle. We deliberately *do not* call
	--     `setStatus` here — the banner is the whole notification, and the
	--     status line stays free for ongoing shipment progress text.
	--   * Anything else (legacy untagged) — fall back to the previous red
	--     `setStatus` + generic banner so we don't silently drop alerts.
	pirateHitAlertEvent.OnClientEvent:Connect(function(payload)
		if typeof(payload) ~= "table" then
			return
		end
		local message = tostring(payload.message or "Pirate hit event.")
		local kind = tostring(payload.kind or "")
		if kind == "contractor" and setStatusLocked then
			setStatusLocked(message, COLOR_CONTRACTOR_HIT_LANDED, PIRATE_HIT_CONTRACTOR_HOLD_SECONDS)
			UiSfx.playPirateHitContract()
			StraitEventPlaytestBanner.show(playerGui, "Pirate Hit")
		elseif kind == "victim" then
			StraitEventPlaytestBanner.show(playerGui, "RAIDED!", {
				color = COLOR_VICTIM_RAID_BANNER,
				subtitle = message,
				holdSeconds = PIRATE_HIT_VICTIM_BANNER_HOLD_SECONDS,
			})
		else
			setStatus(message, false)
			StraitEventPlaytestBanner.show(playerGui, "Pirate Hit")
		end
	end)
end

return PirateHireClient
