--!strict

-- Central list of strait shipment events. Server resolves impacts from these flags.
-- Design / fantasy / backlog: docs/features/strait-waypoint-events/EVENTS.md
-- pause: default ~5s (StraitEventConfig.DefaultWaypointPauseSeconds) unless pauseSeconds / skipWaypointPause set.

export type Severity = "Low" | "Medium" | "High"

export type StraitEventDef = {
	id: string,
	severity: Severity,
	displayName: string,
	skipWaypointPause: boolean?,
	pauseSeconds: number?,
	-- Fraction of hullMax removed (stackable across events).
	hullDamageFraction: number?,
	-- Multiplies shipment.priceMultiplier (e.g. 0.94 = 6% effective payout hit at resolution).
	priceMultiplierFactor: number?,
	totalLoss: boolean?,
	-- Whole barrels lost: ceil(manifestTotal * fraction), removed HeavyCrude → … → PremiumRefined.
	looseBarrelLossFraction: number?,
}

local StraitEventConfig = require(script.Parent.Parent:WaitForChild("StraitEventConfig"))
local EXT = StraitEventConfig.ExtendedWaypointPauseSeconds

local Catalog = {}

Catalog.Events = {
	{
		id = "RoutinePaperwork",
		severity = "Low",
		displayName = "Routine paperwork",
		hullDamageFraction = 0,
		priceMultiplierFactor = 0.97,
	} :: StraitEventDef,
	{
		id = "CoastGuardGlance",
		severity = "Low",
		displayName = "Coast guard glance",
		hullDamageFraction = 0.04,
		priceMultiplierFactor = 1,
	} :: StraitEventDef,
	{
		id = "MinorInspection",
		severity = "Low",
		displayName = "Minor inspection",
		pauseSeconds = EXT,
		hullDamageFraction = 0.02,
		priceMultiplierFactor = 0.95,
	} :: StraitEventDef,
	{
		id = "HighWinds",
		severity = "Low",
		displayName = "High winds",
		pauseSeconds = EXT,
	} :: StraitEventDef,
	{
		id = "TurbulentSeas",
		severity = "Medium",
		displayName = "Turbulent seas",
		looseBarrelLossFraction = 0.1,
	} :: StraitEventDef,
	{
		id = "PirateRaid",
		severity = "Medium",
		displayName = "Pirate raid",
		looseBarrelLossFraction = 0.25,
	} :: StraitEventDef,
	{
		id = "ExtendedInspection",
		severity = "Medium",
		displayName = "Extended inspection",
		pauseSeconds = EXT,
		hullDamageFraction = 0.08,
		priceMultiplierFactor = 0.88,
	} :: StraitEventDef,
	{
		id = "FuelSiphoningAttempt",
		severity = "Medium",
		displayName = "Fuel siphoning attempt",
		hullDamageFraction = 0.05,
		priceMultiplierFactor = 0.82,
	} :: StraitEventDef,
	{
		id = "EngineRoomSmoke",
		severity = "Medium",
		displayName = "Engine room smoke",
		pauseSeconds = EXT,
		hullDamageFraction = 0.12,
		priceMultiplierFactor = 0.9,
	} :: StraitEventDef,
	{
		id = "BoardingAndSeizure",
		severity = "High",
		displayName = "Boarding and seizure",
		totalLoss = true,
	} :: StraitEventDef,
	{
		id = "MineStrike",
		severity = "High",
		displayName = "Mine strike",
		totalLoss = true,
	} :: StraitEventDef,
	{
		id = "MissileStrike",
		severity = "High",
		displayName = "Missile strike",
		totalLoss = true,
	} :: StraitEventDef,
} :: { StraitEventDef }

function Catalog.GetById(id: string): StraitEventDef?
	for _, def in ipairs(Catalog.Events) do
		if def.id == id then
			return def
		end
	end
	return nil
end

function Catalog.GetPool(severity: Severity): { StraitEventDef }
	local pool = {}
	for _, def in ipairs(Catalog.Events) do
		if def.severity == severity then
			table.insert(pool, def)
		end
	end
	return pool
end

function Catalog.PickRandom(severity: Severity, rng: Random): StraitEventDef?
	local pool = Catalog.GetPool(severity)
	if #pool == 0 then
		return nil
	end
	return pool[rng:NextInteger(1, #pool)]
end

return Catalog
