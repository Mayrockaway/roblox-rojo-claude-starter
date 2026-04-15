--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local StarterGui = game:GetService("StarterGui")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local mouse = player:GetMouse()

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))
local Constants = require(Shared:WaitForChild("Constants"))
local OilConfig = require(Shared:WaitForChild("Config"):WaitForChild("OilConfig"))
local PlacementAnchor = require(Shared:WaitForChild("Utils"):WaitForChild("PlacementAnchor"))

type StraitWaypointFxModule = {
	OnStraitWaypointPayload: (data: { [string]: any }) -> (),
	OnMissileStrikePayload: (data: { [string]: any }) -> (),
	OnMineStrikePayload: (data: { [string]: any }) -> (),
	OnPirateRaidPayload: (data: { [string]: any }) -> (),
	OnCoastGuardInspectionPayload: (data: { [string]: any }) -> (),
	OnUSShipSlapPayload: (data: { [string]: any }) -> (),
	OnStormPayload: (data: { [string]: any }) -> (),
	OnTornadoPayload: (data: { [string]: any }) -> (),
}

local function straitWaypointFxStub(): StraitWaypointFxModule
	return {
		OnStraitWaypointPayload = function() end,
		OnMissileStrikePayload = function() end,
		OnMineStrikePayload = function() end,
		OnPirateRaidPayload = function() end,
		OnCoastGuardInspectionPayload = function() end,
		OnUSShipSlapPayload = function() end,
		OnStormPayload = function() end,
		OnTornadoPayload = function() end,
	}
end

local function requireStraitWaypointWorldFx(): StraitWaypointFxModule
	local modScript: ModuleScript? = nil

	-- Rojo: init and StraitWaypointWorldFx are siblings under StarterPlayerScripts.Client
	local sibling = script.Parent:FindFirstChild("StraitWaypointWorldFx")
	if sibling and sibling:IsA("ModuleScript") then
		modScript = sibling
	end

	-- Wrong parent (e.g. LocalScript under PlayerScripts): module still lives under .Client
	if not modScript then
		local ps = player:WaitForChild("PlayerScripts", 30)
		local clientFolder = ps:FindFirstChild("Client")
		if clientFolder then
			local m = clientFolder:FindFirstChild("StraitWaypointWorldFx")
			if m and m:IsA("ModuleScript") then
				modScript = m
			end
		end
		if not modScript then
			clientFolder = ps:WaitForChild("Client", 25)
			if clientFolder then
				local m = clientFolder:WaitForChild("StraitWaypointWorldFx", 25)
				if m and m:IsA("ModuleScript") then
					modScript = m
				end
			end
		end
	end

	if modScript then
		local ok, result = pcall(require, modScript)
		if ok and typeof(result) == "table" then
			return result
		end
		warn("[Client] StraitWaypointWorldFx failed to load: ", result)
		return straitWaypointFxStub()
	end

	warn(
		"[Client] StraitWaypointWorldFx not found under PlayerScripts.Client after 25s — sync Rojo (src/client) so Client contains the ModuleScript."
	)
	return straitWaypointFxStub()
end

local StraitWaypointWorldFx = requireStraitWaypointWorldFx()
local StraitEventPlaytestBanner = require(script:WaitForChild("UI"):WaitForChild("StraitEventPlaytestBanner"))

local remotesFolder = Shared:FindFirstChild("Remotes")
while remotesFolder == nil do
	task.wait(0.1)
	remotesFolder = Shared:FindFirstChild("Remotes")
end

local REMOTE_WAIT_SECS = 60
local function waitRemote(name: string): Instance
	local child = remotesFolder:WaitForChild(name, REMOTE_WAIT_SECS)
	if not child then
		error(
			string.format(
				"[Client] Timed out waiting for Remotes.%s — is Server running RemoteService:Init()?",
				name
			),
			0
		)
	end
	return child
end

local requestOilSnapshot = waitRemote(RemoteNames.RequestOilSnapshot) :: RemoteFunction
local requestPlaceDrill = waitRemote(RemoteNames.RequestPlaceDrill) :: RemoteEvent
local requestStartDrill = waitRemote(RemoteNames.RequestStartDrill) :: RemoteEvent
local requestPlacePump = waitRemote(RemoteNames.RequestPlacePump) :: RemoteEvent
local drillProgressUpdate = waitRemote(RemoteNames.DrillProgressUpdate) :: RemoteEvent
local requestProspect = waitRemote(RemoteNames.RequestProspect) :: RemoteEvent
local prospectProgressUpdate = waitRemote(RemoteNames.ProspectProgressUpdate) :: RemoteEvent
local requestHammerDestroy = waitRemote(RemoteNames.RequestHammerDestroy) :: RemoteEvent
local requestRemoveDrill = waitRemote(RemoteNames.RequestRemoveDrill) :: RemoteEvent
local requestBuyChunk = waitRemote(RemoteNames.RequestBuyChunk) :: RemoteEvent
local requestPlacePipe = waitRemote(RemoteNames.RequestPlacePipe) :: RemoteEvent
local requestRemovePipe = waitRemote(RemoteNames.RequestRemovePipe) :: RemoteEvent
local requestPickupBarrel = waitRemote(RemoteNames.RequestPickupBarrel) :: RemoteEvent
local requestTeleportToShip = waitRemote(RemoteNames.RequestTeleportToShip) :: RemoteEvent
local requestTeleportHome = waitRemote(RemoteNames.RequestTeleportHome) :: RemoteEvent
local requestUpgradeWarehouse = waitRemote(RemoteNames.RequestUpgradeWarehouse) :: RemoteEvent
local requestSellAllWarehouse = waitRemote(RemoteNames.RequestSellAllWarehouse) :: RemoteEvent
local requestTeleportToWarehouse = waitRemote(RemoteNames.RequestTeleportToWarehouse) :: RemoteEvent
local warehouseStateUpdate = waitRemote(RemoteNames.WarehouseStateUpdate) :: RemoteEvent
local requestWarehouseSnapshot = waitRemote(RemoteNames.RequestWarehouseSnapshot) :: RemoteFunction
-- RequestClearObstacle remote no longer bound (obstacle system removed)
local biomeRevealEvent = waitRemote(RemoteNames.BiomeRevealEvent) :: RemoteEvent
local requestDispatchShipment = waitRemote(RemoteNames.RequestDispatchShipment) :: RemoteEvent
local oilStateUpdate = waitRemote(RemoteNames.OilStateUpdate) :: RemoteEvent
local oilActionResult = waitRemote(RemoteNames.OilActionResult) :: RemoteEvent
local shipmentVisualEvent = waitRemote(RemoteNames.ShipmentVisualEvent) :: RemoteEvent
local requestDevSetStraitBracket = waitRemote(RemoteNames.RequestDevSetStraitBracket) :: RemoteEvent
local globalStateUpdate = waitRemote(RemoteNames.GlobalStateUpdate) :: RemoteEvent
local fighterFlyoverEvent = waitRemote(RemoteNames.FighterFlyoverEvent) :: RemoteEvent
local requestPirateHireTargets = waitRemote(RemoteNames.RequestPirateHireTargets) :: RemoteFunction
local requestPirateHireAction = waitRemote(RemoteNames.RequestPirateHireAction) :: RemoteEvent
local pirateHireOpenEvent = waitRemote(RemoteNames.PirateHireOpen) :: RemoteEvent
local pirateHireResultEvent = waitRemote(RemoteNames.PirateHireResult) :: RemoteEvent
local pirateHitAlertEvent = waitRemote(RemoteNames.PirateHitAlert) :: RemoteEvent

-- Dev diagnostic: mirror server-side [PlotService]/[OilState]/[ChunkOwnership] prints
-- to this client's Output so the user doesn't have to hunt the Server Studio process.
local devLogEvent = waitRemote(RemoteNames.DevLog) :: RemoteEvent
devLogEvent.OnClientEvent:Connect(function(msg)
	print("[SRV] " .. tostring(msg))
end)

local function requireFighterPlaneFlyoverFx(): { Start: (RemoteEvent) -> (), Stop: () -> () }?
	local modScript: ModuleScript? = nil
	local sibling = script.Parent:FindFirstChild("FighterPlaneFlyoverFx")
	if sibling and sibling:IsA("ModuleScript") then
		modScript = sibling
	end

	if not modScript then
		local ps = player:FindFirstChild("PlayerScripts") or player:WaitForChild("PlayerScripts", 30)
		local clientFolder = ps and ps:FindFirstChild("Client")
		local m = clientFolder and clientFolder:FindFirstChild("FighterPlaneFlyoverFx")
		if m and m:IsA("ModuleScript") then
			modScript = m
		end
	end

	if not modScript then
		warn("[Client] FighterPlaneFlyoverFx module missing; jet flyovers will not render.")
		return nil
	end

	local ok, loaded = pcall(require, modScript)
	if ok and typeof(loaded) == "table" then
		return loaded :: any
	end

	warn("[Client] FighterPlaneFlyoverFx failed to load:", loaded)
	return nil
end

local fighterPlaneFlyoverFx = requireFighterPlaneFlyoverFx()
if fighterPlaneFlyoverFx then
	fighterPlaneFlyoverFx.Start(fighterFlyoverEvent)
end

local function requireStraitDevPanel(): { mount: (PlayerGui, RemoteEvent, RemoteEvent) -> (), shouldShow: () -> boolean }?
	local modScript: ModuleScript? = nil
	-- Rojo: LocalScript under PlayerScripts.Client, UI sibling
	local siblingUi = script.Parent and script.Parent:FindFirstChild("UI")
	if siblingUi then
		local m = siblingUi:FindFirstChild("StraitDevPanel")
		if m and m:IsA("ModuleScript") then
			modScript = m
		end
	end
	-- Script under PlayerScripts (flat); module under PlayerScripts.Client.UI
	if not modScript then
		local ps = player:FindFirstChild("PlayerScripts") or player:WaitForChild("PlayerScripts", 30)
		local clientFolder = ps:FindFirstChild("Client")
		if clientFolder then
			local ui = clientFolder:FindFirstChild("UI")
			local m = ui and ui:FindFirstChild("StraitDevPanel")
			if m and m:IsA("ModuleScript") then
				modScript = m
			end
		end
		if not modScript then
			clientFolder = ps:WaitForChild("Client", 25)
			local ui = clientFolder:WaitForChild("UI", 25)
			local m = ui:WaitForChild("StraitDevPanel", 25)
			if m:IsA("ModuleScript") then
				modScript = m
			end
		end
	end
	if not modScript then
		warn("[Client] StraitDevPanel not found — ensure Rojo syncs `src/client/UI/StraitDevPanel.luau` under PlayerScripts.Client.UI")
		return nil
	end
	local ok, result = pcall(require, modScript)
	if ok and typeof(result) == "table" then
		return result :: any
	end
	warn("[Client] StraitDevPanel require failed:", result)
	return nil
end

local straitDevPanel = requireStraitDevPanel()
if straitDevPanel then
	straitDevPanel.mount(playerGui, requestDevSetStraitBracket, globalStateUpdate)
end
local marketPriceUpdate = waitRemote(RemoteNames.MarketPriceUpdate) :: RemoteEvent
local requestSellWarehouseType = waitRemote(RemoteNames.RequestSellWarehouseType) :: RemoteEvent
local requestMarketSnapshot = waitRemote(RemoteNames.RequestMarketSnapshot) :: RemoteFunction

local TOOL_DRILL = "Drill"
local TOOL_PIPE = "Pipe"

local state = nil
local cashTextLabel: TextLabel? = nil

local config = {
	drillPlacementCost = 200,
	drillMinSpacing = 6,
	removeDrillHoldSeconds = 2,
	removeDrillRangeStuds = 18,
	pipeCost = 50,
	pipeMinLength = 4,
	pipeMaxLength = 60,
	pipeSnapRadius = 3,
	chunks = { size = 8, rows = 10, cols = 10, startingCenterSize = 4 },
	shipSkinCatalog = {},
}

local ownedPlot: Model? = nil
local chunkPartById = {}
local chunkStateById = {}
local drillStateById = {}
local pipeStateByCellKey = {}
local drumStateByCellKey = {}
local focusBillboard: BillboardGui? = nil
local focusLabel: TextLabel? = nil

local removeHoldStart = 0
local removeHoldDrillId: number? = nil
local promptConnections = {}

-- Pipe ghost (cell-grid)
local pipeGhost: Model? = nil
local lastPipeDebugAt = 0

local function pipeDebugLog(msg: string)
	if not RunService:IsStudio() then
		return
	end
	local now = os.clock()
	if now - lastPipeDebugAt < 0.12 then
		return
	end
	lastPipeDebugAt = now
	print("[PipeDebug] " .. msg)
end

-- =================== CLIENT CELL-GRID HELPERS ===================
local SUB_TILE_SIZE = 8
local _clientGridCache = nil
local function plotGridConstants()
	if _clientGridCache then return unpack(_clientGridCache) end

	local sectionCols = (config.chunks and config.chunks.cols) or 3
	local sectionRows = (config.chunks and config.chunks.rows) or 4
	local sectionSize = (config.chunks and config.chunks.size) or 40
	local subTilesPerSide = math.floor(sectionSize / SUB_TILE_SIZE)

	-- Derive center from actual plot sections instead of hardcoding
	local centerX, centerZ = -840, -1020
	if ownedPlot then
		local ground = ownedPlot:FindFirstChild("PlotGround")
		if ground then
			local totalX, totalZ, count = 0, 0, 0
			for _, section in ipairs(ground:GetChildren()) do
				if section:IsA("Model") then
					local cx = section:GetAttribute("CenterX")
					local cz = section:GetAttribute("CenterZ")
					if typeof(cx) == "number" and typeof(cz) == "number" then
						totalX += cx
						totalZ += cz
						count += 1
					end
				end
			end
			if count > 0 then
				centerX = totalX / count
				centerZ = totalZ / count
			end
		end
	end

	local startX = centerX - ((sectionCols - 1) / 2) * sectionSize
	local startZ = centerZ - ((sectionRows - 1) / 2) * sectionSize
	local cellOriginX = startX - ((subTilesPerSide - 1) / 2) * SUB_TILE_SIZE
	local cellOriginZ = startZ - ((subTilesPerSide - 1) / 2) * SUB_TILE_SIZE
	local globalCols = sectionCols * subTilesPerSide
	local globalRows = sectionRows * subTilesPerSide

	_clientGridCache = { cellOriginX, cellOriginZ, globalRows, globalCols, subTilesPerSide }
	return cellOriginX, cellOriginZ, globalRows, globalCols, subTilesPerSide
end

local function cellKeyOf(row, col): string
	return string.format("R%dC%d", row, col)
end

local function readLocalFtueCellKey(attributeName: string): string?
	local v = player:GetAttribute(attributeName)
	if typeof(v) ~= "string" then
		return nil
	end
	local s = (v :: string):gsub("^%s+", ""):gsub("%s+$", "")
	if s == "" then
		return nil
	end
	return s
end

local function clientWorldToCell(x, z): (number, number)
	local cellOriginX, cellOriginZ = plotGridConstants()
	local col = math.floor((x - cellOriginX) / SUB_TILE_SIZE + 0.5) + 1
	local row = math.floor((z - cellOriginZ) / SUB_TILE_SIZE + 0.5) + 1
	return row, col
end

local function clientCellToWorld(row, col): (number, number)
	local cellOriginX, cellOriginZ = plotGridConstants()
	local x = cellOriginX + (col - 1) * SUB_TILE_SIZE
	local z = cellOriginZ + (row - 1) * SUB_TILE_SIZE
	return x, z
end

local function clientCellInBounds(row, col): boolean
	local _, _, globalRows, globalCols = plotGridConstants()
	return row >= 1 and row <= globalRows and col >= 1 and col <= globalCols
end

--- Shipment strip `Hint` under `HUD` / `ShipmentProgressPanel` (see CANONICAL_STUDIO_LAYOUT.md).
local function resolveShipmentHintLine(): (TextLabel | TextButton)?
	local panel = playerGui:FindFirstChild("ShipmentProgressPanel", true)
	if not (panel and panel:IsA("GuiObject")) then
		return nil
	end
	local hint = panel:FindFirstChild("Hint", true)
	if hint and hint:IsA("TextLabel") then
		return hint
	end
	if hint and hint:IsA("TextButton") then
		return hint
	end
	if hint and hint:IsA("GuiObject") then
		for _, d in ipairs(hint:GetDescendants()) do
			if d:IsA("TextLabel") or d:IsA("TextButton") then
				return d
			end
		end
	end
	return nil
end

local function setStatus(message: string, ok: boolean?)
	local line = resolveShipmentHintLine()
	if line then
		line.RichText = false
		line.Text = message
		if ok == true then
			line.TextColor3 = Color3.fromRGB(75, 200, 115)
		elseif ok == false then
			line.TextColor3 = Color3.fromRGB(235, 100, 100)
		else
			line.TextColor3 = Color3.fromRGB(218, 228, 240)
		end
	end
	if RunService:IsStudio() then
		print("[Client] status:", message, " ok=", ok)
	end
end

local pirateHireUiState = {
	screen = nil :: ScreenGui?,
	targetList = nil :: ScrollingFrame?,
	infoLabel = nil :: TextLabel?,
	confirmButton = nil :: TextButton?,
	selectedVictimUserId = nil :: number?,
	hitCost = 5000,
	freeHitTokens = 0,
}

local function closePirateHireUi()
	local s = pirateHireUiState.screen
	if s and s.Parent then
		s:Destroy()
	end
	pirateHireUiState.screen = nil
	pirateHireUiState.targetList = nil
	pirateHireUiState.infoLabel = nil
	pirateHireUiState.confirmButton = nil
	pirateHireUiState.selectedVictimUserId = nil
end

local function updatePirateHireInfo(text: string)
	local label = pirateHireUiState.infoLabel
	if label then
		label.Text = text
	end
end

local function refreshPirateHireTargets()
	local targetList = pirateHireUiState.targetList
	if not targetList then
		return
	end

	for _, child in ipairs(targetList:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end

	local ok, payload = pcall(function()
		return requestPirateHireTargets:InvokeServer()
	end)
	if not ok or typeof(payload) ~= "table" then
		updatePirateHireInfo("Could not fetch targets.")
		return
	end

	pirateHireUiState.freeHitTokens = math.max(0, math.floor(tonumber((payload :: any).freeHitTokens) or 0))
	pirateHireUiState.hitCost = math.max(0, math.floor(tonumber((payload :: any).hitCost) or pirateHireUiState.hitCost))

	local y = 0
	local targets = (payload :: any).targets
	if typeof(targets) == "table" then
		for _, target in ipairs(targets) do
			if typeof(target) == "table" then
				local userId = tonumber(target.userId)
				if userId then
					local btn = Instance.new("TextButton")
					btn.Name = "Target_" .. tostring(userId)
					btn.Size = UDim2.new(1, -6, 0, 32)
					btn.Position = UDim2.new(0, 3, 0, y)
					btn.BackgroundColor3 = Color3.fromRGB(35, 42, 54)
					btn.TextColor3 = Color3.fromRGB(239, 244, 255)
					btn.TextXAlignment = Enum.TextXAlignment.Left
					btn.Font = Enum.Font.Gotham
					btn.TextSize = 14
					local dn = tostring(target.displayName or target.name or ("User " .. tostring(userId)))
					local un = tostring(target.name or "")
					btn.Text = string.format("  %s (%s)", dn, un)
					btn.Parent = targetList
					btn.MouseButton1Click:Connect(function()
						pirateHireUiState.selectedVictimUserId = userId
						updatePirateHireInfo(string.format(
							"Selected: %s | Cost: $%d%s",
							dn,
							pirateHireUiState.hitCost,
							pirateHireUiState.freeHitTokens > 0 and string.format(" (or 1 free token, you have %d)", pirateHireUiState.freeHitTokens) or ""
						))
					end)
					y += 35
				end
			end
		end
	end

	targetList.CanvasSize = UDim2.new(0, 0, 0, math.max(y, 1))
	if y <= 0 then
		updatePirateHireInfo("No valid targets online right now.")
	else
		updatePirateHireInfo(string.format(
			"Pick a target. Cost: $%d%s",
			pirateHireUiState.hitCost,
			pirateHireUiState.freeHitTokens > 0 and string.format(" | Free tokens: %d", pirateHireUiState.freeHitTokens) or ""
		))
	end
end

local function openPirateHireUi(payload: any)
	closePirateHireUi()

	if typeof(payload) == "table" then
		pirateHireUiState.hitCost = math.max(0, math.floor(tonumber(payload.hitCost) or pirateHireUiState.hitCost))
		pirateHireUiState.freeHitTokens = math.max(0, math.floor(tonumber(payload.freeHitTokens) or 0))
	end

	local screen = Instance.new("ScreenGui")
	screen.Name = "PirateHireGui"
	screen.ResetOnSpawn = false
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screen.Parent = playerGui
	pirateHireUiState.screen = screen

	local dim = Instance.new("Frame")
	dim.Name = "Dim"
	dim.Size = UDim2.fromScale(1, 1)
	dim.BackgroundColor3 = Color3.new(0, 0, 0)
	dim.BackgroundTransparency = 0.35
	dim.BorderSizePixel = 0
	dim.Parent = screen

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(520, 420)
	panel.BackgroundColor3 = Color3.fromRGB(20, 25, 34)
	panel.BorderSizePixel = 0
	panel.Parent = dim

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, -16, 0, 34)
	title.Position = UDim2.fromOffset(8, 8)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 20
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = Color3.fromRGB(248, 234, 146)
	title.Text = "Pirate Broker"
	title.Parent = panel

	local info = Instance.new("TextLabel")
	info.Name = "Info"
	info.BackgroundTransparency = 1
	info.Size = UDim2.new(1, -16, 0, 48)
	info.Position = UDim2.fromOffset(8, 44)
	info.Font = Enum.Font.Gotham
	info.TextWrapped = true
	info.TextXAlignment = Enum.TextXAlignment.Left
	info.TextYAlignment = Enum.TextYAlignment.Top
	info.TextSize = 14
	info.TextColor3 = Color3.fromRGB(223, 232, 244)
	info.Text = "Ask a question or hire a hit."
	info.Parent = panel
	pirateHireUiState.infoLabel = info

	local askButton = Instance.new("TextButton")
	askButton.Name = "AskButton"
	askButton.Size = UDim2.fromOffset(150, 34)
	askButton.Position = UDim2.fromOffset(8, 98)
	askButton.BackgroundColor3 = Color3.fromRGB(56, 70, 92)
	askButton.TextColor3 = Color3.fromRGB(245, 249, 255)
	askButton.Font = Enum.Font.Gotham
	askButton.TextSize = 14
	askButton.Text = "Ask a question"
	askButton.Parent = panel
	askButton.MouseButton1Click:Connect(function()
		requestPirateHireAction:FireServer({ action = "ask" })
	end)

	local refreshButton = Instance.new("TextButton")
	refreshButton.Name = "RefreshButton"
	refreshButton.Size = UDim2.fromOffset(110, 34)
	refreshButton.Position = UDim2.fromOffset(166, 98)
	refreshButton.BackgroundColor3 = Color3.fromRGB(56, 70, 92)
	refreshButton.TextColor3 = Color3.fromRGB(245, 249, 255)
	refreshButton.Font = Enum.Font.Gotham
	refreshButton.TextSize = 14
	refreshButton.Text = "Refresh list"
	refreshButton.Parent = panel
	refreshButton.MouseButton1Click:Connect(function()
		refreshPirateHireTargets()
	end)

	local targetList = Instance.new("ScrollingFrame")
	targetList.Name = "TargetList"
	targetList.Size = UDim2.new(1, -16, 1, -196)
	targetList.Position = UDim2.fromOffset(8, 140)
	targetList.BackgroundColor3 = Color3.fromRGB(28, 34, 46)
	targetList.BorderSizePixel = 0
	targetList.AutomaticCanvasSize = Enum.AutomaticSize.None
	targetList.ScrollBarThickness = 8
	targetList.Parent = panel
	pirateHireUiState.targetList = targetList

	local confirmButton = Instance.new("TextButton")
	confirmButton.Name = "ConfirmButton"
	confirmButton.Size = UDim2.fromOffset(150, 36)
	confirmButton.Position = UDim2.new(1, -314, 1, -44)
	confirmButton.BackgroundColor3 = Color3.fromRGB(158, 53, 53)
	confirmButton.TextColor3 = Color3.fromRGB(253, 242, 242)
	confirmButton.Font = Enum.Font.GothamBold
	confirmButton.TextSize = 14
	confirmButton.Text = "Hire a hit"
	confirmButton.Parent = panel
	pirateHireUiState.confirmButton = confirmButton
	confirmButton.MouseButton1Click:Connect(function()
		local victimUserId = pirateHireUiState.selectedVictimUserId
		if not victimUserId then
			updatePirateHireInfo("Select a target first.")
			return
		end
		requestPirateHireAction:FireServer({
			action = "hire",
			victimUserId = victimUserId,
		})
	end)

	local closeButton = Instance.new("TextButton")
	closeButton.Name = "CloseButton"
	closeButton.Size = UDim2.fromOffset(150, 36)
	closeButton.Position = UDim2.new(1, -158, 1, -44)
	closeButton.BackgroundColor3 = Color3.fromRGB(48, 56, 70)
	closeButton.TextColor3 = Color3.fromRGB(238, 244, 251)
	closeButton.Font = Enum.Font.Gotham
	closeButton.TextSize = 14
	closeButton.Text = "Close"
	closeButton.Parent = panel
	closeButton.MouseButton1Click:Connect(closePirateHireUi)

	refreshPirateHireTargets()
end

local function getEquippedToolName(): string?
	local character = player.Character
	if not character then
		return nil
	end
	for _, child in ipairs(character:GetChildren()) do
		if child:IsA("Tool") then
			return child.Name
		end
	end
	return nil
end

-- Returns (kind, tier) for the currently equipped tool based on its attributes.
-- kind ∈ {"Drill", "Pump", "Pipe", nil}
local function getEquippedToolInfo(): (string?, string?)
	local character = player.Character
	if not character then return nil, nil end
	for _, child in ipairs(character:GetChildren()) do
		if child:IsA("Tool") then
			local kind = child:GetAttribute("ToolKind")
			local tier = child:GetAttribute("Tier")
			return typeof(kind) == "string" and kind or nil, typeof(tier) == "string" and tier or nil
		end
	end
	return nil, nil
end

local function getOwnedPlotByAttribute(): Model?
	local plotId = player:GetAttribute("PlotId")
	if typeof(plotId) ~= "number" or plotId <= 0 then return nil end
	local map = Workspace:FindFirstChild("Map")
	if not map then return nil end
	local plots = map:FindFirstChild("Plots")
	if not plots then return nil end
	for _, item in ipairs(plots:GetChildren()) do
		if item:IsA("Model") then
			local id = item:GetAttribute("PlotId")
			if typeof(id) ~= "number" then
				id = tonumber(item.Name:match("(%d+)"))
			end
			if typeof(id) == "number" and id == plotId then
				return item
			end
		end
	end
	return nil
end

local function rebuildStateMaps()
	chunkStateById = {}
	drillStateById = {}
	pipeStateByCellKey = {}
	drumStateByCellKey = {}
	if not state then
		return
	end
	for _, chunk in ipairs(state.chunks or {}) do
		chunkStateById[chunk.chunkId] = chunk
	end
	for _, drill in ipairs(state.drills or {}) do
		drillStateById[drill.drillId] = drill
	end
	for _, pipe in ipairs(state.pipes or {}) do
		if pipe.cellKey then
			pipeStateByCellKey[pipe.cellKey] = pipe
		end
	end
	for _, drum in ipairs(state.drums or {}) do
		if drum.cellKey then
			drumStateByCellKey[drum.cellKey] = drum
		end
	end
end

local function disconnectPromptConnections()
	for _, c in ipairs(promptConnections) do
		c:Disconnect()
	end
	promptConnections = {}
end

local _wiredPromptSet: { [ProximityPrompt]: true } = {}

local function wireBuyPrompt(prompt: ProximityPrompt)
	if _wiredPromptSet[prompt] then return end
	_wiredPromptSet[prompt] = true
	local conn = prompt.Triggered:Connect(function(triggeringPlayer)
		print(string.format("[Client] BuyPrompt Triggered by %s on %s",
			triggeringPlayer and triggeringPlayer.Name or "?", prompt:GetFullName()))
		if triggeringPlayer ~= player then
			return
		end
		local cursor: Instance? = prompt
		while cursor and cursor.Parent do
			cursor = cursor.Parent
			if cursor and typeof(cursor:GetAttribute("ChunkId")) == "string" then
				local chunkId = cursor:GetAttribute("ChunkId")
				print(string.format("[Client] firing RequestBuyChunk chunkId=%s", chunkId))
				requestBuyChunk:FireServer({ chunkId = chunkId })
				return
			end
		end
		print("[Client] BuyPrompt: no ChunkId ancestor")
	end)
	table.insert(promptConnections, conn)
end

local function bindPromptsForOwnedPlot()
	disconnectPromptConnections()
	_wiredPromptSet = {}
	if not ownedPlot then return end
	local ground = ownedPlot:FindFirstChild("PlotGround")
	if not (ground and ground:IsA("Model")) then return end

	local wired = 0
	for _, descendant in ipairs(ground:GetDescendants()) do
		if descendant:IsA("ProximityPrompt") and descendant.Name == "BuyPrompt" then
			wireBuyPrompt(descendant)
			wired += 1
		end
	end
	print(string.format("[Client] bindPromptsForOwnedPlot: wired %d BuyPrompts on %s (initial)", wired, ownedPlot.Name))

	-- Streaming-resilient: catch BuyPrompts that replicate in later.
	local boundPlot = ownedPlot
	local streamConn = ground.DescendantAdded:Connect(function(d)
		if boundPlot ~= ownedPlot then return end
		if d:IsA("ProximityPrompt") and d.Name == "BuyPrompt" then
			wireBuyPrompt(d)
			print(string.format("[Client] BuyPrompt wired late via DescendantAdded: %s", d:GetFullName()))
		end
	end)
	table.insert(promptConnections, streamConn)
end

local function bindOwnedPlot()
	chunkPartById = {}
	local prevOwned = ownedPlot
	ownedPlot = getOwnedPlotByAttribute()
	_clientGridCache = nil
	if not ownedPlot then
		warn(string.format("[Client] bindOwnedPlot: ownedPlot=nil (PlotId attr=%s, prev=%s, plots-folder-exists=%s, plots-count=%s)",
			tostring(player:GetAttribute("PlotId")),
			prevOwned and prevOwned.Name or "nil",
			tostring(Workspace.Map and Workspace.Map:FindFirstChild("Plots") ~= nil),
			(Workspace.Map and Workspace.Map:FindFirstChild("Plots")) and tostring(#Workspace.Map.Plots:GetChildren()) or "?"))
		return
	end

	local ground = ownedPlot:FindFirstChild("PlotGround")
	if not (ground and ground:IsA("Model")) then
		warn(string.format("[Client] bindOwnedPlot: %s has no PlotGround", ownedPlot.Name))
		return
	end

	local count = 0
	for _, item in ipairs(ground:GetChildren()) do
		if item:IsA("Model") then
			local chunkId = item:GetAttribute("ChunkId")
			if typeof(chunkId) == "string" then
				chunkPartById[chunkId] = item
				count += 1
			end
		end
	end

	print(string.format("[Client] bindOwnedPlot: %s bound, %d chunks found", ownedPlot.Name, count))

	bindPromptsForOwnedPlot()
end

local function getTargetedChunkHit(): (Instance?, Vector3?, string?)
	local target = mouse.Target
	if not (target and target:IsA("BasePart")) then
		return nil, nil, nil
	end
	if not ownedPlot then
		return nil, nil, nil
	end
	-- Walk up parents looking for any instance carrying a ChunkId attribute (Model or BasePart)
	local cursor: Instance? = target
	while cursor do
		if typeof(cursor:GetAttribute("ChunkId")) == "string" then
			return cursor, mouse.Hit.Position, cursor:GetAttribute("ChunkId")
		end
		cursor = cursor.Parent
		if cursor == nil or cursor == ownedPlot.Parent then
			break
		end
	end
	return nil, nil, nil
end

-- Sweep any orphan DrillPreview parts left over from previous bugged builds.
for _, d in ipairs(Workspace:GetChildren()) do
	if d:IsA("BasePart") and d.Name == "DrillPreview" then
		d:Destroy()
	end
end

local function isChunkUnlocked(chunkId: string): boolean
	local c = chunkStateById[chunkId]
	return c ~= nil and c.unlocked == true
end

-- Returns the top Y of a chunk's surface (the highest sub-tile). Uses descendants so nested
-- authored tiles still resolve; avoids falling back to `hitPos.Y` (StartBeach / void) when grazing.
local function getChunkSurfaceY(chunkId: string): number?
	local sectionModel = chunkPartById[chunkId]
	if not sectionModel then
		return nil
	end
	local topY: number? = nil
	for _, d in ipairs(sectionModel:GetDescendants()) do
		if d:IsA("BasePart") and d.Name:match("^T%d%d$") then
			local surface = d.Position.Y + d.Size.Y / 2
			if topY == nil or surface > topY then
				topY = surface
			end
		end
	end
	return topY
end

-- When the mouse hits a tile part directly, use that surface (matches server tile snap).
local function surfaceYFromRayTarget(): number?
	local t = mouse.Target
	if t and t:IsA("BasePart") and t.Name:match("^T%d%d$") then
		return t.Position.Y + t.Size.Y / 2
	end
	return nil
end

local function pumpGhostVisualGroundLiftStuds(tier: string?): number
	if typeof(tier) ~= "string" then
		return 0
	end
	local pt = (OilConfig.PumpTiers :: { [string]: any })[tier]
	if pt and typeof(pt.visualGroundOffsetStuds) == "number" then
		return pt.visualGroundOffsetStuds :: number
	end
	return 0
end

local function distanceXZ(a: Vector3, b: Vector3): number
	local dx = a.X - b.X
	local dz = a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

local function isPlacementValid(chunkId: string, hitPos: Vector3, equipKind: string?): boolean
	if not isChunkUnlocked(chunkId) then
		return false
	end
	local kind = equipKind
	if kind == nil then
		kind = select(1, getEquippedToolInfo())
		if kind == nil and getEquippedToolName() == TOOL_DRILL then
			kind = "Drill"
		end
	end
	if kind == "Drill" then
		local want = readLocalFtueCellKey(Constants.FtueRestrictDrillCellKeyAttribute)
		if want then
			local row, col = clientWorldToCell(hitPos.X, hitPos.Z)
			if not clientCellInBounds(row, col) or cellKeyOf(row, col) ~= want then
				return false
			end
		end
	elseif kind == "Pump" then
		local want = readLocalFtueCellKey(Constants.FtueRestrictPumpCellKeyAttribute)
		if want then
			local row, col = clientWorldToCell(hitPos.X, hitPos.Z)
			if not clientCellInBounds(row, col) or cellKeyOf(row, col) ~= want then
				return false
			end
		end
	end
	for _, drill in pairs(drillStateById) do
		local pos = Vector3.new(drill.position.x, drill.position.y, drill.position.z)
		if distanceXZ(pos, hitPos) < (config.drillMinSpacing or 6) then
			return false
		end
	end
	return true
end

-- Drill placement ghost: a translucent clone of the actual Drill template,
-- color-tinted via Highlight (green = valid, red = invalid).
local ghostDrill: Model? = nil
local ghostHighlight: Highlight? = nil

-- Maps equipped tool (kind + tier) → RS.Assets template name to preview
local function resolveGhostTemplateName(): string?
	local kind, tier = getEquippedToolInfo()
	if kind == "Drill" and tier then return "Drill_" .. tier end
	if kind == "Pump" and tier then return "Pump_" .. tier end
	if kind == "Prospector" then return "Prospector" end
	-- Legacy fallback
	if getEquippedToolName() == TOOL_DRILL then return "Drill_T1" end
	return nil
end

local ghostTemplateName: string? = nil

local function ensureGhost(): Model?
	local wantName = resolveGhostTemplateName()
	if not wantName then return nil end

	-- If the equipped tool changed, rebuild the ghost with the new template
	if ghostDrill and ghostDrill.Parent and ghostTemplateName == wantName then
		return ghostDrill
	end
	if ghostDrill then ghostDrill:Destroy(); ghostDrill = nil; ghostHighlight = nil end

	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local template = assets and assets:FindFirstChild(wantName)
	if not template then return nil end

	local clone = template:Clone()
	clone.Name = "PlacementGhost"
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("Script") or d:IsA("LocalScript") then d:Destroy() end
		if d:IsA("BasePart") then
			d.Anchored = true; d.CanCollide = false; d.CanQuery = false; d.CanTouch = false
		end
	end
	local hl = Instance.new("Highlight")
	hl.Name = "GhostHighlight"
	hl.FillColor = Color3.fromRGB(80, 220, 120)
	hl.OutlineColor = Color3.fromRGB(255, 255, 255)
	hl.FillTransparency = 0.55
	hl.OutlineTransparency = 0
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	hl.Parent = clone
	clone.Parent = Workspace
	ghostDrill = clone
	ghostHighlight = hl
	ghostTemplateName = wantName
	return clone
end

local function hideGhost()
	if ghostDrill then
		ghostDrill:Destroy()
		ghostDrill = nil
		ghostHighlight = nil
	end
end

local function updateGhost()
	local kind = select(1, getEquippedToolInfo())
	local equipped = getEquippedToolName()
	if kind ~= "Drill" and kind ~= "Pump" and kind ~= "Prospector" and equipped ~= TOOL_DRILL then
		hideGhost()
		return
	end
	local _, hitPos, chunkId = getTargetedChunkHit()
	if not (hitPos and chunkId) then
		hideGhost()
		return
	end
	local equipKind = select(1, getEquippedToolInfo())
	local equipTier = select(2, getEquippedToolInfo())
	if equipKind == nil and equipped == TOOL_DRILL then
		equipKind = "Drill"
	end

	local g = ensureGhost()
	if not g then
		return
	end
	local surfaceY = surfaceYFromRayTarget() or getChunkSurfaceY(chunkId) or hitPos.Y
	-- Pivot → ground: optional `Bottom` / `bottom` anchor part, else full-model bbox (PlacementAnchor).
	local pivotToBottom = 0
	if g:IsA("Model") then
		pivotToBottom = PlacementAnchor.pivotYMinusBottomWorldY(g)
	end
	local catalogLift = (equipKind == "Pump") and pumpGhostVisualGroundLiftStuds(equipTier) or 0
	g:PivotTo(CFrame.new(hitPos.X, surfaceY + pivotToBottom + catalogLift, hitPos.Z))
	if ghostHighlight then
		if isPlacementValid(chunkId, hitPos, equipKind) then
			ghostHighlight.FillColor = Color3.fromRGB(80, 220, 120)
			ghostHighlight.OutlineColor = Color3.fromRGB(190, 255, 200)
		else
			ghostHighlight.FillColor = Color3.fromRGB(220, 70, 70)
			ghostHighlight.OutlineColor = Color3.fromRGB(255, 180, 180)
		end
	end
end

-- =================== CELL-GRID PIPE PLACEMENT ===================

local function getPipeHit(): (Vector3?, string?)
	local _chunkInst, hitPos, chunkId = getTargetedChunkHit()
	if not hitPos or not chunkId then
		pipeDebugLog("no valid chunk hit")
		return nil, nil
	end
	if not isChunkUnlocked(chunkId) then
		pipeDebugLog("chunk locked: " .. tostring(chunkId))
		return nil, nil
	end
	return hitPos, chunkId
end

local function ensurePipeGhost(): Model
	if pipeGhost and pipeGhost.Parent then
		return pipeGhost
	end
	local m = Instance.new("Model")
	m.Name = "PipePreview"
	local p = Instance.new("Part")
	p.Name = "Body"
	p.Shape = Enum.PartType.Ball
	p.Size = Vector3.new(6, 1.5, 6)
	p.Material = Enum.Material.Neon
	p.Color = Color3.fromRGB(80, 220, 120)
	p.Transparency = 0.45
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Parent = m
	m.PrimaryPart = p
	m.Parent = Workspace
	pipeGhost = m
	return m
end

local function hidePipeGhost()
	if pipeGhost then
		pipeGhost:Destroy()
		pipeGhost = nil
	end
end

local function pipeHitValid(chunkId: string?): (boolean, string?)
	if not chunkId or chunkId == "" then
		return false, "No chunk"
	end
	local section = chunkStateById[chunkId]
	if not section or section.unlocked ~= true then
		return false, "Locked section"
	end
	return true, nil
end

local function updatePipeGhost()
	local equipped = getEquippedToolName()
	if equipped ~= TOOL_PIPE then
		hidePipeGhost()
		return
	end
	local worldPos, chunkId = getPipeHit()
	if not worldPos then
		pipeDebugLog("ghost hidden: no valid pipe cell")
		hidePipeGhost()
		return
	end
	local valid = pipeHitValid(chunkId)
	local g = ensurePipeGhost()
	local body = g:FindFirstChild("Body")
	if body and body:IsA("BasePart") then
		local y = (chunkId and (surfaceYFromRayTarget() or getChunkSurfaceY(chunkId) or worldPos.Y)) or worldPos.Y
		body.Position = Vector3.new(worldPos.X, y + 0.75, worldPos.Z)
		body.Color = valid and Color3.fromRGB(80, 220, 120) or Color3.fromRGB(220, 70, 70)
	end
end

local function tryPipeAction()
	if getEquippedToolName() ~= TOOL_PIPE then
		return
	end
	local worldPos, chunkId = getPipeHit()
	if not worldPos then
		pipeDebugLog("place failed: no valid owned tile under cursor")
		setStatus("Click on an owned chunk.", false)
		return
	end
	local valid, reason = pipeHitValid(chunkId)
	if not valid then
		pipeDebugLog(string.format("place blocked chunk=%s reason=%s", tostring(chunkId), tostring(reason)))
		setStatus(reason or "Cannot place pipe here.", false)
		return
	end
	requestPlacePipe:FireServer({ x = worldPos.X, z = worldPos.Z, chunkId = chunkId })
	pipeDebugLog(string.format("place request chunk=%s x=%.2f z=%.2f", tostring(chunkId), worldPos.X, worldPos.Z))
end

local function ensureFocusBillboard()
	if focusBillboard and focusLabel and focusBillboard.Parent then
		return
	end
	focusBillboard = Instance.new("BillboardGui")
	focusBillboard.Name = "ChunkFocus"
	focusBillboard.Size = UDim2.fromOffset(170, 32)
	focusBillboard.StudsOffset = Vector3.new(0, 4, 0)
	focusBillboard.AlwaysOnTop = true
	focusBillboard.Enabled = false
	focusBillboard.Parent = playerGui

	focusLabel = Instance.new("TextLabel")
	focusLabel.Size = UDim2.fromScale(1, 1)
	focusLabel.BackgroundTransparency = 0.2
	focusLabel.BackgroundColor3 = Color3.fromRGB(21, 27, 38)
	focusLabel.TextColor3 = Color3.fromRGB(239, 239, 239)
	focusLabel.Font = Enum.Font.GothamBold
	focusLabel.TextSize = 12
	focusLabel.Parent = focusBillboard
end

local function updateFocusUi()
	ensureFocusBillboard()
	if not (focusBillboard and focusLabel) then
		return
	end
	local hit, _, chunkId = getTargetedChunkHit()
	if not (hit and chunkId) then
		focusBillboard.Enabled = false
		return
	end
	local chunk = chunkStateById[chunkId]
	if not chunk then
		focusBillboard.Enabled = false
		return
	end
	-- Use the section's LockOverlay (always present) as adornee since Models need a PrimaryPart
	local adornee: BasePart? = nil
	if hit:IsA("BasePart") then
		adornee = hit
	else
		local overlay = hit:FindFirstChild("LockOverlay")
		if overlay and overlay:IsA("BasePart") then
			adornee = overlay
		end
	end
	if not adornee then
		focusBillboard.Enabled = false
		return
	end
	focusBillboard.Adornee = adornee
	if chunk.unlocked and chunk.revealed then
		-- Show biome + tile name. Oil status line only appears once the chunk has been prospected.
		focusLabel.RichText = true
		local tileInfoText = ""
		if chunk.tiles and mouse.Target and mouse.Target:IsA("BasePart") then
			local targetName = mouse.Target.Name
			local tileData = chunk.tiles[targetName]
			if tileData then
				local tileName = tileData.tileName or "?"
				tileInfoText = string.format(" | %s", tileName)
				if chunk.prospected then
					if tileData.hasOil == false then
						tileInfoText = tileInfoText .. " <font color='rgb(240,70,70)'>— NO OIL</font>"
					else
						tileInfoText = tileInfoText .. " <font color='rgb(80,230,120)'>— HAS OIL</font>"
					end
				end
			end
		end
		focusLabel.Text = string.format("%s%s", chunk.biome or "?", tileInfoText)
		focusLabel.TextColor3 = Color3.fromRGB(160, 230, 170)
	elseif not chunk.unlocked then
		local label = string.format("??? — $%d", chunk.cost or 0)
		if chunk.canBuy == false then
			label = label .. " (no neighbour)"
		end
		focusLabel.Text = label
		focusLabel.TextColor3 = Color3.fromRGB(252, 220, 120)
	end
	focusBillboard.Enabled = true
end

local function formatCashWithCommas(amount: number): string
	local n = math.floor(math.max(0, amount))
	local s = tostring(n)
	local segments = {}
	local i = #s
	while i > 0 do
		local startIdx = math.max(1, i - 2)
		table.insert(segments, 1, string.sub(s, startIdx, i))
		i = startIdx - 1
	end
	return table.concat(segments, ",")
end

local function resolveCashTextLabel(pg: PlayerGui): TextLabel?
	local hud = pg:FindFirstChild("HUD")
	local canvas = hud and hud:FindFirstChild("Canvas")
	local left = canvas and canvas:FindFirstChild("LeftStack")
	local strip = left and left:FindFirstChild("CashStrip")
	local lbl = strip and strip:FindFirstChild("CashText")
	if lbl and lbl:IsA("TextLabel") then
		return lbl
	end
	return nil
end

local function updateCashHud()
	local cash = 0
	if typeof(state) == "table" then
		local st = state :: { [string]: any }
		if typeof(st.cash) == "number" then
			cash = math.floor(math.max(0, st.cash))
		end
	end
	if not (cashTextLabel and cashTextLabel.Parent) then
		cashTextLabel = resolveCashTextLabel(playerGui)
	end
	if not cashTextLabel then
		return
	end
	cashTextLabel.Text = "$" .. formatCashWithCommas(cash)
end

local function updateUi()
	-- Oil HUD is StarterGui `HUD` (cloned to PlayerGui). Rebind labels/buttons here when ready.
	updateCashHud()
end

local function getHudUiFolder(): Instance?
	-- Play: LocalScripts usually live under `PlayerScripts.Client`; Rojo `src/client/UI` mirrors there.
	local psInst = player:FindFirstChild("PlayerScripts")
	if not (psInst and psInst:IsA("PlayerScripts")) then
		psInst = player:WaitForChild("PlayerScripts", 30)
	end
	if not (psInst and psInst:IsA("PlayerScripts")) then
		return nil
	end
	local ps = psInst :: PlayerScripts
	local clientFolder = ps:FindFirstChild("Client")
	if clientFolder then
		local ui = clientFolder:FindFirstChild("UI")
		if ui then
			return ui
		end
	end
	local uiRoot = ps:FindFirstChild("UI")
	if uiRoot then
		return uiRoot
	end
	local sp = script.Parent
	if sp then
		local ui = sp:FindFirstChild("UI")
		if ui then
			return ui
		end
	end
	return nil
end

local function tryBindEquipmentHotbarAsync()
	task.spawn(function()
		local uiFolder = getHudUiFolder()
		if not uiFolder then
			return
		end
		local hbMod = uiFolder:WaitForChild("EquipmentHotbarController", 30)
		if not (hbMod and hbMod:IsA("ModuleScript")) then
			warn("[Client] EquipmentHotbar: `EquipmentHotbarController` ModuleScript missing under Client/UI (sync Rojo).")
			return
		end
		local EquipmentHotbarController = require(hbMod) :: { tryStart: (PlayerGui) -> boolean }
		local ok = EquipmentHotbarController.tryStart(playerGui)
		if ok then
			local okHide, errHide = pcall(function()
				StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
			end)
			if not okHide then
				warn("[Client] EquipmentHotbar: SetCoreGuiEnabled(Backpack) failed: ", errHide)
			end
		end
	end)
end

local function startHudModalWiring()
	local ok, err = pcall(function()
		local uiFolder = getHudUiFolder()
		if not uiFolder then
			for _ = 1, 120 do
				uiFolder = getHudUiFolder()
				if uiFolder then
					break
				end
				task.wait(0.25)
			end
		end
		if not uiFolder then
			warn(
				"[Client] HUD wiring: could not find `UI` under PlayerScripts.Client (or script.Parent). Sync Rojo `src/client/UI`."
			)
			return
		end
		local routerMod = uiFolder:WaitForChild("HudPanelRouter", 30)
		if not (routerMod and routerMod:IsA("ModuleScript")) then
			warn("[Client] HUD wiring: HudPanelRouter ModuleScript missing under UI folder.")
			return
		end
		local HudPanelRouter = require(routerMod) :: { start: (PlayerGui) -> () }
		HudPanelRouter.start(playerGui)

		local tpMod = uiFolder:WaitForChild("HudTeleportRouter", 30)
		if tpMod and tpMod:IsA("ModuleScript") then
			local HudTeleportRouter = require(tpMod) :: { start: (PlayerGui) -> () }
			HudTeleportRouter.start(playerGui)
		else
			warn("[Client] HUD wiring: HudTeleportRouter ModuleScript missing under UI folder.")
		end

		tryBindEquipmentHotbarAsync()
	end)
	if not ok then
		warn("[Client] HUD wiring bootstrap failed: ", err)
	end
end

-- Deferred below after `updateMarketUi` exists: `InvokeServer()` yields mid-script, so an early
-- `task.defer(startHudModalWiring)` could run this bootstrap before `updateMarketUi` is defined (nil call).

local function getTargetedDrillId(): number?
	local target = mouse.Target
	if not target then
		return nil
	end
	local cursor: Instance? = target
	while cursor do
		if cursor.Name and string.sub(cursor.Name, 1, 6) == "Drill_" then
			local id = tonumber(string.sub(cursor.Name, 7))
			if id then
				return id
			end
		end
		cursor = cursor.Parent
	end
	return nil
end

local function distanceFromCharacter(pos: Vector3): number
	local character = player.Character
	if not character then
		return math.huge
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not (hrp and hrp:IsA("BasePart")) then
		return math.huge
	end
	return (hrp.Position - pos).Magnitude
end

-- Hammer target detection: walks up from whatever the mouse is on to find something placed
local function resolveHammerTarget()
	local t = mouse.Target
	while t and t.Parent do
		local n = t.Name
		if n:match("^Drill_%d+$") then
			local id = tonumber(n:match("^Drill_(%d+)$"))
			return { targetKind = "pump", targetId = id }
		elseif n:match("^Pipe_") then
			local cellKey = n:match("^Pipe_(.+)$")
			return { targetKind = "pipe", cellKey = cellKey }
		elseif n:match("^Drum_%d+$") then
			local id = tonumber(n:match("^Drum_(%d+)$"))
			return { targetKind = "drum", targetId = id }
		elseif n:match("^ActiveDrill_%d+$") then
			local id = tonumber(n:match("^ActiveDrill_(%d+)$"))
			return { targetKind = "drill", targetId = id }
		elseif n:match("^ActiveProspector_%d+$") then
			local id = tonumber(n:match("^ActiveProspector_(%d+)$"))
			return { targetKind = "prospector", targetId = id }
		end
		t = t.Parent
	end
	return nil
end

-- Client-side placement cost lookup for refund preview (mirrors OilConfig tier costs)
local function estimateRefundForTarget(target): (number, Instance?)
	if not target then return 0, nil end
	if target.targetKind == "pump" then
		local drill = drillStateById[target.targetId]
		if drill then
			-- Walk the DrillTiers to get the pump tier cost. Use OilConfig from shared.
			local okCfg, OilConfig = pcall(function()
				return require(Shared:WaitForChild("Config"):WaitForChild("OilConfig"))
			end)
			if okCfg and OilConfig.PumpTiers and drill.tier and OilConfig.PumpTiers[drill.tier] then
				local scale = drill.scale or 1
				local cost = OilConfig.PumpTiers[drill.tier].cost or 0
				return math.floor(cost * 0.10 * 1), nil -- scale doesn't affect cost
			end
		end
		return 0, nil
	elseif target.targetKind == "pipe" then
		local okCfg, OilConfig = pcall(function()
			return require(Shared:WaitForChild("Config"):WaitForChild("OilConfig"))
		end)
		local cost = (okCfg and OilConfig.Pipes and OilConfig.Pipes.Cost) or 50
		return math.floor(cost * 0.10), nil
	elseif target.targetKind == "drum" then
		local okCfg, OilConfig = pcall(function()
			return require(Shared:WaitForChild("Config"):WaitForChild("OilConfig"))
		end)
		local cost = (okCfg and OilConfig.Drums and OilConfig.Drums.Cost) or 0
		return math.floor(cost * 0.10), nil
	elseif target.targetKind == "drill" then
		local okCfg, OilConfig = pcall(function()
			return require(Shared:WaitForChild("Config"):WaitForChild("OilConfig"))
		end)
		if okCfg and OilConfig.DrillTiers then
			for _, tier in pairs(OilConfig.DrillTiers) do
				return math.floor((tier.cost or 0) * 0.10), nil
			end
		end
		return 0, nil
	end
	return 0, nil
end

-- Floating hover billboard showing the refund preview
local hammerHoverBB: BillboardGui? = nil
local hammerHoverLbl: TextLabel? = nil
local function ensureHammerHover()
	if hammerHoverBB and hammerHoverBB.Parent then
		return hammerHoverBB, hammerHoverLbl
	end
	local bb = Instance.new("BillboardGui")
	bb.Name = "HammerHoverBB"
	bb.Size = UDim2.new(0, 180, 0, 44)
	bb.StudsOffsetWorldSpace = Vector3.new(0, 4, 0)
	bb.AlwaysOnTop = true
	bb.Parent = playerGui
	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
	lbl.BackgroundTransparency = 0.15
	lbl.TextColor3 = Color3.fromRGB(255, 210, 80)
	lbl.TextStrokeTransparency = 0
	lbl.Font = Enum.Font.GothamBold
	lbl.TextScaled = true
	lbl.Text = ""
	lbl.Parent = bb
	hammerHoverBB = bb
	hammerHoverLbl = lbl
	return bb, lbl
end

local function hideHammerHover()
	if hammerHoverBB then
		hammerHoverBB.Enabled = false
		hammerHoverBB.Adornee = nil
	end
end

-- Called from RenderStepped when hammer is equipped — updates the billboard
local function updateHammerHover()
	local kind = select(1, getEquippedToolInfo())
	if kind ~= "Hammer" then
		hideHammerHover()
		return
	end
	local target = resolveHammerTarget()
	if not target then
		hideHammerHover()
		return
	end
	-- Find a BasePart on the target to adorn
	local adorn: BasePart? = nil
	local ancestor = mouse.Target
	while ancestor and ancestor.Parent do
		if ancestor:IsA("BasePart") then adorn = ancestor; break end
		ancestor = ancestor.Parent
	end
	if not adorn then hideHammerHover(); return end
	local refund = estimateRefundForTarget(target)
	local bb, lbl = ensureHammerHover()
	bb.Adornee = adorn
	bb.Enabled = true
	if lbl then lbl.Text = string.format("Click to refund $%d", refund) end
end

local function tryPrimaryAction()
	local kind, tier = getEquippedToolInfo()
	if kind == nil and getEquippedToolName() == TOOL_DRILL then
		kind, tier = "Drill", "T1"
	end

	-- Hammer: destroy whatever we're hovering over, refund 10%
	if kind == "Hammer" then
		local target = resolveHammerTarget()
		if target then
			requestHammerDestroy:FireServer(target)
		else
			setStatus("Nothing to hammer here.", false)
		end
		return
	end

	if kind ~= "Drill" and kind ~= "Pump" and kind ~= "Prospector" then return end

	local _, hitPos, chunkId = getTargetedChunkHit()
	if not (hitPos and chunkId) then return end
	if not isChunkUnlocked(chunkId) then
		setStatus("That chunk is locked.", false)
		return
	end
	local surfaceY = surfaceYFromRayTarget() or getChunkSurfaceY(chunkId) or hitPos.Y
	local payload = {
		chunkId = chunkId,
		x = hitPos.X,
		y = surfaceY,
		z = hitPos.Z,
		tier = tier or "T1",
	}
	if kind == "Drill" then
		local wantDrill = readLocalFtueCellKey(Constants.FtueRestrictDrillCellKeyAttribute)
		if wantDrill then
			local row, col = clientWorldToCell(hitPos.X, hitPos.Z)
			if not clientCellInBounds(row, col) or cellKeyOf(row, col) ~= wantDrill then
				setStatus("Place the drill on the marked tile.", false)
				return
			end
		end
		requestStartDrill:FireServer(payload)
	elseif kind == "Pump" then
		local wantPump = readLocalFtueCellKey(Constants.FtueRestrictPumpCellKeyAttribute)
		if wantPump then
			local row, col = clientWorldToCell(hitPos.X, hitPos.Z)
			if not clientCellInBounds(row, col) or cellKeyOf(row, col) ~= wantPump then
				setStatus("Place the collector on the marked tile.", false)
				return
			end
		end
		requestPlacePump:FireServer(payload)
	elseif kind == "Prospector" then
		requestProspect:FireServer(payload)
	end
end

local function clearRemoveHold()
	removeHoldStart = 0
	removeHoldDrillId = nil
end

-- If the server hasn't set PlotId yet, wait for the attribute to replicate once.
-- After this, the GetAttributeChangedSignal listener below keeps us in sync.
if not player:GetAttribute("PlotId") then
	player:GetAttributeChangedSignal("PlotId"):Wait()
end
bindOwnedPlot()

local function applySnapshot(snapshot: any): boolean
	if typeof(snapshot) ~= "table" then
		return false
	end
	if typeof(snapshot.state) == "table" then
		state = snapshot.state
	end
	if typeof(snapshot.config) == "table" then
		for k, v in pairs(snapshot.config) do
			config[k] = v
		end
	end
	rebuildStateMaps()
	updateUi()
	return typeof(state) == "table" and next(chunkStateById) ~= nil
end

local function requestSnapshotWithRetry(attempts: number, delaySeconds: number)
	for attempt = 1, attempts do
		local ok, snapshot = pcall(function()
			return requestOilSnapshot:InvokeServer()
		end)
		if ok and applySnapshot(snapshot) then
			if attempt > 1 then
				print(string.format("[Client] snapshot recovered on retry %d", attempt))
			end
			return
		end
		task.wait(delaySeconds)
	end
	warn("[Client] snapshot retries exhausted (state missing or empty chunks).")
end

local initialOk, initialSnapshot = pcall(function()
	return requestOilSnapshot:InvokeServer()
end)
local hasInitialState = initialOk and applySnapshot(initialSnapshot)
if not hasInitialState then
	task.spawn(function()
		requestSnapshotWithRetry(10, 0.25)
	end)
end

player:GetAttributeChangedSignal("PlotId"):Connect(function()
	bindOwnedPlot()
	updateUi()
	task.spawn(function()
		requestSnapshotWithRetry(6, 0.2)
	end)
end)

playerGui.ChildAdded:Connect(function(child)
	if child.Name == "HUD" then
		cashTextLabel = nil
		updateCashHud()
		if child:IsA("ScreenGui") then
			tryBindEquipmentHotbarAsync()
		end
	end
end)

mouse.Button1Down:Connect(function()
	local equipped = getEquippedToolName()
	if equipped == TOOL_PIPE then
		tryPipeAction()
	else
		tryPrimaryAction()
	end
end)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end

	if input.KeyCode ~= Enum.KeyCode.E then
		return
	end
	if getEquippedToolName() ~= nil then
		return
	end

	-- Try drill removal first
	local drillId = getTargetedDrillId()
	if drillId then
		local drill = drillStateById[drillId]
		if not drill then return end
		local pos = Vector3.new(drill.position.x, drill.position.y, drill.position.z)
		if distanceFromCharacter(pos) > (config.removeDrillRangeStuds or 18) then
			setStatus("Move closer to remove.", false)
			return
		end
		removeHoldStart = time()
		removeHoldDrillId = drillId
		setStatus("Holding E to remove drill...", nil)
		return
	end

	-- Otherwise try pipe removal by targeted chunk tile
	local pos, chunkId = getPipeHit()
	if pos then
		requestRemovePipe:FireServer({
			x = pos.X,
			z = pos.Z,
			chunkId = chunkId,
		})
		setStatus("Removed pipe.", true)
		pipeDebugLog(string.format("remove request chunk=%s x=%.2f z=%.2f", tostring(chunkId), pos.X, pos.Z))
		return
	end
	pipeDebugLog("remove: no valid owned chunk hit")
end)

UserInputService.InputEnded:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.E then
		clearRemoveHold()
	end
end)

oilStateUpdate.OnClientEvent:Connect(function(newState)
	state = newState
	rebuildStateMaps()
	updateUi()
end)

oilActionResult.OnClientEvent:Connect(function(payload)
	if typeof(payload) ~= "table" then
		return
	end
	local okOpt: boolean? = nil
	if payload.ok == true then
		okOpt = true
	elseif payload.ok == false then
		okOpt = false
	end
	setStatus(tostring(payload.message or "?"), okOpt)
end)

local warehouseState: any = nil

local MARKET_TYPE_MULS = { HeavyCrude = 0.8, LightSweet = 1.4, PremiumRefined = 2.0 }
local marketState = {
	basePrice = 10,
	prices = {} :: { [string]: number },
	trend = "stable",
	straitState = "Open",
	nextChangeAt = 0,
	globalBaseMin = 8,
	globalBaseMax = 80,
	typeMultipliers = MARKET_TYPE_MULS,
}

local straitStatusHudModule: { refresh: (PlayerGui, string) -> () }? = nil
local function getStraitStatusHud(): { refresh: (PlayerGui, string) -> () }?
	if straitStatusHudModule then
		return straitStatusHudModule
	end
	-- Match `getHudUiFolder` / StraitDevPanel: LocalScript may sit under `PlayerScripts` while `UI` lives under `Client`.
	local ui = getHudUiFolder()
	if not ui then
		return nil
	end
	local m = ui:FindFirstChild("StraitStatusHud")
	if m and m:IsA("ModuleScript") then
		straitStatusHudModule = require(m) :: { refresh: (PlayerGui, string) -> () }
	end
	return straitStatusHudModule
end

local straitStatusChangeFxModule: { trigger: (PlayerGui, string) -> () }? = nil
local function getStraitStatusChangeFx(): { trigger: (PlayerGui, string) -> () }?
	if straitStatusChangeFxModule then
		return straitStatusChangeFxModule
	end
	local ui = getHudUiFolder()
	if not ui then
		return nil
	end
	local m = ui:FindFirstChild("StraitStatusChangeFx")
	if m and m:IsA("ModuleScript") then
		straitStatusChangeFxModule = require(m) :: { trigger: (PlayerGui, string) -> () }
	end
	return straitStatusChangeFxModule
end

local oilPriceHudModule: { refresh: (PlayerGui, any) -> () }? = nil
local function getOilPriceHud(): { refresh: (PlayerGui, any) -> () }?
	if oilPriceHudModule then
		return oilPriceHudModule
	end
	local ui = getHudUiFolder()
	if not ui then
		return nil
	end
	local m = ui:FindFirstChild("OilPriceHud")
	if m and m:IsA("ModuleScript") then
		oilPriceHudModule = require(m) :: { refresh: (PlayerGui, any) -> () }
	end
	return oilPriceHudModule
end

local function updateMarketUi()
	local h = getStraitStatusHud()
	if h then
		h.refresh(playerGui, tostring(marketState.straitState or "Open"))
	end
	local op = getOilPriceHud()
	if op then
		op.refresh(playerGui, marketState)
	end
	_ = warehouseState
end

-- Run after market HUD helpers exist; `requestOilSnapshot:InvokeServer()` above can yield before here.
task.defer(startHudModalWiring)
-- Strait pill refresh must NOT live inside `startHudModalWiring` (closure created when that fn runs);
-- register this defer here so the closure is built after `updateMarketUi` exists.
task.defer(function()
	task.wait(0.5)
	updateMarketUi()
end)

-- Strait Robux CTA: hover scale pop (`UIScale` only — see `StraitControlCtaHover.luau`).
task.defer(function()
	local ui = getHudUiFolder()
	if not ui then
		return
	end
	local m = ui:FindFirstChild("StraitControlCtaHover")
	if not (m and m:IsA("ModuleScript")) then
		return
	end
	local ok, mod = pcall(require, m)
	if not ok or typeof(mod) ~= "table" or typeof((mod :: any).bind) ~= "function" then
		return
	end
	local bind = (mod :: any).bind :: (PlayerGui) -> boolean
	for _ = 1, 100 do
		if bind(playerGui) then
			return
		end
		task.wait(0.25)
	end
end)

local function updateWarehouseUi()
	-- Rebind to StarterGui `HUD` warehouse labels/buttons when wired.
	_ = warehouseState
end

warehouseStateUpdate.OnClientEvent:Connect(function(data)
	warehouseState = data
	updateWarehouseUi()
	updateMarketUi()
end)

-- `WarehouseStateUpdate` may fire before this script connects; re-fetch authoritative counts once.
task.defer(function()
	local ok, data = pcall(function()
		return requestWarehouseSnapshot:InvokeServer()
	end)
	if ok and typeof(data) == "table" and typeof(data.barrels) == "table" then
		warehouseState = data
		updateWarehouseUi()
		updateMarketUi()
	end
end)

globalStateUpdate.OnClientEvent:Connect(function(snapshot)
	if typeof(snapshot) ~= "table" then
		return
	end
	if typeof(snapshot.state) == "string" then
		local prev = marketState.straitState
		marketState.straitState = snapshot.state
		updateMarketUi()
		if prev and prev ~= snapshot.state then
			local fx = getStraitStatusChangeFx()
			if fx then
				fx.trigger(playerGui, snapshot.state)
			end
		end
	end
end)

pirateHireOpenEvent.OnClientEvent:Connect(function(payload)
	openPirateHireUi(payload)
end)

pirateHireResultEvent.OnClientEvent:Connect(function(payload)
	if typeof(payload) ~= "table" then
		return
	end
	local ok = payload.ok == true
	local message = tostring(payload.message or "")
	if message ~= "" then
		setStatus(message, ok)
		updatePirateHireInfo(message)
	end
	local data = payload.data
	if typeof(data) == "table" then
		local tokens = tonumber((data :: any).freeHitTokens)
		if tokens then
			pirateHireUiState.freeHitTokens = math.max(0, math.floor(tokens))
		end
	end
end)

pirateHitAlertEvent.OnClientEvent:Connect(function(payload)
	if typeof(payload) ~= "table" then
		return
	end
	local message = tostring(payload.message or "Pirate hit event.")
	setStatus(message, false)
	StraitEventPlaytestBanner.show(playerGui, "Pirate Hit")
end)

local STRAIT_PLAYTEST_BANNER_KINDS: { [string]: boolean } = {
	StraitWaypointEvent = true,
	PirateRaidEvent = true,
	CoastGuardInspectionEvent = true,
	USShipSlapEvent = true,
	StormEvent = true,
	TornadoEvent = true,
	MineStrikeEvent = true,
	MissileStrikeEvent = true,
}

local function showStraitPlaytestBannerIfNeeded(kind: string, data: { [string]: any })
	if not STRAIT_PLAYTEST_BANNER_KINDS[kind] then
		return
	end
	if kind == "MissileStrikeEvent" then
		local idx = tonumber(data.missileIndex) or 1
		if idx ~= 1 then
			return
		end
	end
	local title = if typeof(data.playtestTitle) == "string" and data.playtestTitle ~= "" then data.playtestTitle elseif typeof(data.displayName) == "string" then data.displayName else nil
	if typeof(title) == "string" and title ~= "" then
		StraitEventPlaytestBanner.show(playerGui, title)
	end
end

shipmentVisualEvent.OnClientEvent:Connect(function(packet)
	if typeof(packet) ~= "table" then
		return
	end
	local kind = packet.type
	local data = packet.data
	if typeof(data) ~= "table" then
		return
	end

	showStraitPlaytestBannerIfNeeded(kind, data)

	if kind == "PirateRaidEvent" then
		StraitWaypointWorldFx.OnPirateRaidPayload(data)
		local isOwner = data.ownerUserId == player.UserId
		local stolen = tonumber(data.barrelsStolen) or 0
		if isOwner then
			setStatus(string.format("PIRATES BOARDING! Lost %d barrels!", stolen), false)
		else
			setStatus("Pirates spotted raiding a vessel nearby!", true)
		end
		return
	end

	if kind == "CoastGuardInspectionEvent" then
		StraitWaypointWorldFx.OnCoastGuardInspectionPayload(data)
		local isOwner = data.ownerUserId == player.UserId
		if isOwner then
			setStatus("Coast guard boarding. Inspection in progress.", false)
		else
			setStatus("Coast guard vessel spotted inspecting a nearby ship.", true)
		end
		return
	end

	if kind == "USShipSlapEvent" then
		StraitWaypointWorldFx.OnUSShipSlapPayload(data)
		local isOwner = data.ownerUserId == player.UserId
		if isOwner then
			setStatus("GOVERNMENT SEIZURE! Your tanker has been confiscated!", false)
		else
			setStatus("A US Navy vessel just seized a nearby ship!", true)
		end
		return
	end

	if kind == "StormEvent" then
		StraitWaypointWorldFx.OnStormPayload(data)
		local isOwner = data.ownerUserId == player.UserId
		local didDelay = data.didDelay == true and (tonumber(data.delaySeconds) or 0) > 0
		local lost = math.max(0, tonumber(data.barrelsLost) or 0)
		local didLoss = data.didBarrelLoss == true and lost > 0
		if isOwner then
			if didDelay and didLoss then
				setStatus(string.format("STORM: delayed %.1fs and lost %d barrels.", tonumber(data.delaySeconds) or 0, lost), false)
			elseif didDelay then
				setStatus(string.format("STORM: heavy weather delay (%.1fs).", tonumber(data.delaySeconds) or 0), false)
			elseif didLoss then
				setStatus(string.format("STORM: cargo washed overboard (-%d barrels).", lost), false)
			else
				setStatus("STORM: rough weather, no major loss.", true)
			end
		else
			setStatus("A thunderstorm hit a nearby vessel.", true)
		end
		return
	end

	if kind == "TornadoEvent" then
		StraitWaypointWorldFx.OnTornadoPayload(data)
		local isOwner = data.ownerUserId == player.UserId
		local didDelay = data.didDelay == true and (tonumber(data.delaySeconds) or 0) > 0
		local lost = math.max(0, tonumber(data.barrelsLost) or 0)
		local didLoss = data.didBarrelLoss == true and lost > 0
		if isOwner then
			if didDelay and didLoss then
				setStatus(string.format("TORNADO: delayed %.1fs and lost %d barrels.", tonumber(data.delaySeconds) or 0, lost), false)
			elseif didDelay then
				setStatus(string.format("TORNADO: route disruption delay (%.1fs).", tonumber(data.delaySeconds) or 0), false)
			elseif didLoss then
				setStatus(string.format("TORNADO: barrels torn loose (-%d).", lost), false)
			else
				setStatus("TORNADO: near miss, shipment survived.", true)
			end
		else
			setStatus("A tornado is tearing through a nearby shipment lane.", false)
		end
		return
	end

	if kind == "MineStrikeEvent" then
		StraitWaypointWorldFx.OnMineStrikePayload(data)
		local isOwner = data.ownerUserId == player.UserId
		if data.didHit then
			setStatus(isOwner and "MINE HIT — Ship destroyed!" or "A vessel struck a mine!", false)
		else
			setStatus(isOwner and "Mines spotted! Navigating through..." or "Mines surfaced near a vessel!", true)
		end
		return
	end

	if kind == "MissileStrikeEvent" then
		StraitWaypointWorldFx.OnMissileStrikePayload(data)
		local isOwner = data.ownerUserId == player.UserId
		local outcome = tostring(data.outcome or "?")
		if outcome == "hit" then
			setStatus(isOwner and "MISSILE STRIKE — Ship destroyed!" or "A vessel was destroyed by a missile!", false)
		elseif outcome == "smallHit" then
			setStatus(isOwner and "MISSILE NEAR HIT — Barrels lost!" or "A missile grazed a vessel nearby!", false)
		else
			setStatus(isOwner and "Missile missed!" or "A missile splashed near a vessel.", true)
		end
		return
	end

	if kind == "StraitWaypointEvent" then
		StraitWaypointWorldFx.OnStraitWaypointPayload(data)
		local name = tostring(data.displayName or data.eventId or "Strait event")
		local sev = tostring(data.severity or "?")
		local isOwner = data.ownerUserId == player.UserId
		if data.totalLoss then
			setStatus(
				isOwner and string.format("STRAIT: %s (%s) — shipment lost", name, sev)
					or string.format("Strait: another vessel lost cargo (%s)", sev),
				false
			)
		else
			local lost = tonumber(data.barrelsLost) or 0
			local extra = lost > 0 and string.format(" — lost %d barrel(s), %d left", lost, tonumber(data.totalLoaded) or 0) or ""
			setStatus(
				isOwner and string.format("STRAIT: %s (%s)%s", name, sev, extra)
					or string.format("Strait: event on another shipment (%s)", sev),
				true
			)
		end
		return
	end

	if data.ownerUserId ~= player.UserId then
		return
	end

	if kind == "ShipmentStarted" then
		local shipLabel = if typeof(data.shipDisplayName) == "string" and (data :: any).shipDisplayName ~= ""
			then (data :: any).shipDisplayName
			else tostring((data :: any).shipSkinId or (data :: any).boatTypeId or "Ship")
		setStatus(string.format("Shipment out: %s (%d barrels)", shipLabel, tonumber(data.loaded) or 0), true)
	elseif kind == "ShipmentResolved" then
		setStatus(
			string.format(
				"Shipment done. %d barrels delivered to warehouse (%d lost). Sell at market for cash.",
				tonumber(data.delivered) or 0,
				tonumber(data.lost) or 0
			),
			true
		)
	end
end)

-- Cache each active drill model's initial pivot + initial height so we can apply sink offsets
local activeDrillBasePivots: { [Instance]: CFrame } = {}
local activeDrillHeights: { [Instance]: number } = {}

local function animateActiveDrill(model: Instance)
	if not model:IsA("Model") and not model:IsA("BasePart") then return end
	local startTime = tonumber(model:GetAttribute("StartTime"))
	local endTime = tonumber(model:GetAttribute("EndTime"))
	if not startTime or not endTime or endTime <= startTime then return end

	local basePivot = activeDrillBasePivots[model]
	if not basePivot then
		basePivot = model:IsA("Model") and model:GetPivot() or (model :: BasePart).CFrame
		activeDrillBasePivots[model] = basePivot

		local bbSizeY = 1
		if model:IsA("Model") then
			local _, bbSize = model:GetBoundingBox()
			bbSizeY = math.max(1, bbSize.Y)
		else
			bbSizeY = math.max(1, (model :: BasePart).Size.Y)
		end
		activeDrillHeights[model] = bbSizeY
	end

	local duration = endTime - startTime
	local alpha = math.clamp((workspace:GetServerTimeNow() - startTime) / duration, 0, 1)

	-- Spin: integrate angular speed over time. speed(t) = BASE + PEAK * t^2  (accelerating)
	-- Integral from 0 to t = BASE*t + PEAK*t^3/3. We express in alpha so: duration * (BASE*alpha + PEAK*alpha^3/3)
	local BASE_RAD = 3   -- starting angular speed rad/s
	local PEAK_RAD = 40  -- added peak angular speed at alpha=1
	local spinAngle = duration * (BASE_RAD * alpha + PEAK_RAD * alpha * alpha * alpha / 3)

	-- Sink: smoothly descends to fully submerged at alpha=1
	local heightY = activeDrillHeights[model] or 5
	local sinkDepth = heightY * alpha * alpha  -- quadratic ease-in so it accelerates downward

	local offset = CFrame.new(0, -sinkDepth, 0) * CFrame.Angles(0, spinAngle, 0)
	local target = basePivot * offset
	if model:IsA("Model") then
		model:PivotTo(target)
	else
		(model :: BasePart).CFrame = target
	end
end

-- PERF: per-frame lookups used to call workspace:GetDescendants() (14k-instance walk).
-- Cached sets, maintained via DescendantAdded/Removing — O(1) instead of O(workspace).
local _activeDrillsFolders: { [Folder]: true } = {}
local _activeProspectorsFolders: { [Folder]: true } = {}
local _superTileSet: { [BasePart]: true } = {}
do
	local function consider(d: Instance)
		if d:IsA("Folder") then
			if d.Name == "ActiveDrills" then _activeDrillsFolders[d] = true
			elseif d.Name == "ActiveProspectors" then _activeProspectorsFolders[d] = true
			end
		elseif d:IsA("BasePart") and d:GetAttribute("TileName") == "SUPER TILE" then
			_superTileSet[d] = true
		end
	end
	for _, d in ipairs(workspace:GetDescendants()) do consider(d) end
	workspace.DescendantAdded:Connect(consider)
	workspace.DescendantRemoving:Connect(function(d)
		_activeDrillsFolders[d] = nil
		_activeProspectorsFolders[d] = nil
		_superTileSet[d] = nil
	end)
end

local function forEachActiveDrill(fn)
	for folder in pairs(_activeDrillsFolders) do
		if folder.Parent then
			for _, m in ipairs(folder:GetChildren()) do
				if m.Name:match("^ActiveDrill_") then
					fn(m)
				end
			end
		end
	end
end

-- Update the text on every drill's static timer billboard
local function updateDrillTimers()
	local now = workspace:GetServerTimeNow()
	for folder in pairs(_activeDrillsFolders) do
		if folder.Parent then
			for _, anchor in ipairs(folder:GetChildren()) do
				if anchor.Name:match("^DrillTimer_") and anchor:IsA("BasePart") then
					local bb = anchor:FindFirstChild("TimerGui")
					local lbl = bb and bb:FindFirstChild("TimerLabel")
					if lbl and lbl:IsA("TextLabel") then
						local endT = tonumber(anchor:GetAttribute("EndTime")) or 0
						local remaining = math.max(0, endT - now)
						if remaining >= 60 then
							lbl.Text = string.format("%dm %02ds", math.floor(remaining / 60), math.floor(remaining % 60))
						else
							lbl.Text = string.format("%.1fs", remaining)
						end
					end
				end
			end
		end
	end
end

local function forEachActiveProspector(fn)
	for folder in pairs(_activeProspectorsFolders) do
		if folder.Parent then
			for _, m in ipairs(folder:GetChildren()) do
				fn(m)
			end
		end
	end
end

RunService.RenderStepped:Connect(function()
	updateFocusUi()
	updateGhost()
	updatePipeGhost()
	updateHammerHover()

	if removeHoldDrillId ~= nil and removeHoldStart > 0 then
		local drill = drillStateById[removeHoldDrillId]
		if not drill then
			clearRemoveHold()
			return
		end
		local pos = Vector3.new(drill.position.x, drill.position.y, drill.position.z)
		if distanceFromCharacter(pos) > (config.removeDrillRangeStuds or 18) then
			clearRemoveHold()
			return
		end
		local holdSeconds = config.removeDrillHoldSeconds or 2
		if time() - removeHoldStart >= holdSeconds then
			requestRemoveDrill:FireServer({ drillId = removeHoldDrillId })
			clearRemoveHold()
		end
	end

	-- Animate every active drill regardless of how the plot is nested
	forEachActiveDrill(animateActiveDrill)
	-- Prospectors use the same sink animation helper
	forEachActiveProspector(animateActiveDrill)
	-- Countdown timers on each drill's static anchor billboard
	updateDrillTimers()

	-- SUPER TILE: pulse HSV rainbow on every tile tagged with TileName = "SUPER TILE".
	-- Use cached set built once + maintained by attribute change listener — was scanning the
	-- entire workspace tree every frame which dominated frame time.
	local t = workspace:GetServerTimeNow()
	for tilePart in pairs(_superTileSet) do
		if tilePart.Parent then
			local hue = (t * 0.6 + tilePart.Position.X * 0.02 + tilePart.Position.Z * 0.02) % 1
			tilePart.Color = Color3.fromHSV(hue, 1, 1)
		end
	end
end)

-- Clean up pivot cache when models are destroyed (otherwise leaked references)
workspace.DescendantRemoving:Connect(function(inst)
	if activeDrillBasePivots[inst] then
		activeDrillBasePivots[inst] = nil
	end
end)

-- Prospector status messages
prospectProgressUpdate.OnClientEvent:Connect(function(data)
	if typeof(data) ~= "table" then return end
	if data.ownerUserId ~= player.UserId then return end
	if data.kind == "started" then
		setStatus(string.format("Prospecting chunk %s — %.1fs", tostring(data.chunkId or "?"), tonumber(data.duration) or 0), false)
	elseif data.kind == "completed" then
		setStatus("Prospect complete! Oil tiles glowing green, dry tiles darkened.", false)
	end
end)

-- Status message when the server confirms drill start/completion/pump placement
drillProgressUpdate.OnClientEvent:Connect(function(data)
	if typeof(data) ~= "table" then return end
	if data.kind == "started" and data.ownerUserId == player.UserId then
		setStatus(string.format("Drilling (%s) — %.1fs", tostring(data.tier or "?"), tonumber(data.duration) or 0), false)
	elseif data.kind == "completed" and data.ownerUserId == player.UserId then
		if data.hasOil == false then
			setStatus("Dry hole — no oil under this tile.", false)
		else
			setStatus("Drill complete. Place a pump on this tile!", false)
		end
	elseif data.kind == "pumpPlaced" and data.ownerUserId == player.UserId then
		setStatus("Pump online — producing oil.", false)
	end
end)

-- Barrel pickup: listen for PickupPrompt ProximityPrompts that appear on conveyor barrels
Workspace.DescendantAdded:Connect(function(descendant)
	if descendant:IsA("ProximityPrompt") and descendant.Name == "PickupPrompt" then
		descendant.Triggered:Connect(function(triggeringPlayer)
			if triggeringPlayer ~= player then return end
			-- Walk up to find the barrel model/part that owns this prompt
			local cursor: Instance? = descendant
			while cursor and cursor.Parent do
				cursor = cursor.Parent
				if cursor and typeof(cursor:GetAttribute("Tier")) == "string" then
					requestPickupBarrel:FireServer({ barrelName = cursor.Name })
					return
				end
			end
		end)
	end
end)

-- Biome reveal slot machine animation
biomeRevealEvent.OnClientEvent:Connect(function(data)
	if typeof(data) ~= "table" or not data.biome or not data.chunkId then return end
	local biomeName = data.biome
	local chunkId = data.chunkId

	-- Find the section model to animate its tiles
	local sectionModel = nil
	if ownedPlot then
		local ground = ownedPlot:FindFirstChild("PlotGround")
		if ground then
			sectionModel = ground:FindFirstChild(chunkId)
		end
	end

	-- Remove the fog overlay immediately
	if sectionModel then
		local overlay = sectionModel:FindFirstChild("LockOverlay")
		if overlay and overlay:IsA("BasePart") then
			overlay.Transparency = 1
		end
		local sign = sectionModel:FindFirstChild("Sign")
		if sign then
			for _, d in ipairs(sign:GetDescendants()) do
				if d:IsA("BasePart") then d.Transparency = 1 end
				if d:IsA("ProximityPrompt") then d.Enabled = false end
				if d:IsA("SurfaceGui") then d.Enabled = false end
			end
		end
	end

	-- Slot machine: flash REAL biome tile sets (pulled live from BiomeConfig) onto the 5x5 grid.
	-- Only flash biomes that could actually appear for THIS chunk (from its row pool).
	task.spawn(function()
		local biomeConfig = require(Shared:WaitForChild("Config"):WaitForChild("BiomeConfig"))

		-- Parse the chunk row from chunkId (format "S<row>_<col>")
		local chunkRow = tonumber(tostring(chunkId):match("^S(%d+)_"))
		local rowPool = chunkRow and biomeConfig.RowPools and biomeConfig.RowPools[chunkRow] or nil

		-- Build presets from the row's pool (fallback to all biomes if no pool found)
		local biomePresets = {}
		local function addPreset(bname)
			local biome = biomeConfig.Biomes[bname]
			if not biome then return end
			local preset = { name = bname, tiles = {} }
			for _, tt in ipairs(biome.tileTypes or {}) do
				table.insert(preset.tiles, {
					mat = tt.material or Enum.Material.Plastic,
					col = tt.color or Color3.fromRGB(180, 180, 180),
					w = tt.weight or 1,
				})
			end
			if #preset.tiles > 0 then table.insert(biomePresets, preset) end
		end
		if rowPool then
			for _, bname in ipairs(rowPool) do addPreset(bname) end
		else
			for bname, _ in pairs(biomeConfig.Biomes) do addPreset(bname) end
		end
		if #biomePresets == 0 then return end

		local function rollTile(preset)
			local totalW = 0
			for _, t in ipairs(preset.tiles) do totalW += t.w end
			local r = math.random(1, totalW)
			local cursor = 0
			for _, t in ipairs(preset.tiles) do
				cursor += t.w
				if r <= cursor then return t end
			end
			return preset.tiles[1]
		end

		local tileParts = {}
		if sectionModel then
			for _, child in ipairs(sectionModel:GetChildren()) do
				if child:IsA("BasePart") and child.Name:match("^T%d%d$") then
					table.insert(tileParts, child)
				end
			end
		end

		-- Flash-through animation (no obstacle preview: obstacles removed)
		local intervals = { 0.12, 0.12, 0.15, 0.18, 0.22, 0.3, 0.4, 0.6 }
		for i, interval in ipairs(intervals) do
			local preset = biomePresets[((i - 1) % #biomePresets) + 1]
			for _, part in ipairs(tileParts) do
				local t = rollTile(preset)
				part.Material = t.mat
				part.Color = t.col
			end
			task.wait(interval)
		end

		_ = biomeName
		task.wait(3.5)
	end)
end)

-- Obstacle system removed; clear-prompt binding deleted.

-- =================== OIL MARKET (data only; wire StarterGui HUD later) ===================

marketPriceUpdate.OnClientEvent:Connect(function(data)
	if typeof(data) ~= "table" then
		return
	end
	marketState.basePrice = data.basePrice or marketState.basePrice
	marketState.prices = data.prices or marketState.prices
	marketState.trend = data.trend or marketState.trend
	marketState.straitState = data.straitState or marketState.straitState
	marketState.nextChangeAt = data.nextChangeAt or marketState.nextChangeAt
	marketState.globalBaseMin = data.globalBaseMin or marketState.globalBaseMin
	marketState.globalBaseMax = data.globalBaseMax or marketState.globalBaseMax
	if data.typeMultipliers then
		marketState.typeMultipliers = data.typeMultipliers
	end
	updateMarketUi()
end)

task.spawn(function()
	local snapshot = requestMarketSnapshot:InvokeServer()
	if typeof(snapshot) == "table" then
		marketState.basePrice = snapshot.basePrice or 10
		marketState.prices = snapshot.prices or {}
		marketState.trend = snapshot.trend or "stable"
		marketState.straitState = snapshot.straitState or "Open"
		marketState.nextChangeAt = snapshot.nextChangeAt or 0
		marketState.globalBaseMin = snapshot.globalBaseMin or 8
		marketState.globalBaseMax = snapshot.globalBaseMax or 80
		if snapshot.typeMultipliers then
			marketState.typeMultipliers = snapshot.typeMultipliers
		end
		updateMarketUi()
	end
end)

print("[Client] Chunked plot mode active.")

-- /diag chat command: dumps client-side plot state so we can see what the player's
-- client thinks the world looks like. Must live here (end of file) so it closes
-- over the ACTUAL local `ownedPlot` / `state` — putting it earlier captured globals.
player.Chatted:Connect(function(message)
	local cmd = message:lower():gsub("^%s+", ""):gsub("%s+$", "")
	if cmd ~= "/diag" then return end

	local myPlotId = player:GetAttribute("PlotId")
	print(string.format("[DIAG] PlotId attr=%s ownedPlot=%s",
		tostring(myPlotId),
		ownedPlot and ownedPlot.Name or "<NIL>"))

	if ownedPlot then
		local ground = ownedPlot:FindFirstChild("PlotGround")
		if ground then
			local visible, invisible = 0, 0
			for _, section in ipairs(ground:GetChildren()) do
				if section:IsA("Model") then
					for _, child in ipairs(section:GetChildren()) do
						if child:IsA("BasePart") and child.Name:match("^T%d%d$") then
							if child.Transparency >= 1 then
								invisible += 1
							else
								visible += 1
							end
						end
					end
				end
			end
			print(string.format("[DIAG] Tiles: visible=%d invisible=%d (expect 300 visible)",
				visible, invisible))

			local starter = ground:FindFirstChild("S04_02")
			if starter then
				local t11 = starter:FindFirstChild("T11")
				if t11 and t11:IsA("BasePart") then
					print(string.format("[DIAG] S04_02.T11: Pos=%s Mat=%s Color=%s Trans=%.2f",
						tostring(t11.Position),
						t11.Material.Name,
						tostring(t11.Color),
						t11.Transparency))
				end
				local overlay = starter:FindFirstChild("LockOverlay")
				if overlay and overlay:IsA("BasePart") then
					print(string.format("[DIAG] S04_02.LockOverlay: Trans=%.2f Color=%s",
						overlay.Transparency, tostring(overlay.Color)))
				end
			end
		end

		local ch = player.Character
		local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
		if hrp then
			print(string.format("[DIAG] HRP.Pos=%s", tostring(hrp.Position)))
		end
	end

	if state and state.chunks then
		local unlocked, locked = 0, 0
		for _, c in ipairs(state.chunks) do
			if c.unlocked then unlocked += 1 else locked += 1 end
		end
		print(string.format("[DIAG] State: %d unlocked + %d locked chunks", unlocked, locked))
	else
		print("[DIAG] state is nil or missing chunks")
	end
end)
