--!strict

local WarehouseConfig = {
	MaxSlots = 12,
	SlotSpacing = 60,

	Tiers = {
		{ tier = 1,  capacity = 20,   footprint = 20, cost = 0 },
		{ tier = 2,  capacity = 50,   footprint = 24, cost = 500 },
		{ tier = 3,  capacity = 100,  footprint = 28, cost = 1500 },
		{ tier = 4,  capacity = 180,  footprint = 32, cost = 4000 },
		{ tier = 5,  capacity = 300,  footprint = 36, cost = 10000 },
		{ tier = 6,  capacity = 500,  footprint = 40, cost = 25000 },
		{ tier = 7,  capacity = 750,  footprint = 44, cost = 60000 },
		{ tier = 8,  capacity = 1100, footprint = 48, cost = 150000 },
		{ tier = 9,  capacity = 1500, footprint = 52, cost = 350000 },
		{ tier = 10, capacity = 2000, footprint = 56, cost = 800000 },
	},

	BarrelVisuals = {
		MaxPerTier = 20,
		BarrelHeight = 4.8,
	},

	DataStoreName = "WarehouseProfiles_v1",
}

function WarehouseConfig.GetTier(tier: number)
	for _, t in ipairs(WarehouseConfig.Tiers) do
		if t.tier == tier then
			return t
		end
	end
	return WarehouseConfig.Tiers[1]
end

function WarehouseConfig.GetCapacity(tier: number): number
	local t = WarehouseConfig.GetTier(tier)
	return t and t.capacity or 20
end

function WarehouseConfig.GetUpgradeCost(tier: number): number?
	local next = WarehouseConfig.GetTier(tier + 1)
	return next and next.cost or nil
end

return WarehouseConfig
