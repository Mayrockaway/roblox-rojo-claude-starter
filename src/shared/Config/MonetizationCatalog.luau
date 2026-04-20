--!strict
--- MonetizationCatalog
---
--- Single source of truth for everything the player can buy with **Robux**.
--- Mirrors the role `EquipmentCatalog` plays for in-game cash purchases:
---   * stable internal `id` ("ship.whale", "currency.cash_5k", "gamepass.double_cash")
---   * exactly one Roblox storefront id (`DevProduct` or `GamePass`)
---   * one `grant` payload describing what the player receives on a verified
---     `ProcessReceipt` (or `UserOwnsGamePassAsync`).
---
--- Server uses this to verify receipts → dispatch grants. Client uses it to
--- render shop chrome and to ask the server to prompt the Roblox purchase
--- dialog (we never call `MarketplaceService` directly from the client; the
--- server calls `PromptProductPurchase`, then `ProcessReceipt` lands here).
---
--- Only the **Default Tanker** ship is a starter-owned skin. Every other ship
--- skin in `ShipSkinCatalog` is gated behind a Robux DevProduct entry below
--- (`productId = 0` until an owner wires the real Roblox asset id).
---
--- Adding new items later (currency packs, consumable nukes, GamePasses, etc.)
--- is intentionally additive: append to `Items`, set `productKind` /
--- `productId`, fill the matching `grant.*` payload, and `MonetizationService`
--- will route it on receipt with no schema bump required.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ShipSkinCatalog = require(Shared:WaitForChild("Config"):WaitForChild("ShipSkinCatalog"))

export type MonetizationProductKind = "DevProduct" | "GamePass"
export type MonetizationGrantKind = "Ship" | "Currency" | "Consumable" | "GamePassEffect" | "Cosmetic" | "Equipment" | "Bundle"

export type MonetizationGrant = {
	--- One-of: discriminator for the grant payload below.
	kind: MonetizationGrantKind,

	--- "Ship" — the catalog skin id to add to `state.ownedShipSkinIds` and
	--- (optionally) auto-equip via `OilStateService:SetShipSkinId`.
	skinId: string?,

	--- Per-grant override of the parent item's `equipOnGrant`. Lets a Bundle
	--- sub-grant opt out of (or into) auto-equip without changing the parent
	--- item flag — `nil` means "fall back to parent item".
	equipOnGrant: boolean?,

	--- "Currency" — flat in-game cash to add via `OilStateService:AddCash`.
	cashAmount: number?,

	--- "Consumable" — symbolic id + quantity. Resolved by a service that
	--- knows what the consumable means (e.g. ArmyGeneralService for nukes).
	consumable: { id: string, quantity: number }?,

	--- "GamePassEffect" — symbolic effect id ("DoubleCash", "AutoCollect"…)
	--- so consuming services can ask `MonetizationService:HasEffect(player, id)`
	--- without hard-coding asset ids in gameplay code.
	gamePassEffect: string?,

	--- "Cosmetic" — opaque id passed to a cosmetic-owning service later
	--- (auras / hats / overhead trails / etc.). Keeps the schema future-proof
	--- without forcing all of those services to exist today.
	cosmetic: { kind: string, id: string }?,

	--- "Equipment" — `EquipmentCatalog` row id (e.g. "drill_t5") + quantity.
	--- Resolved by `EquipmentShopService:GrantFreeOwnedEquipment` via the
	--- `MonetizationService:SetEquipmentHandler` plug, so this catalog stays
	--- decoupled from the equipment subsystem.
	equipment: { itemId: string, quantity: number }?,

	--- "Bundle" — list of nested grants, applied in order on a single
	--- receipt. Used for starter packs / value packs that grant a mix of
	--- ship + currency + equipment in one DevProduct purchase. Sub-grants
	--- are dispatched best-effort: a failure in one entry is logged but the
	--- receipt is still marked granted, because returning false would cause
	--- Roblox to retry and re-grant the entries that did succeed (currency
	--- and equipment are NOT idempotent, only ship grants are). Author
	--- bundles assuming every sub-grant should normally succeed.
	bundle: { MonetizationGrant }?,
}

export type MonetizationItem = {
	id: string,
	productKind: MonetizationProductKind,
	productId: number,
	robuxPrice: number?,
	displayName: string,
	subtitle: string?,
	iconAssetId: string?,
	rarityDisplay: string?,
	--- When set, the shop tab / category this item should render under in any
	--- future "Robux Shop" panel ("Ships", "Currency", "Boosts", "Cosmetics").
	--- `SelectShipPanel` filters Ships out by `grant.kind == "Ship"` so this
	--- field stays optional today.
	category: string?,
	--- After a successful receipt, automatically equip the granted item if
	--- the kind supports it (e.g. ships → `SetShipSkinId`).
	equipOnGrant: boolean?,
	grant: MonetizationGrant,
}

local MonetizationCatalog = {}

--- Master switch: any `MonetizationService` purchase prompt or receipt grant
--- becomes a no-op when this is `false`. Default is `true` because the rest
--- of the wiring (`ProcessReceipt`, prompts, ownership) only "activates" when
--- a real `productId` is set on an item — placeholder rows with `productId == 0`
--- are filtered out of `IsBuyable()` regardless of this flag.
MonetizationCatalog.Enabled = true

--- Helper used during initial Studio setup so a half-wired catalog never
--- spams `Enable Studio Access to API Services` warnings — server defers
--- prompts until at least one item resolves to a real `productId`.
function MonetizationCatalog.IsValidProductId(productId: number?): boolean
	return typeof(productId) == "number" and productId > 0
end

local SHIP_RARITY_FALLBACK = "Common"

local function shipDisplayName(skinId: string): string
	local def = ShipSkinCatalog.Skins[skinId]
	if def and typeof(def.displayName) == "string" and def.displayName ~= "" then
		return def.displayName
	end
	return skinId
end

local function shipRarity(skinId: string): string
	local def = ShipSkinCatalog.Skins[skinId]
	if def and typeof(def.rarityDisplay) == "string" and def.rarityDisplay ~= "" then
		return def.rarityDisplay
	end
	return SHIP_RARITY_FALLBACK
end

--- Per-skin Robux pricing. These are the canonical prices the in-game shop
--- chrome reads (see `RobuxShopPanel` Buy pill text). The Roblox Creator
--- Dashboard owns the *actual* charged price on each DevProduct — keep these
--- in sync when you wire the real `productId` so the in-game label matches
--- what the Roblox prompt will say.
local SHIP_PLACEHOLDER_PRICE: { [string]: number } = {
	Ship3Skin = 199,
	Ship4Skin = 149, -- Pirate (RobuxShop Ship1)
	Ship5Skin = 299, -- Ducky  (RobuxShop Ship2)
	WhaleSkin = 299, -- Whale  (RobuxShop Ship3)
}

local function buildShipItem(skinId: string, productId: number?): MonetizationItem
	return {
		id = "ship." .. string.lower(skinId),
		productKind = "DevProduct",
		productId = productId or 0,
		robuxPrice = SHIP_PLACEHOLDER_PRICE[skinId] or 99,
		displayName = shipDisplayName(skinId),
		subtitle = "Ship Skin",
		rarityDisplay = shipRarity(skinId),
		category = "Ships",
		equipOnGrant = true,
		grant = {
			kind = "Ship",
			skinId = skinId,
		},
	}
end

--- Master item table.
---
--- IMPORTANT: keep `id` values stable. They show up in DataStore receipt
--- idempotency keys (`MonetizationService:ProcessReceipt`) and player
--- inventory snapshots, so renaming an `id` invalidates outstanding
--- purchases. Add new rows; do not rename old ones.
MonetizationCatalog.Items = {
	-- Featured bundles -----------------------------------------------------
	-- Starter Pack: Pirate ship (Ship4Skin) + $5,000 cash + 2x tier-5 drills
	-- ("Glizzy Grinder", `EquipmentCatalog.drill_t5`). Authored card lives at
	-- `StarterGui.RobuxShop.Canvas.Container.Main.Container.Featured` with the
	-- buy button literally named `EquipBest` (Studio author quirk; kept as-is
	-- so the wiring map in `RobuxShopPanel` matches the live tree).
	--
	-- Bundle dispatch is best-effort (see `MonetizationGrant.bundle` doc) —
	-- each sub-grant logs its own failure and the receipt is marked granted
	-- so Roblox doesn't retry and re-deliver the parts that did succeed.
	-- Ship sub-grant `equipOnGrant = true` keeps the visible "you bought a
	-- new ship!" beat for first-time buyers; if the player already owns it,
	-- `_grantShip` short-circuits via `OK_ALREADY_OWNED` and the rest of the
	-- bundle still applies (idempotent re-buy semantics for the cash + drills).
	{
		id = "starter_pack",
		productKind = "DevProduct",
		productId = 3578811060,
		robuxPrice = 199,
		displayName = "Starter Pack",
		subtitle = "Pirate Ship + $5,000 + 2x Glizzy Grinder",
		category = "Featured",
		grant = {
			kind = "Bundle",
			bundle = {
				{ kind = "Ship", skinId = "Ship4Skin", equipOnGrant = true },
				{ kind = "Currency", cashAmount = 5000 },
				{ kind = "Equipment", equipment = { itemId = "drill_t5", quantity = 2 } },
			},
		},
	},

	-- Ships ----------------------------------------------------------------
	-- DefaultTanker is intentionally absent: it's the starter ship granted
	-- to every player by `OilStateService` — no Robux product needed.
	buildShipItem("Ship3Skin"),
	buildShipItem("Ship4Skin", 3578818285),
	buildShipItem("Ship5Skin", 3578818474),
	buildShipItem("WhaleSkin", 3578818669),

	-- Boosts ---------------------------------------------------------------
	-- 2x Earnings GamePass. `gamePassEffect = "DoubleEarnings"` is the
	-- symbolic id consuming services check via
	-- `MonetizationService:HasGamePassEffect(player, "DoubleEarnings")` — keep
	-- that string stable; renaming it would silently disable the multiplier
	-- for every owner. Apply scope (cash from oil sales, contract payouts,
	-- etc.) is owned by whichever service reads the effect, not declared here.
	{
		id = "gamepass.double_earnings",
		productKind = "GamePass",
		productId = 0,
		robuxPrice = 299,
		displayName = "2x Earnings",
		subtitle = "Permanent",
		category = "Boosts",
		grant = { kind = "GamePassEffect", gamePassEffect = "DoubleEarnings" },
	},

	-- Consumables ----------------------------------------------------------
	-- One-shot Robux dev products. `MonetizationService:_grantConsumable`
	-- routes each `consumable.id` to a handler registered by the owning
	-- service via `SetConsumableHandler(id, fn)`. Until that handler is
	-- registered the receipt fails with `ERR_NO_CONSUMABLE_HANDLER` (and
	-- Roblox retries on next session) — that's intentional so a half-wired
	-- product can't silently eat Robux without granting anything.

	-- Nuke strike. Future home for the `ArmyGeneralService` Robux flow noted
	-- in its TODO; consumable id `"nuke"` is what its handler should match on.
	{
		id = "consumable.nuke_x1",
		productKind = "DevProduct",
		productId = 3578819046,
		robuxPrice = 199,
		displayName = "Nuke Strike",
		subtitle = "One-time use",
		category = "Boosts",
		grant = { kind = "Consumable", consumable = { id = "nuke", quantity = 1 } },
	},

	-- Strait force-open / force-close, two minutes server-wide.
	--
	-- Behavioral contract for the future handler (`StraitStateService`-side):
	--   * On grant, force `StraitState` to the matching value AND lock it
	--     (no organic rotation, no other player's force-open/close, no
	--     event-driven flip) for 120 seconds, then release the lock and
	--     resume normal rotation.
	--   * If two players buy in the same 120s window: first grant wins; the
	--     second handler should refund-or-ignore (return false from the
	--     handler so `MonetizationService` retries the receipt and Roblox
	--     auto-refunds, since we can't honour the override). Decide the
	--     refund-vs-queue policy at handler implementation time.
	--   * Broadcast the lock + remaining time via the existing strait state
	--     remote so all clients see the forced state and a "purchased by X"
	--     attribution chip.
	-- Internal `consumable.id` stays stable; rename invalidates outstanding
	-- receipts, same caveat as every other id in this file.
	{
		id = "consumable.strait_open_2min",
		productKind = "DevProduct",
		productId = 3578819223,
		robuxPrice = 99,
		displayName = "Force Open Strait (2 min)",
		subtitle = "One-time use",
		category = "Strait",
		grant = { kind = "Consumable", consumable = { id = "strait_open_2min", quantity = 1 } },
	},
	{
		id = "consumable.strait_close_2min",
		productKind = "DevProduct",
		productId = 3578819374,
		robuxPrice = 99,
		displayName = "Force Close Strait (2 min)",
		subtitle = "One-time use",
		category = "Strait",
		grant = { kind = "Consumable", consumable = { id = "strait_close_2min", quantity = 1 } },
	},

	-- Future categories — left as a commented template so adding the first
	-- Currency entry is a one-liner and the contract stays visible at the
	-- call site (Consumable / GamePassEffect contracts now demonstrated by
	-- the live rows above; no need for separate templates).
	--
	-- {
	-- 	id = "currency.cash_5k",
	-- 	productKind = "DevProduct",
	-- 	productId = 0,
	-- 	robuxPrice = 49,
	-- 	displayName = "Cash Pack — $5,000",
	-- 	category = "Currency",
	-- 	grant = { kind = "Currency", cashAmount = 5000 },
	-- },
} :: { MonetizationItem }

--- Index: stable `id` -> item.
local _itemsById: { [string]: MonetizationItem } = {}
--- Index: ("DevProduct" | "GamePass") productId -> item. Only populated for
--- items with `IsValidProductId(productId)` so placeholder rows can't collide.
local _itemsByProductId: { DevProduct: { [number]: MonetizationItem }, GamePass: { [number]: MonetizationItem } } = {
	DevProduct = {},
	GamePass = {},
}
--- Index: ship skin id -> Ship item (so `OilStateService` can ask "is this
--- skin Robux-gated, and if so what's the Robux price?" without scanning the
--- whole table).
local _shipItemBySkinId: { [string]: MonetizationItem } = {}

local function rebuildIndexes()
	table.clear(_itemsById)
	table.clear(_itemsByProductId.DevProduct)
	table.clear(_itemsByProductId.GamePass)
	table.clear(_shipItemBySkinId)
	for _, item in ipairs(MonetizationCatalog.Items) do
		if typeof(item.id) ~= "string" or item.id == "" then
			continue
		end
		if _itemsById[item.id] then
			warn(string.format("[MonetizationCatalog] Duplicate item id %q — keeping first definition.", item.id))
			continue
		end
		_itemsById[item.id] = item
		if MonetizationCatalog.IsValidProductId(item.productId) then
			local bucket = _itemsByProductId[item.productKind]
			if bucket then
				bucket[item.productId] = item
			end
		end
		if item.grant.kind == "Ship" and typeof(item.grant.skinId) == "string" and item.grant.skinId ~= "" then
			_shipItemBySkinId[item.grant.skinId] = item
		end
	end
end

rebuildIndexes()

function MonetizationCatalog.GetItem(id: string?): MonetizationItem?
	if typeof(id) ~= "string" or id == "" then
		return nil
	end
	return _itemsById[id]
end

function MonetizationCatalog.ItemForReceipt(productId: number?): MonetizationItem?
	if not MonetizationCatalog.IsValidProductId(productId) then
		return nil
	end
	return _itemsByProductId.DevProduct[productId :: number]
end

function MonetizationCatalog.ItemForGamePass(productId: number?): MonetizationItem?
	if not MonetizationCatalog.IsValidProductId(productId) then
		return nil
	end
	return _itemsByProductId.GamePass[productId :: number]
end

function MonetizationCatalog.GetShipItemBySkinId(skinId: string?): MonetizationItem?
	if typeof(skinId) ~= "string" or skinId == "" then
		return nil
	end
	return _shipItemBySkinId[skinId]
end

function MonetizationCatalog.IsRobuxGatedShip(skinId: string?): boolean
	return MonetizationCatalog.GetShipItemBySkinId(skinId) ~= nil
end

function MonetizationCatalog.IsBuyable(item: MonetizationItem?): boolean
	if not item then
		return false
	end
	if not MonetizationCatalog.Enabled then
		return false
	end
	-- In Studio we keep `productId = 0` rows clickable for layout testing,
	-- but flag them so MonetizationService knows to surface a friendly
	-- "Coming soon" toast instead of calling MarketplaceService with 0.
	return MonetizationCatalog.IsValidProductId(item.productId)
end

function MonetizationCatalog.IsStudio(): boolean
	return RunService:IsStudio()
end

--- Snapshot the catalog for the client. Mirrors the EquipmentCatalog pattern
--- — only safe display fields cross the network so server stays the only
--- place that reads `grant` payloads on receipts.
export type MonetizationItemForClient = {
	id: string,
	productKind: MonetizationProductKind,
	productId: number,
	robuxPrice: number?,
	displayName: string,
	subtitle: string?,
	iconAssetId: string?,
	rarityDisplay: string?,
	category: string?,
	grantKind: MonetizationGrantKind,
	grantSkinId: string?,
	isBuyable: boolean,
}

function MonetizationCatalog.ListForClient(): { MonetizationItemForClient }
	local list: { MonetizationItemForClient } = {}
	for _, item in ipairs(MonetizationCatalog.Items) do
		table.insert(list, {
			id = item.id,
			productKind = item.productKind,
			productId = item.productId,
			robuxPrice = item.robuxPrice,
			displayName = item.displayName,
			subtitle = item.subtitle,
			iconAssetId = item.iconAssetId,
			rarityDisplay = item.rarityDisplay,
			category = item.category,
			grantKind = item.grant.kind,
			grantSkinId = item.grant.skinId,
			isBuyable = MonetizationCatalog.IsBuyable(item),
		})
	end
	return list
end

return MonetizationCatalog
