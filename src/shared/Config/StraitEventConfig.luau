--!strict

-- Tuning for waypoint strait events (Open / Restricted / Closed — same as engine `StraitConfig` states).

export type PublicStraitBracket = "Open" | "Restricted" | "Closed"

local StraitEventConfig = {
	-- Lane waypoint ordinals (sorted names under each route); path index = 1 + n (dock is path[1]).
	LaneWaypointTriggers = { 2, 3, 4, 5, 6, 7, 8, 9 } :: { number },

	-- Universal hold at waypoint for strait VFX (events without a longer explicit pause).
	DefaultWaypointPauseSeconds = 5,
	-- Events that already had a dedicated “long” delay use this until tuned (see Catalog).
	ExtendedWaypointPauseSeconds = 10,

	-- P(trigger) at each trigger point, independent rolls.
	OccurrenceChance = {
		Open = 0.15,
		Restricted = 0.40,
		Closed = 0.60,
	} :: { [PublicStraitBracket]: number },

	-- Restricted: P(High | hit); of the remainder, P(Low) = this and P(Medium) = 1 - this (Medium-weighted).
	RestrictedHighChance = 0.15,
	RestrictedLowVersusMediumChance = 0.45, -- Low 45% / Medium 55% after High gate

	-- Closed: P(Medium | hit); else High.
	ClosedMediumChance = 0.60,
}

function StraitEventConfig.PublicBracketFromEngineState(engineState: string): PublicStraitBracket
	if engineState == "Open" then
		return "Open"
	elseif engineState == "Closed" then
		return "Closed"
	elseif engineState == "Restricted" then
		return "Restricted"
	end
	-- Legacy persisted / debug strings (pre–3-state model)
	if engineState == "Tense" or engineState == "Dangerous" then
		return "Restricted"
	end
	if engineState == "Crisis" then
		return "Closed"
	end
	return "Open"
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
		return if rng:NextNumber() < StraitEventConfig.RestrictedLowVersusMediumChance then "Low" else "Medium"
	else
		return if rng:NextNumber() < StraitEventConfig.ClosedMediumChance then "Medium" else "High"
	end
end

return StraitEventConfig
