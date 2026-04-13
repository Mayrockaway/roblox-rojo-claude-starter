--!strict

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local OilConfig = require(Shared:WaitForChild("Config"):WaitForChild("OilConfig"))
local BiomeConfig = require(Shared:WaitForChild("Config"):WaitForChild("BiomeConfig"))
local BoatConfig = require(Shared:WaitForChild("Config"):WaitForChild("BoatConfig"))
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))

local OilStateService = {}

local SAVE_INTERVAL_SECONDS = 20
local DATASTORE_NAME = "OilMiningProfiles_v3"

local TIER_ORDER = {
	"HeavyCrude",
	"StandardCrude",
	"LightSweet",
	"PremiumRefined",
}

local function floorPositive(value: number): number
	return math.max(0, math.floor(value))
end

local function getPlotId(plot: Instance): number
	local plotId = plot:GetAttribute("PlotId")
	if typeof(plotId) == "number" then
		return plotId
	end
	local parsed = tonumber(string.match(plot.Name, "(%d+)"))
	return parsed or 0
end

local function copyTierMap(source)
	return {
		HeavyCrude = source.HeavyCrude or 0,
		StandardCrude = source.StandardCrude or 0,
		LightSweet = source.LightSweet or 0,
		PremiumRefined = source.PremiumRefined or 0,
	}
end

local function sumTierMap(source): number
	local total = 0
	for _, tier in ipairs(TIER_ORDER) do
		total += floorPositive(source[tier] or 0)
	end
	return total
end

local function buildDefaultPersisted()
	return {
		version = 3,
		cash = OilConfig.StartingCash,
		storageCapacity = OilConfig.StartingStorageCapacity,
		oilByTier = {
			HeavyCrude = 0,
			StandardCrude = 0,
			LightSweet = 0,
			PremiumRefined = 0,
		},
		unlockedChunkIds = {},
		drills = {},
		pipes = {},
		drums = {},
		nextDrillId = 1,
		nextPipeId = 1,
		nextDrumId = 1,
		nextAttachmentId = 1,
		selectedBoatTypeId = "RustSkiff",
	}
end

local function emptyTierMap()
	return {
		HeavyCrude = 0,
		StandardCrude = 0,
		LightSweet = 0,
		PremiumRefined = 0,
	}
end

-- =================== CELL GRID HELPERS ===================
-- The plot is 3x4 sections of 5x5 sub-tiles each = 15x20 sub-tiles globally.
-- Sub-tile size = 8 studs. Plot center = (-840, -1020).
-- Section grid origin (top-left section center) = startX/startZ.
-- Sub-tile (1,1) of the top-left section is at:
--   x = startX - 16 = -880 - 16 = -896
--   z = startZ - 16 = -1080 - 16 = -1096

local SUB_TILE_SIZE = 8

-- Computed once at runtime from actual plot position. Falls back to hardcoded if plot not found.
local _cachedGridConstants = nil

local function plotGridConstants()
	if _cachedGridConstants then return _cachedGridConstants end

	local sectionCols = OilConfig.Chunks.GridCols -- 3
	local sectionRows = OilConfig.Chunks.GridRows -- 4
	local sectionSize = OilConfig.Chunks.Size     -- 40
	local subTilesPerSide = math.floor(sectionSize / SUB_TILE_SIZE) -- 5

	-- Derive center from actual Plot_01 section attributes instead of hardcoding
	local centerX, centerZ = -840, -1020
	local Workspace = game:GetService("Workspace")
	local map = Workspace:FindFirstChild("Map")
	local plots = map and map:FindFirstChild("Plots")
	local plot = plots and plots:FindFirstChild("Plot_01")
	local ground = plot and plot:FindFirstChild("PlotGround")
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

	local startX = centerX - ((sectionCols - 1) / 2) * sectionSize
	local startZ = centerZ - ((sectionRows - 1) / 2) * sectionSize
	local cellOriginX = startX - ((subTilesPerSide - 1) / 2) * SUB_TILE_SIZE
	local cellOriginZ = startZ - ((subTilesPerSide - 1) / 2) * SUB_TILE_SIZE
	local globalCols = sectionCols * subTilesPerSide
	local globalRows = sectionRows * subTilesPerSide

	_cachedGridConstants = {
		sectionCols = sectionCols,
		sectionRows = sectionRows,
		sectionSize = sectionSize,
		subTilesPerSide = subTilesPerSide,
		cellOriginX = cellOriginX,
		cellOriginZ = cellOriginZ,
		globalCols = globalCols,
		globalRows = globalRows,
	}
	return _cachedGridConstants
end

local function cellKey(globalRow: number, globalCol: number): string
	return string.format("R%dC%d", globalRow, globalCol)
end

local function worldToCell(x: number, z: number): (number, number)
	local g = plotGridConstants()
	local col = math.floor((x - g.cellOriginX) / SUB_TILE_SIZE + 0.5) + 1
	local row = math.floor((z - g.cellOriginZ) / SUB_TILE_SIZE + 0.5) + 1
	return row, col
end

local function cellToWorld(row: number, col: number): (number, number)
	local g = plotGridConstants()
	local x = g.cellOriginX + (col - 1) * SUB_TILE_SIZE
	local z = g.cellOriginZ + (row - 1) * SUB_TILE_SIZE
	return x, z
end

local function cellToSectionId(row: number, col: number): string
	local g = plotGridConstants()
	local sRow = math.floor((row - 1) / g.subTilesPerSide) + 1
	local sCol = math.floor((col - 1) / g.subTilesPerSide) + 1
	return string.format("S%02d_%02d", sRow, sCol)
end

local function cellInBounds(row: number, col: number): boolean
	local g = plotGridConstants()
	return row >= 1 and row <= g.globalRows and col >= 1 and col <= g.globalCols
end

local function tierMapIsFull(map, capacity: number): boolean
	for _, tier in ipairs(TIER_ORDER) do
		if (map[tier] or 0) < capacity then
			return false
		end
	end
	return true
end

local function isStartingChunk(row: number, col: number): boolean
	return row == OilConfig.Chunks.StartingRow and col == OilConfig.Chunks.StartingCol
end

local function chebyshevFromCenter(row: number, col: number): number
	local rd = math.abs(row - OilConfig.Chunks.StartingRow)
	local cd = math.abs(col - OilConfig.Chunks.StartingCol)
	return math.max(rd, cd)
end

function OilStateService:Init(remoteService, plotService)
	self._remoteService = remoteService
	self._plotService = plotService
	self._statesByUserId = {}
	self._connections = {}
	self._stateChangedEvent = Instance.new("BindableEvent")
	self._dirtyByUserId = {}
	self._memoryStore = {}
	self._running = false
	self._autosaveThread = nil
	self._memoryOnly = RunService:IsStudio()

	if self._memoryOnly then
		self._dataStore = nil
	else
		local ok, storeOrErr = pcall(function()
			return DataStoreService:GetDataStore(DATASTORE_NAME)
		end)
		if ok then
			self._dataStore = storeOrErr
		else
			self._dataStore = nil
			warn("[OilStateService] DataStore unavailable, using memory fallback:", storeOrErr)
		end
	end
end

function OilStateService:Start()
	self._running = true

	table.insert(self._connections, self._plotService:OnPlotAssigned(function(userId: number, plot: Model)
		self:_ensurePlayerState(userId, plot)
		self:PushState(userId)
	end))

	table.insert(self._connections, self._plotService:OnPlotReleased(function(userId: number, _plot: Model)
		self:_flushAndDropUser(userId)
	end))

	table.insert(self._connections, Players.PlayerRemoving:Connect(function(player)
		self:_flushAndDropUser(player.UserId)
	end))

	self._autosaveThread = task.spawn(function()
		while self._running do
			task.wait(SAVE_INTERVAL_SECONDS)
			self:_flushDirtyUsers()
		end
	end)

	for _, player in ipairs(Players:GetPlayers()) do
		local plot = self._plotService:GetOwnedPlot(player.UserId)
		if plot then
			self:_ensurePlayerState(player.UserId, plot)
			self:PushState(player.UserId)
		end
	end
end

function OilStateService:Stop()
	self._running = false
	self:_flushDirtyUsers()

	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	self._connections = {}
	if self._stateChangedEvent then
		self._stateChangedEvent:Destroy()
		self._stateChangedEvent = nil
	end
	self._statesByUserId = {}
	self._dirtyByUserId = {}
end

function OilStateService:OnStateChanged(callback)
	assert(self._stateChangedEvent ~= nil, "OilStateService not initialized.")
	return self._stateChangedEvent.Event:Connect(callback)
end

function OilStateService:GetState(userId: number)
	return self._statesByUserId[userId]
end

local function maxActiveDrillsFor(state): number
	local owned = 0
	for _, chunk in pairs(state.chunksById) do
		if chunk.unlocked then
			owned += 1
		end
	end
	local computed = math.floor(OilConfig.BaseMaxActiveDrills + owned * OilConfig.DrillsPerOwnedChunk)
	return math.clamp(computed, OilConfig.BaseMaxActiveDrills, OilConfig.HardMaxActiveDrills)
end

local function chunkUnlockCost(row: number, col: number): number
	local dist = chebyshevFromCenter(row, col)
	if dist <= 0 then
		return 0
	end
	return floorPositive(OilConfig.ChunkUnlockBaseCost * (1 + (dist - 1) * OilConfig.ChunkUnlockDistanceMultiplier))
end

local function hasUnlockedNeighbor(state, row: number, col: number): boolean
	local deltas = { {1,0}, {-1,0}, {0,1}, {0,-1} }
	for _, d in ipairs(deltas) do
		local rr, cc = row + d[1], col + d[2]
		for _, c in pairs(state.chunksById) do
			if c.unlocked and c.row == rr and c.col == cc then
				return true
			end
		end
	end
	return false
end

function OilStateService:GetStateForClient(userId: number)
	local state = self._statesByUserId[userId]
	if not state then
		return nil
	end

	local chunks = {}
	for _, chunk in pairs(state.chunksById) do
		local entry = {
			chunkId = chunk.chunkId,
			row = chunk.row,
			col = chunk.col,
			biome = chunk.biome,
			unlocked = chunk.unlocked,
			revealed = chunk.revealed or false,
			worldX = chunk.worldX,
			worldZ = chunk.worldZ,
			tiles = chunk.tiles, -- per-tile oil types + obstacles (nil if not revealed)
		}
		if not chunk.unlocked then
			entry.cost = chunkUnlockCost(chunk.row, chunk.col)
			entry.canBuy = hasUnlockedNeighbor(state, chunk.row, chunk.col)
		end
		table.insert(chunks, entry)
	end

	local drills = {}
	local stalledCount = 0
	for _, drill in pairs(state.drillsById) do
		local bufferTotal = 0
		if drill.localBuffer then
			for _, tier in ipairs(TIER_ORDER) do
				bufferTotal += drill.localBuffer[tier] or 0
			end
		end
		local stalled = (not drill.connected) and bufferTotal >= ((OilConfig.DrillBufferCapacity or 20) * #TIER_ORDER)
		if stalled then
			stalledCount += 1
		end
		table.insert(drills, {
			drillId = drill.drillId,
			chunkId = drill.chunkId,
			biome = drill.biome,
			template = drill.template or OilConfig.DefaultDrillTemplate,
			scale = drill.scale or 1,
			position = { x = drill.position.X, y = drill.position.Y, z = drill.position.Z },
			connected = drill.connected == true,
			cellKey = drill.cellKey,
			cellRow = drill.cellRow,
			cellCol = drill.cellCol,
			bufferTotal = bufferTotal,
			bufferCap = (OilConfig.DrillBufferCapacity or 20) * #TIER_ORDER,
		})
	end

	local pipes = {}
	for _, pipe in pairs(state.pipesByCellKey) do
		table.insert(pipes, {
			pipeId = pipe.pipeId,
			cellKey = pipe.cellKey,
			row = pipe.row,
			col = pipe.col,
			sectionId = pipe.sectionId,
			position = { x = pipe.position.X, y = pipe.position.Y, z = pipe.position.Z },
		})
	end

	local drums = {}
	for _, drum in pairs(state.drumsById) do
		table.insert(drums, {
			drumId = drum.drumId,
			position = { x = drum.position.X, y = drum.position.Y, z = drum.position.Z },
			cellKey = drum.cellKey,
			row = drum.row,
			col = drum.col,
		})
	end

	return {
		plotId = state.plotId,
		cash = state.cash,
		totalOil = state.totalOil,
		storageCapacity = state.storageCapacity,
		oilByTier = copyTierMap(state.oilByTier),
		activeDrillCount = state.activeDrillCount,
		stalledDrillCount = stalledCount,
		maxActiveDrills = maxActiveDrillsFor(state),
		activeShipmentCount = state.activeShipmentCount,
		selectedBoatTypeId = state.selectedBoatTypeId or "RustSkiff",
		chunks = chunks,
		drills = drills,
		pipes = pipes,
		drums = drums,
		chunkConfig = {
			size = OilConfig.Chunks.Size,
			rows = OilConfig.Chunks.GridRows,
			cols = OilConfig.Chunks.GridCols,
			startingCenterSize = OilConfig.Chunks.StartingCenterSize,
		},
		pipeConfig = {
			cost = OilConfig.Pipes.Cost,
			minLength = OilConfig.Pipes.MinLength,
			maxLength = OilConfig.Pipes.MaxLength,
			snapRadius = OilConfig.Pipes.EndpointSnapRadius,
		},
	}
end

function OilStateService:PushState(userId: number)
	local snapshot = self:GetStateForClient(userId)
	if self._stateChangedEvent and snapshot then
		self._stateChangedEvent:Fire(userId, snapshot)
	end

	local player = Players:GetPlayerByUserId(userId)
	if not player or not snapshot then
		return
	end
	local event = self._remoteService:GetEvent(RemoteNames.OilStateUpdate)
	event:FireClient(player, snapshot)
end

function OilStateService:TrySpendCash(userId: number, amount: number): boolean
	local state = self._statesByUserId[userId]
	if not state then
		return false
	end
	local cost = floorPositive(amount)
	if state.cash < cost then
		return false
	end
	state.cash -= cost
	self:_markDirty(userId)
	return true
end

function OilStateService:AddCash(userId: number, amount: number): boolean
	local state = self._statesByUserId[userId]
	if not state then
		return false
	end
	local value = floorPositive(amount)
	if value <= 0 then
		return true
	end
	state.cash += value
	self:_markDirty(userId)
	return true
end

function OilStateService:TryBuyChunk(userId: number, chunkId: string): (boolean, string, string)
	local state = self._statesByUserId[userId]
	if not state then
		return false, "ERR_NO_STATE", "State unavailable."
	end
	local chunk = state.chunksById[chunkId]
	if not chunk then
		return false, "ERR_BAD_CHUNK", "Chunk does not exist."
	end
	if chunk.unlocked then
		return false, "ERR_ALREADY_UNLOCKED", "Chunk already unlocked."
	end
	if not hasUnlockedNeighbor(state, chunk.row, chunk.col) then
		return false, "ERR_NOT_ADJACENT", "You can only buy a chunk next to one you already own."
	end
	local cost = chunkUnlockCost(chunk.row, chunk.col)
	if not self:TrySpendCash(userId, cost) then
		return false, "ERR_NOT_ENOUGH_CASH", string.format("Need $%d to buy this chunk.", cost)
	end

	-- Roll a random biome
	local rng = Random.new(userId * 97 + chunk.row * 31 + chunk.col * 17 + math.floor(workspace:GetServerTimeNow() * 1000))
	local biomeName = BiomeConfig.RollBiome(rng)
	chunk.unlocked = true
	chunk.biome = biomeName
	chunk.revealed = false -- stays hidden until slot machine animation finishes

	-- Generate per-tile oil types + obstacles for the 5x5 sub-tiles
	local g = plotGridConstants()
	local subTiles = g.subTilesPerSide
	chunk.tiles = {}

	-- First pass: assign tile types (each defines oil type + visual) to all tiles
	local premiumTileKeys = {}
	for tr = 1, subTiles do
		for tc = 1, subTiles do
			local tileKey = string.format("T%d%d", tr, tc)
			local tileType = BiomeConfig.RollTileType(biomeName, rng)
			chunk.tiles[tileKey] = {
				oilType = tileType.oilType,
				tileName = tileType.name,
				tileMaterial = tileType.material.Name, -- store as string for persistence
				tileColorR = math.floor(tileType.color.R * 255),
				tileColorG = math.floor(tileType.color.G * 255),
				tileColorB = math.floor(tileType.color.B * 255),
				hasObstacle = false,
				obstacleType = nil,
			}
			-- Track premium tiles for obstacle bias
			if tileType.oilType == "PremiumRefined" or tileType.oilType == "LightSweet" then
				table.insert(premiumTileKeys, tileKey)
			end
		end
	end

	-- Second pass: place obstacles, biased toward blocking premium tiles
	local biomeData = BiomeConfig.Biomes[biomeName]
	local obstacleRate = biomeData and biomeData.obstacleRate or 0.18
	local totalTiles = subTiles * subTiles
	local obstacleCount = math.floor(totalTiles * obstacleRate + 0.5)

	-- Prioritize placing obstacles NEAR premium tiles
	local placed = 0
	local usedKeys = {}

	-- Place some obstacles adjacent to premium tiles first (the "pain in the ass" spots)
	for _, pKey in ipairs(premiumTileKeys) do
		if placed >= obstacleCount then break end
		local pr = tonumber(string.sub(pKey, 2, 2))
		local pc = tonumber(string.sub(pKey, 3, 3))
		if pr and pc then
			local adjacents = {
				string.format("T%d%d", pr - 1, pc),
				string.format("T%d%d", pr + 1, pc),
				string.format("T%d%d", pr, pc - 1),
				string.format("T%d%d", pr, pc + 1),
			}
			for _, adjKey in ipairs(adjacents) do
				if placed >= obstacleCount then break end
				if chunk.tiles[adjKey] and not usedKeys[adjKey] and not chunk.tiles[adjKey].hasObstacle then
					-- Don't block the premium tile itself, block its neighbor
					if adjKey ~= pKey then
						local obstType = BiomeConfig.RollObstacleType(biomeName, rng)
						chunk.tiles[adjKey].hasObstacle = true
						chunk.tiles[adjKey].obstacleType = obstType
						usedKeys[adjKey] = true
						placed += 1
					end
				end
			end
		end
	end

	-- Fill remaining obstacle quota with random tiles
	local allTileKeys = {}
	for tr = 1, subTiles do
		for tc = 1, subTiles do
			table.insert(allTileKeys, string.format("T%d%d", tr, tc))
		end
	end
	-- Shuffle
	for i = #allTileKeys, 2, -1 do
		local j = rng:NextInteger(1, i)
		allTileKeys[i], allTileKeys[j] = allTileKeys[j], allTileKeys[i]
	end
	for _, tKey in ipairs(allTileKeys) do
		if placed >= obstacleCount then break end
		if chunk.tiles[tKey] and not usedKeys[tKey] and not chunk.tiles[tKey].hasObstacle then
			local obstType = BiomeConfig.RollObstacleType(biomeName, rng)
			chunk.tiles[tKey].hasObstacle = true
			chunk.tiles[tKey].obstacleType = obstType
			usedKeys[tKey] = true
			placed += 1
		end
	end

	self:_markDirty(userId)

	-- Fire biome reveal event to client for slot machine animation
	local player = Players:GetPlayerByUserId(userId)
	if player then
		local revealEvent = self._remoteService:GetEvent(RemoteNames.BiomeRevealEvent)
		revealEvent:FireClient(player, {
			chunkId = chunkId,
			biome = biomeName,
			tiles = chunk.tiles,
		})
	end

	-- Delay reveal so the slot machine animation plays first
	task.delay(3, function()
		local currentState = self._statesByUserId[userId]
		if currentState then
			local currentChunk = currentState.chunksById[chunkId]
			if currentChunk then
				currentChunk.revealed = true
				self:_markDirty(userId)
				self:PushState(userId)
			end
		end
	end)

	return true, "OK", string.format("%s Discovered!", biomeData and biomeData.displayName or biomeName)
end

function OilStateService:TryClearObstacle(userId: number, chunkId: string, tileKey: string): (boolean, string, string)
	local state = self._statesByUserId[userId]
	if not state then
		return false, "ERR_NO_STATE", "State unavailable."
	end
	local chunk = state.chunksById[chunkId]
	if not chunk or not chunk.unlocked then
		return false, "ERR_BAD_CHUNK", "Chunk not owned."
	end
	if not chunk.tiles or not chunk.tiles[tileKey] then
		return false, "ERR_BAD_TILE", "Tile does not exist."
	end
	local tile = chunk.tiles[tileKey]
	if not tile.hasObstacle then
		return false, "ERR_NO_OBSTACLE", "No obstacle on this tile."
	end

	local biomeName = chunk.biome or "Dustlands"
	local cost = BiomeConfig.GetObstacleCost(biomeName, tile.obstacleType or "Rock")
	if not self:TrySpendCash(userId, cost) then
		return false, "ERR_NOT_ENOUGH_CASH", string.format("Need $%d to clear this obstacle.", cost)
	end

	tile.hasObstacle = false
	tile.obstacleType = nil
	self:_markDirty(userId)
	return true, "OK", "Obstacle cleared."
end

local function pointInsideChunk(chunk, x: number, z: number): boolean
	local size = OilConfig.Chunks.Size
	local half = size / 2
	return math.abs(x - chunk.worldX) <= half and math.abs(z - chunk.worldZ) <= half
end

local function distanceXZ(x1, z1, x2, z2): number
	local dx = x1 - x2
	local dz = z1 - z2
	return math.sqrt(dx * dx + dz * dz)
end

function OilStateService:TryPlaceDrill(userId: number, payload): (boolean, string, string, any)
	local state = self._statesByUserId[userId]
	if not state then
		return false, "ERR_NO_STATE", "State unavailable.", nil
	end
	if typeof(payload) ~= "table" then
		return false, "ERR_BAD_PAYLOAD", "Missing payload.", nil
	end
	local chunkId = payload.chunkId
	local x = tonumber(payload.x)
	local y = tonumber(payload.y)
	local z = tonumber(payload.z)
	if typeof(chunkId) ~= "string" or not x or not y or not z then
		return false, "ERR_BAD_PAYLOAD", "Bad drill payload.", nil
	end

	local chunk = state.chunksById[chunkId]
	if not chunk then
		return false, "ERR_BAD_CHUNK", "Chunk does not exist.", nil
	end
	if not chunk.unlocked then
		return false, "ERR_LOCKED_CHUNK", "Chunk is not unlocked.", nil
	end
	if not pointInsideChunk(chunk, x, z) then
		return false, "ERR_OUT_OF_CHUNK", "Drill position is not on the targeted chunk.", nil
	end

	-- Check tile for obstacles and pipe exclusivity
	local drillRow, drillCol = worldToCell(x, z)
	local drillCellKey = cellKey(drillRow, drillCol)

	-- Obstacle check: can't drill on a tile with an obstacle
	if chunk.tiles then
		-- Find which sub-tile within this section
		local g = plotGridConstants()
		local sRow = (chunk.row - 1) * g.subTilesPerSide
		local sCol = (chunk.col - 1) * g.subTilesPerSide
		local localR = drillRow - sRow
		local localC = drillCol - sCol
		local tileKey = string.format("T%d%d", localR, localC)
		local tile = chunk.tiles[tileKey]
		if tile and tile.hasObstacle then
			-- Water obstacles block drills permanently (pipes only)
			if BiomeConfig.IsPipesOnlyObstacle(tile.obstacleType or "") then
				return false, "ERR_WATER_TILE", "Can't drill on water. Pipes only.", nil
			end
			return false, "ERR_OBSTACLE", "Clear the obstacle first.", nil
		end
	end

	-- Pipe exclusivity: can't drill where a pipe already is
	if state.pipesByCellKey and state.pipesByCellKey[drillCellKey] then
		return false, "ERR_PIPE_HERE", "Remove the pipe first to place a drill.", nil
	end

	-- Snap Y to the chunk's actual tile surface (exclude obstacles, overlays, signs)
	local plot = self._plotService:GetOwnedPlot(userId)
	local sectionModel = plot and self._plotService:GetChunkModel(plot, chunkId)
	if sectionModel then
		local topY: number? = nil
		for _, d in ipairs(sectionModel:GetChildren()) do
			if d:IsA("BasePart") and d.Name:match("^T%d%d$") then
				local surface = d.Position.Y + d.Size.Y / 2
				if topY == nil or surface > topY then
					topY = surface
				end
			end
		end
		if topY then
			y = topY
		end
	end

	for _, existing in pairs(state.drillsById) do
		if distanceXZ(existing.position.X, existing.position.Z, x, z) < OilConfig.DrillMinSpacing then
			return false, "ERR_TOO_CLOSE", "Too close to another drill.", nil
		end
	end

	if state.activeDrillCount >= maxActiveDrillsFor(state) then
		return false, "ERR_MAX_DRILLS", "Max active drills reached.", nil
	end

	if not self:TrySpendCash(userId, OilConfig.DrillPlacementCost) then
		return false, "ERR_NOT_ENOUGH_CASH", "Not enough cash to place drill.", nil
	end

	local biomeConfig = OilConfig.Biomes[chunk.biome] or OilConfig.Biomes.Desert
	local drillId = state.nextDrillId
	state.nextDrillId += 1

	local template = OilConfig.DefaultDrillTemplate
	local roll = math.random()
	if roll < (OilConfig.GoldDrillChance or 0) then
		template = OilConfig.GoldDrillTemplate
	elseif roll < (OilConfig.GoldDrillChance or 0) + (OilConfig.RareDrillChance or 0) then
		template = OilConfig.RareDrillTemplate
	end

	local scaleMin = OilConfig.DrillScaleMin or 1
	local scaleMax = OilConfig.DrillScaleMax or 1
	local scale = scaleMin + math.random() * (scaleMax - scaleMin)

	-- Compute the drill's grid cell from its world position, then SNAP x/z to the cell center
	local cellRow, cellCol = worldToCell(x, z)

	-- Block placement on cells occupied by the Lab Machine (drum cells)
	for _, drum in pairs(state.drumsById) do
		if drum.cellKey == cellKey(cellRow, cellCol) then
			return false, "ERR_CELL_BLOCKED", "This cell is occupied by the refinery.", nil
		end
	end
	-- Also block cells marked as blocked around the drum (flanking + pipe cells)
	local blockedCells = state._blockedCells
	if blockedCells and blockedCells[cellKey(cellRow, cellCol)] then
		return false, "ERR_CELL_BLOCKED", "This cell is occupied by refinery infrastructure.", nil
	end

	local snappedX, snappedZ = cellToWorld(cellRow, cellCol)

	-- Determine the tile's oil type from the chunk's per-tile data
	local tileOilType = nil
	if chunk.tiles then
		local g = plotGridConstants()
		local sRow = (chunk.row - 1) * g.subTilesPerSide
		local sCol = (chunk.col - 1) * g.subTilesPerSide
		local localR = cellRow - sRow
		local localC = cellCol - sCol
		local tileKey = string.format("T%d%d", localR, localC)
		local tile = chunk.tiles[tileKey]
		if tile then
			tileOilType = tile.oilType
		end
	end

	local drill = {
		drillId = drillId,
		chunkId = chunkId,
		biome = chunk.biome,
		template = template,
		scale = scale,
		position = Vector3.new(snappedX, y, snappedZ),
		flowBase = OilConfig.DrillBaseFlow * biomeConfig.flowMul * scale,
		tierMix = copyTierMap(biomeConfig.tierMix),
		tileOilType = tileOilType, -- per-tile oil type (if available)
		cellKey = cellKey(cellRow, cellCol),
		cellRow = cellRow,
		cellCol = cellCol,
		localBuffer = emptyTierMap(),
		connected = false,
	}
	state.drillsById[drillId] = drill
	state.activeDrillCount += 1
	self:_markDirty(userId)
	return true, "OK", "Drill placed.", { drillId = drillId }
end

function OilStateService:TryRemoveDrill(userId: number, drillId: number): (boolean, string, string)
	local state = self._statesByUserId[userId]
	if not state then
		return false, "ERR_NO_STATE", "State unavailable."
	end
	local drill = state.drillsById[drillId]
	if not drill then
		return false, "ERR_BAD_DRILL", "Drill does not exist."
	end
	state.drillsById[drillId] = nil
	state.activeDrillCount = math.max(0, state.activeDrillCount - 1)
	self:_markDirty(userId)
	return true, "OK", "Drill removed."
end

function OilStateService:GetActiveDrills(userId: number)
	local state = self._statesByUserId[userId]
	if not state then
		return {}
	end
	local out = {}
	for _, drill in pairs(state.drillsById) do
		table.insert(out, drill)
	end
	return out
end

function OilStateService:TryPlacePipe(userId: number, payload): (boolean, string, string, any)
	local state = self._statesByUserId[userId]
	if not state then
		return false, "ERR_NO_STATE", "State unavailable.", nil
	end
	if typeof(payload) ~= "table" then
		return false, "ERR_BAD_PAYLOAD", "Missing payload.", nil
	end

	local row = tonumber(payload.row)
	local col = tonumber(payload.col)
	if not row or not col then
		-- Allow client to send world position; server snaps to grid
		local x = tonumber(payload.x)
		local z = tonumber(payload.z)
		if not x or not z then
			return false, "ERR_BAD_PAYLOAD", "Bad pipe payload.", nil
		end
		row, col = worldToCell(x, z)
	end

	if not cellInBounds(row, col) then
		return false, "ERR_OUT_OF_PLOT", "Pipe cell out of bounds.", nil
	end

	-- Section / chunk ownership
	local sectionId = cellToSectionId(row, col)
	local chunk = state.chunksById[sectionId]
	if not chunk or not chunk.unlocked then
		return false, "ERR_LOCKED_CHUNK", "Cell is on a locked section.", nil
	end

	-- One pipe per cell
	local key = cellKey(row, col)
	if state.pipesByCellKey[key] then
		return false, "ERR_CELL_OCCUPIED", "There is already a pipe here.", nil
	end

	-- Drill exclusivity: can't place pipe where a drill already is
	for _, drill in pairs(state.drillsById) do
		if drill.cellKey == key then
			return false, "ERR_DRILL_HERE", "Remove the drill first to place a pipe.", nil
		end
	end

	-- Obstacle check: can't place pipe on a tile with an obstacle UNLESS it's a pipes-only obstacle (Water)
	if chunk and chunk.tiles then
		local g = plotGridConstants()
		local sRow = (chunk.row - 1) * g.subTilesPerSide
		local sCol = (chunk.col - 1) * g.subTilesPerSide
		local localR = row - sRow
		local localC = col - sCol
		local tileKey = string.format("T%d%d", localR, localC)
		local tile = chunk.tiles[tileKey]
		if tile and tile.hasObstacle then
			if not BiomeConfig.IsPipesOnlyObstacle(tile.obstacleType or "") then
				return false, "ERR_OBSTACLE", "Clear the obstacle first.", nil
			end
			-- Water tiles: pipes allowed, drills blocked
		end
	end

	if not self:TrySpendCash(userId, OilConfig.Pipes.Cost or 0) then
		return false, "ERR_NOT_ENOUGH_CASH", "Not enough cash for pipe.", nil
	end

	local pipeId = state.nextPipeId
	state.nextPipeId += 1
	local x, z = cellToWorld(row, col)

	state.pipesByCellKey[key] = {
		pipeId = pipeId,
		cellKey = key,
		row = row,
		col = col,
		sectionId = sectionId,
		position = Vector3.new(x, 6, z),
	}

	self:_markDirty(userId)
	return true, "OK", "Pipe placed.", { pipeId = pipeId, cellKey = key, row = row, col = col }
end

function OilStateService:TryRemovePipe(userId: number, payload): (boolean, string, string)
	local state = self._statesByUserId[userId]
	if not state then
		return false, "ERR_NO_STATE", "State unavailable."
	end
	local row, col
	local key
	if typeof(payload) == "table" then
		if typeof(payload.cellKey) == "string" then
			key = payload.cellKey
		else
			row = tonumber(payload.row)
			col = tonumber(payload.col)
			if row and col then
				key = cellKey(row, col)
			elseif tonumber(payload.x) and tonumber(payload.z) then
				row, col = worldToCell(tonumber(payload.x), tonumber(payload.z))
				key = cellKey(row, col)
			end
		end
	end
	if not key then
		return false, "ERR_BAD_PAYLOAD", "Missing pipe cell."
	end
	if not state.pipesByCellKey[key] then
		return false, "ERR_BAD_PIPE", "Pipe does not exist."
	end
	state.pipesByCellKey[key] = nil
	self:_markDirty(userId)
	return true, "OK", "Pipe removed."
end

function OilStateService:GetDrillById(userId: number, drillId: number)
	local state = self._statesByUserId[userId]
	if not state then
		return nil
	end
	return state.drillsById[drillId]
end

function OilStateService:CanConsumeManifest(userId: number, manifest): (boolean, string, string, number)
	local state = self._statesByUserId[userId]
	if not state then
		return false, "ERR_NO_STATE", "State unavailable.", 0
	end
	if typeof(manifest) ~= "table" then
		return false, "ERR_BAD_PAYLOAD", "Manifest missing.", 0
	end

	local totalRequested = 0
	for _, tier in ipairs(TIER_ORDER) do
		local requested = floorPositive(tonumber(manifest[tier]) or 0)
		if requested > (state.oilByTier[tier] or 0) then
			return false, "ERR_NOT_ENOUGH_OIL", string.format("Not enough %s.", tier), 0
		end
		totalRequested += requested
	end

	if totalRequested <= 0 then
		return false, "ERR_EMPTY_MANIFEST", "Select at least 1 barrel.", 0
	end

	return true, "OK", "Manifest valid.", totalRequested
end

function OilStateService:ConsumeManifest(userId: number, manifest): boolean
	local state = self._statesByUserId[userId]
	if not state then
		return false
	end
	for _, tier in ipairs(TIER_ORDER) do
		local requested = floorPositive(tonumber(manifest[tier]) or 0)
		state.oilByTier[tier] = math.max(0, (state.oilByTier[tier] or 0) - requested)
	end
	state.totalOil = sumTierMap(state.oilByTier)
	self:_markDirty(userId)
	return true
end

function OilStateService:IncrementShipmentCount(userId: number)
	local state = self._statesByUserId[userId]
	if not state then
		return
	end
	state.activeShipmentCount = math.max(0, (state.activeShipmentCount or 0) + 1)
	self:_markDirty(userId)
end

function OilStateService:DecrementShipmentCount(userId: number)
	local state = self._statesByUserId[userId]
	if not state then
		return
	end
	state.activeShipmentCount = math.max(0, (state.activeShipmentCount or 0) - 1)
	self:_markDirty(userId)
end

function OilStateService:DrainDrillBuffer(userId: number, drillId: number): number
	local state = self._statesByUserId[userId]
	if not state then
		return 0
	end
	local drill = state.drillsById[drillId]
	if not drill or not drill.localBuffer then
		return 0
	end
	local space = state.storageCapacity - state.totalOil
	if space <= 0 then
		return 0
	end
	local drained = 0
	for _, tier in ipairs(TIER_ORDER) do
		if space <= 0 then break end
		local amt = floorPositive(drill.localBuffer[tier] or 0)
		local take = math.min(space, amt)
		if take > 0 then
			drill.localBuffer[tier] -= take
			state.oilByTier[tier] += take
			state.totalOil += take
			drained += take
			space -= take
		end
	end
	if drained > 0 then
		self:_markDirty(userId)
	end
	return drained
end

function OilStateService:AddToDrillBuffer(userId: number, drillId: number, additionsByTier): boolean
	local state = self._statesByUserId[userId]
	if not state then
		return false
	end
	local drill = state.drillsById[drillId]
	if not drill then
		return false
	end
	if not drill.localBuffer then
		drill.localBuffer = emptyTierMap()
	end
	local capacity = OilConfig.DrillBufferCapacity or 20
	for _, tier in ipairs(TIER_ORDER) do
		local current = drill.localBuffer[tier] or 0
		local incoming = additionsByTier[tier] or 0
		local newValue = math.min(capacity, current + incoming)
		drill.localBuffer[tier] = newValue
	end
	self:_markDirty(userId)
	return tierMapIsFull(drill.localBuffer, capacity)
end

function OilStateService:ApplyProduction(userId: number, additionsByTier): number
	local state = self._statesByUserId[userId]
	if not state then
		return 0
	end
	if state.totalOil >= state.storageCapacity then
		return 0
	end

	for _, tier in ipairs(TIER_ORDER) do
		state.pendingFloats[tier] += additionsByTier[tier] or 0
	end

	local integersToAdd = {}
	for _, tier in ipairs(TIER_ORDER) do
		integersToAdd[tier] = floorPositive(state.pendingFloats[tier])
		state.pendingFloats[tier] = state.pendingFloats[tier] - integersToAdd[tier]
	end

	local space = state.storageCapacity - state.totalOil
	local added = 0
	for _, tier in ipairs(TIER_ORDER) do
		if space <= 0 then
			break
		end
		local take = math.min(space, integersToAdd[tier])
		if take > 0 then
			state.oilByTier[tier] += take
			state.totalOil += take
			added += take
			space -= take
		end
	end

	if added > 0 then
		self:_markDirty(userId)
	end
	return added
end

function OilStateService:GetAllStates()
	return self._statesByUserId
end

function OilStateService:_ensurePlayerState(userId: number, plot: Model)
	if self._statesByUserId[userId] then
		return
	end

	local plotId = getPlotId(plot)
	local chunkDefs = self._plotService:GetPlotChunkDefinitions(plot)

	local chunksById = {}
	local startRng = Random.new(userId * 12345 + plotId)
	for _, def in ipairs(chunkDefs) do
		local chunkData = {
			chunkId = def.chunkId,
			row = def.row,
			col = def.col,
			biome = def.biome,
			unlocked = def.startingChunk,
			revealed = def.startingChunk,
			worldX = def.worldX,
			worldZ = def.worldZ,
		}

		-- Starting chunk gets a guaranteed Dustlands biome with tiles (so the player can start playing)
		if def.startingChunk then
			chunkData.biome = "DustyDesert"
			chunkData.revealed = true
			chunkData.tiles = {}
			local g = plotGridConstants()
			local subTiles = g.subTilesPerSide
			for tr = 1, subTiles do
				for tc = 1, subTiles do
					local tileKey = string.format("T%d%d", tr, tc)
					local tileType = BiomeConfig.RollTileType("DustyDesert", startRng)
					chunkData.tiles[tileKey] = {
						oilType = tileType.oilType,
						tileName = tileType.name,
						tileMaterial = tileType.material.Name,
						tileColorR = math.floor(tileType.color.R * 255),
						tileColorG = math.floor(tileType.color.G * 255),
						tileColorB = math.floor(tileType.color.B * 255),
						hasObstacle = false,
						obstacleType = nil,
					}
				end
			end
		end

		chunksById[def.chunkId] = chunkData
	end

	local state = {
		ownerUserId = userId,
		plotId = plotId,
		cash = OilConfig.StartingCash,
		storageCapacity = OilConfig.StartingStorageCapacity,
		totalOil = 0,
		oilByTier = {
			HeavyCrude = 0,
			StandardCrude = 0,
			LightSweet = 0,
			PremiumRefined = 0,
		},
		pendingFloats = {
			HeavyCrude = 0,
			StandardCrude = 0,
			LightSweet = 0,
			PremiumRefined = 0,
		},
		activeShipmentCount = 0,
		selectedBoatTypeId = "RustSkiff",
		chunksById = chunksById,
		drillsById = {},
		pipesByCellKey = {},
		drumsById = {},
		nextDrillId = 1,
		nextPipeId = 1,
		nextDrumId = 1,
		activeDrillCount = 0,
	}

	local persisted = self:_loadPersistedProfile(userId)
	if persisted then
		self:_applyPersistedIntoState(state, persisted)
	end

	self:_ensureDefaultDrumForPlayer(state, plot)
	self:_ensureDefaultPipesForPlayer(state)

	self._statesByUserId[userId] = state

	-- Force a deferred visual refresh so biome tiles + fog get applied after state is fully set
	task.defer(function()
		self:PushState(userId)
	end)
end

function OilStateService:_ensureDefaultPipesForPlayer(state)
	-- Only place default pipes if the player has none
	for _, _ in pairs(state.pipesByCellKey) do
		return
	end

	-- The drum occupies cell (20, 8) = center of front 3 tiles.
	-- Block cells (20,7), (20,8), (20,9) for drill placement (Lab Machine footprint).
	-- Pre-place pipes in a ring around the machine: row 19 cols 7-9 (behind/north)
	-- and row 20 cols 6 and 10 (flanking east/west).
	local drumRow = state.drumsById and nil
	local drumCol = nil
	for _, drum in pairs(state.drumsById) do
		drumRow = drum.row
		drumCol = drum.col
		break
	end
	if not drumRow then return end

	-- Blocked cells = the 3 tiles the Lab Machine occupies
	state._blockedCells = {}
	for dc = -1, 1 do
		state._blockedCells[cellKey(drumRow, drumCol + dc)] = true
	end

	-- Pre-place 3 pipes:  P1(left) XXX P2(right)  with P3(center above)
	local pipeCells = {
		{ drumRow, drumCol - 2 },      -- P1: left of machine
		{ drumRow, drumCol + 2 },      -- P2: right of machine
		{ drumRow - 1, drumCol },       -- P3: center above machine
	}

	for _, coords in ipairs(pipeCells) do
		local row, col = coords[1], coords[2]
		if cellInBounds(row, col) then
			local key = cellKey(row, col)
			if not state.pipesByCellKey[key] then
				local sectionId = cellToSectionId(row, col)
				local chunk = state.chunksById[sectionId]
				if chunk and chunk.unlocked then
					local x, z = cellToWorld(row, col)
					state.pipesByCellKey[key] = {
						pipeId = state.nextPipeId,
						cellKey = key,
						row = row,
						col = col,
						sectionId = sectionId,
						position = Vector3.new(x, 6, z),
					}
					state.nextPipeId += 1
				end
			end
		end
	end
end

function OilStateService:_ensureDefaultDrumForPlayer(state, plot: Model)
	-- Only create one default drum if the player has none
	for _, _ in pairs(state.drumsById) do
		return
	end

	-- Pick a sub-tile cell in the starting section's south edge as the drum's grid cell.
	-- Starting section = (StartingRow, StartingCol). Drum sits in the south-edge cell of the
	-- starting section's bottom row, slightly outside the section if there's room.
	local startSectionRow = OilConfig.Chunks.StartingRow
	local startSectionCol = OilConfig.Chunks.StartingCol
	local g = plotGridConstants()
	-- Bottom-center sub-tile of the starting section
	local row = (startSectionRow - 1) * g.subTilesPerSide + g.subTilesPerSide
	local col = (startSectionCol - 1) * g.subTilesPerSide + math.ceil(g.subTilesPerSide / 2)
	local x, z = cellToWorld(row, col)
	local drumPos = Vector3.new(x, 6, z)

	local drumId = state.nextDrumId
	state.nextDrumId += 1
	local key = cellKey(row, col)
	state.drumsById[drumId] = {
		drumId = drumId,
		position = drumPos,
		cellKey = key,
		row = row,
		col = col,
	}
end

function OilStateService:_applyPersistedIntoState(state, persisted)
	if typeof(persisted) ~= "table" then
		return
	end
	if (persisted.version or 1) < 2 then
		-- v1 was the cell/grade era; treat as fresh start but keep cash if present
		if typeof(persisted.cash) == "number" then
			state.cash = floorPositive(persisted.cash)
		end
		return
	end

	if typeof(persisted.cash) == "number" then
		state.cash = floorPositive(persisted.cash)
	end
	if typeof(persisted.storageCapacity) == "number" then
		state.storageCapacity = math.max(1, floorPositive(persisted.storageCapacity))
	end
	if typeof(persisted.oilByTier) == "table" then
		for _, tier in ipairs(TIER_ORDER) do
			local value = persisted.oilByTier[tier]
			if typeof(value) == "number" then
				state.oilByTier[tier] = floorPositive(value)
			end
		end
	end

	if typeof(persisted.selectedBoatTypeId) == "string" and BoatConfig.Boats[persisted.selectedBoatTypeId] then
		state.selectedBoatTypeId = persisted.selectedBoatTypeId
	end

	if typeof(persisted.unlockedChunkIds) == "table" then
		for chunkId, isUnlocked in pairs(persisted.unlockedChunkIds) do
			local chunk = state.chunksById[chunkId]
			if chunk and isUnlocked == true then
				chunk.unlocked = true
				chunk.revealed = true
				-- Restore biome
				if typeof(persisted.chunkBiomes) == "table" and typeof(persisted.chunkBiomes[chunkId]) == "string" then
					chunk.biome = persisted.chunkBiomes[chunkId]
				end
				-- Restore per-tile data
				if typeof(persisted.chunkTiles) == "table" and typeof(persisted.chunkTiles[chunkId]) == "table" then
					chunk.tiles = persisted.chunkTiles[chunkId]
				end
			end
		end
	end

	if typeof(persisted.drills) == "table" then
		local maxId = 0
		for _, record in ipairs(persisted.drills) do
			if typeof(record) == "table" and typeof(record.chunkId) == "string" and typeof(record.position) == "table" then
				local chunk = state.chunksById[record.chunkId]
				if chunk and chunk.unlocked then
					local drillId = tonumber(record.drillId) or (maxId + 1)
					if drillId > maxId then
						maxId = drillId
					end
					local biomeConfig = OilConfig.Biomes[chunk.biome] or OilConfig.Biomes.Desert
					local restoredScale = tonumber(record.scale) or 1
					-- Restore local buffer
					local restoredBuffer = emptyTierMap()
					if typeof(record.localBuffer) == "table" then
						for _, tier in ipairs(TIER_ORDER) do
							restoredBuffer[tier] = floorPositive(tonumber(record.localBuffer[tier]) or 0)
						end
					end
					local drillX = tonumber(record.position.x) or chunk.worldX
					local drillY = tonumber(record.position.y) or 6
					local drillZ = tonumber(record.position.z) or chunk.worldZ
					local cRow, cCol = worldToCell(drillX, drillZ)
					state.drillsById[drillId] = {
						drillId = drillId,
						chunkId = record.chunkId,
						biome = chunk.biome,
						template = (typeof(record.template) == "string" and record.template) or OilConfig.DefaultDrillTemplate,
						scale = restoredScale,
						position = Vector3.new(drillX, drillY, drillZ),
						flowBase = OilConfig.DrillBaseFlow * biomeConfig.flowMul * restoredScale,
						tierMix = copyTierMap(biomeConfig.tierMix),
						cellKey = cellKey(cRow, cCol),
						cellRow = cRow,
						cellCol = cCol,
						localBuffer = restoredBuffer,
						connected = false,
					}
					state.activeDrillCount += 1
				end
			end
		end
		state.nextDrillId = math.max(state.nextDrillId, maxId + 1)
	end

	if typeof(persisted.pipes) == "table" then
		local maxPipeId = 0
		for _, record in ipairs(persisted.pipes) do
			if typeof(record) == "table" then
				local row = tonumber(record.row)
				local col = tonumber(record.col)
				if row and col and cellInBounds(row, col) then
					local pipeId = tonumber(record.pipeId) or (maxPipeId + 1)
					if pipeId > maxPipeId then maxPipeId = pipeId end
					local sectionId = cellToSectionId(row, col)
					local x, z = cellToWorld(row, col)
					state.pipesByCellKey[cellKey(row, col)] = {
						pipeId = pipeId,
						cellKey = cellKey(row, col),
						row = row,
						col = col,
						sectionId = sectionId,
						position = Vector3.new(x, 6, z),
					}
				end
			end
		end
		state.nextPipeId = math.max(state.nextPipeId, maxPipeId + 1)
	end

	if typeof(persisted.drums) == "table" then
		local maxDrumId = 0
		for _, record in ipairs(persisted.drums) do
			if typeof(record) == "table" and typeof(record.position) == "table" then
				local drumId = tonumber(record.drumId) or (maxDrumId + 1)
				if drumId > maxDrumId then maxDrumId = drumId end
				local px = tonumber(record.position.x) or 0
				local py = tonumber(record.position.y) or 0
				local pz = tonumber(record.position.z) or 0
				local row = tonumber(record.row)
				local col = tonumber(record.col)
				if not row or not col then
					row, col = worldToCell(px, pz)
				end
				state.drumsById[drumId] = {
					drumId = drumId,
					position = Vector3.new(px, py, pz),
					cellKey = cellKey(row, col),
					row = row,
					col = col,
				}
			end
		end
		state.nextDrumId = math.max(state.nextDrumId, maxDrumId + 1)
	end

	if typeof(persisted.nextDrillId) == "number" then
		state.nextDrillId = math.max(state.nextDrillId, math.floor(persisted.nextDrillId))
	end
	if typeof(persisted.nextPipeId) == "number" then
		state.nextPipeId = math.max(state.nextPipeId, math.floor(persisted.nextPipeId))
	end
	if typeof(persisted.nextDrumId) == "number" then
		state.nextDrumId = math.max(state.nextDrumId, math.floor(persisted.nextDrumId))
	end

	state.totalOil = sumTierMap(state.oilByTier)

	-- Drop overflow drills if cap shrank
	local cap = maxActiveDrillsFor(state)
	while state.activeDrillCount > cap do
		local removed = false
		for id, _drill in pairs(state.drillsById) do
			state.drillsById[id] = nil
			state.activeDrillCount -= 1
			removed = true
			break
		end
		if not removed then
			break
		end
	end
end

function OilStateService:_markDirty(userId: number)
	self._dirtyByUserId[userId] = true
end

function OilStateService:_flushAndDropUser(userId: number)
	self:_saveUser(userId)
	self._statesByUserId[userId] = nil
	self._dirtyByUserId[userId] = nil
end

function OilStateService:_flushDirtyUsers()
	for userId, _ in pairs(self._dirtyByUserId) do
		self:_saveUser(userId)
	end
end

function OilStateService:_saveUser(userId: number)
	if not self._dirtyByUserId[userId] then
		return
	end

	local state = self._statesByUserId[userId]
	if not state then
		self._dirtyByUserId[userId] = nil
		return
	end

	local payload = self:_serializeState(state)
	local key = tostring(userId)

	if not self._dataStore then
		self._memoryStore[key] = payload
		self._dirtyByUserId[userId] = nil
		return
	end

	local ok, err = pcall(function()
		self._dataStore:SetAsync(key, payload)
	end)
	if ok then
		self._dirtyByUserId[userId] = nil
	else
		warn(string.format("[OilStateService] Save failed for user %d: %s", userId, tostring(err)))
	end
end

function OilStateService:_loadPersistedProfile(userId: number)
	local key = tostring(userId)
	if self._memoryStore[key] then
		return self._memoryStore[key]
	end
	if not self._dataStore then
		return nil
	end

	local ok, profileOrErr = pcall(function()
		return self._dataStore:GetAsync(key)
	end)
	if ok and typeof(profileOrErr) == "table" then
		return profileOrErr
	end
	if not ok then
		warn(string.format("[OilStateService] Load failed for user %d: %s", userId, tostring(profileOrErr)))
	end
	return nil
end

function OilStateService:_serializeState(state)
	local persisted = buildDefaultPersisted()
	persisted.cash = floorPositive(state.cash)
	persisted.storageCapacity = math.max(1, floorPositive(state.storageCapacity))
	persisted.oilByTier = copyTierMap(state.oilByTier)
	persisted.unlockedChunkIds = {}
	persisted.chunkBiomes = {}
	persisted.chunkTiles = {}
	for chunkId, chunk in pairs(state.chunksById) do
		if chunk.unlocked then
			persisted.unlockedChunkIds[chunkId] = true
			if chunk.biome then
				persisted.chunkBiomes[chunkId] = chunk.biome
			end
			if chunk.tiles then
				persisted.chunkTiles[chunkId] = chunk.tiles
			end
		end
	end
	persisted.drills = {}
	for _, drill in pairs(state.drillsById) do
		table.insert(persisted.drills, {
			drillId = drill.drillId,
			chunkId = drill.chunkId,
			template = drill.template or OilConfig.DefaultDrillTemplate,
			scale = drill.scale or 1,
			position = { x = drill.position.X, y = drill.position.Y, z = drill.position.Z },
			localBuffer = drill.localBuffer and copyTierMap(drill.localBuffer) or emptyTierMap(),
			intakeAttachmentId = drill.intakeAttachmentId,
		})
	end

	persisted.pipes = {}
	for _, pipe in pairs(state.pipesByCellKey) do
		table.insert(persisted.pipes, {
			pipeId = pipe.pipeId,
			cellKey = pipe.cellKey,
			row = pipe.row,
			col = pipe.col,
			sectionId = pipe.sectionId,
		})
	end

	persisted.drums = {}
	for _, drum in pairs(state.drumsById) do
		table.insert(persisted.drums, {
			drumId = drum.drumId,
			position = { x = drum.position.X, y = drum.position.Y, z = drum.position.Z },
			cellKey = drum.cellKey,
			row = drum.row,
			col = drum.col,
		})
	end

	persisted.nextDrillId = state.nextDrillId
	persisted.nextPipeId = state.nextPipeId
	persisted.nextDrumId = state.nextDrumId
	persisted.selectedBoatTypeId = state.selectedBoatTypeId or "RustSkiff"

	return persisted
end

function OilStateService:SetSelectedBoatTypeId(userId: number, boatTypeId: string): (boolean, string)
	local state = self._statesByUserId[userId]
	if not state then
		return false, "ERR_NO_STATE"
	end
	if typeof(boatTypeId) ~= "string" or not BoatConfig.Boats[boatTypeId] then
		return false, "ERR_BAD_BOAT"
	end
	state.selectedBoatTypeId = boatTypeId
	self:_markDirty(userId)
	return true, "OK"
end

return OilStateService
