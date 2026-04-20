--!strict

export type QualityTier = "Crude" | "Refined" | "Premium"

local Tiers = {
	Crude = {
		displayName = "Crude",
		--- Compact HUD copy (manifest strip, cargo rows).
		hudShortName = "Crude",
		basePricePerBarrel = 6,
		productionWeight = 80,
	},
	Refined = {
		displayName = "Refined",
		hudShortName = "Refined",
		basePricePerBarrel = 15,
		productionWeight = 15,
	},
	Premium = {
		displayName = "Premium",
		hudShortName = "Premium",
		basePricePerBarrel = 35,
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
	TierOrder = { "Premium", "Refined", "Crude" } :: { QualityTier },
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
