--!strict
-- Single resolver: all voyage/cargo gameplay numbers from speed + capacity levels only.

export type ResolvedShipStats = {
	capacity: number,
	travelSeconds: number,
	--- Legacy snapshot field: always `0` from `Resolve`. Actual dispatch cost is `ComputeDispatchFeeFromManifestOilUnits`.
	dispatchFee: number,
	eventRisk: number,
}

local ShipUpgradeConfig = require(script.Parent:WaitForChild("ShipUpgradeConfig"))

local ShipStats = {}

-- USD per whole barrel shipped (manifest tier keys = `Crude` / `Refined` / `Premium`).
local DISPATCH_FEE_USD_PER_BARREL: { [string]: number } = {
	Crude = 1,
	Refined = 2,
	Premium = 3,
}

--- `manifest` values are **oil units** (barrels × `perBarrelOilUnits`, same as server `ConsumeManifest`).
function ShipStats.ComputeDispatchFeeFromManifestOilUnits(manifest: { [string]: number }, perBarrelOilUnits: number): number
	local per = math.max(1, math.floor(perBarrelOilUnits))
	local total = 0
	for tier, rate in pairs(DISPATCH_FEE_USD_PER_BARREL) do
		local units = math.max(0, math.floor(tonumber(manifest[tier]) or 0))
		local barrels = math.floor(units / per)
		total += barrels * rate
	end
	return total
end

--[[
  Capacity: oil units — from `ShipUpgradeConfig` chunky tier table (few levels, big jumps).
  Speed level lowers travel time; capacity level raises cargo cap and affects event risk.
]]
function ShipStats.Resolve(shipSpeedLevel: number, shipCapacityLevel: number): ResolvedShipStats
	local maxSpd = ShipUpgradeConfig.MaxSpeedLevel
	local speedSpan = math.max(1, maxSpd - 1)
	local speedL = math.clamp(math.floor(shipSpeedLevel), 1, maxSpd)
	local capL = math.clamp(math.floor(shipCapacityLevel), 1, ShipUpgradeConfig.MaxCapacityLevel)

	local capacity = ShipUpgradeConfig.GetCargoCapacity(capL)
	local travelSeconds = ShipUpgradeConfig.GetTravelSeconds(speedL)

	local maxCapL = math.max(2, ShipUpgradeConfig.MaxCapacityLevel)
	local riskHigh, riskLow = 0.34, 0.17
	local capNorm = (capL - 1) / (maxCapL - 1)
	local eventRisk = riskHigh - (riskHigh - riskLow) * (0.55 * capNorm + 0.45 * (speedL - 1) / speedSpan)
	eventRisk = math.clamp(eventRisk, riskLow, riskHigh)

	return {
		capacity = capacity,
		travelSeconds = travelSeconds,
		dispatchFee = 0,
		eventRisk = eventRisk,
	}
end

return ShipStats
