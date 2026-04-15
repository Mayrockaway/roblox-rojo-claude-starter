--!strict
-- Single source of truth for sellable + placable equipment: identity, costs, and gameplay knobs.
-- `OilConfig` drill/pump/prospect/pipe tables are derived here so shop + placement never drift.
--
-- Fields:
--   `cashCost` — used for gameplay spends (drill start, pump place, pipe place, prospect when > 0).
--   `shopPrice` — if set, the equipment shop charges this instead of `cashCost` (UI + purchase).

export type EquipmentRow = {
	id: string,
	toolName: string,
	toolKind: string,
	tierKey: string?,
	displayName: string,
	--- Spend for placement / drill / pump / pipe / prospect (server `TrySpendCash`).
	cashCost: number,
	--- Optional shop-only price; when nil, shop uses `cashCost`.
	shopPrice: number?,
	purchasable: boolean,
	sortOrder: number,
	--- Drill (`TryStartDrill`): effective seconds = tile.drillSeconds / timeDivisor.
	drillTimeDivisor: number?,
	drillFallbackSeconds: number?,
	--- Pump (`TryPlacePump`): multiplies base flow with biome.
	pumpFlowMultiplier: number?,
	--- Pipe segment placement (`TryPlacePipe` uses `OilConfig.Pipes` built from pipe row).
	pipeMinLength: number?,
	pipeMaxLength: number?,
	pipeSnapRadius: number?,
	--- Prospector (`TryStartProspect`).
	prospectDurationSeconds: number?,
	--- Second line on shop cards (e.g. one-use vs persistent).
	shopSubtitle: string?,
	--- Placed model / ghost: extra world +Y after anchor/bbox alignment (fine trim). Prefer naming
	--- a `BasePart` `Bottom` or `bottom` on the asset; see `Shared.Utils.PlacementAnchor`.
	visualGroundOffsetStuds: number?,
}

--- Edit this list only. Keep `tierKey` as "T1"|"T2"|"T3" for drills and pumps.
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
		pumpFlowMultiplier = nil,
		pipeMinLength = nil,
		pipeMaxLength = nil,
		pipeSnapRadius = nil,
		prospectDurationSeconds = nil,
		shopSubtitle = "One-use reveal",
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
		pumpFlowMultiplier = nil,
		pipeMinLength = nil,
		pipeMaxLength = nil,
		pipeSnapRadius = nil,
		prospectDurationSeconds = nil,
		shopSubtitle = "One-use reveal",
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
		pumpFlowMultiplier = nil,
		pipeMinLength = nil,
		pipeMaxLength = nil,
		pipeSnapRadius = nil,
		prospectDurationSeconds = nil,
		shopSubtitle = "One-use reveal",
	},
	{
		id = "pump_t1",
		toolName = "Pump_T1",
		toolKind = "Pump",
		tierKey = "T1",
		displayName = "Basic Pump",
		cashCost = 250,
		shopPrice = nil,
		purchasable = true,
		sortOrder = 5,
		drillTimeDivisor = nil,
		drillFallbackSeconds = nil,
		pumpFlowMultiplier = 1.0,
		pipeMinLength = nil,
		pipeMaxLength = nil,
		pipeSnapRadius = nil,
		prospectDurationSeconds = nil,
		shopSubtitle = "Persistent",
	},
	{
		id = "pump_t2",
		toolName = "Pump_T2",
		toolKind = "Pump",
		tierKey = "T2",
		displayName = "Standard Pump",
		cashCost = 550,
		shopPrice = nil,
		purchasable = true,
		sortOrder = 6,
		drillTimeDivisor = nil,
		drillFallbackSeconds = nil,
		pumpFlowMultiplier = 2.5,
		pipeMinLength = nil,
		pipeMaxLength = nil,
		pipeSnapRadius = nil,
		prospectDurationSeconds = nil,
		shopSubtitle = "Persistent",
	},
	{
		id = "pump_t3",
		toolName = "Pump_T3",
		toolKind = "Pump",
		tierKey = "T3",
		displayName = "Advanced Pump",
		cashCost = 1200,
		shopPrice = nil,
		purchasable = true,
		sortOrder = 7,
		drillTimeDivisor = nil,
		drillFallbackSeconds = nil,
		pumpFlowMultiplier = 6.0,
		pipeMinLength = nil,
		pipeMaxLength = nil,
		pipeSnapRadius = nil,
		prospectDurationSeconds = nil,
		shopSubtitle = "Persistent",
	},
	{
		id = "prospector",
		toolName = "Prospector",
		toolKind = "Prospector",
		tierKey = nil,
		displayName = "Prospector",
		cashCost = 0,
		shopPrice = 500,
		purchasable = true,
		sortOrder = 8,
		drillTimeDivisor = nil,
		drillFallbackSeconds = nil,
		pumpFlowMultiplier = nil,
		pipeMinLength = nil,
		pipeMaxLength = nil,
		pipeSnapRadius = nil,
		prospectDurationSeconds = 5,
		shopSubtitle = "One-use chunk survey",
	},
	{
		id = "pipe",
		toolName = "Pipe",
		toolKind = "Pipe",
		tierKey = nil,
		displayName = "Pipe",
		cashCost = 50,
		shopPrice = nil,
		purchasable = true,
		sortOrder = 9,
		drillTimeDivisor = nil,
		drillFallbackSeconds = nil,
		pumpFlowMultiplier = nil,
		pipeMinLength = 4,
		pipeMaxLength = 60,
		pipeSnapRadius = 3,
		prospectDurationSeconds = nil,
		shopSubtitle = "Per segment",
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
}

local function shopPriceFor(row: EquipmentRow): number
	local sp = row.shopPrice
	if sp ~= nil then
		return math.max(0, math.floor(sp))
	end
	return math.max(0, math.floor(row.cashCost))
end

local EquipmentCatalog = {}

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

--- Shape expected by `OilConfig.PumpTiers` / `OilStateService:TryPlacePump`.
function EquipmentCatalog.getPumpTiersMap(): {
	[string]: {
		cost: number,
		flowMultiplier: number,
		templateName: string,
		displayName: string,
		visualGroundOffsetStuds: number?,
	},
}
	local m: any = {}
	for _, r in ipairs(ITEMS) do
		if r.toolKind == "Pump" and r.tierKey then
			m[r.tierKey] = {
				cost = r.cashCost,
				flowMultiplier = r.pumpFlowMultiplier or 1,
				templateName = r.toolName,
				displayName = r.displayName,
				visualGroundOffsetStuds = r.visualGroundOffsetStuds,
			}
		end
	end
	return m
end

--- Shape expected by `OilConfig.Prospecting` / `OilStateService:TryStartProspect`.
function EquipmentCatalog.getProspecting(): { durationSeconds: number, cost: number, templateName: string }
	for _, r in ipairs(ITEMS) do
		if r.toolKind == "Prospector" then
			return {
				durationSeconds = r.prospectDurationSeconds or 5,
				cost = r.cashCost,
				templateName = r.toolName,
			}
		end
	end
	return { durationSeconds = 5, cost = 0, templateName = "Prospector" }
end

--- Shape expected by `OilConfig.Pipes` / pipe placement in `OilStateService`.
function EquipmentCatalog.getPipes(): { Cost: number, MinLength: number, MaxLength: number, EndpointSnapRadius: number }
	for _, r in ipairs(ITEMS) do
		if r.toolKind == "Pipe" then
			return {
				Cost = r.cashCost,
				MinLength = r.pipeMinLength or 4,
				MaxLength = r.pipeMaxLength or 60,
				EndpointSnapRadius = r.pipeSnapRadius or 3,
			}
		end
	end
	return { Cost = 50, MinLength = 4, MaxLength = 60, EndpointSnapRadius = 3 }
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
