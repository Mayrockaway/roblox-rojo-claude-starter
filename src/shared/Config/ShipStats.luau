--!strict
-- Single resolver: all voyage/cargo gameplay numbers from speed + capacity levels only.

export type ResolvedShipStats = {
	capacity: number,
	travelSeconds: number,
	--- Legacy snapshot field: always `0` from `Resolve`. Actual dispatch cost is `ComputeDispatchFeeFromManifestOilUnits`.
	dispatchFee: number,
	eventRisk: number,
}

local ShipStats = {}

-- USD per whole barrel shipped (manifest tier keys = `HeavyCrude` / `LightSweet` / `PremiumRefined`).
local DISPATCH_FEE_USD_PER_BARREL: { [string]: number } = {
	HeavyCrude = 1,
	LightSweet = 2,
	PremiumRefined = 3,
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
  Capacity: oil units (same semantics as legacy BoatConfig `capacity`).
  Speed level lowers travel time; capacity level raises cap and fee.
]]
function ShipStats.Resolve(shipSpeedLevel: number, shipCapacityLevel: number): ResolvedShipStats
	local speedL = math.clamp(math.floor(shipSpeedLevel), 1, 10)
	local capL = math.clamp(math.floor(shipCapacityLevel), 1, 25)

	local capMin, capMax = 8, 45
	local capacity = math.floor(capMin + (capMax - capMin) * (capL - 1) / 24 + 0.5)

	local travelSlow, travelFast = 90, 42
	local travelSeconds = travelSlow - (travelSlow - travelFast) * (speedL - 1) / 9

	local riskHigh, riskLow = 0.34, 0.17
	local eventRisk = riskHigh
		- (riskHigh - riskLow) * (0.55 * (capL - 1) / 24 + 0.45 * (speedL - 1) / 9)
	eventRisk = math.clamp(eventRisk, riskLow, riskHigh)

	return {
		capacity = capacity,
		travelSeconds = travelSeconds,
		dispatchFee = 0,
		eventRisk = eventRisk,
	}
end

return ShipStats
