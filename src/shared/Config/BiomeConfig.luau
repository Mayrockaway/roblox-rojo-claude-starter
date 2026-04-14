--!strict

local BiomeConfig = {
	-- Roll weights (~11% each, sums to 99 + 1 for rounding = 100)
	RollWeights = {
		DustyDesert = 11,
		DecentDesert = 11,
		ClayDesert = 11,
		Frostlands = 11,
		Volcanic = 11,
		MagmaGrounds = 11,
		GrassyFarm = 12,
		GrassyForrest = 11,
		IceyArea = 11,
	},

	BiomeNames = { "DustyDesert", "DecentDesert", "ClayDesert", "Frostlands", "Volcanic", "MagmaGrounds", "GrassyFarm", "GrassyForrest", "IceyArea" },

	Biomes = {
		DustyDesert = {
			displayName = "Dusty Desert",
			emoji = "🏜️",
			tileTypes = {
				{ name = "Sand", oilType = "HeavyCrude", weight = 100, material = Enum.Material.Sand, color = Color3.fromRGB(210, 185, 130) },
			},
			obstacleRate = 0.04,
			obstacleTypes = { "Rock" },
			obstacleCosts = { Rock = 300 },
		},
		DecentDesert = {
			displayName = "Decent Desert",
			emoji = "🌿",
			tileTypes = {
				{ name = "Sand", oilType = "HeavyCrude", weight = 64, material = Enum.Material.Sand, color = Color3.fromRGB(210, 185, 130) },
				{ name = "Dry Clay", oilType = "HeavyCrude", weight = 20, material = Enum.Material.Sandstone, color = Color3.fromRGB(180, 130, 90) },
				{ name = "Golden Sand", oilType = "LightSweet", weight = 4, material = Enum.Material.Sand, color = Color3.fromRGB(240, 210, 80) },
				{ name = "Peat", oilType = "HeavyCrude", weight = 12, material = Enum.Material.Ground, color = Color3.fromRGB(55, 45, 35) },
			},
			obstacleRate = 0.20,
			obstacleTypes = { "Rock", "MudPit" },
			obstacleCosts = { Rock = 300, MudPit = 250 },
		},
		ClayDesert = {
			displayName = "Clay Desert",
			emoji = "🌲",
			tileTypes = {
				{ name = "Sand", oilType = "HeavyCrude", weight = 48, material = Enum.Material.Sand, color = Color3.fromRGB(210, 185, 130) },
				{ name = "Dry Clay", oilType = "HeavyCrude", weight = 52, material = Enum.Material.Sandstone, color = Color3.fromRGB(180, 130, 90) },
			},
			obstacleRate = 0.32,
			obstacleTypes = { "MudPit", "Pyramid" },
			obstacleCosts = { MudPit = 250, Pyramid = 500 },
		},
		Frostlands = {
			displayName = "Frostlands",
			emoji = "❄️",
			tileTypes = {
				{ name = "Sand", oilType = "HeavyCrude", weight = 32, material = Enum.Material.Sand, color = Color3.fromRGB(210, 185, 130) },
				{ name = "Dry Clay", oilType = "HeavyCrude", weight = 32, material = Enum.Material.Sandstone, color = Color3.fromRGB(180, 130, 90) },
				{ name = "Golden Sand", oilType = "LightSweet", weight = 8, material = Enum.Material.Sand, color = Color3.fromRGB(240, 210, 80) },
				{ name = "Peat", oilType = "HeavyCrude", weight = 20, material = Enum.Material.Ground, color = Color3.fromRGB(55, 45, 35) },
				{ name = "Sulfur", oilType = "HeavyCrude", weight = 8, material = Enum.Material.Pebble, color = Color3.fromRGB(180, 170, 60) },
			},
			obstacleRate = 0.28,
			obstacleTypes = { "ObsidianPillar" },
			obstacleCosts = { ObsidianPillar = 800 },
		},
		Volcanic = {
			displayName = "Volcanic",
			emoji = "🌋",
			tileTypes = {
				{ name = "Peat", oilType = "HeavyCrude", weight = 12, material = Enum.Material.Ground, color = Color3.fromRGB(55, 45, 35) },
				{ name = "Ash", oilType = "HeavyCrude", weight = 12, material = Enum.Material.Basalt, color = Color3.fromRGB(50, 45, 40) },
				{ name = "Sulfur", oilType = "HeavyCrude", weight = 20, material = Enum.Material.Pebble, color = Color3.fromRGB(180, 170, 60) },
				{ name = "Hard Magma", oilType = "LightSweet", weight = 44, material = Enum.Material.Mud, color = Color3.fromRGB(255, 123, 66) },
				{ name = "Obsidian", oilType = "PremiumRefined", weight = 12, material = Enum.Material.Ice, color = Color3.fromRGB(3, 3, 3) },
			},
			obstacleRate = 0.36,
			obstacleTypes = { "Rock", "LavaRock", "ObsidianPillar" },
			obstacleCosts = { Rock = 300, LavaRock = 1000, ObsidianPillar = 800 },
		},
		MagmaGrounds = {
			displayName = "MagmaGrounds",
			emoji = "🌍",
			tileTypes = {
				{ name = "Ash", oilType = "HeavyCrude", weight = 48, material = Enum.Material.Basalt, color = Color3.fromRGB(50, 45, 40) },
				{ name = "Hard Magma", oilType = "LightSweet", weight = 52, material = Enum.Material.Mud, color = Color3.fromRGB(255, 123, 66) },
			},
			obstacleRate = 0.00,
			obstacleTypes = {},
			obstacleCosts = {},
		},
		GrassyFarm = {
			displayName = "GrassyFarm",
			emoji = "🌍",
			tileTypes = {
				{ name = "Soil", oilType = "HeavyCrude", weight = 20, material = Enum.Material.Ground, color = Color3.fromRGB(100, 80, 55) },
				{ name = "Grass", oilType = "HeavyCrude", weight = 32, material = Enum.Material.Grass, color = Color3.fromRGB(4, 255, 0) },
				{ name = "Water", oilType = "HeavyCrude", weight = 24, material = Enum.Material.Mud, color = Color3.fromRGB(0, 255, 225) },
				{ name = "Rich Soil", oilType = "LightSweet", weight = 24, material = Enum.Material.Mud, color = Color3.fromRGB(164, 100, 10) },
			},
			obstacleRate = 0.44,
			obstacleTypes = { "Bush", "Water" },
			obstacleCosts = { Bush = 300, Water = 100000 },
		},
		GrassyForrest = {
			displayName = "Grassy Forrest",
			emoji = "🌍",
			tileTypes = {
				{ name = "Fern Patch", oilType = "HeavyCrude", weight = 36, material = Enum.Material.LeafyGrass, color = Color3.fromRGB(50, 100, 45) },
				{ name = "Grass", oilType = "HeavyCrude", weight = 40, material = Enum.Material.Grass, color = Color3.fromRGB(4, 255, 0) },
				{ name = "Rocky Ground", oilType = "HeavyCrude", weight = 24, material = Enum.Material.Ground, color = Color3.fromRGB(49, 34, 12) },
			},
			obstacleRate = 0.40,
			obstacleTypes = { "Tree" },
			obstacleCosts = { Tree = 500 },
		},
		IceyArea = {
			displayName = "IceyArea",
			emoji = "🌍",
			tileTypes = {
				{ name = "Snow", oilType = "LightSweet", weight = 28, material = Enum.Material.Glacier, color = Color3.fromRGB(230, 240, 250) },
				{ name = "Permafrost", oilType = "PremiumRefined", weight = 32, material = Enum.Material.Glacier, color = Color3.fromRGB(160, 200, 240) },
				{ name = "Tundra", oilType = "HeavyCrude", weight = 28, material = Enum.Material.Rock, color = Color3.fromRGB(120, 115, 110) },
				{ name = "Water", oilType = "HeavyCrude", weight = 12, material = Enum.Material.Mud, color = Color3.fromRGB(0, 255, 225) },
			},
			obstacleRate = 0.40,
			obstacleTypes = { "FrozenStump", "Water" },
			obstacleCosts = { FrozenStump = 500, Water = 100000 },
		},
	},

	ObstacleTemplates = {
		Rock = "Obstacle_Rock",
		DeadStump = "Obstacle_DeadStump",
		FallenLog = "Obstacle_FallenLog",
		MudPit = "Obstacle_MudPit",
		Tree = "Obstacle_Tree",
		Bush = "Obstacle_Bush",
		IceBoulder = "Obstacle_IceBoulder",
		FrozenStump = "Obstacle_FrozenStump",
		LavaRock = "Obstacle_LavaRock",
		ObsidianPillar = "Obstacle_ObsidianPillar",
		Pyramid = "Obstacle_Pyramid",
		Water = "Obstacle_Water",
	},

	-- Obstacles that block drills but allow pipes (water tiles)
	PipesOnlyObstacles = {
		Water = true,
	},

	SlotMachine = {
		FlashCount = 8,
		InitialInterval = 0.15,
		FinalInterval = 0.8,
	},
}

function BiomeConfig.RollBiome(rng: Random?): string
	local total = 0
	for _, w in pairs(BiomeConfig.RollWeights) do total += w end
	local r = rng and rng:NextInteger(1, total) or math.random(1, total)
	local cursor = 0
	for _, biomeName in ipairs(BiomeConfig.BiomeNames) do
		cursor += BiomeConfig.RollWeights[biomeName] or 0
		if r <= cursor then
			return biomeName
		end
	end
	return "DustyDesert"
end

function BiomeConfig.RollTileType(biomeName: string, rng: Random?)
	local biome = BiomeConfig.Biomes[biomeName]
	if not biome or not biome.tileTypes or #biome.tileTypes == 0 then
		return { name = "Sand", oilType = "HeavyCrude", weight = 100, material = Enum.Material.Sand, color = Color3.fromRGB(210, 185, 130) }
	end
	local totalWeight = 0
	for _, tt in ipairs(biome.tileTypes) do totalWeight += tt.weight end
	local r = rng and rng:NextInteger(1, totalWeight) or math.random(1, totalWeight)
	local cursor = 0
	for _, tt in ipairs(biome.tileTypes) do
		cursor += tt.weight
		if r <= cursor then return tt end
	end
	return biome.tileTypes[1]
end

function BiomeConfig.RollTileOilType(biomeName: string, rng: Random?): string
	local tt = BiomeConfig.RollTileType(biomeName, rng)
	return tt and tt.oilType or "HeavyCrude"
end

function BiomeConfig.RollObstacleType(biomeName: string, rng: Random?): string
	local biome = BiomeConfig.Biomes[biomeName]
	if not biome or not biome.obstacleTypes or #biome.obstacleTypes == 0 then return "Rock" end
	local idx = rng and rng:NextInteger(1, #biome.obstacleTypes) or math.random(1, #biome.obstacleTypes)
	return biome.obstacleTypes[idx]
end

function BiomeConfig.GetObstacleCost(biomeName: string, obstacleType: string): number
	local biome = BiomeConfig.Biomes[biomeName]
	if not biome or not biome.obstacleCosts then return 500 end
	return biome.obstacleCosts[obstacleType] or 500
end

function BiomeConfig.IsPipesOnlyObstacle(obstacleType: string): boolean
	return BiomeConfig.PipesOnlyObstacles[obstacleType] == true
end

return BiomeConfig
