--!strict
--- FlotsamConfig: tuning knobs + reward catalog for `FlotsamService`.
--- Designers can rebalance spawn density / drop weights without touching the
--- service. Add new reward kinds (`Equipment`, `Oil`, etc.) here AND wire the
--- matching grant branch in `FlotsamService:_handleClaim` to enable them.

local FlotsamConfig = {}

--- Master switch — flip to `false` to disable the system without uninstalling.
--- Currently OFF: the system needs design changes before it goes live, but
--- we want to keep all the spawn / claim / reward wiring in place so other
--- updates can ship without ripping it out. `FlotsamService:Start()`
--- early-returns on this flag (line ~63) so flipping to `true` re-enables
--- the system in one edit, no service rewrite needed.
FlotsamConfig.Enabled = true

--- Target number of crates alive on the strait at any moment. The maintenance
--- loop tops up to this number whenever a crate is claimed.
--- Crate count ranges per strait state. On each state change (and initial spawn),
--- a random count within the range is chosen.
FlotsamConfig.CrateCountRanges = {
	Open       = { min = 5,  max = 20 },
	Restricted = { min = 10, max = 25 },
	Closed     = { min = 15, max = 30 },
}
FlotsamConfig.MaxActiveCrates = 20 -- fallback default, overridden by CrateCountRanges

--- How often the maintenance loop wakes up to check if spawns need topping up.
--- Lower = snappier respawn after a pickup; higher = less work.
FlotsamConfig.MaintenanceTickSeconds = 5

--- How many random points to try before giving up on a spawn slot. Keeps the
--- service from spinning if the strait happens to be unusually crowded.
FlotsamConfig.MaxSpawnAttempts = 30

--- Minimum world-space distance between two active crates (studs). Prevents
--- the RNG from clumping crates in the same corner.
FlotsamConfig.MinSpacing = 80

--- Stay away from the union's local-XZ edge by this many studs so crates
--- don't spawn pressed against a cliff or jutting into a dock pier.
FlotsamConfig.EdgeMargin = 60

--- Crate Y offset above the water surface. Slightly above so the bottom
--- waterline reads as "half-submerged crate floating", not "submarine".
FlotsamConfig.SpawnYOffset = 1

--- ProximityPrompt activation distance (studs). Player must swim within this
--- range to see + trigger the prompt.
FlotsamConfig.PromptDistance = 8

--- Hold-to-interact duration (seconds). Half a second gives a tactile beat
--- without slowing the loop.
FlotsamConfig.PromptHoldDuration = 0.5

--- Server validates the claimer's `HumanoidRootPart` is within this radius
--- of the crate at claim time. Anti-spoof guard with a small slack on top of
--- `PromptDistance` to allow for one frame of network drift.
FlotsamConfig.ClaimMaxDistance = FlotsamConfig.PromptDistance + 6

--- Crate tier templates. Names match models in ServerStorage.FlotsamCrates.
--- Each tier has its own reward table rolled on claim.
FlotsamConfig.CrateTiers = {
	{ templateName = "BaseCrate",     displayName = "Crate" },
	{ templateName = "Gold Crate",    displayName = "Gold Crate" },
	{ templateName = "Rainbow Crate", displayName = "Rainbow Crate" },
}

--- Spawn weights per strait state. Index matches CrateTiers order.
--- Higher weight = more likely to spawn that tier.
FlotsamConfig.CrateSpawnWeights = {
	Open       = { 90, 8, 2 },
	Restricted = { 70, 25, 5 },
	Closed     = { 50, 40, 10 },
}

--- Reward catalog per crate tier. Keyed by templateName.
--- kind: "Cash" | "Drill" | "Oil"
--- Drill: drillId = "drill_t1".."drill_t6", qty = count
--- Oil:   oilType = "Crude"|"Refined"|"Premium", qty = barrel count
FlotsamConfig.Rewards = {
	BaseCrate = {
		-- Cash (55%)
		{ kind = "Cash", amount = 250,   weight = 15 },
		{ kind = "Cash", amount = 500,   weight = 12 },
		{ kind = "Cash", amount = 750,   weight = 10 },
		{ kind = "Cash", amount = 1000,  weight = 8 },
		{ kind = "Cash", amount = 2000,  weight = 5 },
		{ kind = "Cash", amount = 3000,  weight = 3 },
		{ kind = "Cash", amount = 4000,  weight = 1.5 },
		{ kind = "Cash", amount = 5000,  weight = 0.5 },
		-- Drills (30%)
		{ kind = "Drill", drillId = "drill_t1", qty = 1, weight = 10 },
		{ kind = "Drill", drillId = "drill_t1", qty = 2, weight = 6 },
		{ kind = "Drill", drillId = "drill_t1", qty = 3, weight = 3 },
		{ kind = "Drill", drillId = "drill_t1", qty = 5, weight = 1 },
		{ kind = "Drill", drillId = "drill_t2", qty = 1, weight = 5 },
		{ kind = "Drill", drillId = "drill_t2", qty = 2, weight = 3 },
		{ kind = "Drill", drillId = "drill_t2", qty = 3, weight = 1.5 },
		{ kind = "Drill", drillId = "drill_t2", qty = 5, weight = 0.5 },
		-- Oil (15%)
		{ kind = "Oil", oilType = "Crude",   qty = 5,  weight = 6 },
		{ kind = "Oil", oilType = "Crude",   qty = 10, weight = 4 },
		{ kind = "Oil", oilType = "Crude",   qty = 20, weight = 2 },
		{ kind = "Oil", oilType = "Refined", qty = 5,  weight = 2 },
		{ kind = "Oil", oilType = "Premium", qty = 5,  weight = 1 },
	},
	["Gold Crate"] = {
		-- Cash (40%)
		{ kind = "Cash", amount = 500,   weight = 10 },
		{ kind = "Cash", amount = 1000,  weight = 10 },
		{ kind = "Cash", amount = 1500,  weight = 7 },
		{ kind = "Cash", amount = 2000,  weight = 5 },
		{ kind = "Cash", amount = 4000,  weight = 4 },
		{ kind = "Cash", amount = 6000,  weight = 2 },
		{ kind = "Cash", amount = 8000,  weight = 1.5 },
		{ kind = "Cash", amount = 10000, weight = 0.5 },
		-- Drills (30%)
		{ kind = "Drill", drillId = "drill_t2", qty = 1, weight = 6 },
		{ kind = "Drill", drillId = "drill_t2", qty = 2, weight = 4 },
		{ kind = "Drill", drillId = "drill_t2", qty = 3, weight = 2 },
		{ kind = "Drill", drillId = "drill_t2", qty = 5, weight = 1 },
		{ kind = "Drill", drillId = "drill_t3", qty = 1, weight = 5 },
		{ kind = "Drill", drillId = "drill_t3", qty = 2, weight = 3 },
		{ kind = "Drill", drillId = "drill_t3", qty = 3, weight = 1.5 },
		{ kind = "Drill", drillId = "drill_t3", qty = 5, weight = 1 },
		{ kind = "Drill", drillId = "drill_t4", qty = 1, weight = 3 },
		{ kind = "Drill", drillId = "drill_t4", qty = 2, weight = 2 },
		{ kind = "Drill", drillId = "drill_t4", qty = 3, weight = 1 },
		{ kind = "Drill", drillId = "drill_t4", qty = 5, weight = 0.5 },
		-- Oil (30%)
		{ kind = "Oil", oilType = "Crude",   qty = 5,  weight = 3 },
		{ kind = "Oil", oilType = "Crude",   qty = 10, weight = 3 },
		{ kind = "Oil", oilType = "Crude",   qty = 20, weight = 4 },
		{ kind = "Oil", oilType = "Refined", qty = 5,  weight = 5 },
		{ kind = "Oil", oilType = "Refined", qty = 10, weight = 4 },
		{ kind = "Oil", oilType = "Refined", qty = 20, weight = 3 },
		{ kind = "Oil", oilType = "Premium", qty = 5,  weight = 2 },
		{ kind = "Oil", oilType = "Premium", qty = 10, weight = 1 },
	},
	["Rainbow Crate"] = {
		-- Cash (30%)
		{ kind = "Cash", amount = 1000,   weight = 8 },
		{ kind = "Cash", amount = 3000,   weight = 7 },
		{ kind = "Cash", amount = 5000,   weight = 5 },
		{ kind = "Cash", amount = 10000,  weight = 4 },
		{ kind = "Cash", amount = 50000,  weight = 2 },
		{ kind = "Cash", amount = 100000, weight = 0.5 },
		-- Drills (25%)
		{ kind = "Drill", drillId = "drill_t3", qty = 3,  weight = 5 },
		{ kind = "Drill", drillId = "drill_t3", qty = 5,  weight = 3 },
		{ kind = "Drill", drillId = "drill_t3", qty = 10, weight = 2 },
		{ kind = "Drill", drillId = "drill_t4", qty = 3,  weight = 4 },
		{ kind = "Drill", drillId = "drill_t4", qty = 5,  weight = 2.5 },
		{ kind = "Drill", drillId = "drill_t4", qty = 10, weight = 1.5 },
		{ kind = "Drill", drillId = "drill_t5", qty = 3,  weight = 3 },
		{ kind = "Drill", drillId = "drill_t5", qty = 5,  weight = 2 },
		{ kind = "Drill", drillId = "drill_t5", qty = 10, weight = 1 },
		{ kind = "Drill", drillId = "drill_t6", qty = 3,  weight = 0.5 },
		-- Oil (45%)
		{ kind = "Oil", oilType = "Refined", qty = 10, weight = 6 },
		{ kind = "Oil", oilType = "Refined", qty = 20, weight = 5 },
		{ kind = "Oil", oilType = "Refined", qty = 30, weight = 4 },
		{ kind = "Oil", oilType = "Refined", qty = 40, weight = 3 },
		{ kind = "Oil", oilType = "Refined", qty = 50, weight = 2 },
		{ kind = "Oil", oilType = "Premium", qty = 10, weight = 5 },
		{ kind = "Oil", oilType = "Premium", qty = 20, weight = 4 },
		{ kind = "Oil", oilType = "Premium", qty = 30, weight = 3 },
		{ kind = "Oil", oilType = "Premium", qty = 40, weight = 1.5 },
		{ kind = "Oil", oilType = "Premium", qty = 50, weight = 0.5 },
	},
}

--- Studio-only: `print` every spawn / claim event with reward info.
--- Off in production to avoid log spam.
FlotsamConfig.VerboseLogging = false

return FlotsamConfig
