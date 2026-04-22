--!strict

export type StraitState = "Open" | "Restricted" | "Closed"

local StraitConfig = {
	InitialState = "Open" :: StraitState,
	RollIntervalSeconds = 70,
	RollJitterSeconds = 10,
	StateOrder = { "Open", "Restricted", "Closed" } :: { StraitState },

	--- Weighted picker for `_rollState`. Higher = more likely. The roller
	--- normalizes against `Σ(StateWeights)` so values are relative — these
	--- specific numbers (50 / 30 / 20) just happen to read as percentages,
	--- but the math works with any positive numbers.
	---
	--- Tuning intent: Open is the "default" state of the strait so the
	--- world feels safe most of the time and price spikes (Restricted /
	--- Closed) feel like genuine events worth shipping into. With a 70s
	--- roll cadence and silent-rerolls on same-state landings, a 45/30/25
	--- split lands roughly:
	---   * Open        → ~45% of long-run uptime
	---   * Restricted  → ~30%
	---   * Closed      → ~25%
	---
	--- Add a state to `StateOrder` without listing it here and the roller
	--- defaults its weight to 1 (preserving the legacy uniform behavior).
	StateWeights = {
		Open = 45,
		Restricted = 30,
		Closed = 25,
	} :: { [StraitState]: number },

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
