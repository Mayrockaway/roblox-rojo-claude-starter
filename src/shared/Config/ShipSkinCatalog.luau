--!strict
-- Cosmetic ship skins only. Gameplay stats must never be read from this module.

export type RigDef = {
	dockAnchorName: string,
	frontMarkerName: string,
	deckAnchorName: string,
	deckTopAnchorName: string,
	deckYOffsetFallback: number,
	deckSeatName: string,
	barrelStackRootName: string,
	playerFlagName: string,
}

export type RigOverride = {
	dockAnchorName: string?,
	frontMarkerName: string?,
	deckAnchorName: string?,
	deckTopAnchorName: string?,
	deckYOffsetFallback: number?,
	deckSeatName: string?,
	barrelStackRootName: string?,
	playerFlagName: string?,
}

export type SkinDef = {
	displayName: string,
	templateName: string,
	fxParticleScale: number?,
	rarityDisplay: string?,
	rig: RigOverride?,
}

local DEFAULT_RIG: RigDef = {
	dockAnchorName = "DockAnchor",
	frontMarkerName = "FRONT_MARKER",
	deckAnchorName = "DeckAnchor",
	deckTopAnchorName = "DeckTopAnchor",
	deckYOffsetFallback = 15,
	deckSeatName = "DeckSeat",
	barrelStackRootName = "BarrelStackRoot",
	playerFlagName = "PlayerFlag",
}

local TEMPLATE_RIG_OVERRIDES: { [string]: RigOverride } = {
	-- Per-template placement semantics. Override these when a hull does not match Tanker defaults.
	Tanker = {
		deckYOffsetFallback = 15,
	},
	Ship3 = {
		deckYOffsetFallback = 15,
	},
	Ship4 = {
		deckYOffsetFallback = 15,
	},
	Ship5 = {
		deckYOffsetFallback = 15,
	},
}

local function applyRigOverride(rig: RigDef, over: RigOverride?)
	if not over then
		return
	end
	if typeof(over.dockAnchorName) == "string" and over.dockAnchorName ~= "" then
		rig.dockAnchorName = over.dockAnchorName
	end
	if typeof(over.frontMarkerName) == "string" and over.frontMarkerName ~= "" then
		rig.frontMarkerName = over.frontMarkerName
	end
	if typeof(over.deckAnchorName) == "string" and over.deckAnchorName ~= "" then
		rig.deckAnchorName = over.deckAnchorName
	end
	if typeof(over.deckTopAnchorName) == "string" and over.deckTopAnchorName ~= "" then
		rig.deckTopAnchorName = over.deckTopAnchorName
	end
	if typeof(over.deckYOffsetFallback) == "number" then
		rig.deckYOffsetFallback = over.deckYOffsetFallback
	end
	if typeof(over.deckSeatName) == "string" and over.deckSeatName ~= "" then
		rig.deckSeatName = over.deckSeatName
	end
	if typeof(over.barrelStackRootName) == "string" and over.barrelStackRootName ~= "" then
		rig.barrelStackRootName = over.barrelStackRootName
	end
	if typeof(over.playerFlagName) == "string" and over.playerFlagName ~= "" then
		rig.playerFlagName = over.playerFlagName
	end
end

local function buildRig(templateName: string, skinRigOverride: RigOverride?): RigDef
	local rig: RigDef = {
		dockAnchorName = DEFAULT_RIG.dockAnchorName,
		frontMarkerName = DEFAULT_RIG.frontMarkerName,
		deckAnchorName = DEFAULT_RIG.deckAnchorName,
		deckTopAnchorName = DEFAULT_RIG.deckTopAnchorName,
		deckYOffsetFallback = DEFAULT_RIG.deckYOffsetFallback,
		deckSeatName = DEFAULT_RIG.deckSeatName,
		barrelStackRootName = DEFAULT_RIG.barrelStackRootName,
		playerFlagName = DEFAULT_RIG.playerFlagName,
	}
	applyRigOverride(rig, TEMPLATE_RIG_OVERRIDES[templateName])
	applyRigOverride(rig, skinRigOverride)
	return rig
end

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

function ShipSkinCatalog.GetRigForTemplate(templateName: string?): RigDef
	local name = if typeof(templateName) == "string" and templateName ~= "" then templateName else "Tanker"
	return buildRig(name, nil)
end

function ShipSkinCatalog.GetRigForSkin(skinId: string?): RigDef
	local skin = ShipSkinCatalog.GetSkin(skinId)
	return buildRig(skin.templateName, skin.rig)
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
