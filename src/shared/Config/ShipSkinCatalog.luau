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
	standForwardOffset: number,
	standRightOffset: number,
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
	standForwardOffset: number?,
	standRightOffset: number?,
}

export type SkinDef = {
	displayName: string,
	templateName: string,
	fxParticleScale: number?,
	rarityDisplay: string?,
	rig: RigOverride?,
	--- 2D icon for the Ship Management hero slot + Select Ship card slot
	--- (post-viewport-swap). Painted into the `ImageLabel` shell by
	--- `ShipManagementPanel.applyOilState` and `SelectShipPopulate.Apply`.
	--- When `nil` the slot stays as the empty grey shell so a missing icon is
	--- visually obvious in Studio rather than crashing the panel.
	icon: string?,
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
	standForwardOffset = -5,
	standRightOffset = 4,
}

local TEMPLATE_RIG_OVERRIDES: { [string]: RigOverride } = {
	-- Per-template placement semantics. Override these when a hull does not match Tanker defaults.
	Tanker = {
		deckYOffsetFallback = 15,
	},
	Raft = {
		deckYOffsetFallback = 15,
	},
	PirateShip = {
		deckYOffsetFallback = 15,
	},
	Ducky = {
		deckYOffsetFallback = 15,
	},
	Whale = {
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
	if typeof(over.standForwardOffset) == "number" then
		rig.standForwardOffset = over.standForwardOffset
	end
	if typeof(over.standRightOffset) == "number" then
		rig.standRightOffset = over.standRightOffset
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
		standForwardOffset = DEFAULT_RIG.standForwardOffset,
		standRightOffset = DEFAULT_RIG.standRightOffset,
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
			icon = "rbxassetid://110257950618296",
		},
		Ship3Skin = {
			displayName = "Raft",
			templateName = "Raft",
			fxParticleScale = 1,
			rarityDisplay = "Uncommon",
			-- icon: not yet authored — slot renders as empty grey shell.
		},
		Ship4Skin = {
			displayName = "The Sparrow",
			templateName = "PirateShip",
			fxParticleScale = 1,
			rarityDisplay = "Epic",
			icon = "rbxassetid://80699672548624",
		},
		Ship5Skin = {
			displayName = "Jet Duck",
			templateName = "Ducky",
			fxParticleScale = 1,
			rarityDisplay = "Legendary",
			icon = "rbxassetid://122817352338651",
		},
		WhaleSkin = {
			displayName = "Moby",
			templateName = "Whale",
			fxParticleScale = 1.2,
			rarityDisplay = "Legendary",
			icon = "rbxassetid://77447218245868",
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
