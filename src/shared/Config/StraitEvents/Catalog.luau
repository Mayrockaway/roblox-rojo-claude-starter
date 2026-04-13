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
	-- Multiplies shipment.priceMultiplier (e.g. 0.94 = 6% effective payout hit at resolution).
	priceMultiplierFactor: number?,
	totalLoss: boolean?,
	-- Whole barrels lost: ceil(manifestTotal * fraction), removed HeavyCrude → … → PremiumRefined.
	looseBarrelLossFraction: number?,
	-- If true, server handles missile flight with hit/smallHit/miss outcomes instead of instant totalLoss.
	missileEvent: boolean?,
	-- If true, server handles mine surfacing with hit/miss outcomes.
	mineEvent: boolean?,
	-- If true, server handles pirate boarding visual sequence.
	pirateEvent: boolean?,
}

local StraitEventConfig = require(script.Parent.Parent:WaitForChild("StraitEventConfig"))
local EXT = StraitEventConfig.ExtendedWaypointPauseSeconds

local Catalog = {}

-- Missile strike outcome config
Catalog.MissileConfig = {
	MissileCount = 4,       -- missiles fired per trigger (3 triggers × 4 = 12 total)
	HitChance = 0.05,       -- 5% direct hit → total loss
	SmallHitChance = 0.25,  -- 25% small hit → lose 50% barrels
	-- remaining 70% = clean miss, nothing happens
	SmallHitBarrelLossFraction = 0.50, -- 50% barrels lost on small hit
	FlightSeconds = 2.5,    -- missile flight duration
	BarrageStagger = 0.3,   -- seconds between each missile launch in the barrage
	BarragePauseAfter = 2.0,-- extra pause after last missile lands
	LaunchDistance = 250,    -- how far away missile spawns (behind terrain)
	LaunchHeight = 80,      -- height above water for launch point
	MissSpreadRadius = 40,  -- how far misses splash from ship
}

-- Mine event config
Catalog.MineConfig = {
	MineCount = 15,          -- total mines that surface around the boat
	HitChance = 0.10,        -- 10% chance a mine spawns in the boat's path → boom
	RiseSeconds = 5.0,       -- SLOW rise to the surface
	SpawnRadiusMin = 30,     -- minimum distance from ship
	SpawnRadiusMax = 120,    -- maximum distance — wide spread around the ship
	SpawnDepth = 40,         -- how far below water they start
	PauseAfterSurface = 4.0, -- how long ship pauses while navigating through
	MineScale = 0.4,         -- scale factor on mine model (40% of original size)
}

-- Pirate raid visual sequence config
Catalog.PirateRaidConfig = {
	PirateCount = 4,
	SequenceDuration = 18,
	ApproachDistance = 200,
	PullUpDistance = 15,
	ApproachSeconds = 4,
	BoardingSeconds = 3,
	StealingSeconds = 7,
	EscapeSeconds = 4,
}

Catalog.Events = {
	{
		id = "RoutinePaperwork",
		severity = "Low",
		displayName = "Routine paperwork",
		priceMultiplierFactor = 0.97,
	} :: StraitEventDef,
	{
		id = "CoastGuardGlance",
		severity = "Low",
		displayName = "Coast guard glance",
		priceMultiplierFactor = 1,
	} :: StraitEventDef,
	{
		id = "MinorInspection",
		severity = "Low",
		displayName = "Minor inspection",
		pauseSeconds = EXT,
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
		pirateEvent = true,
	} :: StraitEventDef,
	{
		id = "ExtendedInspection",
		severity = "Medium",
		displayName = "Extended inspection",
		pauseSeconds = EXT,
		priceMultiplierFactor = 0.88,
	} :: StraitEventDef,
	{
		id = "FuelSiphoningAttempt",
		severity = "Medium",
		displayName = "Fuel siphoning attempt",
		priceMultiplierFactor = 0.82,
	} :: StraitEventDef,
	{
		id = "EngineRoomSmoke",
		severity = "Medium",
		displayName = "Engine room smoke",
		pauseSeconds = EXT,
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
		mineEvent = true,
	} :: StraitEventDef,
	{
		id = "MissileStrike",
		severity = "High",
		displayName = "Missile strike",
		totalLoss = true,
		-- Handled specially by OilShipmentService: missile flight animation with hit/smallHit/miss
		missileEvent = true,
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
