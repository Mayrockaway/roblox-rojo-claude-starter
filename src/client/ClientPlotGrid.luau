--!strict
--[[
	ClientPlotGrid — extracted from init.client.luau
	Singleton module holding plot/grid state, cell-grid helpers, prompt wiring,
	and status-line display for the oil gameplay HUD.

	Usage:
		local ClientPlotGrid = require(resolveClientModule(script, "ClientPlotGrid"))
		ClientPlotGrid.init({ ... })
]]

local RunService = game:GetService("RunService")

-- ===================== types =====================
export type InitParams = {
	player: Player,
	playerGui: PlayerGui,
	Workspace: Workspace,
	ReplicatedStorage: ReplicatedStorage,
	Constants: any,
	OilConfig: any,
	mouse: Mouse,
	requestBuyChunk: RemoteEvent,
	oilActionResult: RemoteEvent,
}

-- ===================== module table =====================
local M = {}

-- ===================== upvalues (set by init) =====================
local player: Player
local playerGui: PlayerGui
local _Workspace: Workspace
local _ReplicatedStorage: ReplicatedStorage
local Constants: any
local OilConfig: any
local mouse: Mouse
local requestBuyChunk: RemoteEvent
local oilActionResult: RemoteEvent

-- ===================== state =====================
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

local promptConnections = {}
local _wiredPromptSet: { [ProximityPrompt]: true } = {}

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
	local map = _Workspace:FindFirstChild("Map")
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
			tostring(_Workspace.Map and _Workspace.Map:FindFirstChild("Plots") ~= nil),
			(_Workspace.Map and _Workspace.Map:FindFirstChild("Plots")) and tostring(#_Workspace.Map.Plots:GetChildren()) or "?"))
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

-- ===================== init =====================
function M.init(params: InitParams)
	player = params.player
	playerGui = params.playerGui
	_Workspace = params.Workspace
	_ReplicatedStorage = params.ReplicatedStorage
	Constants = params.Constants
	OilConfig = params.OilConfig
	mouse = params.mouse
	requestBuyChunk = params.requestBuyChunk
	oilActionResult = params.oilActionResult
end

-- ===================== getters =====================
function M.getState()
	return state
end

function M.getConfig(): { [string]: any }
	return config :: { [string]: any }
end

function M.getOwnedPlot(): Model?
	return ownedPlot
end

function M.getChunkPartById(): { [string]: any }
	return chunkPartById
end

function M.getChunkStateById(): { [string]: any }
	return chunkStateById
end

function M.getDrillStateById(): { [string]: any }
	return drillStateById
end

function M.getPipeStateByCellKey(): { [string]: any }
	return pipeStateByCellKey
end

function M.getDrumStateByCellKey(): { [string]: any }
	return drumStateByCellKey
end

-- ===================== setters =====================
function M.setState(newState: any)
	state = newState
end

function M.setConfig(newConfig: any)
	-- Merge new keys into existing config so callers that captured a reference still see defaults
	for k, v in pairs(newConfig) do
		(config :: any)[k] = v
	end
end

function M.setOwnedPlot(plot: Model?)
	ownedPlot = plot
end

-- ===================== cache =====================
function M.invalidatePlotGridCache()
	_clientGridCache = nil
end

-- ===================== exported helpers =====================
M.plotGridConstants = plotGridConstants
M.cellKeyOf = cellKeyOf
M.readLocalFtueCellKey = readLocalFtueCellKey
M.clientWorldToCell = clientWorldToCell
M.clientCellToWorld = clientCellToWorld
M.clientCellInBounds = clientCellInBounds
M.setStatus = setStatus
M.getEquippedToolName = getEquippedToolName
M.getEquippedToolInfo = getEquippedToolInfo
M.getOwnedPlotByAttribute = getOwnedPlotByAttribute
M.rebuildStateMaps = rebuildStateMaps
M.disconnectPromptConnections = disconnectPromptConnections
M.wireBuyPrompt = wireBuyPrompt
M.bindPromptsForOwnedPlot = bindPromptsForOwnedPlot
M.bindOwnedPlot = bindOwnedPlot
M.SUB_TILE_SIZE = SUB_TILE_SIZE

return M
