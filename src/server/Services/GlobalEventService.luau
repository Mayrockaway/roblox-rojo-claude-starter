--!strict
--- GlobalEventService
---
--- Owns the **server-wide global event** rotation: weighted random pick of
--- buff / threat events from `GlobalEventConfig`, broadcast to every client
--- via the `GlobalEventStateUpdate` remote, and a small query API
--- (`GetMultiplier`, `IsActive`, `GetForcedStraitEventId`,
--- `GetShipStatsBoost`) consumed by gameplay services at narrow hook sites
--- (`OilStateService:AddCash`, `OilShipmentService:_handleDispatch`,
--- `OilShipmentService:_handleStraitWaypointTrigger`).
---
--- Lifecycle (mirrors other services' pattern in `init.server.luau`):
---   1. `Init(remoteService)` — store deps, no side effects.
---   2. `Start()` — spawn the rotation tick loop; hook `Players.PlayerAdded`
---      so joiners receive the current snapshot immediately (otherwise they
---      sit on a stale "no events" state until the next broadcast tick).
---   3. `Stop()` — disconnect, flush expirations.
---
--- All wall-clock timing uses `workspace:GetServerTimeNow()` (network-replica
--- safe, monotonic across studio/test) so server lag does not extend events
--- and the client renders the same `expiresAt` for a consistent countdown.
---
--- Telemetry: emits `global_event_started` and `global_event_ended` via
--- `Shared.Telemetry.Track`. Catalog rows for both already exist (see
--- `EventCatalog.luau` §6.5).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GlobalEventConfig = require(Shared:WaitForChild("Config"):WaitForChild("GlobalEventConfig"))
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))
local Telemetry = require(Shared:WaitForChild("Telemetry"))

local GlobalEventService = {}
GlobalEventService.__index = GlobalEventService

--==============================================================================
-- Types
--==============================================================================

type ActiveEvent = {
	id: string,
	startedAt: number,
	expiresAt: number,
	source: string, -- "rotation" / "debug" — for telemetry attribution
}

--==============================================================================
-- Init / lifecycle
--==============================================================================

function GlobalEventService:Init(remoteService: any)
	self._remoteService = remoteService
	self._running = false

	--- Active events keyed by `id`. We only allow one active per id (a second
	--- activation while the first is live is rejected); for "stack two events
	--- of the same kind" use case the rotation can pick a *different* id.
	self._activeById = {} :: { [string]: ActiveEvent }

	--- Last activation timestamp (workspace:GetServerTimeNow()) per event id.
	--- Used for per-event `cooldownSeconds` enforcement so the picker can
	--- skip an id whose cooldown hasn't elapsed yet. Cleared on `Stop`.
	self._lastActivatedAt = {} :: { [string]: number }

	--- When the next rotation roll is allowed to pick. Set to
	--- `serverTimeNow + bootDelaySeconds` on `Start`, then to
	--- `endTime + uniform(min, max)` after each event ends.
	self._nextPickAt = math.huge

	self._connections = {}
	self._heartbeat = nil :: RBXScriptConnection?
	self._tickAccumulator = 0

	--- Cached `Random` so the weighted picker is reproducible per server
	--- instance (no shared state across servers — each server seeds from
	--- its own job id implicitly via Random.new() default).
	self._rng = Random.new()
end

function GlobalEventService:Start()
	if self._running then
		return
	end
	self._running = true

	local cfg = GlobalEventConfig.RotationConfig
	local now = workspace:GetServerTimeNow()
	self._nextPickAt = now + math.max(0, cfg.bootDelaySeconds)

	self._connections.playerAdded = Players.PlayerAdded:Connect(function(player)
		--- Defer one frame so the client's `WaitForChild("Remotes")` resolves
		--- before we fire — same defensive pattern other services use to
		--- avoid joiner races.
		task.defer(function()
			if not self._running then return end
			self:_pushSnapshotToPlayer(player)
		end)
	end)

	self._heartbeat = RunService.Heartbeat:Connect(function(dt)
		self:_onHeartbeat(dt)
	end)

	--- Initial broadcast so any already-present players (Studio Test, dev
	--- replays) see the empty snapshot rather than a `WaitForChild` race.
	self:_broadcastSnapshot()
end

function GlobalEventService:Stop()
	self._running = false
	for _, conn in pairs(self._connections) do
		if conn and conn.Connected then
			conn:Disconnect()
		end
	end
	self._connections = {}
	if self._heartbeat then
		self._heartbeat:Disconnect()
		self._heartbeat = nil
	end
	self._activeById = {}
	self._lastActivatedAt = {}
end

--==============================================================================
-- Public query API (consumed by hook sites)
--==============================================================================

--- Whether `eventId` is currently active. Cheap O(1) lookup; safe to call
--- from hot paths (`AddCash`, per-tick drilling production, etc).
function GlobalEventService:IsActive(eventId: string): boolean
	return self._activeById[eventId] ~= nil
end

--- Multiplier for a metric (`"Cash"` is the only metric today). Returns 1.0
--- when no active event modifies the metric. Multiple events stacking on
--- the same metric multiply together (so two CashMultiplier=2 events would
--- yield ×4) — a single-event design today, but the math is general.
---
--- Hook site: `OilStateService:AddCash` reads `GetMultiplier("Cash")`
--- AFTER the `DoubleEarnings` GamePass multiplier so the two stack
--- multiplicatively (GamePass owner during Cash Frenzy = ×4).
function GlobalEventService:GetMultiplier(metric: string): number
	local result = 1.0
	for id, _ in pairs(self._activeById) do
		local def = GlobalEventConfig.Events[id]
		if def and def.effect.kind == "CashMultiplier" then
			if metric == "Cash" then
				local v = tonumber(def.effect.value) or 1.0
				if v > 0 then
					result = result * v
				end
			end
		end
	end
	return result
end

--- Combined ship stats boost across all active `ShipStatsBoost` events.
--- Returns a table whose missing fields default to 1.0; the consumer
--- (`OilShipmentService:_handleDispatch`) clamps the resulting
--- `travelSeconds` against `ShipStats` minimums to avoid pathological
--- 0-second voyages from a future "instant ship" event misconfig.
---
--- When no boost is active returns `{ speedMul = 1, capacityMul = 1,
--- eventRiskMul = 1 }` — callers can treat the table identically to "no
--- event" without a nil branch.
function GlobalEventService:GetShipStatsBoost(): { speedMul: number, capacityMul: number, eventRiskMul: number }
	local speed, cap, risk = 1.0, 1.0, 1.0
	for id, _ in pairs(self._activeById) do
		local def = GlobalEventConfig.Events[id]
		if def and def.effect.kind == "ShipStatsBoost" then
			local s = tonumber(def.effect.speedMul) or 1.0
			local c = tonumber(def.effect.capacityMul) or 1.0
			local r = tonumber(def.effect.eventRiskMul) or 1.0
			if s > 0 then speed = speed * s end
			if c > 0 then cap = cap * c end
			if r > 0 then risk = risk * r end
		end
	end
	return { speedMul = speed, capacityMul = cap, eventRiskMul = risk }
end

--- Currently-forced strait waypoint event id from an active
--- `ForceStraitEvent`, or `nil` when none. If multiple are active (allowed
--- in schema; none in the current catalog), the lexicographically-first id
--- wins for determinism.
---
--- Hook site: `OilShipmentService:_handleStraitWaypointTrigger` consults
--- this after FTUE suppress and Security Personnel immunity; see that
--- function for how occurrence and catalog pick interact with the override.
function GlobalEventService:GetForcedStraitEventId(): string?
	local picked: string? = nil
	for id, _ in pairs(self._activeById) do
		local def = GlobalEventConfig.Events[id]
		if def and def.effect.kind == "ForceStraitEvent" then
			local strait = def.effect.straitEventId
			if typeof(strait) == "string" and strait ~= "" then
				if picked == nil or strait < picked then
					picked = strait
				end
			end
		end
	end
	return picked
end

--==============================================================================
-- Activation / expiration
--==============================================================================

--- Try to activate an event by id. Returns `(ok, reason)`. Reasons:
---   * `"OK"`               — activated.
---   * `"ERR_UNKNOWN_ID"`   — id not in `GlobalEventConfig.Events`.
---   * `"ERR_ALREADY_ACTIVE"` — same id already active.
---   * `"ERR_COOLDOWN"`     — id-specific cooldown not yet elapsed.
---   * `"ERR_MUTEX"`        — another event in a `mutuallyExclusiveGroups`
---                            entry is currently active.
---   * `"ERR_MAX_CONCURRENT"`— activation would exceed
---                            `RotationConfig.maxConcurrentEvents`.
---
--- `source` is recorded on the active-event row for telemetry attribution
--- (`"rotation"`, `"debug"`, future `"robux_boost"`). Caller controls
--- duration override only when `durationOverrideSeconds` is provided —
--- normal callers pass `nil` to use the configured `durationSeconds`.
function GlobalEventService:Activate(eventId: string, source: string?, durationOverrideSeconds: number?): (boolean, string)
	local def = GlobalEventConfig.Events[eventId]
	if not def then
		return false, "ERR_UNKNOWN_ID"
	end
	if self._activeById[eventId] then
		return false, "ERR_ALREADY_ACTIVE"
	end

	local now = workspace:GetServerTimeNow()
	local lastAt = self._lastActivatedAt[eventId]
	if lastAt and (now - lastAt) < def.cooldownSeconds then
		return false, "ERR_COOLDOWN"
	end

	local cfg = GlobalEventConfig.RotationConfig
	if cfg.mutuallyExclusiveGroups then
		for _, group in ipairs(cfg.mutuallyExclusiveGroups) do
			local thisInGroup = false
			for _, gid in ipairs(group) do
				if gid == eventId then
					thisInGroup = true
					break
				end
			end
			if thisInGroup then
				for _, gid in ipairs(group) do
					if gid ~= eventId and self._activeById[gid] then
						return false, "ERR_MUTEX"
					end
				end
			end
		end
	end

	local activeCount = 0
	for _ in pairs(self._activeById) do
		activeCount += 1
	end
	if activeCount >= (cfg.maxConcurrentEvents or 1) then
		return false, "ERR_MAX_CONCURRENT"
	end

	local duration = tonumber(durationOverrideSeconds) or def.durationSeconds
	if duration <= 0 then
		return false, "ERR_BAD_DURATION"
	end

	local active: ActiveEvent = {
		id = eventId,
		startedAt = now,
		expiresAt = now + duration,
		source = source or "manual",
	}
	self._activeById[eventId] = active
	self._lastActivatedAt[eventId] = now

	Telemetry.Track(nil, "global_event_started", {
		eventId = eventId,
		bannerKind = def.bannerKind,
		effectKind = def.effect.kind,
		durationSeconds = duration,
		source = active.source,
	})

	self:_broadcastSnapshot()
	return true, "OK"
end

--- Force-end an event regardless of remaining time. Returns whether the
--- event was active. Used by the dev `/event end <id>` command and by
--- future tests; rotation never calls this directly (it relies on the
--- heartbeat-driven natural expiry below).
function GlobalEventService:ForceEnd(eventId: string): boolean
	if not self._activeById[eventId] then
		return false
	end
	self:_endEvent(eventId, "force_end")
	self:_broadcastSnapshot()
	return true
end

--==============================================================================
-- Debug helpers (dev / chat commands)
--==============================================================================

--- Returns a sorted list of `{ id, durationSeconds, weight, cooldownSeconds }`
--- for the chat-command help printer. Pure read; safe to call any time.
function GlobalEventService:DebugListEvents(): { { id: string, durationSeconds: number, weight: number, cooldownSeconds: number, active: boolean } }
	local out = {}
	for _, id in ipairs(GlobalEventConfig.GetEventIdsSorted()) do
		local def = GlobalEventConfig.Events[id]
		if def then
			table.insert(out, {
				id = id,
				durationSeconds = def.durationSeconds,
				weight = def.weight,
				cooldownSeconds = def.cooldownSeconds,
				active = self._activeById[id] ~= nil,
			})
		end
	end
	return out
end

--- Bypasses cooldown + min-player gates so QA can fire any event on demand.
--- Mirrors the `/missile`, `/storm`, etc. patterns in `init.server.luau`.
function GlobalEventService:DebugActivate(eventId: string, durationOverrideSeconds: number?): (boolean, string)
	self._lastActivatedAt[eventId] = nil -- bypass per-event cooldown
	return self:Activate(eventId, "debug", durationOverrideSeconds)
end

--==============================================================================
-- Internal: heartbeat / rotation
--==============================================================================

function GlobalEventService:_onHeartbeat(dt: number)
	if not self._running then return end
	self._tickAccumulator += dt
	local interval = GlobalEventConfig.RotationConfig.tickIntervalSeconds or 1.0
	if self._tickAccumulator < interval then return end
	self._tickAccumulator = 0

	local now = workspace:GetServerTimeNow()

	--- Expire any events whose `expiresAt` has passed. Iterate over a
	--- captured key list because `_endEvent` mutates `_activeById`.
	local toExpire: { string } = {}
	for id, ae in pairs(self._activeById) do
		if now >= ae.expiresAt then
			table.insert(toExpire, id)
		end
	end
	if #toExpire > 0 then
		for _, id in ipairs(toExpire) do
			self:_endEvent(id, "expired")
		end
		self:_broadcastSnapshot()
		--- An event just ended; re-arm the next-pick clock.
		self:_scheduleNextPick(now)
	end

	--- Try to activate a rotation-picked event when it's time and the
	--- floor of active concurrent events has room. Per-tick check is
	--- cheap so we don't bother with a separate timer.
	if now >= self._nextPickAt then
		self:_attemptRotationActivation(now)
	end
end

function GlobalEventService:_scheduleNextPick(now: number)
	local cfg = GlobalEventConfig.RotationConfig
	local minS = math.max(1, cfg.minSecondsBetweenEvents)
	local maxS = math.max(minS, cfg.maxSecondsBetweenEvents)
	local gap = self._rng:NextNumber(minS, maxS)
	self._nextPickAt = now + gap
end

function GlobalEventService:_attemptRotationActivation(now: number)
	local cfg = GlobalEventConfig.RotationConfig
	if #Players:GetPlayers() < (cfg.minPlayersToActivate or 1) then
		--- Don't fire events for a near-empty server, but DO push the next
		--- pick clock forward so we re-check soon. Using a short retry so
		--- a player joining mid-cooldown gets an event quickly without
		--- waiting a full 8-12 min from THIS check.
		self._nextPickAt = now + math.min(60, cfg.minSecondsBetweenEvents)
		return
	end

	local activeCount = 0
	for _ in pairs(self._activeById) do
		activeCount += 1
	end
	if activeCount >= (cfg.maxConcurrentEvents or 1) then
		--- An event is already running; defer to its expiration to schedule
		--- the next pick. (Heartbeat above will call `_scheduleNextPick`
		--- when the active event ends.)
		return
	end

	local picked = self:_pickEventByWeight(now)
	if not picked then
		--- Nothing eligible (all on cooldown, or all weights zero). Try
		--- again soon rather than hard-stop.
		self._nextPickAt = now + 60
		return
	end

	local ok, reason = self:Activate(picked, "rotation", nil)
	if not ok then
		--- Activation can still fail mutex/cooldown after pick (race with
		--- a debug activation). Log + try again soon.
		warn(string.format("[GlobalEventService] rotation Activate(%s) failed: %s", picked, reason))
		self._nextPickAt = now + 60
		return
	end
	--- Activated; the pick clock will be re-armed by the heartbeat when
	--- this event expires. (See `_onHeartbeat` -> `_scheduleNextPick`.)
end

function GlobalEventService:_pickEventByWeight(now: number): string?
	--- Build the eligible set: known event id, weight > 0, not currently
	--- active, and per-id cooldown elapsed. Iterate sorted ids so identical
	--- RNG seeds across server restarts produce reproducible sequences for
	--- tests / replays.
	local eligible: { { id: string, weight: number } } = {}
	local total = 0
	for _, id in ipairs(GlobalEventConfig.GetEventIdsSorted()) do
		local def = GlobalEventConfig.Events[id]
		if not def then continue end
		if def.weight <= 0 then continue end
		if self._activeById[id] then continue end
		local lastAt = self._lastActivatedAt[id]
		if lastAt and (now - lastAt) < def.cooldownSeconds then continue end
		table.insert(eligible, { id = id, weight = def.weight })
		total += def.weight
	end
	if #eligible == 0 or total <= 0 then
		return nil
	end
	local roll = self._rng:NextNumber() * total
	local accum = 0
	for _, entry in ipairs(eligible) do
		accum += entry.weight
		if roll <= accum then
			return entry.id
		end
	end
	--- Fallback to last entry if floating-point edge: shouldn't be reachable
	--- but cheaper than a `math.huge` sentinel and identical behavior.
	return eligible[#eligible].id
end

function GlobalEventService:_endEvent(eventId: string, reason: string)
	local ae = self._activeById[eventId]
	if not ae then return end
	self._activeById[eventId] = nil
	local def = GlobalEventConfig.Events[eventId]
	local startedAt = ae.startedAt
	Telemetry.Track(nil, "global_event_ended", {
		eventId = eventId,
		bannerKind = def and def.bannerKind or "Unknown",
		effectKind = def and def.effect.kind or "Unknown",
		durationDelivered = math.max(0, workspace:GetServerTimeNow() - startedAt),
		reason = reason,
		source = ae.source,
	})
end

--==============================================================================
-- Internal: broadcast
--==============================================================================

function GlobalEventService:_buildSnapshotPayload(): { active: { any }, serverNow: number }
	local now = workspace:GetServerTimeNow()
	local active = {}
	for id, ae in pairs(self._activeById) do
		local def = GlobalEventConfig.Events[id]
		if def then
			table.insert(active, {
				id = id,
				displayName = def.displayName,
				subtitle = def.subtitle,
				bannerKind = def.bannerKind,
				expiresAt = ae.expiresAt,
				helpText = def.helpText,
			})
		end
	end
	return { active = active, serverNow = now }
end

function GlobalEventService:_broadcastSnapshot()
	if not self._remoteService then return end
	local ev = self._remoteService:GetEvent(RemoteNames.GlobalEventStateUpdate)
	ev:FireAllClients(self:_buildSnapshotPayload())
end

function GlobalEventService:_pushSnapshotToPlayer(player: Player)
	if not self._remoteService then return end
	local ev = self._remoteService:GetEvent(RemoteNames.GlobalEventStateUpdate)
	ev:FireClient(player, self:_buildSnapshotPayload())
end

return GlobalEventService
