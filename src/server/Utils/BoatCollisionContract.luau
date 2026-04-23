--!strict
--
-- BoatCollisionContract: single source of truth for the universal boat-collision rule.
--
-- The product rule is "boats should not collide with random objects or other boats
-- while on the strait, but humanoids should be able to collide with boats they own
-- and are voyaging on" — see the audit notes in the dock-spawner change that
-- introduced this module.
--
-- Mechanics:
--   * Every BasePart in a boat clone is tagged with one of two collision groups
--     depending on lifecycle state:
--       - "IdleBoat":     idle / docked boats (parked at workspace.dOCKS slot)
--       - "ShipmentShip": active voyage hulls (un-anchored, welded rigid assembly)
--     The pair-rule matrix is registered by `BoatDockService:Init` /
--     `OilShipmentService:Init` (idempotent). Characters use the engine default
--     `Default` group on land; while a player is **on a voyage** (their owner
--     character has been teleported onto the deck at dispatch) the SERVER
--     reassigns every body part to `PlayerInStraitEvent` and only restores
--     the prior group at voyage completion / total loss. The group name is
--     legacy — it originally applied only during the strait-event freeze
--     cinematic, but the rule it expresses ("this character is on a moving
--     boat in the strait, so they should not collide with anything in the
--     world except the deck they're standing on") is the same for the
--     full voyage; expanding scope to the entire voyage was the simplest
--     way to satisfy the product rule that voyaging players never clip on
--     docks / map decor / parked boats while still standing on their
--     own (and other players') ship hulls.
--
--   * Voyage hulls (`ShipmentShip`) collision pairs:
--       - ShipmentShip ↔ Default (characters)   → collide   (owner walks on their own deck)
--       - ShipmentShip ↔ Players                → collide
--       - ShipmentShip ↔ ShipmentShip           → no collide (voyages pass each other)
--       - ShipmentShip ↔ IdleBoat               → no collide (voyages clip through docked boats)
--       - ShipmentShip ↔ MarinaDock             → no collide (pier kept clear)
--       - ShipmentShip ↔ MapDecor               → no collide (buoys, props)
--
--   * Idle / docked hulls (`IdleBoat`) collision pairs:
--       - IdleBoat ↔ Default (characters)       → no collide (players walk THROUGH docked boats so a docked
--                                                              hull never knocks the owner off their own
--                                                              voyage boat as it sails out / returns)
--       - IdleBoat ↔ Players                    → no collide
--       - IdleBoat ↔ ShipmentShip               → no collide (voyages clip through docked boats)
--       - IdleBoat ↔ IdleBoat                   → no collide (parked boats never push each other)
--       - IdleBoat ↔ MarinaDock                 → no collide
--       - IdleBoat ↔ MapDecor                   → no collide
--       - IdleBoat ↔ PlayerInStraitEvent        → no collide (voyaging characters)
--       - IdleBoat ↔ StraitWaypointFxNpc        → no collide
--
--   * Voyaging owner (`PlayerInStraitEvent`, applied for the full voyage):
--       - PlayerInStraitEvent ↔ ShipmentShip    → collide   (owner stands on their hull)
--       - PlayerInStraitEvent ↔ Default/Players → collide   (other characters can bump them)
--       - PlayerInStraitEvent ↔ IdleBoat        → no collide (covered above)
--       - PlayerInStraitEvent ↔ MarinaDock      → no collide (boat can dock right against pier)
--       - PlayerInStraitEvent ↔ MapDecor        → no collide (buoys / props in the lane don't trip them)
--       - PlayerInStraitEvent ↔ StraitWaypointFxNpc → no collide (cosmetic NPCs)
--     The rule "voyaging players only collide with hulls + other players"
--     is what lets the deck stay walkable while ships sail through the
--     dock pier and past world decor without snagging the player.
--
--     The "characters clip through docked boats" rule is deliberate — the
--     gameplay requirement is to prevent owners being knocked off their own
--     voyage boat by a docked boat that the voyage hull sails past or that
--     happens to be in the way at dispatch / re-dock. The trade-off is that
--     players can no longer walk on a parked boat from the pier; in this game
--     that's acceptable because the dispatch flow auto-teleports the owner
--     onto the deck and players have no other reason to board parked boats.
--
--   * Authored `CanCollide` is RESPECTED — we do not force `CanCollide = true` like
--     the previous pipelines did. Per the template audit:
--       - Tanker / Raft / PirateShip: only standard helpers (FRONT_MARKER,
--         WaterlineAnchor) are CC-off; behavior unchanged.
--       - Whale: the artist authored 60+ tiny `Ball` decorations, the two
--         `SaddlePad` MeshParts, and `SprayPoint` as `CanCollide = false`. The
--         old `d.CanCollide = true` loop silently re-enabled all of them, so
--         players were colliding with invisible <0.5-stud cubes spread across
--         the whale rig. Respecting authored intent restores the artist's setup.
--       - Ducky: the duck-body and raft-pillar fake-cube hitboxes are fixed
--         in the template separately (Block-shape Parts wrapping mesh visuals).
--   * Helper parts identified by `isNonCollidableBoatHelperPart` (FRONT_MARKER,
--     WaterlineAnchor, BarrelStackRoot, etc., or any part with transparency
--     ≥ 0.95 and no `AllowInvisibleCollision` opt-out) are explicitly neutralized
--     — fully invisible, non-colliding, non-touching, massless. This catches the
--     legacy authored "guide" parts that should never participate in physics
--     even if their `CanCollide` flag was authored true.
--   * If a future template intentionally needs an invisible collider (e.g. a
--     hidden ramp), set the BasePart attribute `AllowInvisibleCollision = true`
--     and the helper-detector will skip it.
--
-- Call sites and the `mode` they MUST pass:
--   * `BoatDockService:_spawnIdleBoat`           → `Apply(boat, "idle")`
--   * `BoatDockService:CheckoutBoat`             → `Apply(boat, "voyage")` (re-tag idle → voyage)
--   * `OilShipmentService:_setupShip`            → `Apply(boat, "voyage")` (idempotent, after un-anchor / weld)
--
-- Anchoring / welding remain the caller's responsibility — those differ
-- between idle (anchored, no constraints) and voyage (unanchored, welded rigid
-- assembly). Mode only governs the collision-group tag.

local NON_COLLIDABLE_BOAT_HELPER_NAMES: { [string]: boolean } = {
	BarrelStackRoot = true,
	-- `DeckSeat` is authored as a `Seat` so legacy rigs can fall back to its
	-- world position for owner teleport / NPC deck-Y resolution, but it is
	-- never meant to actually seat the player (see the header comment on
	-- `BoatDockService.luau` — "DeckSeat remains as authored rig geometry
	-- only; it is neutralized so players are never seated by the boat").
	-- The legacy `Tanker` / `PirateShip` / `Ducky` templates were authored
	-- with `Transparency = 1` already; the new `Tier1Boat`..`Tier10Boat`
	-- templates ship at `Transparency = 0.30` (they were imported from a
	-- single base raft model and the seat helper was never re-hidden), so
	-- without an entry here the seat showed through during voyages and at
	-- the dock. Adding it makes `BoatCollisionContract.NeutralizeHelperPart`
	-- force `Transparency = 1` + disable `CanCollide` / `CanTouch` /
	-- `CanQuery` on every spawn so the seat never auto-sits a player who
	-- walks over it. Position is preserved (we only flip render / hit flags),
	-- so all existing rig fallbacks that read `seat.Position` keep working.
	DeckSeat = true,
	FRONT_MARKER = true,
	PlayerFlag = true,
	WaterlineAnchor = true,
	ZIPLINE_LAND_ANCHOR = true,
}

local SHIPMENT_SHIP_GROUP = "ShipmentShip"
local IDLE_BOAT_GROUP = "IdleBoat"

export type ApplyMode = "idle" | "voyage"

local BoatCollisionContract = {}

BoatCollisionContract.HelperNames = NON_COLLIDABLE_BOAT_HELPER_NAMES
--- Voyage hull group. Kept as `CollisionGroup` (not `VoyageGroup`) for backward
--- compat with `OilShipmentService._loadBarrelsOnDeck` which tags barrels
--- directly with `BoatCollisionContract.CollisionGroup`. Barrels are cargo
--- on the active voyage, so they should always be `ShipmentShip`.
BoatCollisionContract.CollisionGroup = SHIPMENT_SHIP_GROUP
BoatCollisionContract.VoyageGroup = SHIPMENT_SHIP_GROUP
BoatCollisionContract.IdleGroup = IDLE_BOAT_GROUP

function BoatCollisionContract.IsNonCollidableBoatHelperPart(part: BasePart): boolean
	if NON_COLLIDABLE_BOAT_HELPER_NAMES[part.Name] == true then
		return true
	end
	if part:GetAttribute("AllowInvisibleCollision") == true then
		return false
	end
	return part.Transparency >= 0.95
end

function BoatCollisionContract.NeutralizeHelperPart(part: BasePart)
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Transparency = 1
	part.CastShadow = false
	part.Massless = true
	part:SetAttribute("BoatGameplayHelperDisabled", true)
end

--- Apply the universal collision contract to every BasePart under `boat`.
--- `mode` selects the collision group tag:
---   * "idle"    → `IdleBoat` (parked / docked; clips through characters & voyages)
---   * "voyage"  → `ShipmentShip` (active voyage hull; characters can stand on it)
--- Returns counts of (helpers neutralized, parts tagged) for logging.
---
--- Defaults to "voyage" so any legacy callsite that hasn't been updated yet
--- still produces a hull players can stand on (degrades to current behavior
--- rather than silently making a boat un-walkable).
function BoatCollisionContract.Apply(boat: Instance, mode: ApplyMode?): (number, number)
	local resolvedMode: ApplyMode = if mode == "idle" then "idle" else "voyage"
	local groupName: string = if resolvedMode == "idle" then IDLE_BOAT_GROUP else SHIPMENT_SHIP_GROUP
	local helperCount = 0
	local taggedCount = 0
	for _, d in ipairs(boat:GetDescendants()) do
		if not d:IsA("BasePart") then
			continue
		end
		if BoatCollisionContract.IsNonCollidableBoatHelperPart(d) then
			BoatCollisionContract.NeutralizeHelperPart(d)
			helperCount += 1
		end
		-- CollisionGroup must be applied AFTER helper neutralization. The
		-- helper path doesn't actually rely on the group (it's CanCollide=false
		-- so pair rules don't matter), but tagging everything keeps a uniform
		-- rule in case someone later flips a helper visible.
		pcall(function()
			(d :: BasePart).CollisionGroup = groupName
		end)
		taggedCount += 1
	end
	return helperCount, taggedCount
end

return BoatCollisionContract
