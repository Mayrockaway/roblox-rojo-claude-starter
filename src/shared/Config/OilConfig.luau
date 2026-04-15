--!strict

local EquipmentCatalog = require(script.Parent:WaitForChild("EquipmentCatalog"))

local OilConfig = {
	-- Plot section grid: 3 cols x 4 rows of 40-stud sections (5x5 sub-tiles of 8 studs each).
	-- Total plot footprint = 120 wide x 160 deep.
	-- "Chunk" in code = one section. The unlock unit is the entire 40x40 section.
	Chunks = {
		Size = 40, -- one section is 40x40 studs
		GridRows = 4,
		GridCols = 3,
		StartingRow = 4,
		StartingCol = 2,
	},
	ChunkUnlockBaseCost = 500,
	ChunkUnlockDistanceMultiplier = 1.0,

	-- Legacy drill economy (kept for now; pumps now inherit these values)
	DrillBaseFlow = 0.2,
	DrillMinSpacing = 6,
	BaseMaxActiveDrills = 9999,
	DrillsPerOwnedChunk = 0,
	HardMaxActiveDrills = 9999,
	DrillScaleMin = 0.5,
	DrillScaleMax = 1.2,

	-- Drill / pump / pipe / prospector economy: single source `EquipmentCatalog`.
	DrillTiers = EquipmentCatalog.getDrillTiersMap(),
	DrillPlacementCost = EquipmentCatalog.getDrillPlacementCostHint(),

	PumpTiers = EquipmentCatalog.getPumpTiersMap(),
	-- Each placed pump gets a random visual scale.
	PumpScaleMin = 0.36,
	PumpScaleMax = 0.57,
	-- Rare cosmetic variants: small chance a placed pump is "gold" or "rainbow" (tagged so the
	-- renderer can apply a highlight/aura). Templates can be added later; nil = no override.
	GoldPumpChance = 0.05,
	GoldPumpHighlightColor = Color3.fromRGB(255, 215, 70),
	RainbowPumpChance = 0.02,
	RainbowPumpHighlightColor = Color3.fromRGB(180, 140, 255),

	Prospecting = EquipmentCatalog.getProspecting(),

	-- Colors for the oil spray VFX between drill completion and pump placement
	OilSprayColors = {
		HeavyCrude     = Color3.fromRGB(30, 30, 30),
		LightSweet     = Color3.fromRGB(240, 200, 70),
		PremiumRefined = Color3.fromRGB(180, 80, 255),
	},

	Pipes = EquipmentCatalog.getPipes(),
	Drums = {
		Cost = 0,
		IntakeStubLength = 4,
	},
	DrillBufferCapacity = 20, -- per tier, per drill

	-- Player economy
	StartingCash = 0,
	StartingStorageCapacity = 100,
	ProductionTickSeconds = 1,

	-- Drill removal
	RemoveDrillHoldSeconds = 2,
	RemoveDrillRangeStuds = 18,
	--- Server: `RequestHammerDestroy` / salvage — HRP must be within this of the target's authored world position.
	SalvageProximityMaxStuds = 24,

	-- Barrel display system
	Barrels = {
		PerBarrelOil = 1,
		MaxVisualPerTier = 20,
		BarrelHeight = 3.5,
		ConveyorTweenSeconds = 4,
		MaxOnConveyor = 5,
		TierTemplates = {
			PremiumRefined = "Barrel_PremiumRefined",
			LightSweet = "Barrel_LightSweet",
			HeavyCrude = "Barrel_HeavyCrude",
		},
	},

	-- Biomes drive drill yield mix.
	-- tierMix is a percentage distribution that must sum to 100.
	Biomes = {
		Desert = {
			flowMul = 1.0,
			tierMix = {
				HeavyCrude = 70,
				LightSweet = 25,
				PremiumRefined = 5,
			},
		},
		Rocky = {
			flowMul = 0.9,
			tierMix = {
				HeavyCrude = 85,
				LightSweet = 13,
				PremiumRefined = 2,
			},
		},
		Wetland = {
			flowMul = 1.1,
			tierMix = {
				HeavyCrude = 75,
				LightSweet = 20,
				PremiumRefined = 5,
			},
		},
		Forest = {
			flowMul = 1.05,
			tierMix = {
				HeavyCrude = 55,
				LightSweet = 35,
				PremiumRefined = 10,
			},
		},
	},
}

return OilConfig
