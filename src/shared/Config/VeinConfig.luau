--!strict
-- VeinConfig: ground types, odds tables, stream/oil/vein definitions,
-- rarity colors, nomenclature helpers, combined odds calculator.

local VeinConfig = {}

-- ═══════════════════════════════════════════════════════════
-- Ground Types (by plot row)
-- ═══════════════════════════════════════════════════════════

export type GroundTypeDef = {
	name: string,
	row: number,
	color: Color3,
	material: Enum.Material,
	drillSeconds: number,
	streamWeights: { [string]: number },
	oilWeights: { [string]: number },
	veinWeights: { [string]: number },
}

VeinConfig.GroundTypes = {
	Bronze = {
		name = "Bronze",
		row = 1,
		color = Color3.fromRGB(205, 175, 125),
		material = Enum.Material.Sand,
		drillSeconds = 30,
		streamWeights = { Dribble = 50, Stream = 40, Burst = 9, Geyser = 1 },
		oilWeights = { DirtOil = 95, GoodOil = 5, GoldOil = 0 },
		veinWeights = { Single = 95, Double = 5, Triple = 1 },
	},
	Silver = {
		name = "Silver",
		row = 2,
		color = Color3.fromRGB(192, 192, 192),
		material = Enum.Material.Sand,
		drillSeconds = 1800, -- 30 min
		streamWeights = { Dribble = 30, Stream = 59, Burst = 10, Geyser = 1 },
		oilWeights = { DirtOil = 80, GoodOil = 19, GoldOil = 1 },
		veinWeights = { Single = 80, Double = 19, Triple = 1 },
	},
	Gold = {
		name = "Gold",
		row = 3,
		color = Color3.fromRGB(255, 215, 0),
		material = Enum.Material.Sand,
		drillSeconds = 10800, -- 3 hrs
		streamWeights = { Dribble = 20, Stream = 50, Burst = 25, Geyser = 5 },
		oilWeights = { DirtOil = 35, GoodOil = 60, GoldOil = 5 },
		veinWeights = { Single = 70, Double = 25, Triple = 5 },
	},
	Diamond = {
		name = "Diamond",
		row = 4,
		color = Color3.fromRGB(185, 240, 255),
		material = Enum.Material.Sand,
		drillSeconds = 86400, -- 1 day
		streamWeights = { Dribble = 10, Stream = 40, Burst = 40, Geyser = 10 },
		oilWeights = { DirtOil = 0, GoodOil = 80, GoldOil = 20 },
		veinWeights = { Single = 60, Double = 30, Triple = 10 },
	},
} :: { [string]: GroundTypeDef }

-- Row → ground type lookup
-- Visual layout (top=far, bottom=near spawn):
-- DDD (row 1, furthest from spawn)
-- GGG (row 2)
-- SSS (row 3)
-- BBB (row 4, closest to spawn, has starter pump in middle)
VeinConfig.GroundByRow = {
	[1] = VeinConfig.GroundTypes.Diamond,
	[2] = VeinConfig.GroundTypes.Gold,
	[3] = VeinConfig.GroundTypes.Silver,
	[4] = VeinConfig.GroundTypes.Bronze,
}

-- ═══════════════════════════════════════════════════════════
-- Center Pump Upgrade Config
-- ═══════════════════════════════════════════════════════════

VeinConfig.PumpUpgrades = {
	T1 = { flowMult = 1, templateName = "Pump_T1", displayName = "Basic Pump" },
	T2 = { flowMult = 2, templateName = "Pump_T2", displayName = "Standard Pump" },
	T3 = { flowMult = 4, templateName = "Pump_T3", displayName = "Advanced Pump" },
}

VeinConfig.PumpUpgradeOrder = { "T1", "T2", "T3" }

-- Base upgrade costs (for Bronze / row closest to spawn)
-- Scale by row: Bronze=1x, Silver=3x, Gold=10x, Diamond=30x
VeinConfig.PumpUpgradeCosts = {
	T2 = 5000,
	T3 = 10000,
}

VeinConfig.RowCostMultiplier = {
	Bronze = 1,
	Silver = 3,
	Gold = 10,
	Diamond = 30,
}

function VeinConfig.GetUpgradeCost(currentTier: string, groundType: string): (string?, number?)
	local currentIdx = 0
	for i, t in ipairs(VeinConfig.PumpUpgradeOrder) do
		if t == currentTier then currentIdx = i break end
	end
	local nextTier = VeinConfig.PumpUpgradeOrder[currentIdx + 1]
	if not nextTier then return nil, nil end -- already max

	local baseCost = VeinConfig.PumpUpgradeCosts[nextTier] or 0
	local mult = VeinConfig.RowCostMultiplier[groundType] or 1
	return nextTier, math.floor(baseCost * mult)
end

-- ═══════════════════════════════════════════════════════════
-- Stream Types
-- ═══════════════════════════════════════════════════════════

export type StreamDef = {
	name: string,
	productionMult: number,
	particleMult: number,
	color: Color3,
	bold: boolean,
	shaking: boolean,
}

VeinConfig.Streams = {
	Dead = { name = "Dead", productionMult = 0, particleMult = 0, color = Color3.fromRGB(150, 150, 150), bold = false, shaking = false },
	Dribble = { name = "Dribble", productionMult = 1, particleMult = 0.4, color = Color3.fromRGB(255, 255, 255), bold = false, shaking = false },
	Stream = { name = "Stream", productionMult = 1.5, particleMult = 1, color = Color3.fromRGB(80, 220, 80), bold = false, shaking = false },
	Burst = { name = "Burst", productionMult = 2, particleMult = 2, color = Color3.fromRGB(50, 150, 255), bold = true, shaking = false },
	Geyser = { name = "Geyser", productionMult = 3, particleMult = 4, color = Color3.fromRGB(255, 170, 60), bold = true, shaking = true },
} :: { [string]: StreamDef }

VeinConfig.StreamOrder = { "Dribble", "Stream", "Burst", "Geyser" }

-- ═══════════════════════════════════════════════════════════
-- Oil Types (renamed)
-- ═══════════════════════════════════════════════════════════

export type OilTypeDef = {
	name: string,
	displayName: string,
	internalName: string, -- maps to old HeavyCrude/LightSweet/PremiumRefined
	color: Color3,
	valueMult: number,
}

VeinConfig.OilTypes = {
	DirtOil = { name = "DirtOil", displayName = "Dirt Oil", internalName = "HeavyCrude", color = Color3.fromRGB(200, 200, 200), valueMult = 1 },
	GoodOil = { name = "GoodOil", displayName = "Good Oil", internalName = "LightSweet", color = Color3.fromRGB(240, 200, 70), valueMult = 2 },
	GoldOil = { name = "GoldOil", displayName = "Gold Oil", internalName = "PremiumRefined", color = Color3.fromRGB(255, 150, 200), valueMult = 4 },
} :: { [string]: OilTypeDef }

VeinConfig.OilOrder = { "DirtOil", "GoodOil", "GoldOil" }

-- ═══════════════════════════════════════════════════════════
-- Vein Counts
-- ═══════════════════════════════════════════════════════════

export type VeinCountDef = {
	name: string,
	displayName: string,
	count: number,
	color: Color3,
	bold: boolean,
	shaking: boolean,
}

VeinConfig.VeinCounts = {
	Single = { name = "Single", displayName = "Single Vein", count = 1, color = Color3.fromRGB(255, 255, 255), bold = false, shaking = false },
	Double = { name = "Double", displayName = "Double Vein", count = 2, color = Color3.fromRGB(180, 80, 255), bold = true, shaking = false },
	Triple = { name = "Triple", displayName = "Triple Vein", count = 3, color = Color3.fromRGB(255, 170, 60), bold = true, shaking = true },
} :: { [string]: VeinCountDef }

-- ═══════════════════════════════════════════════════════════
-- Dead chance (no oil at all)
-- ═══════════════════════════════════════════════════════════

VeinConfig.DEAD_CHANCE = 0.15

-- ═══════════════════════════════════════════════════════════
-- Rolling
-- ═══════════════════════════════════════════════════════════

export type SingleVeinResult = {
	streamType: string,
	oilType: string,
}

export type VeinRollResult = {
	isDead: boolean,
	veinCount: string, -- "Single" | "Double" | "Triple"
	veins: { SingleVeinResult }, -- 1, 2, or 3 entries
	groundType: string,
}

local function weightedPick(weights: { [string]: number }, rng: Random): string
	local total = 0
	for _, w in pairs(weights) do
		total += w
	end
	if total <= 0 then
		-- Fallback: pick first key
		for k in pairs(weights) do return k end
	end
	local roll = rng:NextNumber() * total
	local accum = 0
	for key, w in pairs(weights) do
		accum += w
		if roll <= accum then
			return key
		end
	end
	-- Fallback
	for k in pairs(weights) do return k end
	return "Dribble"
end

function VeinConfig.RollVein(groundType: GroundTypeDef, rng: Random): VeinRollResult
	-- 15% chance of dead
	if rng:NextNumber() < VeinConfig.DEAD_CHANCE then
		return {
			isDead = true,
			veinCount = "Single",
			veins = {{ streamType = "Dead", oilType = "DirtOil" }},
			groundType = groundType.name,
		}
	end

	local veinCount = weightedPick(groundType.veinWeights, rng)
	local count = VeinConfig.VeinCounts[veinCount].count

	local veins: { SingleVeinResult } = {}
	for _ = 1, count do
		local stream = weightedPick(groundType.streamWeights, rng)
		local oil = weightedPick(groundType.oilWeights, rng)
		table.insert(veins, { streamType = stream, oilType = oil })
	end

	return {
		isDead = false,
		veinCount = veinCount,
		veins = veins,
		groundType = groundType.name,
	}
end

-- ═══════════════════════════════════════════════════════════
-- Nomenclature
-- ═══════════════════════════════════════════════════════════

function VeinConfig.BuildDisplayName(result: VeinRollResult): string
	if result.isDead then
		return "Dead — No Oil"
	end

	local parts = {}
	for _, vein in ipairs(result.veins) do
		local oilDef = VeinConfig.OilTypes[vein.oilType]
		local streamDef = VeinConfig.Streams[vein.streamType]
		table.insert(parts, (oilDef and oilDef.displayName or vein.oilType) .. " " .. (streamDef and streamDef.name or vein.streamType))
	end

	if result.veinCount == "Triple" then
		if #parts == 3 then
			return "OMG TRIPLE VEIN! " .. parts[1] .. ", " .. parts[2] .. ", and " .. parts[3]
		end
	elseif result.veinCount == "Double" then
		if #parts == 2 then
			return "DOUBLE VEIN! " .. parts[1] .. " and " .. parts[2]
		end
	end

	return parts[1] or "Unknown"
end

-- ═══════════════════════════════════════════════════════════
-- Combined Odds Calculator
-- ═══════════════════════════════════════════════════════════

function VeinConfig.CalculateCombinedOdds(result: VeinRollResult): number
	if result.isDead then
		return VeinConfig.DEAD_CHANCE
	end

	local ground = VeinConfig.GroundTypes[result.groundType]
	if not ground then return 0 end

	-- Probability of NOT being dead
	local prob = 1 - VeinConfig.DEAD_CHANCE

	-- Vein count probability
	local veinTotal = 0
	for _, w in pairs(ground.veinWeights) do veinTotal += w end
	prob *= (ground.veinWeights[result.veinCount] or 0) / math.max(1, veinTotal)

	-- Each vein's stream + oil probability
	local streamTotal = 0
	for _, w in pairs(ground.streamWeights) do streamTotal += w end
	local oilTotal = 0
	for _, w in pairs(ground.oilWeights) do oilTotal += w end

	for _, vein in ipairs(result.veins) do
		prob *= (ground.streamWeights[vein.streamType] or 0) / math.max(1, streamTotal)
		prob *= (ground.oilWeights[vein.oilType] or 0) / math.max(1, oilTotal)
	end

	return prob
end

function VeinConfig.FormatOdds(prob: number): string
	if prob <= 0 then return "???" end
	local inverse = math.floor(1 / prob + 0.5)
	if inverse <= 1 then return "1/1" end
	return "1/" .. tostring(inverse)
end

-- ═══════════════════════════════════════════════════════════
-- Rarity tier from combined probability
-- ═══════════════════════════════════════════════════════════

export type RarityTier = {
	name: string,
	color: Color3,
}

function VeinConfig.GetRarityFromOdds(prob: number): RarityTier
	local inverse = if prob > 0 then 1 / prob else 999999
	if inverse >= 10000 then
		return { name = "LEGENDARY", color = Color3.fromRGB(255, 170, 60) }
	elseif inverse >= 1000 then
		return { name = "EPIC", color = Color3.fromRGB(180, 80, 255) }
	elseif inverse >= 100 then
		return { name = "RARE", color = Color3.fromRGB(50, 150, 255) }
	elseif inverse >= 10 then
		return { name = "UNCOMMON", color = Color3.fromRGB(80, 220, 80) }
	else
		return { name = "COMMON", color = Color3.fromRGB(255, 255, 255) }
	end
end

-- ═══════════════════════════════════════════════════════════
-- Map new oil type names to old internal names for compatibility
-- ═══════════════════════════════════════════════════════════

function VeinConfig.GetInternalOilName(oilType: string): string
	local def = VeinConfig.OilTypes[oilType]
	return def and def.internalName or "HeavyCrude"
end

-- Total production multiplier for a vein result (sum of all veins' stream mults)
function VeinConfig.GetTotalProductionMult(result: VeinRollResult): number
	if result.isDead then return 0 end
	local total = 0
	for _, vein in ipairs(result.veins) do
		local streamDef = VeinConfig.Streams[vein.streamType]
		total += streamDef and streamDef.productionMult or 0
	end
	return total
end

return VeinConfig
