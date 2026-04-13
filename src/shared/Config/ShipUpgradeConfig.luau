--!strict

local ShipUpgradeConfig = {
	MaxSpeedLevel = 10,
	MaxCapacityLevel = 25,
}

-- Cash to upgrade speed from `level` → `level + 1` (`level` is current 1..9).
function ShipUpgradeConfig.GetSpeedUpgradeCost(level: number): number?
	if level < 1 or level >= ShipUpgradeConfig.MaxSpeedLevel then
		return nil
	end
	local base = 450
	return math.floor(base * (1.35 ^ (level - 1)) + 0.5)
end

-- Cash to upgrade capacity from `level` → `level + 1` (`level` is current 1..24).
function ShipUpgradeConfig.GetCapacityUpgradeCost(level: number): number?
	if level < 1 or level >= ShipUpgradeConfig.MaxCapacityLevel then
		return nil
	end
	local base = 320
	return math.floor(base * (1.12 ^ (level - 1)) + 0.5)
end

return ShipUpgradeConfig
