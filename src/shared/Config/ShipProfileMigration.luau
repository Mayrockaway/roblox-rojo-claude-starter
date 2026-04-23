--!strict
-- Maps legacy `selectedBoatTypeId` (pre–player-ship v4) into boat id + starting upgrade levels.
--
-- Naming note (Step 7 boat-progression consolidation): the retired hull ids
-- now fall back to `Tier1Boat` (the new starter, was `DefaultTanker` until
-- Step 7). The placeholder skins (`RustSkiffSkin`, `HaulerSkin`,
-- `ArmoredSkin`) were never shipped and v < 4 profiles only ever stored
-- `selectedBoatTypeId`. The `speedLevel` / `capacityLevel` fields on the
-- result are kept for shape compatibility with v < 4 readers but are
-- ignored by the v >= 8 loader (boats own those numbers now via
-- `BoatCatalog.Boats[id].speedLevel` / `capacityLevel`).

export type MigrationResult = {
	boatId: string,
	speedLevel: number,
	capacityLevel: number,
}

local ShipProfileMigration = {}

-- Tuned so returning players keep sensible upgrade levels vs old "biggest boat" fantasy.
-- The `RustSkiffSkin` / `HaulerSkin` / `ArmoredSkin` placeholder skins were
-- removed from `BoatCatalog`; legacy profiles that referenced those boat
-- type ids fall back to `Tier1Boat` here while keeping the upgrade
-- levels they had earned, so a returning player isn't dumped to level 1
-- with a downgraded hull. (The `speedLevel` / `capacityLevel` numbers are
-- ignored by the v >= 8 loader anyway — boat stats are baked per-id now.)
local LEGACY: { [string]: MigrationResult } = {
	RustSkiff = { boatId = "Tier1Boat", speedLevel = 2, capacityLevel = 4 },
	Hauler = { boatId = "Tier1Boat", speedLevel = 5, capacityLevel = 14 },
	ArmoredTanker = { boatId = "Tier1Boat", speedLevel = 8, capacityLevel = 22 },
}

function ShipProfileMigration.FromLegacyBoatTypeId(legacyBoatTypeId: string?): MigrationResult
	if typeof(legacyBoatTypeId) == "string" then
		local m = LEGACY[legacyBoatTypeId]
		if m then
			return m
		end
	end
	return { boatId = "Tier1Boat", speedLevel = 1, capacityLevel = 1 }
end

function ShipProfileMigration.BoatIdForLegacyBoatTypeId(legacyBoatTypeId: string?): string?
	if typeof(legacyBoatTypeId) ~= "string" then
		return nil
	end
	local m = LEGACY[legacyBoatTypeId]
	if m then
		return m.boatId
	end
	return nil
end

return ShipProfileMigration
