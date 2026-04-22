--!strict
-- Shared.Telemetry — server-authoritative analytics pipeline (PR 3 of
-- `docs/features/telemetry/SPEC.md` §13).
--
-- PUBLIC API (matches SPEC §5):
--   Telemetry.Track(player?, eventName, properties?)            -- catch-all custom event
--   Telemetry.Funnel(player, funnelName, step, stepName, status?) -- progression funnel step
--   Telemetry.Economy(player, flowType, amount, currency, reason, item?) -- soft-currency flow
--   Telemetry.Progression(player, status, path1, path2?, path3?, value?) -- generic progression
--   Telemetry.Purchase(player, productKind, productId, robuxAmount) -- monetization
--
--   Telemetry._getSession(player)   -- debug-only: peek per-player session
--   Telemetry._resetCircuit()       -- test hook: clear circuit-open state
--   Telemetry.Debug.DumpRecentEvents() -- last 100 events ring buffer
--   Telemetry.Debug.ResetForTests()    -- clear sessions / counters / ring
--
-- DUAL FAN-OUT (SPEC §4.1):
--   Every emitted event fans out to BOTH backends inside `pcall`s — one
--   failing never blocks the other or the gameplay caller. PR 3 wires the
--   Roblox `AnalyticsService` half (LogFunnelStepEvent / LogEconomyEvent /
--   LogProgressionEvent / LogCustomEvent) only; the GameAnalytics half
--   routes through `GameAnalyticsAdapter`, which is a stub in PR 3 and
--   will be replaced by the real REST client in PR 4 without touching
--   this file.
--
-- AUTO-ATTACHED CONTEXT (SPEC §4.3, scoped to PR 3):
--   `userId`, `sessionId`, `placeVersion`, `playTimeSeconds` are decorated
--   onto every payload server-side. Things like current ship / strait
--   state are NOT auto-attached in PR 3 — services must pass them via
--   `properties` until the per-service wiring in PR 5 plumbs them in.
--   Server-scoped events (`player == nil`) skip the player-derived fields.
--
-- GUARDS (SPEC §8 — implemented in PR 3, not deferred):
--   * Per-player rate limit (`PerPlayerEventsPerMinute`, default 30)
--   * Per-server rate limit (`PerServerEventsPerMinute`, default 5000)
--     - On trip: emits `telemetry_circuit_open` once and rejects new
--       events for the rest of the minute window.
--   * Oversize guard (`OversizePayloadBytes`, default 4096) on the
--     JSON-encoded `properties`.
--   * Sample rate via `TelemetryConfig:GetSampleRate(eventName)`.
--   * `telemetry_dropped` summary fires at most once per minute per
--     player+reason so we never feedback-loop the very thing it warns
--     about. `telemetry_dropped` and `telemetry_circuit_open` themselves
--     bypass rate-limit + sample-rate.
--
-- STUDIO ROUTING (SPEC §9.4):
--   `TelemetryConfig:IsDebugActive()` true (default in Studio) →
--   structured `print` of every emit. `:ShouldHitNetworkInStudio()` false
--   (default in Studio) → fan-out functions skip the real backend call.
--   Override per-session with `_G.__OTS_TELEMETRY_FORCE_BACKENDS = true`
--   in the command bar, or `Debug.ForceBackendsInStudio = true` in
--   `TelemetryConfig`.
--
-- BOOTSTRAP (SPEC §9.1 / §9.2 / §9.3):
--   Hooks `Players.PlayerAdded`, `Players.PlayerRemoving`, and
--   `game:BindToClose` on first `require`. Iterates `Players:GetPlayers()`
--   once after wiring so any pre-bootstrap players still get a session.
--
-- CLIENT REQUIRES (SPEC §4.2 / §8): client-side requires are tolerated
-- but every public method early-returns when `RunService:IsServer() == false`.

local AnalyticsService = game:GetService("AnalyticsService")
local HttpService       = game:GetService("HttpService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

local TelemetryConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("TelemetryConfig"))
local EventCatalog          = require(script:WaitForChild("EventCatalog"))
local GameAnalyticsAdapter  = require(script:WaitForChild("GameAnalyticsAdapter"))

--==============================================================================
-- Types
--==============================================================================

export type EventName = string

export type EventCategory = EventCatalog.EventCategory
export type GaCategory    = EventCatalog.GaCategory
export type EventDefinition = EventCatalog.EventDefinition

export type EventPayload = { [string]: any }

export type Session = {
	userId: number,
	sessionId: string,
	joinedAtClock: number,
	accountAgeBucket: string,
	membership: string,
	eventsThisMinute: number,
}

export type EconomyFlow = "Source" | "Sink"
export type ProgressionStatus = "Start" | "Complete" | "Fail"
export type FunnelStatus = "Start" | "Complete" | "Fail"
export type ProductKind = "GamePass" | "DevProduct"

--==============================================================================
-- Constants
--==============================================================================

local IS_SERVER = RunService:IsServer()
local PLACE_VERSION = game.PlaceVersion

local RING_BUFFER_MAX = 100
local SESSION_ID_LENGTH = 16

-- One drop-summary per minute per (player, reason). 60s in os.clock units.
local DROP_SUMMARY_INTERVAL_SECONDS = 60
-- Rolling window for both per-player and per-server rate limits.
local RATE_WINDOW_SECONDS = 60

-- Default `transactionType` string passed to `LogEconomyEvent`. Roblox treats
-- this as a free-text bucket; SPEC §4.5 names "Gameplay" as the canonical
-- bucket for non-IAP currency flows.
local DEFAULT_ECONOMY_TRANSACTION_TYPE = "Gameplay"

--==============================================================================
-- Module
--==============================================================================

local Telemetry = {}
Telemetry.Debug = {}

--==============================================================================
-- Internal state — keyed by UserId. Server-only.
--==============================================================================

type RateWindow = { number }
type DropTracker = { [string]: number }
type Sessions = { [number]: Session }

local _sessions: Sessions = {}
local _perPlayerRateWindow: { [number]: RateWindow } = {}
local _serverRateWindow: RateWindow = {}
local _perPlayerLastDropEmit: { [number]: DropTracker } = {}
local _serverLastDropEmit: DropTracker = {}
local _circuitOpenUntilClock: number? = nil
local _ringBuffer: { { eventName: string, at: number, payload: EventPayload } } = {}
local _ringBufferIndex = 0
local _unknownEventWarned: { [string]: boolean } = {}
local _bootstrapped = false

--==============================================================================
-- Helpers
--==============================================================================

local function _generateSessionId(): string
	-- 16 hex chars is plenty of entropy for a single server's lifetime.
	local guid = HttpService:GenerateGUID(false):gsub("-", "")
	return string.sub(guid, 1, SESSION_ID_LENGTH)
end

local function _resolveEventDef(eventName: string): EventDefinition
	local def = EventCatalog.GetEvent(eventName)
	if def then
		return def
	end
	if not _unknownEventWarned[eventName] then
		_unknownEventWarned[eventName] = true
		warn(string.format(
			"[Telemetry] Unknown event '%s' — add it to EventCatalog.luau / SPEC §6. Falling back to custom/design.",
			eventName
		))
	end
	return {
		category = "custom",
		gaCategory = "design",
		sampleRate = 1.0,
	}
end

local function _pruneWindow(window: RateWindow, nowClock: number)
	-- Drop entries older than RATE_WINDOW_SECONDS. Cheap because we always
	-- append to the end so the oldest entries cluster at the front.
	local cutoff = nowClock - RATE_WINDOW_SECONDS
	while window[1] ~= nil and window[1] < cutoff do
		table.remove(window, 1)
	end
end

local function _decoratePayload(player: Player?, properties: EventPayload?): EventPayload
	local out: EventPayload = {}
	if properties then
		for k, v in properties do
			out[k] = v
		end
	end
	out.placeVersion = PLACE_VERSION
	if player then
		out.userId = player.UserId
		local session = _sessions[player.UserId]
		if session then
			out.sessionId = session.sessionId
			out.playTimeSeconds = math.floor(os.clock() - session.joinedAtClock)
		end
	end
	return out
end

local function _ringBufferAppend(eventName: string, payload: EventPayload)
	_ringBufferIndex = (_ringBufferIndex % RING_BUFFER_MAX) + 1
	_ringBuffer[_ringBufferIndex] = {
		eventName = eventName,
		at = os.clock(),
		payload = payload,
	}
end

--==============================================================================
-- Guards (rate limit / oversize / circuit / sample)
--==============================================================================

--- Returns the drop reason if the event should be rejected, else `nil`.
--- Mutates the per-player + per-server windows on success (i.e. counts the
--- event toward the cap as if it'll fan out).
local function _checkAndCountRateLimit(player: Player?): string?
	local nowClock = os.clock()

	-- Server-scope window (every event counts toward this, including
	-- player-scoped ones). This is the GA + Roblox quota-protection cap.
	_pruneWindow(_serverRateWindow, nowClock)
	if #_serverRateWindow >= TelemetryConfig.RateLimits.PerServerEventsPerMinute then
		return "rate_limit_server"
	end

	-- Per-player window only applies when there's a player to attribute to.
	if player then
		local window = _perPlayerRateWindow[player.UserId]
		if not window then
			window = {}
			_perPlayerRateWindow[player.UserId] = window
		end
		_pruneWindow(window, nowClock)
		if #window >= TelemetryConfig.RateLimits.PerPlayerEventsPerMinute then
			return "rate_limit_player"
		end
		table.insert(window, nowClock)
	end

	table.insert(_serverRateWindow, nowClock)
	return nil
end

--- True if the per-server circuit breaker is currently open.
local function _isCircuitOpen(): boolean
	if not _circuitOpenUntilClock then
		return false
	end
	if os.clock() >= _circuitOpenUntilClock then
		_circuitOpenUntilClock = nil
		return false
	end
	return true
end

--- Open the per-server circuit until the next minute boundary. Idempotent.
local function _tripCircuit()
	if _circuitOpenUntilClock and os.clock() < _circuitOpenUntilClock then
		return
	end
	_circuitOpenUntilClock = os.clock() + RATE_WINDOW_SECONDS
end

--- Track and rate-limit `telemetry_dropped` summaries. Returns true if the
--- caller should emit the summary, false if it was throttled.
local function _shouldEmitDropSummary(player: Player?, reason: string): boolean
	local nowClock = os.clock()
	local tracker: DropTracker
	if player then
		tracker = _perPlayerLastDropEmit[player.UserId]
		if not tracker then
			tracker = {}
			_perPlayerLastDropEmit[player.UserId] = tracker
		end
	else
		tracker = _serverLastDropEmit
	end
	local last = tracker[reason]
	if last and (nowClock - last) < DROP_SUMMARY_INTERVAL_SECONDS then
		return false
	end
	tracker[reason] = nowClock
	return true
end

--- Forward declaration so `_emitDropSummary` can call back into the main
--- emit pipeline without recursing through the rate-limit guards.
local _emitInternal: (
	player: Player?,
	eventName: string,
	properties: EventPayload?,
	dispatch: { kind: string, [string]: any }
) -> ()

local function _emitDropSummary(player: Player?, reason: string, eventName: string?, sizeBytes: number?)
	if not _shouldEmitDropSummary(player, reason) then
		return
	end
	local props: EventPayload = {
		reason = reason,
	}
	if eventName then
		props.originalEventName = eventName
	end
	if sizeBytes then
		props.sizeBytes = sizeBytes
	end
	_emitInternal(player, "telemetry_dropped", props, { kind = "custom", value = 1 })
end

local function _emitCircuitOpen(eventsInWindow: number)
	-- Server-scoped (no player). Bypasses every guard via the internal path.
	_emitInternal(nil, "telemetry_circuit_open", {
		windowSeconds = RATE_WINDOW_SECONDS,
		eventsInWindow = eventsInWindow,
	}, { kind = "custom", value = 1 })
end

--==============================================================================
-- Fan-out — Roblox AnalyticsService (PR 3 wires this; PR 4 leaves it alone)
--==============================================================================

local function _printIfDebug(backendTag: string, eventName: string, payload: EventPayload)
	if not TelemetryConfig:IsDebugActive() then
		return
	end
	local ok, encoded = pcall(HttpService.JSONEncode, HttpService, payload)
	if not ok then
		encoded = "<JSONEncode failed>"
	end
	print(string.format("[Telemetry/%s] %s %s", backendTag, eventName, encoded))
end

--- Dispatch an event to the Roblox `AnalyticsService` based on `dispatch.kind`.
--- Any error from the Roblox API is swallowed with a single warn so a stale
--- player reference (left mid-call) cannot take the pipeline down.
---
--- API DRIFT NOTE (verified against current Roblox docs at PR 3 author
--- time):
---   * `LogProgressionEvent` now takes `(player, progressionPathName,
---     status, level, levelName, customFields)` — added `level` (number)
---     and `levelName` (string) since the SPEC was written. We use the
---     optional `value` from `Telemetry.Progression` as `level` (default
---     1) and the path leaves as `levelName`.
---   * `LogFunnelStepEvent` accepts an optional trailing `customFields`
---     dict. We pass `nil` (the rich payload still goes to GA).
---   * `customFields` everywhere requires keys from
---     `Enum.AnalyticsCustomFieldKeys.CustomField0{1,2,3}.Name` with
---     STRING values, and is capped at 3 entries. Our payloads have rich
---     mixed-typed fields and many keys, so passing `nil` is safer than
---     a partial / lossy projection. The full detail still flows to GA
---     in PR 4 where there is no such constraint.
local function _fanOutRoblox(
	player: Player?,
	eventName: string,
	payload: EventPayload,
	_eventDef: EventDefinition,
	dispatch: { kind: string, [string]: any }
)
	_printIfDebug("Roblox", eventName, payload)

	if not TelemetryConfig:ShouldHitNetworkInStudio() then
		-- Studio default: print-only, do not touch AnalyticsService.
		return
	end

	-- Every typed AnalyticsService call requires a `Player` instance; if
	-- this is a server-scoped event we have no choice but to skip the
	-- Roblox fan-out (Roblox's API has no "server-only" event surface).
	if not player then
		return
	end

	local kind = dispatch.kind
	local ok, err: any = pcall(function()
		if kind == "funnel" then
			AnalyticsService:LogFunnelStepEvent(
				player,
				dispatch.funnelName,
				dispatch.funnelSessionId,
				dispatch.step,
				dispatch.stepName,
				nil :: any -- customFields (3-field-Enum-keyed only; full payload goes to GA)
			)
		elseif kind == "economy" then
			-- SPEC §4.5 — `endingBalance` is required by the API. We pass
			-- `0` until PR 5 plumbs the per-player wallet into the
			-- decorator (TODO: read from `OilStateService:GetCash`).
			AnalyticsService:LogEconomyEvent(
				player,
				dispatch.flowTypeEnum,
				dispatch.currency,
				dispatch.amount,
				dispatch.endingBalance or 0,
				dispatch.transactionType or DEFAULT_ECONOMY_TRANSACTION_TYPE,
				dispatch.itemSku,
				nil :: any -- customFields (see drift note above)
			)
		elseif kind == "progression" then
			AnalyticsService:LogProgressionEvent(
				player,
				dispatch.progressionPath,
				dispatch.statusEnum,
				dispatch.level or 1,
				dispatch.levelName or dispatch.progressionPath,
				nil :: any -- customFields (see drift note above)
			)
		else
			-- Default: every other event flows through LogCustomEvent as a
			-- generic catch-all (matches SPEC §4.5). `Telemetry.Purchase`
			-- also lands here because Roblox has no first-party purchase
			-- hook for our use case — the `business` flow on GA owns
			-- monetization and ships in PR 4.
			AnalyticsService:LogCustomEvent(
				player,
				eventName,
				dispatch.value or 1,
				nil :: any -- customFields (see drift note above)
			)
		end
	end)
	if not ok then
		warn(string.format("[Telemetry/Roblox] LogXEvent raised for %s: %s", eventName, tostring(err)))
	end
end

--==============================================================================
-- Fan-out — GameAnalytics (stub in PR 3; PR 4 swaps GameAnalyticsAdapter)
--==============================================================================

local function _fanOutGameAnalytics(
	player: Player?,
	eventName: string,
	payload: EventPayload,
	eventDef: EventDefinition,
	_dispatch: { kind: string, [string]: any }
)
	_printIfDebug("GA", eventName, payload)

	if not TelemetryConfig:ShouldHitNetworkInStudio() then
		return
	end

	-- The stub adapter no-ops; PR 4 replaces the body with the real REST
	-- client. We still call it so PR 4 doesn't have to edit init.luau.
	GameAnalyticsAdapter.Queue(player, eventDef.gaCategory :: GameAnalyticsAdapter.GameAnalyticsCategory, payload)
end

--==============================================================================
-- Internal emit — runs guards, decorates, ring-buffers, and fans out.
--==============================================================================

local function _isInternalDiagnostic(eventName: string): boolean
	return eventName == "telemetry_dropped" or eventName == "telemetry_circuit_open"
end

function _emitInternal(
	player: Player?,
	eventName: string,
	properties: EventPayload?,
	dispatch: { kind: string, [string]: any }
)
	if not IS_SERVER then
		-- Client-side requires are tolerated; calls are silently no-op'd.
		return
	end

	local eventDef = _resolveEventDef(eventName)
	local internal = _isInternalDiagnostic(eventName)

	if not internal then
		-- Circuit breaker — short-circuit BOTH backends until the window
		-- closes so we don't fan out a flood the breaker just declared
		-- abusive (SPEC §8).
		if _isCircuitOpen() then
			return
		end

		-- Sample rate — drop silently per SPEC §6 / §8 (no diagnostic
		-- event; emitting one would defeat the rate).
		local rate = TelemetryConfig:GetSampleRate(eventName)
		if rate < 1.0 and math.random() > rate then
			return
		end

		-- Rate limit — count toward both windows; on trip emit ONE
		-- summary per minute per (player, reason).
		local dropReason = _checkAndCountRateLimit(player)
		if dropReason then
			if dropReason == "rate_limit_server" then
				-- Per-server cap exceeded → trip the circuit so the rest
				-- of the window is also dropped (no need to re-evaluate
				-- per-event), and emit `telemetry_circuit_open` once.
				_tripCircuit()
				_emitCircuitOpen(#_serverRateWindow)
			end
			_emitDropSummary(player, dropReason, eventName, nil)
			return
		end

		-- Oversize guard — measured on the JSON-encoded *raw* properties
		-- (not the decorated payload — the decorator is bounded and we
		-- want callers to see the same byte budget they wrote).
		if properties then
			local ok, encoded = pcall(HttpService.JSONEncode, HttpService, properties)
			if ok and #encoded > TelemetryConfig.RateLimits.OversizePayloadBytes then
				_emitDropSummary(player, "oversize", eventName, #encoded)
				return
			end
		end
	end

	local payload = _decoratePayload(player, properties)
	_ringBufferAppend(eventName, payload)

	-- Each fan-out is in its own pcall so one failing never blocks the
	-- other (SPEC §4.1 independence requirement).
	local okR, errR = pcall(_fanOutRoblox, player, eventName, payload, eventDef, dispatch)
	if not okR then
		warn(string.format("[Telemetry/Roblox] fan-out raised for %s: %s", eventName, tostring(errR)))
	end
	local okG, errG = pcall(_fanOutGameAnalytics, player, eventName, payload, eventDef, dispatch)
	if not okG then
		warn(string.format("[Telemetry/GA] fan-out raised for %s: %s", eventName, tostring(errG)))
	end
end

--==============================================================================
-- Public API (SPEC §5)
--==============================================================================

--- Catch-all custom event. `player` may be `nil` for server-scoped events
--- (e.g. `equipment_shop_rotated`). Auto-attached context: `userId`,
--- `sessionId`, `playTimeSeconds`, `placeVersion` — see module doc-block.
function Telemetry.Track(player: Player?, eventName: string, properties: EventPayload?)
	_emitInternal(player, eventName, properties, { kind = "custom", value = 1 })
end

--- Funnel step — fans out to Roblox `LogFunnelStepEvent` and GA
--- `progression` category. `status` defaults to `"Start"`. The
--- per-player session `sessionId` doubles as the funnel session id so
--- Roblox can correlate steps across the same join.
function Telemetry.Funnel(
	player: Player,
	funnelName: string,
	step: number,
	stepName: string,
	status: FunnelStatus?
)
	if not player then
		warn("[Telemetry] Funnel called with nil player; ignoring.")
		return
	end
	local resolvedStatus = status or "Start"
	local eventName = string.format("funnel_%s", funnelName)
	local properties: EventPayload = {
		funnelName = funnelName,
		step = step,
		stepName = stepName,
		status = resolvedStatus,
	}
	local funnelSessionId: string? = nil
	local session = _sessions[player.UserId]
	if session then
		funnelSessionId = session.sessionId
	end
	_emitInternal(player, eventName, properties, {
		kind = "funnel",
		funnelName = funnelName,
		funnelSessionId = funnelSessionId,
		step = step,
		stepName = stepName,
	})
end

--- Soft-currency flow — fans out to Roblox `LogEconomyEvent` and GA
--- `resource` category. `endingBalance` is passed as `0` until per-player
--- wallet plumbing lands in PR 5; the Roblox dashboard treats `0` as
--- "unknown" rather than a hard error.
function Telemetry.Economy(
	player: Player,
	flowType: EconomyFlow,
	amount: number,
	currency: string,
	reason: string,
	item: string?
)
	if not player then
		warn("[Telemetry] Economy called with nil player; ignoring.")
		return
	end
	local properties: EventPayload = {
		flowType = flowType,
		amount = amount,
		currency = currency,
		reason = reason,
	}
	if item then
		properties.item = item
	end
	-- Use `reason` as the event name so callers line up with the catalog
	-- rows in SPEC §6.4 (`oil_sold`, `dispatch_fee`, `equipment_purchased`, …).
	local flowEnum = (Enum :: any).AnalyticsEconomyFlowType[flowType]
	_emitInternal(player, reason, properties, {
		kind = "economy",
		flowTypeEnum = flowEnum,
		currency = currency,
		amount = amount,
		endingBalance = 0,
		transactionType = reason,
		itemSku = item,
	})
end

--- Generic progression event — fans out to Roblox `LogProgressionEvent`
--- (with the colon-joined path) and GA `progression` category.
function Telemetry.Progression(
	player: Player,
	status: ProgressionStatus,
	path1: string,
	path2: string?,
	path3: string?,
	value: number?
)
	if not player then
		warn("[Telemetry] Progression called with nil player; ignoring.")
		return
	end
	local pathParts: { string } = { path1 }
	if path2 then table.insert(pathParts, path2) end
	if path3 then table.insert(pathParts, path3) end
	local progressionPath = table.concat(pathParts, ":")

	local properties: EventPayload = {
		status = status,
		path1 = path1,
		path2 = path2,
		path3 = path3,
		progressionPath = progressionPath,
	}
	if value ~= nil then
		properties.value = value
	end

	-- API drift: Roblox renamed `Enum.AnalyticsProgressionStatus` to
	-- `Enum.AnalyticsProgressionType` in a recent revision. Fall back to
	-- the legacy enum name if the new one isn't present so the adapter
	-- works against either runtime.
	local progressionEnum = (Enum :: any).AnalyticsProgressionType
		or (Enum :: any).AnalyticsProgressionStatus
	local statusEnum = progressionEnum[status]
	_emitInternal(player, "progression_" .. progressionPath, properties, {
		kind = "progression",
		progressionPath = progressionPath,
		statusEnum = statusEnum,
		level = value or 1,
		levelName = path2 or path1,
	})
end

--- Monetization purchase. Roblox has no first-party purchase event hook
--- for our use case, so we route through `LogCustomEvent` for now; the
--- real revenue tracking ships through the GA `business` flow in PR 4.
function Telemetry.Purchase(
	player: Player,
	productKind: ProductKind,
	productId: number,
	robuxAmount: number
)
	if not player then
		warn("[Telemetry] Purchase called with nil player; ignoring.")
		return
	end
	local lower = string.lower(productKind)
	local eventName = string.format("purchase_%s_%d", lower, productId)
	local properties: EventPayload = {
		productKind = productKind,
		productId = productId,
		robuxAmount = robuxAmount,
		usdCents = math.floor(robuxAmount * TelemetryConfig.RobuxToUsd * 100),
	}
	_emitInternal(player, eventName, properties, {
		kind = "custom",
		value = robuxAmount,
	})
end

--==============================================================================
-- Debug / test surface
--==============================================================================

--- Read-only-ish peek at the per-player session record. Returned table is
--- a shallow copy so callers can't mutate internal state by accident.
function Telemetry._getSession(player: Player): Session?
	local session = _sessions[player.UserId]
	if not session then
		return nil
	end
	return {
		userId = session.userId,
		sessionId = session.sessionId,
		joinedAtClock = session.joinedAtClock,
		accountAgeBucket = session.accountAgeBucket,
		membership = session.membership,
		eventsThisMinute = session.eventsThisMinute,
	}
end

--- Test hook: clear the circuit-open state so a synthetic-burst test can
--- reset between runs. No-op when the circuit is already closed.
function Telemetry._resetCircuit()
	_circuitOpenUntilClock = nil
end

--- Returns a shallow copy of the in-memory ring buffer (last 100 events,
--- newest-last in insertion order rounded around the buffer). Useful for
--- Studio inspection when `Debug.PrintLocally` isn't enough context.
function Telemetry.Debug.DumpRecentEvents(): { { eventName: string, at: number, payload: EventPayload } }
	local out = {}
	-- Walk the buffer in insertion order: start from (current+1) % MAX.
	for offset = 1, RING_BUFFER_MAX do
		local idx = ((_ringBufferIndex + offset - 1) % RING_BUFFER_MAX) + 1
		local entry = _ringBuffer[idx]
		if entry then
			table.insert(out, entry)
		end
	end
	return out
end

--- Test hook: drop sessions, rate counters, drop trackers, and ring
--- buffer. Useful between synthetic-burst tests so state from one test
--- can't leak into the next.
function Telemetry.Debug.ResetForTests()
	_sessions = {}
	_perPlayerRateWindow = {}
	_serverRateWindow = {}
	_perPlayerLastDropEmit = {}
	_serverLastDropEmit = {}
	_circuitOpenUntilClock = nil
	_ringBuffer = {}
	_ringBufferIndex = 0
	_unknownEventWarned = {}
end

--==============================================================================
-- Bootstrap (SPEC §9.1 / §9.2 / §9.3)
--==============================================================================

local function _resolveMembershipLabel(player: Player): string
	local labels = TelemetryConfig.SessionStartCustomDimensions.MembershipLabels
	if player.MembershipType == Enum.MembershipType.Premium then
		return labels.Premium
	end
	return labels.Standard
end

local function _onPlayerAdded(player: Player)
	if _sessions[player.UserId] then
		-- Already bootstrapped (the `Players:GetPlayers()` post-hook pass
		-- can race with a real PlayerAdded). Cheap idempotency guard.
		return
	end

	local accountAgeBucket = TelemetryConfig:BucketAccountAge(player.AccountAge)
	local membership = _resolveMembershipLabel(player)
	local session: Session = {
		userId = player.UserId,
		sessionId = _generateSessionId(),
		joinedAtClock = os.clock(),
		accountAgeBucket = accountAgeBucket,
		membership = membership,
		eventsThisMinute = 0,
	}
	_sessions[player.UserId] = session
	_perPlayerRateWindow[player.UserId] = {}
	_perPlayerLastDropEmit[player.UserId] = {}

	Telemetry.Track(player, "session_start", {
		accountAgeBucket = accountAgeBucket,
		membership = membership,
		placeVersion = PLACE_VERSION,
	})

	GameAnalyticsAdapter.QueueSessionStart(player, {
		accountAgeBucket = accountAgeBucket,
		membership = membership,
	})
end

local function _onPlayerRemoving(player: Player)
	local session = _sessions[player.UserId]
	if not session then
		return
	end
	local lengthSeconds = math.floor(os.clock() - session.joinedAtClock)
	Telemetry.Track(player, "session_end", { lengthSeconds = lengthSeconds })
	GameAnalyticsAdapter.QueueSessionEnd(player, lengthSeconds)
	GameAnalyticsAdapter.FlushPlayer(player)

	_sessions[player.UserId] = nil
	_perPlayerRateWindow[player.UserId] = nil
	_perPlayerLastDropEmit[player.UserId] = nil
end

local function _onBindToClose()
	-- Emit a final session_end for each remaining session with a reason
	-- so downstream queries can separate clean leaves from shutdown sweeps.
	for userId, session in _sessions do
		local player = Players:GetPlayerByUserId(userId)
		local lengthSeconds = math.floor(os.clock() - session.joinedAtClock)
		if player then
			Telemetry.Track(player, "session_end", {
				lengthSeconds = lengthSeconds,
				reason = "shutdown",
			})
		end
	end
	-- 25s ceiling leaves a 5s buffer under Roblox's 30s BindToClose hard
	-- limit (SPEC §9.3). Stub returns immediately in PR 3.
	GameAnalyticsAdapter.FlushAll(25)
end

local function _bootstrap()
	if _bootstrapped or not IS_SERVER then
		return
	end
	_bootstrapped = true

	Players.PlayerAdded:Connect(_onPlayerAdded)
	Players.PlayerRemoving:Connect(_onPlayerRemoving)
	game:BindToClose(_onBindToClose)

	-- Catch any players who joined before the module first `require`d.
	for _, player in Players:GetPlayers() do
		task.spawn(_onPlayerAdded, player)
	end
end

_bootstrap()

return Telemetry
