--!strict

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local DataStoreWriteGate = require(script.Parent.Parent.Utils.DataStoreWriteGate)
local OilConfig = require(Shared:WaitForChild("Config"):WaitForChild("OilConfig"))
local BiomeConfig = require(Shared:WaitForChild("Config"):WaitForChild("BiomeConfig"))
local ShipSkinCatalog = require(Shared:WaitForChild("Config"):WaitForChild("ShipSkinCatalog"))
local ShipStats = require(Shared:WaitForChild("Config"):WaitForChild("ShipStats"))
local ShipUpgradeConfig = require(Shared:WaitForChild("Config"):WaitForChild("ShipUpgradeConfig"))
local ShipProfileMigration = require(Shared:WaitForChild("Config"):WaitForChild("ShipProfileMigration"))
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))
local DevLog = require(Shared:WaitForChild("DevLog"))

local OilStateService = {}

local SAVE_INTERVAL_SECONDS = 25
--- Avoid stacking multiple `SetAsync` calls for the same profile key in one burst (queue / throttling).
local MIN_DATASTORE_SET_INTERVAL_SECONDS = 7
local FLUSH_MULTI_USER_SPACING_SECONDS = 0.2
local DATASTORE_NAME = "OilMiningProfiles_v3"

local TIER_ORDER = {
	"HeavyCrude",
	"LightSweet",
	"PremiumRefined",
}

local function migrateLegacyStandardTileOil(tiles: any)
	if typeof(tiles) ~= "table" then
		return
	end
	for _, tile in pairs(tiles) do
		if typeof(tile) == "table" then
			local t = tile :: any
			if t.oilType == "StandardCrude" then
				t.oilType = "HeavyCrude"
			end
			-- Obstacle system removed: drop legacy fields from loaded saves.
			t.hasObstacle = nil
			t.obstacleType = nil
		end
	end
end

local function floorPositive(value: number): number
	return math.max(0, math.floor(value))
end

local function isDatastoreStudioAccessError(err: any): boolean
	local s = tostring(err)
	return string.find(s, "StudioAccessToApisNotAllowed", 1, true) ~= nil
		or string.find(s, "API access is not enabled", 1, true) ~= nil
		or string.find(s, "Cannot write to DataStore", 1, true) ~= nil
		or string.find(s, "Cannot read from DataStore", 1, true) ~= nil
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
		version = 5,
		cash = OilConfig.StartingCash,
		storageCapacity = OilConfig.StartingStorageCapacity,
		oilByTier = {
			HeavyCrude = 0,
			LightSweet = 0,
			PremiumRefined = 0,
		},
		unlockedChunkIds = {},
		chunkProspected = {},
		drills = {},
		pipes = {},
		drums = {},
		equipmentOwned = {},
		nextDrillId = 1,
		nextPipeId = 1,
		nextDrumId = 1,
		nextAttachmentId = 1,
		shipSpeedLevel = 1,
		shipCapacityLevel = 1,
		shipSkinId = "DefaultTanker",
	}
end

local function emptyTierMap()
	return {
		HeavyCrude = 0,
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

-- Grid math split into two parts:
--   * static parts (subTilesPerSide, global rows/cols, section dims) come from OilConfig
--   * per-plot origin (cellOriginX/Z) is cached per PlotId since each plot has its own
--     world-space center. Without this, placements on Plot_02+ resolve to Plot_01's grid.
local _staticGrid = nil
local _gridOriginByPlotId: { [number]: { cellOriginX: number, cellOriginZ: number } } = {}

local function staticGridConstants()
	if _staticGrid then return _staticGrid end
	local sectionCols = OilConfig.Chunks.GridCols -- 3
	local sectionRows = OilConfig.Chunks.GridRows -- 4
	local sectionSize = OilConfig.Chunks.Size     -- 40
	local subTilesPerSide = math.floor(sectionSize / SUB_TILE_SIZE) -- 5
	_staticGrid = {
		sectionCols = sectionCols,
		sectionRows = sectionRows,
		sectionSize = sectionSize,
		subTilesPerSide = subTilesPerSide,
		globalCols = sectionCols * subTilesPerSide,
		globalRows = sectionRows * subTilesPerSide,
	}
	return _staticGrid
end

local function plotGridOrigin(plot: Model): { cellOriginX: number, cellOriginZ: number }
	local plotId = plot:GetAttribute("PlotId")
	if typeof(plotId) ~= "number" then
		plotId = tonumber(string.match(plot.Name, "(%d+)")) or 0
	end
	local cached = _gridOriginByPlotId[plotId]
	if cached then return cached end

	local s = staticGridConstants()
	local centerX, centerZ = 0, 0
	local ground = plot:FindFirstChild("PlotGround")
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
		else
			warn(string.format("[OilStateService] %s has no CenterX/CenterZ attributes on PlotGround sections", plot.Name))
		end
	end

	local startX = centerX - ((s.sectionCols - 1) / 2) * s.sectionSize
	local startZ = centerZ - ((s.sectionRows - 1) / 2) * s.sectionSize
	local cellOriginX = startX - ((s.subTilesPerSide - 1) / 2) * SUB_TILE_SIZE
	local cellOriginZ = startZ - ((s.subTilesPerSide - 1) / 2) * SUB_TILE_SIZE

	local origin = { cellOriginX = cellOriginX, cellOriginZ = cellOriginZ }
	_gridOriginByPlotId[plotId] = origin
	return origin
end

local function cellKey(globalRow: number, globalCol: number): string
	return string.format("R%dC%d", globalRow, globalCol)
end

local function readFtueCellAttribute(userId: number, attributeName: string): string?
	local plr = Players:GetPlayerByUserId(userId)
	if not plr then
		return nil
	end
	local v = plr:GetAttribute(attributeName)
	if typeof(v) ~= "string" then
		return nil
	end
	local s = (v :: string):gsub("^%s+", ""):gsub("%s+$", "")
	if s == "" then
		return nil
	end
	return s
end

local function worldToCell(plot: Model, x: number, z: number): (number, number)
	local o = plotGridOrigin(plot)
	local col = math.floor((x - o.cellOriginX) / SUB_TILE_SIZE + 0.5) + 1
	local row = math.floor((z - o.cellOriginZ) / SUB_TILE_SIZE + 0.5) + 1
	return row, col
end

local function cellToWorld(plot: Model, row: number, col: number): (number, number)
	local o = plotGridOrigin(plot)
	local x = o.cellOriginX + (col - 1) * SUB_TILE_SIZE
	local z = o.cellOriginZ + (row - 1) * SUB_TILE_SIZE
	return x, z
end

local function cellToSectionId(row: number, col: number): string
	local s = staticGridConstants()
	local sRow = math.floor((row - 1) / s.subTilesPerSide) + 1
	local sCol = math.floor((col - 1) / s.subTilesPerSide) + 1
	return string.format("S%02d_%02d", sRow, sCol)
end

local function cellInBounds(row: number, col: number): boolean
	local s = staticGridConstants()
	return row >= 1 and row <= s.globalRows and col >= 1 and col <= s.globalCols
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
	self._dataStoreStudioFallbackWarned = false
	self._lastOilDataStoreSaveClock = {} :: { [number]: number }
	self._dataStore = nil
	local okStore, storeOrErr = pcall(function()
		return DataStoreService:GetDataStore(DATASTORE_NAME)
	end)
	if okStore then
		self._dataStore = storeOrErr
	else
		self._dataStore = nil
		warn("[OilStateService] DataStore unavailable (enable API access in Studio if needed); using memory fallback:", storeOrErr)
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
		task.wait(3)
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
	self:_flushDirtyUsers(true)

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
			prospected = chunk.prospected or false,
			worldX = chunk.worldX,
			worldZ = chunk.worldZ,
			tiles = chunk.tiles,
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
			template = drill.template or (OilConfig.PumpTiers.T1 and OilConfig.PumpTiers.T1.templateName),
			tier = drill.tier,
			tileKey = drill.tileKey,
			variant = drill.variant,
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

	local activeProspectors = {}
	for _, entry in pairs(state.activeProspectors or {}) do
		table.insert(activeProspectors, {
			prospectId = entry.prospectId,
			chunkId = entry.chunkId,
			tileKey = entry.tileKey,
			template = entry.template,
			position = { x = entry.position.X, y = entry.position.Y, z = entry.position.Z },
			startTime = entry.startTime,
			endTime = entry.endTime,
		})
	end

	local activeDrills = {}
	local nowT = workspace:GetServerTimeNow()
	for _, entry in pairs(state.activeDrills or {}) do
		table.insert(activeDrills, {
			drillId = entry.drillId,
			chunkId = entry.chunkId,
			tier = entry.tier,
			tileKey = entry.tileKey,
			template = entry.template,
			position = { x = entry.position.X, y = entry.position.Y, z = entry.position.Z },
			startTime = entry.startTime,
			endTime = entry.endTime,
			remaining = math.max(0, entry.endTime - nowT),
			oilType = entry.oilType,
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
		shipSpeedLevel = math.clamp(math.floor(state.shipSpeedLevel or 1), 1, ShipUpgradeConfig.MaxSpeedLevel),
		shipCapacityLevel = math.clamp(math.floor(state.shipCapacityLevel or 1), 1, ShipUpgradeConfig.MaxCapacityLevel),
		shipSkinId = (typeof(state.shipSkinId) == "string" and state.shipSkinId) or "DefaultTanker",
		resolvedShip = (function()
			local spd = math.clamp(math.floor(state.shipSpeedLevel or 1), 1, ShipUpgradeConfig.MaxSpeedLevel)
			local capL = math.clamp(math.floor(state.shipCapacityLevel or 1), 1, ShipUpgradeConfig.MaxCapacityLevel)
			local rs = ShipStats.Resolve(spd, capL)
			return {
				capacity = rs.capacity,
				dispatchFee = rs.dispatchFee,
				travelSeconds = rs.travelSeconds,
				eventRisk = rs.eventRisk,
			}
		end)(),
		upgradeShipSpeedCost = ShipUpgradeConfig.GetSpeedUpgradeCost(
			math.clamp(math.floor(state.shipSpeedLevel or 1), 1, ShipUpgradeConfig.MaxSpeedLevel)
		),
		upgradeShipCapacityCost = ShipUpgradeConfig.GetCapacityUpgradeCost(
			math.clamp(math.floor(state.shipCapacityLevel or 1), 1, ShipUpgradeConfig.MaxCapacityLevel)
		),
		chunks = chunks,
		drills = drills,
		activeDrills = activeDrills,
		activeProspectors = activeProspectors,
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

	-- Roll a biome from this chunk's row pool, excluding biomes already taken by siblings in the same row.
	local rng = Random.new(userId * 97 + chunk.row * 31 + chunk.col * 17 + math.floor(workspace:GetServerTimeNow() * 1000))
	local usedInRow: { [string]: boolean } = {}
	for _, otherChunk in pairs(state.chunksById) do
		if otherChunk.row == chunk.row and otherChunk.biome and otherChunk.chunkId ~= chunk.chunkId then
			usedInRow[otherChunk.biome] = true
		end
	end
	local biomeName = BiomeConfig.RollBiomeForRow(chunk.row, usedInRow, rng)
	chunk.unlocked = true
	chunk.biome = biomeName
	chunk.revealed = false -- stays hidden until slot machine animation finishes

	-- Generate per-tile oil types + obstacles for the 5x5 sub-tiles
	local subTiles = staticGridConstants().subTilesPerSide
	chunk.tiles = {}

	-- Assign tile types + bake in one oilType per tile. Then roll hasOil per tile based on row rate:
	-- tiles that lose the roll have no oil underneath and produce a dirt patch when drilled.
	-- SUPER TILEs always keep their oil regardless of row rate.
	local oilRate = BiomeConfig.OilRatePerRow and BiomeConfig.OilRatePerRow[chunk.row] or 0.75
	for tr = 1, subTiles do
		for tc = 1, subTiles do
			local tileKey = string.format("T%d%d", tr, tc)
			local tileType = BiomeConfig.RollTileType(biomeName, rng)
			local pickedOil = BiomeConfig.PickOilType(tileType, rng)
			local hasOil = (tileType.name == "SUPER TILE") or (rng:NextNumber() < oilRate)
			chunk.tiles[tileKey] = {
				oilType = pickedOil,
				hasOil = hasOil,
				tileName = tileType.name,
				tileMaterial = tileType.material.Name,
				tileColorR = math.floor(tileType.color.R * 255),
				tileColorG = math.floor(tileType.color.G * 255),
				tileColorB = math.floor(tileType.color.B * 255),
				drillSeconds = tileType.drillSeconds,
				drilled = false,
			}
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

-- Legacy stub: obstacle system removed. Kept so any stale callers get a clear error
-- instead of crashing. Remove once all call sites are purged.
function OilStateService:TryClearObstacle(_userId: number, _chunkId: string, _tileKey: string): (boolean, string, string)
	return false, "ERR_OBSTACLES_REMOVED", "Obstacles are no longer a thing."
end

local function pointInsideChunk(chunk, x: number, z: number): boolean
	local size = OilConfig.Chunks.Size
	local half = size / 2
	return math.abs(x - chunk.worldX) <= half and math.abs(z - chunk.worldZ) <= half
end

-- Resolve which "Trr" / "Tcc" tile in a chunk contains world position (x, z).
-- Returns (tileKey, tile) or (nil, nil) if out of range or tiles not generated yet.
local function resolveTileAt(plot: Model, chunk, x: number, z: number): (string?, any?)
	if not chunk or not chunk.tiles then return nil, nil end
	local cellR, cellC = worldToCell(plot, x, z)
	local s = staticGridConstants()
	local sRow = (chunk.row - 1) * s.subTilesPerSide
	local sCol = (chunk.col - 1) * s.subTilesPerSide
	local localR = cellR - sRow
	local localC = cellC - sCol
	if localR < 1 or localR > s.subTilesPerSide or localC < 1 or localC > s.subTilesPerSide then
		return nil, nil
	end
	local key = string.format("T%d%d", localR, localC)
	return key, chunk.tiles[key]
end

local function distanceXZ(x1, z1, x2, z2): number
	local dx = x1 - x2
	local dz = z1 - z2
	return math.sqrt(dx * dx + dz * dz)
end

-- Validates a placement payload against tile + chunk rules. Shared by drill-start and pump-place.
-- Returns (ok, code, message, chunk, tileKey, snappedX, snappedY, snappedZ, cellRow, cellCol).
function OilStateService:_validateTilePlacement(userId: number, payload)
	local state = self._statesByUserId[userId]
	if not state then return false, "ERR_NO_STATE", "State unavailable." end
	if typeof(payload) ~= "table" then return false, "ERR_BAD_PAYLOAD", "Missing payload." end
	local chunkId = payload.chunkId
	local x = tonumber(payload.x)
	local y = tonumber(payload.y)
	local z = tonumber(payload.z)
	if typeof(chunkId) ~= "string" or not x or not y or not z then
		return false, "ERR_BAD_PAYLOAD", "Bad placement payload."
	end
	local chunk = state.chunksById[chunkId]
	if not chunk then return false, "ERR_BAD_CHUNK", "Chunk does not exist." end
	if not chunk.unlocked then return false, "ERR_LOCKED_CHUNK", "Chunk is not unlocked." end
	if not pointInsideChunk(chunk, x, z) then
		return false, "ERR_OUT_OF_CHUNK", "Position is not on the targeted chunk."
	end

	local plot = state.plot or self._plotService:GetOwnedPlot(userId)
	if not plot then return false, "ERR_NO_PLOT", "No plot owned." end

	local cellR, cellC = worldToCell(plot, x, z)
	local ck = cellKey(cellR, cellC)

	local tileKey, _tile = resolveTileAt(plot, chunk, x, z)
	if state.pipesByCellKey and state.pipesByCellKey[ck] then
		return false, "ERR_PIPE_HERE", "Remove the pipe first."
	end
	for _, drum in pairs(state.drumsById) do
		if drum.cellKey == ck then
			return false, "ERR_CELL_BLOCKED", "This cell is occupied by the refinery."
		end
	end
	if state._blockedCells and state._blockedCells[ck] then
		return false, "ERR_CELL_BLOCKED", "This cell is occupied by refinery infrastructure."
	end

	-- Snap Y to the tile's top surface
	local sectionModel = self._plotService:GetChunkModel(plot, chunkId)
	if sectionModel then
		local topY: number? = nil
		for _, d in ipairs(sectionModel:GetChildren()) do
			if d:IsA("BasePart") and d.Name:match("^T%d%d$") then
				local surface = d.Position.Y + d.Size.Y / 2
				if topY == nil or surface > topY then topY = surface end
			end
		end
		if topY then y = topY end
	end

	local snappedX, snappedZ = cellToWorld(plot, cellR, cellC)
	return true, "OK", "", chunk, tileKey, snappedX, y, snappedZ, cellR, cellC
end

-- Begin a drill operation on a tile. Server-authoritative timer; pump placement is blocked
-- until CompleteDrill runs (called by DrillingService after DrillTier.drillSeconds).
function OilStateService:TryStartDrill(userId: number, payload): (boolean, string, string, any)
	local state = self._statesByUserId[userId]
	if not state then return false, "ERR_NO_STATE", "State unavailable.", nil end

	local tier = typeof(payload) == "table" and payload.tier or nil
	local tierCfg = tier and OilConfig.DrillTiers[tier]
	if not tierCfg then
		return false, "ERR_BAD_TIER", "Unknown drill tier.", nil
	end

	local ok, code, msg, chunk, tileKey, sx, sy, sz, cellR, cellC = self:_validateTilePlacement(userId, payload)
	if not ok then return false, code, msg, nil end

	local tile = chunk.tiles and chunk.tiles[tileKey]
	if tile and tile.drilled then
		return false, "ERR_ALREADY_DRILLED", "This tile has already been drilled.", nil
	end

	local ck = cellKey(cellR, cellC)
	-- Block placing a drill where a pump or another drill already is
	for _, pump in pairs(state.drillsById) do
		if pump.cellKey == ck then
			return false, "ERR_CELL_BLOCKED", "Cell already has a pump.", nil
		end
	end
	for _, active in pairs(state.activeDrills) do
		if active.cellKey == ck then
			return false, "ERR_CELL_BLOCKED", "Already drilling this tile.", nil
		end
	end

	if not self:TrySpendCash(userId, tierCfg.cost) then
		return false, "ERR_NOT_ENOUGH_CASH", "Not enough cash.", nil
	end

	local drillId = state.nextDrillId
	state.nextDrillId += 1

	-- Effective duration = tile.drillSeconds / tier.timeDivisor (1/10/30 for T1/T2/T3).
	-- T1 at 1x is normal speed; T2 drills 10x faster, T3 drills 30x faster.
	local baseSeconds = (tile and tonumber(tile.drillSeconds)) or tierCfg.fallbackSeconds or 10
	local effectiveSeconds = math.max(0.5, baseSeconds / (tierCfg.timeDivisor or 1))

	local now = workspace:GetServerTimeNow()
	local entry = {
		drillId = drillId,
		chunkId = chunk.chunkId,
		tier = tier,
		tileKey = tileKey,
		cellKey = ck,
		cellRow = cellR,
		cellCol = cellC,
		position = Vector3.new(sx, sy, sz),
		startTime = now,
		endTime = now + effectiveSeconds,
		oilType = (tile and tile.oilType) or nil,
		template = tierCfg.templateName,
	}
	state.activeDrills[drillId] = entry
	return true, "OK", "Drilling...", {
		drillId = drillId,
		duration = effectiveSeconds,
		position = { x = sx, y = sy, z = sz },
		chunkId = chunk.chunkId,
		tileKey = tileKey,
		tier = tier,
		template = tierCfg.templateName,
		oilType = entry.oilType,
	}
end

-- Called by DrillingService when a drill's timer expires. Marks the tile drilled and
-- returns metadata so the caller can fire spray-start VFX to clients.
function OilStateService:CompleteDrill(userId: number, drillId: number): (boolean, any)
	local state = self._statesByUserId[userId]
	if not state then return false, nil end
	local entry = state.activeDrills[drillId]
	if not entry then return false, nil end
	state.activeDrills[drillId] = nil

	local chunk = state.chunksById[entry.chunkId]
	local hasOil = true
	if chunk and chunk.tiles and chunk.tiles[entry.tileKey] then
		chunk.tiles[entry.tileKey].drilled = true
		hasOil = chunk.tiles[entry.tileKey].hasOil ~= false
	end
	self:_markDirty(userId)
	return true, {
		drillId = drillId,
		chunkId = entry.chunkId,
		tileKey = entry.tileKey,
		position = entry.position,
		oilType = entry.oilType,
		hasOil = hasOil,
	}
end

-- Begin a prospect op on a single tile. Affects the whole 5x5 chunk that tile belongs to.
function OilStateService:TryStartProspect(userId: number, payload: any): (boolean, string, string, any)
	local state = self._statesByUserId[userId]
	if not state then return false, "ERR_NO_STATE", "State unavailable.", nil end

	local cfg = OilConfig.Prospecting or { durationSeconds = 5, cost = 0, templateName = "Prospector" }

	local ok, code, msg, chunk, tileKey, sx, sy, sz = self:_validateTilePlacement(userId, payload)
	if not ok then return false, code, msg, nil end

	if chunk.prospected then
		return false, "ERR_ALREADY_PROSPECTED", "This chunk has already been prospected.", nil
	end

	-- Block if another prospect is already running on this chunk
	for _, active in pairs(state.activeProspectors) do
		if active.chunkId == chunk.chunkId then
			return false, "ERR_PROSPECT_IN_PROGRESS", "Already prospecting this chunk.", nil
		end
	end

	if (cfg.cost or 0) > 0 and not self:TrySpendCash(userId, cfg.cost) then
		return false, "ERR_NOT_ENOUGH_CASH", "Not enough cash.", nil
	end

	local prospectId = state.nextProspectId or 1
	state.nextProspectId = prospectId + 1
	local now = workspace:GetServerTimeNow()
	local entry = {
		prospectId = prospectId,
		chunkId = chunk.chunkId,
		tileKey = tileKey,
		position = Vector3.new(sx, sy, sz),
		startTime = now,
		endTime = now + cfg.durationSeconds,
		template = cfg.templateName,
	}
	state.activeProspectors[prospectId] = entry

	return true, "OK", "Prospecting...", {
		prospectId = prospectId,
		chunkId = chunk.chunkId,
		tileKey = tileKey,
		position = { x = sx, y = sy, z = sz },
		duration = cfg.durationSeconds,
		template = cfg.templateName,
	}
end

-- Called by ProspectingService when the timer expires. Marks chunk.prospected = true so clients
-- render tile highlights (oil) / darkens (dry) permanently.
function OilStateService:CompleteProspect(userId: number, prospectId: number): (boolean, any)
	local state = self._statesByUserId[userId]
	if not state then return false, nil end
	local entry = state.activeProspectors[prospectId]
	if not entry then return false, nil end
	state.activeProspectors[prospectId] = nil

	local chunk = state.chunksById[entry.chunkId]
	if chunk then
		chunk.prospected = true
	end
	self:_markDirty(userId)
	return true, {
		prospectId = prospectId,
		chunkId = entry.chunkId,
		position = entry.position,
	}
end

-- Place a pump on a tile that has already been drilled.
function OilStateService:TryPlacePump(userId: number, payload): (boolean, string, string, any)
	local state = self._statesByUserId[userId]
	if not state then return false, "ERR_NO_STATE", "State unavailable.", nil end

	local tier = typeof(payload) == "table" and payload.tier or "T1"
	local tierCfg = OilConfig.PumpTiers[tier]
	if not tierCfg then return false, "ERR_BAD_TIER", "Unknown pump tier.", nil end

	local ok, code, msg, chunk, tileKey, sx, sy, sz, cellR, cellC = self:_validateTilePlacement(userId, payload)
	if not ok then return false, code, msg, nil end

	local tile = chunk.tiles and chunk.tiles[tileKey]
	if not tile or not tile.drilled then
		return false, "ERR_NOT_DRILLED", "Tile must be drilled first.", nil
	end
	if tile.hasOil == false then
		return false, "ERR_NO_OIL", "This tile is a dry hole — no oil to pump.", nil
	end

	local ck = cellKey(cellR, cellC)
	local ftuePumpCell = readFtueCellAttribute(userId, Constants.FtueRestrictPumpCellKeyAttribute)
	if ftuePumpCell and ftuePumpCell ~= ck then
		return false, "ERR_FTUE_WRONG_TILE", "Place the collector on the marked tile.", nil
	end
	for _, existing in pairs(state.drillsById) do
		if existing.cellKey == ck then
			return false, "ERR_CELL_OCCUPIED", "A pump is already placed here.", nil
		end
	end
	for _, active in pairs(state.activeDrills) do
		if active.cellKey == ck then
			return false, "ERR_CELL_BLOCKED", "Drilling in progress here.", nil
		end
	end

	if state.activeDrillCount >= maxActiveDrillsFor(state) then
		return false, "ERR_MAX_DRILLS", "Max active pumps reached.", nil
	end

	if not self:TrySpendCash(userId, tierCfg.cost) then
		return false, "ERR_NOT_ENOUGH_CASH", "Not enough cash.", nil
	end

	local biomeConfig = OilConfig.Biomes[chunk.biome] or OilConfig.Biomes.Desert
	local pumpId = state.nextDrillId
	state.nextDrillId += 1

	-- Random cosmetic scale + rare variant roll (gold / rainbow tint)
	local scaleMin = OilConfig.PumpScaleMin or 1
	local scaleMax = OilConfig.PumpScaleMax or 1
	local scale = scaleMin + math.random() * (scaleMax - scaleMin)
	local roll = math.random()
	local variant = nil
	if roll < (OilConfig.RainbowPumpChance or 0) then
		variant = "rainbow"
	elseif roll < (OilConfig.RainbowPumpChance or 0) + (OilConfig.GoldPumpChance or 0) then
		variant = "gold"
	end

	local pump = {
		drillId = pumpId,
		chunkId = chunk.chunkId,
		biome = chunk.biome,
		tier = tier,
		tileKey = tileKey,
		template = tierCfg.templateName,
		scale = scale,
		variant = variant,
		position = Vector3.new(sx, sy, sz),
		flowBase = OilConfig.DrillBaseFlow * biomeConfig.flowMul * tierCfg.flowMultiplier * scale,
		tierMix = copyTierMap(biomeConfig.tierMix),
		tileOilType = tile.oilType,
		cellKey = ck,
		cellRow = cellR,
		cellCol = cellC,
		localBuffer = emptyTierMap(),
		connected = false,
		placementCost = tierCfg.cost or 0,
	}
	state.drillsById[pumpId] = pump
	state.activeDrillCount += 1
	self:_markDirty(userId)
	return true, "OK", "Pump placed.", { drillId = pumpId, pumpId = pumpId, tier = tier, tileKey = tileKey }
end

-- Legacy name kept for backward compat at call sites; now routes to TryPlacePump.
function OilStateService:TryPlaceDrill(userId: number, payload): (boolean, string, string, any)
	return self:TryPlacePump(userId, payload)
end

local function positionVectorFromStateEntry(pos: any): Vector3?
	-- Runtime state often uses Vector3; persisted saves use { x, y, z } tables.
	if typeof(pos) == "Vector3" then
		return pos :: Vector3
	end
	if typeof(pos) ~= "table" then
		return nil
	end
	local x = tonumber((pos :: any).x)
	local y = tonumber((pos :: any).y)
	local z = tonumber((pos :: any).z)
	if not x or not y or not z then
		return nil
	end
	return Vector3.new(x, y, z)
end

--- World position used for salvage range checks (`OilConfig.SalvageProximityMaxStuds`).
function OilStateService:GetHammerTargetWorldPosition(userId: number, payload: any): Vector3?
	if typeof(payload) ~= "table" then
		return nil
	end
	local state = self._statesByUserId[userId]
	if not state then
		return nil
	end
	local kind = payload.targetKind
	if kind == "pump" then
		local drillId = tonumber(payload.targetId)
		local pump = drillId and state.drillsById[drillId]
		return pump and positionVectorFromStateEntry(pump.position) or nil
	elseif kind == "pipe" then
		local ck = tostring(payload.cellKey or "")
		local pipe = ck ~= "" and state.pipesByCellKey[ck] or nil
		return pipe and positionVectorFromStateEntry(pipe.position) or nil
	elseif kind == "drum" then
		local drumId = tonumber(payload.targetId)
		local drum = drumId and state.drumsById[drumId]
		return drum and positionVectorFromStateEntry(drum.position) or nil
	elseif kind == "drill" then
		local drillId = tonumber(payload.targetId)
		local active = drillId and state.activeDrills[drillId]
		return active and positionVectorFromStateEntry(active.position) or nil
	elseif kind == "prospector" then
		local prospectId = tonumber(payload.targetId)
		local pr = prospectId and state.activeProspectors[prospectId]
		return pr and positionVectorFromStateEntry(pr.position) or nil
	end
	return nil
end

function OilStateService:IsHammerDestroyInRange(userId: number, payload: any, hrpPosition: Vector3): boolean
	local p = self:GetHammerTargetWorldPosition(userId, payload)
	if not p then
		return false
	end
	local maxD = tonumber(OilConfig.SalvageProximityMaxStuds) or 24
	return (p - hrpPosition).Magnitude <= maxD
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

-- Hammer destruction: refunds 10% of the placement cost.
-- payload = { targetKind = "pump"|"pipe"|"drum"|"drill"|"prospector", targetId or cellKey }
function OilStateService:TryHammerDestroy(userId: number, payload: any): (boolean, string, string, any)
	local state = self._statesByUserId[userId]
	if not state then return false, "ERR_NO_STATE", "State unavailable.", nil end
	if typeof(payload) ~= "table" then return false, "ERR_BAD_PAYLOAD", "Missing payload.", nil end
	local kind = payload.targetKind
	local refundedAmount = 0

	if kind == "pump" then
		local drillId = tonumber(payload.targetId)
		local pump = drillId and state.drillsById[drillId]
		if not pump then return false, "ERR_BAD_TARGET", "Pump not found.", nil end
		local cost = tonumber(pump.placementCost) or 0
		refundedAmount = math.floor(cost * 0.10)
		state.drillsById[drillId] = nil
		state.activeDrillCount = math.max(0, state.activeDrillCount - 1)

	elseif kind == "pipe" then
		local ck = tostring(payload.cellKey or "")
		local pipe = state.pipesByCellKey[ck]
		if not pipe then return false, "ERR_BAD_TARGET", "Pipe not found.", nil end
		local cost = tonumber(pipe.placementCost) or tonumber(OilConfig.Pipes.Cost) or 0
		refundedAmount = math.floor(cost * 0.10)
		state.pipesByCellKey[ck] = nil

	elseif kind == "drum" then
		local drumId = tonumber(payload.targetId)
		local drum = drumId and state.drumsById[drumId]
		if not drum then return false, "ERR_BAD_TARGET", "Drum not found.", nil end
		local cost = tonumber(drum.placementCost) or tonumber(OilConfig.Drums.Cost) or 0
		refundedAmount = math.floor(cost * 0.10)
		state.drumsById[drumId] = nil

	elseif kind == "drill" then
		-- Active (in-progress) drill — cancel the op, no refund for already-spent drill cost
		local drillId = tonumber(payload.targetId)
		local active = drillId and state.activeDrills[drillId]
		if not active then return false, "ERR_BAD_TARGET", "Drill op not found.", nil end
		local tierCfg = OilConfig.DrillTiers[active.tier]
		refundedAmount = math.floor((tierCfg and tierCfg.cost or 0) * 0.10)
		state.activeDrills[drillId] = nil

	elseif kind == "prospector" then
		local prospectId = tonumber(payload.targetId)
		local active = prospectId and state.activeProspectors[prospectId]
		if not active then return false, "ERR_BAD_TARGET", "Prospector not found.", nil end
		local cost = tonumber((OilConfig.Prospecting or {}).cost) or 0
		refundedAmount = math.floor(cost * 0.10)
		state.activeProspectors[prospectId] = nil

	else
		return false, "ERR_BAD_KIND", "Unknown target kind.", nil
	end

	if refundedAmount > 0 then
		state.cash = (state.cash or 0) + refundedAmount
	end
	self:_markDirty(userId)
	return true, "OK", string.format("Destroyed — refunded $%d.", refundedAmount), { refunded = refundedAmount }
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

	local plot = state.plot or self._plotService:GetOwnedPlot(userId)
	if not plot then return false, "ERR_NO_PLOT", "No plot owned.", nil end

	local row = tonumber(payload.row)
	local col = tonumber(payload.col)
	if not row or not col then
		-- Allow client to send world position; server snaps to grid
		local x = tonumber(payload.x)
		local z = tonumber(payload.z)
		if not x or not z then
			return false, "ERR_BAD_PAYLOAD", "Bad pipe payload.", nil
		end
		row, col = worldToCell(plot, x, z)
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

	if not self:TrySpendCash(userId, OilConfig.Pipes.Cost or 0) then
		return false, "ERR_NOT_ENOUGH_CASH", "Not enough cash for pipe.", nil
	end

	local pipeId = state.nextPipeId
	state.nextPipeId += 1
	local x, z = cellToWorld(plot, row, col)

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
				local plot = state.plot or self._plotService:GetOwnedPlot(userId)
				if not plot then return false, "ERR_NO_PLOT", "No plot owned." end
				row, col = worldToCell(plot, tonumber(payload.x), tonumber(payload.z))
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

function OilStateService:_rebindExistingStateToPlot(state, plot: Model)
	local newPlotId = getPlotId(plot)
	local chunkDefs = self._plotService:GetPlotChunkDefinitions(plot)
	local defsById = {}
	for _, def in ipairs(chunkDefs) do
		defsById[def.chunkId] = def
	end

	for chunkId, chunk in pairs(state.chunksById or {}) do
		local def = defsById[chunkId]
		if def then
			chunk.row = def.row
			chunk.col = def.col
			chunk.worldX = def.worldX
			chunk.worldZ = def.worldZ
		end
	end

	for _, pipe in pairs(state.pipesByCellKey or {}) do
		if typeof(pipe.row) == "number" and typeof(pipe.col) == "number" then
			local x, z = cellToWorld(plot, pipe.row, pipe.col)
			pipe.cellKey = cellKey(pipe.row, pipe.col)
			pipe.sectionId = cellToSectionId(pipe.row, pipe.col)
			local y = (typeof(pipe.position) == "Vector3" and pipe.position.Y) or 6
			pipe.position = Vector3.new(x, y, z)
		end
	end

	for _, drum in pairs(state.drumsById or {}) do
		if typeof(drum.row) == "number" and typeof(drum.col) == "number" then
			local x, z = cellToWorld(plot, drum.row, drum.col)
			drum.cellKey = cellKey(drum.row, drum.col)
			local y = (typeof(drum.position) == "Vector3" and drum.position.Y) or 6
			drum.position = Vector3.new(x, y, z)
		end
	end

	for _, drill in pairs(state.drillsById or {}) do
		local row = drill.cellRow
		local col = drill.cellCol
		if typeof(row) ~= "number" or typeof(col) ~= "number" then
			local key = drill.cellKey
			if typeof(key) == "string" then
				row = tonumber(key:match("^R(%d+)C%d+$"))
				col = tonumber(key:match("^R%d+C(%d+)$"))
			end
		end
		if typeof(row) == "number" and typeof(col) == "number" and cellInBounds(row, col) then
			local x, z = cellToWorld(plot, row, col)
			local y = (typeof(drill.position) == "Vector3" and drill.position.Y) or 6
			drill.cellRow = row
			drill.cellCol = col
			drill.cellKey = cellKey(row, col)
			drill.chunkId = cellToSectionId(row, col)
			drill.position = Vector3.new(x, y, z)
		end
	end

	state.plot = plot
	state.plotId = newPlotId
	self:_markDirty(state.ownerUserId)
end
function OilStateService:_ensurePlayerState(userId: number, plot: Model)
	local existing = self._statesByUserId[userId]
	if existing then
		local newPlotId = getPlotId(plot)
		if existing.plotId ~= newPlotId then
			DevLog.log(string.format(
				"[OilState] user=%d state/plot mismatch oldPlotId=%s newPlotId=%d - rebinding state",
				userId,
				tostring(existing.plotId),
				newPlotId
			))
			self:_rebindExistingStateToPlot(existing, plot)
		else
			DevLog.log(string.format("[OilState] _ensurePlayerState user=%d plot=%s: state already exists - reusing", userId, plot.Name))
		end
		return
	end

	local plotId = getPlotId(plot)
	local chunkDefs = self._plotService:GetPlotChunkDefinitions(plot)

	-- Diagnostic: show exactly what definitions we got from this plot
	local starterCount = 0
	for _, d in ipairs(chunkDefs) do
		if d.startingChunk then starterCount += 1 end
	end
	DevLog.log(string.format("[OilState] user=%d plot=%s plotId=%d chunks=%d starters=%d",
		userId, plot.Name, plotId, #chunkDefs, starterCount))

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
			local subTiles = staticGridConstants().subTilesPerSide
			for tr = 1, subTiles do
				for tc = 1, subTiles do
					local tileKey = string.format("T%d%d", tr, tc)
					local tileType = BiomeConfig.RollTileType("DustyDesert", startRng)
					-- Starter chunk uses the row-4 oil rate (90%)
					local starterRate = (BiomeConfig.OilRatePerRow and BiomeConfig.OilRatePerRow[4]) or 0.9
					local hasOil = (tileType.name == "SUPER TILE") or (startRng:NextNumber() < starterRate)
					chunkData.tiles[tileKey] = {
						oilType = BiomeConfig.PickOilType(tileType, startRng),
						hasOil = hasOil,
						tileName = tileType.name,
						tileMaterial = tileType.material.Name,
						tileColorR = math.floor(tileType.color.R * 255),
						tileColorG = math.floor(tileType.color.G * 255),
						tileColorB = math.floor(tileType.color.B * 255),
						drillSeconds = tileType.drillSeconds,
						drilled = false,
					}
				end
			end
		end

		chunksById[def.chunkId] = chunkData
	end

	local state = {
		ownerUserId = userId,
		plotId = plotId,
		plot = plot,
		cash = OilConfig.StartingCash,
		storageCapacity = OilConfig.StartingStorageCapacity,
		totalOil = 0,
		oilByTier = {
			HeavyCrude = 0,
			LightSweet = 0,
			PremiumRefined = 0,
		},
		pendingFloats = {
			HeavyCrude = 0,
			LightSweet = 0,
			PremiumRefined = 0,
		},
		activeShipmentCount = 0,
		shipSpeedLevel = 1,
		shipCapacityLevel = 1,
		shipSkinId = "DefaultTanker",
		chunksById = chunksById,
		drillsById = {},         -- each record is now a PLACED PUMP (post-refactor)
		activeDrills = {},       -- transient: in-progress drill operations { [drillId] = {...} }
		activeProspectors = {},  -- transient: in-progress prospect operations { [prospectId] = {...} }
		nextProspectId = 1,
		pipesByCellKey = {},
		drumsById = {},
		nextDrillId = 1,
		nextPumpId = 1,
		nextPipeId = 1,
		nextDrumId = 1,
		activeDrillCount = 0,
		equipmentOwnedByItemId = {} :: { [string]: number },
		--- When true, first inventory sync seeds `equipmentOwnedByItemId` from shop tools in Backpack (legacy profiles).
		equipmentOwnedNeedsInventoryBackfill = false,
	}

	local persisted = self:_loadPersistedProfile(userId)
	if persisted then
		self:_applyPersistedIntoState(state, persisted, plot)
	end

	self:_ensureDefaultDrumForPlayer(state, plot)
	self:_ensureDefaultPipesForPlayer(state, plot)

	self._statesByUserId[userId] = state

	-- Force a deferred visual refresh so biome tiles + fog get applied after state is fully set
	task.defer(function()
		self:PushState(userId)
	end)
end

function OilStateService:_ensureDefaultPipesForPlayer(state, plot: Model)
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
					local x, z = cellToWorld(plot, row, col)
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
	local s = staticGridConstants()
	-- Bottom-center sub-tile of the starting section
	local row = (startSectionRow - 1) * s.subTilesPerSide + s.subTilesPerSide
	local col = (startSectionCol - 1) * s.subTilesPerSide + math.ceil(s.subTilesPerSide / 2)
	local x, z = cellToWorld(plot, row, col)
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

function OilStateService:_applyPersistedIntoState(state, persisted, plot: Model)
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
		local pot = persisted.oilByTier :: { [string]: any }
		local legacyStandard = floorPositive(tonumber(pot.StandardCrude) or 0)
		for _, tier in ipairs(TIER_ORDER) do
			local value = pot[tier]
			if typeof(value) == "number" then
				state.oilByTier[tier] = floorPositive(value)
			end
		end
		if legacyStandard > 0 then
			state.oilByTier.HeavyCrude = (state.oilByTier.HeavyCrude or 0) + legacyStandard
		end
	end

	state.equipmentOwnedByItemId = {}
	state.equipmentOwnedNeedsInventoryBackfill = false
	if typeof(persisted.equipmentOwned) == "table" then
		for _, row in ipairs(persisted.equipmentOwned) do
			if typeof(row) == "table" then
				local r = row :: { [string]: any }
				local itemId = r.itemId
				local cnt = r.count
				if typeof(itemId) == "string" and itemId ~= "" and typeof(cnt) == "number" then
					local c = floorPositive(cnt)
					if c > 0 then
						state.equipmentOwnedByItemId[itemId] = c
					end
				end
			end
		end
	elseif persisted.equipmentOwned == nil then
		state.equipmentOwnedNeedsInventoryBackfill = true
	end

	-- Player ship (v4): migrate from legacy `selectedBoatTypeId` when profile version < 4.
	local pVer = tonumber(persisted.version) or 1
	if pVer >= 4 then
		if typeof(persisted.shipSkinId) == "string" and ShipSkinCatalog.Skins[persisted.shipSkinId] then
			state.shipSkinId = persisted.shipSkinId
		else
			state.shipSkinId = "DefaultTanker"
		end
		state.shipSpeedLevel = math.clamp(math.floor(tonumber(persisted.shipSpeedLevel) or 1), 1, ShipUpgradeConfig.MaxSpeedLevel)
		state.shipCapacityLevel = math.clamp(math.floor(tonumber(persisted.shipCapacityLevel) or 1), 1, ShipUpgradeConfig.MaxCapacityLevel)
	else
		local legacyId = if typeof(persisted.selectedBoatTypeId) == "string" then persisted.selectedBoatTypeId else nil
		local migrated = ShipProfileMigration.FromLegacyBoatTypeId(legacyId)
		state.shipSkinId = migrated.skinId
		state.shipSpeedLevel = math.clamp(migrated.speedLevel, 1, ShipUpgradeConfig.MaxSpeedLevel)
		state.shipCapacityLevel = math.clamp(migrated.capacityLevel, 1, ShipUpgradeConfig.MaxCapacityLevel)
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
					migrateLegacyStandardTileOil(chunk.tiles)
				end
			end
		end
	end

	if typeof(persisted.chunkProspected) == "table" then
		for chunkId, v in pairs(persisted.chunkProspected) do
			if typeof(chunkId) == "string" and v == true then
				local ch = state.chunksById[chunkId]
				if ch then
					ch.prospected = true
				end
			end
		end
	end

	-- Restore placed pumps (requires `tileKey` + cell coords or position — v5+ saves).
	if typeof(persisted.drills) == "table" then
		local maxDrillId = 0
		for _, record in ipairs(persisted.drills) do
			if typeof(record) == "table" then
				local rec = record :: { [string]: any }
				local drillId = tonumber(rec.drillId)
				if drillId then
					maxDrillId = math.max(maxDrillId, drillId)
					local chunkId = rec.chunkId
					if typeof(chunkId) == "string" then
						local chunk = state.chunksById[chunkId]
						local tileKey = if typeof(rec.tileKey) == "string" then rec.tileKey :: string else nil
						if chunk and tileKey and chunk.tiles and chunk.tiles[tileKey] then
							local cellR = tonumber(rec.cellRow)
							local cellC = tonumber(rec.cellCol)
							if not cellR or not cellC or not cellInBounds(cellR, cellC) then
								local pv = positionVectorFromStateEntry(rec.position)
								if pv then
									cellR, cellC = worldToCell(plot, pv.X, pv.Z)
								end
							end
							if cellR and cellC and cellInBounds(cellR, cellC) then
								local ck = cellKey(cellR, cellC)
								local duplicateCell = false
								for _, existing in pairs(state.drillsById) do
									if existing.cellKey == ck then
										duplicateCell = true
										break
									end
								end
								if not duplicateCell then
									local tier = if typeof(rec.tier) == "string" and rec.tier ~= "" then rec.tier :: string else "T1"
									local tierCfg = OilConfig.PumpTiers[tier]
									if not tierCfg then
										tier = "T1"
										tierCfg = OilConfig.PumpTiers["T1"]
									end
									local biome = if typeof(rec.biome) == "string" then rec.biome :: string else chunk.biome
									local biomeConfig = OilConfig.Biomes[biome] or OilConfig.Biomes.Desert
									local pos = positionVectorFromStateEntry(rec.position)
									if not pos then
										local wx, wz = cellToWorld(plot, cellR, cellC)
										pos = Vector3.new(wx, 6, wz)
									end
									local scale = tonumber(rec.scale) or 1
									local flowBase = OilConfig.DrillBaseFlow * biomeConfig.flowMul * tierCfg.flowMultiplier * scale
									local tierMix = emptyTierMap()
									if typeof(rec.tierMix) == "table" then
										local tm = rec.tierMix :: { [string]: any }
										for _, tk in ipairs(TIER_ORDER) do
											local vv = tm[tk]
											if typeof(vv) == "number" then
												tierMix[tk] = floorPositive(vv)
											end
										end
									else
										tierMix = copyTierMap(biomeConfig.tierMix)
									end
									local tileData = chunk.tiles[tileKey] :: any
									local tileOilType = if typeof(rec.tileOilType) == "string" then rec.tileOilType :: string else tileData.oilType
									state.drillsById[drillId] = {
										drillId = drillId,
										chunkId = chunkId,
										biome = biome,
										tier = tier,
										tileKey = tileKey,
										template = (typeof(rec.template) == "string" and rec.template) or tierCfg.templateName,
										scale = scale,
										variant = if typeof(rec.variant) == "string" then rec.variant :: string else nil,
										position = pos,
										flowBase = flowBase,
										tierMix = tierMix,
										tileOilType = tileOilType,
										cellKey = ck,
										cellRow = cellR,
										cellCol = cellC,
										localBuffer = (function()
											local lb = emptyTierMap()
											if typeof(rec.localBuffer) == "table" then
												local lbIn = rec.localBuffer :: { [string]: any }
												for _, tk in ipairs(TIER_ORDER) do
													local vv = lbIn[tk]
													if typeof(vv) == "number" then
														lb[tk] = floorPositive(vv)
													end
												end
											end
											return lb
										end)(),
										connected = rec.connected == true,
										placementCost = floorPositive(tonumber(rec.placementCost) or tierCfg.cost or 0),
										intakeAttachmentId = rec.intakeAttachmentId,
									}
									state.activeDrillCount += 1
								end
							end
						end
					end
				end
			end
		end
		state.nextDrillId = math.max(state.nextDrillId, maxDrillId + 1)
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
					local x, z = cellToWorld(plot, row, col)
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
					row, col = worldToCell(plot, px, pz)
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
	self:_saveUser(userId, true)
	self._statesByUserId[userId] = nil
	self._dirtyByUserId[userId] = nil
end

function OilStateService:_flushDirtyUsers(force: boolean?)
	local ids: { number } = {}
	for userId, _ in pairs(self._dirtyByUserId) do
		table.insert(ids, userId)
	end
	table.sort(ids)
	for i, userId in ipairs(ids) do
		self:_saveUser(userId, force)
		if not force and i < #ids and self._dataStore then
			task.wait(FLUSH_MULTI_USER_SPACING_SECONDS)
		end
	end
end

function OilStateService:_saveUser(userId: number, force: boolean?)
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

	if not force then
		local last = self._lastOilDataStoreSaveClock[userId]
		if last and (os.clock() - last) < MIN_DATASTORE_SET_INTERVAL_SECONDS then
			return
		end
		DataStoreWriteGate.waitForWriteBudget(2.8)
	end

	local ok, err = pcall(function()
		self._dataStore:SetAsync(key, payload)
	end)
	if ok then
		self._lastOilDataStoreSaveClock[userId] = os.clock()
		self._dirtyByUserId[userId] = nil
		return
	end
	if self._dataStore ~= nil and isDatastoreStudioAccessError(err) then
		if not self._dataStoreStudioFallbackWarned then
			self._dataStoreStudioFallbackWarned = true
			warn(
				"[OilStateService] Studio cannot access DataStores (Game Settings → Security → Enable Studio Access to API Services). "
					.. "Using in-session memory for oil profiles for this server run — no cross-session persistence in Studio until enabled."
			)
		end
		self._dataStore = nil
		self._memoryStore[key] = payload
		self._dirtyByUserId[userId] = nil
		return
	end
	warn(string.format("[OilStateService] Save failed for user %d: %s", userId, tostring(err)))
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
	if not ok and self._dataStore ~= nil and isDatastoreStudioAccessError(profileOrErr) then
		if not self._dataStoreStudioFallbackWarned then
			self._dataStoreStudioFallbackWarned = true
			warn(
				"[OilStateService] Studio cannot access DataStores (Game Settings → Security → Enable Studio Access to API Services). "
					.. "Using in-session memory for oil profiles for this server run — no cross-session persistence in Studio until enabled."
			)
		end
		self._dataStore = nil
	elseif not ok then
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
			if chunk.prospected then
				persisted.chunkProspected[chunkId] = true
			end
		end
	end
	persisted.drills = {}
	for _, drill in pairs(state.drillsById) do
		table.insert(persisted.drills, {
			drillId = drill.drillId,
			chunkId = drill.chunkId,
			template = drill.template or OilConfig.DefaultDrillTemplate,
			tier = drill.tier,
			tileKey = drill.tileKey,
			cellRow = drill.cellRow,
			cellCol = drill.cellCol,
			scale = drill.scale or 1,
			variant = drill.variant,
			biome = drill.biome,
			tileOilType = drill.tileOilType,
			position = { x = drill.position.X, y = drill.position.Y, z = drill.position.Z },
			localBuffer = drill.localBuffer and copyTierMap(drill.localBuffer) or emptyTierMap(),
			tierMix = drill.tierMix and copyTierMap(drill.tierMix) or nil,
			intakeAttachmentId = drill.intakeAttachmentId,
			connected = drill.connected == true,
			placementCost = drill.placementCost,
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
	persisted.version = 5
	persisted.shipSpeedLevel = math.clamp(math.floor(state.shipSpeedLevel or 1), 1, ShipUpgradeConfig.MaxSpeedLevel)
	persisted.shipCapacityLevel = math.clamp(math.floor(state.shipCapacityLevel or 1), 1, ShipUpgradeConfig.MaxCapacityLevel)
	persisted.shipSkinId = (typeof(state.shipSkinId) == "string" and state.shipSkinId) or "DefaultTanker"

	persisted.equipmentOwned = {}
	for itemId, n in pairs(state.equipmentOwnedByItemId or {}) do
		local c = floorPositive(n)
		if typeof(itemId) == "string" and itemId ~= "" and c > 0 then
			table.insert(persisted.equipmentOwned, { itemId = itemId, count = c })
		end
	end

	return persisted
end

function OilStateService:SetShipSkinId(userId: number, skinId: string): (boolean, string)
	local state = self._statesByUserId[userId]
	if not state then
		return false, "ERR_NO_STATE"
	end
	if typeof(skinId) ~= "string" or not ShipSkinCatalog.Skins[skinId] then
		return false, "ERR_BAD_SKIN"
	end
	state.shipSkinId = skinId
	self:_markDirty(userId)
	return true, "OK"
end

function OilStateService:TryUpgradeShipSpeed(userId: number): (boolean, string, string)
	local state = self._statesByUserId[userId]
	if not state then
		return false, "ERR_NO_STATE", "State unavailable."
	end
	local level = math.clamp(math.floor(state.shipSpeedLevel or 1), 1, ShipUpgradeConfig.MaxSpeedLevel)
	if level >= ShipUpgradeConfig.MaxSpeedLevel then
		return false, "ERR_MAX_SPEED", "Ship speed is already maxed."
	end
	local cost = ShipUpgradeConfig.GetSpeedUpgradeCost(level)
	if not cost then
		return false, "ERR_MAX_SPEED", "Ship speed is already maxed."
	end
	if not self:TrySpendCash(userId, cost) then
		return false, "ERR_NOT_ENOUGH_CASH", string.format("Need $%d to upgrade speed.", cost)
	end
	state.shipSpeedLevel = level + 1
	self:_markDirty(userId)
	return true, "OK", "Speed upgraded."
end

function OilStateService:TryUpgradeShipCapacity(userId: number): (boolean, string, string)
	local state = self._statesByUserId[userId]
	if not state then
		return false, "ERR_NO_STATE", "State unavailable."
	end
	local level = math.clamp(math.floor(state.shipCapacityLevel or 1), 1, ShipUpgradeConfig.MaxCapacityLevel)
	if level >= ShipUpgradeConfig.MaxCapacityLevel then
		return false, "ERR_MAX_CAPACITY", "Ship capacity is already maxed."
	end
	local cost = ShipUpgradeConfig.GetCapacityUpgradeCost(level)
	if not cost then
		return false, "ERR_MAX_CAPACITY", "Ship capacity is already maxed."
	end
	if not self:TrySpendCash(userId, cost) then
		return false, "ERR_NOT_ENOUGH_CASH", string.format("Need $%d to upgrade capacity.", cost)
	end
	state.shipCapacityLevel = level + 1
	self:_markDirty(userId)
	return true, "OK", "Capacity upgraded."
end

function OilStateService:AddShopEquipmentOwned(userId: number, itemId: string, count: number)
	if typeof(itemId) ~= "string" or itemId == "" or count <= 0 then
		return
	end
	local state = self._statesByUserId[userId]
	if not state then
		return
	end
	state.equipmentOwnedByItemId[itemId] = (state.equipmentOwnedByItemId[itemId] or 0) + floorPositive(count)
	self:_markDirty(userId)
end

function OilStateService:NotifyShopToolConsumed(userId: number, itemId: string)
	if typeof(itemId) ~= "string" or itemId == "" then
		return
	end
	local state = self._statesByUserId[userId]
	if not state then
		return
	end
	local cur = state.equipmentOwnedByItemId[itemId] or 0
	if cur <= 0 then
		return
	end
	local nxt = cur - 1
	if nxt <= 0 then
		state.equipmentOwnedByItemId[itemId] = nil
	else
		state.equipmentOwnedByItemId[itemId] = nxt
	end
	self:_markDirty(userId)
end

function OilStateService:MarkEquipmentInventoryBackfillComplete(userId: number)
	local state = self._statesByUserId[userId]
	if not state then
		return
	end
	state.equipmentOwnedNeedsInventoryBackfill = false
	self:_markDirty(userId)
end

return OilStateService
