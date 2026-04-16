--!strict

export type StraitState = "Open" | "Restricted" | "Closed"

local StraitConfig = {
	InitialState = "Open" :: StraitState,
	RollIntervalSeconds = 70,
	RollJitterSeconds = 10,
	StateOrder = { "Open", "Restricted", "Closed" } :: { StraitState },
	States = {
		Open = {
			riskLabel = "low",
			priceMultiplier = 1.0,
			baseSuccessChance = 0.95,
			initialEventChance = 0.10,
			eventContinuationChance = 0.12,
		},
		Restricted = {
			riskLabel = "elevated",
			priceMultiplier = 2.5,
			baseSuccessChance = 0.45,
			initialEventChance = 0.45,
			eventContinuationChance = 0.35,
		},
		Closed = {
			riskLabel = "blocked",
			priceMultiplier = 5.0,
			baseSuccessChance = 0.05,
			initialEventChance = 0.80,
			eventContinuationChance = 0.60,
		},
	},
}

return StraitConfig
