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
		},
		Hauler = {
			displayName = "Hauler",
			dispatchFee = 600,
			capacity = 20,
			hullHp = 160,
			travelSeconds = 75,
			eventRisk = 0.28,
		},
		ArmoredTanker = {
			displayName = "Armored Tanker",
			dispatchFee = 1800,
			capacity = 45,
			hullHp = 240,
			travelSeconds = 90,
			eventRisk = 0.22,
		},
	},
}

return BoatConfig
