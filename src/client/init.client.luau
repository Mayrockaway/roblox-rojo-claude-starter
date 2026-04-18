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

--- FTUE overlays / pointer ScreenGuis must match **`HUD.IgnoreGuiInset`** or scale-based positions
--- sit in a different viewport (safe-area vs full screen) and look misaligned next to HUD.
--- Modal `ScreenGuis` pointed at during FTUE (e.g. Ship Oil) must use the **same** inset as the pointer layer
--- (`FTUEDialogueGui`) or authored `UDim2` positions will not line up in play vs devices with safe areas.
local function syncFtueOverlayInsetWithHud()
	local hud = playerGui:FindFirstChild("HUD", true)
	if not (hud and hud:IsA("ScreenGui")) then
		return
	end
	local inset = hud.IgnoreGuiInset
	-- FTUE pointers live under `Canvas.Pointers` inside `FTUEDialogueGui` (not separate top-level ScreenGuis).
	for _, n in ipairs({
		"FTUEDialogueGui",
		"FtueDialogueGui",
		"ShipOilPanelGui",
		"SellOilPanelGui",
	}) do
		local sg = playerGui:FindFirstChild(n, true)
		if sg and sg:IsA("ScreenGui") then
			sg.IgnoreGuiInset = inset
		end
	end
end

task.defer(syncFtueOverlayInsetWithHud)
task.spawn(function()
	for _ = 1, 120 do
		syncFtueOverlayInsetWithHud()
		local hud = playerGui:FindFirstChild("HUD", true)
		if hud and hud:IsA("ScreenGui") then
			break
		end
		task.wait(0.25)
	end
end)
playerGui.ChildAdded:Connect(function(ch)
	if ch:IsA("ScreenGui") then
		task.defer(syncFtueOverlayInsetWithHud)
	end
end)

local playerScripts = player:WaitForChild("PlayerScripts")
local resolveClientModuleScript: ModuleScript? = nil
for _ = 1, 300 do
	local r = playerScripts:FindFirstChild("ResolveClientModule", true)
	if r and r:IsA("ModuleScript") then
		resolveClientModuleScript = r
		break
	end
	task.wait(0.05)
end
if not resolveClientModuleScript then
	error("[init.client] Missing ResolveClientModule under PlayerScripts (sync Rojo `src/client`).")
end
local resolveClientModule = require(resolveClientModuleScript)
local ClientAudioPreferences = require(resolveClientModule(script, "ClientAudioPreferences"))
ClientAudioPreferences.init()

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))
local Constants = require(Shared:WaitForChild("Constants"))
local OilConfig = require(Shared:WaitForChild("Config"):WaitForChild("OilConfig"))
local FtueConfig = require(Shared:WaitForChild("Config"):WaitForChild("FtueConfig"))
local PlacementAnchor = require(Shared:WaitForChild("Utils"):WaitForChild("PlacementAnchor"))
local PlotCellTileResolve = require(Shared:WaitForChild("Utils"):WaitForChild("PlotCellTileResolve"))

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
local requestRevealTile = waitRemote(RemoteNames.RequestRevealTile) :: RemoteEvent
local requestDispatchShipment = waitRemote(RemoteNames.RequestDispatchShipment) :: RemoteEvent
local oilStateUpdate = waitRemote(RemoteNames.OilStateUpdate) :: RemoteEvent
local oilActionResult = waitRemote(RemoteNames.OilActionResult) :: RemoteEvent
local requestFtueAcknowledge = waitRemote(RemoteNames.RequestFtueAcknowledge) :: RemoteEvent
local requestFtueSkip = waitRemote(RemoteNames.RequestFtueSkip) :: RemoteEvent
local ftueStateUpdate = waitRemote(RemoteNames.FtueStateUpdate) :: RemoteEvent
local shipmentVisualEvent = waitRemote(RemoteNames.ShipmentVisualEvent) :: RemoteEvent
local requestDevSetStraitBracket = waitRemote(RemoteNames.RequestDevSetStraitBracket) :: RemoteEvent
local globalStateUpdate = waitRemote(RemoteNames.GlobalStateUpdate) :: RemoteEvent
local fighterFlyoverEvent = waitRemote(RemoteNames.FighterFlyoverEvent) :: RemoteEvent
local requestPirateHireTargets = waitRemote(RemoteNames.RequestPirateHireTargets) :: RemoteFunction
local requestPirateHireAction = waitRemote(RemoteNames.RequestPirateHireAction) :: RemoteEvent
local pirateHireOpenEvent = waitRemote(RemoteNames.PirateHireOpen) :: RemoteEvent
local pirateHireResultEvent = waitRemote(RemoteNames.PirateHireResult) :: RemoteEvent
local pirateHitAlertEvent = waitRemote(RemoteNames.PirateHitAlert) :: RemoteEvent
local armyGeneralOpenEvent = waitRemote(RemoteNames.ArmyGeneralOpen) :: RemoteEvent
local requestArmyGeneralAction = waitRemote(RemoteNames.RequestArmyGeneralAction) :: RemoteEvent
local requestArmyGeneralTargets = waitRemote(RemoteNames.RequestArmyGeneralTargets) :: RemoteFunction
local armyGeneralResultEvent = waitRemote(RemoteNames.ArmyGeneralResult) :: RemoteEvent
local nukeCountdownEvent = waitRemote(RemoteNames.NukeCountdownEvent) :: RemoteEvent
local nukeDetonateEvent = waitRemote(RemoteNames.NukeDetonateEvent) :: RemoteEvent
local airStrikeEvent = waitRemote(RemoteNames.AirStrikeEvent) :: RemoteEvent

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

local function requireSkyMissileAmbience(): { Start: () -> (), Stop: () -> () }?
	local modScript: ModuleScript? = nil

	local selfChild = script:FindFirstChild("SkyMissileAmbience")
	if selfChild and selfChild:IsA("ModuleScript") then
		modScript = selfChild
	end

	if not modScript then
		local sibling = script.Parent and script.Parent:FindFirstChild("SkyMissileAmbience")
		if sibling and sibling:IsA("ModuleScript") then
			modScript = sibling
		end
	end

	if not modScript then
		local ps = player:FindFirstChild("PlayerScripts") or player:WaitForChild("PlayerScripts", 30)
		local clientFolder = ps and ps:FindFirstChild("Client")
		local m = clientFolder and clientFolder:FindFirstChild("SkyMissileAmbience")
		if m and m:IsA("ModuleScript") then
			modScript = m
		end
	end

	if not modScript then
		warn("[Client] SkyMissileAmbience module missing; sky missiles disabled.")
		return nil
	end

	local ok, loaded = pcall(require, modScript)
	if ok and typeof(loaded) == "table" then
		return loaded :: any
	end
	warn("[Client] SkyMissileAmbience failed to load:", loaded)
	return nil
end

local skyMissileAmbience = requireSkyMissileAmbience()
if skyMissileAmbience then
	skyMissileAmbience.Start()
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

	-- Must match server `OilConfig.Chunks` (not legacy `config.chunks` defaults) so cell keys align with FTUE / drills.
	local oc = OilConfig.Chunks
	local sectionCols = oc.GridCols
	local sectionRows = oc.GridRows
	local sectionSize = oc.Size
	local subTilesPerSide = math.floor(sectionSize / SUB_TILE_SIZE)

	-- Derive center from actual plot sections; default (0,0) matches `OilStateService.plotGridOrigin`
	-- when sections have no CenterX/CenterZ (legacy hardcoded -840,-1020 broke grid vs server).
	local centerX, centerZ = 0, 0
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
		if line:IsA("TextLabel") or line:IsA("TextButton") then
			line.Font = Enum.Font.Merriweather
		end
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
	selectedVictimUserId = nil :: number?,
	hitCost = 5000,
	freeHitTokens = 0,
}
local PIRATE_AUTO_CLOSE_DIST = 12
local COLOR_PIRATE_IDLE = Color3.fromRGB(255, 255, 255)
local COLOR_PIRATE_HOVER = Color3.fromRGB(255, 205, 80)
local COLOR_PIRATE_DIM = Color3.fromRGB(210, 210, 210)
local COLOR_PIRATE_GOLD = Color3.fromRGB(255, 170, 60)
local COLOR_PIRATE_MONEY = Color3.fromRGB(80, 220, 80)
local COLOR_PIRATE_RED = Color3.fromRGB(255, 80, 80)

local function closePirateHireUi()
	local s = pirateHireUiState.screen
	if s and s.Parent then
		s:Destroy()
	end
	pirateHireUiState.screen = nil
	pirateHireUiState.selectedVictimUserId = nil
end

local function pirateBlockyLine(name, text, order, isButton, parent)
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

local function openPirateHireUi(payload: any)
	closePirateHireUi()

	if typeof(payload) == "table" then
		pirateHireUiState.hitCost = math.max(0, math.floor(tonumber(payload.hitCost) or pirateHireUiState.hitCost))
		pirateHireUiState.freeHitTokens = math.max(0, math.floor(tonumber(payload.freeHitTokens) or 0))
	end

	local screen = Instance.new("ScreenGui")
	screen.Name = "PirateHireGui"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 60
	screen.Parent = playerGui
	pirateHireUiState.screen = screen

	-- Auto-close when walking away
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
			if (hrp.Position - piratePos).Magnitude > PIRATE_AUTO_CLOSE_DIST then
				closePirateHireUi()
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

	local header = pirateBlockyLine("Header", "Pirate Broker:", 1, false, root)
	header.Size = UDim2.new(1, 0, 0, 50); header.TextSize = 44

	local askBtn = pirateBlockyLine("AskButton", "Ask a question", 2, true, root)
	local hireBtn = pirateBlockyLine("HireButton", string.format("Hire a hit ($%d)", pirateHireUiState.hitCost), 3, true, root)
	if pirateHireUiState.freeHitTokens > 0 then
		local freeLabel = pirateBlockyLine("FreeTokens", string.format("  Free tokens: %d", pirateHireUiState.freeHitTokens), 4, false, root)
		freeLabel.TextSize = 22; freeLabel.Size = UDim2.new(1, 0, 0, 28); freeLabel.TextColor3 = COLOR_PIRATE_MONEY
	end
	local backBtn = pirateBlockyLine("BackButton", "back", 10, true, root)
	backBtn.TextSize = 28; backBtn.TextColor3 = COLOR_PIRATE_DIM
	backBtn.MouseLeave:Connect(function() backBtn.TextColor3 = COLOR_PIRATE_DIM end)
	backBtn.MouseButton1Click:Connect(closePirateHireUi)

	askBtn.MouseButton1Click:Connect(function()
		requestPirateHireAction:FireServer({ action = "ask" })
		local quotes = {"Arrr, the seas be rough today!", "I know every ship in these waters.", "Gold talks, sailor.", "Need someone sunk? I know a crew.", "The strait takes what it wants!"}
		header.Text = quotes[math.random(1, #quotes)]; header.TextSize = 28
		task.delay(2, function() if header.Parent then header.Text = "Pirate Broker:"; header.TextSize = 44 end end)
	end)

	hireBtn.MouseButton1Click:Connect(function()
		-- Show targets submenu
		header.Text = "Pick a target:"; header.TextSize = 38
		askBtn.Visible = false; hireBtn.Visible = false; backBtn.Visible = false
		for _, c in ipairs(root:GetChildren()) do if c.Name:find("Target_") or c.Name == "FreeTokens" or c.Name == "NoTargets" or c.Name == "HireBack" then c:Destroy() end end

		local ok, result = pcall(function()
			return requestPirateHireTargets:InvokeServer()
		end)
		if not ok or typeof(result) ~= "table" then
			local errLabel = pirateBlockyLine("NoTargets", "Could not fetch targets", 5, false, root)
			errLabel.TextSize = 22; errLabel.Size = UDim2.new(1, 0, 0, 28); errLabel.TextColor3 = COLOR_PIRATE_RED
		else
			pirateHireUiState.freeHitTokens = math.max(0, math.floor(tonumber((result :: any).freeHitTokens) or 0))
			pirateHireUiState.hitCost = math.max(0, math.floor(tonumber((result :: any).hitCost) or pirateHireUiState.hitCost))
			local targets = (result :: any).targets
			local order = 5
			if typeof(targets) == "table" and #targets > 0 then
				for _, target in ipairs(targets) do
					if typeof(target) == "table" then
						local userId = tonumber(target.userId)
						if userId then
							local dn = tostring(target.displayName or target.name or ("User " .. tostring(userId)))
							local label = string.format("%s", dn)
							local tBtn = pirateBlockyLine("Target_" .. tostring(userId), label, order, true, root)
							tBtn.TextSize = 26; tBtn.Size = UDim2.new(1, 0, 0, 34)
							-- Add cost label
							local costLabel = Instance.new("TextLabel")
							costLabel.Size = UDim2.new(0.4, 0, 1, 0); costLabel.Position = UDim2.new(0.6, 0, 0, 0)
							costLabel.BackgroundTransparency = 1; costLabel.Text = string.format("$%d", pirateHireUiState.hitCost)
							costLabel.Font = Enum.Font.LuckiestGuy; costLabel.TextSize = 22; costLabel.TextColor3 = COLOR_PIRATE_MONEY
							costLabel.TextStrokeTransparency = 0; costLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
							costLabel.TextXAlignment = Enum.TextXAlignment.Right; costLabel.Parent = tBtn
							tBtn.MouseButton1Click:Connect(function()
								requestPirateHireAction:FireServer({ action = "hire", victimUserId = userId })
								header.Text = "Pirates dispatched!"; header.TextSize = 32
								task.delay(1.5, closePirateHireUi)
							end)
							order += 1
						end
					end
				end
			else
				local noTargets = pirateBlockyLine("NoTargets", "No ships on the strait", 5, false, root)
				noTargets.TextSize = 22; noTargets.Size = UDim2.new(1, 0, 0, 28); noTargets.TextColor3 = COLOR_PIRATE_DIM
			end
		end

		local hireBack = pirateBlockyLine("HireBack", "back", 99, true, root)
		hireBack.TextSize = 24; hireBack.TextColor3 = COLOR_PIRATE_DIM
		hireBack.MouseLeave:Connect(function() hireBack.TextColor3 = COLOR_PIRATE_DIM end)
		hireBack.MouseButton1Click:Connect(function() closePirateHireUi(); openPirateHireUi(payload) end)
	end)
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
		if want and ownedPlot then
			local ch = chunkStateById[chunkId]
			local ck = PlotCellTileResolve.globalCellKeyFromChunkHit(
				ownedPlot,
				chunkId,
				hitPos.X,
				hitPos.Z,
				ch and ch.row,
				ch and ch.col
			)
			if ck ~= want then
				return false
			end
		end
	elseif kind == "Pump" then
		local want = readLocalFtueCellKey(Constants.FtueRestrictPumpCellKeyAttribute)
		if want and ownedPlot then
			local ch = chunkStateById[chunkId]
			local ck = PlotCellTileResolve.globalCellKeyFromChunkHit(
				ownedPlot,
				chunkId,
				hitPos.X,
				hitPos.Z,
				ch and ch.row,
				ch and ch.col
			)
			if ck ~= want then
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
	focusLabel.Font = Enum.Font.Merriweather
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

		local ppoMod = uiFolder:FindFirstChild("ProximityPanelOpener")
		if ppoMod and ppoMod:IsA("ModuleScript") then
			local ProximityPanelOpener = require(ppoMod) :: { start: () -> () }
			ProximityPanelOpener.start()
		end

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
	lbl.Font = Enum.Font.Merriweather
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
		if wantDrill and ownedPlot then
			local ch = chunkStateById[chunkId]
			local ck = PlotCellTileResolve.globalCellKeyFromChunkHit(
				ownedPlot,
				chunkId,
				hitPos.X,
				hitPos.Z,
				ch and ch.row,
				ch and ch.col
			)
			if ck ~= wantDrill then
				setStatus(FtueConfig.ClientHintPlaceDrillOnTile, false)
				return
			end
		end
		requestStartDrill:FireServer(payload)
	elseif kind == "Pump" then
		local wantPump = readLocalFtueCellKey(Constants.FtueRestrictPumpCellKeyAttribute)
		if wantPump and ownedPlot then
			local ch = chunkStateById[chunkId]
			local ck = PlotCellTileResolve.globalCellKeyFromChunkHit(
				ownedPlot,
				chunkId,
				hitPos.X,
				hitPos.Z,
				ch and ch.row,
				ch and ch.col
			)
			if ck ~= wantPump then
				setStatus(FtueConfig.ClientHintPlacePumpOnTile, false)
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
	-- Grid cache must rebuild if snapshot arrived late or chunk dimensions changed.
	_clientGridCache = nil
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

--- Death/respawn: re-validate hotbar binding (strip may be recreated) and let controller rebuild after tools replicate.
player.CharacterAdded:Connect(function()
	task.defer(tryBindEquipmentHotbarAsync)
	task.delay(0.18, tryBindEquipmentHotbarAsync)
	task.delay(0.55, tryBindEquipmentHotbarAsync)
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
	if payload.code == "ERR_FTUE_WRONG_TILE" then
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

-- Helper: play a one-shot SFX from Assets.SFX (non-positional, only for this client)
local function playEventSFX(sfxName: string, volume: number?)
	if not ClientAudioPreferences.isSfxEnabled() then
		return
	end
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local sfxFolder = assets and assets:FindFirstChild("SFX")
	local template = sfxFolder and sfxFolder:FindFirstChild(sfxName)
	if not template or not template:IsA("Sound") then return end
	local snd = template:Clone()
	snd.Volume = volume or 0.7
	snd.Parent = workspace.CurrentCamera or workspace
	snd:Play()
	snd.Ended:Once(function() snd:Destroy() end)
end

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
			-- Play strait status change SFX
			print("[StraitSFX] State changed: " .. tostring(prev) .. " -> " .. tostring(snapshot.state))
			local newState = snapshot.state
			if newState == "Closed" then
				playEventSFX("StraitClosed")
			elseif newState == "Open" then
				playEventSFX("StraitOpen")
			else
				-- Tense, Dangerous, Crisis, Restricted — all play restricted sound
				playEventSFX("StraitRestricted")
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

-- Server uses FireClient per recipient; banner only reaches impacted players.
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
	-- ShipmentVisualEvent is FireAllClients; show the large playtest title only to the ship owner.
	local ownerUid = data.ownerUserId or data.playerUserId
	if typeof(ownerUid) ~= "number" or ownerUid ~= player.UserId then
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

-- Helper: play a one-shot SFX from Assets.SFX (non-positional, only for this client)
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
		if isOwner then playEventSFX("Pirates") end
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
		if isOwner then playEventSFX("Coastguard") end
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
			setStatus("SEA MONSTER! Your ship is under attack!", false)
			-- ShipDestroyed SFX is handled inside the kraken FX (plays after kraken audio ends)
		else
			setStatus("A sea monster just attacked a nearby ship!", true)
		end
		return
	end

	if kind == "StormEvent" then
		StraitWaypointWorldFx.OnStormPayload(data)
		local isOwner = data.ownerUserId == player.UserId
		if isOwner then playEventSFX("Storm") end
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
		if isOwner then playEventSFX("Tornado") end
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
		if isOwner then playEventSFX("Mines") end
		if data.didHit then
			if isOwner then
				task.delay(4, function() setStatus("MINE HIT — Ship destroyed!", false) end)
				task.delay(4, function() playEventSFX("ShipDestroyed") end)
			else
				setStatus("A vessel struck a mine!", false)
			end
		else
			setStatus(isOwner and "Mines spotted! Navigating through..." or "Mines surfaced near a vessel!", true)
		end
		return
	end

	if kind == "MissileStrikeEvent" then
		StraitWaypointWorldFx.OnMissileStrikePayload(data)
		local isOwner = data.ownerUserId == player.UserId
		-- Play catalog "MissileStrike" when this missile actually connects (not only barrage slot 1 — first rocket can miss).
		local outcome = tostring(data.outcome or "")
		if isOwner and (outcome == "hit" or outcome == "smallHit") then
			playEventSFX("MissileStrike")
		end
		if outcome == "hit" then
			if isOwner then
				task.delay(4, function() setStatus("MISSILE STRIKE — Ship destroyed!", false) end)
				task.delay(4, function() playEventSFX("ShipDestroyed") end)
			else
				setStatus("A vessel was destroyed by a missile!", false)
			end
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
		if isOwner and (data.eventId == "RoutinePaperwork" or data.eventId == "EngineRoomSmoke") then
			playEventSFX("Paperwork")
		end
		if data.totalLoss then
			if isOwner then
				task.delay(4, function()
					setStatus(string.format("STRAIT: %s (%s) — shipment lost", name, sev), false)
					playEventSFX("ShipDestroyed")
				end)
			else
				setStatus(string.format("Strait: another vessel lost cargo (%s)", sev), false)
			end
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
		local delivered = tonumber(data.delivered) or 0
		local lost = tonumber(data.lost) or 0
		local totalLoss = delivered == 0 and lost == 0
		if not totalLoss then
			setStatus(
				string.format(
					"Shipment done. %d barrels delivered to warehouse (%d lost). Sell at market for cash.",
					delivered, lost
				),
				true
			)
			-- Delivery SFX only if ship actually delivered (not destroyed)
			if lost == 0 then
				playEventSFX("DeliverySuccess")
			else
				playEventSFX("DeliveryOk")
			end
		end
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
		-- Spawn DrillComplete model on the tile with ProximityPrompt
		setStatus("Drill complete! Press E to reveal what's underneath.", false)
		local pos = if typeof(data.position) == "table"
			then Vector3.new(tonumber(data.position.x) or 0, tonumber(data.position.y) or 0, tonumber(data.position.z) or 0)
			else Vector3.new(0, 0, 0)
		local dcTemplate = ReplicatedStorage:FindFirstChild("Assets") and ReplicatedStorage.Assets:FindFirstChild("DrillComplete")
		if dcTemplate and pos.Magnitude > 0 then
			task.spawn(function()
				local dc = dcTemplate:Clone()
				dc.Name = "DrillComplete_" .. tostring(data.chunkId) .. "_" .. tostring(data.tileKey)
				for _, d in ipairs(dc:GetDescendants()) do
					if d:IsA("BasePart") then d.Anchored = true; d.CanCollide = false end
				end
				dc:PivotTo(CFrame.new(pos + Vector3.new(0, 4, 0)))
				dc.Parent = Workspace

				local prompt = Instance.new("ProximityPrompt")
				prompt.Name = "RevealPrompt"
				prompt.ActionText = "Reveal"
				prompt.ObjectText = "Drill Complete"
				prompt.KeyboardKeyCode = Enum.KeyCode.E
				prompt.MaxActivationDistance = 12
				prompt.RequiresLineOfSight = false
				prompt.HoldDuration = 0
				local root = dc:FindFirstChildWhichIsA("BasePart")
				if root then prompt.Parent = root end

				prompt.Triggered:Connect(function(trigPlayer)
					if trigPlayer ~= player then return end
					requestRevealTile:FireServer({
						chunkId = data.chunkId,
						tileKey = data.tileKey,
					})
					-- Remove prompt immediately so you can't double-press
					prompt:Destroy()
				end)
			end)
		end

	elseif data.kind == "revealed" and data.ownerUserId == player.UserId then
		-- Remove DrillComplete model
		local dcName = "DrillComplete_" .. tostring(data.chunkId) .. "_" .. tostring(data.tileKey)
		local dcModel = Workspace:FindFirstChild(dcName)
		if dcModel then dcModel:Destroy() end

		local veinResult = data.veinResult
		if not veinResult then return end

		-- Find the tile Part in workspace by position
		local VeinConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("VeinConfig"))
		local displayName = VeinConfig.BuildDisplayName(veinResult)
		local prob = VeinConfig.CalculateCombinedOdds(veinResult)
		local oddsText = VeinConfig.FormatOdds(prob)
		local rarity = VeinConfig.GetRarityFromOdds(prob)

		-- Slot spin animation on the tile
		-- Find tile part by searching owned plot sections
		local tilePart = nil
		local ownedPlot = Workspace:FindFirstChild("Map") and Workspace.Map:FindFirstChild("Plots")
		if ownedPlot then
			for _, plot in ipairs(ownedPlot:GetChildren()) do
				local pg = plot:FindFirstChild("PlotGround")
				if not pg then continue end
				for _, section in ipairs(pg:GetChildren()) do
					if not section:IsA("Model") then continue end
					local tp = section:FindFirstChild(tostring(data.tileKey))
					if tp and tp:IsA("BasePart") then
						tilePart = tp
						break
					end
				end
				if tilePart then break end
			end
		end

		task.spawn(function()
			-- Billboard above tile showing spinning results
			local billboard = nil
			local nameLabel = nil
			local oddsLabel = nil
			if tilePart then
				billboard = Instance.new("BillboardGui")
				billboard.Name = "VeinRevealBillboard"
				billboard.Size = UDim2.fromOffset(300, 100)
				billboard.StudsOffset = Vector3.new(0, 8, 0)
				billboard.AlwaysOnTop = true
				billboard.Adornee = tilePart
				billboard.Parent = playerGui

				nameLabel = Instance.new("TextLabel")
				nameLabel.Size = UDim2.fromScale(1, 0.6)
				nameLabel.Position = UDim2.fromScale(0, 0)
				nameLabel.BackgroundTransparency = 1
				nameLabel.Font = Enum.Font.LuckiestGuy
				nameLabel.TextSize = 28
				nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
				nameLabel.TextStrokeTransparency = 0
				nameLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
				nameLabel.Text = ""
				nameLabel.Parent = billboard

				oddsLabel = Instance.new("TextLabel")
				oddsLabel.Size = UDim2.fromScale(1, 0.4)
				oddsLabel.Position = UDim2.fromScale(0, 0.6)
				oddsLabel.BackgroundTransparency = 1
				oddsLabel.Font = Enum.Font.LuckiestGuy
				oddsLabel.TextSize = 22
				oddsLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
				oddsLabel.TextStrokeTransparency = 0
				oddsLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
				oddsLabel.Text = ""
				oddsLabel.Parent = billboard
			end

			-- Spin through random combos for 3 seconds
			local spinDur = 3
			local spinT0 = os.clock()
			local spinRng = Random.new(os.clock() * 1000)
			local allStreams = VeinConfig.StreamOrder
			local allOils = VeinConfig.OilOrder
			local originalColor = tilePart and tilePart.Color or Color3.fromRGB(254, 224, 180)

			while true do
				local elapsed = os.clock() - spinT0
				if elapsed >= spinDur then break end
				-- Ease: start fast, slow down
				local progress = elapsed / spinDur
				local interval = 0.06 + 0.4 * (progress * progress * progress)
				-- Pick random combo to display
				local randStream = allStreams[spinRng:NextInteger(1, #allStreams)]
				local randOil = allOils[spinRng:NextInteger(1, #allOils)]
				local streamDef = VeinConfig.Streams[randStream]
				local oilDef = VeinConfig.OilTypes[randOil]

				if tilePart then
					tilePart.Color = oilDef.color
				end
				if nameLabel then
					nameLabel.Text = oilDef.displayName .. " " .. streamDef.name
					nameLabel.TextColor3 = streamDef.color
				end
				if oddsLabel then
					local fakeProbInverse = spinRng:NextInteger(2, 5000)
					oddsLabel.Text = "1/" .. tostring(fakeProbInverse)
				end

				task.wait(interval)
			end

			-- Land on the real result
			if tilePart then
				if veinResult.isDead then
					tilePart.Color = Color3.fromRGB(72, 50, 30)
					tilePart.Material = Enum.Material.Ground
				else
					local firstOil = VeinConfig.OilTypes[veinResult.veins[1].oilType]
					if firstOil then
						tilePart.Color = firstOil.color
					end
				end
			end
			if nameLabel then
				nameLabel.Text = displayName
				nameLabel.TextColor3 = rarity.color
				if rarity.name == "LEGENDARY" or rarity.name == "EPIC" then
					nameLabel.TextSize = 34
				end
			end
			if oddsLabel then
				oddsLabel.Text = oddsText .. " — " .. rarity.name
				oddsLabel.TextColor3 = rarity.color
			end

			-- Toast popup
			local toast = Instance.new("ScreenGui")
			toast.Name = "VeinToast"
			toast.IgnoreGuiInset = true
			toast.DisplayOrder = 100
			toast.Parent = playerGui

			local toastLabel = Instance.new("TextLabel")
			toastLabel.Size = UDim2.new(0.6, 0, 0, 60)
			toastLabel.Position = UDim2.new(0.2, 0, 0.15, 0)
			toastLabel.BackgroundTransparency = 0.3
			toastLabel.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
			toastLabel.Font = Enum.Font.LuckiestGuy
			toastLabel.TextSize = 30
			toastLabel.TextColor3 = rarity.color
			toastLabel.TextStrokeTransparency = 0
			toastLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
			toastLabel.Text = displayName .. "  " .. oddsText
			toastLabel.Parent = toast
			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(0, 12)
			corner.Parent = toastLabel

			-- Oil burst if not dead
			if not veinResult.isDead and data.hasOil then
				local veinCount = VeinConfig.VeinCounts[veinResult.veinCount]
				local count = veinCount and veinCount.count or 1
				for i, vein in ipairs(veinResult.veins) do
					local internalOil = VeinConfig.GetInternalOilName(vein.oilType)
					local sprayName = "OilSpray_" .. internalOil
					local sprayTemplate = ReplicatedStorage.Assets:FindFirstChild(sprayName)
					if sprayTemplate and tilePart then
						local spray = sprayTemplate:Clone()
						for _, d in ipairs(spray:GetDescendants()) do
							if d:IsA("BasePart") then d.Anchored = true; d.CanCollide = false end
						end
						local offset = Vector3.new((i - 1) * 2 - (count - 1), 0.5, 0)
						spray:PivotTo(CFrame.new(tilePart.Position + offset + Vector3.new(0, 0.3, 0)))
						spray.Parent = Workspace
						-- Burst: emit extra particles
						for _, d in ipairs(spray:GetDescendants()) do
							if d:IsA("ParticleEmitter") then
								local streamDef = VeinConfig.Streams[vein.streamType]
								local mult = streamDef and streamDef.particleMult or 1
								d:Emit(math.floor(100 * mult))
							end
						end
						Debris:AddItem(spray, 5) -- server spray takes over
					end
				end
			end

			-- Fade billboard + toast after 3s
			task.wait(3)
			if billboard then billboard:Destroy() end
			task.wait(1)
			if toast and toast.Parent then toast:Destroy() end
		end)

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
	-- Vein system: chunks reveal instantly with ground type color, no slot animation needed
	if typeof(data) ~= "table" or not data.chunkId then return end
	local sectionModel = nil
	if ownedPlot then
		local ground = ownedPlot:FindFirstChild("PlotGround")
		if ground then
			sectionModel = ground:FindFirstChild(data.chunkId)
		end
	end
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

-- FTUE modules live under `PlayerScripts.Client.UI` (Rojo: `src/client/UI`), i.e. `script.Parent.UI` — not `script.UI`.
task.defer(function()
	local uiRoot = (script.Parent and script.Parent:FindFirstChild("UI")) or getHudUiFolder()
	if not uiRoot then
		warn("[FTUE] Client UI folder missing — cannot load FtueDialogueController (expect script.Parent.UI)")
		return
	end
	local mod = uiRoot:FindFirstChild("FtueDialogueController")
	if not (mod and mod:IsA("ModuleScript")) then
		warn("[FTUE] FtueDialogueController ModuleScript not found under " .. uiRoot:GetFullName())
		return
	end
	local ok, FtueDialogueController = pcall(require, mod)
	if not ok then
		warn("[FTUE] FtueDialogueController require failed: " .. tostring(FtueDialogueController))
		return
	end
	local startDlg = (FtueDialogueController :: any).start
	if typeof(FtueDialogueController) == "table" and typeof(startDlg) == "function" then
		print("[FTUE] Starting FtueDialogueController")
		startDlg(player, playerGui, requestFtueAcknowledge, requestFtueSkip, ftueStateUpdate, oilActionResult)
	else
		warn("[FTUE] FtueDialogueController has no start()")
	end
end)

	task.defer(function()
		local uiRoot = (script.Parent and script.Parent:FindFirstChild("UI")) or getHudUiFolder()
		if not uiRoot then
			warn("[FTUE] Client UI folder missing — cannot load FtueUiPointers")
			return
		end
		local modPtr = uiRoot:FindFirstChild("FtueUiPointers")
		if not (modPtr and modPtr:IsA("ModuleScript")) then
			warn("[FTUE] FtueUiPointers ModuleScript not found under " .. uiRoot:GetFullName())
			return
		end
		local okP, FtueUiPointers = pcall(require, modPtr)
		if not okP then
			warn("[FTUE] FtueUiPointers require failed: " .. tostring(FtueUiPointers))
			return
		end
		if typeof(FtueUiPointers) == "table" and typeof((FtueUiPointers :: any).start) == "function" then
			(FtueUiPointers :: any).start(player, playerGui, ftueStateUpdate)
		else
			warn("[FTUE] FtueUiPointers has no start()")
		end
	end)

	task.defer(function()
		local uiRoot = (script.Parent and script.Parent:FindFirstChild("UI")) or getHudUiFolder()
		if not uiRoot then
			warn("[FTUE] Client UI folder missing — cannot load FtueTutorialTileHighlight")
			return
		end
		local mod = uiRoot:FindFirstChild("FtueTutorialTileHighlight")
	if not (mod and mod:IsA("ModuleScript")) then
		warn("[FTUE] FtueTutorialTileHighlight ModuleScript not found under " .. uiRoot:GetFullName())
		return
	end
	local ok, FtueTutorialTileHighlight = pcall(require, mod)
	if not ok then
		warn("[FTUE] FtueTutorialTileHighlight require failed: " .. tostring(FtueTutorialTileHighlight))
		return
	end
	local startHl = (FtueTutorialTileHighlight :: any).start
	if typeof(FtueTutorialTileHighlight) == "table" and typeof(startHl) == "function" then
		print("[FTUE] Starting FtueTutorialTileHighlight")
		startHl(player)
	else
		warn("[FTUE] FtueTutorialTileHighlight has no start()")
	end
end)

print("[Client] Chunked plot mode active.")

-- Play join game sound (plays after FTUE for first joiners, or immediately for returning players)
task.delay(1, function()
	playEventSFX("JoinGame", 0.6)
end)

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

-- =================== NUKE COUNTDOWN ===================
nukeCountdownEvent.OnClientEvent:Connect(function(data)
	if typeof(data) ~= "table" then return end
	local detonateAt = tonumber(data.detonateAt) or 0

	-- Play nuke SFX for ALL players immediately — audio is 12+ seconds long
	-- 0-2s: siren/buildup (nuke symbol shown, no countdown yet)
	-- 2s-12s: countdown plays over the audio
	-- 12s: detonation syncs with the audio explosion
	playEventSFX("TacNuke", 1.0)
	local launchedBy = tostring(data.launchedBy or "Unknown")

	task.spawn(function()
		-- Full-screen countdown overlay
		local screenGui = Instance.new("ScreenGui")
		screenGui.Name = "NukeCountdown"
		screenGui.DisplayOrder = 100
		screenGui.ResetOnSpawn = false
		screenGui.Parent = playerGui

		-- No dark overlay — keep the game visible during countdown

		-- Nuke symbol
		local symbol = Instance.new("TextLabel")
		symbol.Size = UDim2.fromOffset(120, 120)
		symbol.Position = UDim2.new(0.5, -60, 0.3, -60)
		symbol.BackgroundTransparency = 1
		symbol.Text = "\xe2\x98\xa2" -- ☢
		symbol.TextColor3 = Color3.fromRGB(255, 50, 50)
		symbol.TextSize = 80
		symbol.Font = Enum.Font.Merriweather
		symbol.Parent = screenGui

		-- Warning text
		local warning = Instance.new("TextLabel")
		warning.Size = UDim2.new(0.8, 0, 0, 40)
		warning.Position = UDim2.new(0.1, 0, 0.45, 0)
		warning.BackgroundTransparency = 1
		warning.Text = "NUKE INCOMING"
		warning.TextColor3 = Color3.fromRGB(255, 50, 50)
		warning.TextSize = 40
		warning.Font = Enum.Font.Merriweather
		warning.TextStrokeTransparency = 0
		warning.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
		warning.Parent = screenGui

		local subtext = Instance.new("TextLabel")
		subtext.Size = UDim2.new(0.8, 0, 0, 24)
		subtext.Position = UDim2.new(0.1, 0, 0.52, 0)
		subtext.BackgroundTransparency = 1
		subtext.Text = "ALL BOATS ON STRAIT AT RISK OF DESTRUCTION"
		subtext.TextColor3 = Color3.fromRGB(255, 200, 100)
		subtext.TextSize = 18
		subtext.Font = Enum.Font.Merriweather
		subtext.TextStrokeTransparency = 0.3
		subtext.Parent = screenGui

		local countdown = Instance.new("TextLabel")
		countdown.Size = UDim2.new(0.5, 0, 0, 80)
		countdown.Position = UDim2.new(0.25, 0, 0.6, 0)
		countdown.BackgroundTransparency = 1
		countdown.Text = ""
		countdown.TextColor3 = Color3.fromRGB(255, 255, 255)
		countdown.TextSize = 72
		countdown.Font = Enum.Font.Merriweather
		countdown.TextStrokeTransparency = 0
		countdown.Visible = false
		countdown.Text = ""
		countdown.Parent = screenGui

		-- First 2 seconds: just nuke symbol + audio playing, no countdown visible
		task.delay(2, function()
			if countdown.Parent then countdown.Visible = true end
		end)

		-- Flash warning text red/white
		task.spawn(function()
			while screenGui.Parent do
				warning.TextColor3 = Color3.fromRGB(255, 50, 50)
				task.wait(0.3)
				if not screenGui.Parent then break end
				warning.TextColor3 = Color3.fromRGB(255, 255, 255)
				task.wait(0.3)
			end
		end)

		-- Countdown timer
		while workspace:GetServerTimeNow() < detonateAt do
			local remaining = math.max(0, math.ceil(detonateAt - workspace:GetServerTimeNow()))
			countdown.Text = tostring(remaining)
			task.wait(0.1)
		end

		screenGui:Destroy()
	end)
end)

-- =================== NUKE DETONATION ===================
nukeDetonateEvent.OnClientEvent:Connect(function(data)
	if typeof(data) ~= "table" then return end

	-- IMMEDIATELY clone the player's head BEFORE the server dismembers the character
	local nukeHeadClone = nil
	local nukeHeadStartPos = nil
	local localChar = player.Character
	local origHead = localChar and localChar:FindFirstChild("Head")
	if origHead and origHead:IsA("BasePart") then
		nukeHeadClone = origHead:Clone()
		nukeHeadClone.Name = "NukeDeathHead"
		nukeHeadClone.Anchored = false
		nukeHeadClone.CanCollide = false
		nukeHeadClone.CanQuery = false
		nukeHeadClone.CanTouch = false
		nukeHeadStartPos = origHead.Position
	end

	task.spawn(function()
		local Debris = game:GetService("Debris")

		-- WHITE FLASH: full screen overlay
		local flashGui = Instance.new("ScreenGui")
		flashGui.Name = "NukeFlash"
		flashGui.DisplayOrder = 200
		flashGui.Parent = playerGui
		local flash = Instance.new("Frame")
		flash.Size = UDim2.fromScale(1, 1)
		flash.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		flash.BackgroundTransparency = 0
		flash.BorderSizePixel = 0
		flash.Parent = flashGui

		-- Fade out the flash over 1.5 seconds
		task.spawn(function()
			local dur = 1.5
			local t0 = os.clock()
			while os.clock() - t0 < dur do
				local a = (os.clock() - t0) / dur
				flash.BackgroundTransparency = a
				task.wait()
			end
			flashGui:Destroy()
		end)

		-- MUSHROOM CLOUD: use the pre-positioned and pre-scaled template from Assets
		local assets = ReplicatedStorage:FindFirstChild("Assets")
		local cloudTemplate = assets and assets:FindFirstChild("MushroomCloud")
		if cloudTemplate then
			local cloud = cloudTemplate:Clone()
			for _, d in ipairs(cloud:GetDescendants()) do
				if d:IsA("BasePart") then
					d.Anchored = true
					d.CanCollide = false
				end
			end
			-- Template already has correct position and scale baked in
			if cloud:IsA("Model") then
				cloud:PivotTo(cloud:GetPivot())
			end
			cloud.Parent = workspace
			Debris:AddItem(cloud, 8)

			-- FADE OUT: cloud appears instantly, fades out before Debris kills it
			local cloudParts = {}
			local cloudOrigTrans = {}
			for _, p in ipairs(cloud:GetDescendants()) do
				if p:IsA("BasePart") then
					table.insert(cloudParts, p)
					cloudOrigTrans[p] = p.Transparency
				end
			end
			task.spawn(function()
				task.wait(5) -- visible for 5 seconds, then fade out over 3
				local fadeOutDur = 4
				local fo0 = os.clock()
				while os.clock() - fo0 < fadeOutDur do
					local a = math.min((os.clock() - fo0) / fadeOutDur, 1)
					for _, p in ipairs(cloudParts) do
						if p.Parent then
							local orig = cloudOrigTrans[p] or 0
							p.Transparency = orig + a * (1 - orig)
						end
					end
					task.wait()
				end
			end)
		end

		-- SCREEN SHAKE: massive
		local camera = workspace.CurrentCamera
		if camera then
			task.spawn(function()
				local intensity = 8
				local duration = 2
				local elapsed = 0
				local shakeRng = Random.new()
				while elapsed < duration do
					local dt = task.wait()
					elapsed += dt
					local fade = 1 - (elapsed / duration)
					camera.CFrame *= CFrame.new(
						shakeRng:NextNumber(-intensity, intensity) * fade,
						shakeRng:NextNumber(-intensity, intensity) * fade,
						0
					)
				end
			end)
		end

		-- BOATS FLY OFF: find all active shipment boats and fling them
		local shipments = data.shipments
		if typeof(shipments) == "table" then
			for _, info in ipairs(shipments) do
				task.spawn(function()
					local boat = nil
					for _, d in ipairs(workspace:GetDescendants()) do
						if d:IsA("Model") and d.Name == "ActiveShipmentBoat" and d:GetAttribute("ShipmentId") == info.shipmentId then
							boat = d
							break
						end
					end
					if not boat then return end

					local root = boat.PrimaryPart or boat:FindFirstChildWhichIsA("BasePart")
					if not root then return end

					-- Calculate fly-off direction (away from strait center)
					local straitCenter = Vector3.new(-72, 3, 253)
					local flyDir = (root.Position - straitCenter)
					flyDir = Vector3.new(flyDir.X, 0, flyDir.Z)
					if flyDir.Magnitude < 1 then flyDir = Vector3.new(1, 0, 0) end
					flyDir = flyDir.Unit

					local startPos = root.Position
					local endPos = startPos + flyDir * 1500 + Vector3.new(0, -200, 0)
					local startCF = boat:GetPivot()

					-- Fly the boat off with arc
					local flyDur = 2.5
					local arcH = 200
					local ft0 = os.clock()
					while os.clock() - ft0 < flyDur do
						local a = math.min((os.clock() - ft0) / flyDur, 1)
						local e = a * a * (3 - 2 * a)
						local pos = startPos:Lerp(endPos, e)
						pos = pos + Vector3.new(0, arcH * math.sin(e * math.pi), 0)
						-- Add spin
						local spin = CFrame.Angles(e * 3, e * 5, e * 2)
						if boat:IsA("Model") then
							boat:PivotTo(CFrame.new(pos) * spin)
						end
						if a >= 1 then break end
						task.wait()
					end

					Debris:AddItem(boat, 1)
				end)
			end
		end

		-- NUKE DEATH CAM: two cases
		-- Case 1: player on land → do nothing, free cam sees explosion naturally
		-- Case 2: player on boat → head flies away from nuke, camera follows head
		local onBoat = false
		local localChar = player.Character
		local localHRP = localChar and localChar:FindFirstChild("HumanoidRootPart")
		if localHRP and localHRP:IsA("BasePart") then
			for _, d in ipairs(workspace:GetDescendants()) do
				if d:IsA("Model") and d.Name == "ActiveShipmentBoat" then
					local root = d.PrimaryPart or d:FindFirstChildWhichIsA("BasePart")
					if root and (root.Position - localHRP.Position).Magnitude < 80 then
						onBoat = true
						break
					end
				end
			end
		end

		if onBoat and nukeHeadClone then
			local camera = workspace.CurrentCamera
			if camera then
				task.spawn(function()
					-- Hide original character
					if localChar then
						for _, part in ipairs(localChar:GetDescendants()) do
							if part:IsA("BasePart") then part.Transparency = 1 end
						end
					end

					local cloudCenter = Vector3.new(25.9, 789.8, 179.9)
					local headStartPos = nukeHeadStartPos or localHRP.Position

					-- Direction AWAY from the nuke
					local awayDir = Vector3.new(headStartPos.X - cloudCenter.X, 0, headStartPos.Z - cloudCenter.Z)
					if awayDir.Magnitude < 1 then awayDir = Vector3.new(100, 0, 0) end
					awayDir = awayDir.Unit

					-- Head path: starts at player, SOARS way above the mushroom cloud
					-- Cloud is at Y=789, top at ~Y=1600. Head needs to go ABOVE that.
					local headStart = headStartPos + Vector3.new(0, 20, 0)
					local headEnd = headStart + awayDir * 1500 + Vector3.new(0, 2000, 0)

					-- Place head — BIG, ANCHORED, moved by CFrame only
					nukeHeadClone.Size = nukeHeadClone.Size * 4 -- 4x bigger
					nukeHeadClone.Anchored = true
					nukeHeadClone.CanCollide = false
					nukeHeadClone.CFrame = CFrame.new(headStart)
					nukeHeadClone.Parent = workspace
					-- Add glow so head is always visible
					local glow = Instance.new("PointLight")
					glow.Brightness = 3
					glow.Range = 30
					glow.Color = Color3.fromRGB(255, 200, 150)
					glow.Parent = nukeHeadClone
					Debris:AddItem(nukeHeadClone, 12)

					-- Lock camera
					camera.CameraType = Enum.CameraType.Scriptable
					local flyDur = 7
					local nukeCamDone = false

					local respawnConn
					respawnConn = player.CharacterAdded:Connect(function()
						nukeCamDone = true
						camera.CameraType = Enum.CameraType.Custom
						if respawnConn then respawnConn:Disconnect() end
					end)

					local tt0 = os.clock()
					while os.clock() - tt0 < flyDur and not nukeCamDone do
						local a = math.min((os.clock() - tt0) / flyDur, 1)
						local e = a * a * (3 - 2 * a)

						-- Move head along path (anchored, CFrame only)
						local headPos = headStart:Lerp(headEnd, e)
						local spin = CFrame.Angles(a * 12, a * 8, a * 6)
						nukeHeadClone.CFrame = CFrame.new(headPos) * spin

						-- Camera BEHIND the head, LOOKING AT the head
						-- Far enough back to see head + nuke behind it
						local camPos = headPos + awayDir * 25 + Vector3.new(0, 8, 0)
						camera.CFrame = CFrame.lookAt(camPos, headPos)

						task.wait()
					end

					if not nukeCamDone then
						camera.CameraType = Enum.CameraType.Custom
					end
					if respawnConn then respawnConn:Disconnect() end
				end)
			end
		end

		task.delay(6, function()
			setStatus("NUCLEAR STRIKE! All boats in the strait destroyed!", false)
			playEventSFX("ShipDestroyed")
		end)
	end)
end)

-- =================== AIRSTRIKE ===================
airStrikeEvent.OnClientEvent:Connect(function(data)
	if typeof(data) ~= "table" then return end

	task.spawn(function()
		local Debris = game:GetService("Debris")
		local outcome = tostring(data.outcome or "miss")
		local victimName = tostring(data.victimName or "Unknown")
		local isVictim = data.victimUserId == player.UserId

		-- Parse positions
		local jetStart = data.jetStart and Vector3.new(data.jetStart.x, data.jetStart.y, data.jetStart.z)
		local jetEnd = data.jetEnd and Vector3.new(data.jetEnd.x, data.jetEnd.y, data.jetEnd.z)
		local targetPos = data.targetPosition and Vector3.new(data.targetPosition.x, data.targetPosition.y, data.targetPosition.z)
		if not (jetStart and jetEnd and targetPos) then return end

		local jetSpeed = tonumber(data.jetSpeed) or 700
		local bombFallDur = tonumber(data.bombFallDuration) or 2

		-- Play airstrike SFX for affected player
		if isVictim then playEventSFX("Airstrike") end

		-- WARNING SCREEN: "AIRSTRIKE INCOMING" for 2 seconds before jet arrives
		local warningGui = Instance.new("ScreenGui")
		warningGui.Name = "AirstrikeWarning"
		warningGui.DisplayOrder = 90
		warningGui.Parent = playerGui

		local warningLabel = Instance.new("TextLabel")
		warningLabel.Size = UDim2.new(0.8, 0, 0, 50)
		warningLabel.Position = UDim2.new(0.1, 0, 0.3, 0)
		warningLabel.BackgroundTransparency = 1
		warningLabel.Text = "AIRSTRIKE INCOMING"
		warningLabel.TextColor3 = Color3.fromRGB(255, 80, 50)
		warningLabel.Font = Enum.Font.Merriweather
		warningLabel.TextSize = 42
		warningLabel.TextStrokeTransparency = 0
		warningLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
		warningLabel.Parent = warningGui

		local targetLabel = Instance.new("TextLabel")
		targetLabel.Size = UDim2.new(0.8, 0, 0, 30)
		targetLabel.Position = UDim2.new(0.1, 0, 0.37, 0)
		targetLabel.BackgroundTransparency = 1
		targetLabel.Text = isVictim and "YOUR SHIP IS THE TARGET!" or string.format("Target: %s", victimName)
		targetLabel.TextColor3 = isVictim and Color3.fromRGB(255, 50, 50) or Color3.fromRGB(255, 200, 100)
		targetLabel.Font = Enum.Font.Merriweather
		targetLabel.TextSize = 20
		targetLabel.TextStrokeTransparency = 0.3
		targetLabel.Parent = warningGui

		-- Flash the warning text
		task.spawn(function()
			while warningGui.Parent do
				warningLabel.TextColor3 = Color3.fromRGB(255, 80, 50)
				task.wait(0.25)
				if not warningGui.Parent then break end
				warningLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
				task.wait(0.25)
			end
		end)

		-- Wait 2 seconds for warning, then remove and start jet
		task.wait(2)
		warningGui:Destroy()

		-- Slow jet speed so player can see it approach (halved)
		jetSpeed = jetSpeed * 0.5

		-- Clone jet
		local assets = ReplicatedStorage:FindFirstChild("Assets")
		local jetTemplate = assets and assets:FindFirstChild("Jet")
		local jet
		if jetTemplate then
			jet = jetTemplate:Clone()
		else
			jet = Instance.new("Part")
			jet.Name = "Jet"
			jet.Size = Vector3.new(4, 2, 10)
			jet.Material = Enum.Material.Metal
			jet.Color = Color3.fromRGB(80, 80, 80)
		end

		if jet:IsA("Model") then
			for _, d in ipairs(jet:GetDescendants()) do
				if d:IsA("BasePart") then d.Anchored = true; d.CanCollide = false end
			end
			jet:PivotTo(CFrame.lookAt(jetStart, jetEnd))
		elseif jet:IsA("BasePart") then
			jet.Anchored = true; jet.CanCollide = false
			jet.CFrame = CFrame.lookAt(jetStart, jetEnd)
		end
		jet.Parent = workspace

		-- Attach jet engine sound (same as ambient flyover jets)
		local jetSoundHost = jet:IsA("Model") and (jet.PrimaryPart or jet:FindFirstChildWhichIsA("BasePart")) or jet
		if jetSoundHost and jetSoundHost:IsA("BasePart") then
			local snd = Instance.new("Sound")
			snd.Name = "JetEngineFlyover"
			snd.SoundId = "rbxassetid://131368895404825"
			snd.Volume = 0.5
			snd.Looped = true
			snd.RollOffMode = Enum.RollOffMode.Inverse
			snd.RollOffMinDistance = 360
			snd.RollOffMaxDistance = 3000
			snd.EmitterSize = 140
			snd.Parent = jetSoundHost
			snd:Play()
		end

		-- Fly jet from start to end
		local distance = (jetEnd - jetStart).Magnitude
		local flightDur = distance / jetSpeed
		local bombDropped = false
		local bombDropAlpha = 0.5 -- drop at midpoint

		local ft0 = os.clock()
		while true do
			local a = math.min((os.clock() - ft0) / flightDur, 1)
			local pos = jetStart:Lerp(jetEnd, a)
			local cf = CFrame.lookAt(pos, jetEnd)
			if jet:IsA("Model") then jet:PivotTo(cf) else jet.CFrame = cf end

			-- Drop bomb barrage at midpoint
			if not bombDropped and a >= bombDropAlpha then
				bombDropped = true
				local totalBombs = tonumber(data.bombCount) or 1
				for bombIdx = 1, totalBombs do
				task.spawn(function()
					-- Stagger each bomb slightly
					if bombIdx > 1 then task.wait((bombIdx - 1) * 0.15) end
					-- Create bomb
					local bombTemplate = assets and assets:FindFirstChild("Bomb")
					local bomb
					if bombTemplate then
						bomb = bombTemplate:Clone()
					else
						bomb = Instance.new("Part")
						bomb.Size = Vector3.new(1, 1, 3)
						bomb.Material = Enum.Material.Metal
						bomb.Color = Color3.fromRGB(40, 40, 40)
					end
					if bomb:IsA("BasePart") then
						bomb.Anchored = true; bomb.CanCollide = false
					end
					bomb.Parent = workspace

					-- Each bomb targets the boat's LIVE position
					local bombRng = Random.new(os.clock() * 1000 + bombIdx)
					local jetPos = if jet:IsA("Model") then jet:GetPivot().Position else jet.Position
					local bombStart = jetPos + Vector3.new(bombRng:NextNumber(-5, 5), 0, bombRng:NextNumber(-5, 5))
					-- Find victim boat's CURRENT position
					local liveTarget = targetPos
					local vBoat = nil
					local vShipId = data.victimShipmentId
					if vShipId then
						for _, inst in ipairs(workspace:GetDescendants()) do
							if inst:IsA("Model") and inst.Name == "ActiveShipmentBoat" and inst:GetAttribute("ShipmentId") == vShipId then
								vBoat = inst
								break
							end
						end
					end
					if vBoat then
						local vRoot = vBoat.PrimaryPart or vBoat:FindFirstChildWhichIsA("BasePart")
						if vRoot then liveTarget = vRoot.Position end
					end
					local bombEnd = liveTarget + Vector3.new(bombRng:NextNumber(-15, 15), 0, bombRng:NextNumber(-15, 15))
					if outcome == "miss" then
						bombEnd = liveTarget + Vector3.new(bombRng:NextNumber(-40, 40), 0, bombRng:NextNumber(-40, 40))
					end

					-- Bomb falls
					local bt0 = os.clock()
					while true do
						local ba = math.min((os.clock() - bt0) / bombFallDur, 1)
						local be = ba * ba -- accelerating fall
						local bpos = bombStart:Lerp(bombEnd, be)
						if bomb:IsA("BasePart") then
							bomb.CFrame = CFrame.lookAt(bpos, bombEnd)
						elseif bomb:IsA("Model") then
							bomb:PivotTo(CFrame.lookAt(bpos, bombEnd))
						end
						if ba >= 1 then break end
						task.wait()
					end

					-- Impact
					bomb:Destroy()

					if outcome == "hit" then
						-- Explode the boat into pieces
						local victimBoat = nil
						local victimShipId = data.victimShipmentId
						if victimShipId then
							for _, inst in ipairs(workspace:GetDescendants()) do
								if inst:IsA("Model") and inst.Name == "ActiveShipmentBoat" and inst:GetAttribute("ShipmentId") == victimShipId then
									victimBoat = inst
									break
								end
							end
						end
						if victimBoat then
							task.delay(0.2, function()
								StraitWaypointWorldFx.ExplodeBoatIntoPieces(victimBoat, bombEnd)
							end)
						end

						-- Big explosion
						local explosion = Instance.new("Part")
						explosion.Size = Vector3.new(1, 1, 1)
						explosion.Position = bombEnd
						explosion.Anchored = true; explosion.CanCollide = false
						explosion.Transparency = 1
						explosion.Parent = workspace

						-- Flash
						local flash = Instance.new("PointLight")
						flash.Brightness = 12; flash.Range = 140
						flash.Color = Color3.fromRGB(255, 200, 80)
						flash.Parent = explosion
						task.delay(0.15, function() if flash.Parent then flash.Brightness = 5 end end)
						task.delay(0.5, function() if flash.Parent then flash:Destroy() end end)

						-- Fireball
						local fb = Instance.new("ParticleEmitter")
						fb.Rate = 0; fb.Lifetime = NumberRange.new(0.5, 1.5)
						fb.Speed = NumberRange.new(25, 60); fb.SpreadAngle = Vector2.new(180, 180)
						fb.Size = NumberSequence.new({NumberSequenceKeypoint.new(0, 10), NumberSequenceKeypoint.new(0.3, 18), NumberSequenceKeypoint.new(1, 0)})
						fb.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.5, 0.3), NumberSequenceKeypoint.new(1, 1)})
						fb.Color = ColorSequence.new({ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 200)), ColorSequenceKeypoint.new(0.3, Color3.fromRGB(255, 150, 40)), ColorSequenceKeypoint.new(1, Color3.fromRGB(60, 20, 5))})
						fb.LightEmission = 1; fb.Parent = explosion
						fb:Emit(80)

						-- Smoke
						local smoke = Instance.new("ParticleEmitter")
						smoke.Rate = 0; smoke.Lifetime = NumberRange.new(3, 6)
						smoke.Speed = NumberRange.new(8, 20); smoke.SpreadAngle = Vector2.new(180, 180)
						smoke.Size = NumberSequence.new({NumberSequenceKeypoint.new(0, 5), NumberSequenceKeypoint.new(0.5, 20), NumberSequenceKeypoint.new(1, 30)})
						smoke.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(0.3, 0.3), NumberSequenceKeypoint.new(1, 1)})
						smoke.Color = ColorSequence.new(Color3.fromRGB(25, 25, 25))
						smoke.Parent = explosion; smoke:Emit(50)

						-- Screen shake
						local camera = workspace.CurrentCamera
						if camera then
							task.spawn(function()
								local shakeRng = Random.new()
								local elapsed = 0
								while elapsed < 1 do
									local dt = task.wait()
									elapsed += dt
									local fade = 1 - elapsed
									camera.CFrame *= CFrame.new(shakeRng:NextNumber(-4, 4) * fade, shakeRng:NextNumber(-4, 4) * fade, 0)
								end
							end)
						end

						Debris:AddItem(explosion, 10)
					else
						-- Water splash for miss
						local splash = Instance.new("Part")
						splash.Size = Vector3.new(1, 1, 1); splash.Position = bombEnd
						splash.Anchored = true; splash.CanCollide = false; splash.Transparency = 1
						splash.Parent = workspace
						local water = Instance.new("ParticleEmitter")
						water.Rate = 0; water.Lifetime = NumberRange.new(0.8, 2)
						water.Speed = NumberRange.new(25, 50); water.SpreadAngle = Vector2.new(50, 50)
						water.Size = NumberSequence.new({NumberSequenceKeypoint.new(0, 2), NumberSequenceKeypoint.new(0.5, 5), NumberSequenceKeypoint.new(1, 0)})
						water.Color = ColorSequence.new(Color3.fromRGB(100, 180, 255))
						water.Parent = splash; water:Emit(50)
						Debris:AddItem(splash, 4)
					end
				end)
				end -- for bombIdx
			end

			if a >= 1 then break end
			task.wait()
		end

		Debris:AddItem(jet, 2)

		-- Status message
		if isVictim then
			if outcome == "hit" then
				task.delay(5, function()
					setStatus("YOUR SHIP WAS BOMBED! Cargo destroyed!", false)
					playEventSFX("ShipDestroyed")
				end)

				-- DEATH CAM: head flies away from explosion, camera follows
				local localChar = player.Character
				local origHead = localChar and localChar:FindFirstChild("Head")
				if origHead and origHead:IsA("BasePart") then
					local airCam = workspace.CurrentCamera
					if airCam then
						task.spawn(function()
							-- Clone head before server dismembers
							local flyHead = origHead:Clone()
							flyHead.Name = "AirstrikeDeathHead"
							flyHead.Size = flyHead.Size * 3
							flyHead.Anchored = true
							flyHead.CanCollide = false
							flyHead.CFrame = CFrame.new(origHead.Position)
							flyHead.Parent = workspace

							local glow = Instance.new("PointLight")
							glow.Brightness = 2
							glow.Range = 20
							glow.Parent = flyHead

							-- Hide character
							if localChar then
								for _, p in ipairs(localChar:GetDescendants()) do
									if p:IsA("BasePart") then p.Transparency = 1 end
								end
							end

							-- Fly head away from bomb impact
							local impactPos = targetPos
							local headStartP = origHead.Position + Vector3.new(0, 10, 0)
							local awayD = Vector3.new(headStartP.X - impactPos.X, 0, headStartP.Z - impactPos.Z)
							if awayD.Magnitude < 1 then awayD = Vector3.new(50, 0, 0) end
							awayD = awayD.Unit
							local headEndP = headStartP + awayD * 150 + Vector3.new(0, 80, 0)

							airCam.CameraType = Enum.CameraType.Scriptable
							local camDone = false
							local rConn
							rConn = player.CharacterAdded:Connect(function()
								camDone = true
								airCam.CameraType = Enum.CameraType.Custom
								if rConn then rConn:Disconnect() end
							end)

							local at0 = os.clock()
							local aDur = 2
							while os.clock() - at0 < aDur and not camDone do
								local aa = math.min((os.clock() - at0) / aDur, 1)
								local ae = aa * aa * (3 - 2 * aa)
								local hPos = headStartP:Lerp(headEndP, ae)
								local spin = CFrame.Angles(aa * 10, aa * 7, aa * 5)
								flyHead.CFrame = CFrame.new(hPos) * spin
								local cPos = hPos + awayD * 20 + Vector3.new(0, 5, 0)
								airCam.CFrame = CFrame.lookAt(cPos, hPos)
								task.wait()
							end

							if not camDone then
								airCam.CameraType = Enum.CameraType.Custom
							end
							if rConn then rConn:Disconnect() end
							Debris:AddItem(flyHead, 1)
						end)
					end
				end
			else
				setStatus("Airstrike missed your ship!", true)
			end
		else
			if outcome == "hit" then
				setStatus(string.format("Airstrike hit %s's ship!", victimName), true)
			else
				setStatus(string.format("Airstrike missed %s's ship.", victimName), true)
			end
		end
	end)
end)

-- =================== ARMY GENERAL PANEL UI ===================
-- Army General dialogue — same visual style as Oilman (LuckiestGuy blocky text)
armyGeneralOpenEvent.OnClientEvent:Connect(function(data)
	if typeof(data) ~= "table" then return end

	local existing = playerGui:FindFirstChild("ArmyGeneralGui")
	if existing then existing:Destroy() end

	local airstrikeCost = tonumber(data.airstrikeCost) or 10000
	local nukeCooldownRemaining = tonumber(data.nukeCooldownRemaining) or 0

	local COLOR_IDLE = Color3.fromRGB(255, 255, 255)
	local COLOR_HOVER = Color3.fromRGB(255, 205, 80)

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "ArmyGeneralGui"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 60
	screenGui.Parent = playerGui

	-- Auto-close when walking away
	local generalModel = Workspace:FindFirstChild("Army General", true)
	local autoCloseConn
	autoCloseConn = RunService.Heartbeat:Connect(function()
		if not screenGui.Parent then
			if autoCloseConn then autoCloseConn:Disconnect() end
			return
		end
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if hrp and generalModel then
			if (hrp.Position - generalModel:GetPivot().Position).Magnitude > 12 then
				screenGui:Destroy()
				if autoCloseConn then autoCloseConn:Disconnect() end
			end
		end
	end)

	-- Root frame — center-right like Oilman
	local root = Instance.new("Frame")
	root.Name = "Root"
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.Active = false
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Position = UDim2.fromScale(0.68, 0.55)
	root.Size = UDim2.fromOffset(500, 320)
	root.Parent = screenGui

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = root

	local function blockyLine(name, text, order, isButton)
		local obj
		if isButton then
			obj = Instance.new("TextButton")
			obj.AutoButtonColor = false
			obj.Active = true
			obj.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
			obj.BackgroundTransparency = 0.99
			obj.MouseEnter:Connect(function()
				obj.TextColor3 = COLOR_HOVER
				obj.BackgroundTransparency = 0.35
			end)
			obj.MouseLeave:Connect(function()
				obj.TextColor3 = COLOR_IDLE
				obj.BackgroundTransparency = 0.99
			end)
			local c = Instance.new("UICorner")
			c.CornerRadius = UDim.new(0, 6)
			c.Parent = obj
		else
			obj = Instance.new("TextLabel")
			obj.BackgroundTransparency = 1
		end
		obj.Name = name
		obj.Text = text
		obj.Size = UDim2.new(1, 0, 0, 42)
		obj.LayoutOrder = order
		obj.BorderSizePixel = 0
		obj.Font = Enum.Font.LuckiestGuy
		obj.TextSize = 34
		obj.TextColor3 = COLOR_IDLE
		obj.TextStrokeTransparency = 0
		obj.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
		obj.TextXAlignment = Enum.TextXAlignment.Left
		obj.TextYAlignment = Enum.TextYAlignment.Center
		return obj
	end

	-- Header
	local header = blockyLine("Header", "Army General:", 1, false)
	header.Size = UDim2.new(1, 0, 0, 50)
	header.TextSize = 44
	header.Parent = root

	-- Launch Nuke
	local nukeText = "Launch Nuke"
	if nukeCooldownRemaining > 0 then
		nukeText = string.format("Nuke (cooldown %ds)", math.ceil(nukeCooldownRemaining))
	end
	local nukeBtn = blockyLine("NukeButton", nukeText, 2, true)
	nukeBtn.Parent = root

	-- Call Airstrike
	local airBtn = blockyLine("AirstrikeButton", string.format("Call Airstrike ($%d)", airstrikeCost), 3, true)
	airBtn.Parent = root

	-- Back
	local backBtn = blockyLine("BackButton", "back", 4, true)
	backBtn.TextSize = 28
	backBtn.TextColor3 = Color3.fromRGB(210, 210, 210)
	backBtn.MouseLeave:Connect(function()
		backBtn.TextColor3 = Color3.fromRGB(210, 210, 210)
	end)
	backBtn.Parent = root

	-- Close on back
	backBtn.MouseButton1Click:Connect(function()
		screenGui:Destroy()
	end)

	-- Nuke click
	nukeBtn.MouseButton1Click:Connect(function()
		requestArmyGeneralAction:FireServer({ action = "nuke" })
		screenGui:Destroy()
	end)

	-- Airstrike click — show target list as additional blocky lines
	airBtn.MouseButton1Click:Connect(function()
		-- Remove existing target buttons
		for _, c in ipairs(root:GetChildren()) do
			if c.Name:find("Target_") then c:Destroy() end
		end

		-- Fetch targets
		local result = requestArmyGeneralTargets:InvokeServer()
		if typeof(result) ~= "table" or typeof(result.targets) ~= "table" then return end

		-- Replace the options with target list
		header.Text = "Pick Target:"
		nukeBtn.Visible = false
		airBtn.Visible = false

		local order = 5
		for _, target in ipairs(result.targets) do
			local label = target.displayName
			if not target.hasShipment then
				label = label .. " (no ship)"
			end
			local tBtn = blockyLine("Target_" .. tostring(target.userId), label, order, true)
			tBtn.TextSize = 28
			if not target.hasShipment then
				tBtn.TextColor3 = Color3.fromRGB(100, 100, 100)
			end
			tBtn.Parent = root
			order += 1

			if target.hasShipment then
				tBtn.MouseButton1Click:Connect(function()
					requestArmyGeneralAction:FireServer({ action = "airstrike", victimUserId = target.userId })
					screenGui:Destroy()
				end)
			end
		end

		if #result.targets == 0 then
			local noTargets = blockyLine("NoTargets", "No ships on the strait", 5, false)
			noTargets.TextSize = 28
			noTargets.TextColor3 = Color3.fromRGB(180, 80, 80)
			noTargets.Parent = root
		end

		-- Back returns to main menu
		backBtn.MouseButton1Click:Connect(function()
			screenGui:Destroy()
		end)
	end)
end)

-- Army General result messages
armyGeneralResultEvent.OnClientEvent:Connect(function(data)
	if typeof(data) ~= "table" then return end
	setStatus(tostring(data.message or "?"), data.ok == true)
end)
