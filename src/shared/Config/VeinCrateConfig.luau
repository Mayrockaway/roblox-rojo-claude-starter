--!strict
-- Generated from lootbox-1 (3).json and rebalance rules.

local VeinCrateConfig = {}

export type StreamSignature = {
	burstType: string,
	oilType: string,
	internalOilType: string,
	barrelsPerSecond: number,
}

export type VeinTypeDef = {
	id: string,
	displayName: string,
	imageId: string,
	iconAssetId: string?,
	iconKey: string,
	rarity: string,
	sourceRarity: string,
	streamCount: number,
	barrelsPerSecond: number,
	primaryInternalOilType: string,
	isUnlucky: boolean,
	streams: { StreamSignature },
}

VeinCrateConfig.RarityOrder = { "Unlucky", "Common", "Uncommon", "Special", "Rare", "Epic", "Exotic", "Legendary", "Ascendant", "Transcendent", "Top Secret", "Mythic" }

VeinCrateConfig.RarityStyles = {
	["Unlucky"] = { effect = "solid", bgStart = Color3.fromHex("#5f4b40"), bgEnd = Color3.fromHex("#1d1511"), glow = Color3.fromHex("#aa7d66"), text = Color3.fromHex("#f1d3b2"), spark = Color3.fromHex("#ffffff") },
	["Common"] = { effect = "solid", bgStart = Color3.fromHex("#8d939c"), bgEnd = Color3.fromHex("#434952"), glow = Color3.fromHex("#d7dde6"), text = Color3.fromHex("#eef2f7"), spark = Color3.fromHex("#ffffff") },
	["Uncommon"] = { effect = "solid", bgStart = Color3.fromHex("#27cb00"), bgEnd = Color3.fromHex("#136100"), glow = Color3.fromHex("#8bff72"), text = Color3.fromHex("#38ff3f"), spark = Color3.fromHex("#dfffd5") },
	["Special"] = { effect = "solid", bgStart = Color3.fromHex("#00c2a0"), bgEnd = Color3.fromHex("#0a5a5d"), glow = Color3.fromHex("#9ff9ee"), text = Color3.fromHex("#84fff0"), spark = Color3.fromHex("#e8fffb") },
	["Rare"] = { effect = "solid", bgStart = Color3.fromHex("#21c0da"), bgEnd = Color3.fromHex("#0c4f8f"), glow = Color3.fromHex("#82ebff"), text = Color3.fromHex("#84efff"), spark = Color3.fromHex("#d8fcff") },
	["Epic"] = { effect = "solid", bgStart = Color3.fromHex("#a100ff"), bgEnd = Color3.fromHex("#4c0073"), glow = Color3.fromHex("#ff83ff"), text = Color3.fromHex("#ff6cff"), spark = Color3.fromHex("#ffd8ff") },
	["Exotic"] = { effect = "solid", bgStart = Color3.fromHex("#ff3b7d"), bgEnd = Color3.fromHex("#7f1137"), glow = Color3.fromHex("#ffb1ce"), text = Color3.fromHex("#ff7fb1"), spark = Color3.fromHex("#ffe5f0") },
	["Legendary"] = { effect = "solid", bgStart = Color3.fromHex("#ff8b1a"), bgEnd = Color3.fromHex("#8a2a00"), glow = Color3.fromHex("#ffd66b"), text = Color3.fromHex("#ffcf57"), spark = Color3.fromHex("#fff0b6") },
	["Ascendant"] = { effect = "solid", bgStart = Color3.fromHex("#ffd66b"), bgEnd = Color3.fromHex("#9b6200"), glow = Color3.fromHex("#fff1bd"), text = Color3.fromHex("#ffe08d"), spark = Color3.fromHex("#fff9dd") },
	["Transcendent"] = { effect = "solid", bgStart = Color3.fromHex("#fff6de"), bgEnd = Color3.fromHex("#8d97a8"), glow = Color3.fromHex("#fff2b8"), text = Color3.fromHex("#fff6cf"), spark = Color3.fromHex("#ffffff") },
	["Top Secret"] = { effect = "solid", bgStart = Color3.fromHex("#ff2948"), bgEnd = Color3.fromHex("#6f0015"), glow = Color3.fromHex("#ff9bb3"), text = Color3.fromHex("#ff4665"), spark = Color3.fromHex("#ffe1e8") },
	["Mythic"] = { effect = "rainbow", bgStart = Color3.fromHex("#d500ff"), bgEnd = Color3.fromHex("#56007d"), glow = Color3.fromHex("#ff97ff"), text = Color3.fromHex("#ff43ff"), spark = Color3.fromHex("#ffe0ff") },
}

-- Rarity background images (uploaded separately from item icons)
-- Fill these in after uploading the 12 rarity background PNGs
VeinCrateConfig.RarityBackgroundAssets = {
	["Unlucky"] = "rbxassetid://125711380562616",
	["Common"] = "rbxassetid://70504909706756",
	["Uncommon"] = "rbxassetid://128117062570098",
	["Special"] = "rbxassetid://71832305588658",
	["Rare"] = "rbxassetid://93979855515567",
	["Epic"] = "rbxassetid://137994779619345",
	["Exotic"] = "rbxassetid://87748476286830",
	["Legendary"] = "rbxassetid://109246262572681",
	["Ascendant"] = "rbxassetid://83317067223520",
	["Transcendent"] = "rbxassetid://76598028650114",
	["Top Secret"] = "rbxassetid://124329147322417",
	["Mythic"] = "rbxassetid://120812474907419",
}

VeinCrateConfig.GroundRarityWeights = {
	Bronze = { Unlucky = 2000, Common = 4500, Uncommon = 2500, Special = 1500, Rare = 800, Epic = 500, Legendary = 200 },
	Silver = { Unlucky = 1500, Common = 3500, Uncommon = 2500, Special = 2000, Rare = 1500, Exotic = 250, Legendary = 150 },
	Gold = { Unlucky = 400, Common = 600, Uncommon = 1000, Special = 2200, Rare = 2200, Epic = 1800, Exotic = 1000, Legendary = 500, Ascendant = 250, Transcendent = 30 },
	Diamond = { Unlucky = 200, Common = 200, Uncommon = 300, Special = 500, Rare = 800, Epic = 1400, Exotic = 1800, Legendary = 1800, Ascendant = 1400, Mythic = 300 },
}

-- Per-ground rarity assignments: same item can have different rarity per ground.
-- Rarity reflects value WITHIN that ground's context.
VeinCrateConfig.GroundItemRarities = {
	Bronze = {
		["item-45"] = "Unlucky",
		["item-1"] = "Common", ["item-5"] = "Common",
		["item-3"] = "Uncommon", ["item-14"] = "Uncommon",
		["item-17"] = "Special", ["item-6"] = "Special",
		["item-8"] = "Rare", ["item-18"] = "Rare",
		["item-24"] = "Epic", ["item-27"] = "Epic",
		["item-11"] = "Legendary",
	},
	Silver = {
		["item-45"] = "Unlucky",
		["item-1"] = "Common", ["item-5"] = "Common", ["item-14"] = "Common",
		["item-3"] = "Uncommon", ["item-17"] = "Uncommon", ["item-6"] = "Uncommon", ["item-4"] = "Uncommon", ["item-15"] = "Uncommon",
		["item-8"] = "Special", ["item-18"] = "Special", ["item-24"] = "Special",
		["item-27"] = "Rare", ["item-9"] = "Rare", ["item-11"] = "Rare",
		["item-43"] = "Exotic",
		["item-12"] = "Legendary",
	},
	Gold = {
		["item-45"] = "Unlucky",
		["item-1"] = "Common", ["item-5"] = "Common",
		["item-14"] = "Uncommon", ["item-3"] = "Uncommon", ["item-17"] = "Uncommon",
		["item-6"] = "Special", ["item-8"] = "Special", ["item-18"] = "Special", ["item-24"] = "Special", ["item-4"] = "Special", ["item-15"] = "Special",
		["item-27"] = "Rare", ["item-9"] = "Rare", ["item-11"] = "Rare", ["item-16"] = "Rare", ["item-23"] = "Rare", ["item-30"] = "Rare",
		["item-22"] = "Epic", ["item-28"] = "Epic", ["item-7"] = "Epic", ["item-31"] = "Epic", ["item-43"] = "Epic", ["item-12"] = "Epic",
		["item-21"] = "Exotic", ["item-19"] = "Exotic", ["item-25"] = "Exotic", ["item-40"] = "Exotic", ["item-26"] = "Exotic", ["item-29"] = "Exotic",
		["item-41"] = "Legendary", ["item-32"] = "Legendary", ["item-34"] = "Legendary",
		["item-38"] = "Ascendant", ["item-35"] = "Ascendant", ["item-36"] = "Ascendant",
		["item-10"] = "Transcendent",
	},
	Diamond = {
		["item-45"] = "Unlucky",
		["item-1"] = "Common", ["item-5"] = "Common", ["item-14"] = "Common",
		["item-3"] = "Uncommon", ["item-17"] = "Uncommon", ["item-6"] = "Uncommon", ["item-8"] = "Uncommon",
		["item-18"] = "Special", ["item-24"] = "Special", ["item-27"] = "Special", ["item-4"] = "Special", ["item-15"] = "Special", ["item-9"] = "Special",
		["item-11"] = "Rare", ["item-16"] = "Rare", ["item-23"] = "Rare", ["item-30"] = "Rare", ["item-22"] = "Rare", ["item-28"] = "Rare", ["item-31"] = "Rare", ["item-7"] = "Rare",
		["item-21"] = "Epic", ["item-19"] = "Epic", ["item-25"] = "Epic", ["item-40"] = "Epic", ["item-26"] = "Epic", ["item-29"] = "Epic", ["item-43"] = "Epic",
		["item-41"] = "Exotic", ["item-32"] = "Exotic", ["item-34"] = "Exotic", ["item-38"] = "Exotic", ["item-35"] = "Exotic", ["item-36"] = "Exotic", ["item-12"] = "Exotic",
		["item-10"] = "Legendary", ["item-33"] = "Legendary", ["item-39"] = "Legendary",
		["item-42"] = "Ascendant", ["item-37"] = "Ascendant", ["item-44"] = "Ascendant",
		["item-13"] = "Mythic",
	},
}

VeinCrateConfig.VeinTypes = {
	{
		id = "item-1",
		displayName = "Grease Spill",
		imageId = "rbxassetid://0",
		iconAssetId = "rbxassetid://124721839529953",
		iconKey = "master:36",
		rarity = "Common",
		sourceRarity = "Uncommon",
		streamCount = 1,
		barrelsPerSecond = 0.004,
		primaryInternalOilType = "Crude",
		isUnlucky = false,
		streams = { { burstType = "Dribble", oilType = "DirtOil", internalOilType = "Crude", barrelsPerSecond = 0.004 } },
	},
	{
		id = "item-3",
		displayName = "Clean Leak",
		imageId = "rbxassetid://0",
		iconAssetId = "rbxassetid://98228910286161",
		iconKey = "master:9",
		rarity = "Common",
		sourceRarity = "Uncommon",
		streamCount = 1,
		barrelsPerSecond = 0.004,
		primaryInternalOilType = "Refined",
		isUnlucky = false,
		streams = { { burstType = "Dribble", oilType = "GoodOil", internalOilType = "Refined", barrelsPerSecond = 0.004 } },
	},
	{
		id = "item-5",
		displayName = "Grease Cache",
		imageId = "rbxassetid://0",
		iconAssetId = "rbxassetid://89824287926850",
		iconKey = "master:1",
		rarity = "Common",
		sourceRarity = "Uncommon",
		streamCount = 1,
		barrelsPerSecond = 0.012,
		primaryInternalOilType = "Crude",
		isUnlucky = false,
		streams = { { burstType = "Stream", oilType = "DirtOil", internalOilType = "Crude", barrelsPerSecond = 0.012 } },
	},
	{
		id = "item-6",
		displayName = "Clean Cache",
		imageId = "rbxassetid://0",
		iconAssetId = "rbxassetid://127812997157826",
		iconKey = "master:4",
		rarity = "Common",
		sourceRarity = "Rare",
		streamCount = 1,
		barrelsPerSecond = 0.012,
		primaryInternalOilType = "Refined",
		isUnlucky = false,
		streams = { { burstType = "Stream", oilType = "GoodOil", internalOilType = "Refined", barrelsPerSecond = 0.012 } },
	},
	{
		id = "item-4",
		displayName = "Prime Leak",
		imageId = "rbxassetid://0",
		iconAssetId = "rbxassetid://112699026641726",
		iconKey = "master:15",
		rarity = "Uncommon",
		sourceRarity = "Epic",
		streamCount = 1,
		barrelsPerSecond = 0.004,
		primaryInternalOilType = "Premium",
		isUnlucky = false,
		streams = { { burstType = "Dribble", oilType = "GoldOil", internalOilType = "Premium", barrelsPerSecond = 0.004 } },
	},
	{
		id = "item-14",
		displayName = "Double Clean Chaos Leak",
		imageId = "rbxassetid://0",
		iconAssetId = "rbxassetid://99943780547281",
		iconKey = "master:28",
		rarity = "Uncommon",
		sourceRarity = "Uncommon",
		streamCount = 2,
		barrelsPerSecond = 0.01,
		primaryInternalOilType = "Refined",
		isUnlucky = false,
		streams = { { burstType = "Dribble", oilType = "DirtOil", internalOilType = "Crude", barrelsPerSecond = 0.004 }, { burstType = "Dribble", oilType = "GoodOil", internalOilType = "Refined", barrelsPerSecond = 0.004 } },
	},
	{
		id = "item-7",
		displayName = "Prime Cache",
		imageId = "rbxassetid://0",
		iconAssetId = "rbxassetid://130663826781792",
		iconKey = "master:8",
		rarity = "Uncommon",
		sourceRarity = "Epic",
		streamCount = 1,
		barrelsPerSecond = 0.012,
		primaryInternalOilType = "Premium",
		isUnlucky = false,
		streams = { { burstType = "Stream", oilType = "GoldOil", internalOilType = "Premium", barrelsPerSecond = 0.012 } },
	},
	{
		id = "item-18",
		displayName = "Double Clean Janky Cache",
		imageId = "rbxassetid://0",
		iconAssetId = "rbxassetid://128033242558215",
		iconKey = "master:23",
		rarity = "Uncommon",
		sourceRarity = "Uncommon",
		streamCount = 2,
		barrelsPerSecond = 0.0175,
		primaryInternalOilType = "Refined",
		isUnlucky = false,
		streams = { { burstType = "Dribble", oilType = "DirtOil", internalOilType = "Crude", barrelsPerSecond = 0.004 }, { burstType = "Stream", oilType = "GoodOil", internalOilType = "Refined", barrelsPerSecond = 0.012 } },
	},
	{
		id = "item-17",
		displayName = "Double Grease Jackpot Cache",
		imageId = "rbxassetid://0",
		iconAssetId = "rbxassetid://101446140143273",
		iconKey = "master:24",
		rarity = "Uncommon",
		sourceRarity = "Uncommon",
		streamCount = 2,
		barrelsPerSecond = 0.0175,
		primaryInternalOilType = "Refined",
		isUnlucky = false,
		streams = { { burstType = "Dribble", oilType = "GoodOil", internalOilType = "Refined", barrelsPerSecond = 0.004 }, { burstType = "Stream", oilType = "DirtOil", internalOilType = "Crude", barrelsPerSecond = 0.012 } },
	},
	{
		id = "item-15",
		displayName = "Double Prime Bonanza Leak",
		imageId = "rbxassetid://0",
		iconAssetId = "rbxassetid://121894011305126",
		iconKey = "master:29",
		rarity = "Special",
		sourceRarity = "Epic",
		streamCount = 2,
		barrelsPerSecond = 0.01,
		primaryInternalOilType = "Premium",
		isUnlucky = false,
		streams = { { burstType = "Dribble", oilType = "DirtOil", internalOilType = "Crude", barrelsPerSecond = 0.004 }, { burstType = "Dribble", oilType = "GoldOil", internalOilType = "Premium", barrelsPerSecond = 0.004 } },
	},
	{
		id = "item-8",
		displayName = "Grease Strike",
		imageId = "rbxassetid://0",
		iconAssetId = "rbxassetid://122980079468085",
		iconKey = "master:2",
		rarity = "Special",
		sourceRarity = "Rare",
		streamCount = 1,
		barrelsPerSecond = 0.032,
		primaryInternalOilType = "Crude",
		isUnlucky = false,
		streams = { { burstType = "Burst", oilType = "DirtOil", internalOilType = "Crude", barrelsPerSecond = 0.032 } },
	},
	{
		id = "item-16",
		displayName = "Double Prime Gremlin Leak",
		imageId = "rbxassetid://0",
		iconAssetId = "rbxassetid://103613143332837",
		iconKey = "master:30",
		rarity = "Special",
		sourceRarity = "Epic",
		streamCount = 2,
		barrelsPerSecond = 0.01,
		primaryInternalOilType = "Premium",
		isUnlucky = false,
		streams = { { burstType = "Dribble", oilType = "GoodOil", internalOilType = "Refined", barrelsPerSecond = 0.004 }, { burstType = "Dribble", oilType = "GoldOil", internalOilType = "Premium", barrelsPerSecond = 0.004 } },
	},
	{
		id = "item-24",
		displayName = "Double Clean Gremlin Cache",
		imageId = "rbxassetid://0",
		iconAssetId = "rbxassetid://120644789202378",
		iconKey = "master:7",
		rarity = "Special",
		sourceRarity = "Special",
		streamCount = 2,
		barrelsPerSecond = 0.025,
		primaryInternalOilType = "Refined",
		isUnlucky = false,
		streams = { { burstType = "Stream", oilType = "DirtOil", internalOilType = "Crude", barrelsPerSecond = 0.012 }, { burstType = "Stream", oilType = "GoodOil", internalOilType = "Refined", barrelsPerSecond = 0.012 } },
	},
	{
		id = "item-9",
		displayName = "Clean Strike",
		imageId = "rbxassetid://0",
		iconAssetId = "rbxassetid://109343442254181",
		iconKey = "master:5",
		rarity = "Special",
		sourceRarity = "Epic",
		streamCount = 1,
		barrelsPerSecond = 0.032,
		primaryInternalOilType = "Refined",
		isUnlucky = false,
		streams = { { burstType = "Burst", oilType = "GoodOil", internalOilType = "Refined", barrelsPerSecond = 0.032 } },
	},
	{
		id = "item-21",
		displayName = "Double Prime Turbo Cache",
		imageId = "rbxassetid://0",
		iconAssetId = "rbxassetid://125354739045359",
		iconKey = "master:27",
		rarity = "Rare",
		sourceRarity = "Legendary",
		streamCount = 2,
		barrelsPerSecond = 0.0175,
		primaryInternalOilType = "Premium",
		isUnlucky = false,
		streams = { { burstType = "Dribble", oilType = "DirtOil", internalOilType = "Crude", barrelsPerSecond = 0.004 }, { burstType = "Stream", oilType = "GoldOil", internalOilType = "Premium", barrelsPerSecond = 0.012 } },
	},
	{
		id = "item-23",
		displayName = "Double Grease Bonanza Cache",
		imageId = "rbxassetid://0",
		iconAssetId = "rbxassetid://97681704524233",
		iconKey = "master:25",
		rarity = "Rare",
		sourceRarity = "Epic",
		streamCount = 2,
		barrelsPerSecond = 0.0175,
		primaryInternalOilType = "Premium",
		isUnlucky = false,
		streams = { { burstType = "Dribble", oilType = "GoldOil", internalOilType = "Premium", barrelsPerSecond = 0.004 }, { burstType = "Stream", oilType = "DirtOil", internalOilType = "Crude", barrelsPerSecond = 0.012 } },
	},
	{
		id = "item-22",
		displayName = "Double Clean Chaos Cache",
		imageId = "rbxassetid://0",
		iconAssetId = "rbxassetid://115153865706588",
		iconKey = "master:26",
		rarity = "Rare",
		sourceRarity = "Exotic",
		streamCount = 2,
		barrelsPerSecond = 0.0175,
		primaryInternalOilType = "Premium",
		isUnlucky = false,
		streams = { { burstType = "Dribble", oilType = "GoldOil", internalOilType = "Premium", barrelsPerSecond = 0.004 }, { burstType = "Stream", oilType = "GoodOil", internalOilType = "Refined", barrelsPerSecond = 0.012 } },
	},
	{
		id = "item-19",
		displayName = "Double Prime Lucky Cache",
		imageId = "rbxassetid://0",
		iconAssetId = "rbxassetid://103708227046473",
		iconKey = "master:22",
		rarity = "Rare",
		sourceRarity = "Legendary",
		streamCount = 2,
		barrelsPerSecond = 0.0175,
		primaryInternalOilType = "Premium",
		isUnlucky = false,
		streams = { { burstType = "Dribble", oilType = "GoodOil", internalOilType = "Refined", barrelsPerSecond = 0.004 }, { burstType = "Stream", oilType = "GoldOil", internalOilType = "Premium", barrelsPerSecond = 0.012 } },
	},
	{
		id = "item-25",
		displayName = "Double Prime Jackpot Cache",
		imageId = "rbxassetid://0",
		iconAssetId = "rbxassetid://126952724985204",
		iconKey = "master:11",
		rarity = "Rare",
		sourceRarity = "Legendary",
		streamCount = 2,
		barrelsPerSecond = 0.025,
		primaryInternalOilType = "Premium",
		isUnlucky = false,
		streams = { { burstType = "Stream", oilType = "DirtOil", internalOilType = "Crude", barrelsPerSecond = 0.012 }, { burstType = "Stream", oilType = "GoldOil", internalOilType = "Premium", barrelsPerSecond = 0.012 } },
	},
	{
		id = "item-10",
		displayName = "Prime Strike",
		imageId = "rbxassetid://0",
		iconAssetId = "rbxassetid://86899610903112",
		iconKey = "master:12",
		rarity = "Epic",
		sourceRarity = "Legendary",
		streamCount = 1,
		barrelsPerSecond = 0.032,
		primaryInternalOilType = "Premium",
		isUnlucky = false,
		streams = { { burstType = "Burst", oilType = "GoldOil", internalOilType = "Premium", barrelsPerSecond = 0.032 } },
	},
	{
		id = "item-27",
		displayName = "Double Grease Lucky Strike",
		imageId = "rbxassetid://0",
		iconAssetId = "rbxassetid://79292075217436",
		iconKey = "master:14",
		rarity = "Epic",
		sourceRarity = "Epic",
		streamCount = 2,
		barrelsPerSecond = 0.036,
		primaryInternalOilType = "Refined",
		isUnlucky = false,
		streams = { { burstType = "Dribble", oilType = "GoodOil", internalOilType = "Refined", barrelsPerSecond = 0.004 }, { burstType = "Burst", oilType = "DirtOil", internalOilType = "Crude", barrelsPerSecond = 0.032 } },
	},
	{
		id = "item-30",
		displayName = "Triple Prime Chaos Leak",
		imageId = "rbxassetid://0",
		iconAssetId = "rbxassetid://113761854200825",
		iconKey = "master:34",
		rarity = "Epic",
		sourceRarity = "Ascendant",
		streamCount = 3,
		barrelsPerSecond = 0.015,
		primaryInternalOilType = "Premium",
		isUnlucky = false,
		streams = { { burstType = "Dribble", oilType = "DirtOil", internalOilType = "Crude", barrelsPerSecond = 0.004 }, { burstType = "Dribble", oilType = "GoodOil", internalOilType = "Refined", barrelsPerSecond = 0.004 }, { burstType = "Dribble", oilType = "GoldOil", internalOilType = "Premium", barrelsPerSecond = 0.004 } },
	},
	{
		id = "item-26",
		displayName = "Double Prime Janky Cache",
		imageId = "rbxassetid://0",
		iconAssetId = "rbxassetid://100114260169228",
		iconKey = "master:10",
		rarity = "Epic",
		sourceRarity = "Ascendant",
		streamCount = 2,
		barrelsPerSecond = 0.025,
		primaryInternalOilType = "Premium",
		isUnlucky = false,
		streams = { { burstType = "Stream", oilType = "GoodOil", internalOilType = "Refined", barrelsPerSecond = 0.012 }, { burstType = "Stream", oilType = "GoldOil", internalOilType = "Premium", barrelsPerSecond = 0.012 } },
	},
	{
		id = "item-28",
		displayName = "Double Grease Hybrid Strike",
		imageId = "rbxassetid://0",
		iconAssetId = "rbxassetid://86126914003258",
		iconKey = "master:16",
		rarity = "Epic",
		sourceRarity = "Legendary",
		streamCount = 2,
		barrelsPerSecond = 0.036,
		primaryInternalOilType = "Premium",
		isUnlucky = false,
		streams = { { burstType = "Dribble", oilType = "GoldOil", internalOilType = "Premium", barrelsPerSecond = 0.004 }, { burstType = "Burst", oilType = "DirtOil", internalOilType = "Crude", barrelsPerSecond = 0.032 } },
	},
	{
		id = "item-29",
		displayName = "Double Clean Turbo Strike",
		imageId = "rbxassetid://0",
		iconAssetId = "rbxassetid://95330550396262",
		iconKey = "master:17",
		rarity = "Exotic",
		sourceRarity = "Ascendant",
		streamCount = 2,
		barrelsPerSecond = 0.036,
		primaryInternalOilType = "Premium",
		isUnlucky = false,
		streams = { { burstType = "Dribble", oilType = "GoldOil", internalOilType = "Premium", barrelsPerSecond = 0.004 }, { burstType = "Burst", oilType = "GoodOil", internalOilType = "Refined", barrelsPerSecond = 0.032 } },
	},
	{
		id = "item-34",
		displayName = "Triple Prime Janky Cache",
		imageId = "rbxassetid://0",
		iconAssetId = "rbxassetid://125087573091735",
		iconKey = "master:21",
		rarity = "Exotic",
		sourceRarity = "Ascendant",
		streamCount = 3,
		barrelsPerSecond = 0.036,
		primaryInternalOilType = "Premium",
		isUnlucky = false,
		streams = { { burstType = "Stream", oilType = "DirtOil", internalOilType = "Crude", barrelsPerSecond = 0.012 }, { burstType = "Stream", oilType = "GoodOil", internalOilType = "Refined", barrelsPerSecond = 0.012 }, { burstType = "Stream", oilType = "GoldOil", internalOilType = "Premium", barrelsPerSecond = 0.012 } },
	},
	{
		id = "item-43",
		displayName = "Triple Clean Lucky Strike",
		imageId = "rbxassetid://0",
		iconAssetId = "rbxassetid://105150567986687",
		iconKey = "master:43",
		rarity = "Exotic",
		sourceRarity = "Top Secret",
		streamCount = 3,
		barrelsPerSecond = 0.048,
		primaryInternalOilType = "Refined",
		isUnlucky = false,
		streams = { { burstType = "Dribble", oilType = "DirtOil", internalOilType = "Crude", barrelsPerSecond = 0.004 }, { burstType = "Stream", oilType = "GoodOil", internalOilType = "Refined", barrelsPerSecond = 0.012 }, { burstType = "Burst", oilType = "GoodOil", internalOilType = "Refined", barrelsPerSecond = 0.032 } },
	},
	{
		id = "item-11",
		displayName = "Grease Blowout",
		imageId = "rbxassetid://0",
		iconAssetId = "rbxassetid://77814404904603",
		iconKey = "master:3",
		rarity = "Exotic",
		sourceRarity = "Epic",
		streamCount = 1,
		barrelsPerSecond = 0.09,
		primaryInternalOilType = "Crude",
		isUnlucky = false,
		streams = { { burstType = "Geyser", oilType = "DirtOil", internalOilType = "Crude", barrelsPerSecond = 0.09 } },
	},
	{
		id = "item-33",
		displayName = "Triple Prime Jackpot Strike",
		imageId = "rbxassetid://0",
		iconAssetId = "rbxassetid://72757320863090",
		iconKey = "master:33",
		rarity = "Exotic",
		sourceRarity = "Top Secret",
		streamCount = 3,
		barrelsPerSecond = 0.04,
		primaryInternalOilType = "Premium",
		isUnlucky = false,
		streams = { { burstType = "Dribble", oilType = "DirtOil", internalOilType = "Crude", barrelsPerSecond = 0.004 }, { burstType = "Dribble", oilType = "GoodOil", internalOilType = "Refined", barrelsPerSecond = 0.004 }, { burstType = "Burst", oilType = "GoldOil", internalOilType = "Premium", barrelsPerSecond = 0.032 } },
	},
	{
		id = "item-32",
		displayName = "Triple Clean Gremlin Strike",
		imageId = "rbxassetid://0",
		iconAssetId = "rbxassetid://138991572908721",
		iconKey = "master:32",
		rarity = "Legendary",
		sourceRarity = "Transcendent",
		streamCount = 3,
		barrelsPerSecond = 0.04,
		primaryInternalOilType = "Premium",
		isUnlucky = false,
		streams = { { burstType = "Dribble", oilType = "DirtOil", internalOilType = "Crude", barrelsPerSecond = 0.004 }, { burstType = "Burst", oilType = "GoodOil", internalOilType = "Refined", barrelsPerSecond = 0.032 }, { burstType = "Dribble", oilType = "GoldOil", internalOilType = "Premium", barrelsPerSecond = 0.004 } },
	},
	{
		id = "item-31",
		displayName = "Triple Grease Bonanza Strike",
		imageId = "rbxassetid://0",
		iconAssetId = "rbxassetid://79014865416434",
		iconKey = "master:31",
		rarity = "Legendary",
		sourceRarity = "Transcendent",
		streamCount = 3,
		barrelsPerSecond = 0.04,
		primaryInternalOilType = "Premium",
		isUnlucky = false,
		streams = { { burstType = "Burst", oilType = "DirtOil", internalOilType = "Crude", barrelsPerSecond = 0.032 }, { burstType = "Dribble", oilType = "GoodOil", internalOilType = "Refined", barrelsPerSecond = 0.004 }, { burstType = "Dribble", oilType = "GoldOil", internalOilType = "Premium", barrelsPerSecond = 0.004 } },
	},
	{
		id = "item-41",
		displayName = "Triple Grease Jackpot Strike",
		imageId = "rbxassetid://0",
		iconAssetId = "rbxassetid://139806797288294",
		iconKey = "master:41",
		rarity = "Legendary",
		sourceRarity = "Top Secret",
		streamCount = 3,
		barrelsPerSecond = 0.048,
		primaryInternalOilType = "Premium",
		isUnlucky = false,
		streams = { { burstType = "Dribble", oilType = "DirtOil", internalOilType = "Crude", barrelsPerSecond = 0.004 }, { burstType = "Stream", oilType = "GoldOil", internalOilType = "Premium", barrelsPerSecond = 0.012 }, { burstType = "Burst", oilType = "DirtOil", internalOilType = "Crude", barrelsPerSecond = 0.032 } },
	},
	{
		id = "item-12",
		displayName = "Clean Blowout",
		imageId = "rbxassetid://0",
		iconAssetId = "rbxassetid://120297875552892",
		iconKey = "master:6",
		rarity = "Legendary",
		sourceRarity = "Legendary",
		streamCount = 1,
		barrelsPerSecond = 0.09,
		primaryInternalOilType = "Refined",
		isUnlucky = false,
		streams = { { burstType = "Geyser", oilType = "GoodOil", internalOilType = "Refined", barrelsPerSecond = 0.09 } },
	},
	{
		id = "item-42",
		displayName = "Triple Prime Janky Strike",
		imageId = "rbxassetid://0",
		iconAssetId = "rbxassetid://121336558078208",
		iconKey = "master:42",
		rarity = "Ascendant",
		sourceRarity = "Mythic",
		streamCount = 3,
		barrelsPerSecond = 0.048,
		primaryInternalOilType = "Premium",
		isUnlucky = false,
		streams = { { burstType = "Dribble", oilType = "DirtOil", internalOilType = "Crude", barrelsPerSecond = 0.004 }, { burstType = "Stream", oilType = "GoodOil", internalOilType = "Refined", barrelsPerSecond = 0.012 }, { burstType = "Burst", oilType = "GoldOil", internalOilType = "Premium", barrelsPerSecond = 0.032 } },
	},
	{
		id = "item-38",
		displayName = "Triple Clean Chaos Strike",
		imageId = "rbxassetid://0",
		iconAssetId = "rbxassetid://106701350526668",
		iconKey = "master:38",
		rarity = "Ascendant",
		sourceRarity = "Ascendant",
		streamCount = 3,
		barrelsPerSecond = 0.048,
		primaryInternalOilType = "Premium",
		isUnlucky = false,
		streams = { { burstType = "Dribble", oilType = "GoldOil", internalOilType = "Premium", barrelsPerSecond = 0.004 }, { burstType = "Stream", oilType = "DirtOil", internalOilType = "Crude", barrelsPerSecond = 0.012 }, { burstType = "Burst", oilType = "GoodOil", internalOilType = "Refined", barrelsPerSecond = 0.032 } },
	},
	{
		id = "item-40",
		displayName = "Triple Grease Gremlin Strike",
		imageId = "rbxassetid://0",
		iconAssetId = "rbxassetid://108025527665174",
		iconKey = "master:40",
		rarity = "Ascendant",
		sourceRarity = "Top Secret",
		streamCount = 3,
		barrelsPerSecond = 0.048,
		primaryInternalOilType = "Premium",
		isUnlucky = false,
		streams = { { burstType = "Dribble", oilType = "GoldOil", internalOilType = "Premium", barrelsPerSecond = 0.004 }, { burstType = "Stream", oilType = "GoodOil", internalOilType = "Refined", barrelsPerSecond = 0.012 }, { burstType = "Burst", oilType = "DirtOil", internalOilType = "Crude", barrelsPerSecond = 0.032 } },
	},
	{
		id = "item-39",
		displayName = "Triple Prime Bonanza Strike",
		imageId = "rbxassetid://0",
		iconAssetId = "rbxassetid://114146776843911",
		iconKey = "master:39",
		rarity = "Transcendent",
		sourceRarity = "Exotic",
		streamCount = 3,
		barrelsPerSecond = 0.048,
		primaryInternalOilType = "Premium",
		isUnlucky = false,
		streams = { { burstType = "Dribble", oilType = "GoodOil", internalOilType = "Refined", barrelsPerSecond = 0.004 }, { burstType = "Stream", oilType = "DirtOil", internalOilType = "Crude", barrelsPerSecond = 0.012 }, { burstType = "Burst", oilType = "GoldOil", internalOilType = "Premium", barrelsPerSecond = 0.032 } },
	},
	{
		id = "item-13",
		displayName = "Prime Blowout",
		imageId = "rbxassetid://0",
		iconAssetId = "rbxassetid://114387916231990",
		iconKey = "master:13",
		rarity = "Transcendent",
		sourceRarity = "Mythic",
		streamCount = 1,
		barrelsPerSecond = 0.09,
		primaryInternalOilType = "Premium",
		isUnlucky = false,
		streams = { { burstType = "Geyser", oilType = "GoldOil", internalOilType = "Premium", barrelsPerSecond = 0.09 } },
	},
	{
		id = "item-37",
		displayName = "Triple Prime Turbo Strike",
		imageId = "rbxassetid://0",
		iconAssetId = "rbxassetid://127301747668063",
		iconKey = "master:20",
		rarity = "Transcendent",
		sourceRarity = "Mythic",
		streamCount = 3,
		barrelsPerSecond = 0.068,
		primaryInternalOilType = "Premium",
		isUnlucky = false,
		streams = { { burstType = "Dribble", oilType = "DirtOil", internalOilType = "Crude", barrelsPerSecond = 0.004 }, { burstType = "Burst", oilType = "GoodOil", internalOilType = "Refined", barrelsPerSecond = 0.032 }, { burstType = "Burst", oilType = "GoldOil", internalOilType = "Premium", barrelsPerSecond = 0.032 } },
	},
	{
		id = "item-36",
		displayName = "Triple Clean Hybrid Strike",
		imageId = "rbxassetid://0",
		iconAssetId = "rbxassetid://114218511883543",
		iconKey = "master:19",
		rarity = "Top Secret",
		sourceRarity = "Transcendent",
		streamCount = 3,
		barrelsPerSecond = 0.068,
		primaryInternalOilType = "Premium",
		isUnlucky = false,
		streams = { { burstType = "Dribble", oilType = "GoldOil", internalOilType = "Premium", barrelsPerSecond = 0.004 }, { burstType = "Burst", oilType = "DirtOil", internalOilType = "Crude", barrelsPerSecond = 0.032 }, { burstType = "Burst", oilType = "GoodOil", internalOilType = "Refined", barrelsPerSecond = 0.032 } },
	},
	{
		id = "item-35",
		displayName = "Triple Clean Lucky Strike Tar",
		imageId = "rbxassetid://0",
		iconAssetId = "rbxassetid://136866762927828",
		iconKey = "master:18",
		rarity = "Top Secret",
		sourceRarity = "Transcendent",
		streamCount = 3,
		barrelsPerSecond = 0.068,
		primaryInternalOilType = "Premium",
		isUnlucky = false,
		streams = { { burstType = "Dribble", oilType = "GoldOil", internalOilType = "Premium", barrelsPerSecond = 0.004 }, { burstType = "Burst", oilType = "GoodOil", internalOilType = "Refined", barrelsPerSecond = 0.032 }, { burstType = "Burst", oilType = "DirtOil", internalOilType = "Crude", barrelsPerSecond = 0.032 } },
	},
	{
		id = "item-44",
		displayName = "Triple Prime Hybrid Strike",
		imageId = "rbxassetid://0",
		iconAssetId = "rbxassetid://71545440763291",
		iconKey = "master:44",
		rarity = "Mythic",
		sourceRarity = "Mythic",
		streamCount = 3,
		barrelsPerSecond = 0.096,
		primaryInternalOilType = "Premium",
		isUnlucky = false,
		streams = { { burstType = "Burst", oilType = "DirtOil", internalOilType = "Crude", barrelsPerSecond = 0.032 }, { burstType = "Burst", oilType = "GoodOil", internalOilType = "Refined", barrelsPerSecond = 0.032 }, { burstType = "Burst", oilType = "GoldOil", internalOilType = "Premium", barrelsPerSecond = 0.032 } },
	},
	{
		id = "item-45",
		displayName = "Dry Hole",
		imageId = "rbxassetid://0",
		iconAssetId = "rbxassetid://124025915762217",
		iconKey = "master:37",
		rarity = "Unlucky",
		sourceRarity = "Common",
		streamCount = 1,
		barrelsPerSecond = 0,
		primaryInternalOilType = "Crude",
		isUnlucky = true,
		streams = { { burstType = "Dribble", oilType = "DirtOil", internalOilType = "Crude", barrelsPerSecond = 0.004 } },
	},
}

VeinCrateConfig.GroundSpriteSheets = {
    Bronze = {
        assetId = "rbxassetid://71916811703809",
        width = 2760,
        height = 4416,
        cellWidth = 552,
        cellHeight = 552,
    },
    Silver = {
        assetId = "rbxassetid://80019526230979",
        width = 2760,
        height = 4416,
        cellWidth = 552,
        cellHeight = 552,
    },
    Gold = {
        assetId = "rbxassetid://72890617312400",
        width = 2760,
        height = 4968,
        cellWidth = 552,
        cellHeight = 552,
    },
    Diamond = {
        assetId = "rbxassetid://96797628570457",
        width = 2760,
        height = 4968,
        cellWidth = 552,
        cellHeight = 552,
    },
}

VeinCrateConfig.GroundSpritePages = {
    Bronze = {
        {
            index = 1,
            assetId = VeinCrateConfig.GroundSpriteSheets.Bronze.assetId,
            width = VeinCrateConfig.GroundSpriteSheets.Bronze.width,
            height = VeinCrateConfig.GroundSpriteSheets.Bronze.height,
            cellWidth = VeinCrateConfig.GroundSpriteSheets.Bronze.cellWidth,
            cellHeight = VeinCrateConfig.GroundSpriteSheets.Bronze.cellHeight,
        },
    },
    Silver = {
        {
            index = 1,
            assetId = VeinCrateConfig.GroundSpriteSheets.Silver.assetId,
            width = VeinCrateConfig.GroundSpriteSheets.Silver.width,
            height = VeinCrateConfig.GroundSpriteSheets.Silver.height,
            cellWidth = VeinCrateConfig.GroundSpriteSheets.Silver.cellWidth,
            cellHeight = VeinCrateConfig.GroundSpriteSheets.Silver.cellHeight,
        },
    },
    Gold = {
        {
            index = 1,
            assetId = VeinCrateConfig.GroundSpriteSheets.Gold.assetId,
            width = VeinCrateConfig.GroundSpriteSheets.Gold.width,
            height = VeinCrateConfig.GroundSpriteSheets.Gold.height,
            cellWidth = VeinCrateConfig.GroundSpriteSheets.Gold.cellWidth,
            cellHeight = VeinCrateConfig.GroundSpriteSheets.Gold.cellHeight,
        },
    },
    Diamond = {
        {
            index = 1,
            assetId = VeinCrateConfig.GroundSpriteSheets.Diamond.assetId,
            width = VeinCrateConfig.GroundSpriteSheets.Diamond.width,
            height = VeinCrateConfig.GroundSpriteSheets.Diamond.height,
            cellWidth = VeinCrateConfig.GroundSpriteSheets.Diamond.cellWidth,
            cellHeight = VeinCrateConfig.GroundSpriteSheets.Diamond.cellHeight,
        },
    },
}

VeinCrateConfig.GroundSpriteRects = {
    Bronze = {
        ["item-45"] = {
            imageId = "rbxassetid://71916811703809",
            rectOffsetX = 26,
            rectOffsetY = 26,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-3"] = {
            imageId = "rbxassetid://71916811703809",
            rectOffsetX = 578,
            rectOffsetY = 26,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-1"] = {
            imageId = "rbxassetid://71916811703809",
            rectOffsetX = 1130,
            rectOffsetY = 26,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-6"] = {
            imageId = "rbxassetid://71916811703809",
            rectOffsetX = 1682,
            rectOffsetY = 26,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-5"] = {
            imageId = "rbxassetid://71916811703809",
            rectOffsetX = 2234,
            rectOffsetY = 26,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-4"] = {
            imageId = "rbxassetid://71916811703809",
            rectOffsetX = 26,
            rectOffsetY = 578,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-14"] = {
            imageId = "rbxassetid://71916811703809",
            rectOffsetX = 578,
            rectOffsetY = 578,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-7"] = {
            imageId = "rbxassetid://71916811703809",
            rectOffsetX = 1130,
            rectOffsetY = 578,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-18"] = {
            imageId = "rbxassetid://71916811703809",
            rectOffsetX = 1682,
            rectOffsetY = 578,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-17"] = {
            imageId = "rbxassetid://71916811703809",
            rectOffsetX = 2234,
            rectOffsetY = 578,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-15"] = {
            imageId = "rbxassetid://71916811703809",
            rectOffsetX = 26,
            rectOffsetY = 1130,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-16"] = {
            imageId = "rbxassetid://71916811703809",
            rectOffsetX = 578,
            rectOffsetY = 1130,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-24"] = {
            imageId = "rbxassetid://71916811703809",
            rectOffsetX = 1130,
            rectOffsetY = 1130,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-9"] = {
            imageId = "rbxassetid://71916811703809",
            rectOffsetX = 1682,
            rectOffsetY = 1130,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-8"] = {
            imageId = "rbxassetid://71916811703809",
            rectOffsetX = 2234,
            rectOffsetY = 1130,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-22"] = {
            imageId = "rbxassetid://71916811703809",
            rectOffsetX = 26,
            rectOffsetY = 1682,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-23"] = {
            imageId = "rbxassetid://71916811703809",
            rectOffsetX = 578,
            rectOffsetY = 1682,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-19"] = {
            imageId = "rbxassetid://71916811703809",
            rectOffsetX = 1130,
            rectOffsetY = 1682,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-21"] = {
            imageId = "rbxassetid://71916811703809",
            rectOffsetX = 1682,
            rectOffsetY = 1682,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-25"] = {
            imageId = "rbxassetid://71916811703809",
            rectOffsetX = 2234,
            rectOffsetY = 1682,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-30"] = {
            imageId = "rbxassetid://71916811703809",
            rectOffsetX = 26,
            rectOffsetY = 2234,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-26"] = {
            imageId = "rbxassetid://71916811703809",
            rectOffsetX = 578,
            rectOffsetY = 2234,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-10"] = {
            imageId = "rbxassetid://71916811703809",
            rectOffsetX = 1130,
            rectOffsetY = 2234,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-28"] = {
            imageId = "rbxassetid://71916811703809",
            rectOffsetX = 1682,
            rectOffsetY = 2234,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-27"] = {
            imageId = "rbxassetid://71916811703809",
            rectOffsetX = 2234,
            rectOffsetY = 2234,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-29"] = {
            imageId = "rbxassetid://71916811703809",
            rectOffsetX = 26,
            rectOffsetY = 2786,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-34"] = {
            imageId = "rbxassetid://71916811703809",
            rectOffsetX = 578,
            rectOffsetY = 2786,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-33"] = {
            imageId = "rbxassetid://71916811703809",
            rectOffsetX = 1130,
            rectOffsetY = 2786,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-43"] = {
            imageId = "rbxassetid://71916811703809",
            rectOffsetX = 1682,
            rectOffsetY = 2786,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-11"] = {
            imageId = "rbxassetid://71916811703809",
            rectOffsetX = 2234,
            rectOffsetY = 2786,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-32"] = {
            imageId = "rbxassetid://71916811703809",
            rectOffsetX = 26,
            rectOffsetY = 3338,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-31"] = {
            imageId = "rbxassetid://71916811703809",
            rectOffsetX = 578,
            rectOffsetY = 3338,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-41"] = {
            imageId = "rbxassetid://71916811703809",
            rectOffsetX = 1130,
            rectOffsetY = 3338,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-12"] = {
            imageId = "rbxassetid://71916811703809",
            rectOffsetX = 1682,
            rectOffsetY = 3338,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-38"] = {
            imageId = "rbxassetid://71916811703809",
            rectOffsetX = 2234,
            rectOffsetY = 3338,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-40"] = {
            imageId = "rbxassetid://71916811703809",
            rectOffsetX = 26,
            rectOffsetY = 3890,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-42"] = {
            imageId = "rbxassetid://71916811703809",
            rectOffsetX = 578,
            rectOffsetY = 3890,
            rectSizeX = 500,
            rectSizeY = 500,
        },
    },
    Silver = {
        ["item-45"] = {
            imageId = "rbxassetid://80019526230979",
            rectOffsetX = 26,
            rectOffsetY = 26,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-3"] = {
            imageId = "rbxassetid://80019526230979",
            rectOffsetX = 578,
            rectOffsetY = 26,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-1"] = {
            imageId = "rbxassetid://80019526230979",
            rectOffsetX = 1130,
            rectOffsetY = 26,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-6"] = {
            imageId = "rbxassetid://80019526230979",
            rectOffsetX = 1682,
            rectOffsetY = 26,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-5"] = {
            imageId = "rbxassetid://80019526230979",
            rectOffsetX = 2234,
            rectOffsetY = 26,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-4"] = {
            imageId = "rbxassetid://80019526230979",
            rectOffsetX = 26,
            rectOffsetY = 578,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-14"] = {
            imageId = "rbxassetid://80019526230979",
            rectOffsetX = 578,
            rectOffsetY = 578,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-7"] = {
            imageId = "rbxassetid://80019526230979",
            rectOffsetX = 1130,
            rectOffsetY = 578,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-18"] = {
            imageId = "rbxassetid://80019526230979",
            rectOffsetX = 1682,
            rectOffsetY = 578,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-17"] = {
            imageId = "rbxassetid://80019526230979",
            rectOffsetX = 2234,
            rectOffsetY = 578,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-15"] = {
            imageId = "rbxassetid://80019526230979",
            rectOffsetX = 26,
            rectOffsetY = 1130,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-16"] = {
            imageId = "rbxassetid://80019526230979",
            rectOffsetX = 578,
            rectOffsetY = 1130,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-24"] = {
            imageId = "rbxassetid://80019526230979",
            rectOffsetX = 1130,
            rectOffsetY = 1130,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-9"] = {
            imageId = "rbxassetid://80019526230979",
            rectOffsetX = 1682,
            rectOffsetY = 1130,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-8"] = {
            imageId = "rbxassetid://80019526230979",
            rectOffsetX = 2234,
            rectOffsetY = 1130,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-22"] = {
            imageId = "rbxassetid://80019526230979",
            rectOffsetX = 26,
            rectOffsetY = 1682,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-23"] = {
            imageId = "rbxassetid://80019526230979",
            rectOffsetX = 578,
            rectOffsetY = 1682,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-19"] = {
            imageId = "rbxassetid://80019526230979",
            rectOffsetX = 1130,
            rectOffsetY = 1682,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-21"] = {
            imageId = "rbxassetid://80019526230979",
            rectOffsetX = 1682,
            rectOffsetY = 1682,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-25"] = {
            imageId = "rbxassetid://80019526230979",
            rectOffsetX = 2234,
            rectOffsetY = 1682,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-30"] = {
            imageId = "rbxassetid://80019526230979",
            rectOffsetX = 26,
            rectOffsetY = 2234,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-26"] = {
            imageId = "rbxassetid://80019526230979",
            rectOffsetX = 578,
            rectOffsetY = 2234,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-10"] = {
            imageId = "rbxassetid://80019526230979",
            rectOffsetX = 1130,
            rectOffsetY = 2234,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-28"] = {
            imageId = "rbxassetid://80019526230979",
            rectOffsetX = 1682,
            rectOffsetY = 2234,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-27"] = {
            imageId = "rbxassetid://80019526230979",
            rectOffsetX = 2234,
            rectOffsetY = 2234,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-29"] = {
            imageId = "rbxassetid://80019526230979",
            rectOffsetX = 26,
            rectOffsetY = 2786,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-34"] = {
            imageId = "rbxassetid://80019526230979",
            rectOffsetX = 578,
            rectOffsetY = 2786,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-33"] = {
            imageId = "rbxassetid://80019526230979",
            rectOffsetX = 1130,
            rectOffsetY = 2786,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-43"] = {
            imageId = "rbxassetid://80019526230979",
            rectOffsetX = 1682,
            rectOffsetY = 2786,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-11"] = {
            imageId = "rbxassetid://80019526230979",
            rectOffsetX = 2234,
            rectOffsetY = 2786,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-32"] = {
            imageId = "rbxassetid://80019526230979",
            rectOffsetX = 26,
            rectOffsetY = 3338,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-31"] = {
            imageId = "rbxassetid://80019526230979",
            rectOffsetX = 578,
            rectOffsetY = 3338,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-41"] = {
            imageId = "rbxassetid://80019526230979",
            rectOffsetX = 1130,
            rectOffsetY = 3338,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-12"] = {
            imageId = "rbxassetid://80019526230979",
            rectOffsetX = 1682,
            rectOffsetY = 3338,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-38"] = {
            imageId = "rbxassetid://80019526230979",
            rectOffsetX = 2234,
            rectOffsetY = 3338,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-40"] = {
            imageId = "rbxassetid://80019526230979",
            rectOffsetX = 26,
            rectOffsetY = 3890,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-42"] = {
            imageId = "rbxassetid://80019526230979",
            rectOffsetX = 578,
            rectOffsetY = 3890,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-39"] = {
            imageId = "rbxassetid://80019526230979",
            rectOffsetX = 1130,
            rectOffsetY = 3890,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-37"] = {
            imageId = "rbxassetid://80019526230979",
            rectOffsetX = 1682,
            rectOffsetY = 3890,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-13"] = {
            imageId = "rbxassetid://80019526230979",
            rectOffsetX = 2234,
            rectOffsetY = 3890,
            rectSizeX = 500,
            rectSizeY = 500,
        },
    },
    Gold = {
        ["item-45"] = {
            imageId = "rbxassetid://72890617312400",
            rectOffsetX = 26,
            rectOffsetY = 26,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-3"] = {
            imageId = "rbxassetid://72890617312400",
            rectOffsetX = 578,
            rectOffsetY = 26,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-1"] = {
            imageId = "rbxassetid://72890617312400",
            rectOffsetX = 1130,
            rectOffsetY = 26,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-6"] = {
            imageId = "rbxassetid://72890617312400",
            rectOffsetX = 1682,
            rectOffsetY = 26,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-5"] = {
            imageId = "rbxassetid://72890617312400",
            rectOffsetX = 2234,
            rectOffsetY = 26,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-4"] = {
            imageId = "rbxassetid://72890617312400",
            rectOffsetX = 26,
            rectOffsetY = 578,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-14"] = {
            imageId = "rbxassetid://72890617312400",
            rectOffsetX = 578,
            rectOffsetY = 578,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-7"] = {
            imageId = "rbxassetid://72890617312400",
            rectOffsetX = 1130,
            rectOffsetY = 578,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-18"] = {
            imageId = "rbxassetid://72890617312400",
            rectOffsetX = 1682,
            rectOffsetY = 578,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-17"] = {
            imageId = "rbxassetid://72890617312400",
            rectOffsetX = 2234,
            rectOffsetY = 578,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-15"] = {
            imageId = "rbxassetid://72890617312400",
            rectOffsetX = 26,
            rectOffsetY = 1130,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-16"] = {
            imageId = "rbxassetid://72890617312400",
            rectOffsetX = 578,
            rectOffsetY = 1130,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-24"] = {
            imageId = "rbxassetid://72890617312400",
            rectOffsetX = 1130,
            rectOffsetY = 1130,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-9"] = {
            imageId = "rbxassetid://72890617312400",
            rectOffsetX = 1682,
            rectOffsetY = 1130,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-8"] = {
            imageId = "rbxassetid://72890617312400",
            rectOffsetX = 2234,
            rectOffsetY = 1130,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-22"] = {
            imageId = "rbxassetid://72890617312400",
            rectOffsetX = 26,
            rectOffsetY = 1682,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-23"] = {
            imageId = "rbxassetid://72890617312400",
            rectOffsetX = 578,
            rectOffsetY = 1682,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-19"] = {
            imageId = "rbxassetid://72890617312400",
            rectOffsetX = 1130,
            rectOffsetY = 1682,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-21"] = {
            imageId = "rbxassetid://72890617312400",
            rectOffsetX = 1682,
            rectOffsetY = 1682,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-25"] = {
            imageId = "rbxassetid://72890617312400",
            rectOffsetX = 2234,
            rectOffsetY = 1682,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-30"] = {
            imageId = "rbxassetid://72890617312400",
            rectOffsetX = 26,
            rectOffsetY = 2234,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-26"] = {
            imageId = "rbxassetid://72890617312400",
            rectOffsetX = 578,
            rectOffsetY = 2234,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-10"] = {
            imageId = "rbxassetid://72890617312400",
            rectOffsetX = 1130,
            rectOffsetY = 2234,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-28"] = {
            imageId = "rbxassetid://72890617312400",
            rectOffsetX = 1682,
            rectOffsetY = 2234,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-27"] = {
            imageId = "rbxassetid://72890617312400",
            rectOffsetX = 2234,
            rectOffsetY = 2234,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-29"] = {
            imageId = "rbxassetid://72890617312400",
            rectOffsetX = 26,
            rectOffsetY = 2786,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-34"] = {
            imageId = "rbxassetid://72890617312400",
            rectOffsetX = 578,
            rectOffsetY = 2786,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-33"] = {
            imageId = "rbxassetid://72890617312400",
            rectOffsetX = 1130,
            rectOffsetY = 2786,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-43"] = {
            imageId = "rbxassetid://72890617312400",
            rectOffsetX = 1682,
            rectOffsetY = 2786,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-11"] = {
            imageId = "rbxassetid://72890617312400",
            rectOffsetX = 2234,
            rectOffsetY = 2786,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-32"] = {
            imageId = "rbxassetid://72890617312400",
            rectOffsetX = 26,
            rectOffsetY = 3338,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-31"] = {
            imageId = "rbxassetid://72890617312400",
            rectOffsetX = 578,
            rectOffsetY = 3338,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-41"] = {
            imageId = "rbxassetid://72890617312400",
            rectOffsetX = 1130,
            rectOffsetY = 3338,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-12"] = {
            imageId = "rbxassetid://72890617312400",
            rectOffsetX = 1682,
            rectOffsetY = 3338,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-38"] = {
            imageId = "rbxassetid://72890617312400",
            rectOffsetX = 2234,
            rectOffsetY = 3338,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-40"] = {
            imageId = "rbxassetid://72890617312400",
            rectOffsetX = 26,
            rectOffsetY = 3890,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-42"] = {
            imageId = "rbxassetid://72890617312400",
            rectOffsetX = 578,
            rectOffsetY = 3890,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-39"] = {
            imageId = "rbxassetid://72890617312400",
            rectOffsetX = 1130,
            rectOffsetY = 3890,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-37"] = {
            imageId = "rbxassetid://72890617312400",
            rectOffsetX = 1682,
            rectOffsetY = 3890,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-13"] = {
            imageId = "rbxassetid://72890617312400",
            rectOffsetX = 2234,
            rectOffsetY = 3890,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-36"] = {
            imageId = "rbxassetid://72890617312400",
            rectOffsetX = 26,
            rectOffsetY = 4442,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-35"] = {
            imageId = "rbxassetid://72890617312400",
            rectOffsetX = 578,
            rectOffsetY = 4442,
            rectSizeX = 500,
            rectSizeY = 500,
        },
    },
    Diamond = {
        ["item-45"] = {
            imageId = "rbxassetid://96797628570457",
            rectOffsetX = 26,
            rectOffsetY = 26,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-3"] = {
            imageId = "rbxassetid://96797628570457",
            rectOffsetX = 578,
            rectOffsetY = 26,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-1"] = {
            imageId = "rbxassetid://96797628570457",
            rectOffsetX = 1130,
            rectOffsetY = 26,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-6"] = {
            imageId = "rbxassetid://96797628570457",
            rectOffsetX = 1682,
            rectOffsetY = 26,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-5"] = {
            imageId = "rbxassetid://96797628570457",
            rectOffsetX = 2234,
            rectOffsetY = 26,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-4"] = {
            imageId = "rbxassetid://96797628570457",
            rectOffsetX = 26,
            rectOffsetY = 578,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-14"] = {
            imageId = "rbxassetid://96797628570457",
            rectOffsetX = 578,
            rectOffsetY = 578,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-7"] = {
            imageId = "rbxassetid://96797628570457",
            rectOffsetX = 1130,
            rectOffsetY = 578,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-18"] = {
            imageId = "rbxassetid://96797628570457",
            rectOffsetX = 1682,
            rectOffsetY = 578,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-17"] = {
            imageId = "rbxassetid://96797628570457",
            rectOffsetX = 2234,
            rectOffsetY = 578,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-15"] = {
            imageId = "rbxassetid://96797628570457",
            rectOffsetX = 26,
            rectOffsetY = 1130,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-16"] = {
            imageId = "rbxassetid://96797628570457",
            rectOffsetX = 578,
            rectOffsetY = 1130,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-24"] = {
            imageId = "rbxassetid://96797628570457",
            rectOffsetX = 1130,
            rectOffsetY = 1130,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-9"] = {
            imageId = "rbxassetid://96797628570457",
            rectOffsetX = 1682,
            rectOffsetY = 1130,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-8"] = {
            imageId = "rbxassetid://96797628570457",
            rectOffsetX = 2234,
            rectOffsetY = 1130,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-22"] = {
            imageId = "rbxassetid://96797628570457",
            rectOffsetX = 26,
            rectOffsetY = 1682,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-23"] = {
            imageId = "rbxassetid://96797628570457",
            rectOffsetX = 578,
            rectOffsetY = 1682,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-19"] = {
            imageId = "rbxassetid://96797628570457",
            rectOffsetX = 1130,
            rectOffsetY = 1682,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-21"] = {
            imageId = "rbxassetid://96797628570457",
            rectOffsetX = 1682,
            rectOffsetY = 1682,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-25"] = {
            imageId = "rbxassetid://96797628570457",
            rectOffsetX = 2234,
            rectOffsetY = 1682,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-30"] = {
            imageId = "rbxassetid://96797628570457",
            rectOffsetX = 26,
            rectOffsetY = 2234,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-26"] = {
            imageId = "rbxassetid://96797628570457",
            rectOffsetX = 578,
            rectOffsetY = 2234,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-10"] = {
            imageId = "rbxassetid://96797628570457",
            rectOffsetX = 1130,
            rectOffsetY = 2234,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-28"] = {
            imageId = "rbxassetid://96797628570457",
            rectOffsetX = 1682,
            rectOffsetY = 2234,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-27"] = {
            imageId = "rbxassetid://96797628570457",
            rectOffsetX = 2234,
            rectOffsetY = 2234,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-29"] = {
            imageId = "rbxassetid://96797628570457",
            rectOffsetX = 26,
            rectOffsetY = 2786,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-34"] = {
            imageId = "rbxassetid://96797628570457",
            rectOffsetX = 578,
            rectOffsetY = 2786,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-33"] = {
            imageId = "rbxassetid://96797628570457",
            rectOffsetX = 1130,
            rectOffsetY = 2786,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-43"] = {
            imageId = "rbxassetid://96797628570457",
            rectOffsetX = 1682,
            rectOffsetY = 2786,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-11"] = {
            imageId = "rbxassetid://96797628570457",
            rectOffsetX = 2234,
            rectOffsetY = 2786,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-32"] = {
            imageId = "rbxassetid://96797628570457",
            rectOffsetX = 26,
            rectOffsetY = 3338,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-31"] = {
            imageId = "rbxassetid://96797628570457",
            rectOffsetX = 578,
            rectOffsetY = 3338,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-41"] = {
            imageId = "rbxassetid://96797628570457",
            rectOffsetX = 1130,
            rectOffsetY = 3338,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-12"] = {
            imageId = "rbxassetid://96797628570457",
            rectOffsetX = 1682,
            rectOffsetY = 3338,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-38"] = {
            imageId = "rbxassetid://96797628570457",
            rectOffsetX = 2234,
            rectOffsetY = 3338,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-40"] = {
            imageId = "rbxassetid://96797628570457",
            rectOffsetX = 26,
            rectOffsetY = 3890,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-42"] = {
            imageId = "rbxassetid://96797628570457",
            rectOffsetX = 578,
            rectOffsetY = 3890,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-39"] = {
            imageId = "rbxassetid://96797628570457",
            rectOffsetX = 1130,
            rectOffsetY = 3890,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-37"] = {
            imageId = "rbxassetid://96797628570457",
            rectOffsetX = 1682,
            rectOffsetY = 3890,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-13"] = {
            imageId = "rbxassetid://96797628570457",
            rectOffsetX = 2234,
            rectOffsetY = 3890,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-36"] = {
            imageId = "rbxassetid://96797628570457",
            rectOffsetX = 26,
            rectOffsetY = 4442,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-35"] = {
            imageId = "rbxassetid://96797628570457",
            rectOffsetX = 578,
            rectOffsetY = 4442,
            rectSizeX = 500,
            rectSizeY = 500,
        },
        ["item-44"] = {
            imageId = "rbxassetid://96797628570457",
            rectOffsetX = 1130,
            rectOffsetY = 4442,
            rectSizeX = 500,
            rectSizeY = 500,
        },
    },
}

local byId: { [string]: VeinTypeDef } = {}
local byRarity: { [string]: { VeinTypeDef } } = {}
local bySignature: { [string]: VeinTypeDef } = {}

local function signatureKeyFromStreams(streams): string
	local parts = {}
	for _, stream in ipairs(streams) do
		if typeof(stream) == "table" then
			local burstType = stream.burstType or stream.streamType
			local oilType = stream.oilType
			if typeof(burstType) == "string" and typeof(oilType) == "string" then
				table.insert(parts, string.format("%s/%s", burstType, oilType))
			end
		end
	end
	return table.concat(parts, "|")
end

for _, rarity in ipairs(VeinCrateConfig.RarityOrder) do
	byRarity[rarity] = {}
end
for _, def in ipairs(VeinCrateConfig.VeinTypes) do
	byId[def.id] = def
	local bucket = byRarity[def.rarity]
	if bucket then
		table.insert(bucket, def)
	end
	if not def.isUnlucky then
		bySignature[signatureKeyFromStreams(def.streams)] = def
	end
end

local function colorField(rarity: string, field: string): Color3
	local style = VeinCrateConfig.RarityStyles[rarity]
	if style and typeof(style[field]) == "Color3" then
		return style[field]
	end
	return Color3.fromRGB(128, 128, 128)
end

function VeinCrateConfig.GetById(id: string): VeinTypeDef?
	return byId[id]
end

function VeinCrateConfig.GetRarityStyle(rarity: string)
	return VeinCrateConfig.RarityStyles[rarity] or VeinCrateConfig.RarityStyles.Common
end

function VeinCrateConfig.GetRarityColor(rarity: string): Color3
	return colorField(rarity, "bgStart")
end

function VeinCrateConfig.GetRarityTextColor(rarity: string): Color3
	return colorField(rarity, "text")
end

function VeinCrateConfig.GetRaritySparkColor(rarity: string): Color3
	return colorField(rarity, "spark")
end

function VeinCrateConfig.GetGroundSpritePages(groundType: string)
	return VeinCrateConfig.GroundSpritePages[groundType]
end

function VeinCrateConfig.GetGroundSpritePage(groundType: string, pageIndex: number?)
	local pages = VeinCrateConfig.GetGroundSpritePages(groundType)
	if typeof(pages) ~= "table" then
		return nil
	end
	return pages[pageIndex or 1]
end

function VeinCrateConfig.GetGroundSpriteSheet(groundType: string)
	return VeinCrateConfig.GetGroundSpritePage(groundType, 1) or VeinCrateConfig.GroundSpriteSheets[groundType]
end

function VeinCrateConfig.GetDisplaySprite(idOrDef: string | VeinTypeDef, groundType: string)
	local def = if typeof(idOrDef) == "table" then idOrDef else VeinCrateConfig.GetById(idOrDef)
	if not def then
		return nil
	end
	-- Individual icon asset — no spritesheet rect math needed
	if def.iconAssetId and def.iconAssetId ~= "" and def.iconAssetId ~= "rbxassetid://0" then
		return {
			imageId = def.iconAssetId,
			rectOffsetX = 0,
			rectOffsetY = 0,
			rectSizeX = 0,
			rectSizeY = 0,
		}
	end
	-- Legacy spritesheet fallback
	local byGround = VeinCrateConfig.GroundSpriteRects[groundType]
	local sprite = byGround and byGround[def.id] or nil
	if typeof(sprite) ~= "table" then
		return nil
	end
	local pageIndex = if typeof(sprite.pageIndex) == "number" and sprite.pageIndex >= 1 then sprite.pageIndex else 1
	local page = VeinCrateConfig.GetGroundSpritePage(groundType, pageIndex)
	local imageId = sprite.imageId or sprite.assetId or (page and (page.assetId or page.imageId)) or "rbxassetid://0"
	return {
		pageIndex = pageIndex,
		imageId = imageId,
		rectOffsetX = sprite.rectOffsetX or 0,
		rectOffsetY = sprite.rectOffsetY or 0,
		rectSizeX = sprite.rectSizeX or (page and page.cellWidth) or 0,
		rectSizeY = sprite.rectSizeY or (page and page.cellHeight) or 0,
	}
end

function VeinCrateConfig.ApplyGroundSpriteManifest(groundType: string, manifest)
	if typeof(groundType) ~= "string" or typeof(manifest) ~= "table" then
		return
	end
	local pages = {}
	if typeof(manifest.pages) == "table" then
		for _, page in ipairs(manifest.pages) do
			if typeof(page) == "table" then
				local pageIndex = if typeof(page.index) == "number" and page.index >= 1 then page.index else #pages + 1
				pages[pageIndex] = {
					index = pageIndex,
					assetId = page.assetId or page.imageId or "rbxassetid://0",
					width = page.width or 0,
					height = page.height or 0,
					cellWidth = page.cellWidth or 0,
					cellHeight = page.cellHeight or 0,
				}
			end
		end
	end
	if #pages > 0 then
		VeinCrateConfig.GroundSpritePages[groundType] = pages
	end
	local rects = {}
	if typeof(manifest.mapping) == "table" then
		for _, entry in ipairs(manifest.mapping) do
			if typeof(entry) == "table" and typeof(entry.itemId) == "string" then
				rects[entry.itemId] = {
					pageIndex = entry.pageIndex or 1,
					imageId = entry.imageId,
					rectOffsetX = entry.rectOffsetX or 0,
					rectOffsetY = entry.rectOffsetY or 0,
					rectSizeX = entry.rectSizeX or 0,
					rectSizeY = entry.rectSizeY or 0,
				}
			end
		end
	end
	if next(rects) ~= nil then
		VeinCrateConfig.GroundSpriteRects[groundType] = rects
	end
	local firstPage = VeinCrateConfig.GetGroundSpritePage(groundType, 1)
	if firstPage then
		VeinCrateConfig.GroundSpriteSheets[groundType] = {
			assetId = firstPage.assetId,
			width = firstPage.width,
			height = firstPage.height,
			cellWidth = firstPage.cellWidth,
			cellHeight = firstPage.cellHeight,
		}
	end
end

function VeinCrateConfig.ApplyAtlasProjectManifest(manifest)
	if typeof(manifest) ~= "table" or typeof(manifest.lootboxes) ~= "table" then
		return
	end
	for _, lootboxManifest in ipairs(manifest.lootboxes) do
		if typeof(lootboxManifest) == "table" and typeof(lootboxManifest.groundType) == "string" then
			VeinCrateConfig.ApplyGroundSpriteManifest(lootboxManifest.groundType, lootboxManifest)
		end
	end
end

function VeinCrateConfig.GetAllForGround(groundType: string): { VeinTypeDef }
	local weights = VeinCrateConfig.GroundRarityWeights[groundType]
	local groundItems = VeinCrateConfig.GroundItemRarities[groundType]
	if typeof(weights) ~= "table" then
		return table.clone(VeinCrateConfig.VeinTypes)
	end
	local result = {}
	if groundItems then
		-- Per-ground filtered pool
		for itemId, itemRarity in pairs(groundItems) do
			if (weights[itemRarity] or 0) > 0 and byId[itemId] then
				table.insert(result, byId[itemId])
			end
		end
	else
		for rarity, bucket in pairs(byRarity) do
			if (weights[rarity] or 0) > 0 then
				for _, def in ipairs(bucket) do
					table.insert(result, def)
				end
			end
		end
	end
	-- Sort by ground-specific rarity then name
	table.sort(result, function(a, b)
		local aRarity = groundItems and groundItems[a.id] or a.rarity
		local bRarity = groundItems and groundItems[b.id] or b.rarity
		local ai, bi = 999, 999
		for i, rarity in ipairs(VeinCrateConfig.RarityOrder) do
			if rarity == aRarity then ai = i end
			if rarity == bRarity then bi = i end
		end
		if ai ~= bi then return ai < bi end
		return a.displayName < b.displayName
	end)
	return result
end

--- Roll a vein for `groundType`. `weightBias`, when provided, multiplies the
--- per-rarity slice from `GroundRarityWeights` before sampling — used by
--- drills with a rarity-bump (currently T6 in `EquipmentCatalog`). Multipliers
--- default to `1.0` for any rarity not listed (no change). `0` removes that
--- rarity entirely; values `> 1` boost; values `< 1` shrink. Internally we
--- switch to float math + `rng:NextNumber()` because biased weights are
--- typically fractional (e.g. `Unlucky × 0.5`); when no bias is passed the
--- result distribution is statistically identical to the previous integer
--- roll. See `EquipmentCatalog.EquipmentRow.rerollWeightBias` for the
--- design rationale and current values.
function VeinCrateConfig.RollVeinType(groundType: string, rng: Random, weightBias: { [string]: number }?): VeinTypeDef
	local weights = VeinCrateConfig.GroundRarityWeights[groundType] or VeinCrateConfig.GroundRarityWeights.Bronze
	local groundItems = VeinCrateConfig.GroundItemRarities[groundType]
	local effectiveByRarity: { [string]: number } = {}
	local totalWeight = 0.0
	for _, rarity in ipairs(VeinCrateConfig.RarityOrder) do
		local w = weights[rarity] or 0
		if weightBias ~= nil then
			local mult = weightBias[rarity]
			if typeof(mult) == "number" and mult >= 0 then
				w = w * mult
			end
		end
		effectiveByRarity[rarity] = w
		totalWeight += w
	end
	if totalWeight <= 0 then
		return VeinCrateConfig.VeinTypes[1]
	end
	local roll = rng:NextNumber() * totalWeight
	local accum = 0.0
	local pickedRarity = "Common"
	for _, rarity in ipairs(VeinCrateConfig.RarityOrder) do
		accum += effectiveByRarity[rarity]
		if roll <= accum then
			pickedRarity = rarity
			break
		end
	end
	-- Build bucket from per-ground rarity assignments
	local bucket: { VeinTypeDef } = {}
	if groundItems then
		for itemId, itemRarity in pairs(groundItems) do
			if itemRarity == pickedRarity and byId[itemId] then
				table.insert(bucket, byId[itemId])
			end
		end
	else
		bucket = byRarity[pickedRarity] or {}
	end
	-- Fallback: if bucket empty, try lower rarities within this ground
	if #bucket == 0 then
		for i = #VeinCrateConfig.RarityOrder, 1, -1 do
			local fallbackRarity = VeinCrateConfig.RarityOrder[i]
			local fb: { VeinTypeDef } = {}
			if groundItems then
				for itemId, itemRarity in pairs(groundItems) do
					if itemRarity == fallbackRarity and byId[itemId] then
						table.insert(fb, byId[itemId])
					end
				end
			else
				fb = byRarity[fallbackRarity] or {}
			end
			if #fb > 0 then
				bucket = fb
				break
			end
		end
	end
	if #bucket == 0 then
		return VeinCrateConfig.VeinTypes[1]
	end
	return bucket[rng:NextInteger(1, #bucket)]
end

function VeinCrateConfig.BuildVeinResult(def: VeinTypeDef, groundType: string)
	if def.isUnlucky then
		return { isDead = true, veinCount = "Single", veins = { { streamType = "Dead", oilType = "DirtOil" } }, groundType = groundType }
	end
	local veins = {}
	for _, stream in ipairs(def.streams) do
		table.insert(veins, { streamType = stream.burstType, oilType = stream.oilType })
	end
	local veinCount = if #veins >= 3 then "Triple" elseif #veins == 2 then "Double" else "Single"
	return { isDead = false, veinCount = veinCount, veins = veins, groundType = groundType }
end

function VeinCrateConfig.FindByVeinResult(veinResult): VeinTypeDef?
	if typeof(veinResult) ~= "table" then
		return nil
	end
	if veinResult.isDead == true then
		return byRarity.Unlucky and byRarity.Unlucky[1] or nil
	end
	if typeof(veinResult.veins) ~= "table" or #veinResult.veins == 0 then
		return nil
	end
	return bySignature[signatureKeyFromStreams(veinResult.veins)]
end

function VeinCrateConfig.GetInternalOilTotals(def: VeinTypeDef): { [string]: number }
	local totals = { Crude = 0, Refined = 0, Premium = 0 }
	for _, stream in ipairs(def.streams) do
		totals[stream.internalOilType] = (totals[stream.internalOilType] or 0) + stream.barrelsPerSecond
	end
	return totals
end

function VeinCrateConfig.GetSignatureLabel(def: VeinTypeDef): string
	if def.isUnlucky then
		return "Dry Hole"
	end
	local parts = {}
	for _, stream in ipairs(def.streams) do
		table.insert(parts, string.format("%s/%s", stream.burstType, stream.oilType))
	end
	return table.concat(parts, "  +  ")
end

function VeinCrateConfig.GetItemRarityForGround(def: VeinTypeDef, groundType: string): string
	local groundItems = VeinCrateConfig.GroundItemRarities[groundType]
	if groundItems and groundItems[def.id] then
		return groundItems[def.id]
	end
	return def.rarity
end

function VeinCrateConfig.GetById(itemId: string): VeinTypeDef?
	return byId[itemId]
end

function VeinCrateConfig._rebuildLookup()
	byId = {}
	byRarity = {}
	bySignature = {}
	for _, rarity in ipairs(VeinCrateConfig.RarityOrder) do
		byRarity[rarity] = {}
	end
	for _, def in ipairs(VeinCrateConfig.VeinTypes) do
		byId[def.id] = def
		local bucket = byRarity[def.rarity]
		if bucket then
			table.insert(bucket, def)
		end
		if not def.isUnlucky then
			bySignature[signatureKeyFromStreams(def.streams)] = def
		end
	end
end

return VeinCrateConfig
