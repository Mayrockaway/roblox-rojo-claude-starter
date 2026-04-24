--!strict
-- Daily Free Drill configuration.
-- Server picks a random drill at midnight UTC (same for all players).
-- Players can claim once per 24h cycle. Unclaimed drills expire on reset.

local DailyDrillConfig = {}

--- Weighted drill pool. Higher tiers are rarer.
--- Weights are relative ratios (don't need to sum to 100).
DailyDrillConfig.Pool = {
	{ itemId = "drill_t1", weight = 40 },
	{ itemId = "drill_t2", weight = 25 },
	{ itemId = "drill_t3", weight = 18 },
	{ itemId = "drill_t4", weight = 10 },
	{ itemId = "drill_t5", weight = 5 },
	{ itemId = "drill_t6", weight = 2 },
}

--- Seconds in a cycle (24 hours).
DailyDrillConfig.CycleSeconds = 86400

--- Returns the current cycle start (midnight UTC) as a Unix timestamp.
function DailyDrillConfig.GetCurrentCycleStart(): number
	local now = os.time()
	return now - (now % DailyDrillConfig.CycleSeconds)
end

--- Returns seconds remaining in the current cycle.
function DailyDrillConfig.GetSecondsRemaining(): number
	local now = os.time()
	local cycleStart = DailyDrillConfig.GetCurrentCycleStart()
	return DailyDrillConfig.CycleSeconds - (now - cycleStart)
end

--- Deterministic pick: same drill for all players in the same cycle.
--- Uses the cycle start timestamp as a seed so the result is stable
--- for the full 24h window and reproducible on both server and client.
function DailyDrillConfig.GetCurrentDrill(): string
	local seed = DailyDrillConfig.GetCurrentCycleStart()
	local rng = Random.new(seed)

	local totalWeight = 0
	for _, entry in ipairs(DailyDrillConfig.Pool) do
		totalWeight += entry.weight
	end

	local roll = rng:NextNumber(0, totalWeight)
	local cursor = 0
	for _, entry in ipairs(DailyDrillConfig.Pool) do
		cursor += entry.weight
		if roll <= cursor then
			return entry.itemId
		end
	end
	-- Fallback (FP drift safety)
	return DailyDrillConfig.Pool[#DailyDrillConfig.Pool].itemId
end

return DailyDrillConfig
