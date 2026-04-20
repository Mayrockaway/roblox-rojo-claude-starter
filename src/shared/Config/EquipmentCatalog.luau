--!strict
-- Single source of truth for sellable equipment: identity, costs, and gameplay knobs.
-- `OilConfig.DrillTiers` is derived from here so the shop and `OilStateService:TryStartDrill`
-- never drift. Pumps are now plot-static (one auto-placed `isCenterPump = true` per unlocked
-- chunk) and upgraded via prox prompt (see `VeinConfig.PumpUpgrades`); they are NOT sold here.
-- Pipes / prospectors / drums have been removed entirely \u2014 drilling auto-reveals the drilled tile.
--
-- Fields:
--   `cashCost` \u2014 server-side spend for `TryStartDrill` (drill purchase price = `shopPrice or cashCost`).

export type EquipmentRow = {
	id: string,
	toolName: string,
	toolKind: string,
	tierKey: string?,
	displayName: string,
	--- Spend for drill placement (`OilStateService:TryStartDrill`).
	cashCost: number,
	--- Optional shop-only price; when nil, shop uses `cashCost`.
	shopPrice: number?,
	purchasable: boolean,
	sortOrder: number,
	--- Drill (`TryStartDrill`): effective seconds = tile.drillSeconds / timeDivisor.
	drillTimeDivisor: number?,
	drillFallbackSeconds: number?,
	--- Second line on shop cards (e.g. one-use vs persistent).
	shopSubtitle: string?,
	--- Display rarity bucket for shop UI (`ShopPanelTemplates.Rarities`).
	--- Server treats this as cosmetic only; it never gates purchases or affects price.
	rarity: string?,
}

--- Edit this list only. Keep `tierKey` as "T1"|"T2"|"T3" for active drills; T4-T6 are
--- "Coming soon" placeholder tiles in the shop with `tierKey = nil` so they can't
--- be placed/used until real Tool templates and gameplay tuning ship.
local ITEMS: { EquipmentRow } = {
	{
		id = "drill_t1",
		toolName = "Drill_T1",
		toolKind = "Drill",
		tierKey = "T1",
		displayName = "Basic Drill",
		cashCost = 50,
		shopPrice = nil,
		purchasable = true,
		sortOrder = 2,
		drillTimeDivisor = 1,
		drillFallbackSeconds = 10,
		shopSubtitle = "One-use reveal",
		rarity = "COMMON",
	},
	{
		id = "drill_t2",
		toolName = "Drill_T2",
		toolKind = "Drill",
		tierKey = "T2",
		displayName = "Standard Drill",
		cashCost = 100,
		shopPrice = nil,
		purchasable = true,
		sortOrder = 3,
		drillTimeDivisor = 10,
		drillFallbackSeconds = 10,
		shopSubtitle = "One-use reveal",
		rarity = "UNCOMMON",
	},
	{
		id = "drill_t3",
		toolName = "Drill_T3",
		toolKind = "Drill",
		tierKey = "T3",
		displayName = "Advanced Drill",
		cashCost = 200,
		shopPrice = nil,
		purchasable = true,
		sortOrder = 4,
		drillTimeDivisor = 30,
		drillFallbackSeconds = 10,
		shopSubtitle = "One-use reveal",
		rarity = "RARE",
	},
	-- Placeholder drills (EPIC / LEGENDARY / MYTHIC). They render in the shop
	-- (`purchasable = true`) but `tierKey = nil` keeps them out of
	-- `OilConfig.DrillTiers` so they can't be placed/used until real Tool
	-- templates and gameplay tuning ship. Server `EquipmentShopService` will
	-- reject the actual purchase until a matching Tool exists in
	-- `ServerStorage.EquipmentShopTemplates.<toolName>`.
	{
		id = "drill_t4",
		toolName = "Drill_T4",
		toolKind = "Drill",
		tierKey = nil,
		displayName = "Heavy Bore",
		cashCost = 0,
		shopPrice = 12000,
		purchasable = true,
		sortOrder = 4.1,
		drillTimeDivisor = nil,
		drillFallbackSeconds = nil,
		shopSubtitle = "Coming soon",
		rarity = "EPIC",
	},
	{
		id = "drill_t5",
		toolName = "Drill_T5",
		toolKind = "Drill",
		tierKey = nil,
		displayName = "Diesel Rig",
		cashCost = 0,
		shopPrice = 35000,
		purchasable = true,
		sortOrder = 4.2,
		drillTimeDivisor = nil,
		drillFallbackSeconds = nil,
		shopSubtitle = "Coming soon",
		rarity = "LEGENDARY",
	},
	{
		id = "drill_t6",
		toolName = "Drill_T6",
		toolKind = "Drill",
		tierKey = nil,
		displayName = "Tycoon Auger",
		cashCost = 0,
		shopPrice = 100000,
		purchasable = true,
		sortOrder = 4.3,
		drillTimeDivisor = nil,
		drillFallbackSeconds = nil,
		shopSubtitle = "Coming soon",
		rarity = "MYTHIC",
	},
}

export type ShopCatalogRow = {
	id: string,
	displayName: string,
	cost: number,
	toolTemplateName: string,
	toolKind: string,
	tier: string?,
	subtitle: string?,
	rarity: string?,
}

export type ShopStockBand = { min: number, max: number }

--- Rotating-shop knobs. Every `RefreshIntervalSeconds`, the server rolls a
--- fresh stock count per listed item:
---   `stock[id] = max(CoreFloor[id] or 0, rng:NextInteger(band.min, band.max))`
--- Items NOT in `Bands` are non-rotating / always available (fall through to
--- current infinite behavior). Core items are guaranteed a minimum every
--- refresh so players never get stranded with no T1 drill.
local ShopRotation = {
	RefreshIntervalSeconds = 180, -- 3 min
	Bands = {
		drill_t1   = { min = 2,  max = 4  } :: ShopStockBand,
		drill_t2   = { min = 0,  max = 2  } :: ShopStockBand,
		drill_t3   = { min = 0,  max = 1  } :: ShopStockBand,
		drill_t4   = { min = 0,  max = 1  } :: ShopStockBand,
		drill_t5   = { min = 0,  max = 1  } :: ShopStockBand,
		drill_t6   = { min = 0,  max = 1  } :: ShopStockBand,
	} :: { [string]: ShopStockBand },
	CoreFloor = {
		drill_t1 = 1,
	} :: { [string]: number },
}

local function shopPriceFor(row: EquipmentRow): number
	local sp = row.shopPrice
	if sp ~= nil then
		return math.max(0, math.floor(sp))
	end
	return math.max(0, math.floor(row.cashCost))
end

local EquipmentCatalog = {}

EquipmentCatalog.ShopRotation = ShopRotation

--- Roll fresh per-refresh stock counts. Items present in `ShopRotation.Bands`
--- get a uniform int in `[min, max]`, then floored to `CoreFloor` if set.
--- Items NOT listed (e.g. hypothetical non-rotating extras) are omitted from
--- the result \u2014 callers should treat "missing key" as "unlimited / always in stock".
function EquipmentCatalog.rollShopStock(rng: Random): { [string]: number }
	local out: { [string]: number } = {}
	for id, band in pairs(ShopRotation.Bands) do
		local lo = math.max(0, math.floor(band.min))
		local hi = math.max(lo, math.floor(band.max))
		local n = rng:NextInteger(lo, hi)
		local floor = ShopRotation.CoreFloor[id]
		if typeof(floor) == "number" and floor > n then
			n = floor
		end
		out[id] = n
	end
	return out
end

function EquipmentCatalog.getAllRows(): { EquipmentRow }
	return ITEMS
end

function EquipmentCatalog.getRowById(id: string): EquipmentRow?
	for _, r in ipairs(ITEMS) do
		if r.id == id then
			return r
		end
	end
	return nil
end

function EquipmentCatalog.buildShopItems(): { ShopCatalogRow }
	local rows: { ShopCatalogRow } = {}
	for _, r in ipairs(ITEMS) do
		if r.purchasable then
			table.insert(rows, {
				id = r.id,
				displayName = r.displayName,
				cost = shopPriceFor(r),
				toolTemplateName = r.toolName,
				toolKind = r.toolKind,
				tier = r.tierKey,
				subtitle = r.shopSubtitle,
				rarity = r.rarity,
			})
		end
	end
	return rows
end

--- Shape expected by `OilConfig.DrillTiers` / `OilStateService:TryStartDrill`.
function EquipmentCatalog.getDrillTiersMap(): {
	[string]: {
		cost: number,
		timeDivisor: number,
		fallbackSeconds: number,
		templateName: string,
		displayName: string,
	},
}
	local m: any = {}
	for _, r in ipairs(ITEMS) do
		if r.toolKind == "Drill" and r.tierKey then
			m[r.tierKey] = {
				cost = r.cashCost,
				timeDivisor = r.drillTimeDivisor or 1,
				fallbackSeconds = r.drillFallbackSeconds or 10,
				templateName = r.toolName,
				displayName = r.displayName,
			}
		end
	end
	return m
end

--- Hint for client config (`PlotResourceService`); T1 drill placement economy.
function EquipmentCatalog.getDrillPlacementCostHint(): number
	local m = EquipmentCatalog.getDrillTiersMap()
	local t1 = m.T1
	if t1 then
		return t1.cost
	end
	return 0
end

return EquipmentCatalog
