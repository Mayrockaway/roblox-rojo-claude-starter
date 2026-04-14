--!strict

export type QualityTier = "HeavyCrude" | "LightSweet" | "PremiumRefined"

local Tiers = {
	HeavyCrude = {
		displayName = "Heavy Crude",
		--- Compact HUD copy (manifest strip, cargo rows).
		hudShortName = "Crude",
		basePricePerBarrel = 8,
		productionWeight = 80,
	},
	LightSweet = {
		displayName = "Light Sweet",
		hudShortName = "Light",
		basePricePerBarrel = 14,
		productionWeight = 15,
	},
	PremiumRefined = {
		displayName = "Premium Refined",
		hudShortName = "Premium",
		basePricePerBarrel = 20,
		productionWeight = 5,
	},
} :: {
	[QualityTier]: {
		displayName: string,
		hudShortName: string,
		basePricePerBarrel: number,
		productionWeight: number,
	},
}

local QualityConfig = {
	TierOrder = { "PremiumRefined", "LightSweet", "HeavyCrude" } :: { QualityTier },
	Tiers = Tiers,
}

function QualityConfig.hudShortLabel(tier: string): string
	local t = Tiers[tier :: QualityTier]
	if t then
		return t.hudShortName
	end
	return tier
end

return QualityConfig
