--!strict

export type StraitState = "Open" | "Tense" | "Dangerous" | "Crisis" | "Closed"

local StraitConfig = {
	InitialState = "Open" :: StraitState,
	RollIntervalSeconds = 180,
	RollJitterSeconds = 45,
	StateOrder = { "Open", "Tense", "Dangerous", "Crisis", "Closed" } :: { StraitState },
	States = {
		Open = {
			riskLabel = "low",
			priceMultiplier = 1.0,
			baseSuccessChance = 0.95,
			initialEventChance = 0.10,
			eventContinuationChance = 0.12,
		},
		Tense = {
			riskLabel = "medium",
			priceMultiplier = 1.5,
			baseSuccessChance = 0.75,
			initialEventChance = 0.25,
			eventContinuationChance = 0.22,
		},
		Dangerous = {
			riskLabel = "high",
			priceMultiplier = 2.5,
			baseSuccessChance = 0.45,
			initialEventChance = 0.45,
			eventContinuationChance = 0.35,
		},
		Crisis = {
			riskLabel = "extreme",
			priceMultiplier = 4.0,
			baseSuccessChance = 0.25,
			initialEventChance = 0.65,
			eventContinuationChance = 0.48,
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
