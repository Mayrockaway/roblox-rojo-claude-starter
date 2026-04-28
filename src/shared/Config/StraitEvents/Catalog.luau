--!strict

-- **Single source of truth** for strait waypoint shipment events (trigger ordinals from
-- `StraitEventConfig.LaneWaypointTriggers`, per-bracket allow-list:
-- Open={3,6,9} / Restricted={3,5,6,7,9} / Closed={2..9}).
-- Add new events here: flags drive server behavior; `MissileConfig` / `StormConfig` / … hold tuning; optional `StraitWaypointsFx/<id>` for generic FX.
-- Human-oriented writeups: docs/features/strait-waypoint-events/EVENTS.md (keep in sync when changing rows).

export type Severity = "Low" | "Medium" | "High"

export type StraitEventDef = {
	id: string,
	severity: Severity,
	displayName: string,
	--- Optional banner line for playtest HUD (defaults to `displayName` if omitted).
	playtestTitle: string?,
	--- Relative pick weight inside the same-severity pool. `nil` defaults
	--- to 1 (legacy uniform behavior). The picker normalizes against
	--- `Σ(weight)` of the pool, so set these as plain ratios — e.g.
	--- `{Tornado=2, MineStrike=1, MissileStrike=1, USShipSlap=1}` would
	--- make Tornado fire 40% of the time within the High pool while
	--- the three total-loss events split the remaining 60% evenly.
	--- Negative or zero weights are coerced to "skip" (event won't be
	--- picked) so you can hot-mute an event without removing the row.
	weight: number?,
	skipWaypointPause: boolean?,
	pauseSeconds: number?,
	-- Multiplies shipment.priceMultiplier (e.g. 0.94 = 6% effective payout hit at resolution).
	priceMultiplierFactor: number?,
	totalLoss: boolean?,
	-- Whole barrels lost: ceil(manifestTotal * fraction), removed Crude → Refined → Premium.
	looseBarrelLossFraction: number?,
	-- Range variant: server rolls uniform between min and max instead of using flat fraction.
	looseBarrelLossFractionMin: number?,
	looseBarrelLossFractionMax: number?,
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
	HitChance = 0.60,        -- 60% path hit → total loss; 40% survive (no loss after sequence)
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
	-- Interactive slap mini-game: owner clicks/taps pirates to knock them off the ship
	-- before they grab barrels. Un-slapped pirates steal proportional barrel loss.
	InteractiveEnabled = true,
	--- Seconds the owner has to slap pirates after boarding completes.
	--- Must fit within SequenceDuration (20s) minus approach(4)+board(3)+escape(4)=9s
	InteractionWindowSeconds = 9,
	--- Arc height (studs) for the slap knockoff trajectory.
	PirateSlapKnockbackArc = 18,
	--- Minimum seconds between slaps (anti-macro / click-spam guard).
	SlapCooldownSeconds = 0.4,
	--- Server timeout buffer (seconds) added to InteractionWindowSeconds before
	--- applying full barrel loss for AFK/disconnect.
	ServerTimeoutBufferSeconds = 3,
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

-- High Winds (Low severity) — softer version of tornado. 50% chance of no
-- barrel loss at all; when it does hit, 0-20% loss with no minimum floor.
Catalog.HighWindsConfig = {
	BaseSequenceSeconds = 11.5,
	DelayChance = 0.5,
	DelaySecondsMin = 4.0,
	DelaySecondsMax = 9.0,
	BarrelLossChance = 0.5,
	BarrelLossFractionMin = 0.0,
	BarrelLossFractionMax = 0.2,
	MinBarrelsLost = 0,
	MaxVisualBarrels = 10,
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

-- Nuke config (purchasable via Army General NPC)
Catalog.NukeConfig = {
	CountdownSeconds = 12, -- 2s audio buildup + 10s visible countdown = detonation at 12s
	CooldownSeconds = 300, -- 5 minutes between nukes
	SequenceDuration = 15, -- 12s countdown + 3s aftermath
	MushroomCloudScale = 2.0,
	ScreenShakeIntensity = 8,
	ScreenShakeDuration = 2,
	FlashDuration = 1.5,
	BoatFlyArcHeight = 200,
	BoatFlyDuration = 2.5,
}

-- Airstrike config (purchasable via Army General NPC, targets specific player)
--
-- Player-purchased airstrikes are **GUARANTEED** to destroy the target's
-- shipment — `ArmyGeneralService:_handleAirstrike` hardcodes `local hit =
-- true` and broadcasts `outcome = "hit"`. `HitChance` is kept here at 1.0
-- as a self-documenting constant so the config matches behavior; a previous
-- 0.70 value was a stale draft that no callsite read. If a future change
-- reintroduces a `rng:NextNumber() < cfg.HitChance` gate (e.g. a counter-
-- ability or accuracy modifier), tune through this knob — do not undo the
-- `local hit = true` in `ArmyGeneralService` without also flipping the UI
-- copy ("AIRSTRIKE HIT!" / "Airstrike missed") and the victim death-cam
-- assumptions in `StrategicStrikeClient.airStrikeEvent` handler.
Catalog.AirStrikeConfig = {
	-- Cash cost paid by `ArmyGeneralService:_handleAirstrike` via
	-- `OilStateService:TrySpendCash`. Robux variants
	-- (`consumable.airstrike_x1`) pay in Robux at the receipt boundary and
	-- bypass this number AND the same-target cooldown below — by design,
	-- Robux is the "skip the cooldown" path.
	Cost = 20000,
	--- Seconds before the same contractor can land another **cash** airstrike
	--- on the same victim. Mirrors `HitContractConfig.SameTargetHireCooldownSeconds`
	--- so paid-spam griefing has the same anti-spam guardrail across both
	--- NPC contracts. Robux airstrikes neither check nor stamp this.
	SameTargetCooldownSeconds = 120,
	HitChance = 1.0,
	JetAltitude = 300,
	JetSpeed = 700,
	BombFallDuration = 2.0,
	SequenceDuration = 14, -- 2s warning + ~8s jet flight (halved speed) + 4s aftermath
}

--- TUNING NOTE — `weight` field on every row defaults to `1` (uniform
--- inside the same severity pool). Bump a value to make that event
--- relatively more likely than its siblings; drop to `0` to mute. The
--- `Catalog.PickRandom` math normalizes against the pool total, so
--- weights are pure ratios — `2` vs `1` = "fires twice as often within
--- this severity bucket". Per-bracket occurrence chance and severity
--- distribution are still controlled by `StraitEventConfig` (this only
--- affects which event from the chosen severity rolls).
Catalog.Events = {
	-- Low: paperwork FX (StraitWaypointWorldFx EVENT_FX + optional StraitWaypointsFx assets)
	{
		id = "RoutinePaperwork",
		severity = "Low",
		displayName = "Routine paperwork",
		weight = 1,
		priceMultiplierFactor = 0.97,
	} :: StraitEventDef,
	-- Low: former "Coast guard glance" — same boarding inspection cinematic as full inspection
	{
		id = "CoastGuardInspection",
		severity = "Low",
		displayName = "Coast guard inspection",
		weight = 1,
		coastGuardEvent = true,
	} :: StraitEventDef,
	-- Low: former "High winds" — uses tornado rolls + `TornadoEvent` / Tornado VFX (catalog id stays for manifests / logs)
	{
		id = "HighWinds",
		severity = "Low",
		displayName = "High winds",
		weight = 1,
		tornadoEvent = true,
	} :: StraitEventDef,
	-- Medium: no bespoke world FX yet; payout + extended pause only
	{
		id = "EngineRoomSmoke",
		severity = "Medium",
		displayName = "Engine room smoke",
		weight = 1,
		pauseSeconds = EXT,
		priceMultiplierFactor = 0.9,
	} :: StraitEventDef,
	{
		id = "PirateRaid",
		severity = "Medium",
		displayName = "Pirate raid",
		weight = 1,
		looseBarrelLossFractionMin = 0.05,
		looseBarrelLossFractionMax = 0.25,
		pirateEvent = true,
	} :: StraitEventDef,
	-- Medium: storm cinematic + storm gameplay rolls (replaces old fixed-fraction `TurbulentSeas` barrel spill)
	{
		id = "Storm",
		severity = "Medium",
		displayName = "Thunderstorm",
		weight = 1,
		stormEvent = true,
	} :: StraitEventDef,
	-- High: US Navy slap cinematic (absorbs old plain "Boarding and seizure" total-loss row).
	-- Lowest weight in the High pool — Sea Monster is the rare "spectacle"
	-- total loss; Mine and Missile already cover the bulk of that fantasy.
	{
		id = "USShipSlap",
		severity = "High",
		displayName = "Sea Monster",
		weight = 0.5,
		totalLoss = true,
		usShipSlapEvent = true,
	} :: StraitEventDef,
	-- Tornado is the only non-total-loss High event (independent barrel-loss
	-- + delay rolls instead of "instant ship gone"). Heavily weighted so
	-- Closed-strait High rolls don't feel like 75% guaranteed total loss.
	{
		id = "Tornado",
		severity = "High",
		displayName = "Strait tornado",
		weight = 2,
		tornadoEvent = true,
	} :: StraitEventDef,
	{
		id = "MineStrike",
		severity = "High",
		displayName = "Mine strike",
		weight = 0.75,
		totalLoss = true,
		mineEvent = true,
	} :: StraitEventDef,
	{
		id = "MissileStrike",
		severity = "High",
		displayName = "Missile strike",
		weight = 0.75,
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

--- Weighted random pick from the same-severity pool. Each `def.weight`
--- defaults to 1 (legacy uniform behavior), so adding the field to the
--- type without authoring per-row weights is a no-op. Authors can tune
--- relative ratios (e.g. weight 2 vs 1 → 2x as likely within the pool)
--- to bias Closed-strait High rolls away from the three total-loss
--- events and toward Tornado, etc., without touching this function.
---
--- A pool whose total weight is `0` (every entry weight ≤ 0) silently
--- falls back to uniform across the full pool — defensive so a bad
--- config never returns `nil` and breaks the shipment-event chain.
function Catalog.PickRandom(severity: Severity, rng: Random): StraitEventDef?
	local pool = Catalog.GetPool(severity)
	if #pool == 0 then
		return nil
	end

	local total = 0
	for _, def in ipairs(pool) do
		local w = tonumber(def.weight) or 1
		if w > 0 then
			total += w
		end
	end
	if total <= 0 then
		--- Defensive fallback: every entry was 0/negative. Don't return
		--- nil (would cancel the event silently); pick uniformly so the
		--- event chain still resolves while authors investigate.
		return pool[rng:NextInteger(1, #pool)]
	end

	local roll = rng:NextNumber(0, total)
	local cursor = 0
	for _, def in ipairs(pool) do
		local w = tonumber(def.weight) or 1
		if w <= 0 then
			continue
		end
		cursor += w
		if roll <= cursor then
			return def
		end
	end
	-- FP-drift safety: NextNumber's upper bound is exclusive in Roblox
	-- but we use `<=` above to catch the rare exact-`total` case; this
	-- final return guards against a microscopic precision miss.
	return pool[#pool]
end

return Catalog
