--!strict

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

	-- Drill economy
	DrillPlacementCost = 200,
	DrillBaseFlow = 0.2,
	DrillMinSpacing = 6,
	BaseMaxActiveDrills = 9999,
	DrillsPerOwnedChunk = 0,
	HardMaxActiveDrills = 9999,
	GoldDrillChance = 0.05,
	GoldDrillTemplate = "DrillGold",
	RareDrillChance = 0.20,
	RareDrillTemplate = "DrillRainbow",
	DefaultDrillTemplate = "Drill",
	DrillScaleMin = 0.5,
	DrillScaleMax = 1.2,

	-- Pipe network
	Pipes = {
		Cost = 50,
		MinLength = 4,
		MaxLength = 60,
		EndpointSnapRadius = 3,
	},
	Drums = {
		Cost = 0,
		IntakeStubLength = 4,
	},
	DrillBufferCapacity = 20, -- per tier, per drill

	-- Player economy
	StartingCash = 1000000,
	StartingStorageCapacity = 100,
	ProductionTickSeconds = 1,

	-- Drill removal
	RemoveDrillHoldSeconds = 2,
	RemoveDrillRangeStuds = 18,

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
			StandardCrude = "Barrel_StandardCrude",
			HeavyCrude = "Barrel_HeavyCrude",
		},
	},

	-- Biomes drive drill yield mix.
	-- tierMix is a percentage distribution that must sum to 100.
	Biomes = {
		Desert = {
			flowMul = 1.0,
			tierMix = {
				HeavyCrude = 20,
				StandardCrude = 50,
				LightSweet = 25,
				PremiumRefined = 5,
			},
		},
		Rocky = {
			flowMul = 0.9,
			tierMix = {
				HeavyCrude = 50,
				StandardCrude = 35,
				LightSweet = 13,
				PremiumRefined = 2,
			},
		},
		Wetland = {
			flowMul = 1.1,
			tierMix = {
				HeavyCrude = 35,
				StandardCrude = 40,
				LightSweet = 20,
				PremiumRefined = 5,
			},
		},
		Forest = {
			flowMul = 1.05,
			tierMix = {
				HeavyCrude = 15,
				StandardCrude = 40,
				LightSweet = 35,
				PremiumRefined = 10,
			},
		},
	},
}

return OilConfig
