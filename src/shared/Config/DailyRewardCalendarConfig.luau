--!strict
-- 7-day daily reward calendar (`StarterGui.Daily` panel).
--
-- Player progression model (decided 2026-04-26):
--   * Reward 1 is always immediately claimable on first open (no cooldown).
--   * After each claim, a fixed cooldown gates the **next** slot.
--   * Cooldown is per-claim (NOT a daily UTC reset) — friendlier across
--     timezones and avoids the "claim 5min before midnight, next reward
--     available immediately" weirdness of fixed-clock resets.
--   * Streak break = **resume**: if the player misses a day, they pick
--     up exactly where they left off; the timer just keeps running so the
--     next reward becomes available immediately on their next login.
--     (No reset-to-day-1 punishment.)
--
-- Server contract: `DailyRewardCalendarService` owns the claim state
-- (`dailyRewardClaimedCount`, `dailyRewardLastClaimAt` on `OilStateService`)
-- and grants the reward via `Grant<kind>` paths on the corresponding service.
-- The visual layout is fully authored in Studio (`StarterGui.Daily`) — this
-- config drives backend behavior only; per-reward titles/icons live in the
-- ScreenGui itself.

local DailyRewardCalendarConfig = {}

--- 24 hours between claims. Tunable; change here only — the server pushes
--- this value to the client so the countdown rendering stays in sync without
--- a separate client-side constant to keep aligned.
DailyRewardCalendarConfig.CooldownSeconds = 24 * 3600

--- Total number of rewards in the calendar. Must match the count of
--- `Reward1`..`RewardN` frames authored under `StarterGui.Daily.Canvas.Container.Main.Container`.
DailyRewardCalendarConfig.TotalRewards = 7

--- Named pools used by `kind = "boatPool"` rewards. The server picks one
--- entry uniformly at random when the slot is claimed and grants it via
--- `OilStateService:GrantBoat`. Each pool entry must be a valid `boatId`
--- in `BoatCatalog.Boats`. Add a new pool here when introducing another
--- random-boat slot — `DailyRewardCalendarService:_grantReward` reads
--- `payload.poolKey` to look up the pool dynamically.
---
--- `earlyTier` is the early cash chain (T2..T5, Common/Uncommon, sub-$50k
--- unlock prices). Skips Tier1Boat (auto-granted starter) and the Robux-
--- only premium boats so the daily roll can't accidentally hand out a
--- Robux SKU for free.
DailyRewardCalendarConfig.BoatPools = {
	earlyTier = { "Tier2Boat", "Tier3Boat", "Tier4Boat", "Tier5Boat" },
} :: { [string]: { string } }

--- Pick one boatId uniformly at random from a named pool. Returns `nil`
--- if the pool key is unknown or the pool is empty (caller is expected to
--- log + soft-fail; the calendar slot still advances in that case).
function DailyRewardCalendarConfig.RollFromBoatPool(poolKey: string): string?
	local pool = DailyRewardCalendarConfig.BoatPools[poolKey]
	if typeof(pool) ~= "table" or #pool == 0 then
		return nil
	end
	local idx = math.random(1, #pool)
	return pool[idx]
end

--- Per-reward grant definitions. Order matches `Reward1`..`Reward7` in the
--- ScreenGui (index 1 = Reward1). Each entry is dispatched server-side via
--- `kind`:
---   * `"cash"`       — `payload.amount` granted via `OilStateService:AddCash`
---                       with `skipMultiplier = true` (gift-style, not earnings,
---                       so DoubleEarnings / global cash buffs don't compound).
---   * `"boat"`       — `payload.boatId` granted via `OilStateService:GrantBoat`.
---                       If the id is `nil` / not in `BoatCatalog`, the claim
---                       still succeeds and the service logs a TODO warn so the
---                       slot can be wired later without breaking the flow.
---   * `"boatPool"`   — `payload.poolKey` (e.g. `"earlyTier"`) — server picks
---                       a random `boatId` from `BoatPools[poolKey]` and grants
---                       it. The rolled boatId is persisted on the player's
---                       profile so the panel can swap the slot's icon to the
---                       actual hull post-claim. See `kind = "boatPool"` branch
---                       in `DailyRewardCalendarService:_grantReward`.
---   * `"equipment"`  — `payload.itemId` × `payload.qty` granted via
---                       `EquipmentShopService:GrantFreeOwnedEquipment` (same
---                       canonical grant path the FTUE / Robux bundles use, so
---                       inventory backfill + tool reconciliation just works).
---   * `"runUpgrade"` — `payload.itemId` × `payload.qty` granted via
---                       `OilStateService:AddRunUpgradeOwned` (per-shipment
---                       consumable stack, e.g. `security_personnel` decremented
---                       by `OilShipmentService` on dispatch).
---   * `"noop"`       — explicit placeholder: claim succeeds, no grant, no warn.
---                       Use for cosmetic-only "celebration" days if added later.
---
--- The `title` field is documentation only (so a reader can map config rows
--- to the Studio-authored titles). The UI does NOT pull from here — each
--- `RewardN.Title.Text` is authored in StarterGui.
DailyRewardCalendarConfig.Rewards = {
	[1] = { id = "day1_cash_500", title = "$500", kind = "cash", payload = { amount = 500 } },
	[2] = { id = "day2_random_early_boat", title = "RANDOM SHIP", kind = "boatPool", payload = { poolKey = "earlyTier" } },
	[3] = { id = "day3_3x_glizzy_grinder", title = "3x Glizzy Grinder", kind = "equipment", payload = { itemId = "drill_t5", qty = 3 } },
	[4] = { id = "day4_cash_10k", title = "$10k", kind = "cash", payload = { amount = 10000 } },
	[5] = { id = "day5_3x_security_personnel", title = "3x Security Personnel", kind = "runUpgrade", payload = { itemId = "security_personnel", qty = 3 } },
	[6] = { id = "day6_cash_67k", title = "$67k", kind = "cash", payload = { amount = 67000 } },
	[7] = { id = "day7_surfboat", title = "Surfboat", kind = "boat", payload = { boatId = "Surfboat" } },
}

--- Returns seconds remaining until the next reward becomes available.
--- `lastClaimAt` is a Unix timestamp (`os.time()`) of the most recent claim,
--- or `nil` for a brand-new player who hasn't claimed Reward 1 yet — in which
--- case the next reward (Reward 1) is immediately available, so 0.
function DailyRewardCalendarConfig.SecondsUntilNext(lastClaimAt: number?): number
	if typeof(lastClaimAt) ~= "number" then
		return 0
	end
	local elapsed = os.time() - lastClaimAt
	local remaining = DailyRewardCalendarConfig.CooldownSeconds - elapsed
	if remaining < 0 then
		return 0
	end
	return remaining
end

--- True iff the player can claim their next reward right now.
--- Convenience wrapper for `SecondsUntilNext(...) <= 0` so callers don't
--- need to repeat the > 0 check.
function DailyRewardCalendarConfig.IsClaimableNow(claimedCount: number, lastClaimAt: number?): boolean
	if claimedCount >= DailyRewardCalendarConfig.TotalRewards then
		return false
	end
	return DailyRewardCalendarConfig.SecondsUntilNext(lastClaimAt) <= 0
end

return DailyRewardCalendarConfig
