--!strict
--- Rebirth shop catalog (`RebirthShopPanelGui`). Items are spent against
--- `OilStateService.rebirthTokens` and grant rebirth-persistent rewards.
---
--- `cardName` matches the Studio-authored card under
--- `Canvas.PanelHost.Panel.Body.Content.LeftColumn.UpgradeGrid.<cardName>` —
--- both client (selection / hydration) and server (purchase validation) key
--- off the item id directly. Today only `drill` is purchasable; the other
--- three are flagged `available = false` and rendered with a
--- `ComingSoonOverlay` (per `HudPanelRouter`'s convention).
---
--- The Drill grant is a one-time-use Heaven Drill consumable that bumps
--- `OilStateService.rebirthDrills` by `grantsDrillCount`. `OilHeavenDrillService`
--- listens to the mirrored attribute change and ensures the Tool is in the
--- player's Backpack iff the count is > 0.

export type RebirthShopItem = {
	id: string,
	cardName: string,
	displayName: string,
	description: string,
	-- Glyph painted into the right-column `Hero.HeroIcon` and the card's
	-- `IconFrame.Icon`. Plain unicode keeps the panel asset-free for now —
	-- swap to an `Image` field if/when art lands.
	heroGlyph: string,
	tokenCost: number,
	available: boolean,
	-- How many rebirth-drill consumables one purchase grants. Only meaningful
	-- when `available = true` and the item maps to a drill grant.
	grantsDrillCount: number,
}

local RebirthShopConfig = {}

RebirthShopConfig.Items = {
	drill = {
		id = "drill",
		cardName = "DrillCard",
		displayName = "Rebirth Drill",
		description = "One-time-use drill for Oil Heaven tiles. Reveals a permanent rebirth boost (Ship Speed, Warehouse, Earnings, or Luck).",
		heroGlyph = "⛏",
		tokenCost = 2,
		available = true,
		grantsDrillCount = 1,
	} :: RebirthShopItem,
	refiner = {
		id = "refiner",
		cardName = "RefinerCard",
		displayName = "Refiner",
		description = "Coming soon.",
		heroGlyph = "⚗",
		tokenCost = 0,
		available = false,
		grantsDrillCount = 0,
	} :: RebirthShopItem,
	cannon = {
		id = "cannon",
		cardName = "CannonCard",
		displayName = "Cannon",
		description = "Coming soon.",
		heroGlyph = "💣",
		tokenCost = 0,
		available = false,
		grantsDrillCount = 0,
	} :: RebirthShopItem,
	ship = {
		id = "ship",
		cardName = "ShipCard",
		displayName = "Ship",
		description = "Coming soon.",
		heroGlyph = "🚢",
		tokenCost = 0,
		available = false,
		grantsDrillCount = 0,
	} :: RebirthShopItem,
}

--- Rebirth token formula: two-phase sqrt curve with diminishing returns.
--- Phase 1 ($500K–$1B): tokens = floor(5 + 0.8 × (√(cash/$500K) - 1))
--- Phase 2 ($1B+):       continues at 1/10th speed past soft cap.
--- Tuned: $500K=5, $3M=6, $8M=7, $50M=12, $1B≈39, then crawl.
RebirthShopConfig.CashThreshold = 500_000
RebirthShopConfig.TokenBaseGrant = 5
RebirthShopConfig.TokenSqrtScale = 0.8
RebirthShopConfig._softCapRatio = 2000
RebirthShopConfig._softCapSqrt = math.sqrt(2000)
RebirthShopConfig._tokensAtCap = 5 + 0.8 * (math.sqrt(2000) - 1)
RebirthShopConfig._postCapScale = 0.8 / 10

function RebirthShopConfig.CalculateTokens(cash: number): number
	if cash < RebirthShopConfig.CashThreshold then return 0 end
	local ratio = cash / RebirthShopConfig.CashThreshold
	if ratio <= 1 then return RebirthShopConfig.TokenBaseGrant end
	local sqrtRatio = math.sqrt(ratio)
	if sqrtRatio <= RebirthShopConfig._softCapSqrt then
		return math.floor(RebirthShopConfig.TokenBaseGrant
			+ RebirthShopConfig.TokenSqrtScale * (sqrtRatio - 1))
	end
	return math.floor(RebirthShopConfig._tokensAtCap
		+ RebirthShopConfig._postCapScale * (sqrtRatio - RebirthShopConfig._softCapSqrt))
end

--- Backward-compat alias for call sites that still reference CashPerToken.
RebirthShopConfig.CashPerToken = RebirthShopConfig.CashThreshold

--- Default selection on panel open (Q5 — Drill is the only buyable item).
RebirthShopConfig.DefaultSelectedItemId = "drill"

--- Stable iteration order for the left-column grid. Layout is driven by the
--- Studio-authored UIGridLayout, but client code uses this order to decide
--- which card hydrates which item id when names don't match exactly.
RebirthShopConfig.ItemOrder = { "drill", "refiner", "cannon", "ship" }

function RebirthShopConfig.GetItem(itemId: string): RebirthShopItem?
	if typeof(itemId) ~= "string" then
		return nil
	end
	return RebirthShopConfig.Items[itemId]
end

return RebirthShopConfig
