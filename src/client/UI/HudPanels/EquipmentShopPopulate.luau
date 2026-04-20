--!strict
-- Populates `ShopPanelGui` by cloning role-stamped templates per category.
--
-- Flow:
--   1. For each entry in `ShopPanelTemplates.Categories`, locate the Studio-
--      authored template (under `ShopPanelGui.Templates`) and the destination
--      row (matched by `ShopCategory` attribute, with path fallback).
--   2. Build the items list from the *local* `EquipmentCatalog`
--      (`ShopPanelTemplates.GetCategoryItems`); the server payload is only
--      used for live `available` + `stock`. Display copy (name, rarity,
--      subtitle, cost) all sources from the catalog so a missing/late server
--      response never blanks the cards.
--   3. Wipe prior clones from the row and clone the template once per item.
--      Each clone is populated by `Role` attribute lookups, not instance
--      names — designers can rename slots in Studio without touching code.
--
-- Returns a `{Slot}` list (card + itemId) the panel binds buy clicks against.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local SharedConfig = Shared:WaitForChild("Config")
local EquipmentCatalog = require(SharedConfig:WaitForChild("EquipmentCatalog"))
local ShopPanelTemplates = require(SharedConfig:WaitForChild("ShopPanelTemplates"))
local Constants = require(Shared:WaitForChild("Constants"))
local FtueConfig = require(SharedConfig:WaitForChild("FtueConfig"))

export type CatalogRow = {
	id: string,
	displayName: string,
	cost: number,
	available: boolean,
	subtitle: string?,
	--- Rotating-shop remaining count. `nil` = non-rotating / unlimited;
	--- a number = "X left this rotation". Zero = sold out.
	stock: number?,
}

export type Slot = { card: GuiObject, itemId: string }

-- BuyButton background color states. Kept in sync with the Studio template's
-- authored "BUY" green so the ready state matches what designers see in
-- Edit mode; the sold-out tone is a muted slate that reads against the navy
-- card chrome without clashing with the rarity stripes.
local READY_BUY_BG = Color3.fromRGB(56, 145, 70)
local SOLD_BUY_BG = Color3.fromRGB(72, 80, 92)

local M = {}

----------------------------------------------------------------------
-- Internal helpers.
----------------------------------------------------------------------

--- Convert a catalog `iconAssetId` into a URI that `ImageLabel.Image` can render.
--- Catalog assets may have been uploaded as Decals (the upload path Studio's
--- Asset Manager defaults to). `Tool.TextureId` resolves Decal -> Image
--- transparently, but `ImageLabel.Image` does not for many recently-uploaded
--- decals -- the label silently stays `IsLoaded = false`. `rbxthumb://` always
--- renders, regardless of underlying asset type, so we route numeric ids
--- through it. Pass-through for content URIs and pre-formed `rbxthumb://`.
local function toImageUri(raw: string?): string?
	if typeof(raw) ~= "string" or raw == "" then
		return nil
	end
	if raw:match("^rbxthumb://") or raw:match("^rbxasset://") or raw:match("^http") then
		return raw
	end
	local id = raw:match("rbxassetid://(%d+)") or raw:match("^(%d+)$")
	if id then
		return string.format("rbxthumb://type=Asset&id=%s&w=150&h=150", id)
	end
	return raw
end

--- Format an integer with thousands separators (12000 -> "12,000").
local function formatPrice(n: number): string
	local s = tostring(math.floor(math.max(0, n)))
	local out = ""
	local len = #s
	for i = 1, len do
		out = out .. s:sub(i, i)
		local remaining = len - i
		if remaining > 0 and (remaining % 3 == 0) then
			out = out .. ","
		end
	end
	return out
end
M.formatPrice = formatPrice

--- Look up the per-rotation max for an item from `ShopRotation.Bands`. Returns
--- `nil` for non-rotating items.
local function maxStockFor(itemId: string): number?
	local band = EquipmentCatalog.ShopRotation.Bands[itemId]
	if band then
		return math.max(band.min, band.max)
	end
	return nil
end

--- Read an attribute that defaults from the role node first, then the
--- category Defaults block, then the literal fallback.
local function pickText(node: Instance?, attr: string, fromCategory: string?, fallback: string): string
	if node then
		local v = node:GetAttribute(attr)
		if typeof(v) == "string" and v ~= "" then
			return v
		end
	end
	if typeof(fromCategory) == "string" and fromCategory ~= "" then
		return fromCategory
	end
	return fallback
end

--- True only for the **one** Tier 3 drill the FTUE hands the player for free
--- during `WaitDocksEquipmentShop` (sub-step `BuyDrill`). The server already
--- forces `cost = 0` + bypasses rotation stock for this exact item / step / sub
--- combo, so the UI just mirrors that policy: BUY → FREE label until the
--- purchase consumes the freebie (server flips sub to `ClosePanel` and the
--- normal cost / stock copy returns).
local function isFtueFreeFreebie(itemId: string): boolean
	if FtueConfig.Enabled ~= true then
		return false
	end
	if itemId ~= FtueConfig.FtueDocksFreeDrillItemId then
		return false
	end
	local plr = Players.LocalPlayer
	if not plr then
		return false
	end
	if plr:GetAttribute(Constants.FtueStepAttribute) ~= FtueConfig.Step.WaitDocksEquipmentShop then
		return false
	end
	return plr:GetAttribute(Constants.FtueDocksEquipmentShopSubStepAttribute) == "BuyDrill"
end

--- Find a child (or self) carrying `Role == role`. Mirrors
--- `ShopPanelTemplates.FindRole` but inlined to avoid a module call per slot.
local function findRole(card: Instance, role: string): Instance?
	for _, d in ipairs(card:GetDescendants()) do
		if d:GetAttribute("Role") == role then
			return d
		end
	end
	return nil
end

----------------------------------------------------------------------
-- Per-card population.
----------------------------------------------------------------------

local function applyRoles(
	card: GuiObject,
	item: EquipmentCatalog.ShopCatalogRow,
	server: CatalogRow?,
	defaults: any
)
	local rarity = ShopPanelTemplates.GetRarityStyle(item.rarity)

	-- RarityStripe (left edge) ------------------------------------------------
	local stripe = findRole(card, "RarityStripe")
	if stripe and stripe:IsA("GuiObject") then
		stripe.BackgroundColor3 = rarity.stripeColor
		stripe.BackgroundTransparency = 0
	end

	-- Icon (decal in IconBox) -------------------------------------------------
	-- When `iconAssetId` is set we paint the role-tagged Icon ImageLabel and
	-- hide the placeholder `IconHint` text. With no asset we leave both alone
	-- so the authored hint ("?", etc.) stays visible.
	local iconAssetUri = toImageUri(item.iconAssetId)
	local iconLbl = findRole(card, "Icon")
	local iconHint = findRole(card, "IconHint")
	if iconLbl and iconLbl:IsA("ImageLabel") then
		if iconAssetUri then
			iconLbl.Image = iconAssetUri
			iconLbl.ImageTransparency = 0
			iconLbl.ImageColor3 = Color3.new(1, 1, 1)
			iconLbl.Visible = true
		else
			iconLbl.Image = ""
			iconLbl.ImageTransparency = 1
			iconLbl.Visible = false
		end
	end
	if iconHint and iconHint:IsA("GuiObject") then
		iconHint.Visible = (iconAssetUri == nil)
	end

	-- Name --------------------------------------------------------------------
	local nameLbl = findRole(card, "Name")
	if nameLbl and (nameLbl:IsA("TextLabel") or nameLbl:IsA("TextButton") or nameLbl:IsA("TextBox")) then
		nameLbl.Text = item.displayName
	end

	-- RarityTag ---------------------------------------------------------------
	local rarityLbl = findRole(card, "RarityTag")
	if rarityLbl and rarityLbl:IsA("TextLabel") then
		rarityLbl.Text = rarity.label or "RARITY"
		rarityLbl.TextColor3 = rarity.tagColor
	end

	-- Description (subtitle) --------------------------------------------------
	local descLbl = findRole(card, "Description")
	if descLbl and descLbl:IsA("TextLabel") then
		descLbl.Text = (typeof(item.subtitle) == "string" and item.subtitle) or ""
	end

	-- Stock readout (current / max) ------------------------------------------
	local stockLbl = findRole(card, "StockCount")
	if stockLbl and stockLbl:IsA("TextLabel") then
		local format = stockLbl:GetAttribute("Format")
		if typeof(format) ~= "string" or format == "" then
			format = defaults and defaults.StockFormat or "%d / %d"
		end
		local current = if server and typeof(server.stock) == "number" then server.stock else nil
		local maxRotation = maxStockFor(item.id)
		if typeof(current) == "number" and typeof(maxRotation) == "number" then
			stockLbl.Text = string.format(format, current, maxRotation)
		elseif typeof(current) == "number" then
			stockLbl.Text = tostring(current)
		else
			stockLbl.Text = "\u{221E}" -- infinity glyph for unlimited / non-rotating
		end
	end

	-- Stock subtitle ("IN STOCK" / "SOLD OUT") --------------------------------
	local stockSub = findRole(card, "StockSubtitle")
	if stockSub and stockSub:IsA("TextLabel") then
		local soldOut = (server ~= nil and typeof(server.stock) == "number" and server.stock <= 0) == true
		if soldOut then
			stockSub.Text = pickText(stockSub, "SoldOutText", defaults and defaults.StockSubtitleSoldOut, "SOLD OUT")
		else
			stockSub.Text = pickText(stockSub, "InStockText", defaults and defaults.StockSubtitleInStock, "IN STOCK")
		end
	end

	-- Cost --------------------------------------------------------------------
	-- During the FTUE free-drill window we replace the price string entirely
	-- (no `$` glyph, no thousands-formatted zero) so the player reads "FREE"
	-- where the price normally lives. Server already forces `cost = 0`, so
	-- charging math stays correct regardless of what we draw here.
	local costLbl = findRole(card, "Cost")
	if costLbl and costLbl:IsA("TextLabel") then
		if isFtueFreeFreebie(item.id) then
			costLbl.Text = pickText(costLbl, "FreeText", defaults and defaults.CostFreeText, "FREE")
		else
			local format = costLbl:GetAttribute("Format")
			if typeof(format) ~= "string" or format == "" then
				format = defaults and defaults.CostFormat or "$ %s"
			end
			costLbl.Text = string.format(format, formatPrice(item.cost))
		end
	end

	-- Buy button text + background color -------------------------------------
	-- "Sold out" and "unavailable" (placeholder, missing template, catalog
	-- request failed) collapse into one greyed-out SOLD OUT state per design.
	local buyText = findRole(card, "BuyText")
	if buyText and buyText:IsA("TextLabel") then
		local stock = if server and typeof(server.stock) == "number" then server.stock else nil
		local available = server ~= nil and server.available == true
		local soldOut = (stock ~= nil and stock <= 0) or (not available)
		if soldOut then
			buyText.Text = pickText(buyText, "SoldOutText", defaults and defaults.BuySoldOutText, "SOLD OUT")
		else
			buyText.Text = pickText(buyText, "ReadyText", defaults and defaults.BuyText, "BUY")
		end
		-- Walk up to the actual GuiButton and recolor its background.
		local buyButton: Instance? = buyText.Parent
		while buyButton and not buyButton:IsA("GuiButton") do
			buyButton = buyButton.Parent
		end
		if buyButton and buyButton:IsA("GuiObject") then
			buyButton.BackgroundColor3 = if soldOut then SOLD_BUY_BG else READY_BUY_BG
		end
	end

	-- Mark with id so panel-level wiring (Activated → purchase) can resolve it.
	card:SetAttribute("EquipmentShopItemId", item.id)
end

M.ApplyCardByRoles = applyRoles

----------------------------------------------------------------------
-- Per-category populate (clears and re-clones).
----------------------------------------------------------------------

--- Clear prior clones from the row. Anything tagged `IsShopCardClone = true`
--- is destroyed; layout primitives (`UIListLayout`, `UIPadding`, `UIGradient`,
--- etc.) and stray static children are left in place.
local function clearClonesIn(row: GuiObject)
	for _, child in ipairs(row:GetChildren()) do
		if child:GetAttribute("IsShopCardClone") == true then
			child:Destroy()
		end
	end
end

function M.PopulateCategoryRow(panelGui: Instance, shopCategory: string, byId: { [string]: CatalogRow }): { Slot }
	local cat = ShopPanelTemplates.GetCategory(shopCategory)
	if not cat then
		return {}
	end
	local row = ShopPanelTemplates.FindRowForCategory(panelGui, shopCategory)
	if not row then
		warn(string.format("[EquipmentShopPopulate] Row not found for category %q", shopCategory))
		return {}
	end
	local template = ShopPanelTemplates.FindTemplate(panelGui, shopCategory)
	if not template then
		warn(string.format(
			"[EquipmentShopPopulate] Template %q not found under %s.Templates — ensure it's authored + Saved.",
			cat.TemplateName,
			panelGui:GetFullName()
		))
		return {}
	end

	-- First populate of this row: also wipe any leftover hand-authored cards
	-- (the DrillCard1 preview we left in Studio for visual reference). After
	-- that, only `IsShopCardClone` clones get cleared.
	if row:GetAttribute("ShopRowEverPopulated") ~= true then
		for _, child in ipairs(row:GetChildren()) do
			if child:IsA("GuiObject") and child ~= template then
				child:Destroy()
			end
		end
		row:SetAttribute("ShopRowEverPopulated", true)
	else
		clearClonesIn(row)
	end

	local items = ShopPanelTemplates.GetCategoryItems(shopCategory)
	local slots: { Slot } = {}
	for i, item in ipairs(items) do
		local card = template:Clone()
		card.Name = "Card_" .. item.id
		card.Visible = true
		card.LayoutOrder = i
		card:SetAttribute("IsShopCardClone", true)
		card:SetAttribute("ShopCategory", shopCategory)
		applyRoles(card, item, byId[item.id], cat.Defaults)
		card.Parent = row
		table.insert(slots, { card = card, itemId = item.id })
	end
	return slots
end

function M.PopulateAllCategories(panelGui: Instance, byId: { [string]: CatalogRow }): { Slot }
	local slots: { Slot } = {}
	for shopCategory in pairs(ShopPanelTemplates.Categories) do
		for _, slot in ipairs(M.PopulateCategoryRow(panelGui, shopCategory, byId)) do
			table.insert(slots, slot)
		end
	end
	return slots
end

----------------------------------------------------------------------
-- Back-compat: legacy single-card populate (used to be called per
-- hand-authored slot). Kept as a thin wrapper so any straggling caller
-- still compiles, but the new flow is template-based above.
----------------------------------------------------------------------

function M.ApplyCard(card: GuiObject, row: CatalogRow?)
	local itemId = card:GetAttribute("EquipmentShopItemId")
	if typeof(itemId) ~= "string" then
		return
	end
	local catalogRow = nil
	for _, r in ipairs(EquipmentCatalog.buildShopItems()) do
		if r.id == itemId then
			catalogRow = r
			break
		end
	end
	if not catalogRow then
		return
	end
	local shopCategory = card:GetAttribute("ShopCategory")
	local cat = typeof(shopCategory) == "string" and ShopPanelTemplates.GetCategory(shopCategory) or nil
	applyRoles(card, catalogRow, row, cat and cat.Defaults or nil)
end

return M
