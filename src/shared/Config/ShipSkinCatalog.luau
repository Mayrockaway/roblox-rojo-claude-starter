--!strict
-- Cosmetic ship skins only. Gameplay stats must never be read from this module.

export type SkinDef = {
	displayName: string,
	templateName: string,
	fxParticleScale: number?,
	rarityDisplay: string?,
}

local ShipSkinCatalog = {
	Skins = {
		DefaultTanker = {
			displayName = "Standard Tanker",
			templateName = "Tanker",
			fxParticleScale = 1,
			rarityDisplay = "Common",
		},
		RustSkiffSkin = {
			displayName = "Rust Skiff",
			templateName = "Tanker",
			fxParticleScale = 1,
			rarityDisplay = "Common",
		},
		HaulerSkin = {
			displayName = "Hauler",
			templateName = "Tanker",
			fxParticleScale = 1,
			rarityDisplay = "Uncommon",
		},
		ArmoredSkin = {
			displayName = "Armored Tanker",
			templateName = "Tanker",
			fxParticleScale = 1.05,
			rarityDisplay = "Rare",
		},
		Ship3Skin = {
			displayName = "Ship 3",
			templateName = "Ship3",
			fxParticleScale = 1,
			rarityDisplay = "Uncommon",
		},
		Ship4Skin = {
			displayName = "Ship 4",
			templateName = "Ship4",
			fxParticleScale = 1,
			rarityDisplay = "Rare",
		},
		Ship5Skin = {
			displayName = "Ship 5",
			templateName = "Ship5",
			fxParticleScale = 1,
			rarityDisplay = "Epic",
		},
	} :: { [string]: SkinDef },
}

function ShipSkinCatalog.GetSkin(skinId: string?): SkinDef
	local id = if typeof(skinId) == "string" and skinId ~= "" then skinId else "DefaultTanker"
	local s = ShipSkinCatalog.Skins[id]
	if s then
		return s
	end
	return ShipSkinCatalog.Skins.DefaultTanker
end

function ShipSkinCatalog.ListForClient(): { { skinId: string, displayName: string, rarityDisplay: string? } }
	local list = {}
	for skinId, def in pairs(ShipSkinCatalog.Skins) do
		table.insert(list, {
			skinId = skinId,
			displayName = def.displayName,
			rarityDisplay = def.rarityDisplay,
		})
	end
	table.sort(list, function(a, b)
		return a.displayName < b.displayName
	end)
	return list
end

return ShipSkinCatalog
