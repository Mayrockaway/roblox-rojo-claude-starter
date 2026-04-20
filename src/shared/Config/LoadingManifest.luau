--!strict

local EquipmentCatalog = require(script.Parent:WaitForChild("EquipmentCatalog"))
local ShipSkinCatalog = require(script.Parent:WaitForChild("ShipSkinCatalog"))
local FtuePoiBeamConfig = require(script.Parent:WaitForChild("FtuePoiBeamConfig"))
local VeinCrateConfig = require(script.Parent:WaitForChild("VeinCrateConfig"))

export type LoadingPhase = "blocking_core" | "blocking_bulk" | "deferred"
export type LoadingGroupKind = "instance_tree" | "instance_list" | "image_uris" | "content_ids"

export type InstanceEntry = {
	service: string,
	segments: { string }?,
	includeDescendants: boolean?,
	optional: boolean?,
}

export type LoadingGroup = {
	id: string,
	label: string,
	phase: LoadingPhase,
	weight: number,
	kind: LoadingGroupKind,
	optional: boolean?,
	entries: { InstanceEntry }?,
	uris: { string }?,
	contentIds: { string }?,
}

local LoadingManifest = {}

local function toImageUri(raw: string?): string?
	if typeof(raw) ~= "string" or raw == "" then
		return nil
	end
	if raw:match("^rbxthumb://") or raw:match("^rbxasset://") or raw:match("^http") then
		return raw
	end
	local id = raw:match("rbxassetid://(%d+)") or raw:match("^(%d+)$")
	if id then
		return string.format("rbxthumb://type=Asset&id=%s&w=150&h=150", id)
	end
	return raw
end

local function collectCommonUiImageUris(): { string }
	local seen: { [string]: boolean } = {}
	local out: { string } = {}

	local function add(raw: string?)
		local uri = toImageUri(raw)
		if uri and not seen[uri] then
			seen[uri] = true
			table.insert(out, uri)
		end
	end

	for _, row in ipairs(EquipmentCatalog.getAllRows()) do
		add((row :: any).iconAssetId)
	end

	for _, skin in pairs(ShipSkinCatalog.Skins) do
		add((skin :: any).icon)
	end

	return out
end

local function collectFtueGuidanceUris(): { string }
	local seen: { [string]: boolean } = {}
	local out: { string } = {}

	local function add(raw: string?)
		if typeof(raw) == "string" and raw ~= "" and not seen[raw] then
			seen[raw] = true
			table.insert(out, raw)
		end
	end

	add("rbxassetid://94844325087717")
	for _, rule in FtuePoiBeamConfig.Rules do
		for _, target in rule.targets do
			local style = (target :: any).style
			if typeof(style) == "table" then
				add((style :: any).texture)
			end
		end
	end

	return out
end

local function collectVeinCrateStaticUris(): { string }
	local seen: { [string]: boolean } = {}
	local out: { string } = {}

	local function add(raw: string?)
		if typeof(raw) == "string" and raw ~= "" and raw ~= "rbxassetid://0" and not seen[raw] then
			seen[raw] = true
			table.insert(out, raw)
		end
	end

	for _, def in ipairs(VeinCrateConfig.VeinTypes) do
		local sprite = VeinCrateConfig.GetDisplaySprite(def, "Bronze")
		add(sprite and sprite.imageId or nil)
	end

	if VeinCrateConfig.RarityBackgroundAssets then
		for _, bgId in pairs(VeinCrateConfig.RarityBackgroundAssets) do
			add(bgId)
		end
	end

	return out
end

local COMMON_STARTER_GUI_ENTRIES: { InstanceEntry } = {
	{ service = "StarterGui", segments = { "HUD" }, includeDescendants = true, optional = true },
	{ service = "StarterGui", segments = { "SellOilPanelGui" }, includeDescendants = true, optional = true },
	{ service = "StarterGui", segments = { "ShipOilPanelGui" }, includeDescendants = true, optional = true },
	{ service = "StarterGui", segments = { "ShipManagementPanelGui" }, includeDescendants = true, optional = true },
	{ service = "StarterGui", segments = { "SelectShipPanelGui" }, includeDescendants = true, optional = true },
	{ service = "StarterGui", segments = { "Settings" }, includeDescendants = true, optional = true },
	{ service = "StarterGui", segments = { "FTUEDialogueGui" }, includeDescendants = true, optional = true },
	{ service = "StarterGui", segments = { "FtueDialogueGui" }, includeDescendants = true, optional = true },
	{ service = "StarterGui", segments = { "OilPriceInfoPanelGui" }, includeDescendants = true, optional = true },
	{ service = "StarterGui", segments = { "StraitInfoPanelGui" }, includeDescendants = true, optional = true },
}

local COMMON_GAMEPLAY_TEMPLATE_ENTRIES: { InstanceEntry } = {
	{ service = "ReplicatedStorage", segments = { "Assets", "Drill_T1" }, optional = true },
	{ service = "ReplicatedStorage", segments = { "Assets", "Drill_T2" }, optional = true },
	{ service = "ReplicatedStorage", segments = { "Assets", "Drill_T3" }, optional = true },
	{ service = "ReplicatedStorage", segments = { "Assets", "Drill_T4" }, optional = true },
	{ service = "ReplicatedStorage", segments = { "Assets", "Drill_T5" }, optional = true },
	{ service = "ReplicatedStorage", segments = { "Assets", "Drill_T6" }, optional = true },
	{ service = "ReplicatedStorage", segments = { "Assets", "Pump_T1" }, optional = true },
	{ service = "ReplicatedStorage", segments = { "Assets", "Pump_T2" }, optional = true },
	{ service = "ReplicatedStorage", segments = { "Assets", "Pump_T3" }, optional = true },
	{ service = "ReplicatedStorage", segments = { "Assets", "Barrel_Crude" }, optional = true },
	{ service = "ReplicatedStorage", segments = { "Assets", "Barrel_Refined" }, optional = true },
	{ service = "ReplicatedStorage", segments = { "Assets", "Barrel_Premium" }, optional = true },
	{ service = "ReplicatedStorage", segments = { "Assets", "OilTanksTemplate" }, optional = true },
	{ service = "ReplicatedStorage", segments = { "Assets", "ConveyorBelt" }, optional = true },
	{ service = "ReplicatedStorage", segments = { "Assets", "PlotTemplate" }, optional = true },
}

local COMMON_WORLD_FX_ENTRIES: { InstanceEntry } = {
	{ service = "ReplicatedStorage", segments = { "Assets", "OilSpray_Crude" }, optional = true },
	{ service = "ReplicatedStorage", segments = { "Assets", "OilSpray_Refined" }, optional = true },
	{ service = "ReplicatedStorage", segments = { "Assets", "OilSpray_Premium" }, optional = true },
	{ service = "ReplicatedStorage", segments = { "Assets", "DrillComplete" }, optional = true },
	{ service = "ReplicatedStorage", segments = { "Assets", "PlotDispatch" }, optional = true },
	{ service = "Lighting", includeDescendants = true, optional = true },
	{ service = "MaterialService", includeDescendants = true, optional = true },
}

local DEFERRED_RARE_EVENT_ENTRIES: { InstanceEntry } = {
	{ service = "ReplicatedStorage", segments = { "Assets", "StraitWaypointsFx" }, includeDescendants = true, optional = true },
	{ service = "ReplicatedStorage", segments = { "Assets", "PirateShip" }, optional = true },
	{ service = "ReplicatedStorage", segments = { "Assets", "CoastGuardShip" }, optional = true },
	{ service = "ReplicatedStorage", segments = { "Assets", "USShip" }, optional = true },
	{ service = "ReplicatedStorage", segments = { "Assets", "Whale" }, optional = true },
	{ service = "ReplicatedStorage", segments = { "Assets", "Kraken" }, optional = true },
	{ service = "ReplicatedStorage", segments = { "Assets", "KrakenTentacle" }, optional = true },
	{ service = "ReplicatedStorage", segments = { "Assets", "Missile" }, optional = true },
	{ service = "ReplicatedStorage", segments = { "Assets", "Mine" }, optional = true },
	{ service = "ReplicatedStorage", segments = { "Assets", "Jet" }, optional = true },
	{ service = "ReplicatedStorage", segments = { "Assets", "MushroomCloud" }, optional = true },
	{ service = "ReplicatedStorage", segments = { "Assets", "Ducky" }, optional = true },
	{ service = "ReplicatedStorage", segments = { "Assets", "GiantArm" }, optional = true },
}

local DEFERRED_NPC_VOICE_IDS = {
	"rbxassetid://89531954562344",
	"rbxassetid://90371105771118",
	"rbxassetid://138131180590743",
	"rbxassetid://79816242917775",
	"rbxassetid://97435698809776",
	"rbxassetid://118898048174911",
	"rbxassetid://119794938028444",
}

local DEFERRED_CRATE_SOUND_IDS = {
	"rbxassetid://132417511885299",
	"rbxassetid://102778985624056",
}

local GROUPS: { LoadingGroup } = {
	{
		id = "LoadingShell",
		label = "Loading screen",
		phase = "blocking_core",
		weight = 0.05,
		kind = "image_uris",
		uris = { "rbxassetid://94495457583750" },
	},
	{
		id = "CoreHudUi",
		label = "HUD",
		phase = "blocking_core",
		weight = 0.25,
		kind = "instance_tree",
		entries = COMMON_STARTER_GUI_ENTRIES,
	},
	{
		id = "CommonUiIcons",
		label = "UI icons",
		phase = "blocking_core",
		weight = 0.2,
		kind = "image_uris",
		uris = collectCommonUiImageUris(),
	},
	{
		id = "CoreAudio",
		label = "audio",
		phase = "blocking_core",
		weight = 0.15,
		kind = "instance_tree",
		entries = {
			{ service = "ReplicatedStorage", segments = { "Assets", "SFX" }, includeDescendants = true, optional = true },
		},
	},
	{
		id = "FtueGuidance",
		label = "guidance",
		phase = "blocking_core",
		weight = 0.1,
		kind = "image_uris",
		uris = collectFtueGuidanceUris(),
	},
	{
		id = "CommonGameplayTemplates",
		label = "gameplay assets",
		phase = "blocking_bulk",
		weight = 0.15,
		kind = "instance_list",
		entries = COMMON_GAMEPLAY_TEMPLATE_ENTRIES,
	},
	{
		id = "CommonWorldFx",
		label = "world FX",
		phase = "blocking_bulk",
		weight = 0.05,
		kind = "instance_tree",
		entries = COMMON_WORLD_FX_ENTRIES,
	},
	{
		id = "ShipPreviewAssets",
		label = "ship previews",
		phase = "blocking_bulk",
		weight = 0.05,
		kind = "instance_tree",
		optional = true,
		entries = {
			{ service = "ReplicatedStorage", segments = { "Assets", "ShipViewportPreviews" }, includeDescendants = true, optional = true },
		},
	},
	{
		id = "DeferredNpcVoices",
		label = "npc voices",
		phase = "deferred",
		weight = 0,
		kind = "content_ids",
		optional = true,
		contentIds = DEFERRED_NPC_VOICE_IDS,
	},
	{
		id = "DeferredCrateMedia",
		label = "crate media",
		phase = "deferred",
		weight = 0,
		kind = "image_uris",
		optional = true,
		uris = collectVeinCrateStaticUris(),
		contentIds = DEFERRED_CRATE_SOUND_IDS,
	},
	{
		id = "DeferredRareEventFx",
		label = "rare event FX",
		phase = "deferred",
		weight = 0,
		kind = "instance_tree",
		optional = true,
		entries = DEFERRED_RARE_EVENT_ENTRIES,
	},
}

function LoadingManifest.getGroups(): { LoadingGroup }
	return GROUPS
end

return LoadingManifest
