--!strict
--- Pure math for economics session rows + dynamic cash-pack sizing.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local SessionEconomicsConfig = require(Shared:WaitForChild("Config"):WaitForChild("SessionEconomicsConfig"))

local SessionEconomics = {}

export type EconomicsSessionRow = {
	netOrganic: number,
	sessionSeconds: number,
	endedAt: number,
}

local function floorPositive(value: number): number
	return math.max(0, math.floor(value + 1e-6))
end

function SessionEconomics.roundToNice(amount: number, roundTo: number): number
	local rt = tonumber(roundTo) or 500
	if rt < 50 then
		rt = 50
	end
	return math.max(0, math.floor(amount / rt + 0.5) * rt)
end

--- Sum net organic earnings and weighted time from up to last N validated rows.
function SessionEconomics.totalsFromSessions(rows: { EconomicsSessionRow }): (number, number)
	local totalOrganic = 0
	local totalSec = 0
	if typeof(rows) ~= "table" then
		return totalOrganic, totalSec
	end
	for _, row in ipairs(rows) do
		if typeof(row) == "table" then
			local secs = tonumber((row :: any).sessionSeconds)
			local netOrg = tonumber((row :: any).netOrganic)
			if typeof(secs) == "number" and secs > 0 and typeof(netOrg) == "number" then
				totalOrganic += netOrg
				totalSec += secs
			end
		end
	end
	return totalOrganic, totalSec
end

--- Net cash earned per clock hour inferred from trailing sessions.
--- Falls back when history is thin or denominators absurd.
function SessionEconomics.estimateNetCashPerHour(rows: { EconomicsSessionRow }, currentCashFloor: number): number
	local totalOrganic, totalSec = SessionEconomics.totalsFromSessions(rows)
	local minHist =
		tonumber(SessionEconomicsConfig.MIN_TOTAL_HISTORY_SECONDS_FOR_TRUSTED_RATE)
	local fallbackBase = tonumber(SessionEconomicsConfig.FALLBACK_NET_CASH_PER_HOUR) or 15_000
	local mn = tonumber(SessionEconomicsConfig.MIN_NET_PER_HOUR) or 1
	local mx = tonumber(SessionEconomicsConfig.MAX_NET_PER_HOUR) or 1
	local frac = tonumber(SessionEconomicsConfig.CASH_HINT_FRACTION) or 0
	local hintMax = tonumber(SessionEconomicsConfig.CASH_HINT_MAX) or 0

	local hinted = fallbackBase + math.min(hintMax, floorPositive(currentCashFloor) * frac)

	if totalSec < (minHist or 1) then
		return math.clamp(hinted, mn, mx)
	end

	local hours = totalSec / 3600
	if hours < 1e-6 then
		return math.clamp(hinted, mn, mx)
	end

	local perHour = totalOrganic / hours
	if perHour ~= perHour then
		perHour = 0 :: any
	end
	if math.abs(perHour) < mn / 100 then
		return math.clamp(hinted, mn, mx)
	end

	perHour = math.clamp(perHour, mn, mx)
	local blend = math.clamp(totalSec / (minHist :: number), 0, 1)
	return hinted * (1 - blend) + perHour * blend
end

--- Single pack cash amount given effective $/hour and tier name (`"small"|"medium"|"large"`).
function SessionEconomics.cashGrantForTier(effectiveHourlyRate: number, tier: string): number
	local tiers = SessionEconomicsConfig.PACK_TARGET_MINUTES
	local minutes = tonumber(tiers[tier])
	if typeof(minutes) ~= "number" or minutes <= 0 then
		minutes = 12
	end
	local raw = tonumber(effectiveHourlyRate)
	if typeof(raw) ~= "number" or raw ~= raw then
		raw = SessionEconomicsConfig.FALLBACK_NET_CASH_PER_HOUR
	end
	raw = math.clamp(raw, SessionEconomicsConfig.MIN_NET_PER_HOUR, SessionEconomicsConfig.MAX_NET_PER_HOUR)

	local amt = raw * (minutes / 60)
	local hm = SessionEconomicsConfig.PACK_HARD_MIN
	local hmax = SessionEconomicsConfig.PACK_HARD_MAX
	if typeof(hm) == "table" and typeof((hm :: any)[tier]) == "number" then
		amt = math.max(amt, (hm :: any)[tier])
	end
	if typeof(hmax) == "table" and typeof((hmax :: any)[tier]) == "number" then
		amt = math.min(amt, (hmax :: any)[tier])
	end
	amt = SessionEconomics.roundToNice(amt, SessionEconomicsConfig.ROUND_TO)
	local hardMin = tonumber((hm :: any)[tier]) or 1
	local hardMax = tonumber((hmax :: any)[tier]) or amt
	return math.clamp(floorPositive(amt), hardMin, math.max(hardMin, hardMax))
end

return SessionEconomics
