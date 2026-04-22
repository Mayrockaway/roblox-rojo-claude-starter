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
		CrudeTube = "Crude",
		RefinedTube = "Refined",
		PremiumTube = "Premium",
	},

	OilTypeToTube = {
		Crude = "CrudeTube",
		Refined = "RefinedTube",
		Premium = "PremiumTube",
	},

	--- Liquid fill colors for the per-plot OilTanks (the `liquid` BasePart
	--- inside each tube). `OilVisualService:_syncOilTanks` reads this table
	--- every frame, so updating it here is sufficient for live tanks.
	---
	--- These colors are kept in sync with the authored barrel assets in
	--- `ReplicatedStorage.Assets.Barrel_<Tier>` and the L-Shaped pipe
	--- segments inside `OilTanksTemplate.<Tier>Tube` so that barrel → pipe
	--- → tank fluid reads as a single coherent palette per oil tier.
	OilColors = {
		Crude = Color3.fromRGB(30, 30, 30),
		Refined = Color3.fromRGB(0, 255, 0),
		Premium = Color3.fromRGB(170, 0, 170),
	},
}

local TIER_ORDER = { "Crude", "Refined", "Premium" }

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
