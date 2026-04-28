--!strict
-- HitContractConfig
--
-- Tuning for the **player-hired pirate contract** flow only — the broker NPC
-- (`Workspace.PirateHire`) that lets one player pay cash to ambush another
-- player's active shipment via `HitContractService` →
-- `OilShipmentService:QueueOrTriggerForcedPirateHit`.
--
-- NOT to be confused with the ambient **PirateRaid** strait event in
-- `StraitEvents/Catalog.luau` — that one is per-event-tuned (currently
-- `looseBarrelLossFraction = 0.25`) and stays catalog-driven because each
-- ambient event balances differently. This config is exclusively the
-- contractor-hire path.
--
-- Read by:
--   * `OilShipmentService.QueueOrTriggerForcedPirateHit` — uses `StealRatio`
--     to compute `barrelsStolen`.
--   * `HitContractService` — uses `Cost` for the cash gate + UI replication.
--   * `PirateHireClient` — uses `formatStealPercent()` for the broker's pitch
--     label so the displayed % can never drift from the server math.

local HitContractConfig = {
	--- Fraction of the victim's *loose barrels on deck* that the contracted
	--- pirates strip when the hit lands. Whole barrels only; ceil-rounded by
	--- the loss helper (Crude → Refined → Premium tier order).
	StealRatio = 0.5,

	--- Flat in-game cash cost to place a contract. Refundable as a free hit
	--- token if the contract can't be fulfilled (target leaves, no shipment,
	--- etc.) — see `HitContractService:RefundContract`.
	---
	--- Robux variants (`consumable.pirate_hire_x1`) ignore this — they pay in
	--- Robux at the receipt boundary and bypass the same-target cooldown
	--- below. Cash hires are the only path that pays this number AND stamps
	--- the cooldown.
	Cost = 10000,

	--- Seconds before the same contractor can place another **cash** hire on
	--- the same victim (anti-spam). Starts when a cash hire is accepted
	--- (cash/token consumed). Robux hires neither check nor stamp this — by
	--- design, paying Robux skips the cooldown gate entirely.
	SameTargetHireCooldownSeconds = 120,
}

--- Format the steal ratio as a player-facing percent string ("50%"). Truncates
--- to the nearest whole percent — the broker pitch reads cleaner without
--- decimals, and we don't currently tune this in fractional-percent steps.
function HitContractConfig.formatStealPercent(): string
	local r = HitContractConfig.StealRatio
	if typeof(r) ~= "number" then
		return "—"
	end
	return string.format("%d%%", math.floor(r * 100 + 0.5))
end

--- Format the contract cost as a `$N` string ("$5000"). Server already sends
--- the raw number to the client (`hitCost`), but having one place to format
--- keeps the broker dialog consistent if we ever switch to abbreviations
--- ("$5K") or commas ("$5,000").
function HitContractConfig.formatCost(): string
	return string.format("$%d", HitContractConfig.Cost)
end

return HitContractConfig
