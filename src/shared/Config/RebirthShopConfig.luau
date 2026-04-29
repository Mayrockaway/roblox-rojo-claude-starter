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
		tokenCost = 1,
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

--- Cash → token conversion rate used by the rebirth flow (`RebirthPanelGui`).
--- One token costs `CashPerToken` cash; the preview math is `floor(cash / rate)`.
--- Lives next to the shop catalog because both belong to the same rebirth-economy
--- surface and tuning them together avoids cross-config edits. The HUD subtitle
--- above ConversionCard, the panel's TokenCount preview, and the "not enough cash"
--- error gate all read from this constant.
RebirthShopConfig.CashPerToken = 1000000

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
