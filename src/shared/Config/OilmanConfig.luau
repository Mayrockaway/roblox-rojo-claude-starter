--!strict
-- Rodger Dodger (the Oilman NPC at `Workspace.Oilman`) buys LOCAL plot oil
-- (`OilStateService.state.oilByTier`) at a fixed cheap base price scaled by
-- the same tier multipliers the strait market uses, for a quick-cash loop.
-- Intentionally worse than shipping → warehouse → market; this exists for
-- strait-closed windows and early-game pocket change.

local OilmanConfig = {
	--- Base $/barrel before tier multiplier.
	BaseBarrelPrice = 5,

	--- Per-tier price scalar. Final $/barrel = floor(BaseBarrelPrice * multiplier).
	--- Crude $4, Refined $7, Premium $10.
	TierMultiplier = {
		Crude = 0.8,
		Refined = 1.4,
		Premium = 2.0,
	} :: { [string]: number },

	--- Tiers rendered on the sell panel, in vertical order.
	TierOrder = { "Crude", "Refined", "Premium" },

	--- Display names for UI rows (keyed by internal tier id).
	TierDisplayName = {
		Crude = "Crude",
		Refined = "Refined",
		Premium = "Premium",
	} :: { [string]: string },

	--- Cycled one-at-a-time on each "Ask a question" click (client-side only).
	QuestionLines = {
		"I've been in this tub for 20 years, kid.",
		"Price's always fair when the oil's warm.",
		"Closed strait? That's when I eat well.",
		"You ever drink crude? Don't.",
		"Tell your pumps I said hi.",
	} :: { string },

	--- ProximityPrompt tuning. 14 studs covers both Rodger and the tub.
	Prompt = {
		ActionText = "Talk to Rodger",
		ObjectText = "Oilman",
		MaxActivationDistance = 14,
	},
}

function OilmanConfig.pricePerBarrel(tier: string): number
	local mul = OilmanConfig.TierMultiplier[tier]
	if typeof(mul) ~= "number" then
		return 0
	end
	return math.max(0, math.floor(OilmanConfig.BaseBarrelPrice * mul))
end

return OilmanConfig
