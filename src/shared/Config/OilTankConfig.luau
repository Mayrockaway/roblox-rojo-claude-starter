--!strict
-- Per-plot OilTanks: three tier-tubes (Tier1/Tier2/Tier3) mapped to oil types
-- HeavyCrude/LightSweet/PremiumRefined. Each tank upgrades independently 1..10.
-- Capacity + cost grow exponentially. Shell Y-height scales linearly with tier.

local OilTankConfig = {
	MaxTier = 10,

	Tiers = {
		{ tier = 1,  capacity = 25,    cost = 0 },
		{ tier = 2,  capacity = 60,    cost = 400 },
		{ tier = 3,  capacity = 150,   cost = 1200 },
		{ tier = 4,  capacity = 350,   cost = 3500 },
		{ tier = 5,  capacity = 800,   cost = 10000 },
		{ tier = 6,  capacity = 1800,  cost = 28000 },
		{ tier = 7,  capacity = 4000,  cost = 75000 },
		{ tier = 8,  capacity = 9000,  cost = 200000 },
		{ tier = 9,  capacity = 20000, cost = 500000 },
		{ tier = 10, capacity = 50000, cost = 1500000 },
	},

	-- Shell Union Y-size at tier 1 (authored baseline) and tier 10 (max); linear interp between.
	ShellHeightMin = 17.77,
	ShellHeightMax = 60,

	-- Tube Model name → oil type it stores
	TubeToOilType = {
		Tier1Tube = "HeavyCrude",
		Tier2Tube = "LightSweet",
		Tier3Tube = "PremiumRefined",
	},

	-- Reverse map (oil type → tube name) for lookups
	OilTypeToTube = {
		HeavyCrude = "Tier1Tube",
		LightSweet = "Tier2Tube",
		PremiumRefined = "Tier3Tube",
	},

	-- Liquid Part color per oil type
	OilColors = {
		HeavyCrude = Color3.fromRGB(30, 30, 30),       -- black
		LightSweet = Color3.fromRGB(240, 200, 70),      -- yellow (matches pipe color)
		PremiumRefined = Color3.fromRGB(180, 80, 255),   -- pink/purple (matches pipe color)
	},
}

local TIER_ORDER = { "HeavyCrude", "LightSweet", "PremiumRefined" }

function OilTankConfig.GetTier(tier: number)
	for _, t in ipairs(OilTankConfig.Tiers) do
		if t.tier == tier then
			return t
		end
	end
	return OilTankConfig.Tiers[1]
end

function OilTankConfig.GetCapacity(tier: number): number
	local t = OilTankConfig.GetTier(tier)
	return t and t.capacity or 25
end

function OilTankConfig.GetUpgradeCost(tier: number): number?
	local next = OilTankConfig.GetTier(tier + 1)
	return next and next.cost or nil
end

function OilTankConfig.GetShellHeight(tier: number): number
	local t = math.clamp(tier, 1, OilTankConfig.MaxTier)
	local alpha = (t - 1) / (OilTankConfig.MaxTier - 1)
	return OilTankConfig.ShellHeightMin + (OilTankConfig.ShellHeightMax - OilTankConfig.ShellHeightMin) * alpha
end

function OilTankConfig.ClampTier(tier: any): number
	local n = tonumber(tier) or 1
	return math.clamp(math.floor(n), 1, OilTankConfig.MaxTier)
end

function OilTankConfig.TierOrder(): { string }
	return TIER_ORDER
end

return OilTankConfig
