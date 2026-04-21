# Boat collision contract

**Module:** `src/server/Utils/BoatCollisionContract.luau`
**Call sites (must funnel through `.Apply`):**
- `BoatDockService:_spawnIdleBoat` (idle dock spawn)
- `BoatDockService:CheckoutBoat` (idle → voyage handoff, idempotent reapply)
- `OilShipmentService:_setupShip` (voyage hull rigid assembly)
- `OilShipmentService:_loadBarrelsOnDeck` (cargo barrels — tags `ShipmentShip` only; barrels keep `CanCollide = true` so players walk on stacked cargo)

## Universal rule

> Boats must not collide with random objects or other boats while on the strait, but humanoids must be able to collide with boats.

This is realised by tagging every BasePart in a boat clone (idle or voyage, hull or cargo) with `CollisionGroup = "ShipmentShip"` and relying on the engine pair rules:

| Pair | Collide? | Set in |
|---|---|---|
| `ShipmentShip` ↔ `Default` (characters) | yes | implicit (default-true between groups) |
| `ShipmentShip` ↔ `ShipmentShip` | **no** | `OilShipmentService._setupShip` (group registration block) |
| `ShipmentShip` ↔ `MarinaDock` (pier) | **no** | `BoatDockService.applyMarinaDockCollisionRules` |
| `ShipmentShip` ↔ `MapDecor` (buoys, world props) | **no** | `BoatDockService.applyMapDecorVersusShipmentShipRules` |

## Authored `CanCollide` is the source of truth

The previous pipelines unconditionally set `d.CanCollide = true` on every boat part and then patched a small helper allow-list back to false. That **silently overrode artist intent** on whole templates. The audit at the time of extraction:

| Template | Authored CC-off (non-helper) before | After spawner respects authored CC |
|---|---|---|
| Tanker | 0 | 0 — pristine, no behavior change |
| Raft | 0 | 0 — no behavior change |
| PirateShip | 0 | 0 — no behavior change |
| **Whale** | **63** (60× tiny `Ball` decorations + 2× `SaddlePad` MeshPart + `SprayPoint`) | **63 honoured** — artist intent restored |
| **Ducky** | 0 in template + 7 invisible-cube hitboxes patched separately (Epic Duck Mesh, Hat giver, 5 raft pillars) | hitboxes neutralized |

## Helper neutralization

Any BasePart that satisfies `BoatCollisionContract.IsNonCollidableBoatHelperPart` is fully neutralized (invisible, `CanCollide`/`CanTouch`/`CanQuery` false, massless, attribute `BoatGameplayHelperDisabled = true`). Detection rules:

1. Name in `HelperNames` (`BarrelStackRoot`, `FRONT_MARKER`, `PlayerFlag`, `WaterlineAnchor`, `ZIPLINE_LAND_ANCHOR`).
2. **Else** if BasePart attribute `AllowInvisibleCollision = true` → opt-out, treat as a real collider.
3. **Else** if `Transparency >= 0.95` → treat as helper.

## Adding a new boat template

1. Author hull / deck / detail parts with `CanCollide` set per the artist's intent — the spawner will respect it.
2. Avoid Block-shape `Part` instances wrapping a `SpecialMesh` / `CylinderMesh` for visible geometry (the "Ducky duck-body" anti-pattern). Either use a `MeshPart` (collision matches the visible mesh) or set `Part.Shape` to match the visible silhouette. If neither is possible AND nothing needs to land on it, set `CanCollide = false` on the wrapper Part — the visual still renders.
3. If you intentionally need an invisible collider (hidden ramp, ride-on platform), set the BasePart attribute `AllowInvisibleCollision = true` so helper detection skips it.
4. Do **not** introduce a new force-`CanCollide = true` loop in any service — call `BoatCollisionContract.Apply(boat)` instead, after any structural changes (un-anchor, weld, etc.).

## Anchor placement gotcha (rig authoring)

`DeckTopAnchor` is what `ShipRig.ResolveDeckWorldY` returns and what `BoatDockService.resolveOwnerStandCFrame` uses to compute the teleport target (`standPos.Y = deckTopY + 4`). After that, `resolveBoatSupportStandCFrame` raycasts down 14 studs to find the actual support and snap the player onto it. **Both `DeckTopAnchor` and `DeckAnchor` must be authored above (or on top of) every collidable hull part directly underneath the player teleport spot**, otherwise:

- The teleport target lands inside a CC=true bounding box.
- Roblox raycasts skip parts whose interior the ray originates inside, so `resolveBoatSupportStandCFrame` snaps to the *next* surface below — sometimes the deck (good), sometimes a lower interior part (player ends up clipping inside).
- Physics resolution then ejects the character in an unpredictable direction. Sometimes up (works), sometimes down through the ship (falls through).

This was the actual root cause of the original "Ducky clipping" bug, not the collision contract. The Ducky's `DeckTopAnchor` was parented to `Epic Duck Mesh` at world Y=24.5, which is the *middle* of a 46.7-tall block (top at Y=45.46). Fix was to move both attachments above the duck back, so teleport lands cleanly above the duck and gravity drops the player onto its top surface.

When authoring a new template, sanity-check with:

```
DeckTopAnchor.WorldPosition.Y >= max(part.Position.Y + part.Size.Y/2 for every CC=true part directly below DeckTopAnchor in XZ)
```

If a fixed-collision detail (like the legacy "Hat giver" widget on the Ducky) sits less than ~5 studs above the deck and overlaps the stand position in XZ, set its `CanCollide = false` — `Touched` events still fire, so any "touch this to receive item" wiring keeps working.

## Dev testing

`/unlockboats` (server chat command) grants every skin in `ShipSkinCatalog.Skins` to the calling player so each hull can be QA'd through the in-game Ship Management panel without buying via Robux. Aliases: `/unlockallboats`, `/giveallboats`.
