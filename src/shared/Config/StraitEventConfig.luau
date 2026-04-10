--!strict

-- Tuning for waypoint strait events (Open / Restricted / Closed buckets).
-- Engine states Tense, Dangerous, Crisis map to Restricted; see PublicBracketFromEngineState.

export type PublicStraitBracket = "Open" | "Restricted" | "Closed"

local StraitEventConfig = {
	-- Lane waypoint ordinals (sorted names under each route); path index = 1 + n (dock is path[1]).
	LaneWaypointTriggers = { 3, 6, 9 } :: { number },

	DefaultWaypointPauseSeconds = 3,

	-- P(trigger) at each trigger point, independent rolls.
	OccurrenceChance = {
		Open = 0.10,
		Restricted = 0.50,
		Closed = 0.80,
	} :: { [PublicStraitBracket]: number },

	-- Restricted: P(High | hit); remainder splits 50/50 Low vs Medium.
	RestrictedHighChance = 0.25,

	-- Closed: P(Medium | hit); else High.
	ClosedMediumChance = 0.50,
}

function StraitEventConfig.PublicBracketFromEngineState(engineState: string): PublicStraitBracket
	if engineState == "Open" then
		return "Open"
	elseif engineState == "Closed" then
		return "Closed"
	end
	return "Restricted"
end

function StraitEventConfig.GetOccurrenceChance(bracket: PublicStraitBracket): number
	return StraitEventConfig.OccurrenceChance[bracket]
end

function StraitEventConfig.RollSeverity(bracket: PublicStraitBracket, rng: Random): "Low" | "Medium" | "High"
	if bracket == "Open" then
		return "Low"
	elseif bracket == "Restricted" then
		if rng:NextNumber() < StraitEventConfig.RestrictedHighChance then
			return "High"
		end
		return if rng:NextNumber() < 0.5 then "Low" else "Medium"
	else
		return if rng:NextNumber() < StraitEventConfig.ClosedMediumChance then "Medium" else "High"
	end
end

return StraitEventConfig
