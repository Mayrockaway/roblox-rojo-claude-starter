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
local requestDispatchShipment = remotesFolder:WaitForChild(RemoteNames.RequestDispatchShipment) :: RemoteEvent
local oilStateUpdate = remotesFolder:WaitForChild(RemoteNames.OilStateUpdate) :: RemoteEvent
local oilActionResult = remotesFolder:WaitForChild(RemoteNames.OilActionResult) :: RemoteEvent
local shipmentVisualEvent = remotesFolder:WaitForChild(RemoteNames.ShipmentVisualEvent) :: RemoteEvent

local TOOL_DRILL = "Drill"
local TOOL_PIPE = "Pipe"
local TIER_ORDER = { "PremiumRefined", "LightSweet", "StandardCrude", "HeavyCrude" }

local ui = {}
local shipmentInputs = {}
local shipmentOwnedLabels = {}
local boatButtons = {}
local state = nil
local selectedBoatTypeId: string? = nil
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
	boatCatalog = {},
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
local function plotGridConstants()
	local sectionCols = (config.chunks and config.chunks.cols) or 3
	local sectionRows = (config.chunks and config.chunks.rows) or 4
	local sectionSize = (config.chunks and config.chunks.size) or 40
	local subTilesPerSide = math.floor(sectionSize / SUB_TILE_SIZE)
	local centerX = -840
	local centerZ = -1020
	local startX = centerX - ((sectionCols - 1) / 2) * sectionSize
	local startZ = centerZ - ((sectionRows - 1) / 2) * sectionSize
	local cellOriginX = startX - ((subTilesPerSide - 1) / 2) * SUB_TILE_SIZE
	local cellOriginZ = startZ - ((subTilesPerSide - 1) / 2) * SUB_TILE_SIZE
	local globalCols = sectionCols * subTilesPerSide
	local globalRows = sectionRows * subTilesPerSide
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

local function createLabel(parent: Instance, text: string, size: UDim2, position: UDim2, textSize: number)
	local label = Instance.new("TextLabel")
	label.Size = size
	label.Position = position
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = Color3.fromRGB(236, 236, 236)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Font = Enum.Font.GothamSemibold
	label.TextSize = textSize
	label.Parent = parent
	return label
end

local function createButton(parent: Instance, text: string, size: UDim2, position: UDim2)
	local button = Instance.new("TextButton")
	button.Size = size
	button.Position = position
	button.Text = text
	button.BackgroundColor3 = Color3.fromRGB(35, 74, 101)
	button.TextColor3 = Color3.fromRGB(245, 245, 245)
	button.Font = Enum.Font.GothamBold
	button.TextSize = 12
	button.AutoButtonColor = true
	button.Parent = parent
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 5)
	corner.Parent = button
	return button
end

local function createTextBox(parent: Instance, size: UDim2, position: UDim2, defaultText: string)
	local box = Instance.new("TextBox")
	box.Size = size
	box.Position = position
	box.BackgroundColor3 = Color3.fromRGB(18, 40, 58)
	box.TextColor3 = Color3.fromRGB(245, 245, 245)
	box.Font = Enum.Font.GothamSemibold
	box.TextSize = 12
	box.ClearTextOnFocus = false
	box.PlaceholderText = "0"
	box.Text = defaultText
	box.Parent = parent
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 5)
	corner.Parent = box
	return box
end

local function setStatus(message: string, ok: boolean?)
	if not ui.statusLabel then
		return
	end
	ui.statusLabel.Text = message
	if ok == nil then
		ui.statusLabel.TextColor3 = Color3.fromRGB(190, 190, 190)
	elseif ok then
		ui.statusLabel.TextColor3 = Color3.fromRGB(160, 223, 178)
	else
		ui.statusLabel.TextColor3 = Color3.fromRGB(245, 135, 135)
	end
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
		if d:IsA("BasePart") and d.Name ~= "LockOverlay" and d.Name ~= "Sign" then
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
	if chunk.unlocked then
		focusLabel.Text = string.format("%s — Owned", chunk.biome or "?")
		focusLabel.TextColor3 = Color3.fromRGB(160, 230, 170)
	else
		local label = string.format("%s — $%d", chunk.biome or "?", chunk.cost or 0)
		if chunk.canBuy == false then
			label = label .. " (no neighbour)"
		end
		focusLabel.Text = label
		focusLabel.TextColor3 = Color3.fromRGB(252, 220, 120)
	end
	focusBillboard.Enabled = true
end

local function parseIntText(text: string): number
	return math.max(0, math.floor(tonumber(text) or 0))
end

local function getSelectedBoatDef()
	for _, boat in ipairs(config.boatCatalog or {}) do
		if boat.boatTypeId == selectedBoatTypeId then
			return boat
		end
	end
	return nil
end

local function parseManifest()
	local manifest = {}
	local total = 0
	for _, tier in ipairs(TIER_ORDER) do
		local input = shipmentInputs[tier]
		local value = 0
		if input then
			value = parseIntText(input.Text)
		end
		manifest[tier] = value
		total += value
	end
	return manifest, total
end

local function applyBoatButtonStyles()
	for boatTypeId, button in pairs(boatButtons) do
		if boatTypeId == selectedBoatTypeId then
			button.BackgroundColor3 = Color3.fromRGB(72, 146, 196)
		else
			button.BackgroundColor3 = Color3.fromRGB(35, 74, 101)
		end
	end
end

local function updateUi()
	if not state or not ui.cashLabel then
		return
	end

	ui.cashLabel.Text = string.format("Cash: $%d", state.cash or 0)
	ui.storageLabel.Text = string.format("Storage: %d / %d", state.totalOil or 0, state.storageCapacity or 0)
	local stalled = state.stalledDrillCount or 0
	ui.drillsLabel.Text = string.format("Active Drills: %d / %d  (Stalled: %d)", state.activeDrillCount or 0, state.maxActiveDrills or 0, stalled)
	local ownedCount = 0
	for _, chunk in pairs(chunkStateById) do
		if chunk.unlocked then
			ownedCount += 1
		end
	end
	ui.chunksLabel.Text = string.format("Owned Chunks: %d", ownedCount)
	ui.shipmentsLabel.Text = string.format("Active Shipments: %d", state.activeShipmentCount or 0)

	local oilByTier = state.oilByTier or {}
	for _, tier in ipairs(TIER_ORDER) do
		local label = shipmentOwnedLabels[tier]
		if label then
			label.Text = string.format("Owned: %d", oilByTier[tier] or 0)
		end
	end

	local boatDef = getSelectedBoatDef()
	local _, manifestTotal = parseManifest()
	if boatDef and ui.shipSummaryLabel then
		ui.shipSummaryLabel.Text = string.format(
			"%s | Cap %d | Fee $%d | Selected %d",
			boatDef.displayName or boatDef.boatTypeId,
			boatDef.capacity or 0,
			boatDef.dispatchFee or 0,
			manifestTotal
		)
	elseif ui.shipSummaryLabel then
		ui.shipSummaryLabel.Text = "Pick a boat"
	end

	applyBoatButtonStyles()
end

local function buildShipmentInputs(parent: Instance)
	for i, tier in ipairs(TIER_ORDER) do
		local y = 92 + (i - 1) * 34
		local short = tier
		if tier == "PremiumRefined" then
			short = "Premium"
		elseif tier == "StandardCrude" then
			short = "Standard"
		elseif tier == "LightSweet" then
			short = "Light"
		elseif tier == "HeavyCrude" then
			short = "Heavy"
		end

		createLabel(parent, short, UDim2.fromOffset(86, 16), UDim2.fromOffset(12, y), 11)
		local box = createTextBox(parent, UDim2.fromOffset(56, 22), UDim2.fromOffset(102, y - 2), "0")
		box.FocusLost:Connect(function()
			box.Text = tostring(parseIntText(box.Text))
			updateUi()
		end)
		shipmentInputs[tier] = box

		local owned = createLabel(parent, "Owned: 0", UDim2.fromOffset(105, 16), UDim2.fromOffset(164, y), 11)
		owned.TextColor3 = Color3.fromRGB(180, 198, 210)
		shipmentOwnedLabels[tier] = owned
	end
end

local function buildUi()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "OilHud"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = playerGui

	local root = Instance.new("Frame")
	root.Size = UDim2.fromOffset(280, 150)
	root.Position = UDim2.fromOffset(16, 90)
	root.BackgroundColor3 = Color3.fromRGB(17, 23, 33)
	root.BackgroundTransparency = 0.15
	root.Parent = screenGui

	local rootCorner = Instance.new("UICorner")
	rootCorner.CornerRadius = UDim.new(0, 8)
	rootCorner.Parent = root

	ui.cashLabel = createLabel(root, "Cash: --", UDim2.fromOffset(260, 20), UDim2.fromOffset(10, 8), 13)
	ui.storageLabel = createLabel(root, "Storage: --", UDim2.fromOffset(260, 20), UDim2.fromOffset(10, 28), 13)
	ui.drillsLabel = createLabel(root, "Active Drills: --", UDim2.fromOffset(260, 20), UDim2.fromOffset(10, 48), 13)
	ui.chunksLabel = createLabel(root, "Owned Chunks: --", UDim2.fromOffset(260, 20), UDim2.fromOffset(10, 68), 13)
	ui.shipmentsLabel = createLabel(root, "Active Shipments: --", UDim2.fromOffset(260, 20), UDim2.fromOffset(10, 88), 13)
	ui.hintLabel = createLabel(root, "", UDim2.fromOffset(260, 18), UDim2.fromOffset(10, 110), 11)
	ui.hintLabel.TextColor3 = Color3.fromRGB(172, 172, 172)
	ui.statusLabel = createLabel(root, "Buy chunks, place drills, dispatch at terminal.", UDim2.fromOffset(260, 18), UDim2.fromOffset(10, 128), 10)
	ui.statusLabel.TextColor3 = Color3.fromRGB(190, 190, 190)

	local shipFrame = Instance.new("Frame")
	shipFrame.Size = UDim2.fromOffset(290, 258)
	shipFrame.Position = UDim2.fromOffset(16, 252)
	shipFrame.BackgroundColor3 = Color3.fromRGB(15, 31, 45)
	shipFrame.BackgroundTransparency = 0.12
	shipFrame.Parent = screenGui
	local shipCorner = Instance.new("UICorner")
	shipCorner.CornerRadius = UDim.new(0, 8)
	shipCorner.Parent = shipFrame

	createLabel(shipFrame, "Dock Terminal", UDim2.fromOffset(270, 18), UDim2.fromOffset(10, 8), 14)
	ui.shipSummaryLabel = createLabel(shipFrame, "Pick a boat", UDim2.fromOffset(270, 16), UDim2.fromOffset(10, 30), 11)
	ui.shipSummaryLabel.TextColor3 = Color3.fromRGB(186, 212, 226)

	local buttonsHost = Instance.new("Frame")
	buttonsHost.Size = UDim2.fromOffset(270, 40)
	buttonsHost.Position = UDim2.fromOffset(10, 48)
	buttonsHost.BackgroundTransparency = 1
	buttonsHost.Parent = shipFrame
	ui.boatsHost = buttonsHost

	buildShipmentInputs(shipFrame)

	local dispatchButton = createButton(shipFrame, "Dispatch Shipment", UDim2.fromOffset(268, 28), UDim2.fromOffset(11, 228))
	dispatchButton.MouseButton1Click:Connect(function()
		if not selectedBoatTypeId then
			setStatus("Pick a boat type first.", false)
			return
		end
		local manifest = parseManifest()
		requestDispatchShipment:FireServer({
			boatTypeId = selectedBoatTypeId,
			manifest = manifest,
		})
	end)

	-- Teleport buttons (bottom-right of screen)
	local teleportGui = Instance.new("Frame")
	teleportGui.Name = "TeleportButtons"
	teleportGui.Size = UDim2.fromOffset(160, 80)
	teleportGui.Position = UDim2.new(1, -176, 1, -96)
	teleportGui.BackgroundColor3 = Color3.fromRGB(17, 23, 33)
	teleportGui.BackgroundTransparency = 0.15
	teleportGui.Parent = screenGui
	local teleportCorner = Instance.new("UICorner")
	teleportCorner.CornerRadius = UDim.new(0, 8)
	teleportCorner.Parent = teleportGui

	local shipBtn = createButton(teleportGui, "Board Ship", UDim2.fromOffset(144, 30), UDim2.fromOffset(8, 6))
	shipBtn.BackgroundColor3 = Color3.fromRGB(45, 90, 120)
	shipBtn.TextSize = 13
	shipBtn.MouseButton1Click:Connect(function()
		requestTeleportToShip:FireServer()
	end)

	local homeBtn = createButton(teleportGui, "Teleport Home", UDim2.fromOffset(144, 30), UDim2.fromOffset(8, 42))
	homeBtn.BackgroundColor3 = Color3.fromRGB(90, 55, 40)
	homeBtn.TextSize = 13
	homeBtn.MouseButton1Click:Connect(function()
		requestTeleportHome:FireServer()
	end)
end

local function rebuildBoatButtons()
	local host = ui.boatsHost
	if not host then
		return
	end

	for _, child in ipairs(host:GetChildren()) do
		child:Destroy()
	end
	boatButtons = {}

	local catalog = config.boatCatalog or {}
	if #catalog == 0 then
		return
	end
	local width = math.floor((270 - ((#catalog - 1) * 6)) / #catalog)

	for i, boat in ipairs(catalog) do
		local button = createButton(
			host,
			string.format("%s | $%d / %d", boat.displayName or boat.boatTypeId, boat.dispatchFee or 0, boat.capacity or 0),
			UDim2.fromOffset(width, 40),
			UDim2.fromOffset((i - 1) * (width + 6), 0)
		)
		button.TextSize = 10
		button.MouseButton1Click:Connect(function()
			selectedBoatTypeId = boat.boatTypeId
			updateUi()
		end)
		boatButtons[boat.boatTypeId] = button
	end

	if not selectedBoatTypeId then
		selectedBoatTypeId = catalog[1].boatTypeId
	end
end

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

buildUi()
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
rebuildBoatButtons()
updateUi()

player:GetAttributeChangedSignal("PlotId"):Connect(function()
	bindOwnedPlot()
	updateUi()
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

shipmentVisualEvent.OnClientEvent:Connect(function(packet)
	if typeof(packet) ~= "table" then
		return
	end
	local kind = packet.type
	local data = packet.data
	if typeof(data) ~= "table" then
		return
	end
	if data.ownerUserId ~= player.UserId then
		return
	end

	if kind == "ShipmentStarted" then
		setStatus(string.format("Shipment out: %s (%d barrels)", tostring(data.boatTypeId), tonumber(data.loaded) or 0), true)
	elseif kind == "ShipmentEvent" then
		setStatus(string.format("Shipment hit: -%d hull", tonumber(data.damage) or 0), false)
	elseif kind == "ShipmentResolved" then
		setStatus(
			string.format(
				"Shipment done. Delivered %d, lost %d, payout $%d",
				tonumber(data.delivered) or 0,
				tonumber(data.lost) or 0,
				tonumber(data.payout) or 0
			),
			true
		)
	end
end)

RunService.RenderStepped:Connect(function()
	local equipped = getEquippedToolName()
	if ui.hintLabel then
		if equipped == TOOL_DRILL then
			ui.hintLabel.Text = string.format("Drill equipped: Click an owned chunk ($%d).", config.drillPlacementCost or 200)
		elseif equipped == TOOL_PIPE then
			ui.hintLabel.Text = string.format("Pipe equipped: click a grid cell ($%d). Hold E on a pipe to remove.", config.pipeCost or 50)
		else
			ui.hintLabel.Text = string.format("Hands empty: Hold E %.1fs on a drill to remove. E on a pipe to delete.", config.removeDrillHoldSeconds or 2)
		end
	end

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

print("[Client] Chunked plot mode active.")
