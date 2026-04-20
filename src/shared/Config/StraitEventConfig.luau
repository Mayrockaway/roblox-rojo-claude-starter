--!strict

-- Tuning for waypoint strait events (Open / Restricted / Closed — same as engine `StraitConfig` states).

export type PublicStraitBracket = "Open" | "Restricted" | "Closed"

local StraitEventConfig = {
	-- Lane waypoint ordinals (sorted names under each route); path index = 1 + n (dock is path[1]).
	-- **Per-bracket allow-list.** Trigger slots for the voyage are still built from the
	-- *union* of these (so a mid-voyage bracket flip can still fire later waypoints) but
	-- `_handleStraitWaypointTrigger` short-circuits any waypoint whose ordinal is not in
	-- the *current* bracket's list. Authoring rule of thumb:
	--   * `Open` = quiet — fewer rolls, sparse spacing.
	--   * `Restricted` = mid — most waypoints, skips a couple.
	--   * `Closed` = full slate (all 8 lane waypoints).
	-- Update `docs/features/strait-waypoint-events/{EVENTS.md, SPEC.md}` when editing.
	LaneWaypointTriggers = {
		Open = { 3, 6, 9 },
		Restricted = { 3, 5, 6, 7, 9 },
		Closed = { 2, 3, 4, 5, 6, 7, 8, 9 },
	} :: { [PublicStraitBracket]: { number } },

	-- Universal hold at waypoint for strait VFX (events without a longer explicit pause).
	DefaultWaypointPauseSeconds = 5,
	-- Events that already had a dedicated “long” delay use this until tuned (see Catalog).
	ExtendedWaypointPauseSeconds = 10,

	-- P(trigger) at each trigger point, independent rolls.
	-- Tuned alongside `LaneWaypointTriggers` (3 / 5 / 8 rolls per bracket) to land on
	-- expected events per voyage of roughly Open ≈ 0.75, Restricted ≈ 2.0, Closed ≈ 4.0
	-- (P(zero events) ≈ 42% / 7.8% / 0.4%). Bumped from 0.15 / 0.30 / 0.50 after the
	-- Open / Restricted waypoint counts were trimmed so the per-bracket fantasy
	-- (Open = mostly clean, Restricted = consistently busy, Closed = chaotic) survives
	-- the smaller roll pools without each individual roll feeling oppressive.
	OccurrenceChance = {
		Open = 0.25,
		Restricted = 0.40,
		Closed = 0.50,
	} :: { [PublicStraitBracket]: number },

	-- Restricted: P(High | occurrence hit); of the remainder, P(Low) = this vs P(Medium) = 1 - this (Low-weighted).
	RestrictedHighChance = 0.10,
	RestrictedLowVersusMediumChance = 0.62, -- Low 62% / Medium 38% after High gate

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

-- Per-voyage candidate waypoints: union of every bracket's allow-list. We build
-- the trigger slot list from this so the voyage doesn't have to commit to a
-- bracket at start time — the per-trigger gate below decides whether to roll.
local _allTriggersCache: { number }? = nil
function StraitEventConfig.GetAllLaneWaypointTriggers(): { number }
	if _allTriggersCache then
		return _allTriggersCache
	end
	local seen: { [number]: boolean } = {}
	local out: { number } = {}
	for _, list in pairs(StraitEventConfig.LaneWaypointTriggers) do
		for _, n in ipairs(list) do
			if not seen[n] then
				seen[n] = true
				table.insert(out, n)
			end
		end
	end
	table.sort(out)
	_allTriggersCache = out
	return out
end

function StraitEventConfig.IsTriggerEnabledForBracket(
	bracket: PublicStraitBracket,
	laneWaypointIndex: number
): boolean
	local list = StraitEventConfig.LaneWaypointTriggers[bracket]
	if not list then
		return false
	end
	for _, n in ipairs(list) do
		if n == laneWaypointIndex then
			return true
		end
	end
	return false
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
