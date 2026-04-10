--!strict

local BoatConfig = {
	DefaultPriceMultiplier = 1.0,
	MaxConcurrentShipmentsPerPlayer = 30,
	Boats = {
		RustSkiff = {
			displayName = "Rust Skiff",
			dispatchFee = 150,
			capacity = 8,
			hullHp = 100,
			travelSeconds = 60,
			eventRisk = 0.35,
			-- Extra multiplier on top of auto scale from hull extents (ShipmentFxConfig).
			fxParticleScale = 1,
		},
		Hauler = {
			displayName = "Hauler",
			dispatchFee = 600,
			capacity = 20,
			hullHp = 160,
			travelSeconds = 75,
			eventRisk = 0.28,
			fxParticleScale = 1,
		},
		ArmoredTanker = {
			displayName = "Armored Tanker",
			dispatchFee = 1800,
			capacity = 45,
			hullHp = 240,
			travelSeconds = 90,
			eventRisk = 0.22,
			fxParticleScale = 1,
		},
	},
}

return BoatConfig
