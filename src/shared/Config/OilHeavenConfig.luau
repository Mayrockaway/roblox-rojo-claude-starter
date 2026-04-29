--!strict
--- Configuration for the Oil Heaven rebirth sky-island tile grid.
--- Each player's Oil Heaven plot is generated at Y=3000 above their main plot.
--- The grid is 3 columns × 3 rows per section (5 sections), for 45 tiles total.
--- Sections unlock progressively as the player's rebirth count increases.
--- A small gap separates each section so players must jump between them.

local OilHeavenConfig = {
	TileSize = 20, -- studs per tile side (square tiles)
	Columns = 3, -- tiles per row
	RowsPerSection = 3, -- tiles per section vertically
	SectionGap = 5, -- studs of empty space between sections (jumpable)

	--- Ordered top-to-bottom. `rebirthRequired` = minimum rebirth count to unlock.
	--- Every other rebirth unlocks the next 3×6 chunk.
	Sections = {
		{ id = "S1", rebirthRequired = 1, color = Color3.fromRGB(255, 200, 0) },   -- yellow
		{ id = "S2", rebirthRequired = 3, color = Color3.fromRGB(255, 100, 0) },   -- orange
		{ id = "S3", rebirthRequired = 5, color = Color3.fromRGB(255, 0, 150) },   -- pink
		{ id = "S4", rebirthRequired = 7, color = Color3.fromRGB(0, 255, 100) },   -- green
		{ id = "S5", rebirthRequired = 9, color = Color3.fromRGB(80, 0, 255) },    -- purple
	},

	--- Visual treatment for tiles in locked sections.
	LockedTileTransparency = 0.6,
	LockedTileMaterial = Enum.Material.SmoothPlastic,
	UnlockedTileMaterial = Enum.Material.SmoothPlastic,

	--- Barrier walls placed at the boundary between the last unlocked section
	--- and the first locked section. Prevents walking into locked areas.
	BarrierHeight = 12,
	BarrierThickness = 1,
	BarrierColor = Color3.fromRGB(80, 80, 80),
	BarrierTransparency = 0.3,

	--- Base platform underneath the tile grid (floating-island slab).
	BasePlatformOverhang = 4, -- studs wider than grid on each side
	BasePlatformThickness = 4,
	BasePlatformColor = Color3.fromRGB(120, 100, 80),
	BasePlatformMaterial = Enum.Material.Rock,

	--- Spawn offset above the ClaimPad when teleporting to Oil Heaven.
	SpawnHeightOffset = 5,

	--- Sky box enclosure around the plot. Simulates a heaven environment
	--- so the player can't see the ground or the real skybox.
	SkyBox = {
		Size = 500, -- studs: half-extent of the cube (so 1000x1000x1000 total)
		WallColor = Color3.fromRGB(220, 235, 255), -- soft heavenly blue-white
		WallMaterial = Enum.Material.Neon,
		WallTransparency = 0,
		CeilingColor = Color3.fromRGB(255, 248, 220), -- warm golden glow
		FloorColor = Color3.fromRGB(200, 215, 240), -- soft cloud-floor blue
		FloorTransparency = 0.15, -- slightly translucent so it feels airy
	},

	--- BGM for Oil Heaven. Replace with actual heaven music asset id.
	HeavenBgmSoundId = "rbxassetid://104020720458851",
	HeavenBgmVolume = 0.07,
}

return OilHeavenConfig
