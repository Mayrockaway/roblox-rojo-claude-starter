--!strict

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local DataStoreWriteGate = require(script.Parent.Parent.Utils.DataStoreWriteGate)
local OilConfig = require(Shared:WaitForChild("Config"):WaitForChild("OilConfig"))
local BiomeConfig = require(Shared:WaitForChild("Config"):WaitForChild("BiomeConfig"))
local ShipSkinCatalog = require(Shared:WaitForChild("Config"):WaitForChild("ShipSkinCatalog"))
local ShipStats = require(Shared:WaitForChild("Config"):WaitForChild("ShipStats"))
local ShipUpgradeConfig = require(Shared:WaitForChild("Config"):WaitForChild("ShipUpgradeConfig"))
local ShipProfileMigration = require(Shared:WaitForChild("Config"):WaitForChild("ShipProfileMigration"))
local OilTankConfig = require(Shared:WaitForChild("Config"):WaitForChild("OilTankConfig"))
local FtueConfig = require(Shared:WaitForChild("Config"):WaitForChild("FtueConfig"))
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))
local DevLog = require(Shared:WaitForChild("DevLog"))

local OilStateService = {}

--- Set once from `init.server` after `FtueService` is required; used for placement → FTUE hooks.
local _ftueService: any = nil

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

--- Fresh economy when FTUE is on uses `FtueConfig`; otherwise `OilConfig.StartingCash` ($500 legacy default).
local function initialStartingCash(): number
	if FtueConfig.Enabled == true then
		return floorPositive(tonumber(FtueConfig.StartingCash) or 0)
	end
	return OilConfig.StartingCash
end

local function initialFtueEscortShipmentRemaining(): number
	if FtueConfig.Enabled == true then
		return 1
	end
	return 0
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
		version = 7,
		cash = initialStartingCash(),
		ftueEscortShipmentRemaining = initialFtueEscortShipmentRemaining(),
		ftueDispatchCashGranted = false,
		ftueTutorialCompleteCashGranted = false,
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
		nextProspectId = 1,
		nextPipeId = 1,
		nextDrumId = 1,
		nextAttachmentId = 1,
		activeDrills = {},
		activeProspectors = {},
		shipSpeedLevel = 1,
		shipCapacityLevel = 1,
		shipSkinId = "DefaultTanker",
		ftueStep = if FtueConfig.Enabled then FtueConfig.Step.Intro else nil,
		ftueCompleted = not FtueConfig.Enabled,
		ftueDoneScreenAcknowledged = false,
	}
end

local function emptyTierMap()
	return {
		HeavyCrude = 0,
		LightSweet = 0,
		PremiumRefined = 0,
	}
end

local function defaultTankTiers()
	return {
		HeavyCrude = 1,
		LightSweet = 1,
		PremiumRefined = 1,
	}
end

-- Capacity of a single tank (per oil type). Reads per-player tier from state.
local function tankCapacity(state, oilType: string): number
	local tier = state.tankTiers and state.tankTiers[oilType] or 1
	return OilTankConfig.GetCapacity(tier)
end

local function totalTankCapacity(state): number
	local sum = 0
	for _, tier in ipairs(TIER_ORDER) do
		sum += tankCapacity(state, tier)
	end
	return sum
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
	local sectionCenterCount = 0
	local ground = plot:FindFirstChild("PlotGround")
	if ground then
		local totalX, totalZ = 0, 0
		for _, section in ipairs(ground:GetChildren()) do
			if section:IsA("Model") then
				local cx = section:GetAttribute("CenterX")
				local cz = section:GetAttribute("CenterZ")
				if typeof(cx) == "number" and typeof(cz) == "number" then
					totalX += cx
					totalZ += cz
					sectionCenterCount += 1
				end
			end
		end
		if sectionCenterCount > 0 then
			centerX = totalX / sectionCenterCount
			centerZ = totalZ / sectionCenterCount
		else
			warn(string.format("[OilStateService] %s has no CenterX/CenterZ attributes on PlotGround sections", plot.Name))
		end
	end

	local startX = centerX - ((s.sectionCols - 1) / 2) * s.sectionSize
	local startZ = centerZ - ((s.sectionRows - 1) / 2) * s.sectionSize
	local cellOriginX = startX - ((s.subTilesPerSide - 1) / 2) * SUB_TILE_SIZE
	local cellOriginZ = startZ - ((s.subTilesPerSide - 1) / 2) * SUB_TILE_SIZE

	local origin = { cellOriginX = cellOriginX, cellOriginZ = cellOriginZ }
	-- Never cache a grid built from (0,0) when sections had no CenterX/CenterZ yet: that poisons
	-- `_gridOriginByPlotId` for the whole session and intermittently misplaces active drills.
	if sectionCenterCount > 0 then
		_gridOriginByPlotId[plotId] = origin
	end
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

-- Global grid cell (1..globalRows/Cols) → local sub-tile key `T11`..`T55` within that section.
local function globalCellToLocalTileKey(row: number, col: number): string
	local s = staticGridConstants()
	local sRow = math.floor((row - 1) / s.subTilesPerSide) + 1
	local sCol = math.floor((col - 1) / s.subTilesPerSide) + 1
	local localR = row - (sRow - 1) * s.subTilesPerSide
	local localC = col - (sCol - 1) * s.subTilesPerSide
	return string.format("T%d%d", localR, localC)
end

local function inBoundsCell(row: number, col: number): boolean
	local s = staticGridConstants()
	return row >= 1 and row <= s.globalRows and col >= 1 and col <= s.globalCols
end

local function localTileToGlobalCell(sectionId: string, tileKey: string): (number?, number?)
	local sRowStr, sColStr = string.match(sectionId, "^S(%d+)_(%d+)$")
	local tRowStr, tColStr = string.match(tileKey, "^T(%d)(%d)$")
	local sRow = tonumber(sRowStr)
	local sCol = tonumber(sColStr)
	local tRow = tonumber(tRowStr)
	local tCol = tonumber(tColStr)
	if not sRow or not sCol or not tRow or not tCol then
		return nil, nil
	end
	local s = staticGridConstants()
	local row = (sRow - 1) * s.subTilesPerSide + tRow
	local col = (sCol - 1) * s.subTilesPerSide + tCol
	return row, col
end

local function findTilePartForCell(plot: Model, row: number, col: number): BasePart?
	if not inBoundsCell(row, col) then
		return nil
	end
	local ground = plot:FindFirstChild("PlotGround")
	if not (ground and ground:IsA("Model")) then
		return nil
	end
	local sectionId = cellToSectionId(row, col)
	local section = ground:FindFirstChild(sectionId)
	if not (section and section:IsA("Model")) then
		return nil
	end
	local tileKey = globalCellToLocalTileKey(row, col)
	local inst = section:FindFirstChild(tileKey, true)
	if inst and inst:IsA("BasePart") then
		return inst
	end
	if inst and inst:IsA("Model") then
		if inst.PrimaryPart and inst.PrimaryPart:IsA("BasePart") then
			return inst.PrimaryPart
		end
		for _, d in ipairs(inst:GetDescendants()) do
			if d:IsA("BasePart") then
				return d
			end
		end
	end
	for _, d in ipairs(section:GetDescendants()) do
		if d:IsA("BasePart") and d.Name == tileKey then
			return d
		end
	end
	return nil
end

local function findNearestPlotTileCell(plot: Model, worldPos: Vector3): (number?, number?, BasePart?)
	local ground = plot:FindFirstChild("PlotGround")
	if not (ground and ground:IsA("Model")) then
		return nil, nil, nil
	end
	local nearestTile: BasePart? = nil
	local nearestDist = math.huge
	for _, d in ipairs(ground:GetDescendants()) do
		if d:IsA("BasePart") and d.Name:match("^T%d%d$") then
			local dx = d.Position.X - worldPos.X
			local dz = d.Position.Z - worldPos.Z
			local dist2 = dx * dx + dz * dz
			if dist2 < nearestDist then
				nearestDist = dist2
				nearestTile = d
			end
		end
	end
	if not nearestTile then
		return nil, nil, nil
	end
	local tileKey = nearestTile.Name
	local sectionId = nil :: string?
	local node: Instance? = nearestTile
	while node and node.Parent and node.Parent ~= ground do
		node = node.Parent
	end
	if node and node:IsA("Model") then
		sectionId = node.Name
	end
	if not sectionId then
		return nil, nil, nearestTile
	end
	local row, col = localTileToGlobalCell(sectionId, tileKey)
	return row, col, nearestTile
end

local function pickNeighborCellByDirection(plot: Model, row: number, col: number, dir: Vector3): (number?, number?)
	local dirXZ = Vector3.new(dir.X, 0, dir.Z)
	if dirXZ.Magnitude < 0.001 then
		return nil, nil
	end
	local originTile = findTilePartForCell(plot, row, col)
	if not originTile then
		return nil, nil
	end
	local originPos = originTile.Position
	local bestRow, bestCol = nil, nil
	local bestScore = -math.huge
	local candidates = {
		{ row - 1, col },
		{ row + 1, col },
		{ row, col - 1 },
		{ row, col + 1 },
	}
	for _, rc in ipairs(candidates) do
		local rr, cc = rc[1], rc[2]
		if inBoundsCell(rr, cc) then
			local tile = findTilePartForCell(plot, rr, cc)
			if tile then
				local dv = Vector3.new(tile.Position.X - originPos.X, 0, tile.Position.Z - originPos.Z)
				if dv.Magnitude > 0.001 then
					local score = dv.Unit:Dot(dirXZ.Unit)
					if score > bestScore then
						bestScore = score
						bestRow = rr
						bestCol = cc
					end
				end
			end
		end
	end
	return bestRow, bestCol
end

local function cellInBounds(row: number, col: number): boolean
	return inBoundsCell(row, col)
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
	self._boatDockService = nil :: any
	self._skinChangedHandler = nil :: ((number, string) -> ())?
	self._stateReadyForTimersCallback = nil :: ((number, { any }, { any }) -> ())?
	self._pipeNetworkService = nil :: any
	self._dataStore = nil
	self._devSkipSaveOnNextDrop = {} :: { [number]: boolean }
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

function OilStateService:SetFtueService(ftueService: any)
	_ftueService = ftueService
end

function OilStateService:SetPipeNetworkService(pipeNetworkService: any)
	self._pipeNetworkService = pipeNetworkService
end

--- Clears tutorial-only placement flags so hammer sellback / removal works after FTUE (and old saves cannot keep protection).
function OilStateService:_clearFtuePlacementNoSellback(state: any): boolean
	local changed = false
	for _, pump in pairs(state.drillsById or {}) do
		if pump.ftueFreeNoSellback == true then
			pump.ftueFreeNoSellback = false
			changed = true
		end
	end
	for _, pipe in pairs(state.pipesByCellKey or {}) do
		if pipe.ftueFreeNoSellback == true then
			pipe.ftueFreeNoSellback = false
			changed = true
		end
	end
	for _, active in pairs(state.activeDrills or {}) do
		if active.ftueFreeNoSellback == true then
			active.ftueFreeNoSellback = false
			changed = true
		end
	end
	return changed
end

--- Persists FTUE step with oil profile (`_markDirty`). Called from `FtueService` only.
function OilStateService:SetFtueProgress(userId: number, step: string?)
	local state = self._statesByUserId[userId]
	if not state then
		return
	end
	state.ftueStep = step
	--- `ftueCompleted` = tutorial **fully** finished (after Complete! on Done); `ftueStep == Done` is still in-progress.
	state.ftueCompleted = (step == nil)
	if step == nil then
		self:_clearFtuePlacementNoSellback(state)
	end
	-- Tutorial escort vessel is only for the first dispatch during `Dispatch`; never after FTUE completes or past that leg.
	if state.ftueCompleted or step == FtueConfig.Step.Done or step == FtueConfig.Step.WaitShipment then
		state.ftueEscortShipmentRemaining = 0
	end
	if FtueConfig.DebugTrace == true then
		warn(
			string.format(
				"[FTUE][OilState] SetFtueProgress uid=%d step=%s -> ftueStep=%s ftueCompleted=%s",
				userId,
				tostring(step),
				tostring((state :: any).ftueStep),
				tostring((state :: any).ftueCompleted)
			)
		)
	end
	self:_markDirty(userId)
	if step == nil then
		self:PushState(userId)
	end
end

--- After the player dismisses the final FTUE "Done" dialogue; keeps `FtueStep` from re-applying that screen on reload.
function OilStateService:SetFtueDoneScreenAcknowledged(userId: number, acknowledged: boolean)
	local state = self._statesByUserId[userId]
	if not state then
		return
	end
	(state :: any).ftueDoneScreenAcknowledged = acknowledged
	self:_markDirty(userId)
end

--- Fired after a plot profile is loaded into memory: `(userId, drillCompletions, prospectCompletions)`.
--- Used to replay completed timers that finished while offline and to schedule remaining delays.
function OilStateService:SetStateReadyForTimersCallback(cb: (number, { any }, { any }) -> ())
	self._stateReadyForTimersCallback = cb
end

-- Rehydrate runs synchronously so the first `PushState` after assign does not show stale in-progress ops.
-- Client VFX replay + `task.delay` wiring is deferred until `DrillingService` / `ProspectingService` have started.
function OilStateService:_invokeStateTimersReady(userId: number)
	local drillDone, prospectDone = self:RehydrateExpiredTimers(userId)
	task.defer(function()
		local cb = self._stateReadyForTimersCallback
		if not cb then
			return
		end
		cb(userId, drillDone, prospectDone)
	end)
end

function OilStateService:Start()
	self._running = true

	table.insert(self._connections, self._plotService:OnPlotAssigned(function(userId: number, plot: Model)
		self:_ensurePlayerState(userId, plot)
		if _ftueService and typeof((_ftueService :: any).SyncFromOilState) == "function" then
			(_ftueService :: any):SyncFromOilState(userId)
		end
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
			if _ftueService and typeof((_ftueService :: any).SyncFromOilState) == "function" then
				(_ftueService :: any):SyncFromOilState(player.UserId)
			end
			self:PushState(player.UserId)
		end
	end

	-- `OilVisualService:Start()` runs after this `Start()`; the bootstrap `PushState` above would not
	-- reach `OnStateChanged` yet. Re-push once sibling services have wired listeners so ActiveDrill_* reclones.
	task.defer(function()
		if not self._running then
			return
		end
		for _, player in ipairs(Players:GetPlayers()) do
			local uid = player.UserId
			if self._statesByUserId[uid] and self._plotService:GetOwnedPlot(uid) then
				self:PushState(uid)
			end
		end
	end)
end

function OilStateService:Stop()
	self._running = false
	-- Save every in-memory profile (dirty-only flush misses users whose dirty flag cleared after last autosave).
	for uid, _ in pairs(self._statesByUserId) do
		self:_saveUser(uid, true, true)
	end

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

-- DataStore / JSON may use `{x,y,z}` or `{X,Y,Z}`; runtime uses `Vector3`.
local function worldXYZFromPersistedPosition(pos: any): (number?, number?, number?)
	if typeof(pos) == "Vector3" then
		local v = pos :: Vector3
		return v.X, v.Y, v.Z
	end
	if typeof(pos) == "table" then
		local t = pos :: { [any]: any }
		local px = tonumber(t.x) or tonumber(t.X) or tonumber(t[1])
		local py = tonumber(t.y) or tonumber(t.Y) or tonumber(t[2])
		local pz = tonumber(t.z) or tonumber(t.Z) or tonumber(t[3])
		if px and py and pz then
			return px, py, pz
		end
	end
	return nil, nil, nil
end

local function globalCellFromCellKeyString(ck: string): (number?, number?)
	local r, c = string.match(ck, "^R(%d+)C(%d+)$")
	return tonumber(r), tonumber(c)
end

-- `state.plot` can point at a destroyed/stale Model after Studio rejoin while PlotService already
-- references the live plot; fall back to GetOwnedPlot for grid math.
local function activeDrillWorldFromStateEntry(plotForGrid: Model?, e: { [string]: any }): (number?, number?, number?)
	-- Fall back to stored position only if we can't derive from cell/tile, since
	-- stored coords may be stale (different plot from previous session).
	if typeof(plotForGrid) == "Instance" and plotForGrid:IsA("Model") then
		local row = tonumber(e.cellRow) or tonumber(e.row)
		local col = tonumber(e.cellCol) or tonumber(e.col)
		if (not row or not col) and typeof(e.cellKey) == "string" then
			row, col = globalCellFromCellKeyString(e.cellKey :: string)
		end
		if row and col and cellInBounds(row, col) then
			local wx, wz = cellToWorld(plotForGrid :: Model, row, col)
			-- Never hardcode Y=6: plots live at real elevation; stale Y breaks salvage range vs HRP.
			local px, py, pz = worldXYZFromPersistedPosition(e.position)
			if px and py and pz then
				return wx, py, wz
			end
			return wx, 6, wz
		end
	end
	local px, py, pz = worldXYZFromPersistedPosition(e.position)
	if px and py and pz then
		return px, py, pz
	end
	return nil, nil, nil
end

-- Uses authored section/tile parts (same as OilVisualService puddle placement) when analytic
-- `cellToWorld` is unavailable or was skipped due to missing grid metadata.
local function activeDrillWorldFromChunkTile(plotService: any, plot: Model?, chunkId: any, tileKey: any): (number?, number?, number?)
	if typeof(plot) ~= "Instance" or not plot:IsA("Model") then
		return nil, nil, nil
	end
	if typeof(chunkId) ~= "string" or chunkId == "" then
		return nil, nil, nil
	end
	if typeof(tileKey) ~= "string" or tileKey == "" then
		return nil, nil, nil
	end
	local section = plotService:GetChunkModel(plot, chunkId)
	if not section then
		return nil, nil, nil
	end
	local tile = plotService:FindChunkTileBasePart(section, tileKey)
	if not (tile and tile:IsA("BasePart")) then
		return nil, nil, nil
	end
	local topY = tile.Position.Y + tile.Size.Y / 2
	return tile.Position.X, topY, tile.Position.Z
end

function OilStateService:_plotModelForGrid(userId: number, state: any): Model?
	local sp = state.plot
	if typeof(sp) == "Instance" and sp:IsA("Model") and sp:IsDescendantOf(workspace) then
		return sp :: Model
	end
	local owned = self._plotService:GetOwnedPlot(userId)
	if typeof(owned) == "Instance" and owned:IsA("Model") then
		return owned
	end
	return nil
end

function OilStateService:GetStateForClient(userId: number)
	local state = self._statesByUserId[userId]
	if not state then
		return nil
	end

	local plotForGrid = self:_plotModelForGrid(userId, state)

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
			tileOilType = drill.tileOilType,
			flowBase = drill.flowBase,
			cellKey = drill.cellKey,
			cellRow = drill.cellRow,
			cellCol = drill.cellCol,
			bufferTotal = bufferTotal,
			bufferCap = (OilConfig.DrillBufferCapacity or 20) * #TIER_ORDER,
			ftueFreeNoSellback = drill.ftueFreeNoSellback == true,
		})
	end

	local activeProspectors = {}
	for _, entry in pairs(state.activeProspectors or {}) do
		if typeof(entry) == "table" then
			local e = entry :: { [string]: any }
			local px, py, pz = worldXYZFromPersistedPosition(e.position)
			if px and py and pz then
				table.insert(activeProspectors, {
					prospectId = e.prospectId,
					chunkId = e.chunkId,
					tileKey = e.tileKey,
					template = e.template,
					position = { x = px, y = py, z = pz },
					startTime = e.startTime,
					endTime = e.endTime,
				})
			end
		end
	end

	local activeDrills = {}
	local nowT = workspace:GetServerTimeNow()
	for key, entry in pairs(state.activeDrills or {}) do
		if typeof(entry) == "table" then
			local e = entry :: { [string]: any }
			local drillId = typeof(e.drillId) == "number" and e.drillId or tonumber(e.drillId) or tonumber(key)
			if typeof(drillId) == "number" then
				-- Prefer authoritative tile-part position over stored/formula coords — the
				-- formula drifts on authored 8.26-stud tile spacing and stored coords are
				-- stale across cross-plot rejoins.
				local px, py, pz = nil, nil, nil
				if plotForGrid then
					px, py, pz = activeDrillWorldFromChunkTile(self._plotService, plotForGrid, e.chunkId, e.tileKey)
				end
				if not (px and py and pz) then
					px, py, pz = activeDrillWorldFromStateEntry(plotForGrid, e)
				end
				if px and py and pz then
					local st = tonumber(e.startTime) or nowT
					local et = tonumber(e.endTime) or (st + 1)
					table.insert(activeDrills, {
						drillId = drillId,
						chunkId = e.chunkId,
						tier = e.tier,
						tileKey = e.tileKey,
						template = e.template,
						position = { x = px, y = py, z = pz },
						cellRow = e.cellRow,
						cellCol = e.cellCol,
						cellKey = e.cellKey,
						startTime = st,
						endTime = et,
						remaining = math.max(0, et - nowT),
						oilType = e.oilType,
						ftueFreeNoSellback = e.ftueFreeNoSellback == true,
					})
				else
					-- Do not mutate `state.activeDrills` here: a transient missing/stale `state.plot` would
					-- delete valid in-progress ops. Omit from this snapshot only; next push may resolve.
					DevLog.log(string.format(
						"[OilState] activeDrill omitted from snapshot user=%d key=%s id=%s (no world position yet)",
						userId,
						tostring(key),
						tostring(drillId)
					))
				end
			end
		end
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
			isCorePipe = pipe.isCorePipe == true,
			ftueFreeNoSellback = pipe.ftueFreeNoSellback == true,
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
			isCoreDrum = drum.isCoreDrum == true,
		})
	end

	local tankTiers = {
		HeavyCrude = OilTankConfig.ClampTier(state.tankTiers and state.tankTiers.HeavyCrude or 1),
		LightSweet = OilTankConfig.ClampTier(state.tankTiers and state.tankTiers.LightSweet or 1),
		PremiumRefined = OilTankConfig.ClampTier(state.tankTiers and state.tankTiers.PremiumRefined or 1),
	}
	local tankCapacities = {
		HeavyCrude = OilTankConfig.GetCapacity(tankTiers.HeavyCrude),
		LightSweet = OilTankConfig.GetCapacity(tankTiers.LightSweet),
		PremiumRefined = OilTankConfig.GetCapacity(tankTiers.PremiumRefined),
	}
	local tankUpgradeCosts = {
		HeavyCrude = OilTankConfig.GetUpgradeCost(tankTiers.HeavyCrude),
		LightSweet = OilTankConfig.GetUpgradeCost(tankTiers.LightSweet),
		PremiumRefined = OilTankConfig.GetUpgradeCost(tankTiers.PremiumRefined),
	}

	return {
		plotId = state.plotId,
		cash = state.cash,
		totalOil = state.totalOil,
		storageCapacity = state.storageCapacity,
		oilByTier = copyTierMap(state.oilByTier),
		tankTiers = tankTiers,
		tankCapacities = tankCapacities,
		tankUpgradeCosts = tankUpgradeCosts,
		activeDrillCount = state.activeDrillCount,
		stalledDrillCount = stalledCount,
		maxActiveDrills = maxActiveDrillsFor(state),
		activeShipmentCount = state.activeShipmentCount,
		boatState = (self._boatDockService and self._boatDockService:GetState(userId)) or nil,
		boatCooldownEndsAt = (self._boatDockService and self._boatDockService:GetCooldownEndsAt(userId)) or nil,
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
	local perf = _G.Perf
	local hBuild = perf and perf:OpenSpan("PushState.build")
	local snapshot = self:GetStateForClient(userId)
	if hBuild then perf:CloseSpan("PushState.build", hBuild) end
	if self._stateChangedEvent and snapshot then
		self._stateChangedEvent:Fire(userId, snapshot)
	end

	local player = Players:GetPlayerByUserId(userId)
	if not player or not snapshot then
		return
	end
	local event = self._remoteService:GetEvent(RemoteNames.OilStateUpdate)
	local hFire = perf and perf:OpenSpan("PushState.fire")
	event:FireClient(player, snapshot)
	if hFire then perf:CloseSpan("PushState.fire", hFire) end
	if perf then
		perf:Count("PushState")
	end
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
	DevLog.log(string.format("[TryBuyChunk] user=%d chunkId=%s", userId, tostring(chunkId)))
	local state = self._statesByUserId[userId]
	if not state then
		DevLog.log("[TryBuyChunk] FAIL: no state")
		return false, "ERR_NO_STATE", "State unavailable."
	end
	local chunk = state.chunksById[chunkId]
	if not chunk then
		DevLog.log(string.format("[TryBuyChunk] FAIL: chunk not in state. Known=%d",
			(function() local n=0; for _ in pairs(state.chunksById) do n+=1 end; return n end)()))
		return false, "ERR_BAD_CHUNK", "Chunk does not exist."
	end
	if chunk.unlocked then
		DevLog.log(string.format("[TryBuyChunk] FAIL: already unlocked row=%d col=%d", chunk.row, chunk.col))
		return false, "ERR_ALREADY_UNLOCKED", "Chunk already unlocked."
	end
	if not hasUnlockedNeighbor(state, chunk.row, chunk.col) then
		-- Dump current unlocked chunks for diagnosis
		local unlockedList = {}
		for _, c in pairs(state.chunksById) do
			if c.unlocked then table.insert(unlockedList, string.format("%s(r=%d,c=%d)", c.chunkId, c.row, c.col)) end
		end
		DevLog.log(string.format("[TryBuyChunk] FAIL not adjacent. want neighbor of row=%d col=%d. Unlocked=[%s]",
			chunk.row, chunk.col, table.concat(unlockedList, ",")))
		return false, "ERR_NOT_ADJACENT", "You can only buy a chunk next to one you already own."
	end
	local cost = chunkUnlockCost(chunk.row, chunk.col)
	if not self:TrySpendCash(userId, cost) then
		DevLog.log(string.format("[TryBuyChunk] FAIL not enough cash. need=%d have=%d", cost, state.cash or -1))
		return false, "ERR_NOT_ENOUGH_CASH", string.format("Need $%d to buy this chunk.", cost)
	end
	DevLog.log(string.format("[TryBuyChunk] OK user=%d chunkId=%s row=%d col=%d cost=%d",
		userId, chunkId, chunk.row, chunk.col, cost))

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

-- Returns true if (x,z) is on any tile whose parent section matches this chunk,
-- by locating the nearest tile Instance on the plot. Authoritative (uses actual
-- authored tile positions, not formula-assumed 8-stud spacing).
local function pointInsideChunkOnPlot(plot: Model?, chunk, x: number, z: number): boolean
	if not plot then return false end
	local ground = plot:FindFirstChild("PlotGround")
	if not ground then return false end
	local nearest, nearestDist = nil, math.huge
	for _, sect in ipairs(ground:GetChildren()) do
		if sect:IsA("Model") then
			for _, t in ipairs(sect:GetDescendants()) do
				if t:IsA("BasePart") and t.Name:match("^T%d%d$") then
					local dx = t.Position.X - x
					local dz = t.Position.Z - z
					local d2 = dx*dx + dz*dz
					if d2 < nearestDist then
						nearestDist = d2
						nearest = t
					end
				end
			end
		end
	end
	if not nearest then return false end
	-- Nearest tile must be inside a section whose ChunkId matches this chunk.
	local sect = nearest.Parent
	return sect ~= nil and sect:GetAttribute("ChunkId") == chunk.chunkId
end

-- Back-compat signature shim (some callers only have chunk info, no plot).
local function pointInsideChunk(chunk, x: number, z: number): boolean
	local size = OilConfig.Chunks.Size
	local half = size / 2
	return math.abs(x - chunk.worldX) <= half and math.abs(z - chunk.worldZ) <= half
end

-- Resolve which "Trr" / "Tcc" tile in a chunk contains world position (x, z).
-- Returns (tileKey, tile) or (nil, nil) if out of range or tiles not generated yet.
local function resolveTileAt(plot: Model, chunk, x: number, z: number): (string?, any?)
	if not chunk or not chunk.tiles then return nil, nil end
	-- Authoritative: find the nearest T## BasePart inside THIS chunk's section model.
	-- Beats the formula-based worldToCell for plots with non-8-stud tile spacing.
	local ground = plot and plot:FindFirstChild("PlotGround")
	local section = ground and ground:FindFirstChild(chunk.chunkId)
	if section then
		local nearest, nearestDist = nil, math.huge
		for _, t in ipairs(section:GetDescendants()) do
			if t:IsA("BasePart") and t.Name:match("^T%d%d$") then
				local dx = t.Position.X - x
				local dz = t.Position.Z - z
				local d2 = dx*dx + dz*dz
				if d2 < nearestDist then
					nearestDist = d2
					nearest = t
				end
			end
		end
		if nearest then
			local key = nearest.Name
			return key, chunk.tiles[key]
		end
	end
	-- Fallback to formula (legacy paths).
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

local function tileKeyToLocalRowCol(tileKey: string): (number?, number?)
	local a, b = string.match(tileKey, "^T(%d)(%d)$")
	local r = tonumber(a)
	local c = tonumber(b)
	if not r or not c then
		return nil, nil
	end
	return r, c
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

	local plot = state.plot or self._plotService:GetOwnedPlot(userId)
	if not plot then return false, "ERR_NO_PLOT", "No plot owned." end
	if not pointInsideChunkOnPlot(plot, chunk, x, z) then
		return false, "ERR_OUT_OF_CHUNK", "Position is not on the targeted chunk."
	end

	local tileKey, _tile = resolveTileAt(plot, chunk, x, z)
	local cellR, cellC
	if typeof(tileKey) == "string" then
		local localR, localC = tileKeyToLocalRowCol(tileKey)
		local s = staticGridConstants()
		if localR and localC and typeof(chunk.row) == "number" and typeof(chunk.col) == "number" then
			cellR = (chunk.row - 1) * s.subTilesPerSide + localR
			cellC = (chunk.col - 1) * s.subTilesPerSide + localC
		end
	end
	if typeof(cellR) ~= "number" or typeof(cellC) ~= "number" then
		cellR, cellC = worldToCell(plot, x, z)
	end
	local ck = cellKey(cellR, cellC)
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

	-- Snap XYZ to the actual tile instance (recursive search — tiles may sit under folders).
	-- Y must be the tile's top surface; never leave client `payload.y` (can be StartBeach / void ray).
	local snappedX, snappedZ = x, z
	if typeof(tileKey) == "string" then
		local topY = self._plotService:GetChunkTileSurfaceWorldY(plot, chunkId, tileKey)
		local sectionModel = self._plotService:GetChunkModel(plot, chunkId)
		if topY and sectionModel then
			y = topY
			local tilePart = self._plotService:FindChunkTileBasePart(sectionModel, tileKey)
			if tilePart then
				snappedX = tilePart.Position.X
				snappedZ = tilePart.Position.Z
			end
		elseif sectionModel then
			-- Fallback: highest T## surface in section (legacy flat layout).
			local bestTop: number? = nil
			for _, d in ipairs(sectionModel:GetDescendants()) do
				if d:IsA("BasePart") and d.Name:match("^T%d%d$") then
					local surface = d.Position.Y + d.Size.Y / 2
					if bestTop == nil or surface > bestTop then
						bestTop = surface
					end
				end
			end
			if bestTop then
				y = bestTop
			end
		end
	end

	return true, "OK", "", chunk, tileKey, snappedX, y, snappedZ, cellR, cellC
end

-- Complete any in-progress drills/prospects whose `endTime` is already past (e.g. while offline).
-- Returns payloads matching `CompleteDrill` / `CompleteProspect` for replaying client VFX.
function OilStateService:RehydrateExpiredTimers(userId: number): ({ any }, { any })
	local state = self._statesByUserId[userId]
	if not state then
		return {}, {}
	end
	local now = workspace:GetServerTimeNow()
	local drillIds: { number } = {}
	for drillId, entry in pairs(state.activeDrills or {}) do
		if typeof((entry :: any).endTime) == "number" and (entry :: any).endTime <= now then
			table.insert(drillIds, drillId)
		end
	end
	local drillDone: { any } = {}
	for _, drillId in ipairs(drillIds) do
		local ok, data = self:CompleteDrill(userId, drillId)
		if ok and data then
			table.insert(drillDone, data)
		end
	end
	local prospectIds: { number } = {}
	for prospectId, entry in pairs(state.activeProspectors or {}) do
		if typeof((entry :: any).endTime) == "number" and (entry :: any).endTime <= now then
			table.insert(prospectIds, prospectId)
		end
	end
	local prospectDone: { any } = {}
	for _, prospectId in ipairs(prospectIds) do
		local ok, data = self:CompleteProspect(userId, prospectId)
		if ok and data then
			table.insert(prospectDone, data)
		end
	end
	if #drillIds + #prospectIds > 0 then
		self:_markDirty(userId)
	end
	return drillDone, prospectDone
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
	local ftueDrillCell = readFtueCellAttribute(userId, Constants.FtueRestrictDrillCellKeyAttribute)
	if ftueDrillCell and ftueDrillCell ~= ck then
		return false, "ERR_FTUE_WRONG_TILE", FtueConfig.WrongTileDrill, nil
	end
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

	-- Placement does NOT charge cash. Cash was spent at the shop. Placement only
	-- consumes the tool stack (handled by the calling service).

	local drillId = state.nextDrillId
	state.nextDrillId += 1

	-- Effective duration = tile.drillSeconds / tier.timeDivisor (1/10/30 for T1/T2/T3).
	-- T1 at 1x is normal speed; T2 drills 10x faster, T3 drills 30x faster.
	local baseSeconds = (tile and tonumber(tile.drillSeconds)) or tierCfg.fallbackSeconds or 10
	local effectiveSeconds = math.max(0.5, baseSeconds / (tierCfg.timeDivisor or 1))
	local plr = Players:GetPlayerByUserId(userId)
	local ftueStep = plr and plr:GetAttribute(Constants.FtueStepAttribute)
	local ftueFreeNoSellback = (
		FtueConfig.Enabled == true
		and ftueDrillCell ~= nil
		and ftueDrillCell == ck
		and typeof(ftueStep) == "string"
		and ftueStep == FtueConfig.Step.WaitDrill
	)
	if ftueFreeNoSellback then
		effectiveSeconds = math.max(0.5, tonumber(FtueConfig.FtueTutorialDrillSeconds) or 5)
	end

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
		ftueFreeNoSellback = ftueFreeNoSellback,
	}
	state.activeDrills[drillId] = entry
	self:_markDirty(userId)
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
		cellKey = entry.cellKey,
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

	-- Placement does NOT charge cash. Cash was spent at the shop.

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
	self:_markDirty(userId)

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
	local plrPump = Players:GetPlayerByUserId(userId)
	local ftueStepPump = plrPump and plrPump:GetAttribute(Constants.FtueStepAttribute)
	local ftueFreeNoSellbackPump = (
		FtueConfig.Enabled == true
		and ftuePumpCell ~= nil
		and ftuePumpCell == ck
		and typeof(ftueStepPump) == "string"
		and ftueStepPump == FtueConfig.Step.WaitPump
	)
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

	-- Placement does NOT charge cash. Cash was spent at the shop.

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
		ftueFreeNoSellback = ftueFreeNoSellbackPump,
	}
	state.drillsById[pumpId] = pump
	state.activeDrillCount += 1
	self:_markDirty(userId)

	-- FTUE free pump: connectivity was only updated on the next production tick (~1s), and flow is fractional
	-- (e.g. 0.2/s) so the first inventory barrel could take many seconds. Refresh pipes now + grant 1 barrel
	-- of this tile's oil so the HUD updates immediately after placement.
	if ftueFreeNoSellbackPump and self._pipeNetworkService then
		(self._pipeNetworkService :: any):MarkConnectivityForTick(state)
		local grantTier = typeof(tile.oilType) == "string" and tile.oilType or "HeavyCrude"
		if OilTankConfig.OilColors[grantTier] == nil then
			grantTier = "HeavyCrude"
		end
		local cap = tankCapacity(state, grantTier)
		local have = state.oilByTier[grantTier] or 0
		if cap > have then
			state.oilByTier[grantTier] = have + 1
			state.totalOil += 1
			self:_markDirty(userId)
			self:PushState(userId)
		end
	end

	if FtueConfig.Enabled and _ftueService and typeof((_ftueService :: any).OnFtueTutorialPumpPlaced) == "function" then
		(_ftueService :: any):OnFtueTutorialPumpPlaced(userId, ck)
	end

	return true, "OK", "Pump placed.", { drillId = pumpId, pumpId = pumpId, tier = tier, tileKey = tileKey }
end

-- Legacy name kept for backward compat at call sites; now routes to TryPlacePump.
function OilStateService:TryPlaceDrill(userId: number, payload): (boolean, string, string, any)
	return self:TryPlacePump(userId, payload)
end

local function positionVectorFromStateEntry(pos: any): Vector3?
	local px, py, pz = worldXYZFromPersistedPosition(pos)
	if px and py and pz then
		return Vector3.new(px, py, pz)
	end
	return nil
end

--- World position used for salvage range checks (`OilConfig.SalvageProximityMaxStuds`).
--- Prefer current plot + chunk/tile (same as hydrate / visuals) so range matches authored placement
--- when stored world coords are stale or persisted tables omit x/y/z keys.
function OilStateService:GetHammerTargetWorldPosition(userId: number, payload: any): Vector3?
	if typeof(payload) ~= "table" then
		return nil
	end
	local state = self._statesByUserId[userId]
	if not state then
		return nil
	end
	local kind = payload.targetKind
	local entry: { [string]: any }? = nil
	if kind == "pump" then
		local drillId = tonumber(payload.targetId)
		entry = drillId and state.drillsById[drillId] or nil
	elseif kind == "pipe" then
		local ck = tostring(payload.cellKey or "")
		entry = (ck ~= "" and state.pipesByCellKey[ck]) or nil
	elseif kind == "drum" then
		local drumId = tonumber(payload.targetId)
		entry = drumId and state.drumsById[drumId] or nil
	elseif kind == "drill" then
		local drillId = tonumber(payload.targetId)
		entry = drillId and state.activeDrills[drillId] or nil
	elseif kind == "prospector" then
		local prospectId = tonumber(payload.targetId)
		entry = prospectId and state.activeProspectors[prospectId] or nil
	end
	if not entry then
		return nil
	end
	local plot = self:_plotModelForGrid(userId, state)
	local chunkId = entry.chunkId
	local tileKey = entry.tileKey
	if typeof(chunkId) == "string" and chunkId ~= "" and typeof(tileKey) == "string" and tileKey ~= "" and plot then
		local ps = self._plotService
		if ps then
			local tx, ty, tz = activeDrillWorldFromChunkTile(ps, plot, chunkId, tileKey)
			if tx and ty and tz then
				return Vector3.new(tx, ty, tz)
			end
		end
	end
	-- Pipes use `sectionId` + global row/col (not `chunkId`/`tileKey` on the entry).
	if kind == "pipe" and plot then
		local ps = self._plotService
		local secId = entry.sectionId
		local pr = tonumber(entry.row)
		local pc = tonumber(entry.col)
		if ps and typeof(secId) == "string" and secId ~= "" and pr and pc then
			local tk = globalCellToLocalTileKey(pr, pc)
			local tx, ty, tz = activeDrillWorldFromChunkTile(ps, plot, secId, tk)
			if tx and ty and tz then
				return Vector3.new(tx, ty, tz)
			end
		end
	end
	local wx, wy, wz = activeDrillWorldFromStateEntry(plot, entry)
	if wx and wy and wz then
		return Vector3.new(wx, wy, wz)
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
		if pump.ftueFreeNoSellback == true then
			return false, "ERR_PROTECTED_FTUE", "Tutorial equipment cannot be sold back.", nil
		end
		local cost = tonumber(pump.placementCost) or 0
		refundedAmount = math.floor(cost * 0.10)
		state.drillsById[drillId] = nil
		state.activeDrillCount = math.max(0, state.activeDrillCount - 1)

	elseif kind == "pipe" then
		local ck = tostring(payload.cellKey or "")
		local pipe = state.pipesByCellKey[ck]
		if not pipe then return false, "ERR_BAD_TARGET", "Pipe not found.", nil end
		if pipe.isCorePipe == true then
			return false, "ERR_PROTECTED_PIPE", "Core pipe cannot be removed.", nil
		end
		if pipe.ftueFreeNoSellback == true then
			return false, "ERR_PROTECTED_FTUE", "Tutorial equipment cannot be sold back.", nil
		end
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
		if active.ftueFreeNoSellback == true then
			return false, "ERR_PROTECTED_FTUE", "Tutorial equipment cannot be sold back.", nil
		end
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
	local sectionId = nil :: string?
	local snappedX = nil :: number?
	local snappedY = nil :: number?
	local snappedZ = nil :: number?

	-- Preferred path: authoritative tile resolution from chunk + world hit.
	local chunkId = payload.chunkId
	local x = tonumber(payload.x)
	local z = tonumber(payload.z)
	if typeof(chunkId) == "string" and x and z then
		local ok, code, message, chunk, _tileKey, sx, sy, sz, cellR, cellC = self:_validateTilePlacement(userId, {
			chunkId = chunkId,
			x = x,
			y = tonumber(payload.y) or 0,
			z = z,
		})
		if not ok then
			return false, code, message, nil
		end
		row, col = cellR, cellC
		sectionId = chunk.chunkId
		snappedX, snappedY, snappedZ = sx, sy, sz
	end

	-- Legacy fallback for older clients sending only row/col or x/z.
	if not row or not col then
		if x and z then
			row, col = worldToCell(plot, x, z)
		end
	end
	if not row or not col then
		return false, "ERR_BAD_PAYLOAD", "Bad pipe payload.", nil
	end

	if not cellInBounds(row, col) then
		DevLog.log(string.format(
			"[PipePlace] OOB user=%d chunkId=%s row=%s col=%s x=%s z=%s",
			userId,
			tostring(payload.chunkId),
			tostring(row),
			tostring(col),
			tostring(payload.x),
			tostring(payload.z)
		))
		return false, "ERR_OUT_OF_PLOT", "Pipe cell out of bounds.", nil
	end

	-- Section / chunk ownership
	sectionId = sectionId or cellToSectionId(row, col)
	local chunk = state.chunksById[sectionId]
	if not chunk or not chunk.unlocked then
		return false, "ERR_LOCKED_CHUNK", "Cell is on a locked section.", nil
	end

	-- One pipe per cell
	local key = cellKey(row, col)
	local ftuePipeCell = readFtueCellAttribute(userId, Constants.FtueRestrictPipeCellKeyAttribute)
	if ftuePipeCell and ftuePipeCell ~= key then
		return false, "ERR_FTUE_WRONG_TILE", FtueConfig.WrongTilePipe, nil
	end
	if state.pipesByCellKey[key] then
		return false, "ERR_CELL_OCCUPIED", "There is already a pipe here.", nil
	end

	-- Drill exclusivity: can't place pipe where a drill already is
	for _, drill in pairs(state.drillsById) do
		if drill.cellKey == key then
			return false, "ERR_DRILL_HERE", "Remove the drill first to place a pipe.", nil
		end
	end

	-- Placement does NOT charge cash. Cash was spent at the shop.

	local pipeId = state.nextPipeId
	state.nextPipeId += 1
	local wx, wz = cellToWorld(plot, row, col)
	if typeof(snappedX) == "number" and typeof(snappedZ) == "number" then
		wx, wz = snappedX, snappedZ
	end
	local wy = if typeof(snappedY) == "number" then snappedY else 6

	local plrPipe = Players:GetPlayerByUserId(userId)
	local ftueStepPipe = plrPipe and plrPipe:GetAttribute(Constants.FtueStepAttribute)
	local ftueFreeNoSellbackPipe = (
		FtueConfig.Enabled == true
		and ftuePipeCell ~= nil
		and ftuePipeCell == key
		and typeof(ftueStepPipe) == "string"
		and ftueStepPipe == FtueConfig.Step.WaitPipe
	)

	state.pipesByCellKey[key] = {
		pipeId = pipeId,
		cellKey = key,
		row = row,
		col = col,
		sectionId = sectionId,
		position = Vector3.new(wx, wy, wz),
		ftueFreeNoSellback = ftueFreeNoSellbackPipe,
	}

	self:_markDirty(userId)

	if FtueConfig.Enabled and _ftueService and typeof((_ftueService :: any).OnFtueTutorialPipePlaced) == "function" then
		(_ftueService :: any):OnFtueTutorialPipePlaced(userId, key)
	end

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
			elseif typeof(payload.chunkId) == "string" and tonumber(payload.x) and tonumber(payload.z) then
				local chunk = state.chunksById[payload.chunkId]
				local plot = state.plot or self._plotService:GetOwnedPlot(userId)
				if not plot then return false, "ERR_NO_PLOT", "No plot owned." end
				if chunk then
					local tileKey = select(1, resolveTileAt(plot, chunk, tonumber(payload.x), tonumber(payload.z)))
					if typeof(tileKey) == "string" then
						local localR, localC = tileKeyToLocalRowCol(tileKey)
						if localR and localC and typeof(chunk.row) == "number" and typeof(chunk.col) == "number" then
							local s = staticGridConstants()
							row = (chunk.row - 1) * s.subTilesPerSide + localR
							col = (chunk.col - 1) * s.subTilesPerSide + localC
							key = cellKey(row, col)
						end
					end
				end
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
	if state.pipesByCellKey[key].isCorePipe == true then
		return false, "ERR_PROTECTED_PIPE", "Core pipe cannot be removed."
	end
	if state.pipesByCellKey[key].ftueFreeNoSellback == true then
		return false, "ERR_PROTECTED_FTUE", "Tutorial equipment cannot be removed this way."
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
	local drained = 0
	for _, tier in ipairs(TIER_ORDER) do
		local cap = tankCapacity(state, tier)
		local tierSpace = cap - (state.oilByTier[tier] or 0)
		if tierSpace > 0 then
			local amt = floorPositive(drill.localBuffer[tier] or 0)
			local take = math.min(tierSpace, amt)
			if take > 0 then
				drill.localBuffer[tier] -= take
				state.oilByTier[tier] += take
				state.totalOil += take
				drained += take
			end
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

	for _, tier in ipairs(TIER_ORDER) do
		state.pendingFloats[tier] += additionsByTier[tier] or 0
	end

	local integersToAdd = {}
	for _, tier in ipairs(TIER_ORDER) do
		integersToAdd[tier] = floorPositive(state.pendingFloats[tier])
		state.pendingFloats[tier] = state.pendingFloats[tier] - integersToAdd[tier]
	end

	-- Per-tank capacity gating: each tier has its own cap (state.tankTiers[tier]).
	-- When a tank is full, excess for that tier is discarded here (the producer should
	-- also check TankIsFull and avoid generating that tier in the first place).
	local added = 0
	for _, tier in ipairs(TIER_ORDER) do
		local cap = tankCapacity(state, tier)
		local space = cap - (state.oilByTier[tier] or 0)
		if space > 0 and integersToAdd[tier] > 0 then
			local take = math.min(space, integersToAdd[tier])
			state.oilByTier[tier] += take
			state.totalOil += take
			added += take
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

-- Tank accessors used by OilProductionService (per-tier gating) and OilTankService (upgrades).
function OilStateService:GetTankTier(userId: number, oilType: string): number
	local state = self._statesByUserId[userId]
	if not state or not state.tankTiers then return 1 end
	return OilTankConfig.ClampTier(state.tankTiers[oilType] or 1)
end

function OilStateService:GetTankCapacity(userId: number, oilType: string): number
	local state = self._statesByUserId[userId]
	if not state then return OilTankConfig.GetCapacity(1) end
	return tankCapacity(state, oilType)
end

function OilStateService:TankIsFull(userId: number, oilType: string): boolean
	local state = self._statesByUserId[userId]
	if not state then return false end
	return (state.oilByTier[oilType] or 0) >= tankCapacity(state, oilType)
end

-- Upgrade one tank one tier. Charges `OilTankConfig.GetUpgradeCost(currentTier)` on success.
-- Returns (ok, code, message, payload).
function OilStateService:TryUpgradeTank(userId: number, oilType: string): (boolean, string, string, any)
	DevLog.log(string.format("[TryUpgradeTank] user=%d oilType=%s", userId, tostring(oilType)))
	local state = self._statesByUserId[userId]
	if not state then
		DevLog.log("[TryUpgradeTank] FAIL: no state")
		return false, "ERR_NO_STATE", "State unavailable.", nil
	end
	if OilTankConfig.OilColors[oilType] == nil then
		DevLog.log(string.format("[TryUpgradeTank] FAIL: bad oil type %s", tostring(oilType)))
		return false, "ERR_BAD_OIL_TYPE", "Unknown oil type.", nil
	end
	local currentTier = OilTankConfig.ClampTier(state.tankTiers[oilType] or 1)
	if currentTier >= OilTankConfig.MaxTier then
		DevLog.log(string.format("[TryUpgradeTank] FAIL: max tier %s at %d", oilType, currentTier))
		return false, "ERR_MAX_TIER", "Tank already at max tier.", nil
	end
	local cost = OilTankConfig.GetUpgradeCost(currentTier)
	if not cost then
		DevLog.log(string.format("[TryUpgradeTank] FAIL: no cost for tier %d", currentTier))
		return false, "ERR_MAX_TIER", "No further upgrade available.", nil
	end
	if not self:TrySpendCash(userId, cost) then
		DevLog.log(string.format("[TryUpgradeTank] FAIL: not enough cash. need=%d have=%d", cost, state.cash or -1))
		return false, "ERR_NOT_ENOUGH_CASH", string.format("Need $%d to upgrade.", cost), nil
	end
	DevLog.log(string.format("[TryUpgradeTank] OK user=%d oilType=%s newTier=%d cost=%d",
		userId, oilType, currentTier + 1, cost))
	state.tankTiers[oilType] = currentTier + 1
	state.storageCapacity = totalTankCapacity(state)
	self:_markDirty(userId)
	self:PushState(userId)
	return true, "OK", string.format("%s tank upgraded to tier %d.", oilType, state.tankTiers[oilType]), {
		oilType = oilType,
		tier = state.tankTiers[oilType],
		capacity = tankCapacity(state, oilType),
	}
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
		-- Always bind the current Workspace plot Model (same plotId can be a new instance after rejoin).
		existing.plot = plot
		-- Keep starter infrastructure intact for migrated/legacy profiles.
		self:_ensureDefaultDrumForPlayer(existing, plot)
		self:_ensureDefaultPipesForPlayer(existing, plot)
		self:_invokeStateTimersReady(userId)
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
		cash = initialStartingCash(),
		ftueEscortShipmentRemaining = initialFtueEscortShipmentRemaining(),
		ftueDispatchCashGranted = false,
		ftueTutorialCompleteCashGranted = false,
		-- Per-tank upgrade levels. storageCapacity is derived = sum of tank capacities.
		tankTiers = defaultTankTiers(),
		storageCapacity = 0, -- set below from tankTiers
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
		activeDrills = {},       -- in-progress drills; also persisted (wall-clock start/end)
		activeProspectors = {},  -- in-progress prospects; also persisted
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
		ftueStep = if FtueConfig.Enabled then FtueConfig.Step.Intro else nil,
		ftueCompleted = not FtueConfig.Enabled,
		ftueDoneScreenAcknowledged = false,
	}

	local persisted = self:_loadPersistedProfile(userId)
	if persisted then
		self:_applyPersistedIntoState(state, persisted, plot)
	end

	-- Derive storageCapacity from per-tank capacities (after persistence may have set tankTiers).
	state.storageCapacity = totalTankCapacity(state)

	self:_ensureDefaultDrumForPlayer(state, plot)
	self:_ensureDefaultPipesForPlayer(state, plot)

	self._statesByUserId[userId] = state
	self:_invokeStateTimersReady(userId)

	-- Force a deferred visual refresh so biome tiles + fog get applied after state is fully set
	task.defer(function()
		self:PushState(userId)
	end)
end

function OilStateService:_ensureDefaultPipesForPlayer(state, plot: Model)
	local drumRow: number? = nil
	local drumCol: number? = nil
	local labPivot: CFrame? = nil
	local coreDrum = nil
	for _, drum in pairs(state.drumsById) do
		if drum.isCoreDrum == true then
			coreDrum = drum
			break
		end
	end
	if not coreDrum then
		local firstId = nil :: number?
		for drumId, _ in pairs(state.drumsById) do
			if not firstId or drumId < firstId then
				firstId = drumId
			end
		end
		if firstId then
			coreDrum = state.drumsById[firstId]
		end
	end
	if coreDrum then
		drumRow = tonumber(coreDrum.row)
		drumCol = tonumber(coreDrum.col)
	end
	local labModel = plot:FindFirstChild("Lab Machine")
	if labModel and labModel:IsA("Model") then
		labPivot = labModel:GetPivot()
	end
	if not drumRow or not drumCol then
		return
	end

	local leftRow, leftCol = nil :: number?, nil :: number?
	local rightRow, rightCol = nil :: number?, nil :: number?
	local frontRow, frontCol = nil :: number?, nil :: number?
	if labPivot then
		leftRow, leftCol = pickNeighborCellByDirection(plot, drumRow, drumCol, -labPivot.RightVector)
		rightRow, rightCol = pickNeighborCellByDirection(plot, drumRow, drumCol, labPivot.RightVector)
		frontRow, frontCol = pickNeighborCellByDirection(plot, drumRow, drumCol, labPivot.LookVector)
	end
	-- Fallback to Plot_01-authored layout if machine vectors cannot be resolved.
	if not leftRow or not leftCol then
		leftRow, leftCol = drumRow, drumCol - 1
	end
	if not rightRow or not rightCol then
		rightRow, rightCol = drumRow, drumCol + 1
	end
	if not frontRow or not frontCol then
		frontRow, frontCol = drumRow - 1, drumCol
	end

	state._blockedCells = {}
	state._blockedCells[cellKey(drumRow, drumCol)] = true

	local pipeCells = {
		{ leftRow, leftCol },
		{ rightRow, rightCol },
		{ frontRow, frontCol },
	}
	local targetCoreByCellKey = {}
	for _, coords in ipairs(pipeCells) do
		local row, col = coords[1], coords[2]
		if cellInBounds(row, col) then
			targetCoreByCellKey[cellKey(row, col)] = true
		end
	end
	for key, pipe in pairs(state.pipesByCellKey) do
		if pipe.isCorePipe == true and not targetCoreByCellKey[key] then
			state.pipesByCellKey[key] = nil
		end
	end
	for _, legacyKey in ipairs({
		cellKey(drumRow, drumCol - 2),
		cellKey(drumRow, drumCol + 2),
	}) do
		if not targetCoreByCellKey[legacyKey] then
			local p = state.pipesByCellKey[legacyKey]
			if p and p.isCorePipe ~= true then
				state.pipesByCellKey[legacyKey] = nil
			end
		end
	end
	local added = 0

	for _, coords in ipairs(pipeCells) do
		local row, col = coords[1], coords[2]
		if cellInBounds(row, col) then
			local key = cellKey(row, col)
			local existing = state.pipesByCellKey[key]
			if not existing then
				local sectionId = cellToSectionId(row, col)
				local chunk = state.chunksById[sectionId]
				if chunk and chunk.unlocked then
					local tilePart = findTilePartForCell(plot, row, col)
					local x, z = cellToWorld(plot, row, col)
					local y = 6
					if tilePart then
						x = tilePart.Position.X
						z = tilePart.Position.Z
						y = tilePart.Position.Y + tilePart.Size.Y / 2
					end
					state.pipesByCellKey[key] = {
						pipeId = state.nextPipeId,
						cellKey = key,
						row = row,
						col = col,
						sectionId = sectionId,
						position = Vector3.new(x, y, z),
						isCorePipe = true,
						placementCost = 0,
					}
					state.nextPipeId += 1
					added += 1
				end
			else
				existing.isCorePipe = true
				existing.placementCost = 0
			end
		end
	end
	local total = 0
	for _, _ in pairs(state.pipesByCellKey) do
		total += 1
	end
	DevLog.log(string.format(
		"[StarterPipes] user=%d drum=R%dC%d added=%d total=%d",
		state.ownerUserId,
		drumRow,
		drumCol,
		added,
		total
	))
end

function OilStateService:_ensureDefaultDrumForPlayer(state, plot: Model)
	local coreDrumId = nil :: number?
	for drumId, drum in pairs(state.drumsById) do
		if drum.isCoreDrum == true then
			coreDrumId = drumId
			break
		end
	end
	if not coreDrumId then
		for drumId, _ in pairs(state.drumsById) do
			if not coreDrumId or drumId < coreDrumId then
				coreDrumId = drumId
			end
		end
	end

	local row, col, tilePart = nil :: number?, nil :: number?, nil :: BasePart?
	local labModel = plot:FindFirstChild("Lab Machine")
	if labModel and labModel:IsA("Model") then
		row, col, tilePart = findNearestPlotTileCell(plot, labModel:GetPivot().Position)
	end
	if not row or not col then
		local startSectionRow = OilConfig.Chunks.StartingRow
		local startSectionCol = OilConfig.Chunks.StartingCol
		local s = staticGridConstants()
		row = (startSectionRow - 1) * s.subTilesPerSide + s.subTilesPerSide
		col = (startSectionCol - 1) * s.subTilesPerSide + math.ceil(s.subTilesPerSide / 2)
		tilePart = findTilePartForCell(plot, row, col)
	end
	if not row or not col then
		return
	end
	local x, z = cellToWorld(plot, row, col)
	local y = 6
	if tilePart then
		x = tilePart.Position.X
		z = tilePart.Position.Z
		y = tilePart.Position.Y + tilePart.Size.Y / 2
	end
	local drumPos = Vector3.new(x, y, z)
	local key = cellKey(row, col)
	if coreDrumId and state.drumsById[coreDrumId] then
		local drum = state.drumsById[coreDrumId]
		drum.position = drumPos
		drum.cellKey = key
		drum.row = row
		drum.col = col
		drum.isCoreDrum = true
		drum.placementCost = 0
	else
		local drumId = state.nextDrumId
		state.nextDrumId += 1
		state.drumsById[drumId] = {
			drumId = drumId,
			position = drumPos,
			cellKey = key,
			row = row,
			col = col,
			isCoreDrum = true,
			placementCost = 0,
		}
	end
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
	if typeof((persisted :: any).ftueEscortShipmentRemaining) == "number" then
		state.ftueEscortShipmentRemaining = math.clamp(math.floor((persisted :: any).ftueEscortShipmentRemaining), 0, 1)
	else
		state.ftueEscortShipmentRemaining = 0
	end
	if (persisted :: any).ftueDispatchCashGranted == true then
		state.ftueDispatchCashGranted = true
	else
		state.ftueDispatchCashGranted = false
	end
	if (persisted :: any).ftueTutorialCompleteCashGranted == true then
		state.ftueTutorialCompleteCashGranted = true
	else
		state.ftueTutorialCompleteCashGranted = false
	end

	-- FTUE step (v7+). Saves without these keys are pre-FTUE-progress profiles: skip tutorial.
	local pFtue = persisted :: any
	local hasFtueStepKey = typeof(pFtue.ftueStep) == "string"
	local hasFtueCompletedKey = pFtue.ftueCompleted ~= nil
	if not hasFtueStepKey and not hasFtueCompletedKey then
		state.ftueCompleted = true
		state.ftueStep = nil
	elseif hasFtueStepKey then
		local s = (pFtue.ftueStep :: string):gsub("^%s+", ""):gsub("%s+$", "")
		if s == "" then
			state.ftueStep = FtueConfig.Step.Intro
			state.ftueCompleted = false
		else
			state.ftueStep = s
			if s == FtueConfig.Step.Done then
				--- Reaching the Done **step** is not "tutorial complete" until Complete! (`SetFtueProgress(nil)`).
				if pFtue.ftueDoneScreenAcknowledged == true then
					state.ftueStep = nil
					state.ftueCompleted = true
				else
					state.ftueCompleted = false
					--- Old bug: `ftueCompleted` was true while still on the Done modal — force modal to show.
					if pFtue.ftueCompleted == true then
						state.ftueCompleted = false
					end
				end
			else
				state.ftueCompleted = false
			end
		end
	elseif pFtue.ftueCompleted == true then
		state.ftueCompleted = true
		state.ftueStep = nil
	else
		state.ftueCompleted = false
		state.ftueStep = FtueConfig.Step.Intro
	end

	-- Done-screen dismissed (persisted). Legacy saves without key: infer from **fully** completed profile only.
	if pFtue.ftueDoneScreenAcknowledged == true then
		(state :: any).ftueDoneScreenAcknowledged = true
	elseif pFtue.ftueDoneScreenAcknowledged == false then
		(state :: any).ftueDoneScreenAcknowledged = false
	else
		(state :: any).ftueDoneScreenAcknowledged = (state.ftueCompleted == true and typeof((state :: any).ftueStep) ~= "string")
	end

	-- Tutorial escort ship only applies on the `Dispatch` step; clear stale flag after that leg or when FTUE is done.
	if FtueConfig.Enabled then
		local fs = (state :: any).ftueStep
		if (state :: any).ftueCompleted == true then
			state.ftueEscortShipmentRemaining = 0
		elseif typeof(fs) == "string" then
			if
				fs == FtueConfig.Step.WaitShipment
				or fs == FtueConfig.Step.Sell
				or fs == FtueConfig.Step.WaitSell
				or fs == FtueConfig.Step.Done
			then
				state.ftueEscortShipmentRemaining = 0
			end
		end
	end

	-- Legacy: earlier profiles stored a single `storageCapacity` global.
	-- New model derives it from `tankTiers`. We ignore the legacy field unless tankTiers is missing,
	-- in which case we let the default (tier 1 all around) stand — legacy capacity is unused.
	if typeof(persisted.tankTiers) == "table" then
		for _, oilType in ipairs(TIER_ORDER) do
			local v = persisted.tankTiers[oilType]
			if typeof(v) == "number" then
				state.tankTiers[oilType] = OilTankConfig.ClampTier(v)
			end
		end
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

	-- In-progress drills (persisted so timers survive logout / server restart).
	-- Use `pairs`: DataStore JSON can deserialize arrays as sparse/dict tables where `ipairs` would skip rows.
	if typeof(persisted.activeDrills) == "table" then
		for _, rec in pairs(persisted.activeDrills) do
			if typeof(rec) == "table" then
				local r = rec :: { [string]: any }
				local drillId = tonumber(r.drillId)
				local savedChunkId: string? = nil
				if typeof(r.chunkId) == "string" then
					local s = (r.chunkId :: string):gsub("^%s+", ""):gsub("%s+$", "")
					if s ~= "" then
						savedChunkId = s
					end
				end
				local tileKeySaved: string? = nil
				if typeof(r.tileKey) == "string" then
					local t = (r.tileKey :: string):gsub("^%s+", ""):gsub("%s+$", "")
					if t ~= "" then
						tileKeySaved = t
					end
				end
				if drillId then
					local cellR = tonumber(r.cellRow)
					local cellC = tonumber(r.cellCol)
					if not cellR or not cellC or not cellInBounds(cellR, cellC) then
						local pv = positionVectorFromStateEntry(r.position)
						if pv then
							cellR, cellC = worldToCell(plot, pv.X, pv.Z)
						end
					end
					if cellR and cellC and cellInBounds(cellR, cellC) then
						local sectionFromCell = cellToSectionId(cellR, cellC)
						local tileKeyFromCell = globalCellToLocalTileKey(cellR, cellC)
						local chunk = state.chunksById[sectionFromCell]
						if not chunk and savedChunkId then
							chunk = state.chunksById[savedChunkId]
						end
						local tiles = chunk and chunk.tiles
						local tile: any = nil
						local tileKeyResolved: string? = nil
						if typeof(tiles) == "table" then
							if tileKeySaved then
								tile = (tiles :: { [string]: any })[tileKeySaved]
								if tile then
									tileKeyResolved = tileKeySaved
								end
							end
							if not tile then
								tile = (tiles :: { [string]: any })[tileKeyFromCell]
								if tile then
									tileKeyResolved = tileKeyFromCell
								end
							end
						end
						if not tile and savedChunkId and savedChunkId ~= sectionFromCell then
							local ch2 = state.chunksById[savedChunkId]
							local t2 = ch2 and ch2.tiles
							if typeof(t2) == "table" and tileKeySaved then
								tile = (t2 :: { [string]: any })[tileKeySaved]
								if tile then
									chunk = ch2
									tileKeyResolved = tileKeySaved
								end
							end
						end
						-- `chunkTiles` is applied above; a stale profile can have `tile.drilled == true` while
						-- `activeDrills` still lists that op (or wall-clock says it is still running). Do not skip
						-- restore solely on `drilled`, or the drill model never reclones and timers look "wrong".
						if chunk and chunk.unlocked == true and tile then
							local ck = if typeof(r.cellKey) == "string" and r.cellKey ~= "" then r.cellKey :: string else cellKey(cellR, cellC)
							-- ALWAYS re-derive position from the CURRENT plot's tile Instance.
							-- Stored absolute coords would be wrong on cross-plot rejoin (same fix
							-- we applied to pumps). Makes restored active drills appear where they
							-- should, not 250+ studs away at an invisible position.
							local pos: Vector3
							local groundNow = plot:FindFirstChild("PlotGround")
							local sectionNow = groundNow and groundNow:FindFirstChild(chunk.chunkId)
							local tileKeyForLookup = tileKeyResolved or tileKeyFromCell
							local tileInstNow = sectionNow and sectionNow:FindFirstChild(tileKeyForLookup)
							if tileInstNow and tileInstNow:IsA("BasePart") then
								local topY = tileInstNow.Position.Y + tileInstNow.Size.Y / 2
								pos = Vector3.new(tileInstNow.Position.X, topY, tileInstNow.Position.Z)
							else
								local wx, wz = cellToWorld(plot, cellR, cellC)
								pos = Vector3.new(wx, 6, wz)
							end
							local tier = if typeof(r.tier) == "string" and r.tier ~= "" then r.tier :: string else "T1"
							local tierCfg = OilConfig.DrillTiers[tier]
							if not tierCfg then
								tier = "T1"
								tierCfg = OilConfig.DrillTiers["T1"] :: any
							end
							local tmpl = if typeof(r.template) == "string" and r.template ~= "" then r.template :: string else tierCfg.templateName
							local nowWall = workspace:GetServerTimeNow()
							local st = tonumber(r.startTime) or nowWall
							local et = tonumber(r.endTime) or (st + 10)
							if et <= st then
								local baseSec = (tile and tonumber(tile.drillSeconds)) or tierCfg.fallbackSeconds or 10
								local eff = math.max(0.5, baseSec / ((tierCfg :: any).timeDivisor or 1))
								et = st + eff
							end
							if et <= nowWall then
								-- Finished while away: match tile to completed drill; do not resurrect `activeDrills`.
								if tile.drilled ~= true then
									tile.drilled = true
									self:_markDirty(state.ownerUserId)
								end
							else
								if tile.drilled == true then
									tile.drilled = false
									self:_markDirty(state.ownerUserId)
								end
								local chunkIdResolved = chunk.chunkId
								local tk = tileKeyResolved or tileKeyFromCell
								state.activeDrills[drillId] = {
									drillId = drillId,
									chunkId = chunkIdResolved,
									tier = tier,
									tileKey = tk,
									cellKey = ck,
									cellRow = cellR,
									cellCol = cellC,
									position = pos,
									startTime = st,
									endTime = et,
									oilType = r.oilType,
									template = tmpl,
									ftueFreeNoSellback = r.ftueFreeNoSellback == true,
								}
							end
						end
					end
				end
			end
		end
	end

	-- In-progress prospectors (same wall-clock pattern as drills).
	if typeof(persisted.activeProspectors) == "table" then
		for _, rec in pairs(persisted.activeProspectors) do
			if typeof(rec) == "table" then
				local r = rec :: { [string]: any }
				local prospectId = tonumber(r.prospectId)
				local chunkId = r.chunkId
				if prospectId and typeof(chunkId) == "string" then
					local chunk = state.chunksById[chunkId]
					if chunk and chunk.prospected ~= true then
						local pos = positionVectorFromStateEntry(r.position)
						if not pos then
							pos = Vector3.new(0, 6, 0)
						end
						local nowWall = workspace:GetServerTimeNow()
						local st = tonumber(r.startTime) or nowWall
						local et = tonumber(r.endTime) or (st + 5)
						if et <= st then
							et = st + ((OilConfig.Prospecting and OilConfig.Prospecting.durationSeconds) or 5)
						end
						state.activeProspectors[prospectId] = {
							prospectId = prospectId,
							chunkId = chunkId,
							tileKey = if typeof(r.tileKey) == "string" then r.tileKey :: string else "T11",
							position = pos,
							startTime = st,
							endTime = et,
							template = if typeof(r.template) == "string" then r.template :: string else "Prospector",
						}
					end
				end
			end
		end
	end
	if typeof(persisted.nextProspectId) == "number" then
		state.nextProspectId = math.max(state.nextProspectId, math.floor(persisted.nextProspectId))
	end
	for pid, _ in pairs(state.activeProspectors) do
		if typeof(pid) == "number" then
			state.nextProspectId = math.max(state.nextProspectId, pid + 1)
		end
	end

	-- Restore placed pumps (requires `tileKey` + cell coords or position — v5+ saves).
	if typeof(persisted.drills) == "table" then
		local maxDrillId = 0
		local restored, dropped = 0, 0
		DevLog.log(string.format("[RestoreDrills] incoming=%d", #persisted.drills))
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
						local reason
						if not chunk then reason = "no chunk in state"
						elseif not chunk.tiles then reason = "chunk.tiles=nil (not unlocked?)"
						elseif not tileKey then reason = "no tileKey in record"
						elseif not chunk.tiles[tileKey] then reason = string.format("chunk.tiles[%s]=nil", tileKey)
						end
						if reason then
							DevLog.log(string.format("[RestoreDrills] DROP drillId=%d chunkId=%s: %s",
								drillId, tostring(chunkId), reason))
							dropped += 1
						end
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
									-- ALWAYS re-derive world position from the CURRENT plot's tile.
									-- Stored absolute world coords would be wrong if the player was assigned
									-- a different plot than last session (each plot has its own worldspace).
									local pos: Vector3
									local topY = self._plotService:GetChunkTileSurfaceWorldY(plot, chunkId, tileKey)
									local sectionModel = self._plotService:GetChunkModel(plot, chunkId)
									if topY and sectionModel then
										local tilePart = self._plotService:FindChunkTileBasePart(sectionModel, tileKey)
										if tilePart then
											pos = Vector3.new(tilePart.Position.X, topY, tilePart.Position.Z)
										else
											local wx, wz = cellToWorld(plot, cellR, cellC)
											pos = Vector3.new(wx, topY, wz)
										end
									else
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
										ftueFreeNoSellback = rec.ftueFreeNoSellback == true,
									}
									state.activeDrillCount += 1
									restored += 1
								end
							end
						end
					end
				end
			end
		end
		DevLog.log(string.format("[RestoreDrills] restored=%d dropped=%d", restored, dropped))
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
						isCorePipe = record.isCorePipe == true,
						ftueFreeNoSellback = record.ftueFreeNoSellback == true,
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
					isCoreDrum = record.isCoreDrum == true,
				}
			end
		end
		state.nextDrumId = math.max(state.nextDrumId, maxDrumId + 1)
	end

	if typeof(persisted.nextDrillId) == "number" then
		state.nextDrillId = math.max(state.nextDrillId, math.floor(persisted.nextDrillId))
	end
	for aid, _ in pairs(state.activeDrills) do
		if typeof(aid) == "number" then
			state.nextDrillId = math.max(state.nextDrillId, aid + 1)
		end
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

	if (state :: any).ftueCompleted == true then
		if self:_clearFtuePlacementNoSellback(state) then
			self:_markDirty(state.ownerUserId)
		end
	end
end

function OilStateService:_markDirty(userId: number)
	self._dirtyByUserId[userId] = true
end

function OilStateService:_flushAndDropUser(userId: number)
	if self._devSkipSaveOnNextDrop[userId] then
		self._devSkipSaveOnNextDrop[userId] = nil
		self._statesByUserId[userId] = nil
		self._dirtyByUserId[userId] = nil
		return
	end
	-- Always persist latest state when removing session data (PlayerRemoving / plot release),
	-- even if `_markDirty` never ran after the last successful autosave.
	self:_saveUser(userId, true, true)
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

--- @param persistRegardlessOfDirty When true (player drop / plot release), write current state even if not marked dirty.
function OilStateService:_saveUser(userId: number, force: boolean?, persistRegardlessOfDirty: boolean?)
	if self._devSkipSaveOnNextDrop[userId] then
		return
	end
	if not persistRegardlessOfDirty and not self._dirtyByUserId[userId] then
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

	local maxAttempts = if persistRegardlessOfDirty then 4 else 1
	local lastErr: any = nil
	for attempt = 1, maxAttempts do
		if attempt > 1 and self._dataStore then
			DataStoreWriteGate.waitForWriteBudget(2.8)
			task.wait(0.45)
		end

		local ok, err = pcall(function()
			self._dataStore:SetAsync(key, payload)
		end)
		lastErr = err
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
	end
	warn(string.format("[OilStateService] Save failed for user %d after %d attempt(s): %s", userId, maxAttempts, tostring(lastErr)))
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
	persisted.ftueEscortShipmentRemaining = math.clamp(math.floor(state.ftueEscortShipmentRemaining or 0), 0, 1)
	persisted.ftueDispatchCashGranted = state.ftueDispatchCashGranted == true
	persisted.ftueTutorialCompleteCashGranted = (state :: any).ftueTutorialCompleteCashGranted == true
	if typeof((state :: any).ftueStep) == "string" then
		(persisted :: any).ftueStep = (state :: any).ftueStep
	elseif (state :: any).ftueCompleted == true then
		(persisted :: any).ftueStep = nil
	else
		(persisted :: any).ftueStep = if FtueConfig.Enabled then FtueConfig.Step.Intro else FtueConfig.Step.Done
	end
	(persisted :: any).ftueCompleted = (state :: any).ftueCompleted == true
	(persisted :: any).ftueDoneScreenAcknowledged = (state :: any).ftueDoneScreenAcknowledged == true
	persisted.storageCapacity = math.max(1, floorPositive(state.storageCapacity))
	persisted.oilByTier = copyTierMap(state.oilByTier)
	persisted.tankTiers = {
		HeavyCrude = OilTankConfig.ClampTier(state.tankTiers and state.tankTiers.HeavyCrude or 1),
		LightSweet = OilTankConfig.ClampTier(state.tankTiers and state.tankTiers.LightSweet or 1),
		PremiumRefined = OilTankConfig.ClampTier(state.tankTiers and state.tankTiers.PremiumRefined or 1),
	}
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
			flowBase = drill.flowBase,
			placementCost = drill.placementCost,
			ftueFreeNoSellback = drill.ftueFreeNoSellback == true,
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
			isCorePipe = pipe.isCorePipe == true,
			ftueFreeNoSellback = pipe.ftueFreeNoSellback == true,
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
			isCoreDrum = drum.isCoreDrum == true,
		})
	end

	persisted.nextDrillId = state.nextDrillId
	persisted.nextProspectId = state.nextProspectId or 1
	persisted.nextPipeId = state.nextPipeId
	persisted.nextDrumId = state.nextDrumId
	persisted.version = 7

	local activeDrillIds: { number } = {}
	local seenActiveDrill: { [number]: boolean } = {}
	for id, ad0 in pairs(state.activeDrills or {}) do
		local drillId = typeof(id) == "number" and id or tonumber(id)
		if typeof(drillId) == "number" and typeof(ad0) == "table" then
			local adt = ad0 :: { [string]: any }
			local did = tonumber(adt.drillId)
			if did then
				drillId = math.floor(did)
			end
			if not seenActiveDrill[drillId] then
				seenActiveDrill[drillId] = true
				table.insert(activeDrillIds, drillId)
			end
		end
	end
	table.sort(activeDrillIds)
	persisted.activeDrills = {}
	for _, drillId in ipairs(activeDrillIds) do
		local ad = (state.activeDrills :: { [any]: any })[drillId]
			or (state.activeDrills :: { [any]: any })[tostring(drillId)]
		if typeof(ad) == "table" then
			local pos = ad.position
			table.insert(persisted.activeDrills, {
				drillId = drillId,
				chunkId = ad.chunkId,
				tier = ad.tier,
				tileKey = ad.tileKey,
				cellKey = ad.cellKey,
				cellRow = ad.cellRow,
				cellCol = ad.cellCol,
				position = if typeof(pos) == "Vector3" then { x = pos.X, y = pos.Y, z = pos.Z } else ad.position,
				startTime = ad.startTime,
				endTime = ad.endTime,
				oilType = ad.oilType,
				template = ad.template,
				ftueFreeNoSellback = ad.ftueFreeNoSellback == true,
			})
		end
	end

	local prospectIds: { number } = {}
	local seenProspect: { [number]: boolean } = {}
	for id, ap0 in pairs(state.activeProspectors or {}) do
		local prospectId = typeof(id) == "number" and id or tonumber(id)
		if typeof(prospectId) == "number" and typeof(ap0) == "table" then
			local apt = ap0 :: { [string]: any }
			local pid = tonumber(apt.prospectId)
			if pid then
				prospectId = math.floor(pid)
			end
			if not seenProspect[prospectId] then
				seenProspect[prospectId] = true
				table.insert(prospectIds, prospectId)
			end
		end
	end
	table.sort(prospectIds)
	persisted.activeProspectors = {}
	for _, prospectId in ipairs(prospectIds) do
		local ap = (state.activeProspectors :: { [any]: any })[prospectId]
			or (state.activeProspectors :: { [any]: any })[tostring(prospectId)]
		if typeof(ap) == "table" then
			local pos = ap.position
			table.insert(persisted.activeProspectors, {
				prospectId = prospectId,
				chunkId = ap.chunkId,
				tileKey = ap.tileKey,
				position = if typeof(pos) == "Vector3" then { x = pos.X, y = pos.Y, z = pos.Z } else ap.position,
				startTime = ap.startTime,
				endTime = ap.endTime,
				template = ap.template,
			})
		end
	end
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

function OilStateService:SetBoatDockService(svc)
	self._boatDockService = svc
end

function OilStateService:SetSkinChangedHandler(fn: (number, string) -> ())
	self._skinChangedHandler = fn
end

function OilStateService:SetShipSkinId(userId: number, skinId: string): (boolean, string)
	local state = self._statesByUserId[userId]
	if not state then
		return false, "ERR_NO_STATE"
	end
	if typeof(skinId) ~= "string" or not ShipSkinCatalog.Skins[skinId] then
		return false, "ERR_BAD_SKIN"
	end
	local prev = state.shipSkinId
	state.shipSkinId = skinId
	self:_markDirty(userId)
	if prev ~= skinId and self._skinChangedHandler then
		task.spawn(self._skinChangedHandler, userId, skinId)
	end
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

--- Studio/dev: next `PlayerRemoving` / plot drop will not write oil profile (after `RemoveAsync`).
function OilStateService:MarkDevSkipSaveOnNextDrop(userId: number)
	self._devSkipSaveOnNextDrop[userId] = true
end

--- Remove `OilMiningProfiles_v3` entry and in-memory fallback cache. Does not touch live session state.
function OilStateService:DevRemovePersistedOilProfile(userId: number)
	local key = tostring(userId)
	if self._dataStore then
		pcall(function()
			self._dataStore:RemoveAsync(key)
		end)
	end
	self._memoryStore[key] = nil
end

--- FTUE drill tile: **one cell past** the starter **front** core pipe (same rule as `_ensureDefaultPipesForPlayer`:
--- `Lab Machine` `LookVector` from drum, else `drumRow - 1`). So: `Drum — front core pipe — drill`.
--- The following `WaitPipe` step should target `GetFtuePipeTutorialCellKeyForPlot` (the front core pipe cell).
function OilStateService:GetFtueDrillTargetCellKeyForPlot(plot: Model, state: any, userId: number): string?
	local drumRow: number?, drumCol: number? = nil, nil
	for _, drum in pairs(state.drumsById or {}) do
		if typeof(drum) == "table" and drum.isCoreDrum == true then
			local rr = tonumber(drum.row)
			local cc = tonumber(drum.col)
			if typeof(rr) == "number" and typeof(cc) == "number" then
				drumRow, drumCol = rr, cc
				break
			end
		end
	end
	if not drumRow or not drumCol then
		local labModel = plot:FindFirstChild("Lab Machine")
		if labModel and labModel:IsA("Model") then
			drumRow, drumCol = findNearestPlotTileCell(plot, labModel:GetPivot().Position)
		end
	end
	if not drumRow or not drumCol then
		local startSectionRow = OilConfig.Chunks.StartingRow
		local startSectionCol = OilConfig.Chunks.StartingCol
		local s = staticGridConstants()
		drumRow = (startSectionRow - 1) * s.subTilesPerSide + s.subTilesPerSide
		drumCol = (startSectionCol - 1) * s.subTilesPerSide + math.ceil(s.subTilesPerSide / 2)
	end
	if not drumRow or not drumCol then
		return nil
	end

	local frontRow: number?, frontCol: number? = nil, nil
	local labModel = plot:FindFirstChild("Lab Machine")
	if labModel and labModel:IsA("Model") then
		frontRow, frontCol = pickNeighborCellByDirection(plot, drumRow, drumCol, labModel:GetPivot().LookVector)
	end
	if not frontRow or not frontCol then
		frontRow, frontCol = drumRow - 1, drumCol
	end
	if not inBoundsCell(frontRow, frontCol) then
		return nil
	end

	local dRow = frontRow - drumRow
	local dCol = frontCol - drumCol
	if dRow == 0 and dCol == 0 then
		return nil
	end
	local drillRow = frontRow + dRow
	local drillCol = frontCol + dCol
	if not inBoundsCell(drillRow, drillCol) then
		return nil
	end

	local pipes = state.pipesByCellKey or {}
	local ck = cellKey(drillRow, drillCol)
	local pipeOnDrill = pipes[ck]
	if pipeOnDrill and pipeOnDrill.isCorePipe == true then
		state.pipesByCellKey[ck] = nil
		self:_markDirty(userId)
	end
	return ck
end

--- FTUE pipe placement (`WaitPipe`): the starter **front** core pipe cell — between drum and drill target.
function OilStateService:GetFtuePipeTutorialCellKeyForPlot(plot: Model, state: any): string?
	local drumRow: number?, drumCol: number? = nil, nil
	for _, drum in pairs(state.drumsById or {}) do
		if typeof(drum) == "table" and drum.isCoreDrum == true then
			local rr = tonumber(drum.row)
			local cc = tonumber(drum.col)
			if typeof(rr) == "number" and typeof(cc) == "number" then
				drumRow, drumCol = rr, cc
				break
			end
		end
	end
	if not drumRow or not drumCol then
		local labModel = plot:FindFirstChild("Lab Machine")
		if labModel and labModel:IsA("Model") then
			drumRow, drumCol = findNearestPlotTileCell(plot, labModel:GetPivot().Position)
		end
	end
	if not drumRow or not drumCol then
		local startSectionRow = OilConfig.Chunks.StartingRow
		local startSectionCol = OilConfig.Chunks.StartingCol
		local s = staticGridConstants()
		drumRow = (startSectionRow - 1) * s.subTilesPerSide + s.subTilesPerSide
		drumCol = (startSectionCol - 1) * s.subTilesPerSide + math.ceil(s.subTilesPerSide / 2)
	end
	if not drumRow or not drumCol then
		return nil
	end
	local frontRow: number?, frontCol: number? = nil, nil
	local labModel2 = plot:FindFirstChild("Lab Machine")
	if labModel2 and labModel2:IsA("Model") then
		frontRow, frontCol = pickNeighborCellByDirection(plot, drumRow, drumCol, labModel2:GetPivot().LookVector)
	end
	if not frontRow or not frontCol then
		frontRow, frontCol = drumRow - 1, drumCol
	end
	if not inBoundsCell(frontRow, frontCol) then
		return nil
	end
	return cellKey(frontRow, frontCol)
end

return OilStateService
