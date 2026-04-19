--!strict
-- VeinCrateConfig: registry of all vein types that can appear in the crate opener.
-- User supplies: id, displayName, imageId, rarity, barrelsPerSecond, oilType, streamType, weights per ground type.

local VeinCrateConfig = {}

-- ═══════════════════════════════════════════════════════════
-- Rarity tiers + colors
-- ═══════════════════════════════════════════════════════════

VeinCrateConfig.RarityColors = {
	Common      = Color3.fromRGB(128, 128, 128),
	Uncommon    = Color3.fromRGB(0, 204, 0),
	Rare        = Color3.fromRGB(51, 102, 255),
	Epic        = Color3.fromRGB(170, 0, 255),
	Mythic      = Color3.fromRGB(255, 68, 204),
	Legendary   = Color3.fromRGB(255, 170, 0),
	Secret      = Color3.fromRGB(255, 0, 0),
}

VeinCrateConfig.RarityOrder = { "Common", "Uncommon", "Rare", "Epic", "Mythic", "Legendary", "Secret" }

-- ═══════════════════════════════════════════════════════════
-- Vein type definitions
-- ═══════════════════════════════════════════════════════════

export type VeinTypeDef = {
	id: string,
	displayName: string,
	imageId: string,
	rarity: string,
	barrelsPerSecond: number,
	oilType: string,         -- internal: HeavyCrude, LightSweet, PremiumRefined
	streamType: string,      -- Dribble, Stream, Burst, Geyser
	shiny: boolean?,         -- optional "Shiny" label
	-- Weights per ground type (0 = can't appear in that ground)
	weights: {
		Bronze: number,
		Silver: number,
		Gold: number,
		Diamond: number,
	},
}

-- PLACEHOLDER vein types — user will replace these with real data + asset IDs
VeinCrateConfig.VeinTypes = {
	{
		id = "rusty_dribble",
		displayName = "Rusty Dribble",
		imageId = "rbxassetid://0", -- placeholder
		rarity = "Common",
		barrelsPerSecond = 1,
		oilType = "HeavyCrude",
		streamType = "Dribble",
		weights = { Bronze = 100, Silver = 60, Gold = 20, Diamond = 5 },
	},
	{
		id = "steady_stream",
		displayName = "Steady Stream",
		imageId = "rbxassetid://0",
		rarity = "Common",
		barrelsPerSecond = 3,
		oilType = "HeavyCrude",
		streamType = "Stream",
		weights = { Bronze = 80, Silver = 80, Gold = 40, Diamond = 20 },
	},
	{
		id = "golden_stream",
		displayName = "Golden Stream",
		imageId = "rbxassetid://0",
		rarity = "Uncommon",
		barrelsPerSecond = 5,
		oilType = "LightSweet",
		streamType = "Stream",
		weights = { Bronze = 20, Silver = 60, Gold = 80, Diamond = 60 },
	},
	{
		id = "dirty_burst",
		displayName = "Dirty Burst",
		imageId = "rbxassetid://0",
		rarity = "Uncommon",
		barrelsPerSecond = 8,
		oilType = "HeavyCrude",
		streamType = "Burst",
		weights = { Bronze = 15, Silver = 40, Gold = 50, Diamond = 30 },
	},
	{
		id = "golden_burst",
		displayName = "Golden Burst",
		imageId = "rbxassetid://0",
		rarity = "Rare",
		barrelsPerSecond = 12,
		oilType = "LightSweet",
		streamType = "Burst",
		weights = { Bronze = 5, Silver = 20, Gold = 60, Diamond = 50 },
	},
	{
		id = "premium_stream",
		displayName = "Premium Stream",
		imageId = "rbxassetid://0",
		rarity = "Rare",
		barrelsPerSecond = 10,
		oilType = "PremiumRefined",
		streamType = "Stream",
		weights = { Bronze = 0, Silver = 5, Gold = 30, Diamond = 60 },
	},
	{
		id = "crude_geyser",
		displayName = "Crude Geyser",
		imageId = "rbxassetid://0",
		rarity = "Epic",
		barrelsPerSecond = 20,
		oilType = "HeavyCrude",
		streamType = "Geyser",
		weights = { Bronze = 2, Silver = 8, Gold = 15, Diamond = 20 },
	},
	{
		id = "golden_geyser",
		displayName = "Golden Geyser",
		imageId = "rbxassetid://0",
		rarity = "Mythic",
		barrelsPerSecond = 35,
		oilType = "LightSweet",
		streamType = "Geyser",
		weights = { Bronze = 0, Silver = 2, Gold = 8, Diamond = 15 },
	},
	{
		id = "premium_burst",
		displayName = "Premium Burst",
		imageId = "rbxassetid://0",
		rarity = "Mythic",
		barrelsPerSecond = 30,
		oilType = "PremiumRefined",
		streamType = "Burst",
		weights = { Bronze = 0, Silver = 1, Gold = 10, Diamond = 30 },
	},
	{
		id = "premium_geyser",
		displayName = "Premium Geyser",
		imageId = "rbxassetid://0",
		rarity = "Legendary",
		barrelsPerSecond = 60,
		oilType = "PremiumRefined",
		streamType = "Geyser",
		weights = { Bronze = 0, Silver = 0, Gold = 2, Diamond = 10 },
	},
	{
		id = "rainbow_geyser",
		displayName = "Rainbow Geyser",
		imageId = "rbxassetid://0",
		rarity = "Secret",
		barrelsPerSecond = 100,
		oilType = "PremiumRefined",
		streamType = "Geyser",
		shiny = true,
		weights = { Bronze = 0, Silver = 0, Gold = 0, Diamond = 1 },
	},
	{
		id = "dry_hole",
		displayName = "Dry Hole",
		imageId = "rbxassetid://0",
		rarity = "Common",
		barrelsPerSecond = 0,
		oilType = "HeavyCrude",
		streamType = "Dribble",
		weights = { Bronze = 30, Silver = 20, Gold = 10, Diamond = 5 },
	},
}

-- ═══════════════════════════════════════════════════════════
-- Lookup helpers
-- ═══════════════════════════════════════════════════════════

local byId: { [string]: VeinTypeDef } = {}
for _, vt in ipairs(VeinCrateConfig.VeinTypes) do
	byId[vt.id] = vt
end

function VeinCrateConfig.GetById(id: string): VeinTypeDef?
	return byId[id]
end

function VeinCrateConfig.GetAllForGround(groundType: string): { VeinTypeDef }
	local result = {}
	for _, vt in ipairs(VeinCrateConfig.VeinTypes) do
		local w = (vt.weights :: any)[groundType]
		if typeof(w) == "number" and w > 0 then
			table.insert(result, vt)
		end
	end
	return result
end

function VeinCrateConfig.RollVeinType(groundType: string, rng: Random): VeinTypeDef
	local pool = VeinCrateConfig.GetAllForGround(groundType)
	if #pool == 0 then
		return VeinCrateConfig.VeinTypes[1] -- fallback
	end

	local totalWeight = 0
	for _, vt in ipairs(pool) do
		totalWeight += (vt.weights :: any)[groundType] or 0
	end

	local roll = rng:NextNumber() * totalWeight
	local accum = 0
	for _, vt in ipairs(pool) do
		accum += (vt.weights :: any)[groundType] or 0
		if roll <= accum then
			return vt
		end
	end

	return pool[#pool]
end

function VeinCrateConfig.GetRarityColor(rarity: string): Color3
	return VeinCrateConfig.RarityColors[rarity] or Color3.fromRGB(128, 128, 128)
end

-- Rebuild lookup when types are modified
function VeinCrateConfig._rebuildLookup()
	byId = {}
	for _, vt in ipairs(VeinCrateConfig.VeinTypes) do
		byId[vt.id] = vt
	end
end

return VeinCrateConfig
