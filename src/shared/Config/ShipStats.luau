--!strict
-- Single resolver: all voyage/cargo gameplay numbers from speed + capacity levels only.
--
-- BOAT PROGRESSION REFACTOR: the canonical entry point for gameplay code
-- is `ResolveForBoat(boatId)`, which reads the equipped boat's baked
-- `speedLevel` / `capacityLevel` from `BoatCatalog`. The low-level
-- `Resolve(speedLevel, capacityLevel)` is preserved as a pure helper for
-- hypothetical projections (Express Convoy clamp, FTUE escort
-- "max-speed voyage" computation).
--
-- Step 6 rename: `ResolveForSkin` → `ResolveForBoat`,
-- `LevelsForSkin` → `LevelsForBoat`, `ShipSkinCatalog` → `BoatCatalog`.

export type ResolvedShipStats = {
	capacity: number,
	travelSeconds: number,
	--- Legacy snapshot field: always `0` from `Resolve`. Actual dispatch cost is `ComputeDispatchFeeFromManifestOilUnits`.
	dispatchFee: number,
	eventRisk: number,
}

local ShipUpgradeConfig = require(script.Parent:WaitForChild("ShipUpgradeConfig"))
local BoatCatalog = require(script.Parent:WaitForChild("BoatCatalog"))

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

--[[
  Resolve gameplay stats for the player's currently equipped boat.

  Reads the boat's baked `speedLevel` / `capacityLevel` from `BoatCatalog`.
  Falls back to `Tier1Boat` (the starter) when:
    * `boatId` is nil / empty / not a string
    * the catalog entry doesn't exist
    * the entry exists but has no baked levels (defensive — every entry
      authored in Step 1 has them, but the type makes them optional)

  This is the canonical entry point for runtime stat resolution.
]]
function ShipStats.ResolveForBoat(boatId: string?): ResolvedShipStats
	local def = BoatCatalog.GetBoat(boatId)
	local speedL = tonumber(def.speedLevel)
	local capL = tonumber(def.capacityLevel)
	if speedL == nil or capL == nil then
		-- Defensive: an entry without baked levels falls back to the
		-- starter's. This should only fire for hand-edited / partially
		-- authored entries during the refactor; live entries all carry
		-- both fields.
		local fallback = BoatCatalog.GetBoat("Tier1Boat")
		speedL = speedL or tonumber(fallback.speedLevel) or 1
		capL = capL or tonumber(fallback.capacityLevel) or 1
	end
	return ShipStats.Resolve(speedL :: number, capL :: number)
end

--- Convenience accessor for callers that need the raw boat-baked levels
--- (e.g. shipment payload metadata, telemetry). Same fallback semantics
--- as `ResolveForBoat`. Returns `(speedLevel, capacityLevel)`.
function ShipStats.LevelsForBoat(boatId: string?): (number, number)
	local def = BoatCatalog.GetBoat(boatId)
	local speedL = tonumber(def.speedLevel)
	local capL = tonumber(def.capacityLevel)
	if speedL == nil or capL == nil then
		local fallback = BoatCatalog.GetBoat("Tier1Boat")
		speedL = speedL or tonumber(fallback.speedLevel) or 1
		capL = capL or tonumber(fallback.capacityLevel) or 1
	end
	speedL = math.clamp(math.floor(speedL :: number), 1, ShipUpgradeConfig.MaxSpeedLevel)
	capL = math.clamp(math.floor(capL :: number), 1, ShipUpgradeConfig.MaxCapacityLevel)
	return speedL :: number, capL :: number
end

return ShipStats
