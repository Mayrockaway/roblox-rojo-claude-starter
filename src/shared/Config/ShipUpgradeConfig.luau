--!strict
-- Ship upgrades: chunky tiers + explicit cash costs (capacity + speed).
-- Table lengths define max levels; keep *_UPGRADE_COSTS length = maxLevel - 1.

local ShipUpgradeConfig = {}

-- Capacity tiers (10 levels, matches `WarehouseConfig.Tiers` and the speed
-- track below so all three player-progression tracks share the same level
-- cap). Cap rescaled so L10 = 500 barrels (was 68): a fully maxed warehouse
-- stockpile (`WarehouseConfig.MaxSlots = 12 × 5 000 = 60 000` barrels)
-- can now be moved in ~120 voyages instead of ~880, making maxed-warehouse
-- + maxed-ship a genuinely playable late-game loop.
--
-- Per-level increments smoothly taper in proportion (L1→2 doubles cargo,
-- L9→10 only adds 14%) so early upgrades feel impactful and late ones
-- feel like prestige polish.
--
-- Note: visual barrel spawning on the deck is decoupled — the ship rig
-- only ever spawns up to `_loadBarrelsOnDeck`'s MAX_VISUAL_BARRELS (50)
-- regardless of how big the actual cargo number is, so a maxed ship still
-- looks like a packed deck and not a 500-barrel skyscraper that lags out
-- nearby clients.
local CARGO_BY_CAPACITY_LEVEL: { number } = {
	20,
	40,
	70,
	110,
	160,
	220,
	290,
	365,
	440,
	500,
}

-- Curve shape: front-loaded relief, back-loaded grind.
--   L1–L3 are still cheap so a fresh player feels a visible ship boost
--     in the first few sells.
--   L4+ ramps ~2x per tier; the bigger cargo jumps at high tiers (e.g.
--     L9→10 = +60 barrels) justify the steeper price tags.
--   L9→10 is the prestige tier — meaningful cash sink, not a casual
--     unlock. Combined with `WarehouseConfig` tier 9→10 (1 500 000 cash
--     for the warehouse alone), maxed everything is a true long-haul.
-- Totals: cumulative cash to reach L10 = 361,850 (top step alone:
-- 200,000). Compare warehouse fully maxed at 2,358,650 — the maxed ship
-- is ~15% of the maxed warehouse, which feels right since the warehouse
-- is the bigger long-term goal.
local CAPACITY_UPGRADE_COSTS: { number } = {
	250,
	600,
	1500,
	3500,
	8000,
	18000,
	40000,
	90000,
	200000,
}

-- Speed tiers also at 10 (matches capacity + warehouse). Gentle travel-time
-- gains at the top (30 → 28 → 26) so late levels are status / completion
-- goals rather than huge throughput jumps.
local TRAVEL_SECONDS_BY_SPEED_LEVEL: { number } = {
	60,
	50,
	44,
	40,
	37,
	34,
	32,
	30,
	28,
	26,
}

-- Same shape as capacity (cheap early, steep late). Slightly cheaper than
-- the matching capacity tier at every step so players who prefer faster
-- voyages over bigger loads can reach a given speed level a bit sooner.
-- Total to fully max speed: 115,400. Combined fully-maxed ship: 252,600.
local SPEED_UPGRADE_COSTS: { number } = {
	200,
	400,
	850,
	1800,
	3800,
	7800,
	15500,
	30000,
	55000,
}

ShipUpgradeConfig.MaxCapacityLevel = #CARGO_BY_CAPACITY_LEVEL
ShipUpgradeConfig.MaxSpeedLevel = #TRAVEL_SECONDS_BY_SPEED_LEVEL

function ShipUpgradeConfig.GetCargoCapacity(capacityLevel: number): number
	local level = math.clamp(math.floor(capacityLevel), 1, ShipUpgradeConfig.MaxCapacityLevel)
	return CARGO_BY_CAPACITY_LEVEL[level] or CARGO_BY_CAPACITY_LEVEL[1]
end

function ShipUpgradeConfig.GetTravelSeconds(speedLevel: number): number
	local level = math.clamp(math.floor(speedLevel), 1, ShipUpgradeConfig.MaxSpeedLevel)
	return TRAVEL_SECONDS_BY_SPEED_LEVEL[level] or TRAVEL_SECONDS_BY_SPEED_LEVEL[1]
end

function ShipUpgradeConfig.GetSpeedUpgradeCost(level: number): number?
	if level < 1 or level >= ShipUpgradeConfig.MaxSpeedLevel then
		return nil
	end
	return SPEED_UPGRADE_COSTS[level]
end

function ShipUpgradeConfig.GetCapacityUpgradeCost(level: number): number?
	if level < 1 or level >= ShipUpgradeConfig.MaxCapacityLevel then
		return nil
	end
	return CAPACITY_UPGRADE_COSTS[level]
end

return ShipUpgradeConfig
