--!strict
--- CargoHaulerService
---
--- Owns the "Cargo Hauler" Robux-gated **run upgrade**: a single-use crewmate
--- hire that **doubles every barrel on the player's next dispatched shipment**.
--- Stacking is allowed — buying N times boosts the next N dispatches.
---
--- Responsibilities mirror `SecurityPersonnelService` exactly:
---   1. **Receipt grant** — register the `cargo_hauler` consumable handler
---      with `MonetizationService`. A successful Robux receipt for
---      `consumable.cargo_hauler_x1` lands here → +1 stack on the player's
---      run-upgrade inventory in `OilStateService` → push state so any open
---      `ShipOilPanelGui` shows the new owned count.
---   2. **Dispatch consume** — `OilShipmentService:_handleDispatch` calls
---      `:TryConsumeForDispatch(userId)` after the shipment table is built.
---      We decrement one stack and return `true` so the caller stamps
---      `shipment.cargoHauled = true` AND multiplies `manifest[tier]` ×2 +
---      `totalLoaded` ×2 before `_runShipment` spawns. The doubled manifest
---      flows naturally into delivery (the loop at `_handleDelivery` reads
---      `shipment.manifest`), warehouse credit, and pirate-steal math.
---
--- This service intentionally has **no remote events** and **no deck-rig
--- mount** — the visible signal lives in the `ShipOilPanel` capacity
--- readout (gold "×2" badge when armed). Adding a deck rig later is a
--- mirror of `SecurityPersonnelService:MountForShipment`.
---
--- Refund policy: returning `false` from the consumable handler leaves the
--- receipt unfinished, Roblox auto-refunds on next session. The only
--- failure path here is "no oil state" (player left between purchase
--- confirmation and receipt), which is rare and recoverable.

local Players = game:GetService("Players")

local CargoHaulerService = {}

--- Stable id used by both `MonetizationCatalog` (`grant.consumable.id`) and
--- `OilStateService:Add/Get/ConsumeRunUpgradeOwned`. Renaming invalidates
--- outstanding receipts — same caveat as every other id in the
--- monetization pipeline; treat as permanent once products go live.
local CONSUMABLE_ID = "cargo_hauler"
local RUN_UPGRADE_ID = "cargo_hauler"

--- The barrel multiplier this run-upgrade applies on dispatch. Lifted to
--- a constant so the doubling factor is grep-able and a future rebalance
--- (e.g. tripling) is a single-line change. `OilShipmentService` reads
--- this from the service via `GetMultiplier` so the server stays the only
--- place that knows the magnitude.
local DISPATCH_MULTIPLIER = 2

function CargoHaulerService:Init(oilStateService)
	self._oilStateService = oilStateService
	-- Wired by `init.server.luau:SetMonetizationService` after both services
	-- exist. Until then the consumable id has no handler, which causes
	-- `_processReceipt` to return `NotProcessedYet` (auto-refund). That's the
	-- correct "fail safe" behavior during half-wired bring-up.
	self._monetizationService = nil
	self._running = false
end

--- Inject `MonetizationService` and register the `cargo_hauler` consumable
--- handler. The handler is the *only* path that grants run-upgrade
--- inventory — no admin command, no FTUE freebie. Adding either later
--- means calling `OilStateService:AddRunUpgradeOwned(userId, "cargo_hauler", n)`
--- + `:PushState(userId)` directly.
function CargoHaulerService:SetMonetizationService(monetizationService)
	self._monetizationService = monetizationService
	if not monetizationService then
		return
	end
	monetizationService:SetConsumableHandler(CONSUMABLE_ID, function(userId: number, quantity: number): (boolean, string?)
		local n = quantity
		if typeof(n) ~= "number" or n <= 0 then
			n = 1
		end
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

function CargoHaulerService:Start()
	if self._running then
		return
	end
	self._running = true
end

function CargoHaulerService:Stop()
	self._running = false
end

--- Server-only entry point called by `OilShipmentService:_handleDispatch`
--- after the `shipment` table is built and before `_runShipment` spawns.
---
--- Returns `true` when one stack was consumed and the caller should
--- multiply `manifest[tier]` + `totalLoaded` by `DISPATCH_MULTIPLIER`.
--- Returns `false` when the player owned nothing (do nothing — the
--- shipment dispatches with the player's selected manifest unchanged).
---
--- Pushes oil state on a successful consume so the open `ShipOilPanelGui`
--- updates the owned count badge in the same frame as the dispatch.
function CargoHaulerService:TryConsumeForDispatch(userId: number): boolean
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
	pcall(function()
		self._oilStateService:PushState(userId)
	end)
	if Players:GetPlayerByUserId(userId) then
		-- print(string.format("[CargoHauler] Consumed 1 stack for userId=%d (was %d).", userId, owned))
	end
	return true
end

--- The barrel multiplier consumed by `OilShipmentService:_handleDispatch`
--- right after `TryConsumeForDispatch` returns true. Exposed as a function
--- so a future rebalance (different tier values, scaling with ship cap,
--- etc.) doesn't require touching every call site.
function CargoHaulerService:GetMultiplier(): number
	return DISPATCH_MULTIPLIER
end

--- Read-only owned count. Useful for tests / future dev commands; the
--- live UI should read `runUpgradeOwnedByItemId.cargo_hauler` from the
--- oil state snapshot rather than calling this from the client (which
--- can't).
function CargoHaulerService:GetOwnedCount(userId: number): number
	if not self._oilStateService then
		return 0
	end
	return self._oilStateService:GetRunUpgradeOwned(userId, RUN_UPGRADE_ID) or 0
end

return CargoHaulerService
