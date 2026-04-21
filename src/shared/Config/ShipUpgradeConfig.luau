--!strict
-- Ship upgrades: chunky tiers + explicit cash costs (capacity + speed).
-- Table lengths define max levels; keep *_UPGRADE_COSTS length = maxLevel - 1.

local ShipUpgradeConfig = {}

-- Capacity tiers extended from 8 → 10 to match `WarehouseConfig.Tiers`
-- (also 10) so all three player-progression tracks (warehouse / ship cargo
-- / ship speed) have the same level cap. Top end tapers (cargo per level
-- shrinks at the cap) so each later level is a smaller bump in output but
-- a much bigger bump in cost — sink, not power-spike.
local CARGO_BY_CAPACITY_LEVEL: { number } = {
	15,
	24,
	32,
	40,
	46,
	52,
	56,
	60,
	64,
	68,
}

-- Curve shape: front-loaded relief, back-loaded grind. Early upgrades
-- (L1→4) are noticeably cheaper than the previous "~25% off" pass so a
-- fresh player gets a visible ship boost in the first few sells; mid-late
-- (L5+) ramps harder than before (~2x per tier) so the new top tiers
-- (L8→9, L9→10) become a real long-term cash sink instead of a casual
-- unlock. Crossover vs. previous curve is around L4→5 (≈ same cost), then
-- steeper. Total to fully max capacity: 137,200.
local CAPACITY_UPGRADE_COSTS: { number } = {
	250,
	500,
	1100,
	2300,
	4800,
	9500,
	18500,
	35000,
	65000,
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
