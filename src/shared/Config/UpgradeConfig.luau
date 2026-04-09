--!strict

export type UpgradeId =
	"PumpRate"
	| "StorageCapacity"
	| "TankerDurability"
	| "EscortBonus"
	| "QualityBias"

local UpgradeConfig = {
	DefaultLevels = {
		PumpRate = 0,
		StorageCapacity = 0,
		TankerDurability = 0,
		EscortBonus = 0,
		QualityBias = 0,
	},
	Definitions = {
		PumpRate = {
			displayName = "Pump Rate",
			maxLevel = 200,
			baseCost = 100,
			costGrowth = 1.14,
			effectPerLevel = 0.015,
		},
		StorageCapacity = {
			displayName = "Storage Capacity",
			maxLevel = 200,
			baseCost = 120,
			costGrowth = 1.13,
			effectPerLevel = 8,
		},
		TankerDurability = {
			displayName = "Tanker Durability",
			maxLevel = 100,
			baseCost = 200,
			costGrowth = 1.16,
			effectPerLevel = 0.02,
		},
		EscortBonus = {
			displayName = "Escort Bonus",
			maxLevel = 100,
			baseCost = 260,
			costGrowth = 1.17,
			effectPerLevel = 0.02,
		},
		QualityBias = {
			displayName = "Quality Bias",
			maxLevel = 100,
			baseCost = 280,
			costGrowth = 1.18,
			effectPerLevel = 0.01,
		},
	},
}

return UpgradeConfig
