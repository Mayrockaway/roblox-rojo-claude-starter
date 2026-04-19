--!strict
-- Client-only UX for Ship Management panel. Gameplay stats are unchanged.

local ShipManagementUiConfig = {
	--- When **true**, the ship `ViewportFrame` clones the full gameplay hull from `ReplicatedStorage.Assets`
	--- (heavy Union rigs → large hitches). When **false** (default), the panel uses **`ShipViewportPreviewFactory`**
	--- plus optional authored models under **`Assets.ShipViewportPreviews`**.
	UseGameplayHullInViewport = false,
}

return ShipManagementUiConfig
