--!strict
-- VeinConfig: ground progression, pump upgrades, oil types, and legacy helpers.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")

local VeinConfig = {}

export type GroundTypeDef = {
	name: string,
	row: number,
	color: Color3,
	material: Enum.Material,
	drillSeconds: number,
	unlockCost: number,
}

VeinConfig.GroundTypes = {
	Bronze = {
		name = "Bronze",
		row = 4,
		color = Color3.fromRGB(176, 120, 72),
		material = Enum.Material.Metal,
		drillSeconds = 30,
		unlockCost = 750,
	},
	Silver = {
		name = "Silver",
		row = 3,
		color = Color3.fromRGB(196, 202, 210),
		material = Enum.Material.Metal,
		drillSeconds = 8 * 60,
		unlockCost = 5000,
	},
	Gold = {
		name = "Gold",
		row = 2,
		color = Color3.fromRGB(255, 200, 46),
		material = Enum.Material.Metal,
		drillSeconds = 35 * 60,
		unlockCost = 45000,
	},
	Diamond = {
		name = "Diamond",
		row = 1,
		color = Color3.fromRGB(154, 235, 255),
		material = Enum.Material.Metal,
		drillSeconds = 2 * 60 * 60,
		unlockCost = 350000,
	},
} :: { [string]: GroundTypeDef }

VeinConfig.GroundByRow = {
	[1] = VeinConfig.GroundTypes.Diamond,
	[2] = VeinConfig.GroundTypes.Gold,
	[3] = VeinConfig.GroundTypes.Silver,
	[4] = VeinConfig.GroundTypes.Bronze,
}

VeinConfig.PumpUpgrades = {
	T1 = { flowMult = 1, templateName = "Pump_T1", displayName = "Basic Pump" },
	T2 = { flowMult = 2, templateName = "Pump_T2", displayName = "Standard Pump" },
	T3 = { flowMult = 4, templateName = "Pump_T3", displayName = "Advanced Pump" },
}

VeinConfig.PumpUpgradeOrder = { "T1", "T2", "T3" }

VeinConfig.PumpUpgradeCostsByGround = {
	Bronze = { T2 = 900, T3 = 3200 },
	Silver = { T2 = 6000, T3 = 22000 },
	Gold = { T2 = 45000, T3 = 165000 },
	Diamond = { T2 = 320000, T3 = 1200000 },
}

function VeinConfig.GetUpgradeCost(currentTier: string, groundType: string): (string?, number?)
	local currentIdx = 0
	for i, tier in ipairs(VeinConfig.PumpUpgradeOrder) do
		if tier == currentTier then
			currentIdx = i
			break
		end
	end
	local nextTier = VeinConfig.PumpUpgradeOrder[currentIdx + 1]
	if not nextTier then
		return nil, nil
	end
	local groundCosts = VeinConfig.PumpUpgradeCostsByGround[groundType] or VeinConfig.PumpUpgradeCostsByGround.Bronze
	return nextTier, groundCosts[nextTier]
end

function VeinConfig.GetChunkUnlockCostByGround(groundType: string): number
	local ground = VeinConfig.GroundTypes[groundType]
	return ground and ground.unlockCost or VeinConfig.GroundTypes.Bronze.unlockCost
end

export type StreamDef = {
	name: string,
	barrelsPerSecond: number,
	productionMult: number,
	particleMult: number,
	color: Color3,
	bold: boolean,
	shaking: boolean,
}

VeinConfig.BurstOutputBps = {
	Dribble = 0.005,
	Stream = 0.0125,
	Burst = 0.03,
	Geyser = 0.08,
}

VeinConfig.Streams = {
	Dead = { name = "Dead", barrelsPerSecond = 0, productionMult = 0, particleMult = 0, color = Color3.fromRGB(150, 150, 150), bold = false, shaking = false },
	Dribble = { name = "Dribble", barrelsPerSecond = VeinConfig.BurstOutputBps.Dribble, productionMult = VeinConfig.BurstOutputBps.Dribble, particleMult = 0.4, color = Color3.fromRGB(255, 255, 255), bold = false, shaking = false },
	Stream = { name = "Stream", barrelsPerSecond = VeinConfig.BurstOutputBps.Stream, productionMult = VeinConfig.BurstOutputBps.Stream, particleMult = 1, color = Color3.fromRGB(80, 220, 80), bold = false, shaking = false },
	Burst = { name = "Burst", barrelsPerSecond = VeinConfig.BurstOutputBps.Burst, productionMult = VeinConfig.BurstOutputBps.Burst, particleMult = 2, color = Color3.fromRGB(50, 150, 255), bold = true, shaking = false },
	Geyser = { name = "Geyser", barrelsPerSecond = VeinConfig.BurstOutputBps.Geyser, productionMult = VeinConfig.BurstOutputBps.Geyser, particleMult = 4, color = Color3.fromRGB(255, 170, 60), bold = true, shaking = true },
} :: { [string]: StreamDef }

VeinConfig.StreamOrder = { "Dribble", "Stream", "Burst", "Geyser" }

export type OilTypeDef = {
	name: string,
	displayName: string,
	internalName: string,
	color: Color3,
	valueMult: number,
}

VeinConfig.OilTypes = {
	DirtOil = { name = "DirtOil", displayName = "Crude", internalName = "Crude", color = Color3.fromRGB(200, 200, 200), valueMult = 1 },
	GoodOil = { name = "GoodOil", displayName = "Refined", internalName = "Refined", color = Color3.fromRGB(240, 200, 70), valueMult = 2 },
	GoldOil = { name = "GoldOil", displayName = "Premium", internalName = "Premium", color = Color3.fromRGB(255, 150, 200), valueMult = 4 },
} :: { [string]: OilTypeDef }

VeinConfig.OilOrder = { "DirtOil", "GoodOil", "GoldOil" }

export type VeinCountDef = {
	name: string,
	displayName: string,
	count: number,
	color: Color3,
	bold: boolean,
	shaking: boolean,
}

VeinConfig.VeinCounts = {
	Single = { name = "Single", displayName = "Single Vein", count = 1, color = Color3.fromRGB(255, 255, 255), bold = false, shaking = false },
	Double = { name = "Double", displayName = "Double Vein", count = 2, color = Color3.fromRGB(180, 80, 255), bold = true, shaking = false },
	Triple = { name = "Triple", displayName = "Triple Vein", count = 3, color = Color3.fromRGB(255, 170, 60), bold = true, shaking = true },
} :: { [string]: VeinCountDef }

export type SingleVeinResult = {
	streamType: string,
	oilType: string,
}

export type VeinRollResult = {
	isDead: boolean,
	veinCount: string,
	veins: { SingleVeinResult },
	groundType: string,
}

function VeinConfig.RollVein(groundType: GroundTypeDef, rng: Random): VeinRollResult
	local VeinCrateConfig = require(Shared:WaitForChild("Config"):WaitForChild("VeinCrateConfig"))
	local rolled = VeinCrateConfig.RollVeinType(groundType.name, rng)
	return VeinCrateConfig.BuildVeinResult(rolled, groundType.name)
end

function VeinConfig.BuildDisplayName(result: VeinRollResult): string
	if result.isDead then
		return "Dry Hole"
	end
	local parts = {}
	for _, vein in ipairs(result.veins) do
		local oilDef = VeinConfig.OilTypes[vein.oilType]
		local streamDef = VeinConfig.Streams[vein.streamType]
		table.insert(parts, string.format("%s %s", oilDef and oilDef.displayName or vein.oilType, streamDef and streamDef.name or vein.streamType))
	end
	return table.concat(parts, " + ")
end

function VeinConfig.CalculateCombinedOdds(_result: VeinRollResult): number
	return 0
end

function VeinConfig.FormatOdds(prob: number): string
	if prob <= 0 then
		return "ROW POOL"
	end
	local inverse = math.max(1, math.floor(1 / prob + 0.5))
	return "1/" .. tostring(inverse)
end

export type RarityTier = {
	name: string,
	color: Color3,
}

function VeinConfig.GetRarityFromOdds(prob: number): RarityTier
	if prob <= 0 then
		return { name = "ROW POOL", color = Color3.fromRGB(255, 255, 255) }
	end
	local inverse = 1 / prob
	if inverse >= 10000 then
		return { name = "LEGENDARY", color = Color3.fromRGB(255, 170, 60) }
	elseif inverse >= 1000 then
		return { name = "EPIC", color = Color3.fromRGB(180, 80, 255) }
	elseif inverse >= 100 then
		return { name = "RARE", color = Color3.fromRGB(50, 150, 255) }
	elseif inverse >= 10 then
		return { name = "UNCOMMON", color = Color3.fromRGB(80, 220, 80) }
	end
	return { name = "COMMON", color = Color3.fromRGB(255, 255, 255) }
end

function VeinConfig.GetInternalOilName(oilType: string): string
	local def = VeinConfig.OilTypes[oilType]
	return def and def.internalName or "Crude"
end

function VeinConfig.GetTotalProductionMult(result: VeinRollResult): number
	if result.isDead then
		return 0
	end
	local total = 0
	for _, vein in ipairs(result.veins) do
		local streamDef = VeinConfig.Streams[vein.streamType]
		total += streamDef and streamDef.barrelsPerSecond or 0
	end
	return total
end

return VeinConfig
