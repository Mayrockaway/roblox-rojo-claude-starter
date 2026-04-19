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
local FtueHudInsetSync = require(resolveClientModule(script, "FtueHudInsetSync"))
FtueHudInsetSync.start(playerGui)
local StrategicStrikeClient = require(resolveClientModule(script, "StrategicStrikeClient"))
local StraitMarketHudClient = require(resolveClientModule(script, "StraitMarketHudClient"))
local ShipmentVisualClient = require(resolveClientModule(script, "ShipmentVisualClient"))
local PirateHireClient = require(resolveClientModule(script, "PirateHireClient"))
local OilSnapshotClient = require(resolveClientModule(script, "OilSnapshotClient"))
local ClientAudioPreferences = require(resolveClientModule(script, "ClientAudioPreferences"))
ClientAudioPreferences.init()
local ClientPlotGrid = require(resolveClientModule(script, "ClientPlotGrid"))
local DrillAnimationClient = require(resolveClientModule(script, "DrillAnimationClient"))
local DrillReplicationClient = require(resolveClientModule(script, "DrillReplicationClient"))
local PlacementClient = require(resolveClientModule(script, "PlacementClient"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
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

local getClientRemotes = require(resolveClientModule(script, "GetClientRemotes")) :: () -> any
local Remotes = getClientRemotes()

local requestOilSnapshot = Remotes.requestOilSnapshot :: RemoteFunction
local requestPlaceDrill = Remotes.requestPlaceDrill :: RemoteEvent
local requestStartDrill = Remotes.requestStartDrill :: RemoteEvent
local requestPlacePump = Remotes.requestPlacePump :: RemoteEvent
local drillProgressUpdate = Remotes.drillProgressUpdate :: RemoteEvent
local requestProspect = Remotes.requestProspect :: RemoteEvent
local prospectProgressUpdate = Remotes.prospectProgressUpdate :: RemoteEvent
local requestHammerDestroy = Remotes.requestHammerDestroy :: RemoteEvent
local requestRemoveDrill = Remotes.requestRemoveDrill :: RemoteEvent
local requestBuyChunk = Remotes.requestBuyChunk :: RemoteEvent
local requestPlacePipe = Remotes.requestPlacePipe :: RemoteEvent
local requestRemovePipe = Remotes.requestRemovePipe :: RemoteEvent
local requestPickupBarrel = Remotes.requestPickupBarrel :: RemoteEvent
local requestTeleportToShip = Remotes.requestTeleportToShip :: RemoteEvent
local requestTeleportHome = Remotes.requestTeleportHome :: RemoteEvent
local requestUpgradeWarehouse = Remotes.requestUpgradeWarehouse :: RemoteEvent
local requestSellAllWarehouse = Remotes.requestSellAllWarehouse :: RemoteEvent
local requestTeleportToWarehouse = Remotes.requestTeleportToWarehouse :: RemoteEvent
local warehouseStateUpdate = Remotes.warehouseStateUpdate :: RemoteEvent
local requestWarehouseSnapshot = Remotes.requestWarehouseSnapshot :: RemoteFunction
-- RequestClearObstacle remote no longer bound (obstacle system removed)
local biomeRevealEvent = Remotes.biomeRevealEvent :: RemoteEvent
local requestRevealTile = Remotes.requestRevealTile :: RemoteEvent
local VeinCrateOpener = nil
do
	local ok, result = pcall(function()
		return require(script:WaitForChild("UI"):WaitForChild("VeinCrateOpener"))
	end)
	if ok then
		VeinCrateOpener = result
	else
		warn("[Client] VeinCrateOpener failed to load: " .. tostring(result))
	end
end
local requestDispatchShipment = Remotes.requestDispatchShipment :: RemoteEvent
local oilStateUpdate = Remotes.oilStateUpdate :: RemoteEvent
local oilActionResult = Remotes.oilActionResult :: RemoteEvent
local requestFtueAcknowledge = Remotes.requestFtueAcknowledge :: RemoteEvent
local requestFtueSkip = Remotes.requestFtueSkip :: RemoteEvent
local ftueStateUpdate = Remotes.ftueStateUpdate :: RemoteEvent
local shipmentVisualEvent = Remotes.shipmentVisualEvent :: RemoteEvent
local requestDevSetStraitBracket = Remotes.requestDevSetStraitBracket :: RemoteEvent
local globalStateUpdate = Remotes.globalStateUpdate :: RemoteEvent
local fighterFlyoverEvent = Remotes.fighterFlyoverEvent :: RemoteEvent
local requestPirateHireTargets = Remotes.requestPirateHireTargets :: RemoteFunction
local requestPirateHireAction = Remotes.requestPirateHireAction :: RemoteEvent
local pirateHireOpenEvent = Remotes.pirateHireOpenEvent :: RemoteEvent
local pirateHireResultEvent = Remotes.pirateHireResultEvent :: RemoteEvent
local pirateHitAlertEvent = Remotes.pirateHitAlertEvent :: RemoteEvent
local armyGeneralOpenEvent = Remotes.armyGeneralOpenEvent :: RemoteEvent
local requestArmyGeneralAction = Remotes.requestArmyGeneralAction :: RemoteEvent
local requestArmyGeneralTargets = Remotes.requestArmyGeneralTargets :: RemoteFunction
local armyGeneralResultEvent = Remotes.armyGeneralResultEvent :: RemoteEvent
local nukeCountdownEvent = Remotes.nukeCountdownEvent :: RemoteEvent
local nukeDetonateEvent = Remotes.nukeDetonateEvent :: RemoteEvent
local airStrikeEvent = Remotes.airStrikeEvent :: RemoteEvent
local marketPriceUpdate = Remotes.marketPriceUpdate :: RemoteEvent
local requestMarketSnapshot = Remotes.requestMarketSnapshot :: RemoteFunction
-- `ClientRemotes` already binds `DevLog` printing on first require; no extra hook needed here.

-- Initialize ClientPlotGrid singleton with remotes
ClientPlotGrid.init({
	player = player,
	playerGui = playerGui,
	Workspace = Workspace,
	ReplicatedStorage = ReplicatedStorage,
	Constants = Constants,
	OilConfig = OilConfig,
	mouse = mouse,
	requestBuyChunk = requestBuyChunk,
	oilActionResult = oilActionResult,
})

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
local requestSellWarehouseType = Remotes.requestSellWarehouseType :: RemoteEvent

local TOOL_DRILL = "Drill"
local TOOL_PIPE = "Pipe"

-- State variables kept local for backward compatibility; synced to ClientPlotGrid module.
-- Functions extracted to ClientPlotGrid are aliased below after their old definitions are removed.
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

local removeHoldStart = 0
local removeHoldDrillId: number? = nil
local promptConnections = {}

-- =================== ALIASES TO ClientPlotGrid MODULE ===================
-- Functions extracted to ClientPlotGrid singleton — aliased here for backward compat.
local SUB_TILE_SIZE = ClientPlotGrid.SUB_TILE_SIZE
local plotGridConstants = ClientPlotGrid.plotGridConstants
local cellKeyOf = ClientPlotGrid.cellKeyOf
local readLocalFtueCellKey = ClientPlotGrid.readLocalFtueCellKey
local clientWorldToCell = ClientPlotGrid.clientWorldToCell
local clientCellToWorld = ClientPlotGrid.clientCellToWorld
local clientCellInBounds = ClientPlotGrid.clientCellInBounds
local setStatus = ClientPlotGrid.setStatus
local getEquippedToolName = ClientPlotGrid.getEquippedToolName
local getEquippedToolInfo = ClientPlotGrid.getEquippedToolInfo
local getOwnedPlotByAttribute = ClientPlotGrid.getOwnedPlotByAttribute
local rebuildStateMaps = function()
	ClientPlotGrid.rebuildStateMaps()
	-- Sync module state back to local vars
	chunkStateById = ClientPlotGrid.getChunkStateById()
	drillStateById = ClientPlotGrid.getDrillStateById()
	pipeStateByCellKey = ClientPlotGrid.getPipeStateByCellKey()
	drumStateByCellKey = ClientPlotGrid.getDrumStateByCellKey()
end
local disconnectPromptConnections = ClientPlotGrid.disconnectPromptConnections
local bindPromptsForOwnedPlot = ClientPlotGrid.bindPromptsForOwnedPlot
local bindOwnedPlot = function()
	ClientPlotGrid.bindOwnedPlot()
	-- Sync module state back to local vars
	ownedPlot = ClientPlotGrid.getOwnedPlot()
	chunkPartById = ClientPlotGrid.getChunkPartById()
end

-- =================== ALIASES TO PlacementClient MODULE ===================
local getTargetedChunkHit = PlacementClient.getTargetedChunkHit
local isChunkUnlocked = PlacementClient.isChunkUnlocked
local getChunkSurfaceY = PlacementClient.getChunkSurfaceY
local surfaceYFromRayTarget = PlacementClient.surfaceYFromRayTarget
local pumpGhostVisualGroundLiftStuds = PlacementClient.pumpGhostVisualGroundLiftStuds
local distanceXZ = PlacementClient.distanceXZ
local isPlacementValid = PlacementClient.isPlacementValid
local updateGhost = PlacementClient.updateGhost
local updatePipeGhost = PlacementClient.updatePipeGhost
local tryPipeAction = PlacementClient.tryPipeAction
local updateFocusUi = PlacementClient.updateFocusUi
local hideGhost = PlacementClient.hideGhost
local hidePipeGhost = PlacementClient.hidePipeGhost
local updateHammerHover = PlacementClient.updateHammerHover
local hideHammerHover = PlacementClient.hideHammerHover
local getPipeHit = PlacementClient.getPipeHit
local pipeDebugLog = PlacementClient.pipeDebugLog


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
	-- `CashStrip` lives directly under `HUD.Canvas` (legacy `LeftStack` parent removed).
	-- Fall back to a recursive search so a future re-author into a sibling frame still
	-- resolves without a code change.
	local hud = pg:FindFirstChild("HUD")
	local canvas = hud and hud:FindFirstChild("Canvas")
	local strip = canvas and canvas:FindFirstChild("CashStrip")
	if not strip then
		strip = hud and hud:FindFirstChild("CashStrip", true)
	end
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

-- Deferred below: `InvokeServer()` yields mid-script, so an early `task.defer(startHudModalWiring)`
-- could run this bootstrap before `playEventSFX` / `StraitMarketHudClient` connect (nil call).

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

-- Initialize PlacementClient now that resolveHammerTarget + estimateRefundForTarget are defined
PlacementClient.init({
	player = player,
	playerGui = playerGui,
	mouse = mouse,
	Workspace = Workspace,
	ReplicatedStorage = ReplicatedStorage,
	OilConfig = OilConfig,
	Constants = Constants,
	requestPlacePipe = requestPlacePipe,
	PlacementAnchor = PlacementAnchor,
	PlotCellTileResolve = PlotCellTileResolve,
	ClientPlotGrid = ClientPlotGrid,
	resolveHammerTarget = resolveHammerTarget,
	estimateRefundForTarget = estimateRefundForTarget,
})

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

local oilSnapshotDeps = {
	setState = function(s: any)
		state = s
		ClientPlotGrid.setState(s)
	end,
	getState = function() return state end,
	getConfigTable = function() return ClientPlotGrid.getConfig() end,
	invalidatePlotGridCache = function() ClientPlotGrid.invalidatePlotGridCache() end,
	rebuildStateMaps = rebuildStateMaps,
	updateUi = updateUi,
	hasChunkState = function() return next(ClientPlotGrid.getChunkStateById()) ~= nil end,
}

local initialOk, initialSnapshot = OilSnapshotClient.invokeOilSnapshot(requestOilSnapshot)
local hasInitialState = initialOk and OilSnapshotClient.applySnapshot(oilSnapshotDeps, initialSnapshot)
if not hasInitialState then
	task.spawn(function()
		OilSnapshotClient.requestSnapshotWithRetry(oilSnapshotDeps, requestOilSnapshot, 10, 0.25)
	end)
end

player:GetAttributeChangedSignal("PlotId"):Connect(function()
	bindOwnedPlot()
	updateUi()
	task.spawn(function()
		OilSnapshotClient.requestSnapshotWithRetry(oilSnapshotDeps, requestOilSnapshot, 6, 0.2)
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
	OilSnapshotClient.onOilStatePush(oilSnapshotDeps, newState)
end)

-- `oilActionResult.OnClientEvent` handler is wired after `playEventSFX` is defined (below)
-- so the upgrade-success SFX has the helper in scope.

-- Strait status pill, oil prices, warehouse snapshot, and `globalStateUpdate` SFX live in `StraitMarketHudClient`.
-- `playEventSFX` defined below; the module is wired after it exists.

task.defer(startHudModalWiring)

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

-- Server tags upgrade results with `payload.action` ∈ { "UpgradeWarehouse", "UpgradeOilTank",
-- "UpgradeShipSpeed", "UpgradeShipCapacity" } so the client can play a single shared SFX on success.
local UPGRADE_SUCCESS_ACTIONS: { [string]: boolean } = {
	UpgradeWarehouse = true,
	UpgradeOilTank = true,
	UpgradeShipSpeed = true,
	UpgradeShipCapacity = true,
}

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
	if okOpt == true and typeof(payload.action) == "string" and UPGRADE_SUCCESS_ACTIONS[payload.action] then
		playEventSFX("Upgrade", 0.3)
	end
end)

StrategicStrikeClient.connect({
	player = player,
	playerGui = playerGui,
	setStatus = setStatus,
	playEventSFX = playEventSFX,
	explodeBoatIntoPieces = function(boat: Instance, epicenter: Vector3?)
		StraitWaypointWorldFx.ExplodeBoatIntoPieces(boat, epicenter)
	end,
}, {
	nukeCountdownEvent = nukeCountdownEvent,
	nukeDetonateEvent = nukeDetonateEvent,
	airStrikeEvent = airStrikeEvent,
	armyGeneralOpenEvent = armyGeneralOpenEvent,
	armyGeneralResultEvent = armyGeneralResultEvent,
	requestArmyGeneralAction = requestArmyGeneralAction,
	requestArmyGeneralTargets = requestArmyGeneralTargets,
})

StraitMarketHudClient.connect({
	player = player,
	playerGui = playerGui,
	getHudUiFolder = getHudUiFolder,
	playEventSFX = playEventSFX,
}, {
	warehouseStateUpdate = warehouseStateUpdate,
	requestWarehouseSnapshot = requestWarehouseSnapshot,
	globalStateUpdate = globalStateUpdate,
	marketPriceUpdate = marketPriceUpdate,
	requestMarketSnapshot = requestMarketSnapshot,
})

ShipmentVisualClient.connect({
	player = player,
	playerGui = playerGui,
	straitWaypointFx = StraitWaypointWorldFx,
	setStatus = setStatus,
	playEventSFX = playEventSFX,
}, shipmentVisualEvent)

PirateHireClient.connect({
	player = player,
	playerGui = playerGui,
	setStatus = setStatus,
}, {
	requestPirateHireTargets = requestPirateHireTargets,
	requestPirateHireAction = requestPirateHireAction,
	pirateHireOpenEvent = pirateHireOpenEvent,
	pirateHireResultEvent = pirateHireResultEvent,
	pirateHitAlertEvent = pirateHitAlertEvent,
})

-- ShipmentVisualEvent strait FX + HUD status + delivery SFX live in `ShipmentVisualClient`
-- (wired above with `StraitWaypointWorldFx` + `setStatus` + `playEventSFX`).

-- Drill/prospector animation + super tile pulse live in DrillAnimationClient
DrillAnimationClient.start()

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

	DrillAnimationClient.tick()
end)

DrillReplicationClient.connect({
	player = player,
	playerGui = playerGui,
	setStatus = setStatus,
	prospectProgressUpdate = prospectProgressUpdate,
	drillProgressUpdate = drillProgressUpdate,
	requestRevealTile = requestRevealTile,
	VeinCrateOpener = VeinCrateOpener,
})

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

-- Oil market price/snapshot replication owned by `StraitMarketHudClient` (wired earlier).

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

