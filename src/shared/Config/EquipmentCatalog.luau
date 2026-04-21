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
	--- Decal asset (`rbxassetid://...`) used for shop card Icon and the
	--- Tool's `TextureId` (hotbar / native backpack). Optional — when nil
	--- the shop falls back to its `IconHint` and the hotbar shows the tool
	--- name stub. The Tool template's `TextureId` should be set in Studio
	--- to the same id so the native backpack icon stays in sync.
	iconAssetId: string?,
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
		-- shopSubtitle auto-derived by `formatDrillStatsLine` → "1 meters/sec • 10 sec/tile"
		rarity = "COMMON",
		iconAssetId = "rbxassetid://106727111593273",
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
		-- shopSubtitle auto-derived → "10 meters/sec • 1.0 sec/tile"
		rarity = "UNCOMMON",
		iconAssetId = "rbxassetid://116861633893420",
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
		-- shopSubtitle auto-derived → "30 meters/sec • 0.33 sec/tile"
		rarity = "RARE",
		iconAssetId = "rbxassetid://90931184788322",
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
		tierKey = "T4",
		displayName = "Sundae Driller",
		cashCost = 12000,
		shopPrice = nil,
		purchasable = true,
		sortOrder = 4.1,
		drillTimeDivisor = 100,
		drillFallbackSeconds = 10,
		-- shopSubtitle auto-derived → "100 meters/sec • 0.10 sec/tile"
		rarity = "EPIC",
		iconAssetId = "rbxassetid://123969726593017",
	},
	{
		id = "drill_t5",
		toolName = "Drill_T5",
		toolKind = "Drill",
		tierKey = "T5",
		displayName = "Glizzy Grinder",
		cashCost = 35000,
		shopPrice = nil,
		purchasable = true,
		sortOrder = 4.2,
		drillTimeDivisor = 300,
		drillFallbackSeconds = 10,
		-- shopSubtitle auto-derived → "300 meters/sec • 0.03 sec/tile"
		rarity = "LEGENDARY",
		iconAssetId = "rbxassetid://129251905585363",
	},
	{
		id = "drill_t6",
		toolName = "Drill_T6",
		toolKind = "Drill",
		tierKey = "T6",
		displayName = "Ground Pounder",
		cashCost = 100000,
		shopPrice = nil,
		purchasable = true,
		sortOrder = 4.3,
		drillTimeDivisor = 1000,
		drillFallbackSeconds = 10,
		-- shopSubtitle auto-derived → "1000 meters/sec • 0.01 sec/tile"
		rarity = "MYTHIC",
		iconAssetId = "rbxassetid://135865747560987",
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
	iconAssetId: string?,
}

export type ShopStockBand = {
	min: number,
	max: number,
	--- Per-player additive scale. Every roll the server adds
	--- `floor(perPlayer * max(1, playerCount))` to **both** `min` and `max`
	--- before sampling, so a full lobby gets a meaningfully bigger rack
	--- without changing the *shape* of the band. Omit / set to 0 for items
	--- that should NOT scale with population (e.g. mythic chase items where
	--- "≤1 even on a full server" is the design intent).
	perPlayer: number?,
}

--- Rotating-shop knobs. Every `RefreshIntervalSeconds`, the server rolls a
--- fresh stock count per listed item:
---   `extra  = floor((band.perPlayer or 0) * max(1, playerCount))`
---   `lo     = max(0, floor(band.min) + extra)`
---   `hi     = max(lo, floor(band.max) + extra)`
---   `stock[id] = max(CoreFloor[id] or 0, rng:NextInteger(lo, hi))`
--- Items NOT in `Bands` are non-rotating / always available (fall through to
--- current infinite behavior). Core items are guaranteed a minimum every
--- refresh so players never get stranded with no early-tier drill.
---
--- Band tuning rationale (see chat 2026-04 "store capacity scaling"):
---   * T1/T2/T3 are cheap consumables ($50/$100/$200) — bands sized so a
---     solo player buying everything they can afford never empties the rack
---     mid-window, and full lobbies see ~5-6 drills per player per rotation.
---   * T4 ($12k) is a real cash sink; rack caps stay low so wallet, not
---     stock, is the bottleneck.
---   * T5/T6 stay aspirational — T6 still ≤1 even at 8 players to preserve
---     the "wow it's actually here" moment.
local ShopRotation = {
	RefreshIntervalSeconds = 180, -- 3 min
	Bands = {
		drill_t1   = { min = 5,  max = 8,  perPlayer = 1.25 } :: ShopStockBand,
		drill_t2   = { min = 3,  max = 5,  perPlayer = 1.0  } :: ShopStockBand,
		drill_t3   = { min = 2,  max = 3,  perPlayer = 0.5  } :: ShopStockBand,
		drill_t4   = { min = 1,  max = 2,  perPlayer = 0.35 } :: ShopStockBand,
		drill_t5   = { min = 0,  max = 1,  perPlayer = 0.20 } :: ShopStockBand,
		drill_t6   = { min = 0,  max = 1,  perPlayer = 0.10 } :: ShopStockBand,
	} :: { [string]: ShopStockBand },
	CoreFloor = {
		drill_t1 = 3,
		drill_t2 = 1,
	} :: { [string]: number },
}

local function shopPriceFor(row: EquipmentRow): number
	local sp = row.shopPrice
	if sp ~= nil then
		return math.max(0, math.floor(sp))
	end
	return math.max(0, math.floor(row.cashCost))
end

--- Round a small float to a sensible string for the shop subtitle. We always
--- want at least 2 significant figures: `0.333…` → `"0.33"`, `1.0` → `"1.0"`,
--- `10` → `"10"`. Avoids `"0.3333333"` and avoids `"1"` (looks identical to
--- `int 1` next to other rounded values).
local function formatTileSeconds(seconds: number): string
	if seconds <= 0 then
		return "0"
	end
	if seconds >= 10 then
		return string.format("%.0f", seconds)
	end
	if seconds >= 1 then
		return string.format("%.1f", seconds)
	end
	return string.format("%.2f", seconds)
end

--- Per-drill stats line shown in the shop card's `Role = "Description"` slot.
--- Always derived from `drillTimeDivisor` + `drillFallbackSeconds` so a knob
--- change in this file flows through to the UI with no extra edit. A drill
--- row may still set `shopSubtitle` manually to override (kept for designer
--- escape hatches / placeholder copy on tiers that aren't fully wired yet).
local function formatDrillStatsLine(row: EquipmentRow): string?
	if row.toolKind ~= "Drill" then
		return nil
	end
	local divisor = tonumber(row.drillTimeDivisor) or 0
	if divisor <= 0 then
		return nil
	end
	local fallback = tonumber(row.drillFallbackSeconds) or 10
	local tileSec = fallback / divisor
	return string.format("%d meters/sec • %s sec/tile", math.floor(divisor + 0.5), formatTileSeconds(tileSec))
end

local EquipmentCatalog = {}

EquipmentCatalog.ShopRotation = ShopRotation

--- Roll fresh per-refresh stock counts. Items present in `ShopRotation.Bands`
--- get a uniform int in `[min, max]`, then floored to `CoreFloor` if set.
--- Items NOT listed (e.g. hypothetical non-rotating extras) are omitted from
--- the result \u2014 callers should treat "missing key" as "unlimited / always in stock".
function EquipmentCatalog.rollShopStock(rng: Random, playerCount: number?): { [string]: number }
	local pop = math.max(1, math.floor(tonumber(playerCount) or 1))
	local out: { [string]: number } = {}
	for id, band in pairs(ShopRotation.Bands) do
		local extra = math.floor((tonumber(band.perPlayer) or 0) * pop)
		local lo = math.max(0, math.floor(band.min) + extra)
		local hi = math.max(lo, math.floor(band.max) + extra)
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
				subtitle = r.shopSubtitle or formatDrillStatsLine(r),
				rarity = r.rarity,
				iconAssetId = r.iconAssetId,
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
