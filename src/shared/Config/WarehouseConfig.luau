--!strict

local WarehouseConfig = {
	MaxSlots = 12,
	SlotSpacing = 60,

	Tiers = {
		{ tier = 1,  capacity = 40,   footprint = 20, cost = 0 },
		{ tier = 2,  capacity = 60,   footprint = 24, cost = 350 },
		{ tier = 3,  capacity = 120,  footprint = 28, cost = 1100 },
		{ tier = 4,  capacity = 220,  footprint = 32, cost = 3200 },
		{ tier = 5,  capacity = 400,  footprint = 36, cost = 9000 },
		{ tier = 6,  capacity = 700,  footprint = 40, cost = 25000 },
		{ tier = 7,  capacity = 1200, footprint = 44, cost = 70000 },
		{ tier = 8,  capacity = 2000, footprint = 48, cost = 200000 },
		{ tier = 9,  capacity = 3200, footprint = 52, cost = 550000 },
		{ tier = 10, capacity = 5000, footprint = 56, cost = 1500000 },
	},

	BarrelVisuals = {
		MaxPerTier = 20,
		BarrelHeight = 4.8,
	},

	DataStoreName = "WarehouseProfiles_v1",
}

function WarehouseConfig.GetTier(tier: number)
	for _, def in ipairs(WarehouseConfig.Tiers) do
		if def.tier == tier then
			return def
		end
	end
	return WarehouseConfig.Tiers[1]
end

function WarehouseConfig.GetCapacity(tier: number): number
	local def = WarehouseConfig.GetTier(tier)
	return def and def.capacity or 20
end

function WarehouseConfig.GetUpgradeCost(tier: number): number?
	local nextDef = WarehouseConfig.GetTier(tier + 1)
	return nextDef and nextDef.cost or nil
end

return WarehouseConfig
