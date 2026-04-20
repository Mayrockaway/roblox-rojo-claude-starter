--!strict
-- "Instant sell" prices for the ShipOilPanel.InstantSell sub-modal — the
-- DeliveryMan flow that lets a player dump their plot `oilByTier` for cash
-- without queueing a shipment.
--
-- Intentionally MUCH worse than `OilmanConfig` / shipping → market so this
-- stays a "panic button" loop rather than the dominant sell strategy.
-- Numbers below are placeholders requested by the user; safe to retune from
-- this file alone — server (`InstantSellService`) and client (`ShipOilPanel`
-- InstantSell wiring) both read from here.

local InstantSellConfig = {
	--- Flat $/barrel per tier. NOT scaled by market — price is fixed regardless
	--- of strait state, by design.
	PricePerBarrel = {
		HeavyCrude = 2,
		LightSweet = 4,
		PremiumRefined = 8,
	} :: { [string]: number },

	--- Tier render order in the InstantSell modal (matches ShipOilPanel cargo).
	TierOrder = { "HeavyCrude", "LightSweet", "PremiumRefined" },

	--- Display names (matches `OilmanConfig`/`QualityConfig` strings so labels
	--- read consistently across panels).
	TierDisplayName = {
		HeavyCrude = "Heavy Crude",
		LightSweet = "Light Sweet",
		PremiumRefined = "Premium Refined",
	} :: { [string]: string },
}

function InstantSellConfig.pricePerBarrel(tier: string): number
	local p = InstantSellConfig.PricePerBarrel[tier]
	if typeof(p) ~= "number" then
		return 0
	end
	return math.max(0, math.floor(p))
end

return InstantSellConfig
