--!strict
--- GlobalEventConfig
---
--- Single source of truth for **server-wide** timed events that affect every
--- player at once (Cash Frenzy, Pirate Wave, Express Convoy, …). Mirrors the
--- pattern of `MonetizationCatalog` / `StraitEventConfig`: pure data, no
--- behavior — `GlobalEventService` consumes it.
---
--- Architecture overview
--- =====================
---   * `GlobalEventService` (server) owns the rotation timer + active-event
---     table. It re-reads this module on each rotation tick so designers can
---     hot-reload tuning by editing this file (Rojo sync only; no service
---     restart required for `weight` / `durationSeconds` / `cooldownSeconds`
---     changes — `MutuallyExclusiveGroups` and adding/removing event ids
---     still need a server bounce because the active-event table caches by
---     event id at activation time).
---   * Effects are applied at narrow, well-known hook sites in gameplay
---     services (`OilStateService:AddCash` for cash multipliers,
---     `OilShipmentService:_handleDispatch` for ship stats, etc). Each
---     consumer queries `GlobalEventService:GetMultiplier(metric)` or
---     `GlobalEventService:IsActive(eventId)` — they never read this config
---     directly so the service can layer caching / mutex policy without
---     leaking it.
---   * Clients receive a snapshot via the `GlobalEventStateUpdate` remote
---     (broadcast on activate / expire / rotation tick) and render the
---     `GlobalEventBanner` overlay with countdown + voice line. Client never
---     applies the effect — it only renders the chrome.
---
--- Adding a new event
--- ==================
---   1. Append a row to `Events` below with a stable `id` (the id appears in
---      telemetry and the active-events table; renaming an id mid-rotation
---      breaks de-dupe and `MutuallyExclusiveGroups`).
---   2. Pick the matching `effect.kind` (or add a new one + a single
---      consumer hook in the owning service).
---   3. If the new event must not coexist with another, add the pair to
---      `RotationConfig.MutuallyExclusiveGroups`.
---   4. Optionally bump telemetry — `EventCatalog.luau` already has
---      `global_event_started` / `global_event_ended` so analytics get the
---      new id automatically via the `eventId` field.

local GlobalEventConfig = {}

--==============================================================================
-- Effect kinds
--==============================================================================

--- Effect kinds applied by the server-side hooks. Each kind corresponds to
--- exactly one query method on `GlobalEventService` so the consumer code
--- stays trivial:
---
---   * `CashMultiplier`  → `GlobalEventService:GetMultiplier("Cash")`
---     Stacks **multiplicatively** with the `DoubleEarnings` GamePass in
---     `OilStateService:AddCash` (so a player who owns the GamePass during
---     Cash Frenzy gets ×4, not ×2 + ×2).
---
---   * `ShipStatsBoost`  → `GlobalEventService:GetShipStatsBoost()`
---     Returns a `{ speedMul, capacityMul, eventRiskMul }` table consumed by
---     `OilShipmentService:_handleDispatch` to overwrite `stats` *after*
---     `ShipStats.ResolveForBoat` (so the equipped boat's baked stats stay
---     authoritative; this is a temporary multiplicative override, not a
---     stat change). Post-Step-2 of the boat-progression refactor the
---     resolver reads directly from the equipped boat's catalog entry.
---
	---   * `ForceStraitEvent` → `GlobalEventService:GetForcedStraitEventId()`
---     Returns the `StraitEventCatalog` id ("PirateRaid", "CoastGuardInspection",
---     etc.) to force at every reachable waypoint while the event is
---     active. `_handleStraitWaypointTrigger` resolves this BEFORE the
---     bracket allow-list and occurrence-chance gates so the event
---     actually fires on every waypoint (Open strait alone is ~0.75
---     events per voyage organically — gating Pirate Wave through that
---     would make it invisible). Severity still pulls from the engine
---     bracket so impact scales naturally (Open Pirate Wave = light
---     raids, Closed Pirate Wave = brutal). Read AFTER the
---     `eventImmunity` (Security Personnel) and FTUE-suppress checks so
---     defensive purchases still work — Pirate Wave is a "spike up the
---     value of Security Personnel" lever, not a "punish everyone
---     equally" lever.
export type EffectKind = "CashMultiplier" | "ShipStatsBoost" | "ForceStraitEvent"

--- Banner kinds drive UI flavor on the client. Server passes the kind in the
--- broadcast payload so the client doesn't need to know event-id semantics.
---
---   * `Buff`        — green-tinted banner, friendly SFX (Cash Frenzy,
---                     Express Convoy).
---   * `Threat`      — red-tinted banner, ominous SFX (Pirate Wave). Players
---                     should think "defend or wait" not "go fast".
---   * `Cooperative` — gold-tinted banner with progress bar (future: Server
---                     Goal events). Listed here so the client banner
---                     module's switch covers all three from day one.
export type BannerKind = "Buff" | "Threat" | "Cooperative"

export type EventEffect = {
	kind: EffectKind,

	--- "CashMultiplier" — multiplier value (e.g. `2` for ×2 cash). 1 is a
	--- no-op (handy for documentation parity if you wanted to ship an event
	--- that's purely flavor / banner). Negative or zero values are coerced
	--- to 1 by the consumer for safety.
	value: number?,

	--- "ShipStatsBoost" — per-axis multipliers. `nil` axes are treated as
	--- 1.0 (no change). Values < 1.0 are allowed (e.g. a "Sluggish Currents"
	--- threat could pass `speedMul = 0.6`); the consumer clamps the
	--- resulting `travelSeconds` against `ShipStats` minimums to avoid
	--- pathological 0-second voyages.
	speedMul: number?,
	capacityMul: number?,
	--- Multiplier applied to `stats.eventRisk`. Express Convoy passes 1.0
	--- (event chance unchanged); a future "Storm Run" event could bump this
	--- to 1.5 to make the speed boost feel more dangerous.
	eventRiskMul: number?,

	--- "ForceStraitEvent" — id from `StraitEventCatalog` to force at every
	--- waypoint trigger that *would have* rolled an event. We do NOT bypass
	--- the bracket gate (`IsTriggerEnabledForBracket`) so a Pirate Wave
	--- during `Open` strait fires only on the Open allow-list waypoints,
	--- which keeps the "more events overall" feeling proportional to the
	--- current strait state.
	straitEventId: string?,
}

export type EventDefinition = {
	--- Stable internal id. Appears in:
	---   * `GlobalEventService` active-events table key
	---   * `MutuallyExclusiveGroups` membership tests
	---   * Telemetry `eventId` field on `global_event_*` rows
	---   * `/event <id>` debug chat command
	--- Renaming is **not** safe mid-rotation; treat like
	--- `MonetizationItem.id`.
	id: string,

	--- Human display strings used by the client banner. Server includes
	--- them in the broadcast so the client doesn't re-require this module.
	displayName: string,
	subtitle: string,

	--- Banner flavor (color / SFX) on the client.
	bannerKind: BannerKind,

	--- Single effect payload. Each event has exactly one effect today;
	--- promote to `effects: { EventEffect }` when an event needs to stack
	--- (e.g. a future "Refinery Bonus" that's both `CashMultiplier` AND
	--- `ShipStatsBoost`). Keeping the simple shape until that's needed.
	effect: EventEffect,

	--- Wall-clock duration in seconds. The service uses
	--- `workspace:GetServerTimeNow()` so server lag does not extend events,
	--- and the client renders the same `expiresAt` so banner countdowns
	--- stay synced.
	durationSeconds: number,

	--- Weighted-random pick weight when the rotation timer fires. Higher
	--- = more frequent. Set to 0 to keep an event in the catalog for
	--- testing (`/event <id>` still works) without rolling it organically.
	weight: number,

	--- Minimum seconds between two activations of *this same event id*.
	--- Independent of the inter-event cooldown
	--- (`RotationConfig.minSecondsBetweenEvents`) so high-weight events
	--- don't spam back-to-back.
	cooldownSeconds: number,

	--- Optional hint surfaced to the client banner so players understand
	--- what the event means without opening a wiki. Kept in the config
	--- (not the service) so design owns copy-on-screen.
	helpText: string?,
}

--==============================================================================
-- Events
--==============================================================================

GlobalEventConfig.Events = {
	--- Cash Frenzy — all earnings ×2 server-wide for 30 seconds.
	---
	--- Stacks multiplicatively with the `DoubleEarnings` GamePass in
	--- `OilStateService:AddCash` (GamePass owners get ×4 during the event).
	--- Refunds and Robux currency packs continue to opt out via
	--- `AddCash(uid, n, { skipMultiplier = true })` so neither the Frenzy
	--- nor the GamePass apply to those credits — same contract as today.
	---
	--- Tuning intent: lower frequency than Express Convoy (weight 6 vs
	--- 10) — Cash Frenzy is the highest-impact `Buff` (literal ×2 on
	--- every earning hook including sales, contracts, and oil-tank
	--- payouts), so making it the rarer of the two `Buff` events keeps
	--- it feeling like a payday moment instead of the default state. Was
	--- weight 10; reduced after playtesters reported it eclipsing
	--- Express Convoy in roll frequency. 8-min self-cooldown still
	--- prevents the same player from seeing two Cash Frenzies
	--- back-to-back. Duration was 60s → 30s to make the buff feel like
	--- a "scramble window" — long enough to dispatch a shipment / sell
	--- a stockpile, short enough that it still feels rare and worth
	--- pre-stacking inventory for.
	cash_frenzy = {
		id = "cash_frenzy",
		displayName = "Cash Frenzy",
		subtitle = "All earnings x2!",
		bannerKind = "Buff",
		effect = { kind = "CashMultiplier", value = 2 },
		durationSeconds = 30,
		weight = 6,
		cooldownSeconds = 480,
		helpText = "Sell oil, ship cargo, or finish contracts NOW for double cash!",
	},

	--- Pirate Wave — every strait waypoint event roll for the next 30
	--- seconds is forced to `PirateRaid`. Players who own the
	--- `Security Personnel` consumable (`OilStateService:GetRunUpgradeOwned(
	--- userId, "security_personnel") > 0`) still get full deflection on
	--- their next dispatched shipment — the override fires AFTER the
	--- `eventImmunity` short-circuit in `_handleStraitWaypointTrigger`.
	---
	--- Bracket gate (`StraitEventConfig.IsTriggerEnabledForBracket`) is
	--- preserved so a Pirate Wave during `Open` strait still uses the
	--- sparse Open waypoint allow-list — the goal is "spike Pirate
	--- frequency", not "make the strait feel like Closed for the
	--- duration of the event".
	---
	--- Tuning intent: this is the only `Threat`-flavor event today, so it's
	--- intentionally the rarest of the three (weight 3 vs Cash Frenzy's
	--- 10 / Express Convoy's 8 → ~14% of rolls). Lowered from weight 6
	--- after playtesters reported it landing too often relative to the
	--- two `Buff` events. Duration was 60s → 30s for the same reason —
	--- shorter window means a single Pirate Wave doesn't dominate a
	--- rotation slot if the player happens to have a shipment in flight.
	pirate_wave = {
		id = "pirate_wave",
		displayName = "Pirate Wave",
		subtitle = "Pirates raiding all shipments!",
		bannerKind = "Threat",
		effect = { kind = "ForceStraitEvent", straitEventId = "PirateRaid" },
		durationSeconds = 30,
		weight = 3,
		cooldownSeconds = 720,
		helpText = "Ship now and get raided, or wait it out. Security Personnel still defends.",
	},

	--- Express Convoy — ship speed ×2 + cargo capacity ×1.5 for 90 seconds.
	---
	--- Speed multiplier is applied as `travelSeconds := travelSeconds /
	--- speedMul` in `OilShipmentService:_handleDispatch` (so ×2 speed = half
	--- the voyage time). Capacity multiplier raises the per-shipment cap
	--- AFTER the player's `shipCapacityLevel` is resolved, so a maxed ship
	--- still benefits proportionally. Capacity dispatches that exceed the
	--- normal limit by virtue of the boost are valid for the duration of
	--- the event — the dispatch fee scales with the requested manifest oil
	--- units (existing `ShipStats.ComputeDispatchFeeFromManifestOilUnits`),
	--- not capacity, so larger shipments still cost more cash.
	---
	--- `eventRiskMul = 1.0`: voyages during Express Convoy face the same
	--- per-waypoint roll chance — the boost is pure upside. If a future
	--- "Storm Run" event uses ShipStatsBoost with `eventRiskMul > 1`, that
	--- event's banner copy should warn players in `subtitle` /
	--- `helpText`.
	express_convoy = {
		id = "express_convoy",
		displayName = "Express Convoy",
		subtitle = "Ship speed x2, cargo capacity x1.5!",
		bannerKind = "Buff",
		effect = {
			kind = "ShipStatsBoost",
			speedMul = 2.0,
			capacityMul = 1.5,
			eventRiskMul = 1.0,
		},
		durationSeconds = 60,
		weight = 10,
		cooldownSeconds = 600,
		helpText = "Dispatch big shipments now — they arrive in half the time.",
	},
} :: { [string]: EventDefinition }

--==============================================================================
-- Rotation
--==============================================================================

GlobalEventConfig.RotationConfig = {
	--- Minimum seconds of "no global event" between two activations. The
	--- service picks a uniform random in `[min, max]` after the previous
	--- event ends to avoid metronome-feel. Today min == max (flat 4 min)
	--- — events rotate on a steady 4-minute beat and randomness comes
	--- entirely from the weighted event picker, not the spacing.
	minSecondsBetweenEvents = 240, -- 4 min
	maxSecondsBetweenEvents = 240, -- 4 min

	--- Skip rotation when fewer than this many players are in the server.
	--- Avoids "you joined an empty server, here's a Pirate Wave for you
	--- alone" feel. Set to 1 if you want events to always rotate.
	minPlayersToActivate = 2,

	--- Hard cap on simultaneously active events. Today there's no real
	--- "stack two events" use case — the rotation picks one at a time —
	--- but a future "Boss Convoy + Pirate Wave double feature" could lift
	--- this. The service refuses to activate beyond the cap.
	maxConcurrentEvents = 1,

	--- Pairs of event ids that must NEVER coexist (server enforces by
	--- rejecting a pick that would activate while a member of the same
	--- group is already active). Empty today since the 3 starter events
	--- are fine to compose with each other (Cash Frenzy + Pirate Wave is
	--- intentionally a great moment — "earn 2x but defend!"); add entries
	--- when adding mutually-exclusive future events (e.g.
	--- `{"calm_seas", "storm_front"}`).
	mutuallyExclusiveGroups = {} :: { { string } },

	--- Wall-clock seconds to delay the FIRST event after server start. Lets
	--- the place fully load and players settle in before the rotation
	--- kicks in. Independent of `minSecondsBetweenEvents` because at boot
	--- there is no "previous event end time" yet. Lowered to 2 min to
	--- match the snappier 4-min rotation — first event lands while the
	--- earliest joiners are still in their first session.
	bootDelaySeconds = 120, -- 2 min after server start

	--- How often the service ticks its rotation timer. Coarse on purpose —
	--- this is a 5–12 minute cadence loop, sub-second precision is wasted.
	--- Lowering this just costs `Heartbeat` cycles for no design benefit.
	tickIntervalSeconds = 1.0,
}

--==============================================================================
-- Helpers
--==============================================================================

--- Iterate `Events` in a stable order (sorted by id). Useful for the
--- weighted-random picker so identical seeds produce identical sequences in
--- replay tests, and for telemetry dumps.
function GlobalEventConfig.GetEventIdsSorted(): { string }
	local ids: { string } = {}
	for id, _ in pairs(GlobalEventConfig.Events) do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end

--- Snapshot a single event for the client (banner copy + duration + kind).
--- Excludes `effect` payload so the client never sees the raw multiplier
--- — server stays the only place that applies effects.
export type EventSnapshot = {
	id: string,
	displayName: string,
	subtitle: string,
	bannerKind: BannerKind,
	durationSeconds: number,
	helpText: string?,
}

function GlobalEventConfig.SnapshotEvent(eventId: string): EventSnapshot?
	local def = GlobalEventConfig.Events[eventId]
	if not def then
		return nil
	end
	return {
		id = def.id,
		displayName = def.displayName,
		subtitle = def.subtitle,
		bannerKind = def.bannerKind,
		durationSeconds = def.durationSeconds,
		helpText = def.helpText,
	}
end

return GlobalEventConfig
