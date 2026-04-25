--!strict
--- FlotsamConfig: tuning knobs + reward catalog for `FlotsamService`.
--- Designers can rebalance spawn density / drop weights without touching the
--- service. Add new reward kinds (`Equipment`, `Oil`, etc.) here AND wire the
--- matching grant branch in `FlotsamService:_handleClaim` to enable them.

local FlotsamConfig = {}

--- Master switch — flip to `false` to disable the system without uninstalling.
FlotsamConfig.Enabled = true

--- Target number of crates alive on the strait at any moment. The maintenance
--- loop tops up to this number whenever a crate is claimed.
FlotsamConfig.MaxActiveCrates = 6

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

--- Reward catalog. Server rolls one row per claim, weighted by `weight`.
--- Only `kind = "Cash"` is grant-wired today (MVP); add Equipment / Oil
--- rows here AND extend `FlotsamService:_handleClaim` together when you
--- want richer drops.
FlotsamConfig.Rewards = {
	{ kind = "Cash", amount = 250,  weight = 50 },
	{ kind = "Cash", amount = 500,  weight = 30 },
	{ kind = "Cash", amount = 1500, weight = 15 },
	{ kind = "Cash", amount = 5000, weight = 5 },
}

--- Studio-only: `print` every spawn / claim event with reward info.
--- Off in production to avoid log spam.
FlotsamConfig.VerboseLogging = true

return FlotsamConfig
