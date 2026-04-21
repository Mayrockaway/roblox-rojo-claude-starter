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
	"Crude",
	"Refined",
	"Premium",
}

local function migrateLegacyStandardTileOil(tiles: any)
	if typeof(tiles) ~= "table" then
		return
	end
	for _, tile in pairs(tiles) do
		if typeof(tile) == "table" then
			local t = tile :: any
			-- Obstacle system removed: drop legacy fields from loaded saves.
			t.hasObstacle = nil
			t.obstacleType = nil
		end
	end
end

local function migrateLegacyVeinTypeIds(tiles: any)
	if typeof(tiles) ~= "table" then
		return
	end
	local VeinCrateConfig = require(Shared:WaitForChild("Config"):WaitForChild("VeinCrateConfig"))
	local dryHole = VeinCrateConfig.FindByVeinResult({ isDead = true })
	for _, tile in pairs(tiles) do
		if typeof(tile) == "table" then
			local t = tile :: any
			if typeof(t.veinTypeId) == "string" and VeinCrateConfig.GetById(t.veinTypeId) then
				continue
			end
			local migrated = nil
			if typeof(t.veinResult) == "table" then
				migrated = VeinCrateConfig.FindByVeinResult(t.veinResult)
			elseif t.hasOil == false then
				migrated = dryHole
			end
			if migrated then
				t.veinTypeId = migrated.id
				if migrated.isUnlucky then
					t.hasOil = false
					t.oilType = nil
				elseif typeof(t.oilType) ~= "string" then
					t.oilType = migrated.primaryInternalOilType
				end
			end
		end
	end
end

local function normalizeChunkTilesToGroundType(tiles: any, groundType: any)
	if typeof(tiles) ~= "table" or typeof(groundType) ~= "table" then
		return
	end
	local materialName = if typeof(groundType.material) == "EnumItem" then groundType.material.Name else "Metal"
	local color = groundType.color
	local colorR = math.floor((color :: Color3).R * 255)
	local colorG = math.floor((color :: Color3).G * 255)
	local colorB = math.floor((color :: Color3).B * 255)
	for _, tile in pairs(tiles) do
		if typeof(tile) == "table" then
			local t = tile :: any
			t.tileName = groundType.name
			t.tileMaterial = materialName
			t.tileColorR = colorR
			t.tileColorG = colorG
			t.tileColorB = colorB
			t.drillSeconds = groundType.drillSeconds
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
		Crude = source.Crude or 0,
		Refined = source.Refined or 0,
		Premium = source.Premium or 0,
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
		ftueFreeCargoCapacityUpgradeUsed = false,
		--- One-shot flag: when `false`, the dock equipment shop FTUE leg
		--- (`WaitDocksEquipmentShop`) hands the player **one** free drill of
		--- `FtueConfig.FtueDocksFreeDrillItemId` (cost forced to 0 + rotation stock
		--- bypass in `EquipmentShopService:_handlePurchase`). Flips to `true` on the
		--- successful free purchase so the discount cannot be replayed.
		ftueFreeDocksDrillUsed = false,
		--- One-shot flag: when `false`, the very next FTUE drill reveal is locked to a
		--- vein of **exactly Rare** rarity (see `OilStateService:CompleteDrill`). Flips
		--- to `true` after the locked roll fires so subsequent reveals roll normally.
		ftueFirstRevealApplied = false,
		--- One-shot flag: when `false`, the **first barrel** produced from the FTUE
		--- tutorial vein is granted instantly the moment production visuals start
		--- (see `OilStateService:StartRevealVisuals`) so the player isn't stuck
		--- waiting for their first `barrelsPerSecond` tick before they can dispatch.
		--- Flips to `true` after the boost fires; subsequent barrels accumulate normally.
		ftueFirstBarrelGranted = false,
		storageCapacity = OilConfig.StartingStorageCapacity,
		oilByTier = {
			Crude = 0,
			Refined = 0,
			Premium = 0,
		},
		unlockedChunkIds = {},
		drills = {},
		equipmentOwned = {},
		--- Stackable, single-use "run upgrades" (e.g. Security Personnel —
		--- next-shipment event immunity). Stored as `{ itemId, count }` rows
		--- like `equipmentOwned` so adding new run-upgrade ids later is just
		--- a new id string; no schema bump. `nil` on legacy profiles is read
		--- as "no rows owned" (NOT a backfill flag — there's no inventory to
		--- migrate from).
		runUpgradesOwned = {},
		nextDrillId = 1,
		nextAttachmentId = 1,
		activeDrills = {},
		shipSpeedLevel = 1,
		shipCapacityLevel = 1,
		shipSkinId = "DefaultTanker",
		--- Seeded so a freshly persisted profile is never written without the
		--- starter tanker entry — keeps `_applyPersistedIntoState` and
		--- `MonetizationService` from disagreeing on first save.
		ownedShipSkinIds = { DefaultTanker = true },
		--- Ship skins the player is allowed to equip via `SetShipSkinId`. Every
		--- new profile starts with the starter `DefaultTanker`; everything else
		--- is granted by `MonetizationService` on a verified Robux receipt.
		--- Stored as `[skinId] = true` so JSON round-trip is order-stable.
		ownedShipSkinIds = { DefaultTanker = true },
		ftueStep = if FtueConfig.Enabled then FtueConfig.Step.Intro else nil,
		ftueCompleted = not FtueConfig.Enabled,
		ftueDoneScreenAcknowledged = false,
		--- One-shot suppression flag for the **post-login Robux Shop auto-open**
		--- (`init.client.luau` opens `RobuxShop` once per session for any player
		--- whose FTUE is complete and who hasn't bought a Robux item yet — the
		--- Starter Pack upsell). Flips to `true` the first time
		--- `MonetizationService` records a successful purchase
		--- (`_processReceipt` for DevProducts, `PromptGamePassPurchaseFinished`
		--- for GamePasses). Once true, the auto-open never fires again for this
		--- profile, so a paying customer is not nagged on every login.
		robuxShopAutoOpenDismissed = false,
		--- Persisted **sub-step** within `WaitDocksUpgradeShip` so a player who quits
		--- mid-leg (after talking to the dockman / mid-cargo-buy / about to close
		--- the modal) resumes on the **same** dock ship beam + UI pointer they last
		--- saw. Values: `"Dockman"` | `"CargoBuy"` | `"CloseModal"`. `nil` outside
		--- that step. Mirrors `Constants.FtueDocksUpgradeSubStepAttribute` 1-to-1.
		ftueDocksUpgradeSubStep = nil :: string?,
		--- Persisted **rejoin / death-respawn anchor** while the player is mid-FTUE.
		--- Captured (a) ~1s after every `_setStep` transition (post-step-driven
		--- teleports settle), and (b) on `PlayerRemoving` right before the profile
		--- flushes — so a disconnect-mid-leg or in-session death drops the player
		--- back where they were instead of the `ClaimPad`. Cleared the moment the
		--- FTUE reaches `Done` (or is otherwise nil) so post-FTUE rejoins go to
		--- `ClaimPad` as before. Stored as raw position + Y-axis yaw (radians) —
		--- pitch / roll are intentionally dropped to avoid spawning the character
		--- ragdolled. See `OilStateService:SetFtueLastSpawn` /
		--- `:GetFtueLastSpawnCFrame` for read/write, and `FtueService` for the
		--- step-change capture + character-spawn restore wiring.
		ftueLastSpawn = nil :: { x: number, y: number, z: number, yaw: number }?,
	}
end

local function emptyTierMap()
	return {
		Crude = 0,
		Refined = 0,
		Premium = 0,
	}
end

local function defaultTankTiers()
	return {
		Crude = 1,
		Refined = 1,
		Premium = 1,
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
	self._stateReadyForTimersCallback = nil :: ((number, { any }) -> ())?
		self._dataStore = nil
	self._devSkipSaveOnNextDrop = {} :: { [number]: boolean }
	--- Set by `init.server` after `MonetizationService` is required. Used by
	--- `AddCash` to apply the **DoubleEarnings** GamePass multiplier to every
	--- gameplay cash credit. Refunds and direct Robux currency packs opt out
	--- via the `skipMultiplier = true` option so the player isn't getting back
	--- 2x what they paid (refund) or doubling a cash pack the price was set
	--- against (Robux currency grant).
	self._monetizationService = nil :: any
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

--- Set by `init.server` after `MonetizationService` is constructed. Optional
--- — without it `AddCash` skips the GamePass multiplier (effectively the same
--- as every caller passing `{ skipMultiplier = true }`).
function OilStateService:SetMonetizationService(monetizationService: any)
	self._monetizationService = monetizationService
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
	-- Drop the dock-ship sub-step persistence whenever we leave that step so a
	-- save flush mid-transition can never re-arm a stale Dockman / CargoBuy /
	-- CloseModal value on a future rejoin.
	if step ~= FtueConfig.Step.WaitDocksUpgradeShip then
		(state :: any).ftueDocksUpgradeSubStep = nil
	end
	-- Tutorial escort vessel is only for the first dispatch during **`WaitPlotShipment`**; never after FTUE completes or past that leg.
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

--- Persist (or clear with `nil`) the player's FTUE rejoin anchor.
--- Pass a `CFrame` to snapshot — only position + Y-axis yaw are stored so we
--- never spawn the player ragdolled (pitch/roll dropped). `nil` clears the
--- anchor (called on `Done`/cancel so post-FTUE rejoins go back to ClaimPad).
--- Reads/writes are no-ops if the player has no loaded state — silently safe
--- to call from `_setStep` even mid-load.
function OilStateService:SetFtueLastSpawn(userId: number, cframe: CFrame?)
	local state = self._statesByUserId[userId]
	if not state then
		return
	end
	if cframe == nil then
		if (state :: any).ftueLastSpawn == nil then
			return
		end
		(state :: any).ftueLastSpawn = nil
		self:_markDirty(userId)
		return
	end
	local _, yaw, _ = cframe:ToEulerAnglesYXZ()
	local pos = cframe.Position
	;(state :: any).ftueLastSpawn = {
		x = pos.X,
		y = pos.Y,
		z = pos.Z,
		yaw = yaw,
	}
	self:_markDirty(userId)
end

--- Returns the persisted FTUE rejoin CFrame (position + yaw only) or nil if
--- the player has no anchor or is no longer mid-FTUE. Consumers
--- (`PlotService` / `FtueService`) use this to override the default ClaimPad
--- teleport on the first character spawn after rejoin and on in-session FTUE
--- death-respawns.
function OilStateService:GetFtueLastSpawnCFrame(userId: number): CFrame?
	local state = self._statesByUserId[userId]
	if not state then
		return nil
	end
	if (state :: any).ftueCompleted == true then
		return nil
	end
	local snap = (state :: any).ftueLastSpawn
	if typeof(snap) ~= "table" then
		return nil
	end
	return CFrame.new(snap.x, snap.y, snap.z) * CFrame.fromEulerAnglesYXZ(0, snap.yaw, 0)
end

--- Look up the player by `userId`, read their HumanoidRootPart `CFrame`, and
--- persist it as the FTUE rejoin anchor. No-op (and does **not** clear the
--- existing anchor) when the character / HRP isn't available — that way a
--- mid-respawn `PlayerRemoving` falls back to the previous step-change
--- snapshot rather than wiping it.
function OilStateService:CaptureFtueSpawnSnapshot(userId: number)
	local player = Players:GetPlayerByUserId(userId)
	if not player then
		return
	end
	local char = player.Character
	if not char then
		return
	end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not (hrp and hrp:IsA("BasePart")) then
		return
	end
	self:SetFtueLastSpawn(userId, hrp.CFrame)
end

--- Persist the dock-ship sub-step so a player who quits mid-leg rejoins on the
--- **same** beam / pointer they last saw. Valid values:
---   * `Dockman` — world beam to the dockman (no UI pointer)
---   * `CargoBuy` — `CargoUpgradePointer` over the cargo upgrade button
---   * `ChangeShip` — `ChangeShipPointer` over the change-ship button (after upgrade buy)
---   * `SelectShipOpen` — `CloseButtonPointer` on `SelectShipPanelGui` (browse + close)
---   * `CloseModal` — `ClosePointer` on `ShipManagementPanelGui` (close to advance)
---   * `nil` — not in the leg
--- `FtueService` mirrors its `Constants.FtueDocksUpgradeSubStepAttribute` writes
--- through this setter.
function OilStateService:SetFtueDocksUpgradeSubStep(userId: number, sub: string?)
	local state = self._statesByUserId[userId]
	if not state then
		return
	end
	if
		sub ~= nil
		and sub ~= "Dockman"
		and sub ~= "CargoBuy"
		and sub ~= "ChangeShip"
		and sub ~= "SelectShipOpen"
		and sub ~= "CloseModal"
	then
		sub = nil
	end
	if (state :: any).ftueDocksUpgradeSubStep == sub then
		return
	end
	(state :: any).ftueDocksUpgradeSubStep = sub
	self:_markDirty(userId)
end

--- Fired after a plot profile is loaded into memory: `(userId, drillCompletions)`.
--- Used to replay completed timers that finished while offline and to schedule remaining delays.
function OilStateService:SetStateReadyForTimersCallback(cb: (number, { any }) -> ())
	self._stateReadyForTimersCallback = cb
end

-- Rehydrate runs synchronously so the first `PushState` after assign does not show stale in-progress ops.
-- Client VFX replay + `task.delay` wiring is deferred until `DrillingService` has started.
function OilStateService:_invokeStateTimersReady(userId: number)
	local drillDone = self:RehydrateExpiredTimers(userId)
	task.defer(function()
		local cb = self._stateReadyForTimersCallback
		if not cb then
			return
		end
		cb(userId, drillDone)
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
		--- Snapshot the FTUE rejoin anchor **before** flushing so a player who
		--- disconnects mid-leg lands back where they were on next join (instead
		--- of the ClaimPad). No-op when the character has already torn down or
		--- when the player is post-FTUE (`SetFtueLastSpawn` early-outs there).
		--- Done here (vs. `FtueService:PlayerRemoving`) so we don't depend on
		--- listener connect-order between services — the very next line is the
		--- flush, so the snapshot is guaranteed to be in the persisted blob.
		local stepAttr = player:GetAttribute(Constants.FtueStepAttribute)
		if FtueConfig.Enabled == true
			and typeof(stepAttr) == "string"
			and stepAttr ~= FtueConfig.Step.Done
		then
			self:CaptureFtueSpawnSnapshot(player.UserId)
		end
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
	local VeinConfig = require(Shared:WaitForChild("Config"):WaitForChild("VeinConfig"))
	local groundType = VeinConfig.GroundByRow[row]
	if not groundType then
		return floorPositive(OilConfig.ChunkUnlockBaseCost)
	end
	return VeinConfig.GetChunkUnlockCostByGround(groundType.name)
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
			isCenterPump = drill.isCenterPump == true,
		})
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
					local tierName = if typeof(e.tier) == "string" and e.tier ~= "" then e.tier else "T1"
					local tierCfg = OilConfig.DrillTiers[tierName] or OilConfig.DrillTiers.T1
					local depthMeters = e.depthMeters
					if typeof(depthMeters) ~= "number" and typeof(e.chunkId) == "string" and typeof(e.tileKey) == "string" then
						local chunk = state.chunksById[e.chunkId]
						local tile = chunk and chunk.tiles and chunk.tiles[e.tileKey]
						if typeof(tile) == "table" then
							depthMeters = tonumber(tile.drillSeconds)
						end
					end
					if typeof(depthMeters) ~= "number" then
						depthMeters = tierCfg and tierCfg.fallbackSeconds or nil
					end
					local metersPerSecond = tonumber(e.metersPerSecond)
					if typeof(metersPerSecond) ~= "number" then
						metersPerSecond = (tierCfg and tierCfg.timeDivisor) or 1
					end
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
						depthMeters = depthMeters,
						metersPerSecond = metersPerSecond,
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

	local tankTiers = {
		Crude = OilTankConfig.ClampTier(state.tankTiers and state.tankTiers.Crude or 1),
		Refined = OilTankConfig.ClampTier(state.tankTiers and state.tankTiers.Refined or 1),
		Premium = OilTankConfig.ClampTier(state.tankTiers and state.tankTiers.Premium or 1),
	}
	local tankCapacities = {
		Crude = OilTankConfig.GetCapacity(tankTiers.Crude),
		Refined = OilTankConfig.GetCapacity(tankTiers.Refined),
		Premium = OilTankConfig.GetCapacity(tankTiers.Premium),
	}
	local tankUpgradeCosts = {
		Crude = OilTankConfig.GetUpgradeCost(tankTiers.Crude),
		Refined = OilTankConfig.GetUpgradeCost(tankTiers.Refined),
		Premium = OilTankConfig.GetUpgradeCost(tankTiers.Premium),
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
		--- Sent on every snapshot + push so `SelectShipPanel` can render the
		--- locked / owned state without invoking a separate snapshot RemoteFn.
		--- Keys are skin ids, values are always `true`. Unknown ids are
		--- filtered defensively (catalog rename safety).
		ownedShipSkinIds = (function()
			local out: { [string]: boolean } = { DefaultTanker = true }
			if typeof(state.ownedShipSkinIds) == "table" then
				for skinId, owned in pairs(state.ownedShipSkinIds) do
					if typeof(skinId) == "string" and skinId ~= "" and owned == true and ShipSkinCatalog.Skins[skinId] then
						out[skinId] = true
					end
				end
			end
			return out
		end)(),
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
		upgradeShipCapacityCost = (function()
			local capL = math.clamp(math.floor(state.shipCapacityLevel or 1), 1, ShipUpgradeConfig.MaxCapacityLevel)
			local capCost = ShipUpgradeConfig.GetCapacityUpgradeCost(capL)
			local plrSnap = Players:GetPlayerByUserId(userId)
			if FtueConfig.Enabled and plrSnap and typeof(capCost) == "number" and capCost > 0 then
				local fs = plrSnap:GetAttribute(Constants.FtueStepAttribute)
				local sub = plrSnap:GetAttribute(Constants.FtueDocksUpgradeSubStepAttribute)
				if
					fs == FtueConfig.Step.WaitDocksUpgradeShip
					and sub == "CargoBuy"
					and (state :: any).ftueFreeCargoCapacityUpgradeUsed ~= true
				then
					return 0
				end
			end
			return capCost
		end)(),
		chunks = chunks,
		drills = drills,
		activeDrills = activeDrills,
		chunkConfig = {
			size = OilConfig.Chunks.Size,
			rows = OilConfig.Chunks.GridRows,
			cols = OilConfig.Chunks.GridCols,
			startingCenterSize = OilConfig.Chunks.StartingCenterSize,
		},
		--- Tutorial completion flag. Mirrors `state.ftueCompleted` so the
		--- client can gate features that should only run after the tutorial
		--- (currently: the post-login Robux Shop auto-open in
		--- `init.client.luau`). Always boolean (`true`/`false`) — never `nil`.
		ftueCompleted = (state :: any).ftueCompleted == true,
		--- Suppression flag for the post-login Robux Shop auto-open. The
		--- client only auto-opens the shop when this is `false`. Server
		--- flips it to `true` on the first successful Robux purchase via
		--- `MonetizationService` → `OilStateService:MarkRobuxShopAutoOpenDismissed`.
		robuxShopAutoOpenDismissed = (state :: any).robuxShopAutoOpenDismissed == true,
		--- Per-itemId stack counts of single-use run-upgrades the player
		--- currently owns. Drives the "x N" badge on `RunUpgradeCard*` in
		--- `ShipOilPanelGui` and lets the panel disable / hide the buy CTA
		--- when sufficient stock is in inventory. `{}` when nothing owned.
		runUpgradeOwnedByItemId = (function()
			local out: { [string]: number } = {}
			if typeof(state.runUpgradeOwnedByItemId) == "table" then
				for itemId, n in pairs(state.runUpgradeOwnedByItemId) do
					if typeof(itemId) == "string" and itemId ~= "" and typeof(n) == "number" then
						local c = math.floor(n)
						if c > 0 then
							out[itemId] = c
						end
					end
				end
			end
			return out
		end)(),
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

--- Credits the player's cash balance, applying the **DoubleEarnings** GamePass
--- multiplier (2x) when the player owns it and the caller did not pass
--- `opts.skipMultiplier = true`.
---
--- Returns `(success, actualAdded)` — `actualAdded` reflects the post-multiplier
--- amount so callers that surface the payout in user-facing copy
--- (`OilMarketService` "Sold N barrels for $X!" toasts) can show the real
--- credited number instead of the pre-multiplier number.
---
--- Pass `opts = { skipMultiplier = true }` for:
---   * **Refunds** (`ArmyGeneralService` airstrike refund, `EquipmentShopService`
---     backpack-failure refund) — refunding 2x what the player paid would
---     duplicate cash on every failure.
---   * **Direct Robux currency grants** (`MonetizationService:_grantCurrency`) —
---     the listed Robux price was sized against the catalog's `cashAmount`;
---     doubling that on top of the GamePass would silently overpay.
---   * Anywhere else the credit is "money the player already had returning",
---     not money they earned through gameplay.
function OilStateService:AddCash(userId: number, amount: number, opts: { skipMultiplier: boolean? }?): (boolean, number)
	local state = self._statesByUserId[userId]
	if not state then
		return false, 0
	end
	local value = floorPositive(amount)
	if value <= 0 then
		return true, 0
	end
	local skipMultiplier = (opts ~= nil) and (opts :: any).skipMultiplier == true
	if not skipMultiplier and self._monetizationService then
		local player = Players:GetPlayerByUserId(userId)
		if player then
			-- `HasGamePassEffect` itself caches `UserOwnsGamePassAsync` per
			-- (userId, gamePassId); the call here is hot but cheap after the
			-- first lookup. If `MonetizationService` somehow throws, we
			-- swallow it and treat the player as not owning the boost so a
			-- transient marketplace error never blocks gameplay credits.
			local ok, owns = pcall(function()
				return self._monetizationService:HasGamePassEffect(player, "DoubleEarnings")
			end)
			if ok and owns == true then
				value = value * 2
			end
		end
	end
	state.cash += value
	self:_markDirty(userId)
	return true, value
end

-- Auto-place a T1 pump at the center tile (T33) of a section.
-- This pump is permanent and can only be upgraded, not removed.
function OilStateService:_autoPlaceCenterPump(userId: number, state: any, chunk: any, groundType: any)
	local centerTileKey = "T33"
	local tile = chunk.tiles and chunk.tiles[centerTileKey]
	if not tile then warn("[CenterPump] No tile T33 in chunk " .. tostring(chunk.chunkId)) return end

	-- Mark center tile as having the fixed pump
	tile.hasCenterPump = true
	tile.drilled = true
	tile.hasOil = true

	-- Resolve position from the plot model
	local plot = state.plot or self._plotService:GetOwnedPlot(userId)
	if not plot then warn("[CenterPump] No plot for user " .. tostring(userId)) return end

	local sectionModel = self._plotService:GetChunkModel(plot, chunk.chunkId)
	if not sectionModel then warn("[CenterPump] No section model for " .. tostring(chunk.chunkId) .. " in " .. plot.Name) return end

	local tilePart = self._plotService:FindChunkTileBasePart(sectionModel, centerTileKey)
	if not tilePart then warn("[CenterPump] No tile part T33 in section " .. tostring(chunk.chunkId)) return end

	local topY = tilePart.Position.Y + tilePart.Size.Y / 2
	local sx, sz = tilePart.Position.X, tilePart.Position.Z

	-- Compute cell coords (T33 = local row 3, col 3)
	local s = staticGridConstants()
	local localR, localC = 3, 3
	local cellR = (chunk.row - 1) * s.subTilesPerSide + localR
	local cellC = (chunk.col - 1) * s.subTilesPerSide + localC
	local ck = cellKey(cellR, cellC)

	local tierCfg = OilConfig.PumpTiers and OilConfig.PumpTiers["T1"]
	if not tierCfg then return end

	local biomeConfig = OilConfig.Biomes[chunk.biome] or OilConfig.Biomes.Desert or { flowMul = 1, tierMix = { Crude = 100 } }
	local pumpId = state.nextDrillId
	state.nextDrillId += 1

	local pump = {
		drillId = pumpId,
		chunkId = chunk.chunkId,
		biome = chunk.biome,
		tier = "T1",
		tileKey = centerTileKey,
		template = tierCfg.templateName,
		scale = 1,
		variant = nil,
		position = Vector3.new(sx, topY, sz),
		flowBase = OilConfig.DrillBaseFlow * (biomeConfig.flowMul or 1) * (tierCfg.flowMultiplier or 1),
		tierMix = copyTierMap(biomeConfig.tierMix or { Crude = 100 }),
		tileOilType = tile.oilType,
		cellKey = ck,
		cellRow = cellR,
		cellCol = cellC,
		localBuffer = emptyTierMap(),
		connected = true, -- center pump is always connected
		placementCost = 0,
		isCenterPump = true, -- flag: can't be removed, only upgraded
	}
	state.drillsById[pumpId] = pump
	state.activeDrillCount += 1
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

	-- Vein system: ground type determined by row, all tiles same appearance
	local VeinConfig = require(Shared:WaitForChild("Config"):WaitForChild("VeinConfig"))
	local groundType = VeinConfig.GroundByRow[chunk.row] or VeinConfig.GroundTypes.Bronze
	local rng = Random.new(userId * 97 + chunk.row * 31 + chunk.col * 17 + math.floor(workspace:GetServerTimeNow() * 1000))

	chunk.unlocked = true
	chunk.biome = groundType.name -- store ground type name as biome for compat
	chunk.revealed = true -- no reveal animation needed, tiles appear immediately
	chunk.groundType = groundType.name

	-- Generate per-tile data — all tiles use ground type's appearance
	-- Oil type / vein data is NOT rolled here — it's rolled at drill completion
	local subTiles = staticGridConstants().subTilesPerSide
	chunk.tiles = {}

	for tr = 1, subTiles do
		for tc = 1, subTiles do
			local tileKey = string.format("T%d%d", tr, tc)
			chunk.tiles[tileKey] = {
				oilType = nil, -- rolled at drill completion
				hasOil = true, -- placeholder, real result from vein roll
				tileName = groundType.name,
				tileMaterial = groundType.material.Name,
				tileColorR = math.floor(groundType.color.R * 255),
				tileColorG = math.floor(groundType.color.G * 255),
				tileColorB = math.floor(groundType.color.B * 255),
				drillSeconds = groundType.drillSeconds,
				drilled = false,
			}
		end
	end

	-- Auto-place a T1 pump at center tile T33
	self:_autoPlaceCenterPump(userId, state, chunk, groundType)

	self:_markDirty(userId)
	self:PushState(userId)

	return true, "OK", string.format("%s Plot Unlocked!", groundType.name)
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

-- Complete any in-progress drills whose `endTime` is already past (e.g. while offline).
-- Returns payloads matching `CompleteDrill` for replaying client VFX.
function OilStateService:RehydrateExpiredTimers(userId: number): { any }
	local state = self._statesByUserId[userId]
	if not state then
		return {}
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
	if #drillIds > 0 then
		self:_markDirty(userId)
	end
	return drillDone
end

--- Find tiles with revealPending=true (drilled but player never clicked shovel) and return
--- payloads matching _fireDrillCompleted format so the client can re-spawn DrillComplete models.
function OilStateService:GetUnrevealedTiles(userId: number): { any }
	local state = self._statesByUserId[userId]
	if not state then return {} end
	local plot = state.plot or self._plotService:GetOwnedPlot(userId)
	local results = {}
	for chunkId, chunk in pairs(state.chunksById) do
		if chunk.tiles then
			for tileKey, tile in pairs(chunk.tiles) do
				if tile.drilled and tile.revealPending and typeof(tile.revealedAt) ~= "number" then
					local px, py, pz = 0, 0, 0
					-- Always resolve from live plot geometry — saved drillPosition is from
					-- a previous plot assignment and has wrong absolute world coordinates
					if plot then
						local topY = self._plotService:GetChunkTileSurfaceWorldY(plot, chunkId, tileKey)
						local sectionModel = self._plotService:GetChunkModel(plot, chunkId)
						if topY and sectionModel then
							py = topY
							local tilePart = self._plotService:FindChunkTileBasePart(sectionModel, tileKey)
							if tilePart then
								px = tilePart.Position.X
								pz = tilePart.Position.Z
							end
						end
					end
					if px ~= 0 or pz ~= 0 then
						table.insert(results, {
							drillId = 0,
							chunkId = chunkId,
							tileKey = tileKey,
							position = { x = px, y = py, z = pz },
							oilType = tile.oilType,
							hasOil = tile.hasOil,
						})
					end
				end
			end
		end
	end
	return results
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
		and ftueStep == FtueConfig.Step.WaitDrillOil_WIP
	)
	if ftueFreeNoSellback then
		effectiveSeconds = math.max(0.5, tonumber(FtueConfig.FtueTutorialDrillSeconds) or 5)
	end

	local depthMeters = baseSeconds -- 1 second = 1 meter
	local metersPerSecond = tierCfg.timeDivisor or 1
	--- FTUE freebie shortens `effectiveSeconds` without touching the tile's
	--- `baseSeconds`, which would leave the billboard "Xm / Ym" depth counter
	--- creeping at the slow tier-1 speed while the drill itself finishes in a
	--- few seconds (visual mismatch — depth caps mid-drill, then the tile spawns
	--- oil "early"). Recompute `metersPerSecond` so the counter counts up to the
	--- full `depthMeters` over `effectiveSeconds`, matching the on-screen timer.
	if ftueFreeNoSellback and effectiveSeconds > 0 then
		metersPerSecond = math.max(1, math.ceil(depthMeters / effectiveSeconds))
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
		depthMeters = depthMeters,
		metersPerSecond = metersPerSecond,
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
		depthMeters = depthMeters,
		metersPerSecond = metersPerSecond,
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
	if not chunk or not chunk.tiles or not chunk.tiles[entry.tileKey] then
		self:_markDirty(userId)
		return false, nil
	end

	local tile = chunk.tiles[entry.tileKey]
	tile.drilled = true
	tile.revealPending = true -- wait for player to press E on DrillComplete
	tile.drillPosition = { x = entry.position.X, y = entry.position.Y, z = entry.position.Z }

	local VeinCrateConfig = require(Shared:WaitForChild("Config"):WaitForChild("VeinCrateConfig"))
	local groundTypeName = chunk.groundType or chunk.biome or "Bronze"
	local rng = Random.new(userId * 13 + drillId * 7 + math.floor(workspace:GetServerTimeNow() * 1000))
	local rolledType = VeinCrateConfig.RollVeinType(groundTypeName, rng)

	--- FTUE first reveal: force Crude Geyser (item-11) — the Bronze Legendary jackpot.
	--- Gives new players an immediate exciting hook. Only applies once per profile.
	if (state :: any).ftueFirstRevealApplied ~= true then
		local ftueDef = VeinCrateConfig.GetById("item-11")
		if ftueDef then
			rolledType = ftueDef
		end
		(state :: any).ftueFirstRevealApplied = true
	end

	local veinResult = VeinCrateConfig.BuildVeinResult(rolledType, groundTypeName)

	tile.veinTypeId = rolledType.id
	tile.veinResult = veinResult

	if rolledType.isUnlucky then
		tile.hasOil = false
		tile.oilType = nil
	else
		tile.hasOil = true
		tile.oilType = rolledType.primaryInternalOilType
	end

	self:_markDirty(userId)
	return true, {
		drillId = drillId,
		chunkId = entry.chunkId,
		tileKey = entry.tileKey,
		cellKey = entry.cellKey,
		position = entry.position,
		oilType = tile.oilType,
		hasOil = tile.hasOil,
		revealPending = true,
	}
end

function OilStateService:RevealTile(userId: number, chunkId: string, tileKey: string): (boolean, any)
	local state = self._statesByUserId[userId]
	if not state then return false, nil end
	local chunk = state.chunksById[chunkId]
	if not chunk or not chunk.tiles or not chunk.tiles[tileKey] then return false, nil end

	local tile = chunk.tiles[tileKey]
	if not tile.drilled then return false, nil end
	if not tile.revealPending then return false, nil end

	tile.revealPending = nil
	tile.revealedAt = workspace:GetServerTimeNow()
	tile.visualsStartedAt = nil

	local VeinCrateConfig = require(Shared:WaitForChild("Config"):WaitForChild("VeinCrateConfig"))
	local gt = chunk.groundType or chunk.biome or "Bronze"
	local rolledType = if typeof(tile.veinTypeId) == "string" then VeinCrateConfig.GetById(tile.veinTypeId) else nil
	if not rolledType then
		local rng = Random.new(userId * 17 + math.floor(workspace:GetServerTimeNow() * 1000))
		rolledType = VeinCrateConfig.RollVeinType(gt, rng)
		tile.veinTypeId = rolledType.id
		tile.veinResult = VeinCrateConfig.BuildVeinResult(rolledType, gt)
		tile.hasOil = not rolledType.isUnlucky
		tile.oilType = if rolledType.isUnlucky then nil else rolledType.primaryInternalOilType
	end
	self:_markDirty(userId)

	return true, {
		chunkId = chunkId,
		tileKey = tileKey,
		oilType = tile.oilType,
		hasOil = tile.hasOil,
		veinResult = tile.veinResult,
		veinTypeId = rolledType.id,
		groundType = gt,
	}
end

function OilStateService:StartRevealVisuals(userId: number, chunkId: string, tileKey: string): (boolean, any)
	local state = self._statesByUserId[userId]
	if not state then return false, nil end
	local chunk = state.chunksById[chunkId]
	if not chunk or not chunk.tiles or not chunk.tiles[tileKey] then return false, nil end

	local tile = chunk.tiles[tileKey]
	if not tile.drilled then return false, nil end
	if typeof(tile.revealedAt) ~= "number" then return false, nil end

	if tile.hasOil ~= false and typeof(tile.visualsStartedAt) ~= "number" then
		tile.visualsStartedAt = workspace:GetServerTimeNow()
		self:_markDirty(userId)
		--- FTUE one-shot: grant a single barrel of the rolled vein's primary tier the
		--- moment production visuals begin so the new player can see oil in their tank
		--- and dispatch a shipment without waiting on the normal `barrelsPerSecond`
		--- accumulation. Only fires for the very first revealed FTUE tile per profile.
		if (state :: any).ftueFirstBarrelGranted ~= true then
			local primaryTier = tile.oilType
			if typeof(primaryTier) == "string" and OilTankConfig.OilColors[primaryTier] ~= nil then
				local cap = tankCapacity(state, primaryTier)
				local space = cap - (state.oilByTier[primaryTier] or 0)
				if space > 0 then
					state.oilByTier[primaryTier] += 1
					state.totalOil += 1
					(state :: any).ftueFirstBarrelGranted = true
					self:_markDirty(userId)
					self:PushState(userId)
				end
			end
		end
	end

	return true, {
		chunkId = chunkId,
		tileKey = tileKey,
		hasOil = tile.hasOil,
		visualsStartedAt = tile.visualsStartedAt,
	}
end

function OilStateService:TryUpgradeCenterPump(userId: number, chunkId: string): (boolean, string, string)
	local state = self._statesByUserId[userId]
	if not state then return false, "ERR_NO_STATE", "State unavailable." end
	local chunk = state.chunksById[chunkId]
	if not chunk or not chunk.unlocked then return false, "ERR_BAD_CHUNK", "Chunk not found." end

	-- Find the center pump in this chunk
	local centerPump = nil
	for _, drill in pairs(state.drillsById) do
		if drill.chunkId == chunkId and drill.isCenterPump then
			centerPump = drill
			break
		end
	end
	if not centerPump then return false, "ERR_NO_PUMP", "No center pump in this section." end

	local VeinConfigUpg = require(Shared:WaitForChild("Config"):WaitForChild("VeinConfig"))
	local gt = chunk.groundType or chunk.biome or "Bronze"
	local nextTier, cost = VeinConfigUpg.GetUpgradeCost(centerPump.tier, gt)
	if not nextTier or not cost then
		return false, "ERR_MAX_TIER", "Pump is already max tier!"
	end

	if not self:TrySpendCash(userId, cost) then
		return false, "ERR_NOT_ENOUGH_CASH", string.format("Need $%d to upgrade.", cost)
	end

	-- Upgrade the pump
	local upgDef = VeinConfigUpg.PumpUpgrades[nextTier]
	centerPump.tier = nextTier
	centerPump.template = upgDef.templateName
	-- Recalculate flow with new multiplier
	local OilConfig = require(Shared:WaitForChild("Config"):WaitForChild("OilConfig"))
	local biomeConfig = OilConfig.Biomes[chunk.biome] or OilConfig.Biomes.Desert or { flowMul = 1 }
	centerPump.flowBase = OilConfig.DrillBaseFlow * (biomeConfig.flowMul or 1) * upgDef.flowMult

	self:_markDirty(userId)
	self:PushState(userId)

	return true, "OK", string.format("Pump upgraded to %s!", upgDef.displayName)
end

-- (drills-only refactor) Removed: TryStartProspect, CompleteProspect,
-- TryPlacePump, TryPlaceDrill. Pumps are now static center-pumps auto-placed
-- per chunk (upgraded only via prox prompt); prospecting was replaced by the
-- per-tile drill reveal flow.

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
	if kind == "drill" then
		local drillId = tonumber(payload.targetId)
		entry = drillId and state.activeDrills[drillId] or nil
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
-- payload = { targetKind = "drill", targetId } — only active (in-progress) drills can
-- be cancelled this way. Pumps are static center-pumps (upgrade-only); pipes / drums /
-- prospectors no longer exist post drills-only refactor.
function OilStateService:TryHammerDestroy(userId: number, payload: any): (boolean, string, string, any)
	local state = self._statesByUserId[userId]
	if not state then return false, "ERR_NO_STATE", "State unavailable.", nil end
	if typeof(payload) ~= "table" then return false, "ERR_BAD_PAYLOAD", "Missing payload.", nil end
	local kind = payload.targetKind
	local refundedAmount = 0

	if kind == "drill" then
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

-- (drills-only refactor) Removed: TryPlacePipe / _TryPlacePipe_LEGACY / TryRemovePipe.
-- Pipes are obsolete; oil flows from drilled tiles directly to the auto-placed
-- center pump per chunk (see OilProductionService:_accumulateCenterPumpChunk).

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

--- FTUE testing: add whole barrels to refinery storage (`oilByTier`), clamped to tank capacity.
function OilStateService:FtueTestGrantRefineryBarrels(userId: number, oilType: string, barrelCount: number): number
	local state = self._statesByUserId[userId]
	if not state then
		return 0
	end
	local tier = oilType
	if OilTankConfig.OilColors[tier] == nil then
		tier = "Crude"
	end
	local want = floorPositive(barrelCount)
	if want <= 0 then
		return 0
	end
	local cap = tankCapacity(state, tier)
	local have = floorPositive(state.oilByTier[tier] or 0)
	local add = math.min(want, math.max(0, cap - have))
	if add <= 0 then
		return 0
	end
	state.oilByTier[tier] = have + add
	state.totalOil = sumTierMap(state.oilByTier)
	self:_markDirty(userId)
	self:PushState(userId)
	return add
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

		-- Starting chunk gets ground type based on its row (vein system)
		if def.startingChunk then
			local VeinConfigStarter = require(Shared:WaitForChild("Config"):WaitForChild("VeinConfig"))
			local gt = VeinConfigStarter.GroundByRow[def.row] or VeinConfigStarter.GroundTypes.Bronze
			chunkData.biome = gt.name
			chunkData.groundType = gt.name
			chunkData.revealed = true
			chunkData.tiles = {}
			local subTiles = staticGridConstants().subTilesPerSide
			for tr = 1, subTiles do
				for tc = 1, subTiles do
					local tileKey = string.format("T%d%d", tr, tc)
					chunkData.tiles[tileKey] = {
						oilType = nil,
						hasOil = true,
						tileName = gt.name,
						tileMaterial = gt.material.Name,
						tileColorR = math.floor(gt.color.R * 255),
						tileColorG = math.floor(gt.color.G * 255),
						tileColorB = math.floor(gt.color.B * 255),
						drillSeconds = gt.drillSeconds,
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
		ftueFreeCargoCapacityUpgradeUsed = false,
		--- See `buildDefaultPersisted` — runtime mirror of the one-shot free dock equipment shop drill flag.
		ftueFreeDocksDrillUsed = false,
		--- See `buildDefaultPersisted` — runtime mirror of the one-shot exact-Rare FTUE first-reveal flag.
		ftueFirstRevealApplied = false,
		--- See `buildDefaultPersisted` — runtime mirror of the one-shot fast first-barrel grant.
		ftueFirstBarrelGranted = false,
		-- Per-tank upgrade levels. storageCapacity is derived = sum of tank capacities.
		tankTiers = defaultTankTiers(),
		storageCapacity = 0, -- set below from tankTiers
		totalOil = 0,
		oilByTier = {
			Crude = 0,
			Refined = 0,
			Premium = 0,
		},
		pendingFloats = {
			Crude = 0,
			Refined = 0,
			Premium = 0,
		},
		activeShipmentCount = 0,
		shipSpeedLevel = 1,
		shipCapacityLevel = 1,
		shipSkinId = "DefaultTanker",
		--- See `buildDefaultPersisted` — same field, runtime side. Always
		--- includes the starter tanker; `_applyPersistedIntoState` overlays
		--- saved entries on top and `MonetizationService` mutates this via
		--- `OilStateService:GrantShipSkin` after a verified receipt.
		ownedShipSkinIds = { DefaultTanker = true } :: { [string]: boolean },
		chunksById = chunksById,
		drillsById = {},         -- each record is a placed PUMP (center pumps + legacy migrated)
		activeDrills = {},       -- in-progress drills; also persisted (wall-clock start/end)
		nextDrillId = 1,
		activeDrillCount = 0,
		equipmentOwnedByItemId = {} :: { [string]: number },
		--- When true, first inventory sync seeds `equipmentOwnedByItemId` from shop tools in Backpack (legacy profiles).
		equipmentOwnedNeedsInventoryBackfill = false,
		--- Runtime mirror of persisted `runUpgradesOwned`. itemId -> stack
		--- count. Consumed by gameplay services (e.g. Security Personnel
		--- decrements on dispatch via `:ConsumeRunUpgradeOwned`). Empty table
		--- means no run-upgrades stocked.
		runUpgradeOwnedByItemId = {} :: { [string]: number },
		ftueStep = if FtueConfig.Enabled then FtueConfig.Step.Intro else nil,
		ftueCompleted = not FtueConfig.Enabled,
		ftueDoneScreenAcknowledged = false,
		--- See `buildDefaultPersisted` — runtime mirror of the Robux-shop
		--- post-login auto-open suppression flag. Flips on the first
		--- successful Robux purchase (see `MarkRobuxShopAutoOpenDismissed`).
		robuxShopAutoOpenDismissed = false,
		--- See `buildDefaultPersisted` — runtime mirror of the persisted `WaitDocksUpgradeShip`
		--- sub-step (`Dockman` / `CargoBuy` / `CloseModal`) so rejoin restores the right beam + pointer.
		ftueDocksUpgradeSubStep = nil :: string?,
		--- See `buildDefaultPersisted` — runtime mirror of the persisted FTUE rejoin
		--- anchor. Read by `PlotService` / `FtueService` to override the default
		--- ClaimPad teleport on the **first** character spawn after rejoin and on
		--- in-session FTUE death-respawns.
		ftueLastSpawn = nil :: { x: number, y: number, z: number, yaw: number }?,
	}

	local persisted = self:_loadPersistedProfile(userId)
	if persisted then
		self:_applyPersistedIntoState(state, persisted, plot)
	end

	-- Fix tile state on load:
	-- 1. Clear stale tubeDelayed
	-- 2. Tiles that are drilled but never revealed (no revealedAt) get revealPending restored
	--    so the shovel prompt respawns and puddles don't show
	for _, chunk in pairs(state.chunksById) do
		if chunk.tiles then
			for _, tile in pairs(chunk.tiles) do
				tile.tubeDelayed = nil
				if tile.drilled and typeof(tile.revealedAt) ~= "number" and not tile.hasCenterPump then
					-- Drilled but never revealed — restore revealPending so shovel spawns
					tile.revealPending = true
				else
					tile.revealPending = nil
				end
				if tile.hasOil ~= false and typeof(tile.revealedAt) == "number" and typeof(tile.visualsStartedAt) ~= "number" then
					tile.visualsStartedAt = tile.revealedAt
				end
			end
		end
	end

	-- Derive storageCapacity from per-tank capacities (after persistence may have set tankTiers).
	state.storageCapacity = totalTankCapacity(state)

	-- Auto-place center pumps on all unlocked sections (including starter chunk)
	for _, chunk in pairs(state.chunksById) do
		if chunk.unlocked and chunk.tiles then
			-- Check if this chunk already has a center pump
			local hasCenterPump = false
			for _, drill in pairs(state.drillsById) do
				if drill.chunkId == chunk.chunkId and drill.isCenterPump then
					hasCenterPump = true
					break
				end
			end
			if not hasCenterPump then
				local VeinConfigInit = require(Shared:WaitForChild("Config"):WaitForChild("VeinConfig"))
				local gt = VeinConfigInit.GroundByRow[chunk.row] or VeinConfigInit.GroundTypes.Bronze
				self:_autoPlaceCenterPump(userId, state, chunk, gt)
			end
		end
	end

	self._statesByUserId[userId] = state
	self:_invokeStateTimersReady(userId)

	-- Force a deferred visual refresh so biome tiles + fog get applied after state is fully set
	task.defer(function()
		self:PushState(userId)
	end)
end

-- (drills-only refactor) Removed: _ensureDefaultPipesForPlayer / _ensureDefaultDrumForPlayer.
-- Pipes + drums no longer exist; the per-chunk auto-placed center pump (see _ensurePlayerState)
-- is the single oil ingress point.

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
	if (persisted :: any).ftueFreeCargoCapacityUpgradeUsed == true then
		(state :: any).ftueFreeCargoCapacityUpgradeUsed = true
	else
		(state :: any).ftueFreeCargoCapacityUpgradeUsed = false
	end
	if (persisted :: any).ftueFreeDocksDrillUsed == true then
		(state :: any).ftueFreeDocksDrillUsed = true
	else
		(state :: any).ftueFreeDocksDrillUsed = false
	end
	if (persisted :: any).ftueFirstRevealApplied == true then
		(state :: any).ftueFirstRevealApplied = true
	else
		(state :: any).ftueFirstRevealApplied = false
	end
	if (persisted :: any).ftueFirstBarrelGranted == true then
		(state :: any).ftueFirstBarrelGranted = true
	else
		(state :: any).ftueFirstBarrelGranted = false
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
		local LEGACY_FTUE_STEP: { [string]: string } = {
			WaitDrill = FtueConfig.Step.WaitDrillOil_WIP,
			WaitPipe = FtueConfig.Step.WaitDrillOil_WIP,
			WaitPump = FtueConfig.Step.WaitDrillOil_WIP,
			Dispatch = FtueConfig.Step.WaitPlotShipment,
			Sell = FtueConfig.Step.WaitWarehouseSell,
		}
		local mapped = LEGACY_FTUE_STEP[s]
		if mapped then
			s = mapped
		end
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

	-- Robux-shop auto-open suppression (persisted). Legacy saves without the key
	-- read as `nil`, which we treat as "not yet dismissed" so existing profiles
	-- get the upsell on next login (intentional — they may not have seen the
	-- Starter Pack yet). The flag flips to `true` on first successful Robux
	-- purchase via `MarkRobuxShopAutoOpenDismissed`.
	if (pFtue :: any).robuxShopAutoOpenDismissed == true then
		(state :: any).robuxShopAutoOpenDismissed = true
	else
		(state :: any).robuxShopAutoOpenDismissed = false
	end

	-- Restore the persisted dock-ship sub-step (only valid while ftueStep ==
	-- WaitDocksUpgradeShip; otherwise force-clear so a stale value can't bleed
	-- through if the step was advanced from a save flush in between).
	do
		local subAny = (pFtue :: any).ftueDocksUpgradeSubStep
		local sub = if typeof(subAny) == "string" then (subAny :: string) else nil
		if sub ~= "Dockman" and sub ~= "CargoBuy" and sub ~= "CloseModal" then
			sub = nil
		end
		if (state :: any).ftueStep == FtueConfig.Step.WaitDocksUpgradeShip then
			(state :: any).ftueDocksUpgradeSubStep = sub
		else
			(state :: any).ftueDocksUpgradeSubStep = nil
		end
	end

	-- Restore the persisted FTUE rejoin anchor (only valid while the player is
	-- still mid-FTUE; ignored once `ftueCompleted == true` so finished players
	-- spawn at ClaimPad even if a stale snapshot somehow survived a flush).
	do
		local snap = (pFtue :: any).ftueLastSpawn
		local mid = (state :: any).ftueCompleted ~= true and typeof((state :: any).ftueStep) == "string"
		if mid and typeof(snap) == "table"
			and typeof(snap.x) == "number"
			and typeof(snap.y) == "number"
			and typeof(snap.z) == "number"
			and typeof(snap.yaw) == "number"
		then
			(state :: any).ftueLastSpawn = {
				x = snap.x,
				y = snap.y,
				z = snap.z,
				yaw = snap.yaw,
			}
		else
			(state :: any).ftueLastSpawn = nil
		end
	end

	-- Tutorial escort ship only applies on **`WaitPlotShipment`**; clear stale flag after that leg or when FTUE is done.
	if FtueConfig.Enabled then
		local fs = (state :: any).ftueStep
		if (state :: any).ftueCompleted == true then
			state.ftueEscortShipmentRemaining = 0
		elseif typeof(fs) == "string" then
			if
				fs == FtueConfig.Step.WaitShipment
				or fs == FtueConfig.Step.WaitWarehouseSell
				or fs == FtueConfig.Step.WaitSell
				or fs == FtueConfig.Step.WaitDocksShipUpgrade
				or fs == FtueConfig.Step.WaitDocksUpgradeShip
				or fs == FtueConfig.Step.WaitDocksHire
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
		for _, tier in ipairs(TIER_ORDER) do
			local value = pot[tier]
			if typeof(value) == "number" then
				state.oilByTier[tier] = floorPositive(value)
			end
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

	-- Run-upgrades (e.g. Security Personnel). Same `{ itemId, count }` row
	-- shape as `equipmentOwned`. Legacy profiles without the field are
	-- treated as "none owned" (no inventory to backfill from).
	state.runUpgradeOwnedByItemId = {}
	if typeof(persisted.runUpgradesOwned) == "table" then
		for _, row in ipairs(persisted.runUpgradesOwned) do
			if typeof(row) == "table" then
				local r = row :: { [string]: any }
				local itemId = r.itemId
				local cnt = r.count
				if typeof(itemId) == "string" and itemId ~= "" and typeof(cnt) == "number" then
					local c = floorPositive(cnt)
					if c > 0 then
						state.runUpgradeOwnedByItemId[itemId] = c
					end
				end
			end
		end
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

	-- Restore the ship-skin ownership map (set in `buildDefaultPersisted`).
	-- Pre-`ownedShipSkinIds` profiles still played the legacy "all skins
	-- selectable" UX, so we honor whatever they had as `shipSkinId` at the
	-- time of the migration: the starter tanker plus the equipped skin gets
	-- seeded as owned. `MonetizationService` will only ever add to this set
	-- on a verified DevProduct receipt — there's no way to lose a skin.
	state.ownedShipSkinIds = { DefaultTanker = true } :: { [string]: boolean }
	if typeof(persisted.ownedShipSkinIds) == "table" then
		for skinId, owned in pairs(persisted.ownedShipSkinIds) do
			if typeof(skinId) == "string" and skinId ~= "" and owned == true and ShipSkinCatalog.Skins[skinId] then
				state.ownedShipSkinIds[skinId] = true
			end
		end
	end
	-- Always grant the equipped skin so a returning player can't be locked
	-- out of the boat they last sailed if their saved ownership map drifted
	-- (e.g. catalog rename, old profile written before this field existed).
	if typeof(state.shipSkinId) == "string" and ShipSkinCatalog.Skins[state.shipSkinId] then
		state.ownedShipSkinIds[state.shipSkinId] = true
	end

	if typeof(persisted.unlockedChunkIds) == "table" then
		for chunkId, isUnlocked in pairs(persisted.unlockedChunkIds) do
			local chunk = state.chunksById[chunkId]
			if chunk and isUnlocked == true then
				chunk.unlocked = true
				chunk.revealed = true
				local VeinConfigPersisted = require(Shared:WaitForChild("Config"):WaitForChild("VeinConfig"))
				local gt = VeinConfigPersisted.GroundByRow[chunk.row] or VeinConfigPersisted.GroundTypes.Bronze
				chunk.biome = gt.name
				chunk.groundType = gt.name
				-- Restore per-tile data
				if typeof(persisted.chunkTiles) == "table" and typeof(persisted.chunkTiles[chunkId]) == "table" then
					chunk.tiles = persisted.chunkTiles[chunkId]
					migrateLegacyStandardTileOil(chunk.tiles)
					migrateLegacyVeinTypeIds(chunk.tiles)
					normalizeChunkTilesToGroundType(chunk.tiles, gt)
				end
			end
		end
	end

	-- (drills-only refactor) Removed: chunkProspected restore. Prospecting was deleted; chunks
	-- become "revealed" via Chunks.RevealAfterDrillCount drilled tiles only.

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
							local baseSec = (tile and tonumber(tile.drillSeconds)) or tierCfg.fallbackSeconds or 10
							local depthMeters = tonumber(r.depthMeters) or baseSec
							local metersPerSecond = tonumber(r.metersPerSecond) or ((tierCfg :: any).timeDivisor or 1)
							local tmpl = if typeof(r.template) == "string" and r.template ~= "" then r.template :: string else tierCfg.templateName
							local nowWall = workspace:GetServerTimeNow()
							local st = tonumber(r.startTime) or nowWall
							local et = tonumber(r.endTime) or (st + 10)
							if et <= st then
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
									depthMeters = depthMeters,
									metersPerSecond = metersPerSecond,
								}
				end
			end
		end
				end
			end
		end
	end

	-- (drills-only refactor) Removed: activeProspectors restore + nextProspectId.

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

	-- (drills-only refactor) Removed: pipes / drums restore + nextPipeId / nextDrumId migration.

	if typeof(persisted.nextDrillId) == "number" then
		state.nextDrillId = math.max(state.nextDrillId, math.floor(persisted.nextDrillId))
	end
	for aid, _ in pairs(state.activeDrills) do
		if typeof(aid) == "number" then
			state.nextDrillId = math.max(state.nextDrillId, aid + 1)
	end
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
	-- Bump the FTUE tile-marker generation so any in-flight retry stops cleanly,
	-- then forget the entry to avoid the map growing across many sessions.
	if self._ftueTileMarkerRetryGen then
		self._ftueTileMarkerRetryGen[userId] = (self._ftueTileMarkerRetryGen[userId] or 0) + 1
		self._ftueTileMarkerRetryGen[userId] = nil
	end
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

	local MAX_LOAD_RETRIES = 3
	local RETRY_DELAY = 1
	for attempt = 1, MAX_LOAD_RETRIES do
		local ok, profileOrErr = pcall(function()
			return self._dataStore:GetAsync(key)
		end)
		if ok and typeof(profileOrErr) == "table" then
			return profileOrErr
		end
		-- Studio access error is permanent — stop retrying immediately.
		if not ok and self._dataStore ~= nil and isDatastoreStudioAccessError(profileOrErr) then
			if not self._dataStoreStudioFallbackWarned then
				self._dataStoreStudioFallbackWarned = true
				warn(
					"[OilStateService] Studio cannot access DataStores (Game Settings → Security → Enable Studio Access to API Services). "
						.. "Using in-session memory for oil profiles for this server run — no cross-session persistence in Studio until enabled."
				)
			end
			self._dataStore = nil
			return nil
		end
		-- Transient error (throttle, timeout, network): retry.
		if not ok and attempt < MAX_LOAD_RETRIES then
			warn(string.format(
				"[OilStateService] Load attempt %d/%d failed for user %d: %s — retrying in %ds",
				attempt, MAX_LOAD_RETRIES, userId, tostring(profileOrErr), RETRY_DELAY
			))
			task.wait(RETRY_DELAY)
		elseif not ok then
			warn(string.format(
				"[OilStateService] Load failed for user %d after %d attempts: %s",
				userId, MAX_LOAD_RETRIES, tostring(profileOrErr)
			))
		end
		-- ok == true but profileOrErr is not a table (nil / non-table) means
		-- the key doesn't exist yet (new player). No point retrying.
		if ok then
			break
		end
	end
	return nil
end

function OilStateService:_serializeState(state)
	local persisted = buildDefaultPersisted()
	persisted.cash = floorPositive(state.cash)
	persisted.ftueEscortShipmentRemaining = math.clamp(math.floor(state.ftueEscortShipmentRemaining or 0), 0, 1)
	persisted.ftueDispatchCashGranted = state.ftueDispatchCashGranted == true
	persisted.ftueTutorialCompleteCashGranted = (state :: any).ftueTutorialCompleteCashGranted == true
	(persisted :: any).ftueFreeCargoCapacityUpgradeUsed = (state :: any).ftueFreeCargoCapacityUpgradeUsed == true
	(persisted :: any).ftueFreeDocksDrillUsed = (state :: any).ftueFreeDocksDrillUsed == true
	(persisted :: any).ftueFirstRevealApplied = (state :: any).ftueFirstRevealApplied == true
	(persisted :: any).ftueFirstBarrelGranted = (state :: any).ftueFirstBarrelGranted == true
	if typeof((state :: any).ftueStep) == "string" then
		(persisted :: any).ftueStep = (state :: any).ftueStep
	elseif (state :: any).ftueCompleted == true then
		(persisted :: any).ftueStep = nil
	else
		(persisted :: any).ftueStep = if FtueConfig.Enabled then FtueConfig.Step.Intro else FtueConfig.Step.Done
	end
	(persisted :: any).ftueCompleted = (state :: any).ftueCompleted == true
	(persisted :: any).ftueDoneScreenAcknowledged = (state :: any).ftueDoneScreenAcknowledged == true
	(persisted :: any).robuxShopAutoOpenDismissed = (state :: any).robuxShopAutoOpenDismissed == true
	-- Only persist the dock-ship sub-step while we're actually in that leg.
	-- Anywhere else it's nil and `_applyPersistedIntoState` re-clears anyway.
	if (state :: any).ftueStep == FtueConfig.Step.WaitDocksUpgradeShip then
		local sub = (state :: any).ftueDocksUpgradeSubStep
		if sub == "Dockman" or sub == "CargoBuy" or sub == "CloseModal" then
			(persisted :: any).ftueDocksUpgradeSubStep = sub
		else
			(persisted :: any).ftueDocksUpgradeSubStep = nil
		end
	else
		(persisted :: any).ftueDocksUpgradeSubStep = nil
	end
	-- FTUE rejoin anchor: only persist while still mid-FTUE so finished players
	-- never carry a stale snapshot back into a fresh post-FTUE session.
	do
		local snap = (state :: any).ftueLastSpawn
		if (state :: any).ftueCompleted ~= true and typeof(snap) == "table" then
			(persisted :: any).ftueLastSpawn = {
				x = snap.x,
				y = snap.y,
				z = snap.z,
				yaw = snap.yaw,
			}
		else
			(persisted :: any).ftueLastSpawn = nil
		end
	end
	persisted.storageCapacity = math.max(1, floorPositive(state.storageCapacity))
	persisted.oilByTier = copyTierMap(state.oilByTier)
	persisted.tankTiers = {
		Crude = OilTankConfig.ClampTier(state.tankTiers and state.tankTiers.Crude or 1),
		Refined = OilTankConfig.ClampTier(state.tankTiers and state.tankTiers.Refined or 1),
		Premium = OilTankConfig.ClampTier(state.tankTiers and state.tankTiers.Premium or 1),
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

	-- (drills-only refactor) Removed: pipes / drums serialization + nextProspectId / nextPipeId / nextDrumId.
	persisted.nextDrillId = state.nextDrillId
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
				depthMeters = ad.depthMeters,
				metersPerSecond = ad.metersPerSecond,
			})
		end
	end

	-- (drills-only refactor) Removed: activeProspectors serialization.
	persisted.shipSpeedLevel = math.clamp(math.floor(state.shipSpeedLevel or 1), 1, ShipUpgradeConfig.MaxSpeedLevel)
	persisted.shipCapacityLevel = math.clamp(math.floor(state.shipCapacityLevel or 1), 1, ShipUpgradeConfig.MaxCapacityLevel)
	persisted.shipSkinId = (typeof(state.shipSkinId) == "string" and state.shipSkinId) or "DefaultTanker"

	-- Persist the Robux-granted ship skin ownership set. Only emit known
	-- catalog ids so a stale skin removed from `ShipSkinCatalog` doesn't
	-- linger in DataStores and a typo in `GrantShipSkin` can't pollute
	-- saves. DefaultTanker is always written so the seed is explicit.
	local ownedOut: { [string]: boolean } = { DefaultTanker = true }
	if typeof(state.ownedShipSkinIds) == "table" then
		for skinId, owned in pairs(state.ownedShipSkinIds) do
			if typeof(skinId) == "string" and skinId ~= "" and owned == true and ShipSkinCatalog.Skins[skinId] then
				ownedOut[skinId] = true
			end
		end
	end
	persisted.ownedShipSkinIds = ownedOut

	persisted.equipmentOwned = {}
	for itemId, n in pairs(state.equipmentOwnedByItemId or {}) do
		local c = floorPositive(n)
		if typeof(itemId) == "string" and itemId ~= "" and c > 0 then
			table.insert(persisted.equipmentOwned, { itemId = itemId, count = c })
		end
	end

	persisted.runUpgradesOwned = {}
	for itemId, n in pairs(state.runUpgradeOwnedByItemId or {}) do
		local c = floorPositive(n)
		if typeof(itemId) == "string" and itemId ~= "" and c > 0 then
			table.insert(persisted.runUpgradesOwned, { itemId = itemId, count = c })
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

function OilStateService:OwnsShipSkin(userId: number, skinId: string?): boolean
	if typeof(skinId) ~= "string" or skinId == "" then
		return false
	end
	-- Starter tanker is always owned, even before state loads, so the UI
	-- shouldn't briefly render "locked" on the very first frame after join.
	if skinId == "DefaultTanker" then
		return true
	end
	local state = self._statesByUserId[userId]
	if not state then
		return false
	end
	local owned = state.ownedShipSkinIds
	return typeof(owned) == "table" and owned[skinId] == true
end

--- Idempotent — called by `MonetizationService` on a verified DevProduct
--- receipt. Returns (didChange, errCode). Caller is responsible for
--- `PushState`/auto-equip side effects so this stays a pure data mutation.
--- Flips the persisted `robuxShopAutoOpenDismissed` flag to `true` so the
--- post-login Robux Shop auto-open never fires again for this player.
--- Idempotent: re-calling on an already-dismissed profile is a cheap no-op
--- (no dirty-mark / re-push). Called from `MonetizationService` on:
---   * `_processReceipt` after `_recordReceiptGranted` (DevProducts)
---   * `PromptGamePassPurchaseFinished` when `wasPurchased == true` (GamePasses)
--- Returns `true` if the flag was newly flipped this call (and a state push
--- was queued), `false` otherwise (no state, or already dismissed).
function OilStateService:MarkRobuxShopAutoOpenDismissed(userId: number): boolean
	local state = self._statesByUserId[userId]
	if not state then
		return false
	end
	if (state :: any).robuxShopAutoOpenDismissed == true then
		return false
	end
	(state :: any).robuxShopAutoOpenDismissed = true
	self:_markDirty(userId)
	-- Push so any client-side listeners (currently none, but trivial future-proofing)
	-- see the new value without waiting for the next snapshot trigger.
	pcall(function()
		self:PushState(userId)
	end)
	return true
end

function OilStateService:GrantShipSkin(userId: number, skinId: string): (boolean, string)
	local state = self._statesByUserId[userId]
	if not state then
		return false, "ERR_NO_STATE"
	end
	if typeof(skinId) ~= "string" or not ShipSkinCatalog.Skins[skinId] then
		return false, "ERR_BAD_SKIN"
	end
	if typeof(state.ownedShipSkinIds) ~= "table" then
		state.ownedShipSkinIds = { DefaultTanker = true }
	end
	if state.ownedShipSkinIds[skinId] == true then
		return false, "OK_ALREADY_OWNED"
	end
	state.ownedShipSkinIds[skinId] = true
	self:_markDirty(userId)
	return true, "OK"
end

function OilStateService:SetShipSkinId(userId: number, skinId: string): (boolean, string)
	local state = self._statesByUserId[userId]
	if not state then
		return false, "ERR_NO_STATE"
	end
	if typeof(skinId) ~= "string" or not ShipSkinCatalog.Skins[skinId] then
		return false, "ERR_BAD_SKIN"
	end
	-- Robux-gating: refuse to equip skins the player hasn't unlocked. Without
	-- this check a malicious client could fire `RequestSetShipSkin` directly
	-- and bypass `MonetizationService` entirely. `OwnsShipSkin` treats the
	-- starter tanker as always-owned so the default flow is unaffected.
	if not self:OwnsShipSkin(userId, skinId) then
		return false, "ERR_NOT_OWNED"
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
	local plr = Players:GetPlayerByUserId(userId)
	local ftueFree = false
	if FtueConfig.Enabled and plr then
		local fs = plr:GetAttribute(Constants.FtueStepAttribute)
		local sub = plr:GetAttribute(Constants.FtueDocksUpgradeSubStepAttribute)
		if
			fs == FtueConfig.Step.WaitDocksUpgradeShip
			and sub == "CargoBuy"
			and (state :: any).ftueFreeCargoCapacityUpgradeUsed ~= true
		then
			ftueFree = true
		end
	end
	if not ftueFree then
	if not self:TrySpendCash(userId, cost) then
		return false, "ERR_NOT_ENOUGH_CASH", string.format("Need $%d to upgrade capacity.", cost)
		end
	else
		(state :: any).ftueFreeCargoCapacityUpgradeUsed = true
	end
	state.shipCapacityLevel = level + 1
	self:_markDirty(userId)
	if ftueFree and _ftueService and typeof((_ftueService :: any).OnFtueShipCapacityUpgradeSuccess) == "function" then
		(_ftueService :: any):OnFtueShipCapacityUpgradeSuccess(plr)
	end
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

--- Run-upgrade inventory ----------------------------------------------------
--- Generic stackable consumables that gameplay services consume on a
--- per-action basis (e.g. `SecurityPersonnelService` decrements on
--- shipment dispatch). Keyed by stable `itemId`. Mirrors
--- `equipmentOwnedByItemId` shape so persistence stays uniform.

function OilStateService:AddRunUpgradeOwned(userId: number, itemId: string, count: number)
	if typeof(itemId) ~= "string" or itemId == "" or count <= 0 then
		return
	end
	local state = self._statesByUserId[userId]
	if not state then
		return
	end
	state.runUpgradeOwnedByItemId[itemId] = (state.runUpgradeOwnedByItemId[itemId] or 0) + floorPositive(count)
	self:_markDirty(userId)
end

function OilStateService:GetRunUpgradeOwned(userId: number, itemId: string): number
	if typeof(itemId) ~= "string" or itemId == "" then
		return 0
	end
	local state = self._statesByUserId[userId]
	if not state then
		return 0
	end
	return state.runUpgradeOwnedByItemId[itemId] or 0
end

--- Decrement N stacks. Returns true when the full quantity was consumed,
--- false when the player did not own enough (state untouched on false).
--- Defaults to 1 when `count` is omitted.
function OilStateService:ConsumeRunUpgradeOwned(userId: number, itemId: string, count: number?): boolean
	if typeof(itemId) ~= "string" or itemId == "" then
		return false
	end
	local n = floorPositive(count or 1)
	if n <= 0 then
		return false
	end
	local state = self._statesByUserId[userId]
	if not state then
		return false
	end
	local cur = state.runUpgradeOwnedByItemId[itemId] or 0
	if cur < n then
		return false
	end
	local nxt = cur - n
	if nxt <= 0 then
		state.runUpgradeOwnedByItemId[itemId] = nil
	else
		state.runUpgradeOwnedByItemId[itemId] = nxt
	end
	self:_markDirty(userId)
	return true
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

--- FTUE drill tile: **adjacent to the auto-placed center pump** (T33 of the starting chunk).
--- Pumps now spawn automatically at section center, so the tutorial tile sits one cell next to
--- it (preferred direction = toward the `Lab Machine` if present, so the pipe path the player
--- sees from spawn flows naturally; falls back to the cell directly "below" the pump otherwise).
function OilStateService:GetFtueDrillTargetCellKeyForPlot(plot: Model, _state: any, _userId: number): string?
	local s = staticGridConstants()
	local startSectionRow = OilConfig.Chunks.StartingRow
	local startSectionCol = OilConfig.Chunks.StartingCol
	local pumpRow = (startSectionRow - 1) * s.subTilesPerSide + 3
	local pumpCol = (startSectionCol - 1) * s.subTilesPerSide + 3
	if not inBoundsCell(pumpRow, pumpCol) then
		return nil
	end

	local labModel = plot:FindFirstChild("Lab Machine")
	local nbrRow: number?, nbrCol: number? = nil, nil
	if labModel and labModel:IsA("Model") then
		local labPos = labModel:GetPivot().Position
		local pumpTile = findTilePartForCell(plot, pumpRow, pumpCol)
		if pumpTile then
			local dirToLab = Vector3.new(labPos.X - pumpTile.Position.X, 0, labPos.Z - pumpTile.Position.Z)
			if dirToLab.Magnitude > 0.001 then
				nbrRow, nbrCol = pickNeighborCellByDirection(plot, pumpRow, pumpCol, dirToLab)
			end
		end
	end
	if not nbrRow or not nbrCol then
		nbrRow, nbrCol = pumpRow + 1, pumpCol
	end
	if not inBoundsCell(nbrRow, nbrCol) then
		nbrRow, nbrCol = pumpRow - 1, pumpCol
		if not inBoundsCell(nbrRow, nbrCol) then
			return nil
		end
	end
	return cellKey(nbrRow, nbrCol)
end

--- Stamps `IsFtueTutorialTile=true` on the BasePart for the player's current FTUE
--- tutorial cell (read from `Constants.FtueRestrictDrillCellKeyAttribute`) and clears
--- the same attribute on every other tile of the player's plot. Idempotent. Used by
--- **`FtueService`** so the per-plot world beam (see `FtuePoiBeamConfig` `WaitReveal`
--- rule + `PlayerToPoiBeamBootstrap`) can find the tile reliably even after streaming
--- in late or after respawn.
---
--- Rejoin bulletproofing: on first call after a fresh server load (or after a player
--- rejoins while their plot is still being assembled by `PlotService` /
--- `ChunkOwnershipService`), the plot may not yet contain the section / tile BasePart
--- the marker has to land on. A naive "stamp once" returns silently in that case and
--- the highlight (`FtueTutorialTileHighlight`) and the WaitReveal world beam never
--- resolve. We therefore retry every 0.5 s for ~30 s. A per-user generation token
--- invalidates the prior retry loop the moment a *different* call comes in (e.g.
--- step advances and the marker is supposed to clear), so we never re-stamp a stale
--- cell on top of fresh state.
function OilStateService:SetFtueTutorialTileMarker(userId: number, enabled: boolean)
	local plr = Players:GetPlayerByUserId(userId)
	if not plr then return end
	-- Lazily-initialised per-user generation token map (this method is the only
	-- writer/reader of it, so initialising here is safe and avoids touching
	-- `OilStateService.new` / `Init`).
	self._ftueTileMarkerRetryGen = self._ftueTileMarkerRetryGen or {}
	-- Bump the per-user generation so any in-flight retry from a prior call exits.
	self._ftueTileMarkerRetryGen[userId] = (self._ftueTileMarkerRetryGen[userId] or 0) + 1
	local myGen = self._ftueTileMarkerRetryGen[userId]

	local function clearAllOnPlot(plot: Model)
		local ground = plot:FindFirstChild("PlotGround")
		if not (ground and ground:IsA("Model")) then return end
		for _, sect in ipairs(ground:GetChildren()) do
			if sect:IsA("Model") then
				for _, d in ipairs(sect:GetDescendants()) do
					if d:IsA("BasePart") and d:GetAttribute("IsFtueTutorialTile") == true then
						d:SetAttribute("IsFtueTutorialTile", nil)
					end
				end
			end
		end
	end

	--- Returns true once the desired stamping/clearing reached its terminal state
	--- (so the retry loop can exit). Returns false if we still need to wait for
	--- streaming/world build.
	local function attempt(): boolean
		if self._ftueTileMarkerRetryGen[userId] ~= myGen then
			return true -- a newer call superseded us; stop quietly
		end
		local plot = self._plotService and self._plotService:GetOwnedPlot(userId)
		if not plot then
			return false
		end
		clearAllOnPlot(plot)
		if not enabled then
			return true
		end
		local ck = readFtueCellAttribute(userId, Constants.FtueRestrictDrillCellKeyAttribute)
		if not ck then
			-- Player attribute not yet replicated/restored. Wait and retry.
			return false
		end
		local row, col = globalCellFromCellKeyString(ck)
		if not row or not col then
			-- Malformed cell key; nothing we can stamp. Don't keep retrying.
			return true
		end
		local part = findTilePartForCell(plot, row, col)
		if not part then
			-- Plot section / tile BasePart not built yet. Wait and retry.
			return false
		end
		part:SetAttribute("IsFtueTutorialTile", true)
		return true
	end

	if attempt() then
		return
	end
	task.spawn(function()
		for _ = 1, 60 do
			task.wait(0.5)
			local p = Players:GetPlayerByUserId(userId)
			if not p or not p.Parent then
				return
			end
			if attempt() then
				return
			end
		end
	end)
end

--- Used while `ftueStep == WaitDrillOil_WIP` to restore drill restriction attributes after join.
function OilStateService:IsFtueDrillTutorialCellDrilled(state: any, drillCk: string): boolean
	local rowStr, colStr = string.match(drillCk, "^R(%d+)C(%d+)$")
	local row = tonumber(rowStr)
	local col = tonumber(colStr)
	if not row or not col then
		return false
	end
	local sectionId = cellToSectionId(row, col)
	local localKey = globalCellToLocalTileKey(row, col)
	local chunk = state.chunksById and (state.chunksById :: any)[sectionId]
	if not chunk or not chunk.tiles then
		return false
	end
	local t = (chunk.tiles :: any)[localKey]
	return t ~= nil and t.drilled == true
end

return OilStateService
