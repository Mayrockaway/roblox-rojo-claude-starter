--!strict
-- Ship upgrades: chunky tiers + explicit cash costs (capacity + speed).
-- Table lengths define max levels; keep *_UPGRADE_COSTS length = maxLevel - 1.

local ShipUpgradeConfig = {}

local CARGO_BY_CAPACITY_LEVEL: { number } = {
	15,
	24,
	32,
	40,
	46,
	52,
	56,
	60,
}

local CAPACITY_UPGRADE_COSTS: { number } = {
	750,
	1200,
	1900,
	3000,
	4700,
	7200,
	10500,
}

local TRAVEL_SECONDS_BY_SPEED_LEVEL: { number } = {
	60,
	50,
	44,
	40,
	37,
	34,
	32,
	30,
}

local SPEED_UPGRADE_COSTS: { number } = {
	600,
	950,
	1500,
	2400,
	3800,
	5800,
	8500,
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
