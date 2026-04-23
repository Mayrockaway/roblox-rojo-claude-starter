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
	--- (Drill) When `true`, this drill can be placed on a tile that has
	--- already been drilled (any state — dead, productive, mid-reveal).
	--- The tile is wiped back to "pre-drilled" state and the standard
	--- drill → shovel → reveal flow runs again, rolling a fresh vein
	--- against the chunk's `GroundRarityWeights`. Drills without this
	--- flag continue to reject already-drilled tiles. Center-pump tile
	--- (`tile.hasCenterPump = true`) is **always** rejected regardless
	--- of this flag — that pump is permanent. Currently set on T4-T6;
	--- T1-T3 stay strictly first-drill only. See `OilStateService:TryStartDrill`.
	canRedrill: boolean?,
	--- (Drill) Per-rarity multiplier applied to `GroundRarityWeights` at
	--- roll time inside `VeinCrateConfig.RollVeinType`. Multipliers
	--- default to `1.0` for any rarity not listed (no change). Values
	--- `< 1` shrink that rarity's slice (less likely), `> 1` grow it
	--- (more likely), `0` removes it entirely. Applies to **every** drill
	--- placed with this tier, not just rerolls — so e.g. T6 rolls the
	--- biased weights even on first drills. See `OilStateService:_completeDrill`.
	---
	--- Currently set only on T6 (Option 3 from chat 2026-04 "T6 reroll
	--- bias"): half dud rate + 1.5× boost to Epic+ rarities. Future
	--- Robux-gated drills can ship their own bias here (e.g. `Unlucky = 0`,
	--- larger Mythic boost) without changing the roll function.
	rerollWeightBias: { [string]: number }?,
}

--- Edit this list only. Keep `tierKey` as "T1"|"T2"|"T3" for active drills; T4-T6 are
--- "Coming soon" placeholder tiles in the shop with `tierKey = nil` so they can't
--- be placed/used until real Tool templates and gameplay tuning ship.
---
--- Drill pricing (`cashCost`) is **linear in `drillTimeDivisor` at $50 per
--- m/s**, anchored on the Basic Drill ($50 / 1 m/s):
---     T1 / 1     m/s →     $50
---     T2 / 10    m/s →    $500
---     T3 / 30    m/s →  $1 500
---     T4 / 100   m/s →  $5 000
---     T5 / 300   m/s → $15 000
---     T6 / 1 000 m/s → $50 000
--- Linear (vs. the previous mixed exponential / discount curve) means cost
--- per meter is identical across all tiers — players pick the tier they
--- can afford / want to flex, not the tier with the best $/m/s deal.
--- Same number drives placement cost (`TryStartDrill`) since `shopPrice`
--- is `nil` everywhere; if a designer ever wants the shop and placement
--- to diverge, set `shopPrice` on that row.
---
--- Drill **redrill** capability (`canRedrill`) and rarity bias
--- (`rerollWeightBias`):
---   * T1 / T2 / T3 — strict first-drill only. Reject already-drilled tiles.
---   * T4 / T5     — `canRedrill = true`, no bias. Player can re-drill any
---                    productive / dead / mid-reveal tile (except the
---                    chunk's permanent center pump). Wipes the tile back
---                    to pre-drilled and re-rolls against the same
---                    `GroundRarityWeights` — same odds as a fresh tile.
---   * T6          — `canRedrill = true` **and** `rerollWeightBias` set
---                    (Option 3 from chat 2026-04 "T6 reroll bias"):
---                    `Unlucky = 0.5` (half dud rate) and Epic / Exotic /
---                    Legendary / Ascendant / Transcendent / Mythic each
---                    `× 1.5`. Bias applies on **every** T6 drill, not
---                    only rerolls — so a stocked T6 is meaningfully
---                    more enticing to buy at $50k vs. T4 at $5k. Future
---                    Robux drills can ship `Unlucky = 0` + larger boosts.
---
--- Net Bronze T6 rates (vs. base `2000/4500/2500/1500/800/500/200`):
---   Unlucky 16.7% → 8.5%  •  Epic 4.17% → 6.4%  •  Legendary 1.67% → 2.6%
--- Net Diamond T6 rates: Unlucky 2.3% → 1.2%  •  Mythic 3.4% → 4.1%
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
		cashCost = 500,
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
		cashCost = 1500,
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
		cashCost = 5000,
		shopPrice = nil,
		purchasable = true,
		sortOrder = 4.1,
		drillTimeDivisor = 100,
		drillFallbackSeconds = 10,
		--- Manual subtitle (overrides `formatDrillStatsLine`) so we can
		--- advertise the T4+ re-drill capability alongside the speed stat.
		--- Edit freely; if you set this back to nil, the auto-derived
		--- "100 meters/sec • 0.10 sec/tile" line returns.
		shopSubtitle = "100 m/s • 0.10 sec/tile • can RE-DRILL ANY TILE!",
		rarity = "EPIC",
		iconAssetId = "rbxassetid://123969726593017",
		canRedrill = true,
	},
	{
		id = "drill_t5",
		toolName = "Drill_T5",
		toolKind = "Drill",
		tierKey = "T5",
		displayName = "Glizzy Grinder",
		cashCost = 15000,
		shopPrice = nil,
		purchasable = true,
		sortOrder = 4.2,
		drillTimeDivisor = 300,
		drillFallbackSeconds = 10,
		--- Manual subtitle (overrides `formatDrillStatsLine`). Edit freely;
		--- set to nil to fall back to "300 meters/sec • 0.03 sec/tile".
		shopSubtitle = "300 m/s • 0.03 sec/tile • can RE-DRILL ANY TILE!",
		rarity = "LEGENDARY",
		iconAssetId = "rbxassetid://129251905585363",
		canRedrill = true,
	},
	{
		id = "drill_t6",
		toolName = "Drill_T6",
		toolKind = "Drill",
		tierKey = "T6",
		displayName = "Ground Pounder",
		cashCost = 50000,
		shopPrice = nil,
		purchasable = true,
		sortOrder = 4.3,
		drillTimeDivisor = 1000,
		drillFallbackSeconds = 10,
		--- Manual subtitle (overrides `formatDrillStatsLine`). Calls out
		--- both T6's re-drill capability AND its rarity bias (Option 3:
		--- half dud rate + ×1.5 to Epic+) so the $50k price tag /
		--- ~20% in-stock rate read as premium even before purchase.
		--- Edit freely; set to nil to fall back to
		--- "1000 meters/sec • 0.01 sec/tile" (loses the bias callout).
		shopSubtitle = "1000 m/s • 0.01 sec/tile • RE-DRILLS AND BETTER ODDS!",
		rarity = "MYTHIC",
		iconAssetId = "rbxassetid://135865747560987",
		canRedrill = true,
		--- Option 3 from chat 2026-04 "T6 reroll bias": halve dud rate,
		--- bump Epic+ rarities ×1.5. Bias applies on every T6 placement
		--- (first drill OR reroll), not just rerolls — makes T6's $50k
		--- price + scarce stock rotation feel premium even on a fresh tile.
		--- Future Robux drills can override these multipliers (e.g. set
		--- `Unlucky = 0` to never dig dry, or larger Mythic boost).
		rerollWeightBias = {
			Unlucky = 0.5,
			Epic = 1.5,
			Exotic = 1.5,
			Legendary = 1.5,
			Ascendant = 1.5,
			Transcendent = 1.5,
			Mythic = 1.5,
		},
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
	--- Optional 0..1 gate rolled **before** the min/max band each refresh.
	--- If `rng:NextNumber() > appearChance`, this item is skipped entirely
	--- this rotation (stock = 0) — the band is never sampled. Use for
	--- "rare even when it shows up" items where the min/max range alone
	--- can't push the in-stock probability below 50% (a `[0,1]` band is
	--- a flat coin flip and lowering `max` to 0 means never). Omit / nil
	--- for items that should always roll the band normally.
	appearChance: number?,
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
---   * T1/T2/T3 are cheap consumables ($50/$500/$1500) — bands sized so a
---     solo player buying everything they can afford never empties the rack
---     mid-window, and full lobbies see ~5-6 drills per player per rotation.
---   * T4 ($5k) is a real cash sink; rack caps stay low so wallet, not
---     stock, is the bottleneck.
---   * T5/T6 stay aspirational. T5 still ≤1 in small lobbies (flat 50%
---     per refresh on `[0,1]`). T6 layers an `appearChance = 0.20` gate
---     on top of the band so it only shows up ~20% of refreshes (~once
---     every 15 min on the 3-min cycle) instead of 50% — preserves the
---     "wow it's actually here" mythic moment instead of normalizing it.
--- Multiplier applied to the **rolled** stock count in `rollShopStock`
--- (NOT to the displayed cap from `computeShopStockMax`). Lets us keep
--- the "what could the rack hold" number visible in the UI ("of N")
--- while the actual rolled stock ("X of N") trends a bit lower so the
--- shop usually has some empty slots — feels less "everything's always
--- in stock" without lowering the design ceiling.
---
--- Applied with `math.ceil` so single-slot items (T5/T6 `[0,1]`) aren't
--- accidentally zeroed out (`ceil(1 * 0.8) = 1`), while bigger bands
--- (T1 `[5,8]` solo) shed a slot or two off the top
--- (`ceil(8 * 0.8) = 7`). `CoreFloor` still applies AFTER scaling so
--- onboarding essentials (drill_t1 = 3, drill_t2 = 1) stay guaranteed.
---
--- Set to `1.0` (or omit / nil) to disable the scaling and roll the
--- band as-is. Lower values (e.g. 0.6) shed more slots on average.
local ROLL_FILL_RATIO = 0.8

local ShopRotation = {
	RefreshIntervalSeconds = 180, -- 3 min
	RollFillRatio = ROLL_FILL_RATIO,
	Bands = {
		drill_t1   = { min = 5,  max = 8,  perPlayer = 1.25 } :: ShopStockBand,
		drill_t2   = { min = 3,  max = 5,  perPlayer = 1.0  } :: ShopStockBand,
		drill_t3   = { min = 2,  max = 3,  perPlayer = 0.5  } :: ShopStockBand,
		drill_t4   = { min = 1,  max = 2,  perPlayer = 0.35 } :: ShopStockBand,
		drill_t5   = { min = 0,  max = 1,  perPlayer = 0.20 } :: ShopStockBand,
		drill_t6   = { min = 0,  max = 1,  perPlayer = 0.10, appearChance = 0.20 } :: ShopStockBand,
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
	local fillRatio = math.clamp(tonumber(ShopRotation.RollFillRatio) or 1, 0, 1)
	local out: { [string]: number } = {}
	for id, band in pairs(ShopRotation.Bands) do
		-- `appearChance` is rolled BEFORE the band and BEFORE `CoreFloor`,
		-- so an item with `appearChance = 0.20` skips this rotation 80% of
		-- the time even if `CoreFloor` would otherwise force ≥1. Intent:
		-- "this item is rare even when it shows up at all" (e.g. mythic
		-- chase drill). Guarded by `floor > 0` check below so designers
		-- don't accidentally combine `appearChance` with a guaranteed
		-- `CoreFloor` and get confusing behavior.
		local appearChance = tonumber(band.appearChance)
		if appearChance ~= nil and appearChance < 1 then
			if appearChance <= 0 or rng:NextNumber() > appearChance then
				out[id] = 0
				continue
			end
		end
		local extra = math.floor((tonumber(band.perPlayer) or 0) * pop)
		local lo = math.max(0, math.floor(band.min) + extra)
		local hi = math.max(lo, math.floor(band.max) + extra)
		local raw = rng:NextInteger(lo, hi)
		-- `RollFillRatio` shaves a bit off the rolled count without
		-- touching `computeShopStockMax`, so the UI's "of N" cap stays
		-- the same while "X / N" trends lower (rack usually has empty
		-- slots). `math.ceil` keeps single-slot bands like T5/T6
		-- (`[0,1]` → `ceil(0..1 * 0.8) = 0..1`) untouched. `CoreFloor`
		-- below still guarantees onboarding minimums after scaling.
		local n = if fillRatio < 1 then math.ceil(raw * fillRatio) else raw
		local floor = ShopRotation.CoreFloor[id]
		if typeof(floor) == "number" and floor > n then
			n = floor
		end
		out[id] = n
	end
	return out
end

--- Per-rotation **maximum** stock cap (the `hi` used when `rollShopStock` rolls
--- this rotation). Mirrors the formula in `rollShopStock` but without the RNG,
--- so the UI can show "X / hi" with the same `hi` the server actually rolled
--- against. Without this, the shop label uses the raw `band.max` (e.g. `8`)
--- while a full lobby's actual cap may be much higher (e.g. `8 + floor(1.25*4)
--- = 13`), which makes the rack legitimately refresh to "13 / 8" — looks like
--- a bug to the player. Same `playerCount` policy as `_rollShopStock`: sampled
--- once per rotation, **not** updated on join/leave mid-window. Items not in
--- `Bands` are omitted (callers treat "missing" as unlimited).
function EquipmentCatalog.computeShopStockMax(playerCount: number?): { [string]: number }
	local pop = math.max(1, math.floor(tonumber(playerCount) or 1))
	local out: { [string]: number } = {}
	for id, band in pairs(ShopRotation.Bands) do
		local extra = math.floor((tonumber(band.perPlayer) or 0) * pop)
		local lo = math.max(0, math.floor(band.min) + extra)
		local hi = math.max(lo, math.floor(band.max) + extra)
		local floor = ShopRotation.CoreFloor[id]
		if typeof(floor) == "number" and floor > hi then
			hi = floor
		end
		out[id] = hi
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
--- `canRedrill` and `rerollWeightBias` are surfaced here so the drill server
--- can branch on tile-already-drilled placement (T4+) and apply the per-rarity
--- weight bias at vein roll time (T6) without re-reading `EquipmentCatalog`.
function EquipmentCatalog.getDrillTiersMap(): {
	[string]: {
		cost: number,
		timeDivisor: number,
		fallbackSeconds: number,
		templateName: string,
		displayName: string,
		canRedrill: boolean?,
		rerollWeightBias: { [string]: number }?,
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
				canRedrill = r.canRedrill,
				rerollWeightBias = r.rerollWeightBias,
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
