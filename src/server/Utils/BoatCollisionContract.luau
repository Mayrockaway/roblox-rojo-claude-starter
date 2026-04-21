--!strict
--
-- BoatCollisionContract: single source of truth for the universal boat-collision rule.
--
-- The product rule is "boats should not collide with random objects or other boats
-- while on the strait, but humanoids should be able to collide with boats" — see
-- the audit notes in the dock-spawner change that introduced this module.
--
-- Mechanics:
--   * Every BasePart in a boat clone (idle dock OR active voyage) is tagged with
--     `CollisionGroup = "ShipmentShip"`. Pair rules in `BoatDockService.applyMarinaDockCollisionRules`
--     and `applyMapDecorVersusShipmentShipRules`, plus the self-pair in `OilShipmentService._setupShip`
--     (`ShipmentShip` vs `ShipmentShip` = false), then deliver the rest:
--       - ShipmentShip ↔ Default (characters)  → collide  (humanoids stand on deck)
--       - ShipmentShip ↔ ShipmentShip          → no collide (boats pass each other)
--       - ShipmentShip ↔ MarinaDock            → no collide (pier kept clear)
--       - ShipmentShip ↔ MapDecor              → no collide (buoys, props)
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
-- Both call sites (`BoatDockService:_spawnIdleBoat` and
-- `OilShipmentService:_setupShip`) MUST go through `Apply` so the rule stays
-- universal. Anchoring / welding remain the caller's responsibility — those
-- differ between idle (anchored, no constraints) and voyage (unanchored,
-- welded rigid assembly).

local NON_COLLIDABLE_BOAT_HELPER_NAMES: { [string]: boolean } = {
	BarrelStackRoot = true,
	FRONT_MARKER = true,
	PlayerFlag = true,
	WaterlineAnchor = true,
	ZIPLINE_LAND_ANCHOR = true,
}

local SHIPMENT_SHIP_GROUP = "ShipmentShip"

local BoatCollisionContract = {}

BoatCollisionContract.HelperNames = NON_COLLIDABLE_BOAT_HELPER_NAMES
BoatCollisionContract.CollisionGroup = SHIPMENT_SHIP_GROUP

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
--- Returns counts of (helpers neutralized, parts tagged ShipmentShip) for logging.
function BoatCollisionContract.Apply(boat: Instance): (number, number)
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
			(d :: BasePart).CollisionGroup = SHIPMENT_SHIP_GROUP
		end)
		taggedCount += 1
	end
	return helperCount, taggedCount
end

return BoatCollisionContract
