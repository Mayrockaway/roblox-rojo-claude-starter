--!strict
-- Telemetry event catalog — pure data, no behavior.
--
-- Single source of truth for **what events exist** and **which backend
-- categories they fan out to**. Mirrors the catalog in
-- `docs/features/telemetry/SPEC.md` §6 (subsections 6.1 — 6.7) and the
-- internal-vocabulary → GameAnalytics category map in §4.6.7.
--
-- `Shared.Telemetry` (init.luau) reads this at every `Track` call to:
--   * resolve the GA category for the event,
--   * tag the event with its internal `category` (funnel / economy / …)
--     for downstream buffering decisions,
--   * pick up the SPEC-locked sample-rate hint (the **runtime** sample
--     rate still resolves through `TelemetryConfig:GetSampleRate(name)`
--     so the locked rates from SPEC §11.A.2 / `TelemetryConfig.SampleRates`
--     stay single-sourced).
--
-- Adding a new event:
--   1. Add the row to `docs/features/telemetry/SPEC.md` §6 first.
--   2. Add a row to `Events` below with the matching `category` /
--      `gaCategory` from §4.6.7.
--   3. Wire the call site in the owner service (PR 5+).
--
-- `GetEvent(name)` returns `nil` when the event is not registered; the
-- caller decides whether to warn or silently fall back. `Shared.Telemetry`
-- treats unknown events as `category = "custom"`, `gaCategory = "design"`
-- and emits a one-shot warning (so we notice the gap without breaking
-- the pipeline mid-incident).

--==============================================================================
-- Types
--==============================================================================

export type EventCategory =
	"funnel" | "economy" | "progression" | "custom" | "session" | "error"

export type GaCategory =
	"business" | "resource" | "design" | "progression" | "error" | "session_start" | "session_end"

export type EventDefinition = {
	--- Internal classification — drives which `Telemetry.*` helper is the
	--- "preferred" call site and (in PR 4) which GA buffer slot the event
	--- lands in. `funnel` / `progression` events are also surfaced via the
	--- typed Roblox `AnalyticsService` calls.
	category: EventCategory,

	--- GameAnalytics REST v2 category — see SPEC §4.6.7. `session_start`
	--- and `session_end` are GA built-ins; everything else is one of
	--- `business` / `resource` / `design` / `progression` / `error`.
	gaCategory: GaCategory,

	--- Default sample rate hint, in [0, 1]. The runtime resolver in
	--- `Shared.Telemetry` calls `TelemetryConfig:GetSampleRate(name)` so
	--- the locked rates from SPEC §11.A.2 stay authoritative — this field
	--- exists for documentation parity with §6.
	sampleRate: number,

	--- Optional list of property keys the event **should** carry. Treated
	--- as a documentation aid in PR 3 (no enforcement); PR 5+ wiring may
	--- check this in Studio mode to catch missed fields early.
	requiredFields: { string }?,
}

--==============================================================================
-- Catalog
--==============================================================================

local EventCatalog = {}

--- Sample-rate hint copied from `TelemetryConfig.SampleRates` (SPEC §11.A.2).
--- Kept here only so this module is self-contained for documentation; the
--- runtime resolver in `Shared.Telemetry` always re-queries `TelemetryConfig`.
local SAMPLE_HIGH_VOLUME_STRAIT = 0.1
local SAMPLE_HIGH_VOLUME_OIL_PUMP = 0.05

EventCatalog.Events = {
	--==========================================================================
	-- 6.1 Onboarding / session
	--==========================================================================
	session_start = { category = "session", gaCategory = "session_start", sampleRate = 1.0 },
	session_end   = { category = "session", gaCategory = "session_end",   sampleRate = 1.0 },
	first_join    = { category = "custom",  gaCategory = "design",        sampleRate = 1.0 },
	ftue_started  = { category = "custom",  gaCategory = "design",        sampleRate = 1.0 },
	client_ready  = { category = "custom",  gaCategory = "design",        sampleRate = 1.0 },

	--==========================================================================
	-- 6.2 FTUE funnel
	--==========================================================================
	funnel_ftue          = { category = "funnel",      gaCategory = "progression", sampleRate = 1.0 },
	funnel_first_run     = { category = "funnel",      gaCategory = "progression", sampleRate = 1.0 },
	ftue_step_completed  = { category = "progression", gaCategory = "progression", sampleRate = 1.0 },
	ftue_step_abandoned  = { category = "progression", gaCategory = "progression", sampleRate = 1.0 },
	ftue_skipped         = { category = "progression", gaCategory = "progression", sampleRate = 1.0 },
	ftue_done            = { category = "progression", gaCategory = "progression", sampleRate = 1.0 },

	--==========================================================================
	-- 6.3 Voyage / engagement
	--==========================================================================
	shipment_dispatched          = { category = "custom",  gaCategory = "design", sampleRate = 1.0 },
	shipment_first_dispatched    = { category = "custom",  gaCategory = "design", sampleRate = 1.0 },
	shipment_voyage_started      = { category = "custom",  gaCategory = "design", sampleRate = 1.0 },
	strait_waypoint_evaluated    = { category = "custom",  gaCategory = "design", sampleRate = SAMPLE_HIGH_VOLUME_STRAIT },
	strait_event_fired           = { category = "custom",  gaCategory = "design", sampleRate = 1.0 },
	shipment_completed           = { category = "custom",  gaCategory = "design", sampleRate = 1.0 },
	shipment_total_loss          = { category = "custom",  gaCategory = "design", sampleRate = 1.0 },
	shipment_pirate_hit          = { category = "custom",  gaCategory = "design", sampleRate = 1.0 },
	shipment_pirate_hit_payout   = { category = "custom",  gaCategory = "design", sampleRate = 1.0 },
	security_personnel_consumed  = { category = "custom",  gaCategory = "design", sampleRate = 1.0 },
	security_personnel_deflected = { category = "custom",  gaCategory = "design", sampleRate = 1.0 },
	player_died                  = { category = "custom",  gaCategory = "design", sampleRate = 1.0 },

	--==========================================================================
	-- 6.4 Economy — sources and sinks
	--==========================================================================
	oil_pumped              = { category = "economy", gaCategory = "resource", sampleRate = SAMPLE_HIGH_VOLUME_OIL_PUMP },
	oil_pump_collected      = { category = "economy", gaCategory = "resource", sampleRate = SAMPLE_HIGH_VOLUME_OIL_PUMP },
	oil_sold                = { category = "economy", gaCategory = "resource", sampleRate = 1.0 },
	oilman_sold             = { category = "economy", gaCategory = "resource", sampleRate = 1.0 },
	instant_sold            = { category = "economy", gaCategory = "resource", sampleRate = 1.0 },
	dispatch_fee            = { category = "economy", gaCategory = "resource", sampleRate = 1.0 },
	equipment_purchased     = { category = "economy", gaCategory = "resource", sampleRate = 1.0 },
	equipment_purchase_failed = { category = "error", gaCategory = "error",   sampleRate = 1.0 },
	chunk_unlocked          = { category = "economy", gaCategory = "resource", sampleRate = 1.0 },
	warehouse_upgraded      = { category = "economy", gaCategory = "resource", sampleRate = 1.0 },
	oil_tank_upgraded       = { category = "economy", gaCategory = "resource", sampleRate = 1.0 },
	ship_speed_upgraded     = { category = "economy", gaCategory = "resource", sampleRate = 1.0 },
	ship_capacity_upgraded  = { category = "economy", gaCategory = "resource", sampleRate = 1.0 },
	-- `ship_skin_equipped` was renamed to `boat_equipped` + `boat_unlocked`
	-- by Step 6 of the boat-progression refactor (`OilStateService` emits
	-- `boat_equipped` from `:SetEquippedBoatId` and `boat_unlocked` from
	-- `:TryUnlockBoat`). The old key is kept here for back-compat with
	-- pre-Step-6 dashboards but is no longer emitted by live code.
	ship_skin_equipped      = { category = "custom",  gaCategory = "design",   sampleRate = 1.0 },
	boat_equipped           = { category = "custom",  gaCategory = "design",   sampleRate = 1.0 },
	boat_unlocked           = { category = "custom",  gaCategory = "design",   sampleRate = 1.0 },
	equipment_shop_rotated  = { category = "custom",  gaCategory = "design",   sampleRate = 1.0 },

	-- Daily reward calendar (`DailyRewardCalendarService`). One Track event per
	-- successful claim regardless of reward kind so the dashboard can answer
	-- "how far do players progress through the 7-slot calendar". Cash-bearing
	-- claims (kind=cash, plus the boatPool→cash fallback) ALSO emit
	-- `daily_reward_cash` through `Telemetry.Economy` so the soft-currency
	-- source flow on the Roblox dashboard counts the grant.
	daily_reward_claimed    = { category = "custom",  gaCategory = "design",   sampleRate = 1.0 },
	daily_reward_cash       = { category = "economy", gaCategory = "resource", sampleRate = 1.0 },

	-- Rebirth (`OilStateService:Rebirth` + `RebirthShopService`). One custom
	-- `rebirth_completed` event per successful rebirth (carries the new
	-- rebirthCount, tokens granted, balance after) so the dashboard can answer
	-- "rebirth distribution per player" and "how many tokens does the median
	-- player accumulate over a session". The two `rebirth_tokens_*` rows are
	-- the soft-currency flow on the `rebirth_tokens` currency — Source on the
	-- cash → tokens conversion at rebirth time, Sink on shop purchase. Each
	-- routes through `Telemetry.Economy` and the `endingBalance` is auto-
	-- attached by the wallet reader (registered for `cash`; the rebirth
	-- balance reader is registered alongside in `init.server.luau`).
	rebirth_completed         = { category = "custom",  gaCategory = "design",   sampleRate = 1.0 },
	rebirth_tokens_earned     = { category = "economy", gaCategory = "resource", sampleRate = 1.0 },
	rebirth_tokens_spent      = { category = "economy", gaCategory = "resource", sampleRate = 1.0 },

	-- Oil Heaven tile drilling (`OilHeavenDrillService` + `OilStateService:ClaimOilHeavenRewardTile`).
	-- One row per drilled tile so the dashboard can answer "what's the
	-- distribution of category x rarity x rebirthRequired across all
	-- drills?" — and trace per-tier conversion (drillers who hit S1 vs S5).
	-- `heaven_tile_doubled` fires only when a player buys the 2x DevProduct
	-- and the consumable handler resolves. The Robux receipt itself flows
	-- through `monetization_purchased` for revenue tracking; this event
	-- adds the gameplay-side context (which tile / category got doubled).
	-- `heaven_drill_consumed` fires every time a rebirth drill is spent on
	-- a tile drill (one per `ConsumeRebirthDrill` call). Useful for
	-- per-session drill velocity vs the existing `rebirth_drills` attribute,
	-- which only shows the wallet snapshot.
	heaven_tile_drilled       = { category = "custom",  gaCategory = "design",   sampleRate = 1.0 },
	heaven_tile_doubled       = { category = "custom",  gaCategory = "design",   sampleRate = 1.0 },
	heaven_drill_consumed     = { category = "custom",  gaCategory = "design",   sampleRate = 1.0 },

	--==========================================================================
	-- 6.5 Strait / world events
	--==========================================================================
	strait_state_changed = { category = "custom", gaCategory = "design", sampleRate = 1.0 },
	strait_force_lock    = { category = "custom", gaCategory = "design", sampleRate = 1.0 },
	nuke_fired           = { category = "custom", gaCategory = "design", sampleRate = 1.0 },
	airstrike_fired      = { category = "custom", gaCategory = "design", sampleRate = 1.0 },
	pirate_hire_created  = { category = "custom", gaCategory = "design", sampleRate = 1.0 },
	pirate_hire_refunded = { category = "custom", gaCategory = "design", sampleRate = 1.0 },
	pirate_hire_executed = { category = "custom", gaCategory = "design", sampleRate = 1.0 },

	-- Global events (`GlobalEventService`). One row per lifecycle stage so
	-- analytics can compute (a) activation rate per event id, (b) average
	-- duration delivered (start vs end), and (c) whether players are
	-- earning/dispatching during the buff window vs ignoring it. The
	-- `eventId` property carries the `GlobalEventConfig.Events[*].id`.
	global_event_started = { category = "custom", gaCategory = "design", sampleRate = 1.0 },
	global_event_ended   = { category = "custom", gaCategory = "design", sampleRate = 1.0 },

	--==========================================================================
	-- 6.6 Monetization
	--==========================================================================
	monetization_prompted          = { category = "custom",  gaCategory = "design",   sampleRate = 1.0 },
	monetization_prompt_failed     = { category = "error",   gaCategory = "error",    sampleRate = 1.0 },
	monetization_purchased         = { category = "custom",  gaCategory = "business", sampleRate = 1.0 },
	monetization_purchased_replay  = { category = "error",   gaCategory = "error",    sampleRate = 1.0 },
	monetization_grant_failed      = { category = "error",   gaCategory = "error",    sampleRate = 1.0 },
	monetization_first_purchase    = { category = "custom",  gaCategory = "design",   sampleRate = 1.0 },
	gamepass_purchased             = { category = "custom",  gaCategory = "business", sampleRate = 1.0 },
	gamepass_prompt_cancelled      = { category = "custom",  gaCategory = "design",   sampleRate = 1.0 },
	gamepass_owned_resolved        = { category = "custom",  gaCategory = "design",   sampleRate = 1.0 },

	--==========================================================================
	-- 6.7 Engagement / errors
	--==========================================================================
	profile_load_failed     = { category = "error",  gaCategory = "error",  sampleRate = 1.0 },
	profile_save_failed     = { category = "error",  gaCategory = "error",  sampleRate = 1.0 },
	oil_state_load_failed   = { category = "error",  gaCategory = "error",  sampleRate = 1.0 },
	auto_ship_engaged       = { category = "custom", gaCategory = "design", sampleRate = 1.0 },
	auto_ship_dispatched    = { category = "custom", gaCategory = "design", sampleRate = 1.0 },
	auto_ship_skipped       = { category = "custom", gaCategory = "design", sampleRate = 1.0 },
	dock_idle_to_active     = { category = "custom", gaCategory = "design", sampleRate = 1.0 },

	--==========================================================================
	-- Internal diagnostics — emitted by `Shared.Telemetry` itself when its
	-- guards trip (rate-limit, oversize, GA buffer overflow, circuit breaker).
	-- These bypass rate-limit + sample-rate so we never lose visibility into
	-- the very thing they warn about — see SPEC §8.
	--==========================================================================
	telemetry_dropped       = { category = "error", gaCategory = "error", sampleRate = 1.0 },
	telemetry_circuit_open  = { category = "error", gaCategory = "error", sampleRate = 1.0 },
} :: { [string]: EventDefinition }

--==============================================================================
-- Lookup helpers
--==============================================================================

--- Fetch an event definition. Returns `nil` for unregistered events; the
--- caller decides the fallback (`Shared.Telemetry` warns once and treats
--- as `custom`/`design`).
function EventCatalog.GetEvent(eventName: string): EventDefinition?
	return EventCatalog.Events[eventName]
end

--- Whether an event is in the catalog. Cheap boolean wrapper around
--- `GetEvent` for hot-path call sites.
function EventCatalog.IsRegistered(eventName: string): boolean
	return EventCatalog.Events[eventName] ~= nil
end

return EventCatalog
