--!strict
-- Display + binding configuration for `ShopPanelGui` card templates.
--
-- One block per *category* (DRILLS, future ENGINES / CREW / GEAR …). Each
-- category names its own Studio-authored template under
-- `ShopPanelGui.Templates.*` and the row in the panel that should host the
-- runtime clones. The populate code resolves slots inside a clone by the
-- `Role` attribute on each child (stamped in Studio), not by hard-coded
-- instance names.
--
-- This module is purely about *how* a row of items is presented; the items
-- themselves still live in `EquipmentCatalog.luau`. Adding a new category
-- means:
--   1. Author a new `*CardTemplate` in `ShopPanelGui.Templates`, stamp `Role`
--      attributes on its children.
--   2. Add an entry to `M.Categories` below pointing at that template + the
--      target row + which catalog rows belong in this section.
--
-- The drill-only marker `ShopCategory = "DRILLS"` on the template root + the
-- row guarantees future categories can ship their own templates side-by-side
-- without colliding with this one.

local EquipmentCatalog = require(script.Parent:WaitForChild("EquipmentCatalog"))

export type RarityKey = "COMMON" | "UNCOMMON" | "RARE" | "EPIC" | "LEGENDARY" | "MYTHIC"

export type RarityStyle = {
	--- `RarityTag.TextColor3` and other accent text.
	tagColor: Color3,
	--- `RarityStripe.BackgroundColor3` (left edge) — slightly brighter version
	--- of `tagColor` is fine; kept separate so designers can tune them apart.
	stripeColor: Color3,
	--- Display label. Defaults to the key (e.g. "COMMON").
	label: string?,
}

export type ShopSortKey = "ShopPriceAsc" | "ShopPriceDesc" | "CatalogOrder"

--- Function form lets a category cherry-pick from the catalog without coupling
--- the populate code to specific tool kinds / ids.
export type ItemFilter = (EquipmentCatalog.ShopCatalogRow) -> boolean

export type CategoryConfig = {
	--- Stable id; matches the `ShopCategory` attribute stamped on both the
	--- template root and the target row in `ShopPanelGui`.
	ShopCategory: string,
	--- Instance name of the template under `ShopPanelGui.Templates`.
	--- Resolved via `ShopPanelGui.Templates:FindFirstChild(TemplateName)`.
	TemplateName: string,
	--- Optional path under `ShopPanelGui` for the row that should host clones.
	--- Use this *only* if the row can't carry the `ShopCategory` attribute
	--- (preferred lookup is by attribute — see `M.FindRowForCategory`).
	TargetRowPath: string?,
	--- How to order items within the row.
	SortKey: ShopSortKey,
	--- Pulls the items this category renders out of `EquipmentCatalog`.
	--- Returning `false` excludes the row.
	ItemFilter: ItemFilter,
	--- Defaults applied when role attributes on the template don't already
	--- specify them; lets a category override copy globally.
	Defaults: {
		StockSubtitleInStock: string?,
		StockSubtitleSoldOut: string?,
		BuyText: string?,
		BuySoldOutText: string?,
		BuyOwnedText: string?,
		BuyUnaffordableText: string?,
		CostFormat: string?, -- printf-style; consumes already-formatted price string
		StockFormat: string?,
	},
}

local M = {}

----------------------------------------------------------------------
-- Rarity palette — shared across templates.
----------------------------------------------------------------------

M.Rarities = {
	COMMON    = {
		tagColor    = Color3.fromRGB(170, 175, 185),
		stripeColor = Color3.fromRGB(170, 175, 185),
		label       = "COMMON",
	} :: RarityStyle,
	UNCOMMON  = {
		tagColor    = Color3.fromRGB(120, 220, 130),
		stripeColor = Color3.fromRGB(120, 220, 130),
		label       = "UNCOMMON",
	} :: RarityStyle,
	RARE      = {
		tagColor    = Color3.fromRGB(100, 170, 255),
		stripeColor = Color3.fromRGB(100, 170, 255),
		label       = "RARE",
	} :: RarityStyle,
	EPIC      = {
		tagColor    = Color3.fromRGB(195, 130, 240),
		stripeColor = Color3.fromRGB(195, 130, 240),
		label       = "EPIC",
	} :: RarityStyle,
	LEGENDARY = {
		tagColor    = Color3.fromRGB(248, 196, 88),
		stripeColor = Color3.fromRGB(248, 196, 88),
		label       = "LEGENDARY",
	} :: RarityStyle,
	MYTHIC    = {
		tagColor    = Color3.fromRGB(255, 120, 160),
		stripeColor = Color3.fromRGB(255, 120, 160),
		label       = "MYTHIC",
	} :: RarityStyle,
} :: { [string]: RarityStyle }

--- Default returned when a row has no `rarity` (or an unknown key).
M.NeutralRarity = {
	tagColor    = Color3.fromRGB(110, 118, 134),
	stripeColor = Color3.fromRGB(110, 118, 134),
	label       = "RARITY",
} :: RarityStyle

function M.GetRarityStyle(key: string?): RarityStyle
	if typeof(key) == "string" then
		local style = M.Rarities[key]
		if style then
			return style
		end
	end
	return M.NeutralRarity
end

----------------------------------------------------------------------
-- Categories — add new shop sections here.
----------------------------------------------------------------------

M.Categories = {
	DRILLS = {
		ShopCategory = "DRILLS",
		TemplateName = "DrillCardTemplate",
		TargetRowPath = "Canvas.PanelHost.Panel.Body.ShopScroll.ScrollContent.EquipmentSection.DRILLSBlock.DRILLSRow",
		SortKey = "ShopPriceAsc",
		ItemFilter = function(row)
			return row.toolKind == "Drill"
		end,
		Defaults = {
			StockSubtitleInStock = "IN STOCK",
			StockSubtitleSoldOut = "SOLD OUT",
			BuyText             = "BUY",
			BuySoldOutText      = "SOLD OUT",
			BuyOwnedText        = "OWNED",
			BuyUnaffordableText = "NEED $$",
			CostFormat          = "$ %s",
			StockFormat         = "%d / %d",
		},
	} :: CategoryConfig,
} :: { [string]: CategoryConfig }

----------------------------------------------------------------------
-- Lookups (used by the populate / controller code).
----------------------------------------------------------------------

--- Resolve a category by its `ShopCategory` attribute (case-sensitive).
function M.GetCategory(shopCategory: string?): CategoryConfig?
	if typeof(shopCategory) ~= "string" then
		return nil
	end
	return M.Categories[shopCategory]
end

--- Walk a `ShopPanelGui` looking for the row attributed with this category.
--- Falls back to `TargetRowPath` if the attribute isn't found yet (e.g. older
--- Studio sync). Returns `nil` if neither resolves.
function M.FindRowForCategory(shopPanelGui: Instance, shopCategory: string): GuiObject?
	for _, d in ipairs(shopPanelGui:GetDescendants()) do
		if d:IsA("GuiObject")
			and d:GetAttribute("IsShopCategoryRow") == true
			and d:GetAttribute("ShopCategory") == shopCategory
		then
			return d
		end
	end
	local cat = M.Categories[shopCategory]
	if cat and cat.TargetRowPath then
		local node: Instance? = shopPanelGui
		for segment in string.gmatch(cat.TargetRowPath, "[^%.]+") do
			if not node then
				return nil
			end
			node = node:FindFirstChild(segment)
		end
		if node and node:IsA("GuiObject") then
			return node
		end
	end
	return nil
end

--- Find the template instance for a category under `ShopPanelGui.Templates`.
function M.FindTemplate(shopPanelGui: Instance, shopCategory: string): GuiObject?
	local cat = M.Categories[shopCategory]
	if not cat then
		return nil
	end
	local templates = shopPanelGui:FindFirstChild("Templates")
	if not templates then
		return nil
	end
	local t = templates:FindFirstChild(cat.TemplateName)
	if t and t:IsA("GuiObject") and t:GetAttribute("ShopCategory") == shopCategory then
		return t
	end
	return nil
end

--- Find a child instance inside a card by its `Role` attribute. Cheaper than
--- name lookups when role names diverge from instance names.
function M.FindRole(card: Instance, role: string): Instance?
	if card:GetAttribute("Role") == role then
		return card
	end
	for _, d in ipairs(card:GetDescendants()) do
		if d:GetAttribute("Role") == role then
			return d
		end
	end
	return nil
end

--- Pull the items belonging to a category from `EquipmentCatalog`, sorted
--- per `SortKey`. Result is a fresh array — safe to mutate.
function M.GetCategoryItems(shopCategory: string): { EquipmentCatalog.ShopCatalogRow }
	local cat = M.Categories[shopCategory]
	if not cat then
		return {}
	end
	local out: { EquipmentCatalog.ShopCatalogRow } = {}
	for _, row in ipairs(EquipmentCatalog.buildShopItems()) do
		if cat.ItemFilter(row) then
			table.insert(out, row)
		end
	end
	if cat.SortKey == "ShopPriceAsc" then
		table.sort(out, function(a, b)
			if a.cost ~= b.cost then
				return a.cost < b.cost
			end
			return a.id < b.id
		end)
	elseif cat.SortKey == "ShopPriceDesc" then
		table.sort(out, function(a, b)
			if a.cost ~= b.cost then
				return a.cost > b.cost
			end
			return a.id < b.id
		end)
	end
	return out
end

return M
