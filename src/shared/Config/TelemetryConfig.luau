--!strict
-- Pure-constants config for the server-authoritative telemetry pipeline.
-- Values here are the resolved decisions from `docs/features/telemetry/SPEC.md`
-- (§3.3 + §11.A) — the spec is authority; this file is the load-bearing
-- runtime mirror that downstream modules (`Shared.Telemetry`,
-- `Shared.Telemetry.GameAnalyticsAdapter`) `require` for sample rates,
-- backoff curves, batch sizes, and the GameAnalytics endpoint base.
--
-- This module is intentionally **constants + tiny pure helpers only**:
-- no `HttpService`, no behavior, no I/O. The only runtime dependency is a
-- `RunService:IsStudio()` lookup inside `IsDebugActive` /
-- `ShouldHitNetworkInStudio` so individual call sites do not have to
-- re-resolve the Studio context.

local RunService = game:GetService("RunService")

--==============================================================================
-- Types
--==============================================================================

export type BackendsConfig = {
	--- Roblox `AnalyticsService` fan-out (Creator Dashboard). Production: `true`.
	Roblox: boolean,
	--- GameAnalytics REST v2 fan-out. Production: `true`.
	GameAnalytics: boolean,
}

export type DebugConfig = {
	--- When true, `Telemetry.Track` also `print`s every payload server-side.
	--- Auto-true in Studio via `IsDebugActive()` regardless of this flag.
	PrintLocally: boolean,
	--- When false, Studio routes GameAnalytics fan-out to `print` instead of
	--- live HTTP so playtests do not pollute prod / burn quota. Override
	--- per-session in the command bar via
	--- `_G.__OTS_TELEMETRY_FORCE_BACKENDS = true`; `ShouldHitNetworkInStudio()`
	--- resolves both inputs.
	ForceBackendsInStudio: boolean,
}

export type SampleRates = {
	[string]: number,
}

export type RateLimitsConfig = {
	PerPlayerEventsPerMinute: number,
	PerServerEventsPerMinute: number,
	--- Encoded payloads above this byte budget are dropped and emit a single
	--- `telemetry_dropped { reason = "oversize" }` event per (event, player,
	--- minute) — see SPEC §8.
	OversizePayloadBytes: number,
}

export type GameAnalyticsBatchConfig = {
	FlushSeconds: number,
	FlushAtCount: number,
	MaxBufferPerUser: number,
	MaxAgeSeconds: number,
}

export type GameAnalyticsBackoffConfig = {
	InitialSeconds: number,
	MaxSeconds: number,
	Multiplier: number,
}

export type GameAnalyticsSecretNames = {
	GameKey: string,
}

export type GameAnalyticsConfig = {
	EndpointBase: string,
	SdkVersion: string,
	Batch: GameAnalyticsBatchConfig,
	Backoff: GameAnalyticsBackoffConfig,
	SecretNames: GameAnalyticsSecretNames,
	SecretsModulePath: { string },
	SecretsModuleField: string,
}

export type AccountAgeBucket = {
	max: number,
	label: string,
}

export type SessionStartCustomDimensionsConfig = {
	AccountAgeBuckets: { AccountAgeBucket },
	MembershipLabels: { Premium: string, Standard: string },
}

export type TelemetryConfig = {
	Backends: BackendsConfig,
	Debug: DebugConfig,
	SampleRates: SampleRates,
	RateLimits: RateLimitsConfig,
	GameAnalytics: GameAnalyticsConfig,
	RobuxToUsd: number,
	SessionStartCustomDimensions: SessionStartCustomDimensionsConfig,

	IsDebugActive: (self: TelemetryConfig) -> boolean,
	ShouldHitNetworkInStudio: (self: TelemetryConfig) -> boolean,
	BucketAccountAge: (self: TelemetryConfig, accountAgeDays: number) -> string,
	GetSampleRate: (self: TelemetryConfig, eventName: string) -> number,
}

--==============================================================================
-- Config
--==============================================================================

local TelemetryConfig = {} :: TelemetryConfig

--------------------------------------------------------------------------------
-- Backends — dual fan-out (SPEC §4.1).
--
-- In production both flags MUST be true. Flipping either to `false` is a
-- single-line **kill-switch** for an incident — not a regular config toggle.
-- The two adapters run independently inside `Shared.Telemetry._fanOut`;
-- disabling one does not change the behavior of the other.
--------------------------------------------------------------------------------
TelemetryConfig.Backends = {
	Roblox = true,
	GameAnalytics = true,
}

--------------------------------------------------------------------------------
-- Debug (SPEC §4.1 / §9.4).
--
-- `IsDebugActive()` returns `Debug.PrintLocally or RunService:IsStudio()`,
-- so leaving `PrintLocally = false` here still gives Studio playtesters
-- structured `[Telemetry] …` Output.
-- `ShouldHitNetworkInStudio()` defaults to `false` in Studio so GA HTTP is
-- replaced by `print`; override with `_G.__OTS_TELEMETRY_FORCE_BACKENDS = true`
-- in the command bar for end-to-end QA against the live GA endpoint.
--------------------------------------------------------------------------------
TelemetryConfig.Debug = {
	PrintLocally = false,
	ForceBackendsInStudio = false,
}

--------------------------------------------------------------------------------
-- Sample rates (SPEC §6 / §11.A.2 — locked).
--
-- Any event NOT listed here defaults to **1.0** (always emit). Use
-- `GetSampleRate(eventName)` to resolve — never index `SampleRates` directly.
--
-- Do not silently re-tune these without a follow-up SPEC decision; they are
-- canonical and downstream queries scale up by the recorded `sampleRate`.
--------------------------------------------------------------------------------
TelemetryConfig.SampleRates = {
	strait_waypoint_evaluated = 0.1,
	oil_pumped = 0.05,
	oil_pump_collected = 0.05,
}

--------------------------------------------------------------------------------
-- Rate limits (SPEC §8).
--
-- `PerPlayerEventsPerMinute` and `PerServerEventsPerMinute` are independent
-- rolling 60s buckets. `OversizePayloadBytes` is checked on the
-- JSON-encoded payload before fan-out; oversize events drop and emit
-- `telemetry_dropped { reason = "oversize" }` once per (event, player, minute).
--------------------------------------------------------------------------------
TelemetryConfig.RateLimits = {
	PerPlayerEventsPerMinute = 30,
	PerServerEventsPerMinute = 5000,
	OversizePayloadBytes = 4096,
}

--------------------------------------------------------------------------------
-- GameAnalytics (SPEC §4.6).
--
-- Pure constants only — no secrets in this file. The Game Key lives in the
-- Roblox first-party Secret named by `SecretNames.GameKey` (Creator Hub →
-- Configure Experience → Secrets); the Secret Key lives in the gitignored
-- ModuleScript at `SecretsModulePath` returning `{ [SecretsModuleField] = "..." }`
-- (see SPEC §4.6.2 / §4.6.3 for the split-storage rationale).
--
-- The Game Key is appended to `EndpointBase` at the adapter level via the
-- `Secret:AddPrefix` / `Secret:AddSuffix` API so its raw value never enters
-- Lua memory.
--------------------------------------------------------------------------------
TelemetryConfig.GameAnalytics = {
	EndpointBase = "https://api.gameanalytics.com/v2/",
	--- GameAnalytics REST v2 SDK string. Literal value GA expects per their docs.
	SdkVersion = "rest 2 v3",

	Batch = {
		FlushSeconds = 8,
		FlushAtCount = 100,
		MaxBufferPerUser = 500,
		MaxAgeSeconds = 300,
	},

	Backoff = {
		InitialSeconds = 1,
		MaxSeconds = 30,
		Multiplier = 2,
	},

	SecretNames = {
		GameKey = "GA_GAME_KEY",
	},

	SecretsModulePath = { "ServerStorage", "Secrets", "GameAnalytics" },
	SecretsModuleField = "secretKey",
}

--------------------------------------------------------------------------------
-- Robux → USD conversion (SPEC §11.A.3 — locked at 0.0035).
--
-- 1 R$ ≈ $0.0035 USD retail (the price-paid conversion, NOT actual revenue —
-- Roblox's DevEx pre-tax rate is materially lower). Used by
-- `Telemetry.Purchase` to populate the GameAnalytics `business` event
-- `amount` in integer USD cents:
--   amount = math.floor(robuxPrice * TelemetryConfig.RobuxToUsd * 100)
--------------------------------------------------------------------------------
TelemetryConfig.RobuxToUsd = 0.0035

--------------------------------------------------------------------------------
-- session_start custom dimensions (SPEC §4.6.5 step 3 / §11.A.4 — locked).
--
-- `AccountAgeBuckets` is sorted ascending by `max` and resolved by
-- `BucketAccountAge(days)` with **lower-bound-inclusive** semantics
-- (i.e. `accountAgeDays < bucket.max`). 7 → "7-30d", 30 → "30-90d",
-- 90 → ">90d". This avoids leaking the player's exact join date to the
-- third party while still letting GA segment cohorts by tenure.
--------------------------------------------------------------------------------
TelemetryConfig.SessionStartCustomDimensions = {
	AccountAgeBuckets = {
		{ max = 7,           label = "<7d" },
		{ max = 30,          label = "7-30d" },
		{ max = 90,          label = "30-90d" },
		{ max = math.huge,   label = ">90d" },
	},
	MembershipLabels = {
		Premium = "premium",
		Standard = "standard",
	},
}

--==============================================================================
-- Helpers (pure; only RunService is consulted)
--==============================================================================

--- True when local debug `print`ing should run for every emitted event.
--- Always true in Studio so playtesters get structured Output without
--- having to flip `Debug.PrintLocally` by hand.
function TelemetryConfig:IsDebugActive(): boolean
	return self.Debug.PrintLocally or RunService:IsStudio()
end

--- True when GameAnalytics fan-out should reach the live HTTP endpoint.
--- In live servers this is unconditionally true. In Studio it is false
--- by default (`ForceBackendsInStudio = false`) so HTTP is replaced by a
--- debug `print`; opt in for end-to-end QA by either flipping
--- `Debug.ForceBackendsInStudio` here or setting
--- `_G.__OTS_TELEMETRY_FORCE_BACKENDS = true` in the command bar.
function TelemetryConfig:ShouldHitNetworkInStudio(): boolean
	if not RunService:IsStudio() then
		return true
	end
	if self.Debug.ForceBackendsInStudio then
		return true
	end
	return _G.__OTS_TELEMETRY_FORCE_BACKENDS == true
end

--- Map a player's `AccountAge` (in days) onto the locked bucket label.
--- Lower-bound-inclusive: an exact boundary value belongs to the **next**
--- bucket (e.g. `7` → "7-30d", `30` → "30-90d", `90` → ">90d").
function TelemetryConfig:BucketAccountAge(accountAgeDays: number): string
	for _, bucket in ipairs(self.SessionStartCustomDimensions.AccountAgeBuckets) do
		if accountAgeDays < bucket.max then
			return bucket.label
		end
	end
	-- Defensive fallback: the final bucket uses `math.huge`, so we should
	-- never reach this — but if the table is misconfigured we still hand
	-- back a usable label rather than nil.
	local buckets = self.SessionStartCustomDimensions.AccountAgeBuckets
	return buckets[#buckets].label
end

--- Sample-rate lookup with the SPEC §6 default of 1.0 for unlisted events.
--- Always go through this helper instead of indexing `SampleRates` directly
--- so the default contract stays single-sourced.
function TelemetryConfig:GetSampleRate(eventName: string): number
	local rate = self.SampleRates[eventName]
	if rate == nil then
		return 1.0
	end
	return rate
end

return TelemetryConfig
