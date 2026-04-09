--!strict

export type QualityTier = "HeavyCrude" | "StandardCrude" | "LightSweet" | "PremiumRefined"

local QualityConfig = {
	TierOrder = { "PremiumRefined", "LightSweet", "StandardCrude", "HeavyCrude" } :: { QualityTier },
	Tiers = {
		HeavyCrude = {
			displayName = "Heavy Crude",
			basePricePerBarrel = 8,
			productionWeight = 45,
		},
		StandardCrude = {
			displayName = "Standard Crude",
			basePricePerBarrel = 10,
			productionWeight = 35,
		},
		LightSweet = {
			displayName = "Light Sweet",
			basePricePerBarrel = 14,
			productionWeight = 15,
		},
		PremiumRefined = {
			displayName = "Premium Refined",
			basePricePerBarrel = 20,
			productionWeight = 5,
		},
	},
}

return QualityConfig
