--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ShipmentConfig = require(Shared:WaitForChild("Config"):WaitForChild("ShipmentConfig"))

local Engine = {}

local function floorPositive(value: number): number
	return math.max(0, math.floor(value))
end

function Engine.BuildPlan(params)
	local rng = Random.new(params.seed)
	local baseSuccessChance = math.clamp(params.baseSuccessChance + params.escortBonus + params.durabilityBonus - params.sizePenalty, 0, 1)
	local hp = 1.0
	local events = {}
	local elapsed = 0

	local baseDuration = rng:NextNumber(params.minVoyageSeconds, params.maxVoyageSeconds)
	local chanceToStart = math.max(0, math.min(1, 1 - baseSuccessChance))
	local shouldContinue = rng:NextNumber() <= chanceToStart
	local eventCount = 0

	while shouldContinue and eventCount < ShipmentConfig.HardSafetyMaxEvents and hp > 0 do
		local eventId, eventData = Engine._rollEvent(rng)
		local travelGap = rng:NextNumber(ShipmentConfig.MinEventSpacingSeconds, ShipmentConfig.MaxEventSpacingSeconds)
		elapsed += travelGap
		eventCount += 1

		local damage = rng:NextNumber(eventData.damageMin, eventData.damageMax)
		local delay = rng:NextInteger(eventData.delayMin, eventData.delayMax)
		hp = math.max(0, hp - damage)

		table.insert(events, {
			index = eventCount,
			eventId = eventId,
			atOffsetSeconds = elapsed,
			damage = damage,
			delaySeconds = delay,
			hpAfter = hp,
		})

		baseDuration += delay
		shouldContinue = rng:NextNumber() <= params.eventContinuationChance
	end

	return {
		seed = params.seed,
		baseSuccessChance = baseSuccessChance,
		plannedDurationSeconds = math.max(1, baseDuration),
		events = events,
		hpAfterEvents = hp,
		destroyedByEvents = hp <= 0,
	}
end

function Engine.BuildDeliveredByTier(loadedByTier, hpPercent)
	local deliveredByTier = {}
	local deliveredTotal = 0
	local loadedTotal = 0
	local ratio = math.clamp(hpPercent, 0, 1)
	for tier, loaded in pairs(loadedByTier) do
		local loadedInt = floorPositive(loaded)
		local delivered = floorPositive(loadedInt * ratio)
		deliveredByTier[tier] = delivered
		deliveredTotal += delivered
		loadedTotal += loadedInt
	end

	return deliveredByTier, deliveredTotal, loadedTotal
end

function Engine._rollEvent(rng: Random)
	local totalWeight = 0
	for _, eventId in ipairs(ShipmentConfig.EventOrder) do
		totalWeight += ShipmentConfig.Events[eventId].weight
	end

	local roll = rng:NextNumber(0, totalWeight)
	local cursor = 0
	for _, eventId in ipairs(ShipmentConfig.EventOrder) do
		local data = ShipmentConfig.Events[eventId]
		cursor += data.weight
		if roll <= cursor then
			return eventId, data
		end
	end

	local fallback = ShipmentConfig.EventOrder[1]
	return fallback, ShipmentConfig.Events[fallback]
end

return Engine
