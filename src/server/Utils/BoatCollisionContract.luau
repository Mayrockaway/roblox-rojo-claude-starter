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
--     `Default` group; the strait-event freeze flow temporarily reassigns to
--     `PlayerInStraitEvent` (see `OilShipmentService`).
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
--       - IdleBoat ↔ PlayerInStraitEvent        → no collide (strait-event reassigned characters too)
--       - IdleBoat ↔ StraitWaypointFxNpc        → no collide
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
