--!strict
--- GlobalEventClientState — single client-side subscriber for `GlobalEventStateUpdate`.
--
-- The server (`GlobalEventService`) emits a snapshot whenever the active
-- event set changes. Multiple client UIs (currently `GlobalEventBanner`
-- and `SellOilPanel`) need to react:
--   * `GlobalEventBanner` renders rows + chrome accents.
--   * `SellOilPanel` recolors / re-tweens / re-prices labels while
--     `cash_frenzy` (or any future CashMultiplier event) is active.
--
-- Rather than have each UI open its own `OnClientEvent` connection (and
-- duplicate the snapshot-parsing + active-table state), this module owns
-- one connection, one parsed snapshot, and exposes a tiny query API +
-- a `Changed` BindableEvent.
--
-- Server snapshot intentionally does NOT carry the raw effect value
-- (`GlobalEventConfig.EventSnapshot` excludes `effect`) — the client
-- reads `GlobalEventConfig.Events[id].effect` directly from the shared
-- module to compute multipliers. Server still applies the actual reward
-- on `OilStateService:AddCash`, so leaking the multiplier here only
-- affects display, never the credited cash.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = Shared:WaitForChild("Net")
local RemoteNames = require(Net:WaitForChild("RemoteNames"))
local GlobalEventConfig = require(Shared:WaitForChild("Config"):WaitForChild("GlobalEventConfig"))

export type ActiveEntry = {
	id: string,
	displayName: string,
	subtitle: string,
	bannerKind: string,
	expiresAt: number,
	helpText: string?,
}

local GlobalEventClientState = {}

local _started = false
local _player: Player? = nil
local _remoteConn: RBXScriptConnection? = nil

local _activeById: { [string]: ActiveEntry } = {}
local _serverClockOffset: number = 0
local _changed: BindableEvent = Instance.new("BindableEvent")

--==============================================================================
-- Snapshot ingestion
--==============================================================================

local function applySnapshot(snapshot: any)
	if typeof(snapshot) ~= "table" then return end

	local serverNow = tonumber(snapshot.serverNow) or 0
	if serverNow > 0 then
		_serverClockOffset = os.clock() - serverNow
	end

	local incoming: { [string]: ActiveEntry } = {}
	if typeof(snapshot.active) == "table" then
		for _, raw in ipairs(snapshot.active) do
			if typeof(raw) == "table" and typeof(raw.id) == "string" and raw.id ~= "" then
				incoming[raw.id] = {
					id = raw.id,
					displayName = tostring(raw.displayName or raw.id),
					subtitle = tostring(raw.subtitle or ""),
					bannerKind = tostring(raw.bannerKind or "Threat"),
					expiresAt = tonumber(raw.expiresAt) or (serverNow + 1),
					helpText = (typeof(raw.helpText) == "string") and raw.helpText or nil,
				}
			end
		end
	end

	_activeById = incoming
	_changed:Fire()
end

--==============================================================================
-- Public API
--==============================================================================

--- Returns the **product** of every active `CashMultiplier` event's
--- `effect.value`. Defaults to `1` (no boost). Stacking is multiplicative
--- to mirror server behavior (`OilStateService:AddCash` multiplies the
--- GamePass DoubleEarnings by the global multiplier).
function GlobalEventClientState.GetCashMultiplier(): number
	local mul = 1
	for id, _ in pairs(_activeById) do
		local def = GlobalEventConfig.Events[id]
		if def and def.effect and def.effect.kind == "CashMultiplier" then
			local v = tonumber(def.effect.value) or 1
			if v > 0 then
				mul *= v
			end
		end
	end
	return mul
end

--- True when ANY global event is currently active. Used by chrome
--- treatments that should pulse regardless of which event is live
--- (e.g. the gold UIStroke + pulse on `GlobalEventBannerGui`).
function GlobalEventClientState.IsAnyActive(): boolean
	return next(_activeById) ~= nil
end

--- Read-only view of the current active set. Returned table is the
--- live module-internal map — DO NOT mutate. Re-call after every
--- `Changed` fire (entries are replaced wholesale on each snapshot).
function GlobalEventClientState.GetActiveById(): { [string]: ActiveEntry }
	return _activeById
end

--- Approximate server clock for countdown rendering. Banner controllers
--- typically subtract this from `entry.expiresAt`.
function GlobalEventClientState.ApproxServerNow(): number
	return os.clock() - _serverClockOffset
end

--- Fires whenever a new snapshot replaces the active table. Listeners
--- should re-query `GetCashMultiplier` / `IsAnyActive` rather than
--- diffing themselves.
GlobalEventClientState.Changed = _changed.Event

--==============================================================================
-- Lifecycle
--==============================================================================

function GlobalEventClientState.start()
	if _started then return end
	_started = true
	_player = Players.LocalPlayer
	if not _player then
		warn("[GlobalEventClientState] LocalPlayer missing — start aborted")
		_started = false
		return
	end

	-- Same path as `GlobalEventBanner`: `Remotes` lives under `Shared`.
	-- See `RemoteService.luau:25` (`remotesFolder.Parent = Shared`).
	local remotesRoot = Shared:WaitForChild("Remotes", 10)
	if not remotesRoot then
		warn("[GlobalEventClientState] ReplicatedStorage.Shared.Remotes missing")
		return
	end
	local remote = remotesRoot:WaitForChild(RemoteNames.GlobalEventStateUpdate, 10)
	if not remote or not remote:IsA("RemoteEvent") then
		warn("[GlobalEventClientState] " .. RemoteNames.GlobalEventStateUpdate .. " remote missing")
		return
	end

	_remoteConn = remote.OnClientEvent:Connect(applySnapshot)
end

function GlobalEventClientState.stop()
	if _remoteConn then _remoteConn:Disconnect() ; _remoteConn = nil end
	_activeById = {}
	_started = false
	_changed:Fire()
end

return GlobalEventClientState
