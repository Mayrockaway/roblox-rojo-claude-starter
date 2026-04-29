--!strict

export type HeavenRewardCategory = "ShipSpeed" | "GoldEarnPct" | "WarehouseCapacity" | "LuckPct"
export type HeavenRewardRarity = "Common" | "Rare" | "Epic" | "Legendary" | "Mythic"

export type HeavenRewardDef = {
	rewardId: string,
	category: HeavenRewardCategory,
	rarity: HeavenRewardRarity,
	amount: number,
	title: string,
	displayText: string,
}

local HeavenRewardConfig = {}

HeavenRewardConfig.DoubleRewardMonetizationItemId = "consumable.heaven_reward_x2"
HeavenRewardConfig.DoubleRewardRobuxPrice = 100

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
	GoldEarnPct = "Gold Earn",
	WarehouseCapacity = "Warehouse",
	LuckPct = "Luck",
}

HeavenRewardConfig.ValuesByRarity = {
	Common = {
		ShipSpeed = 2,
		GoldEarnPct = 5,
		WarehouseCapacity = 10,
		LuckPct = 2,
	},
	Rare = {
		ShipSpeed = 4,
		GoldEarnPct = 10,
		WarehouseCapacity = 20,
		LuckPct = 4,
	},
	Epic = {
		ShipSpeed = 6,
		GoldEarnPct = 15,
		WarehouseCapacity = 30,
		LuckPct = 6,
	},
	Legendary = {
		ShipSpeed = 8,
		GoldEarnPct = 20,
		WarehouseCapacity = 40,
		LuckPct = 8,
	},
	Mythic = {
		ShipSpeed = 10,
		GoldEarnPct = 25,
		WarehouseCapacity = 50,
		LuckPct = 10,
	},
}

local function displayTextFor(category: HeavenRewardCategory, amount: number): string
	if category == "WarehouseCapacity" then
		return string.format("+%d Warehouse", amount)
	end
	if category == "ShipSpeed" then
		return string.format("+%d%% Ship Speed", amount)
	end
	if category == "GoldEarnPct" then
		return string.format("+%d%% Gold Earn", amount)
	end
	return string.format("+%d%% Luck", amount)
end

local function rewardIdFor(category: HeavenRewardCategory, rarity: HeavenRewardRarity, amount: number): string
	return string.format("%s_%s_%d", rarity, category, amount)
end

function HeavenRewardConfig.BuildReward(category: HeavenRewardCategory, rarity: HeavenRewardRarity): HeavenRewardDef
	local amount = HeavenRewardConfig.ValuesByRarity[rarity][category]
	return {
		rewardId = rewardIdFor(category, rarity, amount),
		category = category,
		rarity = rarity,
		amount = amount,
		title = HeavenRewardConfig.CategoryDisplayNames[category],
		displayText = displayTextFor(category, amount),
	}
end

function HeavenRewardConfig.GetAllRewards(): { HeavenRewardDef }
	local out = {}
	for _, rarity in ipairs(HeavenRewardConfig.RarityOrder) do
		for _, category in ipairs(HeavenRewardConfig.CategoryOrder) do
			table.insert(out, HeavenRewardConfig.BuildReward(category, rarity))
		end
	end
	return out
end

function HeavenRewardConfig.RollReward(rng: Random): HeavenRewardDef
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
	return HeavenRewardConfig.BuildReward(category, chosenRarity)
end

return HeavenRewardConfig
