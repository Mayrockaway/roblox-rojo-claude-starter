--!strict
-- Maps legacy `selectedBoatTypeId` (pre–player-ship v4) into skin + starting upgrade levels.

export type MigrationResult = {
	skinId: string,
	speedLevel: number,
	capacityLevel: number,
}

local ShipProfileMigration = {}

-- Tuned so returning players keep sensible upgrade levels vs old “biggest boat” fantasy.
-- The `RustSkiffSkin` / `HaulerSkin` / `ArmoredSkin` placeholder skins were
-- removed from `ShipSkinCatalog`; legacy profiles that referenced those
-- boat type ids fall back to `DefaultTanker` here while keeping the upgrade
-- levels they had earned, so a returning player isn't dumped to level 1
-- with a downgraded hull.
local LEGACY: { [string]: MigrationResult } = {
	RustSkiff = { skinId = "DefaultTanker", speedLevel = 2, capacityLevel = 4 },
	Hauler = { skinId = "DefaultTanker", speedLevel = 5, capacityLevel = 14 },
	ArmoredTanker = { skinId = "DefaultTanker", speedLevel = 8, capacityLevel = 22 },
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
