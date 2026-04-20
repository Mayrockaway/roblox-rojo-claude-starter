--!strict

local EquipmentCatalog = require(script.Parent:WaitForChild("EquipmentCatalog"))
local VeinConfig = require(script.Parent:WaitForChild("VeinConfig"))

--- `PumpTiers` for `OilStateService` center-pump templating. Derived from
--- `VeinConfig.PumpUpgrades` so the prox-prompt upgrade flow and the auto-place
--- spawn share one source of truth (no `EquipmentCatalog` row needed because
--- pumps are no longer purchasable).
local function buildPumpTiers()
	local out: { [string]: { templateName: string, displayName: string, flowMultiplier: number, cost: number } } = {}
	for tier, def in pairs(VeinConfig.PumpUpgrades) do
		out[tier] = {
			templateName = def.templateName,
			displayName = def.displayName,
			flowMultiplier = def.flowMult,
			cost = 0, -- center pumps don't have a placement cost; upgrades use VeinConfig.PumpUpgradeCostsByGround
		}
	end
	return out
end

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

	-- Drill economy (one consumable drill per tile reveal).
	DrillBaseFlow = 0.2,
	DrillMinSpacing = 6,
	BaseMaxActiveDrills = 9999,
	DrillsPerOwnedChunk = 0,
	HardMaxActiveDrills = 9999,
	DrillScaleMin = 0.5,
	DrillScaleMax = 1.2,

	-- Drill economy: single source `EquipmentCatalog`.
	DrillTiers = EquipmentCatalog.getDrillTiersMap(),
	DrillPlacementCost = EquipmentCatalog.getDrillPlacementCostHint(),

	-- Pump templating for the auto-placed center pump (one per unlocked chunk).
	-- Pumps are NOT purchasable / NOT player-placed; only upgraded via prox prompt.
	-- See `OilStateService:_autoPlaceCenterPump` and `OilStateService:TryUpgradeCenterPump`.
	PumpTiers = buildPumpTiers(),
	-- Each placed pump gets a random visual scale.
	PumpScaleMin = 0.36,
	PumpScaleMax = 0.57,
	-- Rare cosmetic variants: small chance a placed pump is "gold" or "rainbow" (tagged so the
	-- renderer can apply a highlight/aura). Templates can be added later; nil = no override.
	GoldPumpChance = 0.05,
	GoldPumpHighlightColor = Color3.fromRGB(255, 215, 70),
	RainbowPumpChance = 0.02,
	RainbowPumpHighlightColor = Color3.fromRGB(180, 140, 255),

	-- Colors for the oil spray VFX over drilled tiles (now used between drill
	-- completion and the center pump's pickup tick).
	OilSprayColors = {
		Crude     = Color3.fromRGB(30, 30, 30),
		Refined     = Color3.fromRGB(240, 200, 70),
		Premium = Color3.fromRGB(180, 80, 255),
	},

	DrillBufferCapacity = 20, -- per tier, per drill

	-- Player economy
	StartingCash = 500,
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
		MaxVisualPerTier = 40,
		BarrelHeight = 3.5,
		ConveyorTweenSeconds = 4,
		MaxOnConveyor = 5,
		TierTemplates = {
			Premium = "Barrel_Premium",
			Refined = "Barrel_Refined",
			Crude = "Barrel_Crude",
		},
	},

	-- Biomes drive drill yield mix.
	-- tierMix is a percentage distribution that must sum to 100.
	Biomes = {
		Desert = {
			flowMul = 1.0,
			tierMix = {
				Crude = 70,
				Refined = 25,
				Premium = 5,
			},
		},
		Rocky = {
			flowMul = 0.9,
			tierMix = {
				Crude = 85,
				Refined = 13,
				Premium = 2,
			},
		},
		Wetland = {
			flowMul = 1.1,
			tierMix = {
				Crude = 75,
				Refined = 20,
				Premium = 5,
			},
		},
		Forest = {
			flowMul = 1.05,
			tierMix = {
				Crude = 55,
				Refined = 35,
				Premium = 10,
			},
		},
	},
}

return OilConfig
