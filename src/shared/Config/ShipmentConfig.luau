--!strict

export type ShipmentSizeId = "Small" | "Medium" | "Large" | "AllIn"
export type ShipmentEventId = "MinorDamage" | "Delay" | "MineHit" | "DroneAttack" | "PirateSwarm" | "Catastrophic"

local ShipmentConfig = {
	Sizes = {
		Small = {
			maxBarrels = 10,
			sizePenalty = 0.00,
		},
		Medium = {
			maxBarrels = 30,
			sizePenalty = 0.05,
		},
		Large = {
			maxBarrels = 70,
			sizePenalty = 0.12,
		},
		AllIn = {
			maxBarrels = nil,
			sizePenalty = 0.20,
		},
	},
	ClosedStateExtraDestructionFloor = 0.10,
	HardSafetyMaxEvents = 20,
	EventOrder = {
		"MinorDamage",
		"Delay",
		"MineHit",
		"DroneAttack",
		"PirateSwarm",
		"Catastrophic",
	} :: { ShipmentEventId },
	MinEventSpacingSeconds = 1.5,
	MaxEventSpacingSeconds = 4.5,
	Events = {
		MinorDamage = {
			weight = 36,
			damageMin = 0.05,
			damageMax = 0.12,
			delayMin = 0,
			delayMax = 0,
		},
		Delay = {
			weight = 25,
			damageMin = 0.00,
			damageMax = 0.00,
			delayMin = 2,
			delayMax = 6,
		},
		MineHit = {
			weight = 16,
			damageMin = 0.15,
			damageMax = 0.30,
			delayMin = 1,
			delayMax = 3,
		},
		DroneAttack = {
			weight = 13,
			damageMin = 0.10,
			damageMax = 0.22,
			delayMin = 0,
			delayMax = 2,
		},
		PirateSwarm = {
			weight = 8,
			damageMin = 0.25,
			damageMax = 0.45,
			delayMin = 2,
			delayMax = 7,
		},
		Catastrophic = {
			weight = 2,
			damageMin = 1.00,
			damageMax = 1.00,
			delayMin = 0,
			delayMax = 0,
		},
	},
}

return ShipmentConfig
