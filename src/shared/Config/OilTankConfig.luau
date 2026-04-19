--!strict
-- Per-plot OilTanks: three tier-tubes mapped to oil types.

local OilTankConfig = {
	MaxTier = 10,

	Tiers = {
		{ tier = 1,  capacity = 25,    cost = 0 },
		{ tier = 2,  capacity = 50,    cost = 250 },
		{ tier = 3,  capacity = 100,   cost = 800 },
		{ tier = 4,  capacity = 225,   cost = 2500 },
		{ tier = 5,  capacity = 500,   cost = 7500 },
		{ tier = 6,  capacity = 1100,  cost = 22000 },
		{ tier = 7,  capacity = 2400,  cost = 65000 },
		{ tier = 8,  capacity = 5000,  cost = 180000 },
		{ tier = 9,  capacity = 11000, cost = 500000 },
		{ tier = 10, capacity = 24000, cost = 1400000 },
	},

	ShellHeightMin = 17.77,
	ShellHeightMax = 60,

	TubeToOilType = {
		Tier1Tube = "HeavyCrude",
		Tier2Tube = "LightSweet",
		Tier3Tube = "PremiumRefined",
	},

	OilTypeToTube = {
		HeavyCrude = "Tier1Tube",
		LightSweet = "Tier2Tube",
		PremiumRefined = "Tier3Tube",
	},

	OilColors = {
		HeavyCrude = Color3.fromRGB(30, 30, 30),
		LightSweet = Color3.fromRGB(240, 200, 70),
		PremiumRefined = Color3.fromRGB(180, 80, 255),
	},
}

local TIER_ORDER = { "HeavyCrude", "LightSweet", "PremiumRefined" }

function OilTankConfig.GetTier(tier: number)
	for _, def in ipairs(OilTankConfig.Tiers) do
		if def.tier == tier then
			return def
		end
	end
	return OilTankConfig.Tiers[1]
end

function OilTankConfig.GetCapacity(tier: number): number
	local def = OilTankConfig.GetTier(tier)
	return def and def.capacity or 25
end

function OilTankConfig.GetUpgradeCost(tier: number): number?
	local nextDef = OilTankConfig.GetTier(tier + 1)
	return nextDef and nextDef.cost or nil
end

function OilTankConfig.GetShellHeight(tier: number): number
	local clamped = math.clamp(tier, 1, OilTankConfig.MaxTier)
	local alpha = (clamped - 1) / (OilTankConfig.MaxTier - 1)
	return OilTankConfig.ShellHeightMin + (OilTankConfig.ShellHeightMax - OilTankConfig.ShellHeightMin) * alpha
end

function OilTankConfig.ClampTier(tier: any): number
	local value = tonumber(tier) or 1
	return math.clamp(math.floor(value), 1, OilTankConfig.MaxTier)
end

function OilTankConfig.TierOrder(): { string }
	return TIER_ORDER
end

return OilTankConfig
