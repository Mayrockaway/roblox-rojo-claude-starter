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
local BoatCatalog = require(Shared:WaitForChild("Config"):WaitForChild("BoatCatalog"))
local ShipStats = require(Shared:WaitForChild("Config"):WaitForChild("ShipStats"))
local ShipUpgradeConfig = require(Shared:WaitForChild("Config"):WaitForChild("ShipUpgradeConfig"))
local ShipProfileMigration = require(Shared:WaitForChild("Config"):WaitForChild("ShipProfileMigration"))
local OilTankConfig = require(Shared:WaitForChild("Config"):WaitForChild("OilTankConfig"))
local FtueConfig = require(Shared:WaitForChild("Config"):WaitForChild("FtueConfig"))
local SessionEconomicsConfig = require(Shared:WaitForChild("Config"):WaitForChild("SessionEconomicsConfig"))
local SessionEconomics = require(Shared:WaitForChild("Utils"):WaitForChild("SessionEconomics"))
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))
local DevLog = require(Shared:WaitForChild("DevLog"))
local Telemetry = require(Shared:WaitForChild("Telemetry"))

local OilStateService = {}

--- Set once from `init.server` after `FtueService` is required; used for placement → FTUE hooks.
local _ftueService: any = nil

local SAVE_INTERVAL_SECONDS = 25
--- PushState throttle: max one network push per this many seconds per player.
--- Calls within the window mark the userId pending; a flush loop drains them.
local PUSH_THROTTLE_SECONDS = 0.5
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
		--- Profile version. Bumped to **12** — adds `economicsSessions` for
		--- rolling net-cash/session-time windows that feed **dynamic Robux cash
		--- pack** sizing (`SessionEconomicsConfig` / `SessionEconomics`). v11
		--- history below still applies per field.
		---
		--- Earlier: **11** — Step 7 boat refactor: v11 retires legacy boat ids (`DefaultTanker`,
		--- `Ship3Skin`, `Ship4Skin`, `Ship5Skin`, `WhaleSkin`) in favor of
		--- the consolidated `Tier1Boat`..`Tier10Boat` cash chain plus
		--- `PirateShip` / `Ducky` / `Moby` Robux boats. The v10 → v11
		--- migration in `_applyPersistedIntoState` runs every persisted
		--- `equippedBoatId` and every key of `ownedBoatIds` /
		--- `ownedShipSkinIds` through `BoatCatalog.RemapLegacyBoatId`
		--- BEFORE any catalog gate so Robux purchases survive the rename.
		---
		--- Earlier history:
		---   * 9 → 10 (Step 6): `shipSkinId` → `equippedBoatId`,
		---     `ownedShipSkinIds` → `ownedBoatIds` field rename. Robux-only
		---     carry-forward from the legacy ownership map.
		---   * 8 → 9 (Step 4): deleted the `shipSpeedLevel` /
		---     `shipCapacityLevel` + `ftueDocksUpgradeSubStep` upgrade
		---     fields.
		---   * 7 → 8 (Step 3): data-driven starter set.
		--- v < 8 backfill still runs — see `_applyPersistedIntoState`.
		version = 12,
		cash = initialStartingCash(),
		ftueEscortShipmentRemaining = initialFtueEscortShipmentRemaining(),
		ftueDispatchCashGranted = false,
		ftueTutorialCompleteCashGranted = false,
		--- One-shot **boat-progression refund** flag (Step 7+). When the
		--- per-player speed/capacity upgrade ladder was retired (v8 → v9)
		--- in favor of stats baked per-boat in `BoatCatalog`, the
		--- `shipSpeedLevel` / `shipCapacityLevel` profile fields were
		--- silently dropped — players who had spent cash on those
		--- upgrades had no way to recover it. The v8 → v11 read shim in
		--- `_applyPersistedIntoState` now refunds the exact cumulative
		--- ladder cost (`ShipUpgradeConfig.GetTotalSpeedUpgradeCost` +
		--- `GetTotalCapacityUpgradeCost`) into `state.cash` for any
		--- profile that still carries the legacy fields, then flips this
		--- flag to `true` so the refund cannot be replayed on subsequent
		--- loads. Profiles whose legacy fields were already stripped by
		--- an earlier v9+ load **cannot** be retroactively refunded —
		--- the level data is gone — so this flag is also set to `true`
		--- on those reads to avoid leaving a permanently "pending" mark.
		legacyShipUpgradeRefunded = false,
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
		--- 7-day daily reward calendar (`StarterGui.Daily` modal driven by
		--- `DailyRewardCalendarService`). `dailyRewardClaimedCount` is the
		--- number of slots the player has already claimed (0..7); the next
		--- claimable slot is `dailyRewardClaimedCount + 1`.
		--- `dailyRewardLastClaimAt` is the `os.time()` of the most recent
		--- claim — `nil` for a brand-new player so Reward 1 is immediately
		--- available with no cooldown. Cooldown duration lives in
		--- `DailyRewardCalendarConfig.CooldownSeconds` (12h today). Streak
		--- break = resume: the timer keeps running while the player is
		--- offline so missed days unlock the next slot on next login (no
		--- reset-to-day-1 punishment).
		dailyRewardClaimedCount = 0,
		dailyRewardLastClaimAt = nil :: number?,
		--- Rolled boatId for the Slot 2 random-boat pool reward. Persisted
		--- so the panel can swap the slot's icon to the actual hull on every
		--- subsequent open (the receipt-of-what-you-rolled doubles as the
		--- "this is what you got" reveal — there is no separate popup UI).
		--- `nil` until the player claims slot 2.
		dailyRewardSlot2BoatId = nil :: string?,
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
		equippedBoatId = "Tier1Boat",
		--- Boats the player is allowed to equip via `SetEquippedBoatId`.
		--- Seeded data-drivenly from
		--- `BoatCatalog.GetStarterBoatIds()` (Step 3 of the boat-
		--- progression refactor) so adding a second starter / changing
		--- the starter id in the catalog requires no service edit. Cash
		--- unlocks land via `OilStateService:TryUnlockBoat`; Robux
		--- unlocks land via `MonetizationService` `ProcessReceipt` →
		--- `GrantBoat`. Stored as `[boatId] = true` so JSON
		--- round-trip is order-stable.
		ownedBoatIds = BoatCatalog.GetStarterBoatIds(),
		ftueStep = if FtueConfig.Enabled then FtueConfig.Step.WaitDrillOil_WIP else nil,
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
		--- Persisted per-profile set of `MonetizationCatalog` item ids that
		--- were marketed as `oneTimePurchase = true` (e.g. the Featured
		--- "Starter Pack" bundle) and have already been bought. Drives:
		---   * `MonetizationService:_handlePromptRequest` — server-side
		---     gate that rejects re-purchase clicks with `ERR_ALREADY_PURCHASED`
		---     before opening the Roblox prompt.
		---   * `MonetizationService:_processReceipt` — defensive replay
		---     guard that marks the receipt granted but skips the bundle so
		---     a stale Roblox re-deliver can't re-grant the cash + drills.
		---   * `RobuxShopPanel` — hides the entire Featured row from the
		---     snapshot once the buyer's flag is set.
		--- Set semantics: keys are stable item ids, values are always `true`
		--- (we never store `false`; absence == not purchased). Legacy saves
		--- without the field load as `{}`.
		purchasedOneTimeItemIds = {} :: { [string]: boolean },
		-- `ftueDocksUpgradeSubStep` was deleted by Step 4 of the boat-
		-- progression refactor along with the `WaitDocksUpgradeShip`
		-- FTUE leg + the speed/capacity upgrade ladder. Pre-Step-4
		-- payloads carrying that field are silently ignored on load.
		--- Persisted **rejoin / death-respawn anchor** while the player is mid-FTUE.
		--- Captured (a) ~1s after every `_setStep` transition (post-step-driven
		--- teleports settle), and (b) on `PlayerRemoving` right before the profile
		--- flushes — so a disconnect-mid-leg or in-session death drops the player
		--- back where they were instead of the `ClaimPad`. Cleared the moment the
		--- FTUE reaches `Done` (or is otherwise nil) so post-FTUE rejoins go to
		--- `ClaimPad` as before. Stored as raw position + Y-axis yaw (radians)
		--- + the player's `PlotId` at capture time. Pitch / roll are
		--- intentionally dropped to avoid spawning the character ragdolled.
		--- `plotId` is used by `GetFtueLastSpawnCFrame` to **reject** restores
		--- that don't match the player's currently assigned plot — without this
		--- check the player would be teleported into the previous plot's world
		--- coordinates, which on rejoin is frequently another player's plot.
		--- See `OilStateService:SetFtueLastSpawn` / `:GetFtueLastSpawnCFrame`
		--- for read/write, and `FtueService` for the step-change capture +
		--- character-spawn restore wiring.
		ftueLastSpawn = nil :: { x: number, y: number, z: number, yaw: number, plotId: number? }?,
		--- Completed session economics snapshots (organic net ≠ Robux-direct cash).
		--- See `OilStateService:_finalizeEconomicsSessionOnDrop`,
		--- `_:NotifyEconomicsRobuxDirectCashGrant`, `:GetDynamicCurrencyPackGrant`.
		economicsSessions = {} :: { { netOrganic: number, sessionSeconds: number, endedAt: number } },
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
	self._equippedBoatChangedHandler = nil :: ((number, string) -> ())?
	self._stateReadyForTimersCallback = nil :: ((number, { any }) -> ())?
		self._dataStore = nil
	self._devSkipSaveOnNextDrop = {} :: { [number]: boolean }
	--- PushState throttle: at most one push per PUSH_THROTTLE_SECONDS per player.
	--- Calls within the throttle window mark the userId pending; a periodic flush
	--- loop in Start() drains the pending set.
	self._lastPushClockByUserId = {} :: { [number]: number }
	self._pendingPushByUserId = {} :: { [number]: boolean }
	--- Set by `init.server` after `MonetizationService` is required. Used by
	--- `AddCash` to apply the **DoubleEarnings** GamePass multiplier to every
	--- gameplay cash credit. Refunds and direct Robux currency packs opt out
	--- via the `skipMultiplier = true` option so the player isn't getting back
	--- 2x what they paid (refund) or doubling a cash pack the price was set
	--- against (Robux currency grant).
	self._monetizationService = nil :: any
	--- Set by `init.server` after `LeaderboardService` is constructed. Optional
	--- — `AddCash` notifies it for **gameplay** credits only (`skipMultiplier` false)
	--- so the docks board can track session + global “lifetime cash earned”
	--- without counting refunds or Robux currency grants.
	self._leaderboardService = nil :: any
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

--- Set by `init.server` after `GlobalEventService` is constructed. Optional
--- — without it `AddCash` skips the global event multiplier (effectively
--- the same as every caller passing `{ skipMultiplier = true }`). The
--- multiplier composes **after** the per-player `DoubleEarnings` GamePass:
--- a player who owns the GamePass during a `cash_frenzy` event receives
--- `amount × 2 (GamePass) × 2 (Frenzy) = ×4`. Refunds and Robux currency
--- packs continue to opt out via `AddCash(uid, n, { skipMultiplier =
--- true })` — same `skipMultiplier` flag covers both stack layers so we
--- don't have to thread a second opt-out flag through every caller.
function OilStateService:SetGlobalEventService(globalEventService: any)
	self._globalEventService = globalEventService
end

--- Set by `init.server` after `LeaderboardService` is constructed. Optional.
function OilStateService:SetLeaderboardService(leaderboardService: any)
	self._leaderboardService = leaderboardService
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
	-- `ftueDocksUpgradeSubStep` cleanup removed by Step 4 (the leg + the
	-- field are gone — see `WaitDocksUpgradeShip` notes above).
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
function OilStateService:SetFtueLastSpawn(userId: number, cframe: CFrame?, plotId: number?)
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
		plotId = if typeof(plotId) == "number" and plotId > 0 then plotId else nil,
	}
	self:_markDirty(userId)
end

--- Returns the persisted FTUE rejoin CFrame (position + yaw only) or nil if
--- the player has no anchor or is no longer mid-FTUE. Consumers
--- (`PlotService` / `FtueService`) use this to override the default ClaimPad
--- teleport on the first character spawn after rejoin and on in-session FTUE
--- death-respawns.
---
--- `currentPlotId` (optional) — when provided, the snapshot is rejected
--- (returns `nil`) if the saved snapshot was captured on a **different** plot.
--- This prevents the rejoin restore from teleporting the player into world
--- coordinates that now belong to another player's plot (the saved snapshot
--- is in absolute world space, not plot-relative). Snapshots written before
--- the `plotId` field existed (legacy) are accepted unconditionally.
function OilStateService:GetFtueLastSpawnCFrame(userId: number, currentPlotId: number?): CFrame?
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
	if typeof(currentPlotId) == "number" and currentPlotId > 0 then
		local snapPlotId = (snap :: any).plotId
		if typeof(snapPlotId) == "number" and snapPlotId > 0 and snapPlotId ~= currentPlotId then
			return nil
		end
	end
	return CFrame.new(snap.x, snap.y, snap.z) * CFrame.fromEulerAnglesYXZ(0, snap.yaw, 0)
end

--- Look up the player by `userId`, read their HumanoidRootPart `CFrame` +
--- assigned `PlotId` attribute, and persist them as the FTUE rejoin anchor.
--- No-op (and does **not** clear the existing anchor) when the character /
--- HRP isn't available — that way a mid-respawn `PlayerRemoving` falls back
--- to the previous step-change snapshot rather than wiping it. Captures the
--- player's current `PlotId` so `GetFtueLastSpawnCFrame` can reject restores
--- that would land the player on someone else's plot after a re-assignment.
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
	local plotIdAttr = player:GetAttribute("PlotId")
	local plotId: number? = if typeof(plotIdAttr) == "number" and plotIdAttr > 0 then plotIdAttr else nil
	self:SetFtueLastSpawn(userId, hrp.CFrame, plotId)
end

-- `SetFtueDocksUpgradeSubStep` was deleted by Step 4 of the boat-
-- progression refactor along with the entire `WaitDocksUpgradeShip`
-- FTUE leg.

--- Daily Free Drill claim-cycle accessors. The value is the UTC cycle-start
--- timestamp the player has already claimed in (see
--- `DailyDrillConfig.GetCurrentCycleStart`). `EquipmentShopService` uses this
--- to gate `_handleClaimDailyDrill` + to rehydrate the in-memory claim map
--- when a player joins. Scope today is **per-session in-memory** (not
--- persisted to the DataStore profile); a cross-session persistence pass
--- can land later by routing through `_applyPersistedIntoState` /
--- `_buildPersistedFromState` like the other profile fields.
function OilStateService:SetDailyDrillClaimCycle(userId: number, cycleStart: number)
	local state = self:GetState(userId)
	if state then
		(state :: any).dailyDrillClaimCycle = cycleStart
		self:_markDirty(userId)
	end
end

function OilStateService:GetDailyDrillClaimCycle(userId: number): number?
	local state = self:GetState(userId)
	if not state then
		return nil
	end
	local v = (state :: any).dailyDrillClaimCycle
	if typeof(v) == "number" then
		return v
	end
	return nil
end

--- 7-day daily reward calendar accessors.
--- `claimedCount` ranges 0..`DailyRewardCalendarConfig.TotalRewards`.
--- `lastClaimAt` is `os.time()` of the most recent claim, or `nil` for a
--- brand-new player (so Reward 1 is immediately available, no cooldown).
--- Both fields persist across sessions via `_applyPersistedIntoState` /
--- `_flushStateIntoPersisted`.
function OilStateService:GetDailyRewardProgress(userId: number): (number, number?)
	local state = self:GetState(userId)
	if not state then
		return 0, nil
	end
	local count = (state :: any).dailyRewardClaimedCount
	local lastAt = (state :: any).dailyRewardLastClaimAt
	local countNum = if typeof(count) == "number" and count >= 0 then math.floor(count) else 0
	local lastAtNum: number? = if typeof(lastAt) == "number" and lastAt > 0 then lastAt else nil
	return countNum, lastAtNum
end

--- Set both fields atomically. The service calls this on a successful
--- claim with `(prev + 1, os.time())`. The wrapper marks the state dirty
--- so the next persistence flush includes the update.
function OilStateService:SetDailyRewardProgress(userId: number, claimedCount: number, lastClaimAt: number?)
	local state = self:GetState(userId)
	if not state then
		return
	end
	(state :: any).dailyRewardClaimedCount = math.max(0, math.floor(claimedCount))
	if typeof(lastClaimAt) == "number" and lastClaimAt > 0 then
		(state :: any).dailyRewardLastClaimAt = lastClaimAt
	else
		(state :: any).dailyRewardLastClaimAt = nil
	end
	self:_markDirty(userId)
end

--- Slot 2 random-boat reward: the rolled boatId persists so the panel can
--- swap the slot's icon to the actual hull on every subsequent open. The
--- service calls `Set` once on a successful slot-2 claim; `Get` is read by
--- `_pushState` to include the icon in the snapshot. Both no-op cleanly
--- if the player profile hasn't loaded yet.
function OilStateService:GetDailyRewardSlot2BoatId(userId: number): string?
	local state = self:GetState(userId)
	if not state then
		return nil
	end
	local v = (state :: any).dailyRewardSlot2BoatId
	if typeof(v) == "string" and v ~= "" then
		return v
	end
	return nil
end

function OilStateService:SetDailyRewardSlot2BoatId(userId: number, boatId: string?)
	local state = self:GetState(userId)
	if not state then
		return
	end
	if typeof(boatId) == "string" and boatId ~= "" then
		(state :: any).dailyRewardSlot2BoatId = boatId
	else
		(state :: any).dailyRewardSlot2BoatId = nil
	end
	self:_markDirty(userId)
end

--- Mobile drill hint persistence: mark as dismissed so it never shows again.
function OilStateService:SetMobileDrillHintDismissed(userId: number)
	local state = self:GetState(userId)
	if state then
		(state :: any).mobileDrillHintDismissed = true
		self:_markDirty(userId)
	end
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

	--- Hand `PlotService` a back-reference to us so its `CharacterAdded`
	--- teleport (`_teleportCharacterToOwnedPlot`) can read the persisted
	--- FTUE rejoin snapshot (`ftueLastSpawn`) and target it directly,
	--- instead of teleporting to the ClaimPad and racing with the drift
	--- defense loop when `FtueService:_onCharacterSpawnedDuringFtue`
	--- tries to follow up with the FTUE-specific destination.
	if self._plotService and typeof((self._plotService :: any).SetOilStateService) == "function" then
		(self._plotService :: any):SetOilStateService(self)
	end

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
		self._lastPushClockByUserId[player.UserId] = nil
		self._pendingPushByUserId[player.UserId] = nil
	end))

	self._autosaveThread = task.spawn(function()
		task.wait(3)
		while self._running do
			task.wait(SAVE_INTERVAL_SECONDS)
			self:_flushDirtyUsers()
		end
	end)

	-- PushState throttle flush: drain pending pushes that were deferred.
	self._pushThrottleThread = task.spawn(function()
		while self._running do
			task.wait(PUSH_THROTTLE_SECONDS)
			for pendingUserId, _ in pairs(self._pendingPushByUserId) do
				self._pendingPushByUserId[pendingUserId] = nil
				self._lastPushClockByUserId[pendingUserId] = os.clock()
				self:_doPushState(pendingUserId)
			end
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
		-- `shipSpeedLevel` / `shipCapacityLevel` snapshot fields were
		-- removed by Step 4 of the boat-progression refactor — speed and
		-- capacity are baked per-boat in `BoatCatalog`. Clients that
		-- need the equipped boat's level should look it up via
		-- `ShipStats.LevelsForBoat(snap.equippedBoatId)`.
		equippedBoatId = (typeof(state.equippedBoatId) == "string" and state.equippedBoatId) or "Tier1Boat",
		--- Sent on every snapshot + push so `FleetPanel` (the boat picker /
		--- buy / equip modal) can render the locked / owned / equipped
		--- state without invoking a separate snapshot RemoteFn. Keys are
		--- boat ids, values are always `true`. Unknown ids are filtered
		--- defensively (catalog rename safety).
		ownedBoatIds = (function()
			-- Boat progression refactor (Step 3): seed the wire snapshot
			-- from the data-driven starter set and filter persisted
			-- entries through `IsBoatPurchasable` so placeholder
			-- (`Tier*Boat`) ids never leak to the client even if a
			-- tampered profile somehow contained one.
			local out: { [string]: boolean } = BoatCatalog.GetStarterBoatIds()
			if typeof(state.ownedBoatIds) == "table" then
				for boatId, owned in pairs(state.ownedBoatIds) do
					if
						typeof(boatId) == "string"
						and boatId ~= ""
						and owned == true
						and BoatCatalog.IsBoatPurchasable(boatId)
					then
						out[boatId] = true
					end
				end
			end
			return out
		end)(),
		resolvedBoat = (function()
			-- Boat progression refactor (Step 2/4): `resolvedBoat` is the
			-- snapshot field clients render as the player's authoritative
			-- ship stats (cargo, voyage seconds, dispatch fee). Stats are
			-- baked per-boat in `BoatCatalog` (Step 4 deleted the
			-- legacy per-player `shipSpeedLevel` / `shipCapacityLevel`
			-- profile fields and the per-player upgrade ladder).
			local boatId = (typeof(state.equippedBoatId) == "string" and BoatCatalog.Boats[state.equippedBoatId] and state.equippedBoatId)
				or "Tier1Boat"
			local rs = ShipStats.ResolveForBoat(boatId)
			return {
				capacity = rs.capacity,
				dispatchFee = rs.dispatchFee,
				travelSeconds = rs.travelSeconds,
				eventRisk = rs.eventRisk,
			}
		end)(),
		-- `upgradeShipSpeedCost` / `upgradeShipCapacityCost` snapshot
		-- fields were removed by Step 4 of the boat-progression refactor
		-- alongside the `RequestUpgradeShip*` remotes. Per-boat unlock
		-- costs live on `BoatCatalog.Boats[boatId].unlock.cashCost`
		-- and are surfaced via the `RequestUnlockBoat` flow.
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
		--- Per-profile one-time-purchase set (e.g. Featured Starter Pack).
		--- Drives `RobuxShopPanel`'s decision to hide the entire Featured
		--- row once the buyer's flag is set; without this snapshot field
		--- the client would have to round-trip the server on every open
		--- to know whether to render the card. Filtered down to plain
		--- `{ [itemId] = true }` entries so the wire payload stays minimal.
		purchasedOneTimeItemIds = (function()
			local out: { [string]: boolean } = {}
			local src = (state :: any).purchasedOneTimeItemIds
			if typeof(src) == "table" then
				for k, v in pairs(src) do
					if typeof(k) == "string" and v == true then
						out[k] = true
					end
				end
			end
			return out
		end)(),
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
		-- Oil Heaven / rebirth
		oilHeavenUnlocked = state.oilHeavenUnlocked == true,
		rebirthCount = if typeof(state.rebirthCount) == "number" then state.rebirthCount else 0,
	}
end

function OilStateService:PushState(userId: number)
	local now = os.clock()
	local last = self._lastPushClockByUserId[userId] or 0
	if now - last < PUSH_THROTTLE_SECONDS then
		-- Within throttle window — mark pending for the flush loop.
		self._pendingPushByUserId[userId] = true
		return
	end
	self._lastPushClockByUserId[userId] = now
	self._pendingPushByUserId[userId] = nil
	self:_doPushState(userId)
end

--- Internal: builds snapshot, fires BindableEvent + RemoteEvent. Called by
--- `PushState` (when allowed) and by the periodic throttle flush loop.
function OilStateService:_doPushState(userId: number)
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
	-- Stack server-wide global event cash multiplier (`cash_frenzy`, …)
	-- AFTER the GamePass so the two compose multiplicatively. We swallow
	-- errors the same way as the GamePass call: a transient `GlobalEvent`
	-- service hiccup must never block a gameplay credit.
	if not skipMultiplier and self._globalEventService then
		local okM, mul = pcall(function()
			return self._globalEventService:GetMultiplier("Cash")
		end)
		if okM and typeof(mul) == "number" and mul > 0 and mul ~= 1 then
			value = math.floor(value * mul + 0.5)
		end
	end
	state.cash += value
	self:_markDirty(userId)
	if not skipMultiplier then
		local lb = self._leaderboardService
		if lb and typeof((lb :: any).OnCashEarned) == "function" then
			(lb :: any):OnCashEarned(userId, value)
		end
	end
	return true, value
end

--- Read the player's current cash balance. Returns `0` if no oil state is
--- loaded for the user (e.g. pre-`Init`, mid-bootstrap, or after Stop).
--- Used by `Shared.Telemetry`'s wallet reader to populate the
--- `endingBalance` argument of `LogEconomyEvent` — wire-up happens in
--- `src/server/init.server.luau` once `OilStateService:Init` returns.
function OilStateService:GetCash(userId: number): number
	local state = self._statesByUserId[userId]
	if not state then
		return 0
	end
	return state.cash or 0
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

	-- Telemetry §6.4 `chunk_unlocked` (Sink). Fires after `TrySpendCash`
	-- + `chunk.unlocked = true`. SPEC §7 names this in `ChunkOwnershipService`
	-- but the actual ownership flip lives here in `OilStateService:TryBuyChunk`
	-- (server-authoritative path); `ChunkOwnershipService` only renders the
	-- buy signs and routes the click into `TryBuyChunk` via `PlotResourceService`.
	pcall(function()
		local plr = Players:GetPlayerByUserId(userId)
		Telemetry.Economy(plr, "Sink", cost, "cash", "chunk", { kind = "chunk", id = chunkId })
		Telemetry.Track(plr, "chunk_unlocked", {
			chunkId = chunkId,
			cost = cost,
		})
	end)

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

	-- Redrill path (T4+ with `canRedrill = true`): if the tile has already
	-- been drilled, allow placement only when the tier supports redrill AND
	-- the tile is not the chunk's permanent center pump. The tile's
	-- production state is wiped here so the standard `_completeDrill` →
	-- shovel → reveal flow re-rolls a fresh vein against
	-- `GroundRarityWeights[chunk.groundType]` (with optional T6 bias from
	-- `tierCfg.rerollWeightBias`). Production naturally stops the next tick
	-- because `OilProductionService` / `OilVisualService` gate on
	-- `tile.drilled` + `tile.veinTypeId` + `tile.visualsStartedAt`. The
	-- shovel model (if any) gets cleaned up client-side via the
	-- `kind="redrilled"` `DrillProgressUpdate` fired by `DrillingService`.
	-- See chat 2026-04 "T4-T6 reroll capability".
	local tile = chunk.tiles and chunk.tiles[tileKey]
	local isRedrill = false
	if tile and tile.drilled then
		if tile.hasCenterPump == true then
			return false, "ERR_CENTER_PUMP", "The center pump is permanent — it can't be re-drilled.", nil
		end
		-- Shovel reveal stage: the tile has been drilled but the player has
		-- not yet used the shovel on the `DrillComplete` model. Block ALL
		-- placements (including T4+ `canRedrill`) so the player has to
		-- shovel before this tile becomes available again — otherwise the
		-- pending shovel reveal model gets orphaned and the player can
		-- "skip" the shovel mechanic by stomping a fresh drill on top.
		-- `PlacementClient.isPlacementValid` mirrors this rule so the
		-- preview ghost goes red; this server check is the authoritative
		-- gate against stale client state.
		if tile.revealPending then
			return false, "ERR_TILE_AWAITING_SHOVEL", "Shovel this drill open before placing another here.", nil
		end
		if tierCfg.canRedrill ~= true then
			return false, "ERR_ALREADY_DRILLED", "This tile has already been drilled. Use a T4+ drill to re-drill it.", nil
		end
		isRedrill = true
		tile.drilled = nil
		tile.revealPending = nil
		tile.revealedAt = nil
		tile.visualsStartedAt = nil
		tile.veinTypeId = nil
		tile.veinResult = nil
		tile.hasOil = nil
		tile.oilType = nil
		tile.drillPosition = nil
	end

	local ck = cellKey(cellR, cellC)
	local ftueDrillCell = readFtueCellAttribute(userId, Constants.FtueRestrictDrillCellKeyAttribute)
	if ftueDrillCell and ftueDrillCell ~= ck then
		return false, "ERR_FTUE_WRONG_TILE", FtueConfig.WrongTileDrill, nil
	end
	-- Chunk-level FTUE restriction (WaitDrillOil_WIP): any tile in the starter chunk is valid.
	local ftueChunkId = readFtueCellAttribute(userId, Constants.FtueRestrictDrillChunkIdAttribute)
	if ftueChunkId and ftueChunkId ~= "" then
		if payload.chunkId ~= ftueChunkId then
			return false, "ERR_FTUE_WRONG_TILE", FtueConfig.WrongTileDrill, nil
		end
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
		and typeof(ftueStep) == "string"
		and ftueStep == FtueConfig.Step.WaitDrillOil_WIP
		and (
			(ftueDrillCell ~= nil and ftueDrillCell == ck)
			or (ftueChunkId ~= nil and ftueChunkId ~= "")
		)
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
		--- True when this placement re-drilled an already-drilled tile (T4+
		--- with `canRedrill = true`). `DrillingService` uses this to fire a
		--- `kind="redrilled"` cleanup so the previous shovel model + production
		--- visuals despawn before the new drill animation starts.
		isRedrill = isRedrill,
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
	-- Per-tier rarity bias (e.g. T6's halved Unlucky + ×1.5 Epic+). Bias is
	-- looked up by `entry.tier` rather than stored on the entry so config
	-- changes take effect even for drills placed before the change. Applies
	-- to every roll for that tier — first drill or reroll alike. Nil for
	-- T1-T5 → standard `GroundRarityWeights` apply unchanged.
	local rollTierCfg = entry.tier and OilConfig.DrillTiers[entry.tier]
	local rolledType = VeinCrateConfig.RollVeinType(groundTypeName, rng, rollTierCfg and rollTierCfg.rerollWeightBias or nil)

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
	-- Telemetry §6.4 `oil_tank_upgraded` (Sink). Fires after successful
	-- spend + tier increment. `item_type` encodes the oil tier so
	-- analytics can split by which tank players upgrade most.
	pcall(function()
		local plr = Players:GetPlayerByUserId(userId)
		Telemetry.Economy(plr, "Sink", cost, "cash", "oil_tank_upgrade:" .. oilType, { kind = "oil_tank_upgrade", id = oilType })
		Telemetry.Track(plr, "oil_tank_upgraded", {
			oilType = oilType,
			tierFrom = currentTier,
			tierTo = currentTier + 1,
			cost = cost,
		})
	end)
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
		self:_economicsBeginSessionTracking(existing)
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
		--- See `buildDefaultPersisted` — runtime mirror of the one-shot
		--- legacy ship-upgrade cash refund flag. Flips to `true` after
		--- `_applyPersistedIntoState` processes a profile that still
		--- carried the v8 `shipSpeedLevel` / `shipCapacityLevel` fields
		--- (or that arrived already stripped — see the field doc on the
		--- persisted side for why both cases mark refunded).
		legacyShipUpgradeRefunded = false,
		--- See `buildDefaultPersisted` — runtime mirror of the one-shot free dock equipment shop drill flag.
		ftueFreeDocksDrillUsed = false,
		--- See `buildDefaultPersisted` — runtime mirror of the one-shot exact-Rare FTUE first-reveal flag.
		ftueFirstRevealApplied = false,
		--- See `buildDefaultPersisted` — runtime mirror of the one-shot fast first-barrel grant.
		ftueFirstBarrelGranted = false,
		--- See `buildDefaultPersisted` — runtime mirror of the daily reward calendar progress.
		dailyRewardClaimedCount = 0,
		dailyRewardLastClaimAt = nil :: number?,
		dailyRewardSlot2BoatId = nil :: string?,
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
		equippedBoatId = "Tier1Boat",
		--- See `buildDefaultPersisted` — same field, runtime side.
		--- Seeded from `BoatCatalog.GetStarterBoatIds()` (Step 3 of
		--- the boat-progression refactor); `_applyPersistedIntoState`
		--- overlays saved entries + re-runs the starter backfill so
		--- legacy v<8 profiles converge to the data-driven starter set.
		--- `OilStateService:GrantBoat` (Robux receipts) and
		--- `:TryUnlockBoat` (cash unlocks) mutate this set at runtime.
		ownedBoatIds = BoatCatalog.GetStarterBoatIds() :: { [string]: boolean },
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
		ftueStep = if FtueConfig.Enabled then FtueConfig.Step.WaitDrillOil_WIP else nil,
		ftueCompleted = not FtueConfig.Enabled,
		ftueDoneScreenAcknowledged = false,
		--- See `buildDefaultPersisted` — runtime mirror of the Robux-shop
		--- post-login auto-open suppression flag. Flips on the first
		--- successful Robux purchase (see `MarkRobuxShopAutoOpenDismissed`).
		robuxShopAutoOpenDismissed = false,
		--- See `buildDefaultPersisted` — runtime mirror of the per-profile
		--- one-time-purchase set. Empty for fresh / legacy profiles. Stays
		--- in lockstep with the persisted column via
		--- `_applyPersistedIntoState` / `_buildPersistedFromState`.
		purchasedOneTimeItemIds = {} :: { [string]: boolean },
		--- Oil Heaven (rebirth sky-island). Unlocked after the player's
		--- first rebirth; `rebirthCount` tracks how many rebirths total.
		oilHeavenUnlocked = false,
		rebirthCount = 0,
		oilHeavenState = {} :: { [string]: any },
		-- `ftueDocksUpgradeSubStep` runtime mirror was deleted by Step 4
		-- of the boat-progression refactor along with the upgrade leg.
		--- See `buildDefaultPersisted` — runtime mirror of the persisted FTUE rejoin
		--- anchor. Read by `PlotService` / `FtueService` to override the default
		--- ClaimPad teleport on the **first** character spawn after rejoin and on
		--- in-session FTUE death-respawns.
		ftueLastSpawn = nil :: { x: number, y: number, z: number, yaw: number, plotId: number? }?,
		economicsSessions = {} :: { { netOrganic: number, sessionSeconds: number, endedAt: number } },
		economicsSessionJoinWallTime = nil :: number?,
		economicsSessionBaselineCash = nil :: number?,
		economicsExcludedRobuxCashThisSession = 0,
	}

	local persisted = self:_loadPersistedProfile(userId)
	if persisted then
		self:_applyPersistedIntoState(state, persisted, plot)
	else
		-- Telemetry §6.1 `first_join` — brand-new player (no persisted
		-- profile in DataStore yet). `oilProfileVersionAtCreate` is the
		-- current `_serializeState` version so we can backfill profile
		-- migrations against this row later.
		pcall(function()
			local plr = Players:GetPlayerByUserId(userId)
			Telemetry.Track(plr, "first_join", {
				oilProfileVersionAtCreate = 12,
			})
		end)
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
	self:_economicsBeginSessionTracking(state)
	self:_invokeStateTimersReady(userId)

	-- Replicate Oil Heaven attributes to the Player so client UI can react.
	do
		local plr = Players:GetPlayerByUserId(userId)
		if plr then
			plr:SetAttribute(Constants.OilHeavenUnlockedAttribute, state.oilHeavenUnlocked == true)
			plr:SetAttribute(Constants.CurrentWorldAttribute, Constants.WorldMain)
			plr:SetAttribute(Constants.RebirthCountAttribute, state.rebirthCount or 0)
		end
	end

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

	-- ─── Legacy ship-upgrade cash refund (boat-progression Step 7+) ────
	-- Step 4 of the boat-progression refactor (v8 → v9) deleted the
	-- per-player `shipSpeedLevel` / `shipCapacityLevel` fields and the
	-- speed/capacity upgrade ladder, in favor of stats baked per-boat in
	-- `BoatCatalog`. That deletion stripped the level fields from saves
	-- without refunding the cash players had spent on those upgrades.
	--
	-- This block runs **once per profile** and refunds the exact
	-- cumulative cost from the surviving level fields:
	--
	--   refund = ShipUpgradeConfig.GetTotalSpeedUpgradeCost(L_speed)
	--          + ShipUpgradeConfig.GetTotalCapacityUpgradeCost(L_cap)
	--
	-- where `GetTotal*` sums the published upgrade costs from L1 → L
	-- (a level-1 ship paid nothing; level 10 paid every step's price).
	-- Profiles that no longer carry the legacy fields (because they
	-- already loaded post-Step-4 and saved without them) cannot be
	-- retroactively reconstructed — the level data is gone — so they
	-- silently flip the flag without granting any cash. The flag
	-- `legacyShipUpgradeRefunded` persists via `_serializeState` so the
	-- refund cannot be replayed even if a future bug somehow
	-- re-introduced the legacy fields into the persisted blob.
	local pAny = persisted :: any
	if pAny.legacyShipUpgradeRefunded == true then
		(state :: any).legacyShipUpgradeRefunded = true
	else
		local rawSpeed = pAny.shipSpeedLevel
		local rawCap = pAny.shipCapacityLevel
		local refund = 0
		if typeof(rawSpeed) == "number" then
			refund += ShipUpgradeConfig.GetTotalSpeedUpgradeCost(rawSpeed)
		end
		if typeof(rawCap) == "number" then
			refund += ShipUpgradeConfig.GetTotalCapacityUpgradeCost(rawCap)
		end
		if refund > 0 then
			state.cash = floorPositive((state.cash or 0) + refund)
			DevLog.log(string.format(
				"[boat-refund] userId=%d refunded $%d (speedLevel=%s capacityLevel=%s) from legacy upgrade ladder",
				tonumber(state.ownerUserId) or -1,
				refund,
				tostring(rawSpeed),
				tostring(rawCap)
			))
		end
		(state :: any).legacyShipUpgradeRefunded = true
		-- Always queue a save after the one-shot branch: we flip
		-- `legacyShipUpgradeRefunded` in RAM even when `refund == 0` (L1/L1
		-- legacy fields — no cash to return, but we must persist the flag
		-- so the migration never re-runs). Without `_markDirty`, a player
		-- could get `refund > 0` in-session but lose it on crash if no
		-- other action marked the profile dirty before the next flush.
		self:_markDirty(state.ownerUserId)
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
	-- `ftueFreeCargoCapacityUpgradeUsed` was deleted by Step 4 of the
	-- boat-progression refactor (the free first cargo upgrade leg is
	-- gone). Pre-Step-4 payloads still carrying the field are silently
	-- ignored on load.
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

	--- Daily reward calendar (`DailyRewardCalendarService`). Legacy profiles
	--- without these keys default to (0, nil) — same as a brand-new player,
	--- so the very first open reveals Reward 1 ready to claim.
	local pDrcc = (persisted :: any).dailyRewardClaimedCount
	if typeof(pDrcc) == "number" and pDrcc >= 0 then
		(state :: any).dailyRewardClaimedCount = math.floor(pDrcc)
	else
		(state :: any).dailyRewardClaimedCount = 0
	end
	local pDrlca = (persisted :: any).dailyRewardLastClaimAt
	if typeof(pDrlca) == "number" and pDrlca > 0 then
		(state :: any).dailyRewardLastClaimAt = pDrlca
	else
		(state :: any).dailyRewardLastClaimAt = nil
	end
	local pDrs2bid = (persisted :: any).dailyRewardSlot2BoatId
	if typeof(pDrs2bid) == "string" and pDrs2bid ~= "" then
		(state :: any).dailyRewardSlot2BoatId = pDrs2bid
	else
		(state :: any).dailyRewardSlot2BoatId = nil
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
			state.ftueStep = FtueConfig.Step.WaitDrillOil_WIP
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
		state.ftueStep = FtueConfig.Step.WaitDrillOil_WIP
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

	-- One-time-purchase set (e.g. Featured Starter Pack). Same legacy-save
	-- handling as `robuxShopAutoOpenDismissed` above: missing key == empty
	-- set, so existing profiles can still buy any one-time SKU on next login.
	-- Only string keys with `true` values survive — defensive against a hand-
	-- edited DataStore row leaking other types in.
	do
		local rawAny = (pFtue :: any).purchasedOneTimeItemIds
		local out: { [string]: boolean } = {}
		if typeof(rawAny) == "table" then
			for k, v in pairs(rawAny) do
				if typeof(k) == "string" and k ~= "" and v == true then
					out[k] = true
				end
			end
		end
		(state :: any).purchasedOneTimeItemIds = out
	end

	-- `ftueDocksUpgradeSubStep` restore was deleted by Step 4 of the
	-- boat-progression refactor — the entire `WaitDocksUpgradeShip` leg
	-- is gone (TODO Step 6/7 may re-introduce a boat-inventory FTUE leg
	-- that pairs with the new boat unlock + equip flow).

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
				plotId = if typeof((snap :: any).plotId) == "number" and (snap :: any).plotId > 0 then (snap :: any).plotId else nil,
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

	-- Player ship / boat: migrate the equipped boat id across all known
	-- profile schema versions. The persisted `shipSpeedLevel` /
	-- `shipCapacityLevel` fields were deleted by Step 4 of the boat-
	-- progression refactor — per-boat speed/capacity now live in
	-- `BoatCatalog.Boats[id]` (`speedLevel` / `capacityLevel`). Old
	-- payloads that still carry those fields are silently discarded;
	-- the boat catalog is the only source of truth for stats now.
	--
	-- ─── v10 → v11 migration (Step 7) ──────────────────────────────────
	-- v11 retires the legacy boat ids (`DefaultTanker`, `Ship3Skin`,
	-- `Ship4Skin`, `Ship5Skin`, `WhaleSkin`) in favor of the consolidated
	-- `Tier1Boat`..`Tier10Boat` cash chain plus three Robux ids
	-- (`PirateShip`, `Ducky`, `Moby`). Every persisted boat id (the
	-- equipped one + every key in `ownedBoatIds` / `ownedShipSkinIds`)
	-- runs through `BoatCatalog.RemapLegacyBoatId` BEFORE any catalog
	-- gate, so:
	--
	--   * `DefaultTanker` → `Tier1Boat`     (old starter → new starter)
	--   * `Ship4Skin`     → `PirateShip`    (Robux purchase preserved)
	--   * `Ship5Skin`     → `Ducky`         (Robux purchase preserved)
	--   * `WhaleSkin`     → `Moby`          (Robux purchase preserved)
	--   * `Ship3Skin`     → DROPPED         (never sold for real money;
	--                                        productId was always 0)
	--
	-- ─── v9 → v10 (Step 6) — STILL APPLIES ─────────────────────────────
	-- v9 profiles persisted `shipSkinId` + `ownedShipSkinIds`; v10+ uses
	-- `equippedBoatId` + `ownedBoatIds`. We read either set and prefer
	-- the new names. The Step-6 policy still holds: Robux-purchased boats
	-- from `ownedShipSkinIds` carry forward, cash-only entries reset, and
	-- the equipped boat carries forward only if it was Robux-bought (or
	-- already a v10+ id). All the Step-7 remap above happens FIRST so
	-- `Ship4Skin` already reads as `PirateShip` by the time the Step-6
	-- Robux gate runs.
	--
	-- The starter set is always re-granted via `GetStarterBoatIds()`
	-- below so the player is never left without an equippable boat.
	-- ───────────────────────────────────────────────────────────────────
	local pVer = tonumber(persisted.version) or 1
	local persistedEquippedId: string? = nil
	if typeof(persisted.equippedBoatId) == "string" then
		persistedEquippedId = persisted.equippedBoatId
	elseif typeof(persisted.shipSkinId) == "string" then
		persistedEquippedId = persisted.shipSkinId
	end
	-- Step 7: legacy id remap. `RemapLegacyBoatId` returns `nil` for ids
	-- that should drop entirely (`Ship3Skin`); everything else either
	-- maps to the new id or passes through unchanged.
	local persistedEquippedIdRemapped = BoatCatalog.RemapLegacyBoatId(persistedEquippedId)

	if pVer >= 4 then
		if
			typeof(persistedEquippedIdRemapped) == "string"
			and BoatCatalog.Boats[persistedEquippedIdRemapped]
		then
			-- v11 (or v10 with no remap needed): trust the saved equip if
			-- it points at a real (non-placeholder) catalog entry.
			-- For v9 reads via the legacy `shipSkinId` key, additionally
			-- gate the equipped carry-forward on the Robux-only rule —
			-- a v9 profile that equipped a cash-only boat should reset
			-- to the starter so the player isn't equipped to a boat they
			-- no longer own after the Robux-only ownership filter below.
			local fromLegacyShipSkinId = typeof(persisted.equippedBoatId) ~= "string"
			if fromLegacyShipSkinId then
				if BoatCatalog.IsBoatRobuxOwned(persistedEquippedIdRemapped) then
					state.equippedBoatId = persistedEquippedIdRemapped
				else
					state.equippedBoatId = "Tier1Boat"
				end
			else
				state.equippedBoatId = persistedEquippedIdRemapped
			end
		else
			state.equippedBoatId = "Tier1Boat"
		end
	else
		local legacyId = if typeof(persisted.selectedBoatTypeId) == "string" then persisted.selectedBoatTypeId else nil
		local migrated = ShipProfileMigration.FromLegacyBoatTypeId(legacyId)
		state.equippedBoatId = migrated.boatId
	end

	-- Restore the boat ownership map.
	--
	-- Always seed from `BoatCatalog.GetStarterBoatIds()` (entries with
	-- `unlock.kind == "starter"`, placeholders excluded). Re-running this
	-- on every load is also the v < 8 → v 8 migration safety net: pre-
	-- Step-3 profiles only ever had the legacy starter seeded; this
	-- picks up any additional starters added to the catalog post-launch.
	--
	-- Persisted entries are filtered: every key first runs through
	-- `BoatCatalog.RemapLegacyBoatId` (Step 7 — drops `Ship3Skin`,
	-- remaps `DefaultTanker` / `Ship4Skin` / `Ship5Skin` / `WhaleSkin` →
	-- their v11 successors); the remapped id then passes through the
	-- standard `IsBoatPurchasable` / `IsBoatRobuxOwned` gate so missing
	-- catalog rows are dropped and `placeholder = true` entries cannot
	-- be promoted to live equippable boats by a tampered profile.
	--
	-- v9 → v10 (Step 6) policy still applies: when the profile carries
	-- the legacy `ownedShipSkinIds` key, ONLY entries whose catalog
	-- `unlock.kind == "robux"` carry forward (cash boats reset). When
	-- the profile carries the new `ownedBoatIds` key (v10+ save), every
	-- owned id passes the standard `IsBoatPurchasable` filter
	-- (Robux + cash both kept).
	--
	-- The currently-equipped boat is always re-granted as a defense
	-- against an ownership map that drifted out of sync with
	-- `equippedBoatId` (e.g. catalog rename mid-flight).
	state.ownedBoatIds = BoatCatalog.GetStarterBoatIds() :: { [string]: boolean }
	if typeof(persisted.ownedBoatIds) == "table" then
		for boatId, owned in pairs(persisted.ownedBoatIds) do
			local remapped = BoatCatalog.RemapLegacyBoatId(boatId)
			if
				typeof(remapped) == "string"
				and remapped ~= ""
				and owned == true
				and BoatCatalog.IsBoatPurchasable(remapped)
			then
				state.ownedBoatIds[remapped] = true
			end
		end
	elseif typeof(persisted.ownedShipSkinIds) == "table" then
		for boatId, owned in pairs(persisted.ownedShipSkinIds) do
			local remapped = BoatCatalog.RemapLegacyBoatId(boatId)
			if
				typeof(remapped) == "string"
				and remapped ~= ""
				and owned == true
				and BoatCatalog.IsBoatRobuxOwned(remapped)
			then
				state.ownedBoatIds[remapped] = true
			end
		end
	end
	if typeof(state.equippedBoatId) == "string" and BoatCatalog.IsBoatPurchasable(state.equippedBoatId) then
		state.ownedBoatIds[state.equippedBoatId] = true
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
									-- Restore the center-pump flag so the post-restore
									-- `_ensurePlayerState` auto-place loop recognizes the
									-- existing pump and does NOT spawn a fresh T1 on top
									-- of it. Without this, reconnects silently reset every
									-- upgraded pump back to T1 (the restored record is
									-- shadowed by a new auto-placed one and then
									-- overwritten on the next save). See save side ~line
									-- 3767 — both sides must round-trip this flag.
									isCenterPump = rec.isCenterPump == true,
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

	-- One-shot center-pump backfill (legacy profiles).
	--
	-- A prior bug omitted `isCenterPump` from the persisted/restored drill
	-- record. After restore, `_ensurePlayerState`'s auto-place loop
	-- (search: `_autoPlaceCenterPump`) saw no flagged pump for the chunk
	-- and spawned a fresh **T1** record on top of the player's upgraded
	-- one. Production + visuals key off `isCenterPump`, so the player's
	-- T2/T3 upgrade silently disappeared on every reconnect (cash spent
	-- was lost too — no audit log to refund from).
	--
	-- The fix (above) round-trips `isCenterPump` correctly going forward,
	-- but profiles saved before the fix still have the upgraded record
	-- without the flag. The duplicate-cell guard in the restore loop kept
	-- the *highest-priority* (lowest `drillId`) record at each center
	-- cell, so the upgraded tier is still in `state.drillsById` — it just
	-- needs the flag re-attached so auto-place skips the chunk.
	--
	-- For each chunk, find the surviving T33 record(s), pick the highest
	-- tier (ties → smallest drillId, the original pump), set the flag,
	-- and drop any siblings (defensive — duplicate-cell guard normally
	-- prevents siblings, but future restore changes shouldn't silently
	-- recreate the bug). Idempotent: re-running on an already-fixed
	-- profile is a no-op because `hasFlagged` short-circuits.
	do
		local CENTER_TILE_KEY = "T33"
		local PUMP_TIER_RANK = { T1 = 1, T2 = 2, T3 = 3 }
		local centerCandidates: { [string]: { number } } = {}
		for drillId, drill in pairs(state.drillsById) do
			if drill.tileKey == CENTER_TILE_KEY and typeof(drill.chunkId) == "string" then
				local list = centerCandidates[drill.chunkId]
				if not list then
					list = {}
					centerCandidates[drill.chunkId] = list
				end
				table.insert(list, drillId)
			end
		end
		local repaired = 0
		for chunkId, ids in pairs(centerCandidates) do
			local hasFlagged = false
			for _, id in ipairs(ids) do
				if state.drillsById[id].isCenterPump == true then
					hasFlagged = true
					break
				end
			end
			if not hasFlagged then
				local bestId, bestRank = nil :: number?, -1
				for _, id in ipairs(ids) do
					local rank = PUMP_TIER_RANK[state.drillsById[id].tier or "T1"] or 1
					if rank > bestRank or (rank == bestRank and (bestId == nil or id < bestId)) then
						bestId = id
						bestRank = rank
					end
				end
				if bestId then
					state.drillsById[bestId].isCenterPump = true
					for _, id in ipairs(ids) do
						if id ~= bestId then
							state.drillsById[id] = nil
							state.activeDrillCount = math.max(0, state.activeDrillCount - 1)
						end
					end
					repaired += 1
					DevLog.log(string.format(
						"[CenterPumpBackfill] chunk=%s reflagged drillId=%d tier=%s (dropped %d shadow record(s))",
						tostring(chunkId), bestId, tostring(state.drillsById[bestId].tier), #ids - 1
					))
				end
			end
		end
		if repaired > 0 then
			-- Mark dirty so the cleaned-up state (with flag set + shadow
			-- records removed) gets written on the next save tick. New
			-- save format includes `isCenterPump`, so this fix sticks.
			self:_markDirty(state.ownerUserId)
		end
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

	-- Oil Heaven / rebirth fields.
	if (persisted :: any).oilHeavenUnlocked == true then
		state.oilHeavenUnlocked = true
	end
	if typeof((persisted :: any).rebirthCount) == "number" and (persisted :: any).rebirthCount > 0 then
		state.rebirthCount = math.floor((persisted :: any).rebirthCount)
	end
	if typeof((persisted :: any).oilHeavenState) == "table" then
		state.oilHeavenState = (persisted :: any).oilHeavenState
	end

	-- ─── Rolling session economics (`economicsSessions`, v12+) ─────────────
	do
		(state :: any).economicsSessions = {}
		local rawEco = (persisted :: any).economicsSessions
		local maxEcoRows = tonumber(SessionEconomicsConfig.MAX_SESSION_ROWS)
		maxEcoRows = if typeof(maxEcoRows) == "number" and maxEcoRows >= 2 then math.floor(maxEcoRows) else 10
		if typeof(rawEco) == "table" then
			local rows = rawEco :: { any }
			local count = #rows
			local startCopy = math.max(1, count - maxEcoRows + 1)
			for idx = startCopy, count do
				local row = rows[idx]
				if typeof(row) == "table" then
					local net = tonumber(row.netOrganic)
					local sec = tonumber(row.sessionSeconds)
					local ended = tonumber(row.endedAt)
					if typeof(net) == "number" and typeof(sec) == "number" and sec >= 0 then
						table.insert((state :: any).economicsSessions, {
							netOrganic = math.floor(net + 0.5),
							sessionSeconds = math.max(0, math.floor(sec)),
							endedAt = if typeof(ended) == "number" then math.floor(ended) else os.time(),
						})
					end
				end
			end
		end
	end

	if (state :: any).ftueCompleted == true then
		if self:_clearFtuePlacementNoSellback(state) then
			self:_markDirty(state.ownerUserId)
		end
	end
end

--- Start per-join economics window (**not persisted**) — captures baseline cash +
--- clock so `PlayerRemoving` can append one organic `{ netOrganic, seconds }`
--- row (Robux-direct cash subtracted separately).
function OilStateService:_economicsBeginSessionTracking(state: any)
	if typeof(state) ~= "table" then
		return
	end
	if typeof(state.economicsSessionJoinWallTime) == "number" then
		return
	end
	if typeof(state.economicsSessions) ~= "table" then
		state.economicsSessions = {}
	end
	state.economicsSessionJoinWallTime = os.time()
	state.economicsSessionBaselineCash = floorPositive(state.cash or 0)
	state.economicsExcludedRobuxCashThisSession = 0
end

--- Append a trailing session economics row + trim (`MAX_SESSION_ROWS`). Clears
--- runtime session trackers so the profile never persists join baselines.
function OilStateService:_economicsFinalizeSessionOnDrop(state: any)
	if typeof(state) ~= "table" then
		return
	end
	local joinWall = state.economicsSessionJoinWallTime
	local baseline = state.economicsSessionBaselineCash
	state.economicsSessionJoinWallTime = nil :: any
	state.economicsSessionBaselineCash = nil :: any
	if typeof(joinWall) ~= "number" or typeof(baseline) ~= "number" then
		return
	end

	local excluded = floorPositive(state.economicsExcludedRobuxCashThisSession or 0)
	state.economicsExcludedRobuxCashThisSession = 0

	local endWall = os.time()
	local seconds = math.max(0, endWall - math.floor(joinWall))
	local gross = floorPositive(state.cash) - floorPositive(baseline)
	local organic = gross - excluded

	local minSec =
		math.floor(tonumber(SessionEconomicsConfig.MIN_SESSION_SECONDS_TO_RECORD) or 45)
	minSec = math.max(10, math.min(minSec, 900))
	if seconds < minSec and math.abs(organic) < 250 then
		return
	end

	local maxEcoRows =
		math.clamp(math.floor(tonumber(SessionEconomicsConfig.MAX_SESSION_ROWS) or 10), 3, 30)
	table.insert(state.economicsSessions, {
		netOrganic = math.floor(organic + 0.5),
		sessionSeconds = math.max(seconds, 1),
		endedAt = endWall,
	})
	local ecoRows = state.economicsSessions
	while typeof(ecoRows) == "table" and #ecoRows > maxEcoRows do
		table.remove(ecoRows, 1)
	end
	self:_markDirty(state.ownerUserId :: any)
end

--- Exclude Robux-funded **direct cash** grants from rolling organic net so buying
--- a Large pack yesterday doesn't inflate tomorrow's inferred $/hour. Call for
--- every `MonetizationService` `_grantCurrency` path (dynamic + flat).
function OilStateService:NotifyEconomicsRobuxDirectCashGrant(userId: number, grantedAmount: number?)
	if typeof(userId) ~= "number" then
		return
	end
	if typeof(grantedAmount) ~= "number" or grantedAmount <= 0 then
		return
	end
	local st = self._statesByUserId[userId]
	if typeof(st) ~= "table" then
		return
	end
	st.economicsExcludedRobuxCashThisSession = floorPositive(
		st.economicsExcludedRobuxCashThisSession or 0
	) + math.floor(grantedAmount)
end

--- Returns **post-multiplier / post-safety** dollar amount for `"small"|"medium"|"large"` packs.
function OilStateService:GetDynamicCurrencyPackGrant(userId: number, tier: string): number
	local tierNorm = ""
	if tier == "small" or tier == "medium" or tier == "large" then
		tierNorm = tier
	else
		return 0 :: any
	end
	local state = self._statesByUserId[userId]
	if typeof(state) ~= "table" then
		local fb = tonumber(SessionEconomicsConfig.FALLBACK_NET_CASH_PER_HOUR) or 15_000
		return SessionEconomics.cashGrantForTier(fb, tierNorm)
	end
	local cashFloor = floorPositive(state.cash or 0)
	local hourly = SessionEconomics.estimateNetCashPerHour(state.economicsSessions or {}, cashFloor)
	return SessionEconomics.cashGrantForTier(hourly, tierNorm)
end

--- Client preview blob for HUD copy — never trust `grant` literals from Studio.
function OilStateService:GetEconomicsCashPackPreview(userId: number)
	local state = self._statesByUserId[userId]
	if typeof(state) ~= "table" then
		local hourly = SessionEconomics.estimateNetCashPerHour({}, 0 :: any)
		return {
			ok = false,
			code = "ERR_NO_STATE",
			rollingNetCashPerHour = hourly,
			smallCash = SessionEconomics.cashGrantForTier(hourly, "small"),
			mediumCash = SessionEconomics.cashGrantForTier(hourly, "medium"),
			largeCash = SessionEconomics.cashGrantForTier(hourly, "large"),
		}
	end
	local cashFloor = floorPositive(state.cash or 0)
	local hourly =
		SessionEconomics.estimateNetCashPerHour(state.economicsSessions or {}, cashFloor)
	return {
		ok = true,
		code = nil,
		rollingNetCashPerHour = hourly,
		smallCash = SessionEconomics.cashGrantForTier(hourly, "small"),
		mediumCash = SessionEconomics.cashGrantForTier(hourly, "medium"),
		largeCash = SessionEconomics.cashGrantForTier(hourly, "large"),
	}
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
	local econState = self._statesByUserId[userId]
	if econState then
		self:_economicsFinalizeSessionOnDrop(econState)
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
			-- Telemetry §6.7 `oil_state_load_failed` — fire on EACH
			-- retry attempt (with `attempt` so analytics can plot
			-- "retry #N → successful resolve" tail behaviour).
			pcall(function()
				Telemetry.Track(nil, "oil_state_load_failed", {
					userId = userId,
					attempt = attempt,
					error = tostring(profileOrErr),
				})
			end)
			task.wait(RETRY_DELAY)
		elseif not ok then
			warn(string.format(
				"[OilStateService] Load failed for user %d after %d attempts: %s",
				userId, MAX_LOAD_RETRIES, tostring(profileOrErr)
			))
			pcall(function()
				Telemetry.Track(nil, "oil_state_load_failed", {
					userId = userId,
					attempt = attempt,
					error = tostring(profileOrErr),
				})
			end)
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
	-- Persist the legacy ship-upgrade refund one-shot so the v8 → v11
	-- migration in `_applyPersistedIntoState` cannot replay the cash
	-- grant on subsequent loads. See the field doc on
	-- `buildDefaultPersisted` for the full migration story.
	(persisted :: any).legacyShipUpgradeRefunded = (state :: any).legacyShipUpgradeRefunded == true
	-- `ftueFreeCargoCapacityUpgradeUsed` removed by Step 4 — see the
	-- companion comment in `_applyPersistedIntoState` for details.
	(persisted :: any).ftueFreeDocksDrillUsed = (state :: any).ftueFreeDocksDrillUsed == true
	(persisted :: any).ftueFirstRevealApplied = (state :: any).ftueFirstRevealApplied == true
	(persisted :: any).ftueFirstBarrelGranted = (state :: any).ftueFirstBarrelGranted == true
	--- Daily reward calendar — see `_applyPersistedIntoState` for the read side.
	--- Leading `;` disambiguates the `(persisted :: any)` paren-call from the
	--- previous `local` assignment (Lua would otherwise treat it as
	--- `dailyRewardClaimedCount(persisted :: any)` — a function call).
	local sDrcc = (state :: any).dailyRewardClaimedCount
	;(persisted :: any).dailyRewardClaimedCount = if typeof(sDrcc) == "number" and sDrcc >= 0 then math.floor(sDrcc) else 0
	local sDrlca = (state :: any).dailyRewardLastClaimAt
	if typeof(sDrlca) == "number" and sDrlca > 0 then
		(persisted :: any).dailyRewardLastClaimAt = sDrlca
	else
		(persisted :: any).dailyRewardLastClaimAt = nil
	end
	local sDrs2bid = (state :: any).dailyRewardSlot2BoatId
	if typeof(sDrs2bid) == "string" and sDrs2bid ~= "" then
		(persisted :: any).dailyRewardSlot2BoatId = sDrs2bid
	else
		(persisted :: any).dailyRewardSlot2BoatId = nil
	end
	if typeof((state :: any).ftueStep) == "string" then
		(persisted :: any).ftueStep = (state :: any).ftueStep
	elseif (state :: any).ftueCompleted == true then
		(persisted :: any).ftueStep = nil
	else
		(persisted :: any).ftueStep = if FtueConfig.Enabled then FtueConfig.Step.WaitDrillOil_WIP else FtueConfig.Step.Done
	end
	(persisted :: any).ftueCompleted = (state :: any).ftueCompleted == true
	(persisted :: any).ftueDoneScreenAcknowledged = (state :: any).ftueDoneScreenAcknowledged == true
	(persisted :: any).robuxShopAutoOpenDismissed = (state :: any).robuxShopAutoOpenDismissed == true
	-- Mirror the per-profile one-time-purchase set verbatim. Only string
	-- keys with `true` values are kept (matches the load-side filter in
	-- `_applyPersistedIntoState`). `nil` / `false` values are skipped so
	-- the persisted column stays compact.
	do
		local out: { [string]: boolean } = {}
		local src = (state :: any).purchasedOneTimeItemIds
		if typeof(src) == "table" then
			for k, v in pairs(src) do
				if typeof(k) == "string" and k ~= "" and v == true then
					out[k] = true
				end
			end
		end
		(persisted :: any).purchasedOneTimeItemIds = out
	end
	-- `ftueDocksUpgradeSubStep` persistence removed by Step 4 of the
	-- boat-progression refactor (the entire `WaitDocksUpgradeShip` leg
	-- is gone).
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
				plotId = if typeof((snap :: any).plotId) == "number" and (snap :: any).plotId > 0 then (snap :: any).plotId else nil,
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
			-- Persist the center-pump flag so reconnects keep the upgraded
			-- tier. Without this, the restore path at ~line 3413 rebuilds the
			-- record without `isCenterPump`, then `_ensurePlayerState`
			-- (~line 2767) thinks the chunk has no center pump and
			-- auto-places a fresh T1 pump over it — the player's upgrade
			-- visibly disappears. See restore side for the matching read.
			isCenterPump = drill.isCenterPump == true,
		})
	end

	-- (drills-only refactor) Removed: pipes / drums serialization + nextProspectId / nextPipeId / nextDrumId.
	persisted.nextDrillId = state.nextDrillId
	-- v12+: `economicsSessions` for dynamic Robux cash-pack sizing.
	--
	-- v11: Step 7 boat refactor — consolidated `Tier1Boat`..`Tier10Boat` ids.
	-- Earlier history:
	--   * 9 → 10 (Step 6): `shipSkinId` → `equippedBoatId`,
	--     `ownedShipSkinIds` → `ownedBoatIds`.
	--   * 8 → 9 (Step 4): deleted the `shipSpeedLevel` /
	--     `shipCapacityLevel` + `ftueDocksUpgradeSubStep` fields.
	--   * 7 → 8 (Step 3): data-driven starter set.
	persisted.economicsSessions = {}
	if typeof((state :: any).economicsSessions) == "table" then
		for _, row in ipairs((state :: any).economicsSessions :: { any }) do
			if typeof(row) == "table" then
				table.insert((persisted :: any).economicsSessions, {
					netOrganic = math.floor((tonumber((row :: any).netOrganic) or 0) + 0.5),
					sessionSeconds = math.max(
						0,
						math.floor(tonumber((row :: any).sessionSeconds) or 0)
					),
					endedAt = math.floor(tonumber((row :: any).endedAt) or os.time()),
				})
			end
		end
	end
	persisted.version = 12

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
	-- Step 4 of the boat-progression refactor deleted the per-player
	-- `shipSpeedLevel` / `shipCapacityLevel` fields — speed and capacity
	-- are baked per-boat in `BoatCatalog`. Only the equipped boat id
	-- + the ownership set (below) are persisted now.
	persisted.equippedBoatId = (typeof(state.equippedBoatId) == "string" and state.equippedBoatId) or "Tier1Boat"

	-- Persist the boat ownership set. Only emit known catalog ids so a
	-- stale boat removed from `BoatCatalog` doesn't linger in DataStores
	-- and a typo in `GrantBoat` can't pollute saves. The starter is
	-- always written so the seed is explicit.
	local ownedOut: { [string]: boolean } = { Tier1Boat = true }
	if typeof(state.ownedBoatIds) == "table" then
		for boatId, owned in pairs(state.ownedBoatIds) do
			if typeof(boatId) == "string" and boatId ~= "" and owned == true and BoatCatalog.Boats[boatId] then
				ownedOut[boatId] = true
			end
		end
	end
	persisted.ownedBoatIds = ownedOut

	-- Step 6 cleanup: explicitly clear the v9 field names so a profile
	-- that was loaded from a v9 row + then re-saved doesn't carry the
	-- old keys forward in DataStore. Without this clear the legacy
	-- `shipSkinId` / `ownedShipSkinIds` would round-trip from the
	-- `_loadPersistedProfile` table indefinitely (defaults assign new
	-- keys but never remove old ones). Costs nothing on a brand-new
	-- profile (the keys are nil → still nil).
	persisted.shipSkinId = nil
	persisted.ownedShipSkinIds = nil

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

	-- Oil Heaven / rebirth
	;(persisted :: any).oilHeavenUnlocked = state.oilHeavenUnlocked == true
	;(persisted :: any).rebirthCount = if typeof(state.rebirthCount) == "number" then math.floor(state.rebirthCount) else 0
	;(persisted :: any).oilHeavenState = if typeof(state.oilHeavenState) == "table" then state.oilHeavenState else {}

	return persisted
end

function OilStateService:SetBoatDockService(svc)
	self._boatDockService = svc
end

function OilStateService:SetEquippedBoatChangedHandler(fn: (number, string) -> ())
	self._equippedBoatChangedHandler = fn
end

function OilStateService:OwnsBoat(userId: number, boatId: string?): boolean
	if typeof(boatId) ~= "string" or boatId == "" then
		return false
	end
	-- Boat progression refactor (Step 3): starter boats are owned by
	-- definition (data-driven via `unlock.kind == "starter"`) so the UI
	-- doesn't briefly render "locked" on the very first frame after join,
	-- even before the player's state loads.
	local starters = BoatCatalog.GetStarterBoatIds()
	if starters[boatId] == true then
		return true
	end
	local state = self._statesByUserId[userId]
	if not state then
		return false
	end
	local owned = state.ownedBoatIds
	return typeof(owned) == "table" and owned[boatId] == true
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

--- Returns `true` when the player has already purchased the given
--- `MonetizationCatalog` item flagged with `oneTimePurchase = true`. Cheap
--- in-memory lookup; does NOT touch DataStore. Returns `false` if the
--- player's state isn't loaded (e.g. between PlayerAdded and the profile
--- async-fetch completing) — callers should treat that as "not purchased"
--- so a brand-new player with a slow load can still see the upsell card,
--- and the server-side prompt gate in `MonetizationService` is the final
--- word once state is hydrated.
function OilStateService:HasPurchasedOneTimeItem(userId: number, itemId: string): boolean
	if typeof(itemId) ~= "string" or itemId == "" then
		return false
	end
	local state = self._statesByUserId[userId]
	if not state then
		return false
	end
	local set = (state :: any).purchasedOneTimeItemIds
	if typeof(set) ~= "table" then
		return false
	end
	return set[itemId] == true
end

--- Idempotent flip-on-first-buy for `oneTimePurchase` items. Mirrors the
--- shape of `MarkRobuxShopAutoOpenDismissed`: returns `true` only when the
--- flag was newly set (caller can avoid double pushes). Always pushes the
--- state on a fresh flip so the open `RobuxShopPanel` repaints/hides the
--- Featured row immediately, without waiting for the next periodic snapshot.
--- Called by `MonetizationService:_processReceipt` after `_applyGrant`.
function OilStateService:MarkPurchasedOneTimeItem(userId: number, itemId: string): boolean
	if typeof(itemId) ~= "string" or itemId == "" then
		return false
	end
	local state = self._statesByUserId[userId]
	if not state then
		return false
	end
	local set = (state :: any).purchasedOneTimeItemIds
	if typeof(set) ~= "table" then
		set = {}
		(state :: any).purchasedOneTimeItemIds = set
	end
	if set[itemId] == true then
		return false
	end
	set[itemId] = true
	self:_markDirty(userId)
	pcall(function()
		self:PushState(userId)
	end)
	return true
end

--- Adds `boatId` to the player's owned set. Used by:
---   * `MonetizationService` `_grantShip` / bundle `_grantShip` after a
---     verified Robux receipt.
---   * `OilStateService:TryUnlockBoat` after a successful cash debit
---     (boat-progression refactor Step 3).
---   * `_applyPersistedIntoState` when migrating a legacy profile that
---     was missing the equipped boat from its ownership map.
---
--- Boat progression refactor (Step 3): now rejects `placeholder = true`
--- catalog entries (`Tier1Boat` … `Tier10Boat`) via
--- `BoatCatalog.IsBoatPurchasable` so a tampered receipt or future
--- Monetization wiring error cannot promote a placeholder into an
--- equippable boat. Returns `OK_ALREADY_OWNED` (not an error) when the
--- boat is already in the set so callers can short-circuit silently.
function OilStateService:GrantBoat(userId: number, boatId: string): (boolean, string)
	local state = self._statesByUserId[userId]
	if not state then
		return false, "ERR_NO_STATE"
	end
	if not BoatCatalog.IsBoatPurchasable(boatId) then
		return false, "ERR_BAD_BOAT"
	end
	if typeof(state.ownedBoatIds) ~= "table" then
		state.ownedBoatIds = BoatCatalog.GetStarterBoatIds()
	end
	if state.ownedBoatIds[boatId] == true then
		return false, "OK_ALREADY_OWNED"
	end
	state.ownedBoatIds[boatId] = true
	self:_markDirty(userId)
	return true, "OK"
end

--- Boat progression refactor (Step 3). Atomic cash-debit + grant for
--- catalog entries whose `unlock.kind == "starter"` is `"cash"`. The
--- starter and Robux paths are explicitly rejected with codes that tell
--- the caller (and ultimately the client) which path to use:
---
---   * `unlock.kind == "starter"` → `ERR_STARTER_AUTO_GRANTED` (the
---     starter is granted on profile load by `_applyPersistedIntoState`;
---     a client should not be calling this for the starter).
---   * `unlock.kind == "robux"`   → `ERR_USE_ROBUX_PROMPT` (Robux
---     unlocks flow through `MonetizationService` ProcessReceipt — the
---     client should send `RequestPromptRobuxPurchase` with the
---     matching `MonetizationCatalog` item id, e.g. `"ship.<lower>"`).
---   * No `unlock` block / `cashCost` ≤ 0 → `ERR_NOT_PURCHASABLE`.
---
--- The boat is NOT auto-equipped on success — the equip flow stays in
--- `SetEquippedBoatId` so the UI can confirm the unlock toast before
--- swapping the equipped boat. Telemetry: emits a Sink economy event +
--- a `boat_unlocked` design event so unlock rates can be tracked
--- separately from equip frequency.
function OilStateService:TryUnlockBoat(userId: number, boatId: string): (boolean, string, string)
	local state = self._statesByUserId[userId]
	if not state then
		return false, "ERR_NO_STATE", "State unavailable."
	end
	if typeof(boatId) ~= "string" or boatId == "" then
		return false, "ERR_BAD_PAYLOAD", "Missing boatId."
	end
	if not BoatCatalog.IsBoatPurchasable(boatId) then
		return false, "ERR_BAD_BOAT", "Unknown or unavailable boat."
	end
	local def = BoatCatalog.Boats[boatId]
	local unlock = def and def.unlock
	if typeof(unlock) ~= "table" then
		return false, "ERR_NOT_PURCHASABLE", "Boat is not purchasable."
	end
	if unlock.kind == "starter" then
		return false, "ERR_STARTER_AUTO_GRANTED", "Starter boats are granted automatically."
	end
	if unlock.kind == "robux" then
		return false, "ERR_USE_ROBUX_PROMPT", "Use the Robux purchase prompt for this boat."
	end
	if unlock.kind ~= "cash" then
		return false, "ERR_NOT_PURCHASABLE", "Boat is not purchasable."
	end
	local cost = tonumber(unlock.cashCost)
	if not cost or cost <= 0 then
		return false, "ERR_NOT_PURCHASABLE", "Boat has no valid cash cost."
	end
	if typeof(state.ownedBoatIds) ~= "table" then
		state.ownedBoatIds = BoatCatalog.GetStarterBoatIds()
	end
	if state.ownedBoatIds[boatId] == true then
		return false, "ERR_ALREADY_OWNED", "You already own this boat."
	end
	if not self:TrySpendCash(userId, cost) then
		return false, "ERR_NOT_ENOUGH_CASH", string.format("Need $%d to unlock this boat.", cost)
	end
	-- Cash already debited; the grant must succeed at this point. Use
	-- `GrantBoat` so any future ownership-side bookkeeping (e.g.
	-- analytics on owned-set growth) flows through one chokepoint.
	local granted, grantCode = self:GrantBoat(userId, boatId)
	if not granted and grantCode ~= "OK_ALREADY_OWNED" then
		-- Should be unreachable (we already verified `IsBoatPurchasable`
		-- and not-already-owned above), but if it ever fires we'd be
		-- charging the player without granting — surface loudly.
		warn(string.format(
			"[OilStateService] TryUnlockBoat: GrantBoat failed AFTER cash debit (userId=%d, boatId=%s, code=%s)",
			userId, boatId, tostring(grantCode)
		))
		return false, "ERR_GRANT_FAILED", "Boat grant failed; contact support."
	end
	-- Telemetry: pair the cash sink with a boat_unlocked design event so
	-- analytics can correlate unlock cost vs. unlock-to-equip latency
	-- without joining tables.
	pcall(function()
		local plr = Players:GetPlayerByUserId(userId)
		Telemetry.Economy(plr, "Sink", cost, "cash", "boat_unlock:" .. boatId, {
			kind = "boat_unlock",
			id = boatId,
		})
		Telemetry.Track(plr, "boat_unlocked", {
			boatId = boatId,
			source = "cash",
			cost = cost,
		})
	end)
	return true, "OK", "Boat unlocked."
end

function OilStateService:SetEquippedBoatId(userId: number, boatId: string): (boolean, string)
	local state = self._statesByUserId[userId]
	if not state then
		return false, "ERR_NO_STATE"
	end
	-- Boat progression refactor (Step 3): `IsBoatPurchasable` rejects
	-- both unknown ids AND `placeholder = true` entries
	-- (`Tier1Boat` … `Tier10Boat`). Without this gate a malicious client
	-- (or a stale, hand-edited profile) could equip a placeholder and
	-- get the L1/L1 stats baked into it.
	if not BoatCatalog.IsBoatPurchasable(boatId) then
		return false, "ERR_BAD_BOAT"
	end
	-- Refuse to equip boats the player hasn't unlocked. Without this
	-- check a malicious client could fire `RequestSetEquippedBoat` directly
	-- and bypass both `MonetizationService` (Robux unlocks) and
	-- `TryUnlockBoat` (cash unlocks). `OwnsBoat` treats data-driven
	-- starter boats as always-owned so the default flow is unaffected.
	if not self:OwnsBoat(userId, boatId) then
		return false, "ERR_NOT_OWNED"
	end
	local prev = state.equippedBoatId
	state.equippedBoatId = boatId
	self:_markDirty(userId)
	if prev ~= boatId and self._equippedBoatChangedHandler then
		task.spawn(self._equippedBoatChangedHandler, userId, boatId)
	end
	-- Telemetry §6.4 `boat_equipped` (renamed from `ship_skin_equipped`
	-- in Step 6). Fires on every equip call (even no-op same-boat) so
	-- analytics can see equip frequency, but `boatIdFrom == boatIdTo`
	-- lets queries filter for actual changes vs idle re-equip clicks.
	if prev ~= boatId then
		pcall(function()
			local plr = Players:GetPlayerByUserId(userId)
			Telemetry.Track(plr, "boat_equipped", {
				boatIdFrom = prev,
				boatIdTo = boatId,
			})
		end)
	end
	return true, "OK"
end

-- `TryUpgradeShipSpeed` and `TryUpgradeShipCapacity` were deleted by
-- Step 4 of the boat-progression refactor. Speed and capacity are now
-- baked per-boat in `BoatCatalog.Boats[boatId]` (`speedLevel` /
-- `capacityLevel`); progression happens via the unlock flow
-- (`TryUnlockBoat`) plus the equip flow (`SetEquippedBoatId`). Re-introducing
-- per-boat upgrades would need a fresh design, fresh remotes, and fresh
-- telemetry rows — do NOT revive the old paths in place.

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

--------------------------------------------------------------------------------
-- Oil Heaven / Rebirth
--------------------------------------------------------------------------------

function OilStateService:UnlockOilHeaven(userId: number): boolean
	local state = self._statesByUserId[userId]
	if not state then
		return false
	end
	if state.oilHeavenUnlocked then
		return true -- already unlocked
	end
	state.oilHeavenUnlocked = true
	self:_markDirty(userId)
	local plr = Players:GetPlayerByUserId(userId)
	if plr then
		plr:SetAttribute(Constants.OilHeavenUnlockedAttribute, true)
	end
	return true
end

function OilStateService:IsOilHeavenUnlocked(userId: number): boolean
	local state = self._statesByUserId[userId]
	if not state then
		return false
	end
	return state.oilHeavenUnlocked == true
end

function OilStateService:GetRebirthCount(userId: number): number
	local state = self._statesByUserId[userId]
	if not state then
		return 0
	end
	return state.rebirthCount or 0
end

--- Increments the rebirth counter by 1 and returns the new count.
--- Does NOT unlock Oil Heaven — call `UnlockOilHeaven` separately.
function OilStateService:IncrementRebirth(userId: number): number
	local state = self._statesByUserId[userId]
	if not state then
		return 0
	end
	state.rebirthCount = (state.rebirthCount or 0) + 1
	self:_markDirty(userId)
	local plr = Players:GetPlayerByUserId(userId)
	if plr then
		plr:SetAttribute(Constants.RebirthCountAttribute, state.rebirthCount)
	end
	return state.rebirthCount
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
--- Returns the starter chunk's section ID (e.g. "S04_02") based on OilConfig.
function OilStateService:GetStarterChunkSectionId(): string
	return string.format("S%02d_%02d", OilConfig.Chunks.StartingRow, OilConfig.Chunks.StartingCol)
end

--- Returns true if ANY tile in the given section has been drilled.
--- Used by FTUE rejoin logic to detect if the player already placed a drill
--- during WaitDrillOil_WIP before disconnecting.
function OilStateService:IsAnyTileInChunkDrilled(state: any, sectionId: string): boolean
	local chunks = (state :: any).chunksById
	if not chunks then return false end
	local chunk = chunks[sectionId]
	if not chunk or not chunk.tiles then return false end
	for _, tile in pairs(chunk.tiles) do
		if typeof(tile) == "table" and tile.drilled == true then
			return true
		end
	end
	return false
end

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
