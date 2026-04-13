--!strict
-- Maps legacy `selectedBoatTypeId` (pre–player-ship v4) into skin + starting upgrade levels.

export type MigrationResult = {
	skinId: string,
	speedLevel: number,
	capacityLevel: number,
}

local ShipProfileMigration = {}

-- Tuned so returning players keep sensible upgrade levels vs old “biggest boat” fantasy.
local LEGACY: { [string]: MigrationResult } = {
	RustSkiff = { skinId = "RustSkiffSkin", speedLevel = 2, capacityLevel = 4 },
	Hauler = { skinId = "HaulerSkin", speedLevel = 5, capacityLevel = 14 },
	ArmoredTanker = { skinId = "ArmoredSkin", speedLevel = 8, capacityLevel = 22 },
}

function ShipProfileMigration.FromLegacyBoatTypeId(legacyBoatTypeId: string?): MigrationResult
	if typeof(legacyBoatTypeId) == "string" then
		local m = LEGACY[legacyBoatTypeId]
		if m then
			return m
		end
	end
	return { skinId = "DefaultTanker", speedLevel = 1, capacityLevel = 1 }
end

function ShipProfileMigration.SkinIdForLegacyBoatTypeId(legacyBoatTypeId: string?): string?
	if typeof(legacyBoatTypeId) ~= "string" then
		return nil
	end
	local m = LEGACY[legacyBoatTypeId]
	if m then
		return m.skinId
	end
	return nil
end

return ShipProfileMigration
