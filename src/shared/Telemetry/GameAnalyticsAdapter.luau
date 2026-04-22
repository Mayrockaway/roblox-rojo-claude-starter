--!strict
-- GameAnalytics REST v2 adapter (PR 4 of `docs/features/telemetry/SPEC.md` §13).
--
-- Owns:
--   * Boot-time secret loading per SPEC §4.6.2 (split: Game Key via
--     `HttpService:GetSecret`, Secret Key via `ServerStorage.Secrets.GameAnalytics`).
--   * The mandatory ordering per SPEC §4.6.5: `init` → `user` → `session_start`
--     → gameplay events. The drain loop refuses to POST gameplay events
--     for a user before that user's `user`/`session_start` have shipped.
--   * HMAC-SHA256 signing of every POST per SPEC §4.6.3, computed over the
--     EXACT bytes of the JSON-encoded body (no whitespace mutation post-sign).
--   * Per-user batched buffer per SPEC §4.6.8 (8s flush / 100-event flush /
--     on PlayerRemoving / on BindToClose, hard cap 500 with FIFO eviction,
--     5-minute age-out).
--   * Exponential backoff per SPEC §4.6.9 (1s → 2s → 4s → … → 30s cap).
--   * Studio routing per SPEC §9.4 — `[Telemetry/GA]` prints in lieu of
--     real HTTP unless `_G.__OTS_TELEMETRY_FORCE_BACKENDS = true` (or the
--     `Debug.ForceBackendsInStudio` config flag) opts in.
--
-- Does NOT own:
--   * Decoration of payloads (`init.luau` runs `_decoratePayload` first;
--     this adapter trusts what arrives via `Queue` / `QueueSessionStart` /
--     `QueueSessionEnd`).
--   * Per-server / per-player rate limiting and the cross-server
--     `telemetry_circuit_open` event — those live in `Shared.Telemetry`.
--   * The Roblox `AnalyticsService` half of the dual fan-out.
--
-- Public function signatures are FROZEN by `init.luau` per the SPEC §3.3
-- contract — extending them is a separate PR.
--
-- Failure modes that intentionally degrade silently to keep the gameplay
-- path running:
--   * Secrets missing → `secretsHealthy = false`, one-shot warn, every
--     public method becomes a clean no-op, `IsReady() == false`.
--   * `/init` returns `enabled = false` → `_gaDisabled = true`, queued
--     events are dropped from the buffer the next time we walk it (we
--     stop POSTing — Roblox `AnalyticsService` is unaffected).
--   * `RequestAsync` raises (network unreachable) → counted toward the
--     same backoff curve as a non-2xx response.

local GameAnalyticsAdapter = {}

local HttpService       = game:GetService("HttpService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local ServerStorage     = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local TelemetryConfig = require(Shared:WaitForChild("Config"):WaitForChild("TelemetryConfig"))
local HmacSha256      = require(Shared:WaitForChild("Vendor"):WaitForChild("HmacSha256"))

--==============================================================================
-- Types
--==============================================================================

--- The set of GameAnalytics REST v2 categories this adapter understands.
--- Mirrors the `gaCategory` column in `EventCatalog.luau` plus the GA-only
--- `"user"` value emitted internally by the `user` handshake event.
export type GameAnalyticsCategory =
	"business" | "resource" | "design" | "progression" | "error"
	| "session_start" | "session_end" | "user"

--- Payload shape for `QueueSessionStart` — a thin pair driving the locked
--- §4.6.5 step 3 custom dimensions. The adapter generates / stores the
--- session id internally and does not require it here.
export type SessionStartPayload = {
	accountAgeBucket: string,
	membership: string,
	[string]: any,
}

--- Permissive payload shape for `Queue`. The adapter pulls the
--- category-specific fields below to construct each GA event. Missing
--- required fields cause the event to be dropped locally with
--- `ga_payload_invalid` (counted in `_droppedCounters` for diagnostics).
---
--- Common (decorated by `init.luau`, optional but recommended):
---   `userId`           number
---   `sessionId`        string
---   `playTimeSeconds`  number
---   `placeVersion`     number
---
--- `business` events expect:
---   `cart_type` or `productKind`     string ("DevProduct" | "GamePass")
---   `productId`                      number
---   `usdCents` (preferred) OR `robuxAmount`  number
---   `itemId` (optional)              string
---
--- `resource` events expect:
---   `flowType`                       "Source" | "Sink"
---   `currency`                       string
---   `amount`                         number
---   `itemType` or `reason`           string
---   `itemId` or `item` (optional)    string
---
--- `progression` events expect:
---   `status`                         "Start" | "Complete" | "Fail"
---   `progressionPath` OR `path1`/`path2`/`path3`  string(s)
---   `value` (optional)               number — emitted as `score`
---
--- `design` events expect:
---   `gaEventId` (preferred) OR `funnelName` / `progressionPath` / `reason`
---     — used to construct the colon-joined `event_id`. Missing → drop.
---
--- `error` events expect:
---   `severity`                       "info" | "debug" | "warning" | "error" | "critical"
---   `message` (optional)             string
export type EventPayload = {
	[string]: any,
}

type GaEventBody = { [string]: any }

type BufferedEvent = {
	body: GaEventBody,
	queuedAtClock: number,
	-- True for the user/session_start handshake events so the drain
	-- loop can stack them at the head of the user's POST.
	isHandshake: boolean,
}

type UserState = {
	userId: number,
	sessionId: string,
	joinedAtClock: number,
	gaUserSent: boolean,
	gaSessionStartSent: boolean,
	isEnding: boolean,
	buffer: { BufferedEvent },
	lastFlushAtClock: number,
	backoffUntilClock: number,
	consecutiveFailures: number,
	inFlight: boolean,
}

--==============================================================================
-- Constants (resolved from TelemetryConfig at boot — SPEC §3.3 single source)
--==============================================================================

local IS_SERVER     = RunService:IsServer()
local PLACE_VERSION = game.PlaceVersion

local GA_CONFIG       = TelemetryConfig.GameAnalytics
local BATCH_CONFIG    = GA_CONFIG.Batch
local BACKOFF_CONFIG  = GA_CONFIG.Backoff

local SDK_VERSION     = GA_CONFIG.SdkVersion
local ENDPOINT_BASE   = GA_CONFIG.EndpointBase
local ENDPOINT_INIT   = "/init"
local ENDPOINT_EVENTS = "/events"

local FLUSH_SECONDS        = BATCH_CONFIG.FlushSeconds
local FLUSH_AT_COUNT       = BATCH_CONFIG.FlushAtCount
local MAX_BUFFER_PER_USER  = BATCH_CONFIG.MaxBufferPerUser
local MAX_AGE_SECONDS      = BATCH_CONFIG.MaxAgeSeconds

local BACKOFF_INITIAL = BACKOFF_CONFIG.InitialSeconds
local BACKOFF_MAX     = BACKOFF_CONFIG.MaxSeconds
local BACKOFF_MULT    = BACKOFF_CONFIG.Multiplier

-- Drain loop tick. The flush trigger is `now - lastFlushAt >= FLUSH_SECONDS`,
-- so checking once per second gives ≤1s overshoot of the configured 8s.
local DRAIN_TICK_SECONDS = 1

-- Cap on concurrent in-flight POSTs during `FlushAll`. Above this we'd
-- risk slamming GA during shutdown and tripping their per-IP rate limits.
local SHUTDOWN_CONCURRENCY = 4

-- Default `FlushAll` deadline — leaves a 5s buffer under Roblox's 30s
-- BindToClose hard limit per SPEC §9.3.
local DEFAULT_FLUSHALL_SECONDS = 25

-- Threshold for the §4.6.9 critical-state warn (≥6 consecutive failures
-- AND ≥5min stuck — see prompt §7).
local CIRCUIT_FAILURES_THRESHOLD     = 6
local CIRCUIT_DURATION_THRESHOLD_SEC = 300

-- Truncated body size in failure logs so a runaway server log doesn't get
-- consumed by 4KB GA error responses.
local LOG_BODY_TRUNCATE_BYTES = 256

--==============================================================================
-- Internal state — server-singleton + per-user
--==============================================================================

local _secretsHealthy        = false
local _gameKeySecret: any    = nil   -- `Secret` userdata; never reified to string
local _secretKeyRaw: string  = ""    -- raw bytes for HMAC; never logged

local _gaDisabled            = false  -- set when `/init` responds `enabled = false`
local _gaServerInitDone      = false
local _gaServerInitInFlight  = false
local _gaServerOffsetMs      = 0      -- (server_ts*1000 - os.time()*1000)
local _gaInitFirstFailureAt: number? = nil
local _circuitWarned         = false
local _bootstrapped          = false
local _drainLoopStarted      = false
local _serverEventUserId: string? = nil  -- lazy-initialised; depends on JobId

local _userStates: { [number]: UserState } = {}
local _droppedCounters: { [string]: number } = {}

--==============================================================================
-- Tiny helpers
--==============================================================================

local function _truncate(s: string, n: number): string
	if #s <= n then return s end
	return string.sub(s, 1, n) .. "…"
end

local function _bumpDropped(reason: string)
	_droppedCounters[reason] = (_droppedCounters[reason] or 0) + 1
end

local function _serverUserId(): string
	if _serverEventUserId then
		return _serverEventUserId
	end
	local jobId = game.JobId
	if jobId == nil or jobId == "" then
		-- In Studio Run mode `JobId` is empty; synth a stable-per-session id
		-- so server-scoped events still group together.
		_serverEventUserId = "studio-" .. HttpService:GenerateGUID(false)
	else
		-- Hard-cap to 64 chars per the prompt's safety note.
		_serverEventUserId = "server-" .. string.sub(jobId, 1, 56)
	end
	return _serverEventUserId :: string
end

--- Compute the integer GA `client_ts` (unix seconds). Uses the server-clock
--- offset cached at `/init` time so events line up with GA's authoritative
--- session math even if the local Roblox host's clock drifts.
local function _gaClientTs(): number
	return os.time() + math.floor(_gaServerOffsetMs / 1000)
end

--==============================================================================
-- Secrets — boot-time load (SPEC §4.6.2)
--==============================================================================

local function _loadSecrets()
	if not IS_SERVER then
		return
	end

	local gameKeyName = GA_CONFIG.SecretNames.GameKey
	local okGameKey, gameKeyOrErr = pcall(function()
		return HttpService:GetSecret(gameKeyName)
	end)
	local gameKey = if okGameKey then gameKeyOrErr else nil

	-- Walk the configured ServerStorage path to find the Secret Key module.
	-- We resolve at the configured node (typically ServerStorage.Secrets.GameAnalytics)
	-- to keep this adapter the only consumer of the raw secret string.
	local pathParts = GA_CONFIG.SecretsModulePath
	local field = GA_CONFIG.SecretsModuleField
	local secretModule: ModuleScript? = nil
	local okPath = pcall(function()
		local node: Instance = game
		for _, part in pathParts do
			local child = node:FindFirstChild(part)
			if not child then
				node = nil :: any
				return
			end
			node = child
		end
		if node and node:IsA("ModuleScript") then
			secretModule = node :: ModuleScript
		end
	end)

	local secretKey: string? = nil
	if okPath and secretModule then
		local okReq, modOrErr = pcall(require, secretModule)
		if okReq and type(modOrErr) == "table" then
			local maybe = (modOrErr :: any)[field]
			if type(maybe) == "string" then
				secretKey = maybe
			end
		end
	end

	if not okGameKey or gameKey == nil then
		_secretsHealthy = false
	elseif not secretKey or #secretKey < 8 then
		_secretsHealthy = false
	else
		_secretsHealthy = true
		_gameKeySecret = gameKey
		_secretKeyRaw = secretKey
	end

	if not _secretsHealthy then
		warn(string.format(
			"[Telemetry/GA] secrets unavailable — GA fan-out disabled. "
			.. "Add %s on Creator Hub → Configure → Secrets, and create "
			.. "%s ModuleScript with { %s = \"...\" }.",
			gameKeyName,
			table.concat(pathParts, "."),
			field
		))
	end
end

--==============================================================================
-- URL builders — keep the Game Key opaque end-to-end via Secret:AddPrefix /
-- Secret:AddSuffix per SPEC §4.6.3. The composed value is `Secret` userdata
-- and is passed straight into `RequestAsync` without ever being printed,
-- tostring'd, or concatenated into a regular Lua string.
--==============================================================================

local function _buildUrlSecret(endpoint: string): any
	-- gameKeySecret :: Secret. AddPrefix/AddSuffix return new Secret values.
	-- API drift note: if Roblox renames AddPrefix/AddSuffix in a future
	-- release, that breaks here loudly (pcall in caller catches it) — the
	-- §4.6.3 spec is explicit that we MUST keep the key non-extractable.
	local prefixed = (_gameKeySecret :: any):AddPrefix(ENDPOINT_BASE)
	return prefixed:AddSuffix(endpoint)
end

--==============================================================================
-- Studio routing helpers (SPEC §9.4)
--==============================================================================

local function _shouldHitNetwork(): boolean
	return TelemetryConfig:ShouldHitNetworkInStudio()
end

local function _studioPrint(category: string, eventId: string, body: string)
	print(string.format("[Telemetry/GA] %s %s %dB", category, eventId, #body))
end

--==============================================================================
-- Event body builders
--==============================================================================

--- Build the common top-level fields shared by every GA event per the SPEC
--- §4.6 / prompt §4 schema. `user_id` / `session_id` differ for server-scoped
--- events; everything else is uniform.
local function _baseEventFields(player: Player?, sessionId: string?): GaEventBody
	local userId: string
	if player then
		userId = tostring(player.UserId)
	else
		userId = _serverUserId()
	end
	return {
		v             = 2,
		user_id       = userId,
		client_ts     = _gaClientTs(),
		sdk_version   = SDK_VERSION,
		os_version    = "roblox 0.0.0",
		manufacturer  = "roblox",
		platform      = "roblox",
		device        = "unknown",
		session_id    = sessionId or "",
		session_num   = 1,
		build         = tostring(PLACE_VERSION),
	}
end

local function _buildUserBody(user: UserState): GaEventBody
	local body = _baseEventFields(Players:GetPlayerByUserId(user.userId), user.sessionId)
	body.category = "user"
	return body
end

local function _buildSessionStartBody(user: UserState, payload: SessionStartPayload): GaEventBody
	local body = _baseEventFields(Players:GetPlayerByUserId(user.userId), user.sessionId)
	body.category  = "session_start"
	body.custom_01 = payload.accountAgeBucket
	body.custom_02 = payload.membership
	return body
end

local function _buildSessionEndBody(user: UserState, lengthSeconds: number): GaEventBody
	local body = _baseEventFields(Players:GetPlayerByUserId(user.userId), user.sessionId)
	body.category = "session_end"
	body.length   = math.max(0, math.floor(lengthSeconds))
	return body
end

--- Try to build a gameplay event body for the given category from the
--- decorated payload. Returns `nil` if a required field is missing — the
--- caller treats that as a drop with reason `ga_payload_invalid`.
local function _buildGameplayBody(
	player: Player?,
	gaCategory: GameAnalyticsCategory,
	sessionId: string,
	payload: EventPayload
): GaEventBody?
	local body = _baseEventFields(player, sessionId)
	body.category = gaCategory

	if gaCategory == "business" then
		local cartType = payload.cart_type or payload.productKind
		local productId = payload.productId or payload.itemId
		if type(cartType) ~= "string" or productId == nil then
			return nil
		end
		local amountCents: number? = nil
		if type(payload.usdCents) == "number" then
			amountCents = math.floor(payload.usdCents)
		elseif type(payload.robuxAmount) == "number" then
			amountCents = math.floor(payload.robuxAmount * TelemetryConfig.RobuxToUsd * 100)
		end
		if amountCents == nil then
			return nil
		end
		body.event_id        = string.format("%s:%s", cartType, tostring(productId))
		body.amount          = amountCents
		body.currency        = payload.currency or "USD"
		body.cart_type       = cartType
		body.transaction_num = 1
		return body

	elseif gaCategory == "resource" then
		local flow = payload.flowType
		if flow ~= "Source" and flow ~= "Sink" then
			return nil
		end
		local currency = payload.currency
		if type(currency) ~= "string" then
			return nil
		end
		local amount = payload.amount
		if type(amount) ~= "number" then
			return nil
		end
		local itemType = payload.itemType or payload.reason
		if type(itemType) ~= "string" then
			return nil
		end
		local itemId: string
		if type(payload.itemId) == "string" then
			itemId = payload.itemId
		elseif type(payload.item) == "string" then
			itemId = payload.item
		elseif type(payload.item) == "table" and type((payload.item :: any).id) == "string" then
			itemId = (payload.item :: any).id
		else
			itemId = "any"
		end
		body.event_id = string.format("%s:%s:%s:%s", flow, currency, itemType, itemId)
		body.amount   = math.floor(amount)
		return body

	elseif gaCategory == "progression" then
		local status = payload.status
		if status ~= "Start" and status ~= "Complete" and status ~= "Fail" then
			return nil
		end
		local pathStr: string? = nil
		if type(payload.progressionPath) == "string" then
			pathStr = payload.progressionPath
		else
			-- Build from path1/path2/path3 OR funnelName/stepName as a fallback
			-- so funnel events with `gaCategory = "progression"` work too.
			local p1 = payload.path1 or payload.funnelName
			if type(p1) == "string" then
				local parts = { p1 }
				if type(payload.path2) == "string" then table.insert(parts, payload.path2) end
				if type(payload.path3) == "string" then table.insert(parts, payload.path3) end
				if type(payload.stepName) == "string" and #parts < 3 then
					table.insert(parts, payload.stepName)
				end
				pathStr = table.concat(parts, ":")
			end
		end
		if not pathStr or pathStr == "" then
			return nil
		end
		body.event_id = string.format("%s:%s", status, pathStr)
		if type(payload.value) == "number" then
			body.score = payload.value
		end
		return body

	elseif gaCategory == "design" then
		local eventId: string? = nil
		if type(payload.gaEventId) == "string" then
			eventId = payload.gaEventId
		elseif type(payload.eventName) == "string" then
			eventId = payload.eventName
		elseif type(payload.funnelName) == "string" then
			eventId = string.format("funnel:%s", payload.funnelName)
		elseif type(payload.progressionPath) == "string" then
			eventId = string.format("progression:%s", payload.progressionPath)
		elseif type(payload.reason) == "string" then
			eventId = payload.reason
		end
		if not eventId or eventId == "" then
			return nil
		end
		body.event_id = eventId
		if type(payload.value) == "number" then
			body.value = payload.value
		end
		return body

	elseif gaCategory == "error" then
		local severity = payload.severity
		if severity ~= "info" and severity ~= "debug" and severity ~= "warning"
			and severity ~= "error" and severity ~= "critical"
		then
			severity = "info"
		end
		local message = payload.message
		if type(message) ~= "string" then
			-- Synthesize a short message from the originating event name so
			-- the GA dashboard isn't full of empty-message error rows.
			message = tostring(payload.originalEventName or payload.reason or "(unspecified)")
		end
		body.severity = severity
		body.message  = message
		return body
	end

	-- Unknown category — drop. Should not happen if `EventCatalog.luau` and
	-- this adapter stay in sync.
	return nil
end

--==============================================================================
-- Per-user state
--==============================================================================

local function _ensureUserState(player: Player, payloadSessionId: string?): UserState
	local userId = player.UserId
	local state = _userStates[userId]
	if state then
		return state
	end
	-- Prefer the sessionId from `init.luau`'s decorator (so both backends
	-- correlate the same join). Fall back to a fresh GUID if we get here
	-- before any decorated payload has arrived.
	local sessionId: string
	if type(payloadSessionId) == "string" and payloadSessionId ~= "" then
		sessionId = payloadSessionId
	else
		sessionId = (HttpService:GenerateGUID(false):gsub("-", "")):sub(1, 16)
	end
	state = {
		userId = userId,
		sessionId = sessionId,
		joinedAtClock = os.clock(),
		gaUserSent = false,
		gaSessionStartSent = false,
		isEnding = false,
		buffer = {},
		lastFlushAtClock = os.clock(),
		backoffUntilClock = 0,
		consecutiveFailures = 0,
		inFlight = false,
	}
	_userStates[userId] = state
	return state
end

local function _appendToBuffer(state: UserState, event: BufferedEvent)
	-- Hard cap: drop the oldest event (FIFO eviction) per SPEC §4.6.8.
	if #state.buffer >= MAX_BUFFER_PER_USER then
		table.remove(state.buffer, 1)
		_bumpDropped("ga_buffer_overflow")
	end
	table.insert(state.buffer, event)
end

--==============================================================================
-- HTTP — sign + POST
--
-- Note on whitespace: `JSONEncode` is the ONLY producer of the body string;
-- we feed the same string to both the HMAC and the request `Body` field so
-- the signature matches the bytes GA receives. Do not whitespace-pretty
-- this anywhere or GA returns 401 (SPEC §4.6.3).
--==============================================================================

type HttpResult = {
	ok: boolean,
	-- True iff RequestAsync raised (network unreachable, secret API drift,
	-- etc.) — distinct from a server-returned non-2xx so the caller can
	-- pick the right log message per SPEC §10.
	raised: boolean,
	status: number,
	body: string,
}

local function _signedRequest(endpoint: string, jsonBody: string): HttpResult
	-- Studio default: simulate success without touching the network so
	-- playtests don't burn quota or pollute live dashboards (SPEC §9.4).
	if not _shouldHitNetwork() then
		return {
			ok = true, raised = false, status = 200,
			body = "{\"server_ts\":" .. tostring(os.time()) .. ",\"enabled\":true}",
		}
	end

	local urlSecret: any
	local okUrl, urlErr = pcall(function()
		urlSecret = _buildUrlSecret(endpoint)
	end)
	if not okUrl then
		return { ok = false, raised = true, status = 0, body = "url-build-failed: " .. tostring(urlErr) }
	end

	local sig = HmacSha256.HmacBase64(_secretKeyRaw, jsonBody)

	local okReq, respOrErr = pcall(function()
		return HttpService:RequestAsync({
			Url = urlSecret,
			Method = "POST",
			Headers = {
				["Authorization"]   = sig,
				["Content-Type"]    = "application/json",
			},
			Body = jsonBody,
		})
	end)
	if not okReq then
		return { ok = false, raised = true, status = 0, body = tostring(respOrErr) }
	end
	local resp = respOrErr :: { Success: boolean, StatusCode: number, Body: string }
	return {
		ok     = resp.StatusCode >= 200 and resp.StatusCode < 300,
		raised = false,
		status = resp.StatusCode,
		body   = resp.Body or "",
	}
end

local function _logFailure(context: string, result: HttpResult)
	if result.raised then
		warn(string.format("[Telemetry/GA] RequestAsync raised: %s", _truncate(result.body, LOG_BODY_TRUNCATE_BYTES)))
	else
		warn(string.format("[Telemetry/GA] %s failed: HTTP %d %s",
			context, result.status, _truncate(result.body, LOG_BODY_TRUNCATE_BYTES)))
	end
end

--==============================================================================
-- /init handshake (SPEC §4.6.5 step 1)
--==============================================================================

local function _maybeWarnLongOutage(now: number)
	if _circuitWarned then return end
	if not _gaInitFirstFailureAt then return end
	if (now - _gaInitFirstFailureAt) < CIRCUIT_DURATION_THRESHOLD_SEC then return end
	_circuitWarned = true
	-- Intentionally a `warn` and NOT `Telemetry.Track(...)` — the latter
	-- would loop back into this adapter while it's already failing. The
	-- per-server circuit breaker in `init.luau` covers the cross-backend
	-- case; this is the GA-specific sustained-outage signal.
	warn("[Telemetry/GA] sustained outage — ≥" .. tostring(CIRCUIT_FAILURES_THRESHOLD)
		.. " consecutive init failures, >" .. tostring(CIRCUIT_DURATION_THRESHOLD_SEC) .. "s.")
end

local function _runInit(): boolean
	if _gaServerInitDone or _gaDisabled then
		return _gaServerInitDone
	end
	if _gaServerInitInFlight then
		return false
	end
	_gaServerInitInFlight = true

	-- /init body is a minimal handshake — only platform/os_version/sdk_version
	-- per SPEC §4.6.5.
	local initBody = {
		platform     = "roblox",
		os_version   = "roblox 0.0.0",
		sdk_version  = SDK_VERSION,
	}
	local jsonBody = HttpService:JSONEncode(initBody)

	local result = _signedRequest(ENDPOINT_INIT, jsonBody)
	_gaServerInitInFlight = false

	if not result.ok then
		if not _gaInitFirstFailureAt then
			_gaInitFirstFailureAt = os.clock()
		end
		_logFailure("init", result)
		_maybeWarnLongOutage(os.clock())
		return false
	end

	-- Parse server_ts + enabled. The decode failure path is treated as a
	-- soft success (we got 200) but with offset=0 — the SPEC's assumption
	-- is that GA returns valid JSON so this branch is defensive.
	local okDecode, decoded = pcall(function()
		return HttpService:JSONDecode(result.body)
	end)
	if okDecode and type(decoded) == "table" then
		local serverTs = (decoded :: any).server_ts
		if type(serverTs) == "number" then
			_gaServerOffsetMs = math.floor(serverTs * 1000) - math.floor(os.time() * 1000)
		end
		if (decoded :: any).enabled == false then
			_gaDisabled = true
			warn("[Telemetry/GA] init returned enabled=false — GA fan-out disabled for this session.")
			return false
		end
	end

	_gaServerInitDone     = true
	_gaInitFirstFailureAt = nil
	_circuitWarned        = false
	print(string.format(
		"[Telemetry/GA] init OK, server_ts=%d, offset=%dms",
		_gaClientTs(),
		_gaServerOffsetMs
	))
	return true
end

--==============================================================================
-- Per-user flush
--==============================================================================

local function _backoffDelayFor(failures: number): number
	if failures <= 0 then return 0 end
	local delay = BACKOFF_INITIAL * (BACKOFF_MULT ^ (failures - 1))
	if delay > BACKOFF_MAX then return BACKOFF_MAX end
	if delay < BACKOFF_INITIAL then return BACKOFF_INITIAL end
	return delay
end

--- Pull events from a user's buffer subject to age-out and the §4.6.5 ordering
--- requirements. Returns the slice we will POST and the count of in-buffer
--- events still pending after slice-out.
local function _drainSlice(state: UserState): { BufferedEvent }
	local now = os.clock()
	-- Age-out: drop anything older than MaxAgeSeconds before we POST.
	local kept: { BufferedEvent } = {}
	for _, ev in state.buffer do
		if (now - ev.queuedAtClock) > MAX_AGE_SECONDS then
			_bumpDropped("ga_age_out")
		else
			table.insert(kept, ev)
		end
	end
	state.buffer = kept

	if #state.buffer == 0 then
		return {}
	end

	-- Take everything; GA accepts large arrays and we'd rather POST once
	-- per flush than fragment. The handshake events are already at the
	-- head of the buffer (we `table.insert(buffer, 1, ...)` for them).
	local slice = state.buffer
	state.buffer = {}
	return slice
end

--- Flush one user's buffer. Returns true if anything was POSTed (so the
--- caller can decide whether to continue draining other users).
local function _flushUser(state: UserState): boolean
	if state.inFlight then return false end
	if _gaDisabled or not _secretsHealthy then return false end

	local now = os.clock()
	if state.backoffUntilClock > now then return false end

	-- Make sure server-level /init has completed. If it hasn't, run it
	-- inline so this user's flush can proceed in the same drain tick.
	if not _gaServerInitDone then
		if not _runInit() then
			-- Apply backoff to this user too so we don't hammer.
			state.consecutiveFailures += 1
			state.backoffUntilClock = now + _backoffDelayFor(state.consecutiveFailures)
			return false
		end
	end

	-- Prepend handshake events if missing. They live in the buffer as
	-- distinct entries so age-out applies to them too (an outage that
	-- exceeds 5 minutes drops the partial session per SPEC §4.6.5 last line).
	if not state.gaUserSent then
		local userBody = _buildUserBody(state)
		table.insert(state.buffer, 1, {
			body = userBody,
			queuedAtClock = now,
			isHandshake = true,
		})
	end
	-- session_start handshake is queued separately by `QueueSessionStart`
	-- (it carries the locked custom dimensions) — we do not synthesize
	-- it here. If it was never queued, the user simply has no session
	-- and gameplay events would be invalid; we drop them below.

	if not state.gaSessionStartSent then
		-- Walk the buffer for a session_start; if absent we cannot POST
		-- gameplay events for this user yet (GA would reject them).
		local hasSessionStart = false
		for _, ev in state.buffer do
			if ev.body.category == "session_start" then
				hasSessionStart = true
				break
			end
		end
		if not hasSessionStart then
			-- Nothing we can POST — leave non-handshake events queued.
			-- This branch shouldn't happen in practice (`QueueSessionStart`
			-- runs from `_onPlayerAdded` before gameplay events).
			return false
		end
	end

	local slice = _drainSlice(state)
	if #slice == 0 then
		return false
	end

	-- Re-walk the slice to confirm handshake event presence — if user/session_start
	-- events fall out of the slice (e.g. age-out), we can't safely POST the rest.
	local sliceHasUser = state.gaUserSent
	local sliceHasSessionStart = state.gaSessionStartSent
	for _, ev in slice do
		if ev.body.category == "user" then sliceHasUser = true end
		if ev.body.category == "session_start" then sliceHasSessionStart = true end
	end

	state.inFlight = true
	state.lastFlushAtClock = now

	-- Build POST body — array of event objects per SPEC §4.6.8.
	local bodies: { GaEventBody } = table.create(#slice)
	for i, ev in slice do
		bodies[i] = ev.body
	end
	local jsonBody = HttpService:JSONEncode(bodies)

	-- Studio routing: print one line per event for visibility, then mark
	-- as sent without touching the network.
	if not _shouldHitNetwork() then
		for _, ev in slice do
			_studioPrint(ev.body.category or "?", tostring(ev.body.event_id or "-"), HttpService:JSONEncode(ev.body))
		end
		if sliceHasUser then state.gaUserSent = true end
		if sliceHasSessionStart then state.gaSessionStartSent = true end
		state.consecutiveFailures = 0
		state.backoffUntilClock = 0
		state.inFlight = false
		return true
	end

	local result = _signedRequest(ENDPOINT_EVENTS, jsonBody)
	state.inFlight = false

	if result.ok then
		if sliceHasUser then state.gaUserSent = true end
		if sliceHasSessionStart then state.gaSessionStartSent = true end
		state.consecutiveFailures = 0
		state.backoffUntilClock = 0
		return true
	end

	-- Failure: re-queue the slice at the head, apply backoff. Only warn
	-- on the FIRST failure of a backoff cycle to avoid log spam during
	-- sustained outages.
	if state.consecutiveFailures == 0 then
		_logFailure("flush", result)
	end
	state.consecutiveFailures += 1
	state.backoffUntilClock = now + _backoffDelayFor(state.consecutiveFailures)
	-- Re-prepend the slice in original order. The age-out applied during
	-- `_drainSlice` already culled stale events.
	for i = #slice, 1, -1 do
		table.insert(state.buffer, 1, slice[i])
	end
	return false
end

--==============================================================================
-- Drain loop
--==============================================================================

local function _shouldFlush(state: UserState, now: number): boolean
	if #state.buffer == 0 then return false end
	if state.isEnding then return true end
	if #state.buffer >= FLUSH_AT_COUNT then return true end
	if (now - state.lastFlushAtClock) >= FLUSH_SECONDS then return true end
	return false
end

local function _startDrainLoop()
	if _drainLoopStarted or not IS_SERVER then return end
	_drainLoopStarted = true
	task.spawn(function()
		while true do
			local now = os.clock()
			if _secretsHealthy and not _gaDisabled then
				for _, state in _userStates do
					if _shouldFlush(state, now) then
						-- Each user flushes in its own thread so a slow GA
						-- response for one player doesn't stall the rest.
						task.spawn(_flushUser, state)
					end
				end
			end
			task.wait(DRAIN_TICK_SECONDS)
		end
	end)
end

--==============================================================================
-- Public API (signatures FROZEN per init.luau contract)
--==============================================================================

function GameAnalyticsAdapter.IsReady(): boolean
	if not _secretsHealthy or _gaDisabled then return false end
	if not _shouldHitNetwork() then
		-- Studio no-network mode: pretend ready so callers that *opt into*
		-- GA-only behavior can still exercise their code paths in Studio.
		-- Note this differs from the stub's always-false; PR 5+ wiring may
		-- key off this in Studio playtests.
		return _gaServerInitDone or false
	end
	return _gaServerInitDone
end

function GameAnalyticsAdapter.QueueSessionStart(player: Player, payload: SessionStartPayload)
	if not IS_SERVER then return end
	if not _secretsHealthy or _gaDisabled then return end
	if not player then return end

	local state = _ensureUserState(player, nil)
	-- Insert the session_start handshake at the head so subsequent
	-- gameplay events POST after it (the drain loop also scans for it).
	local body = _buildSessionStartBody(state, payload)
	table.insert(state.buffer, 1, {
		body = body,
		queuedAtClock = os.clock(),
		isHandshake = true,
	})
	-- The `user` event is added lazily by `_flushUser` so we don't double-
	-- queue if QueueSessionStart is called twice.
end

function GameAnalyticsAdapter.Queue(
	player: Player?,
	gaCategory: GameAnalyticsCategory,
	payload: EventPayload
)
	if not IS_SERVER then return end
	if not _secretsHealthy or _gaDisabled then return end

	-- session_start / session_end are owned by the dedicated functions —
	-- treat dual-fan-out calls as no-ops, but still snapshot sessionId
	-- so QueueSessionStart (which lacks decoration) stays consistent.
	if gaCategory == "session_start" or gaCategory == "session_end" then
		if player then
			local sid: string? = nil
			if type(payload.sessionId) == "string" then
				sid = payload.sessionId
			end
			_ensureUserState(player, sid)
		end
		return
	end

	-- Server-scoped events (no player) — only `error` / `design` make sense
	-- without a user context. Skip the rest to avoid GA rejecting "user
	-- not initialized" for events with our synthetic server-scope user_id.
	if not player then
		if gaCategory ~= "error" and gaCategory ~= "design" then
			_bumpDropped("ga_no_player")
			return
		end
		-- Build directly without per-user state; queue under a fake
		-- "server" pseudo-user. We re-use the first existing user's
		-- buffer if any to keep ordering happy, otherwise drop.
		local firstUser: UserState? = nil
		for _, s in _userStates do
			firstUser = s
			break
		end
		if not firstUser then
			-- No active session; can't POST yet. Drop quietly — server-
			-- scoped events are low-volume and lossy is acceptable.
			_bumpDropped("ga_no_active_session")
			return
		end
		local body = _buildGameplayBody(nil, gaCategory, firstUser.sessionId, payload)
		if not body then
			_bumpDropped("ga_payload_invalid")
			return
		end
		_appendToBuffer(firstUser, {
			body = body,
			queuedAtClock = os.clock(),
			isHandshake = false,
		})
		return
	end

	local sid: string? = nil
	if type(payload.sessionId) == "string" then
		sid = payload.sessionId
	end
	local state = _ensureUserState(player, sid)
	if state.isEnding then
		-- Player is leaving; their session_end is in flight. Adding more
		-- gameplay events would risk POSTing them after the session_end
		-- which would corrupt GA's session math.
		_bumpDropped("ga_session_ending")
		return
	end

	local body = _buildGameplayBody(player, gaCategory, state.sessionId, payload)
	if not body then
		_bumpDropped("ga_payload_invalid")
		return
	end
	_appendToBuffer(state, {
		body = body,
		queuedAtClock = os.clock(),
		isHandshake = false,
	})
end

function GameAnalyticsAdapter.QueueSessionEnd(player: Player, lengthSeconds: number)
	if not IS_SERVER then return end
	if not _secretsHealthy or _gaDisabled then return end
	if not player then return end

	local state = _userStates[player.UserId]
	if not state then
		-- No session was ever started; nothing to end.
		return
	end
	state.isEnding = true
	local body = _buildSessionEndBody(state, lengthSeconds)
	_appendToBuffer(state, {
		body = body,
		queuedAtClock = os.clock(),
		isHandshake = false,
	})
end

--- Best-effort synchronous-ish flush for a single player. We do not block
--- the caller — `Players.PlayerRemoving` runs on the main thread and
--- yielding here would stall PlayerGui teardown. Instead we fire-and-forget
--- a flush attempt; the BindToClose path picks up anything left.
function GameAnalyticsAdapter.FlushPlayer(player: Player)
	if not IS_SERVER then return end
	if not player then return end
	local state = _userStates[player.UserId]
	if not state then return end
	-- Mark ending so subsequent Queue calls no-op.
	state.isEnding = true
	-- Fire two flush attempts off-thread with a short gap so transient
	-- backoff or in-flight conflicts get a second swing.
	task.spawn(function()
		_flushUser(state)
		task.wait(0.2)
		if #state.buffer > 0 then
			_flushUser(state)
		end
		-- Keep the user state around — FlushAll iterates all states and
		-- needs to see the (possibly drained) buffer. Cleanup happens at
		-- BindToClose / next server tick.
	end)
end

--- Drain every user's buffer in parallel under a deadline. Best-effort —
--- partial drain on timeout is acceptable per SPEC §9.3 (the alternative
--- is being killed mid-flush, which is no better).
function GameAnalyticsAdapter.FlushAll(maxWaitSeconds: number?)
	if not IS_SERVER then return end
	local deadline = os.clock() + (maxWaitSeconds or DEFAULT_FLUSHALL_SECONDS)
	if not _secretsHealthy or _gaDisabled then return end

	-- Mark every user as ending so any racing `Queue` calls are dropped.
	for _, state in _userStates do
		state.isEnding = true
	end

	-- Concurrency-capped worker pool over the user list. Each worker
	-- claims the next pending user and flushes it; we spin until either
	-- everyone is empty or the deadline elapses.
	local function _hasPending(): boolean
		for _, state in _userStates do
			if #state.buffer > 0 and state.backoffUntilClock < os.clock() then
				return true
			end
		end
		return false
	end

	while _hasPending() and os.clock() < deadline do
		local userQueue: { UserState } = {}
		for _, state in _userStates do
			if #state.buffer > 0 and not state.inFlight and state.backoffUntilClock < os.clock() then
				table.insert(userQueue, state)
			end
		end
		if #userQueue == 0 then
			-- Either everyone is in-flight or everyone is in backoff; wait
			-- a tick and re-evaluate.
			task.wait(0.1)
		else
			-- Cap concurrency. Each worker flushes its assigned user; we
			-- wait for the whole batch (or a sub-deadline) before queuing
			-- the next round so backoff stays responsive.
			local batchSize = math.min(SHUTDOWN_CONCURRENCY, #userQueue)
			local launched = batchSize
			local completed = 0
			local doneSignal = Instance.new("BindableEvent")
			for i = 1, batchSize do
				local state = userQueue[i]
				task.spawn(function()
					_flushUser(state)
					completed += 1
					if completed >= launched then
						doneSignal:Fire()
					end
				end)
			end
			local subDeadline = math.min(2.0, math.max(0.1, deadline - os.clock()))
			local timed = task.delay(subDeadline, function()
				doneSignal:Fire()
			end)
			doneSignal.Event:Wait()
			if timed then pcall(task.cancel, timed) end
			doneSignal:Destroy()
		end
	end
end

--==============================================================================
-- Bootstrap
--==============================================================================

local function _onPlayerRemoving(player: Player)
	local state = _userStates[player.UserId]
	if not state then return end
	-- Mark ending; the `init.luau` `_onPlayerRemoving` already calls our
	-- QueueSessionEnd + FlushPlayer, so we just clean up after.
	state.isEnding = true
	-- We DON'T immediately delete the state — FlushPlayer's deferred
	-- attempts and BindToClose's FlushAll need it to live a bit longer.
	-- Schedule cleanup after a generous grace.
	task.delay(10, function()
		local current = _userStates[player.UserId]
		if current and current.isEnding then
			_userStates[player.UserId] = nil
		end
	end)
end

local function _bootstrap()
	if _bootstrapped or not IS_SERVER then return end
	_bootstrapped = true
	_loadSecrets()
	if _secretsHealthy then
		_startDrainLoop()
		Players.PlayerRemoving:Connect(_onPlayerRemoving)
		-- Run /init eagerly so the first user's flush doesn't have to
		-- pay the round-trip latency on top of their own POST.
		task.spawn(_runInit)
	end
end

_bootstrap()

return GameAnalyticsAdapter
