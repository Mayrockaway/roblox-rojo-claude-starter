--!strict

export type QualityTier = "Crude" | "Refined" | "Premium"

--- Per-tier square barrel icon. Authored as the source of truth for **every**
--- runtime-cloned tier surface (e.g. `ActiveManifestController` `LossChip.TierIcon`).
--- Studio-authored placeholders (Sell / Ship cargo rows, manifest LoadedRow tier icons)
--- are painted from these same ids — keep both in sync if a future tier swaps art.
local Tiers = {
	Crude = {
		displayName = "Crude",
		--- Compact HUD copy (manifest strip, cargo rows).
		hudShortName = "Crude",
		basePricePerBarrel = 6,
		productionWeight = 80,
		iconAssetId = "rbxassetid://102169788803948",
	},
	Refined = {
		displayName = "Refined",
		hudShortName = "Refined",
		basePricePerBarrel = 15,
		productionWeight = 15,
		iconAssetId = "rbxassetid://131963438621981",
	},
	Premium = {
		displayName = "Premium",
		hudShortName = "Premium",
		basePricePerBarrel = 35,
		productionWeight = 5,
		iconAssetId = "rbxassetid://127818508063880",
	},
} :: {
	[QualityTier]: {
		displayName: string,
		hudShortName: string,
		basePricePerBarrel: number,
		productionWeight: number,
		iconAssetId: string,
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

--- Per-tier square barrel icon asset id (`""` if `tier` is unknown — caller may keep current image).
function QualityConfig.iconAssetIdForTier(tier: string): string
	local t = Tiers[tier :: QualityTier]
	if t then
		return t.iconAssetId
	end
	return ""
end

return QualityConfig
