--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local mouse = player:GetMouse()

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))

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

local remotesFolder = Shared:FindFirstChild("Remotes")
while remotesFolder == nil do
	task.wait(0.1)
	remotesFolder = Shared:FindFirstChild("Remotes")
end

local requestOilSnapshot = remotesFolder:WaitForChild(RemoteNames.RequestOilSnapshot) :: RemoteFunction
local requestPlaceDrill = remotesFolder:WaitForChild(RemoteNames.RequestPlaceDrill) :: RemoteEvent
local requestRemoveDrill = remotesFolder:WaitForChild(RemoteNames.RequestRemoveDrill) :: RemoteEvent
local requestBuyChunk = remotesFolder:WaitForChild(RemoteNames.RequestBuyChunk) :: RemoteEvent
local requestPlacePipe = remotesFolder:WaitForChild(RemoteNames.RequestPlacePipe) :: RemoteEvent
local requestRemovePipe = remotesFolder:WaitForChild(RemoteNames.RequestRemovePipe) :: RemoteEvent
local requestPickupBarrel = remotesFolder:WaitForChild(RemoteNames.RequestPickupBarrel) :: RemoteEvent
local requestTeleportToShip = remotesFolder:WaitForChild(RemoteNames.RequestTeleportToShip) :: RemoteEvent
local requestTeleportHome = remotesFolder:WaitForChild(RemoteNames.RequestTeleportHome) :: RemoteEvent
local requestUpgradeWarehouse = remotesFolder:WaitForChild(RemoteNames.RequestUpgradeWarehouse) :: RemoteEvent
local requestSellAllWarehouse = remotesFolder:WaitForChild(RemoteNames.RequestSellAllWarehouse) :: RemoteEvent
local requestTeleportToWarehouse = remotesFolder:WaitForChild(RemoteNames.RequestTeleportToWarehouse) :: RemoteEvent
local warehouseStateUpdate = remotesFolder:WaitForChild(RemoteNames.WarehouseStateUpdate) :: RemoteEvent
local requestWarehouseSnapshot = remotesFolder:WaitForChild(RemoteNames.RequestWarehouseSnapshot) :: RemoteFunction
local requestClearObstacle = remotesFolder:WaitForChild(RemoteNames.RequestClearObstacle) :: RemoteEvent
local biomeRevealEvent = remotesFolder:WaitForChild(RemoteNames.BiomeRevealEvent) :: RemoteEvent
local requestDispatchShipment = remotesFolder:WaitForChild(RemoteNames.RequestDispatchShipment) :: RemoteEvent
local oilStateUpdate = remotesFolder:WaitForChild(RemoteNames.OilStateUpdate) :: RemoteEvent
local oilActionResult = remotesFolder:WaitForChild(RemoteNames.OilActionResult) :: RemoteEvent
local shipmentVisualEvent = remotesFolder:WaitForChild(RemoteNames.ShipmentVisualEvent) :: RemoteEvent
local requestDevSetStraitBracket = remotesFolder:WaitForChild(RemoteNames.RequestDevSetStraitBracket) :: RemoteEvent
local globalStateUpdate = remotesFolder:WaitForChild(RemoteNames.GlobalStateUpdate) :: RemoteEvent

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
local marketPriceUpdate = remotesFolder:WaitForChild(RemoteNames.MarketPriceUpdate) :: RemoteEvent
local requestSellWarehouseType = remotesFolder:WaitForChild(RemoteNames.RequestSellWarehouseType) :: RemoteEvent
local requestMarketSnapshot = remotesFolder:WaitForChild(RemoteNames.RequestMarketSnapshot) :: RemoteFunction

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

local function setStatus(_message: string, _ok: boolean?)
	-- Previously OilHud status label; rebind to StarterGui `HUD` when wired.
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

local function getOwnedPlotByAttribute(): Model?
	local plotId = player:GetAttribute("PlotId")
	if typeof(plotId) ~= "number" or plotId <= 0 then
		return nil
	end
	local map = Workspace:FindFirstChild("Map")
	if not map then
		return nil
	end
	local plots = map:FindFirstChild("Plots")
	if not plots then
		return nil
	end
	for _, item in ipairs(plots:GetChildren()) do
		if item:IsA("Model") then
			local id = item:GetAttribute("PlotId")
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

local function bindPromptsForOwnedPlot()
	disconnectPromptConnections()
	if not ownedPlot then
		return
	end
	local ground = ownedPlot:FindFirstChild("PlotGround")
	if not (ground and ground:IsA("Model")) then
		return
	end
	for _, descendant in ipairs(ground:GetDescendants()) do
		if descendant:IsA("ProximityPrompt") and descendant.Name == "BuyPrompt" then
			local conn = descendant.Triggered:Connect(function(triggeringPlayer)
				if triggeringPlayer ~= player then
					return
				end
				-- Walk up to find the section model carrying ChunkId
				local cursor: Instance? = descendant
				while cursor and cursor.Parent do
					cursor = cursor.Parent
					if cursor and typeof(cursor:GetAttribute("ChunkId")) == "string" then
						requestBuyChunk:FireServer({ chunkId = cursor:GetAttribute("ChunkId") })
						return
					end
				end
			end)
			table.insert(promptConnections, conn)
		end
	end
end

local function bindOwnedPlot()
	chunkPartById = {}
	ownedPlot = getOwnedPlotByAttribute()
	if not ownedPlot then
		return
	end

	local ground = ownedPlot:FindFirstChild("PlotGround")
	if not (ground and ground:IsA("Model")) then
		return
	end

	for _, item in ipairs(ground:GetChildren()) do
		if item:IsA("Model") then
			local chunkId = item:GetAttribute("ChunkId")
			if typeof(chunkId) == "string" then
				chunkPartById[chunkId] = item
			end
		end
	end

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

-- Returns the top Y of a chunk's surface (the highest sub-tile).
-- Used to snap drill placement Y so grazing-camera raycasts don't yield floating drills.
local function getChunkSurfaceY(chunkId: string): number?
	local sectionModel = chunkPartById[chunkId]
	if not sectionModel then
		return nil
	end
	local topY: number? = nil
	for _, d in ipairs(sectionModel:GetChildren()) do
		if d:IsA("BasePart") and d.Name:match("^T%d%d$") then
			local surface = d.Position.Y + d.Size.Y / 2
			if topY == nil or surface > topY then
				topY = surface
			end
		end
	end
	return topY
end

local function distanceXZ(a: Vector3, b: Vector3): number
	local dx = a.X - b.X
	local dz = a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

local function isPlacementValid(chunkId: string, hitPos: Vector3): boolean
	if not isChunkUnlocked(chunkId) then
		return false
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

local function ensureGhost(): Model?
	if ghostDrill and ghostDrill.Parent then
		return ghostDrill
	end
	local template = ReplicatedStorage:FindFirstChild("Assets")
	template = template and template:FindFirstChild("Drill")
	if not template then
		return nil
	end
	local clone = template:Clone()
	clone.Name = "DrillGhost"
	-- Strip any server scripts so the ghost doesn't run OilBurstSpawner
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("Script") or d:IsA("LocalScript") then
			d:Destroy()
		end
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
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
	local equipped = getEquippedToolName()
	if equipped ~= TOOL_DRILL then
		hideGhost()
		return
	end
	local _, hitPos, chunkId = getTargetedChunkHit()
	if not (hitPos and chunkId) then
		hideGhost()
		return
	end
	local g = ensureGhost()
	if not g then
		return
	end
	local surfaceY = getChunkSurfaceY(chunkId) or hitPos.Y
	g:PivotTo(CFrame.new(hitPos.X, surfaceY, hitPos.Z))
	if ghostHighlight then
		if isPlacementValid(chunkId, hitPos) then
			ghostHighlight.FillColor = Color3.fromRGB(80, 220, 120)
			ghostHighlight.OutlineColor = Color3.fromRGB(190, 255, 200)
		else
			ghostHighlight.FillColor = Color3.fromRGB(220, 70, 70)
			ghostHighlight.OutlineColor = Color3.fromRGB(255, 180, 180)
		end
	end
end

-- =================== CELL-GRID PIPE PLACEMENT ===================

local function getPipeCellHit(): (number?, number?)
	local target = mouse.Target
	if not (target and target:IsA("BasePart")) then
		return nil, nil
	end
	local _, hitPos, _chunkId = getTargetedChunkHit()
	if not hitPos then
		return nil, nil
	end
	local row, col = clientWorldToCell(hitPos.X, hitPos.Z)
	if not clientCellInBounds(row, col) then
		return nil, nil
	end
	return row, col
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

local function pipeCellValid(row: number, col: number): (boolean, string?)
	if not clientCellInBounds(row, col) then
		return false, "Out of bounds"
	end
	local _, _, _, _, subTilesPerSide = plotGridConstants()
	local sRow = math.floor((row - 1) / subTilesPerSide) + 1
	local sCol = math.floor((col - 1) / subTilesPerSide) + 1
	local sectionId = string.format("S%02d_%02d", sRow, sCol)
	local section = chunkStateById[sectionId]
	if not section or not section.unlocked then
		return false, "Locked section"
	end
	local key = cellKeyOf(row, col)
	if pipeStateByCellKey[key] then
		return false, "Cell already has a pipe"
	end
	return true
end

local function updatePipeGhost()
	local equipped = getEquippedToolName()
	if equipped ~= TOOL_PIPE then
		hidePipeGhost()
		return
	end
	local row, col = getPipeCellHit()
	if not row then
		hidePipeGhost()
		return
	end
	local x, z = clientCellToWorld(row, col)
	local valid = pipeCellValid(row, col)
	local g = ensurePipeGhost()
	local body = g:FindFirstChild("Body")
	if body and body:IsA("BasePart") then
		body.Position = Vector3.new(x, 6.5, z)
		body.Color = valid and Color3.fromRGB(80, 220, 120) or Color3.fromRGB(220, 70, 70)
	end
end

local function tryPipeAction()
	if getEquippedToolName() ~= TOOL_PIPE then
		return
	end
	local row, col = getPipeCellHit()
	if not row then
		setStatus("Click on an owned chunk.", false)
		return
	end
	local valid, reason = pipeCellValid(row, col)
	if not valid then
		setStatus(reason or "Cannot place pipe here.", false)
		return
	end
	requestPlacePipe:FireServer({ row = row, col = col })
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
		-- Show biome name + per-tile oil type if we can determine which tile is hovered
		local tileInfo = ""
		if chunk.tiles and mouse.Target and mouse.Target:IsA("BasePart") then
			local targetName = mouse.Target.Name
			local tileData = chunk.tiles[targetName]
			if tileData then
				local oilNames = {
					HeavyCrude = "Heavy Crude",
					LightSweet = "Light Sweet",
					PremiumRefined = "Premium Refined",
				}
				local tileName = tileData.tileName or "?"
				local oilName = oilNames[tileData.oilType] or tileData.oilType or "?"
				tileInfo = string.format(" | %s — %s", tileName, oilName)
				if tileData.hasObstacle then
					tileInfo = tileInfo .. " [BLOCKED]"
				end
			end
		end
		focusLabel.Text = string.format("%s%s", chunk.biome or "?", tileInfo)
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

local function tryPrimaryAction()
	if getEquippedToolName() ~= TOOL_DRILL then
		return
	end
	local _, hitPos, chunkId = getTargetedChunkHit()
	if not (hitPos and chunkId) then
		return
	end
	if not isChunkUnlocked(chunkId) then
		setStatus("That chunk is locked.", false)
		return
	end
	local surfaceY = getChunkSurfaceY(chunkId) or hitPos.Y
	requestPlaceDrill:FireServer({
		chunkId = chunkId,
		x = hitPos.X,
		y = surfaceY,
		z = hitPos.Z,
	})
end

local function clearRemoveHold()
	removeHoldStart = 0
	removeHoldDrillId = nil
end

bindOwnedPlot()

local initial = requestOilSnapshot:InvokeServer()
if typeof(initial) == "table" then
	state = initial.state
	if typeof(initial.config) == "table" then
		for k, v in pairs(initial.config) do
			config[k] = v
		end
	end
end
rebuildStateMaps()
updateUi()

player:GetAttributeChangedSignal("PlotId"):Connect(function()
	bindOwnedPlot()
	updateUi()
end)

playerGui.ChildAdded:Connect(function(child)
	if child.Name == "HUD" then
		cashTextLabel = nil
		updateCashHud()
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

	-- Otherwise try pipe removal by cell: take cursor world position, snap to cell
	local _, hitPos, _hitChunk = getTargetedChunkHit()
	if hitPos then
		local row, col = clientWorldToCell(hitPos.X, hitPos.Z)
		if clientCellInBounds(row, col) and pipeStateByCellKey[cellKeyOf(row, col)] then
			requestRemovePipe:FireServer({ row = row, col = col })
			setStatus("Removed pipe.", true)
			return
		end
	end
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
	setStatus(tostring(payload.message or "?"), payload.ok == true)
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
		marketState.straitState = snapshot.state
		updateMarketUi()
	end
end)

shipmentVisualEvent.OnClientEvent:Connect(function(packet)
	if typeof(packet) ~= "table" then
		return
	end
	local kind = packet.type
	local data = packet.data
	if typeof(data) ~= "table" then
		return
	end

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

RunService.RenderStepped:Connect(function()
	updateFocusUi()
	updateGhost()
	updatePipeGhost()

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

	-- Slot machine: flash REAL biome tile sets onto the 5x5 grid (no runtime ScreenGui; rewire banner to HUD later)
	task.spawn(function()
		-- All 9 biomes with their actual tile types
		local biomePresets = {
			{ name = "Dusty Desert", tiles = {
				{ mat = Enum.Material.Sand, col = Color3.fromRGB(210,185,130), w = 100 },
			}},
			{ name = "Decent Desert", tiles = {
				{ mat = Enum.Material.Sand, col = Color3.fromRGB(210,185,130), w = 64 },
				{ mat = Enum.Material.Sandstone, col = Color3.fromRGB(180,130,90), w = 20 },
				{ mat = Enum.Material.Sand, col = Color3.fromRGB(240,210,80), w = 4 },
				{ mat = Enum.Material.Ground, col = Color3.fromRGB(55,45,35), w = 12 },
			}},
			{ name = "Clay Desert", tiles = {
				{ mat = Enum.Material.Sand, col = Color3.fromRGB(210,185,130), w = 48 },
				{ mat = Enum.Material.Sandstone, col = Color3.fromRGB(180,130,90), w = 52 },
			}},
			{ name = "Frostlands", tiles = {
				{ mat = Enum.Material.Sand, col = Color3.fromRGB(210,185,130), w = 32 },
				{ mat = Enum.Material.Sandstone, col = Color3.fromRGB(180,130,90), w = 32 },
				{ mat = Enum.Material.Sand, col = Color3.fromRGB(240,210,80), w = 8 },
				{ mat = Enum.Material.Ground, col = Color3.fromRGB(55,45,35), w = 20 },
				{ mat = Enum.Material.Pebble, col = Color3.fromRGB(180,170,60), w = 8 },
			}},
			{ name = "Volcanic", tiles = {
				{ mat = Enum.Material.Ground, col = Color3.fromRGB(55,45,35), w = 12 },
				{ mat = Enum.Material.Basalt, col = Color3.fromRGB(50,45,40), w = 12 },
				{ mat = Enum.Material.Pebble, col = Color3.fromRGB(180,170,60), w = 20 },
				{ mat = Enum.Material.Mud, col = Color3.fromRGB(255,123,66), w = 44 },
				{ mat = Enum.Material.Ice, col = Color3.fromRGB(3,3,3), w = 12 },
			}},
			{ name = "MagmaGrounds", tiles = {
				{ mat = Enum.Material.Basalt, col = Color3.fromRGB(50,45,40), w = 48 },
				{ mat = Enum.Material.Mud, col = Color3.fromRGB(255,123,66), w = 52 },
			}},
			{ name = "GrassyFarm", tiles = {
				{ mat = Enum.Material.Ground, col = Color3.fromRGB(100,80,55), w = 20 },
				{ mat = Enum.Material.Grass, col = Color3.fromRGB(4,255,0), w = 32 },
				{ mat = Enum.Material.Mud, col = Color3.fromRGB(0,255,225), w = 24 },
				{ mat = Enum.Material.Mud, col = Color3.fromRGB(164,100,10), w = 24 },
			}},
			{ name = "Grassy Forrest", tiles = {
				{ mat = Enum.Material.LeafyGrass, col = Color3.fromRGB(50,100,45), w = 36 },
				{ mat = Enum.Material.Grass, col = Color3.fromRGB(4,255,0), w = 40 },
				{ mat = Enum.Material.Ground, col = Color3.fromRGB(49,34,12), w = 24 },
			}},
			{ name = "IceyArea", tiles = {
				{ mat = Enum.Material.Glacier, col = Color3.fromRGB(230,240,250), w = 28 },
				{ mat = Enum.Material.Glacier, col = Color3.fromRGB(160,200,240), w = 32 },
				{ mat = Enum.Material.Rock, col = Color3.fromRGB(120,115,110), w = 28 },
				{ mat = Enum.Material.Mud, col = Color3.fromRGB(0,255,225), w = 12 },
			}},
		}

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

		-- Collect tile parts
		local tileParts = {}
		if sectionModel then
			for _, child in ipairs(sectionModel:GetChildren()) do
				if child:IsA("BasePart") and child.Name:match("^T%d%d$") then
					table.insert(tileParts, child)
				end
			end
		end

		-- Obstacle preview data per biome
		local biomeObstacles = {
			["Dusty Desert"] = { rate = 0.04, types = {"Obstacle_Rock"} },
			["Decent Desert"] = { rate = 0.20, types = {"Obstacle_Rock", "Obstacle_MudPit"} },
			["Clay Desert"] = { rate = 0.32, types = {"Obstacle_MudPit", "Obstacle_Pyramid"} },
			["Frostlands"] = { rate = 0.28, types = {"Obstacle_ObsidianPillar"} },
			["Volcanic"] = { rate = 0.36, types = {"Obstacle_Rock", "Obstacle_LavaRock", "Obstacle_ObsidianPillar"} },
			["MagmaGrounds"] = { rate = 0, types = {} },
			["GrassyFarm"] = { rate = 0.44, types = {"Obstacle_Bush", "Obstacle_Water"} },
			["Grassy Forrest"] = { rate = 0.40, types = {"Obstacle_Tree"} },
			["IceyArea"] = { rate = 0.40, types = {"Obstacle_FrozenStump", "Obstacle_Water"} },
		}
		local assetsFolder = ReplicatedStorage:FindFirstChild("Assets")
		local previewObstacles = {} -- track spawned preview obstacles to clean up

		local function clearPreviewObstacles()
			for _, obj in ipairs(previewObstacles) do
				if obj.Parent then obj:Destroy() end
			end
			previewObstacles = {}
		end

		-- Track tiles hidden by water preview so we can restore them
		local hiddenTiles = {}

		local function spawnPreviewObstacles(preset)
			clearPreviewObstacles()
			-- Restore any tiles hidden by water preview
			for _, t in ipairs(hiddenTiles) do
				if t and t.Parent then t.Transparency = 0 end
			end
			hiddenTiles = {}

			local obsData = biomeObstacles[preset.name]
			if not obsData or obsData.rate <= 0 or #obsData.types == 0 or not assetsFolder then return end

			for _, part in ipairs(tileParts) do
				if math.random() < obsData.rate then
					local templateName = obsData.types[math.random(1, #obsData.types)]
					local isWater = templateName == "Obstacle_Water"
					local template = assetsFolder:FindFirstChild(templateName)
					if template then
						if isWater then
							-- Water: hide tile, place water block at tile level
							part.Transparency = 1
							table.insert(hiddenTiles, part)
							local waterParts = {}
							if template:IsA("Folder") or template:IsA("Model") then
								for _, child in ipairs(template:GetChildren()) do
									if child:IsA("BasePart") then table.insert(waterParts, child) end
								end
							elseif template:IsA("BasePart") then
								table.insert(waterParts, template)
							end
							for _, wp in ipairs(waterParts) do
								local wc = wp:Clone()
								wc.Name = "PreviewObstacle"
								wc.Anchored = true
								wc.CanCollide = false
								wc.CanQuery = false
								wc.Size = Vector3.new(part.Size.X, wp.Size.Y, part.Size.Z)
								wc.Position = part.Position + Vector3.new(0, (wp.Size.Y - part.Size.Y) / 2, 0)
								wc.Parent = sectionModel
								table.insert(previewObstacles, wc)
							end
						else
							-- Normal obstacles: spawn on top
							local clone = template:Clone()
							clone.Name = "PreviewObstacle"
							if clone:IsA("BasePart") then
								clone.Anchored = true
								clone.CanCollide = false
								clone.CanQuery = false
								clone.Position = part.Position + Vector3.new(0, clone.Size.Y / 2 + part.Size.Y / 2, 0)
							elseif clone:IsA("Model") then
								clone:PivotTo(CFrame.new(part.Position + Vector3.new(0, 2, 0)))
							end
							clone.Parent = sectionModel
							table.insert(previewObstacles, clone)
						end
					end
				end
			end
		end

		-- Flash through biomes, each time randomizing tiles + obstacles
		local intervals = { 0.12, 0.12, 0.15, 0.18, 0.22, 0.3, 0.4, 0.6 }
		for i, interval in ipairs(intervals) do
			local preset = biomePresets[((i - 1) % #biomePresets) + 1]

			-- Apply random tiles from this biome's set to each cell
			for _, part in ipairs(tileParts) do
				local t = rollTile(preset)
				part.Material = t.mat
				part.Color = t.col
			end

			-- Spawn preview obstacles for this biome
			spawnPreviewObstacles(preset)

			task.wait(interval)
		end

		-- Clean up preview obstacles before final reveal
		clearPreviewObstacles()
		for _, t in ipairs(hiddenTiles) do
			if t and t.Parent then t.Transparency = 0 end
		end
		hiddenTiles = {}

		-- Wait for server to set revealed=true and push the final tile visuals
		_ = biomeName
		task.wait(3.5)
	end)
end)

-- Obstacle clear prompts: bind when they appear
Workspace.DescendantAdded:Connect(function(descendant)
	if descendant:IsA("ProximityPrompt") and descendant.Name == "ClearPrompt" then
		descendant.Triggered:Connect(function(triggeringPlayer)
			if triggeringPlayer ~= player then return end
			local obstacle = descendant.Parent
			while obstacle and obstacle.Parent do
				if obstacle:GetAttribute("IsObstacle") then
					local chunkId = obstacle:GetAttribute("ChunkId")
					local tileKey = obstacle:GetAttribute("TileKey")
					if chunkId and tileKey then
						requestClearObstacle:FireServer({ chunkId = chunkId, tileKey = tileKey })
					end
					return
				end
				obstacle = obstacle.Parent
			end
		end)
	end
end)

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
