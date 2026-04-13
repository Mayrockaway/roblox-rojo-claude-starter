--!strict
-- Single resolver: all voyage/cargo gameplay numbers from speed + capacity levels only.

export type ResolvedShipStats = {
	capacity: number,
	travelSeconds: number,
	dispatchFee: number,
	eventRisk: number,
}

local ShipStats = {}

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

	local feeMin, feeMax = 150, 1800
	local fee = math.floor(
		feeMin + (feeMax - feeMin) * (0.62 * (capL - 1) / 24 + 0.38 * (speedL - 1) / 9) + 0.5
	)

	local riskHigh, riskLow = 0.34, 0.17
	local eventRisk = riskHigh
		- (riskHigh - riskLow) * (0.55 * (capL - 1) / 24 + 0.45 * (speedL - 1) / 9)
	eventRisk = math.clamp(eventRisk, riskLow, riskHigh)

	return {
		capacity = capacity,
		travelSeconds = travelSeconds,
		dispatchFee = fee,
		eventRisk = eventRisk,
	}
end

return ShipStats
