--!strict
-- Ship upgrades: **chunky tiers** + explicit cash costs (capacity + speed).
-- Table lengths define max levels; keep `*_UPGRADE_COSTS` length = maxLevel - 1.

local ShipUpgradeConfig = {}

-- Cargo (barrels / oil units) at each ship capacity **level** — large jumps, fewer purchases.
local CARGO_BY_CAPACITY_LEVEL: { number } = {
	15, -- 1 starter
	24, -- 2  (+9)
	32, -- 3  (+8)
	40, -- 4  (+8)
	46, -- 5  (+6)
	52, -- 6  (+6)
	56, -- 7  (+4)
	60, -- 8  (+4) max
}

--- Cost to upgrade capacity **from** `level` **to** `level + 1` (`level` is current 1..MaxCapacityLevel-1).
local CAPACITY_UPGRADE_COSTS: { number } = {
	1800, -- 1→2
	2800, -- 2→3
	4200, -- 3→4
	5500, -- 4→5
	7000, -- 5→6
	6000, -- 6→7
	7500, -- 7→8
}

-- Base voyage duration (seconds) at each speed **level** before strait/events add time.
-- Max tier **30s** — leaves headroom so incidents/extensions don’t start from an already-tiny leg.
local TRAVEL_SECONDS_BY_SPEED_LEVEL: { number } = {
	60, -- 1
	50, -- 2  (−10)
	44, -- 3  (−6)
	40, -- 4  (−4)
	37, -- 5  (−3)
	34, -- 6  (−3)
	32, -- 7  (−2)
	30, -- 8  (−2) max
}

--- Cost to upgrade speed **from** `level` **to** `level + 1` (`level` is current 1..MaxSpeedLevel-1).
local SPEED_UPGRADE_COSTS: { number } = {
	1400, -- 1→2
	2200, -- 2→3
	3200, -- 3→4
	4200, -- 4→5
	5200, -- 5→6
	5800, -- 6→7
	6500, -- 7→8
}

ShipUpgradeConfig.MaxCapacityLevel = #CARGO_BY_CAPACITY_LEVEL
ShipUpgradeConfig.MaxSpeedLevel = #TRAVEL_SECONDS_BY_SPEED_LEVEL

function ShipUpgradeConfig.GetCargoCapacity(capacityLevel: number): number
	local L = math.clamp(math.floor(capacityLevel), 1, ShipUpgradeConfig.MaxCapacityLevel)
	return CARGO_BY_CAPACITY_LEVEL[L] or CARGO_BY_CAPACITY_LEVEL[1]
end

function ShipUpgradeConfig.GetTravelSeconds(speedLevel: number): number
	local L = math.clamp(math.floor(speedLevel), 1, ShipUpgradeConfig.MaxSpeedLevel)
	return TRAVEL_SECONDS_BY_SPEED_LEVEL[L] or TRAVEL_SECONDS_BY_SPEED_LEVEL[1]
end

function ShipUpgradeConfig.GetSpeedUpgradeCost(level: number): number?
	if level < 1 or level >= ShipUpgradeConfig.MaxSpeedLevel then
		return nil
	end
	local cost = SPEED_UPGRADE_COSTS[level]
	if cost == nil then
		return nil
	end
	return cost
end

function ShipUpgradeConfig.GetCapacityUpgradeCost(level: number): number?
	if level < 1 or level >= ShipUpgradeConfig.MaxCapacityLevel then
		return nil
	end
	local cost = CAPACITY_UPGRADE_COSTS[level]
	if cost == nil then
		return nil
	end
	return cost
end

return ShipUpgradeConfig
