--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ShipmentEngine = require(script.Parent.Parent:WaitForChild("Domain"):WaitForChild("DeterministicShipmentEngine"))
local StraitConfig = require(Shared:WaitForChild("Config"):WaitForChild("StraitConfig"))

local SelfTest = {}

function SelfTest.Run()
	local params = {
		seed = 1234567,
		baseSuccessChance = StraitConfig.States.Open.baseSuccessChance,
		escortBonus = 0.10,
		durabilityBonus = 0.05,
		sizePenalty = 0.1,
		minVoyageSeconds = 10,
		maxVoyageSeconds = 25,
		eventContinuationChance = StraitConfig.States.Open.eventContinuationChance,
	}

	local a = ShipmentEngine.BuildPlan(params)
	local b = ShipmentEngine.BuildPlan(params)
	assert(a.plannedDurationSeconds == b.plannedDurationSeconds, "Deterministic duration mismatch.")
	assert(#a.events == #b.events, "Deterministic event count mismatch.")

	local deliveredByTier, deliveredTotal = ShipmentEngine.BuildDeliveredByTier({
		HeavyCrude = 20,
		PremiumRefined = 10,
	})
	assert(deliveredByTier.HeavyCrude == 20, "Delivered tier should match loaded when not destroyed.")
	assert(deliveredByTier.PremiumRefined == 10, "Delivered tier should match loaded when not destroyed.")
	assert(deliveredTotal == 30, "Delivered total should equal loaded total.")
end

return SelfTest
