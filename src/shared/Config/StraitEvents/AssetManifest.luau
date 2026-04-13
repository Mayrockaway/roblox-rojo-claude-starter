--!strict

export type EventAssetSpec = {
	folderName: string,
	expectedInstances: { string },
}

local AssetManifest = {}

AssetManifest.Events = {
	Storm = {
		folderName = "Storm",
		expectedInstances = {
			"CloudRig",
			"RainHandler",
			"RainLoopSfx",
			"ThunderSfx",
			"LightningSfx",
		},
	} :: EventAssetSpec,
	Tornado = {
		folderName = "Tornado",
		expectedInstances = {
			"FunnelRig",
			"WindLoopSfx",
			"DebrisEmitter",
		},
	} :: EventAssetSpec,
} :: { [string]: EventAssetSpec }

return AssetManifest
