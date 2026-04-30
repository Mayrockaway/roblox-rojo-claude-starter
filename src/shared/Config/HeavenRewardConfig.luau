--!strict

export type HeavenRewardCategory = "ShipSpeed" | "GoldEarnPct" | "WarehouseCapacity" | "LuckPct"
export type HeavenRewardRarity = "Common" | "Rare" | "Epic" | "Legendary" | "Mythic"

export type HeavenRewardDef = {
	rewardId: string,
	category: HeavenRewardCategory,
	rarity: HeavenRewardRarity,
	rebirthRequired: number,
	amount: number,
	title: string,
	displayText: string,
}

local HeavenRewardConfig = {}

HeavenRewardConfig.DoubleRewardMonetizationItemId = "consumable.heaven_reward_x2"
HeavenRewardConfig.DoubleRewardRobuxPrice = 100

HeavenRewardConfig.RebirthRequiredOrder = { 1, 3, 5, 7, 9 }
HeavenRewardConfig.RarityOrder = { "Common", "Rare", "Epic", "Legendary", "Mythic" }
HeavenRewardConfig.CategoryOrder = { "ShipSpeed", "GoldEarnPct", "WarehouseCapacity", "LuckPct" }

HeavenRewardConfig.RarityWeights = {
	Common = 45,
	Rare = 27,
	Epic = 15,
	Legendary = 9,
	Mythic = 4,
}

HeavenRewardConfig.CategoryDisplayNames = {
	ShipSpeed = "Ship Speed",
	GoldEarnPct = "Earnings",
	WarehouseCapacity = "Warehouse Capacity",
	LuckPct = "Luck",
}

HeavenRewardConfig.ValuesByRebirthRequired = {
	[1] = {
		Common = {
			ShipSpeed = 1.5,
			GoldEarnPct = 1.5,
			WarehouseCapacity = 4,
			LuckPct = 1,
		},
		Rare = {
			ShipSpeed = 2.5,
			GoldEarnPct = 2.5,
			WarehouseCapacity = 8,
			LuckPct = 2,
		},
		Epic = {
			ShipSpeed = 3.5,
			GoldEarnPct = 3.5,
			WarehouseCapacity = 12,
			LuckPct = 3,
		},
		Legendary = {
			ShipSpeed = 4.5,
			GoldEarnPct = 4.5,
			WarehouseCapacity = 16,
			LuckPct = 4,
		},
		Mythic = {
			ShipSpeed = 6,
			GoldEarnPct = 6,
			WarehouseCapacity = 20,
			LuckPct = 5,
		},
	},
	[3] = {
		Common = {
			ShipSpeed = 2.5,
			GoldEarnPct = 2.5,
			WarehouseCapacity = 6,
			LuckPct = 2,
		},
		Rare = {
			ShipSpeed = 4,
			GoldEarnPct = 4,
			WarehouseCapacity = 12,
			LuckPct = 3,
		},
		Epic = {
			ShipSpeed = 5.5,
			GoldEarnPct = 5.5,
			WarehouseCapacity = 18,
			LuckPct = 4,
		},
		Legendary = {
			ShipSpeed = 7,
			GoldEarnPct = 7,
			WarehouseCapacity = 24,
			LuckPct = 6,
		},
		Mythic = {
			ShipSpeed = 8.5,
			GoldEarnPct = 8.5,
			WarehouseCapacity = 30,
			LuckPct = 8,
		},
	},
	[5] = {
		Common = {
			ShipSpeed = 5,
			GoldEarnPct = 5,
			WarehouseCapacity = 12,
			LuckPct = 3,
		},
		Rare = {
			ShipSpeed = 7,
			GoldEarnPct = 7,
			WarehouseCapacity = 16,
			LuckPct = 4,
		},
		Epic = {
			ShipSpeed = 9,
			GoldEarnPct = 9,
			WarehouseCapacity = 20,
			LuckPct = 5,
		},
		Legendary = {
			ShipSpeed = 11,
			GoldEarnPct = 11,
			WarehouseCapacity = 24,
			LuckPct = 6,
		},
		Mythic = {
			ShipSpeed = 13,
			GoldEarnPct = 13,
			WarehouseCapacity = 28,
			LuckPct = 7,
		},
	},
	[7] = {
		Common = {
			ShipSpeed = 8,
			GoldEarnPct = 8,
			WarehouseCapacity = 16,
			LuckPct = 4,
		},
		Rare = {
			ShipSpeed = 10,
			GoldEarnPct = 10,
			WarehouseCapacity = 20,
			LuckPct = 5,
		},
		Epic = {
			ShipSpeed = 12,
			GoldEarnPct = 12,
			WarehouseCapacity = 24,
			LuckPct = 6,
		},
		Legendary = {
			ShipSpeed = 14,
			GoldEarnPct = 14,
			WarehouseCapacity = 28,
			LuckPct = 7,
		},
		Mythic = {
			ShipSpeed = 16,
			GoldEarnPct = 16,
			WarehouseCapacity = 32,
			LuckPct = 8,
		},
	},
	[9] = {
		Common = {
			ShipSpeed = 16,
			GoldEarnPct = 16,
			WarehouseCapacity = 24,
			LuckPct = 6,
		},
		Rare = {
			ShipSpeed = 20,
			GoldEarnPct = 20,
			WarehouseCapacity = 32,
			LuckPct = 8,
		},
		Epic = {
			ShipSpeed = 24,
			GoldEarnPct = 24,
			WarehouseCapacity = 40,
			LuckPct = 10,
		},
		Legendary = {
			ShipSpeed = 28,
			GoldEarnPct = 28,
			WarehouseCapacity = 48,
			LuckPct = 12,
		},
		Mythic = {
			ShipSpeed = 34,
			GoldEarnPct = 34,
			WarehouseCapacity = 56,
			LuckPct = 14,
		},
	},
}

HeavenRewardConfig.RarityVisualTiers = {
	Common = "T1",
	Rare = "T2",
	Epic = "T3",
	Legendary = "T4",
	Mythic = "T4",
}

HeavenRewardConfig.RewardIconAssetsByTier = {
	ShipSpeed = {
		T1 = "rbxassetid://119717103629357",
		T2 = "rbxassetid://135568213721750",
		T3 = "rbxassetid://124640997598427",
		T4 = "rbxassetid://115859729981654",
	},
	GoldEarnPct = {
		T1 = "rbxassetid://100640600433175",
		T2 = "rbxassetid://71884317646135",
		T3 = "rbxassetid://100730296903156",
		T4 = "rbxassetid://115108794669856",
	},
	WarehouseCapacity = {
		T1 = "rbxassetid://71184712958695",
		T2 = "rbxassetid://100941671504461",
		T3 = "rbxassetid://132821476641824",
		T4 = "rbxassetid://104929671077636",
	},
	LuckPct = {
		T1 = "rbxassetid://107929651207318",
		T2 = "rbxassetid://140000557710081",
		T3 = "rbxassetid://108671456896974",
		T4 = "rbxassetid://109740908338323",
	},
}

local function normalizeRebirthRequired(rebirthRequired: number?): number
	if typeof(rebirthRequired) == "number" and HeavenRewardConfig.ValuesByRebirthRequired[rebirthRequired] ~= nil then
		return rebirthRequired
	end
	return 1
end

local function formatAmount(amount: number): string
	local whole = math.round(amount)
	if math.abs(amount - whole) < 0.001 then
		return tostring(whole)
	end
	return string.format("%.1f", amount)
end

local function displayTextFor(category: HeavenRewardCategory, amount: number): string
	local amountText = formatAmount(amount)
	if category == "ShipSpeed" then
		return string.format("+%s%% Ship Speed", amountText)
	end
	if category == "GoldEarnPct" then
		return string.format("+%s%% Earnings", amountText)
	end
	if category == "WarehouseCapacity" then
		return string.format("+%s%% Warehouse Capacity", amountText)
	end
	return string.format("+%s%% Luck", amountText)
end

local function rewardIdFor(category: HeavenRewardCategory, rarity: HeavenRewardRarity, rebirthRequired: number): string
	return string.format("R%d_%s_%s", rebirthRequired, rarity, category)
end

function HeavenRewardConfig.GetVisualTierForRarity(rarity: HeavenRewardRarity): string
	return HeavenRewardConfig.RarityVisualTiers[rarity] or "T1"
end

function HeavenRewardConfig.GetRewardIconAsset(category: HeavenRewardCategory, rarity: HeavenRewardRarity): string?
	local tier = HeavenRewardConfig.GetVisualTierForRarity(rarity)
	local assetsByTier = HeavenRewardConfig.RewardIconAssetsByTier[category]
	return assetsByTier and assetsByTier[tier] or nil
end

function HeavenRewardConfig.BuildReward(category: HeavenRewardCategory, rarity: HeavenRewardRarity, rebirthRequired: number?): HeavenRewardDef
	local resolvedRebirthRequired = normalizeRebirthRequired(rebirthRequired)
	local amount = HeavenRewardConfig.ValuesByRebirthRequired[resolvedRebirthRequired][rarity][category]
	return {
		rewardId = rewardIdFor(category, rarity, resolvedRebirthRequired),
		category = category,
		rarity = rarity,
		rebirthRequired = resolvedRebirthRequired,
		amount = amount,
		title = HeavenRewardConfig.CategoryDisplayNames[category],
		displayText = displayTextFor(category, amount),
	}
end

function HeavenRewardConfig.GetAllRewards(): { HeavenRewardDef }
	local out = {}
	for _, rebirthRequired in ipairs(HeavenRewardConfig.RebirthRequiredOrder) do
		for _, rarity in ipairs(HeavenRewardConfig.RarityOrder) do
			for _, category in ipairs(HeavenRewardConfig.CategoryOrder) do
				table.insert(out, HeavenRewardConfig.BuildReward(category, rarity, rebirthRequired))
			end
		end
	end
	return out
end

function HeavenRewardConfig.RollReward(rng: Random, rebirthRequired: number?): HeavenRewardDef
	local totalWeight = 0
	for _, rarity in ipairs(HeavenRewardConfig.RarityOrder) do
		totalWeight += HeavenRewardConfig.RarityWeights[rarity] or 0
	end
	local roll = rng:NextNumber() * totalWeight
	local accum = 0
	local chosenRarity: HeavenRewardRarity = "Common"
	for _, rarity in ipairs(HeavenRewardConfig.RarityOrder) do
		accum += HeavenRewardConfig.RarityWeights[rarity] or 0
		if roll <= accum then
			chosenRarity = rarity
			break
		end
	end
	local categoryIndex = rng:NextInteger(1, #HeavenRewardConfig.CategoryOrder)
	local category = HeavenRewardConfig.CategoryOrder[categoryIndex]
	return HeavenRewardConfig.BuildReward(category, chosenRarity, rebirthRequired)
end

return HeavenRewardConfig
