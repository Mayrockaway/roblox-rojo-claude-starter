--!strict
--- SecurityPersonnelService
---
--- Owns the "Security Personnel" Robux-gated **run upgrade**: a single-use
--- crewmate hire that grants the player **complete event immunity on their
--- next dispatched shipment**. Stacking is allowed — buying N times protects
--- the next N dispatches.
---
--- Responsibilities:
---   1. **Receipt grant** — register the `security_personnel` consumable
---      handler with `MonetizationService`. A successful Robux receipt for
---      `consumable.security_personnel_x1` lands here → +1 stack on the
---      player's run-upgrade inventory in `OilStateService` → push state
---      so any open `ShipOilPanelGui` shows the new owned count.
---   2. **Dispatch consume** — `OilShipmentService:_handleDispatch` calls
---      `:TryConsumeForDispatch(userId)` after the shipment table is built.
---      We decrement one stack atomically and return `true` so the caller
---      stamps `shipment.eventImmunity = true`. The strait waypoint handler
---      and the forced contract pirate path read that flag and short-circuit
---      every event roll for the rest of the voyage.
---
--- This service intentionally has **no remote events** — there is nothing
--- the client can ask it to do directly. The buy CTA is just a Robux prompt
--- routed through `MonetizationService`; consumption is server-driven on
--- dispatch. That keeps the surface tiny and unspoofable.
---
--- Refund policy mirrors `ArmyGeneralService`: returning `false` from the
--- consumable handler leaves the receipt unfinished, Roblox auto-refunds on
--- next session. The only failure path here is "no oil state" (player left
--- between purchase confirmation and receipt) which is rare and recoverable.

local Players = game:GetService("Players")

local SecurityPersonnelService = {}

--- Stable id used by both `MonetizationCatalog` (`grant.consumable.id`) and
--- `OilStateService:Add/Get/ConsumeRunUpgradeOwned`. Renaming invalidates
--- outstanding receipts — same caveat as every other id in the monetization
--- pipeline; treat as permanent once products go live.
local CONSUMABLE_ID = "security_personnel"
local RUN_UPGRADE_ID = "security_personnel"

function SecurityPersonnelService:Init(oilStateService)
	self._oilStateService = oilStateService
	-- Wired by `init.server.luau:SetMonetizationService` after both services
	-- exist. Until then the consumable id has no handler, which causes
	-- `_processReceipt` to return `NotProcessedYet` (auto-refund). That's the
	-- correct "fail safe" behavior during half-wired bring-up.
	self._monetizationService = nil
	self._running = false
end

--- Inject `MonetizationService` and register the `security_personnel`
--- consumable handler. The handler is the *only* path that grants run-upgrade
--- inventory — no admin command, no FTUE freebie. Adding either later means
--- calling `OilStateService:AddRunUpgradeOwned(userId, "security_personnel", n)`
--- + `:PushState(userId)` directly.
function SecurityPersonnelService:SetMonetizationService(monetizationService)
	self._monetizationService = monetizationService
	if not monetizationService then
		return
	end
	monetizationService:SetConsumableHandler(CONSUMABLE_ID, function(userId: number, quantity: number): (boolean, string?)
		local n = quantity
		if typeof(n) ~= "number" or n <= 0 then
			n = 1
		end
		-- `AddRunUpgradeOwned` is a no-op when state hasn't loaded yet
		-- (player left mid-receipt). Treat as "not granted" so Roblox
		-- retries on next session and the player gets their stack — same
		-- pattern `_grantShip` uses for `OK_ALREADY_OWNED`.
		if not self._oilStateService then
			return false, "ERR_NO_OIL_STATE"
		end
		local before = self._oilStateService:GetRunUpgradeOwned(userId, RUN_UPGRADE_ID) or 0
		self._oilStateService:AddRunUpgradeOwned(userId, RUN_UPGRADE_ID, math.floor(n))
		local after = self._oilStateService:GetRunUpgradeOwned(userId, RUN_UPGRADE_ID) or 0
		if after <= before then
			-- State write silently dropped (no profile loaded). Refund.
			return false, "ERR_GRANT_FAILED"
		end
		pcall(function()
			self._oilStateService:PushState(userId)
		end)
		return true, nil
	end)
end

function SecurityPersonnelService:Start()
	if self._running then
		return
	end
	self._running = true
end

function SecurityPersonnelService:Stop()
	self._running = false
end

--- Server-only entry point called by `OilShipmentService:_handleDispatch`
--- after the `shipment` table is built and before `_runShipment` spawns.
---
--- Returns `true` when one stack was consumed and the caller should stamp
--- `shipment.eventImmunity = true`. Returns `false` when the player owned
--- nothing (do nothing — normal voyage rolls events as usual).
---
--- Pushes oil state on a successful consume so the open `ShipOilPanelGui`
--- updates the owned count badge in the same frame as the dispatch.
function SecurityPersonnelService:TryConsumeForDispatch(userId: number): boolean
	if not self._oilStateService then
		return false
	end
	local owned = self._oilStateService:GetRunUpgradeOwned(userId, RUN_UPGRADE_ID) or 0
	if owned <= 0 then
		return false
	end
	local consumed = self._oilStateService:ConsumeRunUpgradeOwned(userId, RUN_UPGRADE_ID, 1)
	if not consumed then
		return false
	end
	-- Best-effort push so the panel "x N" badge tracks the consume. Wrapped
	-- in pcall: if PushState throws (e.g. mid-shutdown) the dispatch must
	-- still proceed because we already decremented the stack.
	pcall(function()
		self._oilStateService:PushState(userId)
	end)
	if Players:GetPlayerByUserId(userId) then
		-- Optional debug breadcrumb; no DevLog import to keep this file dep-free.
		-- print(string.format("[SecurityPersonnel] Consumed 1 stack for userId=%d (was %d).", userId, owned))
	end
	return true
end

--- Read-only owned count. Useful for tests / future dev commands; the live
--- UI should read `runUpgradeOwnedByItemId.security_personnel` from the oil
--- state snapshot rather than calling this from the client (which can't).
function SecurityPersonnelService:GetOwnedCount(userId: number): number
	if not self._oilStateService then
		return 0
	end
	return self._oilStateService:GetRunUpgradeOwned(userId, RUN_UPGRADE_ID) or 0
end

return SecurityPersonnelService
