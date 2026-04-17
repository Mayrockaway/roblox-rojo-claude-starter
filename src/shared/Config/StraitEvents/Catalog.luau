--!strict

-- **Single source of truth** for strait waypoint shipment events (trigger ordinals from `StraitEventConfig.LaneWaypointTriggers`).
-- Add new events here: flags drive server behavior; `MissileConfig` / `StormConfig` / … hold tuning; optional `StraitWaypointsFx/<id>` for generic FX.
-- Human-oriented writeups: docs/features/strait-waypoint-events/EVENTS.md (keep in sync when changing rows).

export type Severity = "Low" | "Medium" | "High"

export type StraitEventDef = {
	id: string,
	severity: Severity,
	displayName: string,
	--- Optional banner line for playtest HUD (defaults to `displayName` if omitted).
	playtestTitle: string?,
	skipWaypointPause: boolean?,
	pauseSeconds: number?,
	-- Multiplies shipment.priceMultiplier (e.g. 0.94 = 6% effective payout hit at resolution).
	priceMultiplierFactor: number?,
	totalLoss: boolean?,
	-- Whole barrels lost: ceil(manifestTotal * fraction), removed HeavyCrude → LightSweet → PremiumRefined.
	looseBarrelLossFraction: number?,
	-- If true, server handles missile flight with hit/smallHit/miss outcomes instead of instant totalLoss.
	missileEvent: boolean?,
	-- If true, server handles mine surfacing with hit/miss outcomes.
	mineEvent: boolean?,
	-- If true, server handles pirate boarding visual sequence.
	pirateEvent: boolean?,
	-- If true, server handles thunder/rain storm sequence with independent delay + barrel loss rolls.
	stormEvent: boolean?,
	-- If true, server handles tornado sequence with independent delay + barrel loss rolls.
	tornadoEvent: boolean?,
	-- If true, server handles coast guard inspection boarding sequence.
	coastGuardEvent: boolean?,
	-- If true, server handles US Navy ship slap sequence (total loss).
	usShipSlapEvent: boolean?,
}

local StraitEventConfig = require(script.Parent.Parent:WaitForChild("StraitEventConfig"))
local EXT = StraitEventConfig.ExtendedWaypointPauseSeconds

local Catalog = {}

-- Missile strike outcome config
Catalog.MissileConfig = {
	MissileCount = 4,       -- missiles fired per trigger (up to 8 triggers × 4 if all fire)
	-- Per missile: roll hit → total loss; else small hit → partial loss; else miss.
	-- HitChance chosen so P(no direct hit in 4) ≈ 50% (~50% survival vs total loss from barrage).
	HitChance = 0.16,       -- ~50% chance at least one of 4 is a direct hit → total loss
	SmallHitChance = 0.25,  -- 25% small hit → lose 50% barrels
	-- remainder = clean miss for that missile
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
	HitChance = 0.50,        -- 50% path hit → total loss; 50% survive (no loss after sequence)
	RiseSeconds = 5.0,       -- SLOW rise to the surface
	SpawnRadiusMin = 30,     -- minimum distance from ship
	SpawnRadiusMax = 120,    -- maximum distance — wide spread around the ship
	SpawnDepth = 40,         -- how far below water they start
	PauseAfterSurface = 4.0, -- how long ship pauses while navigating through
	MineScale = 0.4,         -- scale factor on mine model (40% of original size)
}

-- US Navy ship slap sequence config
Catalog.USShipSlapConfig = {
	SequenceDuration = 8,   -- server waits this long before cancelling shipment
	ApproachSeconds = 3,
	HandGrowSeconds = 1.5,
	WindupSeconds = 0.5,
	SlapSeconds = 0.3,
	FlySeconds = 2,
}

-- Coast guard inspection visual sequence config
Catalog.CoastGuardInspectionConfig = {
	OfficerCount = 6,
	-- approach 3 + board/insp 8.5 + zipline-back 1 + CG-boat depart 2.5 + buffer 1 = 16
	SequenceDuration = 16,
	ApproachSeconds = 3,
	BoardingSeconds = 2.5,
	InspectSeconds = 5.5,
	ReturnSeconds = 1.5,
}

-- Pirate raid visual sequence config
Catalog.PirateRaidConfig = {
	PirateCount = 4,
	-- approach 4 + board 3 + steal 7 + escape 4 = 18. Add 2s buffer for pirate boat
	-- to fully depart before player boat resumes.
	SequenceDuration = 20,
	ApproachDistance = 200,
	PullUpDistance = 15,
	ApproachSeconds = 4,
	BoardingSeconds = 3,
	StealingSeconds = 7,
	EscapeSeconds = 4,
}

-- Storm visual + gameplay config (delay and barrel-loss outcomes are rolled independently).
Catalog.StormConfig = {
	BaseSequenceSeconds = 10.0,
	DelayChance = 0.55,
	DelaySecondsMin = 3.5,
	DelaySecondsMax = 8.0,
	BarrelLossChance = 0.45,
	BarrelLossFractionMin = 0.05,
	BarrelLossFractionMax = 0.16,
}

-- Tornado visual + gameplay config. Unlike storms, tornadoes always strip
-- barrels — there's no `BarrelLossChance` gate. `MinBarrelsLost` guarantees a
-- floor on small manifests where `ceil(onShip * fraction)` could round low.
Catalog.TornadoConfig = {
	BaseSequenceSeconds = 11.5,
	DelayChance = 0.5,
	DelaySecondsMin = 4.0,
	DelaySecondsMax = 9.0,
	BarrelLossFractionMin = 0.12,
	BarrelLossFractionMax = 0.3,
	MinBarrelsLost = 5,
	MaxVisualBarrels = 10,
}

Catalog.Events = {
	-- Low: paperwork FX (StraitWaypointWorldFx EVENT_FX + optional StraitWaypointsFx assets)
	{
		id = "RoutinePaperwork",
		severity = "Low",
		displayName = "Routine paperwork",
		priceMultiplierFactor = 0.97,
	} :: StraitEventDef,
	-- Low: former "Coast guard glance" — same boarding inspection cinematic as full inspection
	{
		id = "CoastGuardInspection",
		severity = "Low",
		displayName = "Coast guard inspection",
		coastGuardEvent = true,
	} :: StraitEventDef,
	-- Low: former "High winds" — uses tornado rolls + `TornadoEvent` / Tornado VFX (catalog id stays for manifests / logs)
	{
		id = "HighWinds",
		severity = "Low",
		displayName = "High winds",
		tornadoEvent = true,
	} :: StraitEventDef,
	-- Medium: no bespoke world FX yet; payout + extended pause only
	{
		id = "EngineRoomSmoke",
		severity = "Medium",
		displayName = "Engine room smoke",
		pauseSeconds = EXT,
		priceMultiplierFactor = 0.9,
	} :: StraitEventDef,
	{
		id = "PirateRaid",
		severity = "Medium",
		displayName = "Pirate raid",
		looseBarrelLossFraction = 0.25,
		pirateEvent = true,
	} :: StraitEventDef,
	-- Medium: storm cinematic + storm gameplay rolls (replaces old fixed-fraction `TurbulentSeas` barrel spill)
	{
		id = "Storm",
		severity = "Medium",
		displayName = "Thunderstorm",
		stormEvent = true,
	} :: StraitEventDef,
	-- High: US Navy slap cinematic (absorbs old plain "Boarding and seizure" total-loss row)
	{
		id = "USShipSlap",
		severity = "High",
		displayName = "Government seizure",
		totalLoss = true,
		usShipSlapEvent = true,
	} :: StraitEventDef,
	{
		id = "Tornado",
		severity = "High",
		displayName = "Strait tornado",
		tornadoEvent = true,
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

function Catalog.GetPlaytestTitle(def: StraitEventDef): string
	if def.playtestTitle and def.playtestTitle ~= "" then
		return def.playtestTitle
	end
	return def.displayName
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
