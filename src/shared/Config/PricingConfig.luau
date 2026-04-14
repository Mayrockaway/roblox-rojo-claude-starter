--!strict

local PricingConfig = {
	-- Sub-cycle fluctuation interval (seconds)
	MicroTickSeconds = 45,
	MicroTickJitterSeconds = 10,

	-- How many past base prices to track for trend arrows
	TrendMemory = 3,

	-- Trend thresholds (vs rolling average)
	TrendUpThreshold = 1.03,
	TrendDownThreshold = 0.97,

	-- Market health labels for compact indicator
	HotThreshold = 15, -- deviation% >= this = HOT
	ColdThreshold = -15, -- deviation% <= this = COLD

	-- ONE base oil price, fluctuates per strait state
	-- Each barrel type is a fixed multiplier of this base price
	BasePrice = 10,

	-- Per-type multiplier on the base price
	-- HeavyCrude = worst, PremiumRefined = best
	TypeMultipliers = {
		HeavyCrude = 0.8, -- $8 at base (all sub-light crude)
		LightSweet = 1.4, -- $14 at base
		PremiumRefined = 2.0, -- $20 at base
	},

	-- Strait state bands for the SINGLE base oil price
	-- baseOilPrice = floor(BasePrice * lerp(minMul, maxMul, randomFactor))
	-- then per-type price = floor(baseOilPrice * TypeMultipliers[type])
	Bands = {
		Open = { minMul = 0.80, maxMul = 1.20 }, -- base $8-$12
		Restricted = { minMul = 2.00, maxMul = 3.20 }, -- base $20-$32 (mid strait pressure)
		Closed = { minMul = 5.00, maxMul = 8.00 }, -- base $50-$80
	},
}

-- Precompute global min/max for the base price (for gradient bar)
local allMins, allMaxs = {}, {}
for _, band in pairs(PricingConfig.Bands) do
	table.insert(allMins, band.minMul)
	table.insert(allMaxs, band.maxMul)
end
table.sort(allMins)
table.sort(allMaxs)
PricingConfig.GlobalBaseMin = math.floor(PricingConfig.BasePrice * allMins[1])
PricingConfig.GlobalBaseMax = math.floor(PricingConfig.BasePrice * allMaxs[#allMaxs])

return PricingConfig
