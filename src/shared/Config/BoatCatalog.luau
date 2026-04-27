--!strict
-- Boat catalog (renamed from `ShipSkinCatalog` in Step 6 of the boat-
-- progression refactor — see `docs/features/player-ship/SPEC.md`).
-- Defines the full boat inventory (5 legacy entries + 10 placeholder
-- tier entries), per-boat baked stats, unlock metadata, and rig
-- overrides.
--
-- Naming history (Step 6 — RENAMED):
--   `ShipSkinCatalog` → `BoatCatalog`           (module / file)
--   `Skins`           → `Boats`                 (table key)
--   `SkinDef`         → `BoatDef`               (type)
--   `GetSkin`         → `GetBoat`               (accessor)
--   `GetRigForSkin`   → `GetRigForBoat`         (accessor)
--   Per-player profile fields and snapshot fields:
--     `shipSkinId`        → `equippedBoatId`
--     `ownedShipSkinIds`  → `ownedBoatIds`
--     `resolvedShip`      → `resolvedBoat`
--   Server methods (`OilStateService`):
--     `:SetShipSkinId`    → `:SetEquippedBoatId`
--     `:GrantShipSkin`    → `:GrantBoat`
--     `:OwnsShipSkin`     → `:OwnsBoat`
--   Remote (`RemoteNames`):
--     `RequestSetShipSkin` → `RequestSetEquippedBoat`
--   Boat instance attribute:
--     `ShipSkinId`         → `BoatId`
--   `ShipStats` helpers:
--     `ResolveForSkin`     → `ResolveForBoat`
--     `LevelsForSkin`      → `LevelsForBoat`
-- Profile bumped v9 → v10 with a one-shot migration in
-- `OilStateService._applyPersistedIntoState`: Robux-purchased boats
-- carry forward into `ownedBoatIds`; cash-purchased boats reset to
-- starter only (the equipped boat resets to starter unless the saved
-- equip was Robux). See the Step 6 history block in `OilStateService`
-- for the migration rationale.
--
-- ─────────────────────────────────────────────────────────────────
-- Step 1 (DONE): new `progressionIndex` / `speedLevel` /
-- `capacityLevel` / `unlock` fields authored on every live entry; 10
-- placeholder `Tier1Boat` … `Tier10Boat` entries added with
-- `placeholder = true` and filtered out of all client-facing
-- iteration sites. (2026-04-22: dedicated `Tier{N}Boat` models now
-- live in `ReplicatedStorage.Assets`; `templateName` updated per
-- entry. `Tier9Boat` still resolves to `Tanker` by design.)
--
-- Step 2 (DONE): `ShipStats.ResolveForBoat(boatId)` reads `speedLevel`
-- / `capacityLevel` directly from the equipped entry below — this is
-- now the canonical source of truth for runtime stat resolution
-- (`OilStateService` snapshot `resolvedBoat`, `OilShipmentService`
-- dispatch + 7 debug helpers, both UI panel fallbacks).
--
-- Step 3 (DONE): unlock + inventory plumbing landed —
-- `RequestUnlockBoat` remote, `OilStateService:TryUnlockBoat`
-- (starter / cash / Robux routing), starter boat auto-grant on
-- profile load, and defensive `BoatCatalog.IsBoatPurchasable` gate at
-- every grant / equip / snapshot site so placeholders cannot be
-- promoted by tampered profiles or future bugs.
--
-- Step 4 (DONE): tore down the per-player upgrade ladder. Deleted the
-- `RequestUpgradeShipSpeed` / `RequestUpgradeShipCapacity` remotes +
-- handlers, `OilStateService:TryUpgradeShipSpeed/Capacity`, the
-- `shipSpeedLevel` / `shipCapacityLevel` profile + snapshot fields,
-- the `WaitDocksUpgradeShip` FTUE leg + dockman beam + sub-step
-- attribute, the `ftueFreeCargoCapacityUpgradeUsed` flag, and the
-- dead `BoatConfig.luau` + `OilShipmentService:_createFallbackBoat`.
-- Speed/capacity are baked per-boat in `BoatCatalog.Boats[boatId]`
-- (`speedLevel` / `capacityLevel`); progression happens via the
-- unlock flow (`OilStateService:TryUnlockBoat`) + the equip flow
-- (`OilStateService:SetEquippedBoatId`).
--
-- Step 5 (SKIPPED): authoring 10 distinct boat templates was
-- deferred. Every `Tier*Boat` placeholder below uses the `Tanker`
-- template so the full progression chain is equippable today (rig
-- overrides + owner teleport / crewmate spots inherit Tanker
-- semantics). Tune visuals + per-tier hulls in a post-Step-7 content
-- pass.
--
-- Step 6 (THIS REVISION): Skin → Boat rename across the codebase.
--
-- Placeholder *stat* values still ship as-authored (linear 1..10 /
-- 1..10), so equipping a `Tier*Boat` is now safe but not yet tuned
-- for live pacing. Tune cash-cost curve + speed/capacity numbers
-- before opening the boat-inventory UI to public play.

export type RigDef = {
	dockAnchorName: string,
	frontMarkerName: string,
	deckAnchorName: string,
	deckTopAnchorName: string,
	deckYOffsetFallback: number,
	deckSeatName: string,
	barrelStackRootName: string,
	playerFlagName: string,
	standForwardOffset: number,
	standRightOffset: number,
}

export type RigOverride = {
	dockAnchorName: string?,
	frontMarkerName: string?,
	deckAnchorName: string?,
	deckTopAnchorName: string?,
	deckYOffsetFallback: number?,
	deckSeatName: string?,
	barrelStackRootName: string?,
	playerFlagName: string?,
	standForwardOffset: number?,
	standRightOffset: number?,
}

--- How a player gains ownership of a boat. Authored per-entry; consumed by
--- `OilStateService:TryUnlockBoat` (Step 3).
---
---  * `starter` — auto-granted on first profile load. No cost fields.
---  * `cash`    — unlocked via in-game cash (`cashCost`). Cash boats fill
---                progressionIndex slots between the starter and the Robux
---                tier; only one purchase required (no per-level upgrades).
---  * `robux`   — sold as a DevProduct (`devProductId`). `MonetizationCatalog`
---                still owns the actual product wiring; this field exists so
---                future code can ask "what is this boat's unlock?" without
---                cross-referencing the monetization table.
export type BoatUnlockKind = "starter" | "cash" | "robux"

export type BoatUnlock = {
	kind: BoatUnlockKind,
	cashCost: number?,
	devProductId: number?,
}

export type BoatDef = {
	displayName: string,
	templateName: string,
	fxParticleScale: number?,
	rarityDisplay: string?,
	rig: RigOverride?,
	--- 2D icon for the Fleet panel boat card + right-column hero slot.
	--- Painted into the `ImageLabel` shells by `FleetPanelPopulate.Apply`
	--- and `FleetPanelPopulate.HydrateRightColumn`. When `nil` the slot
	--- stays as the empty grey shell so a missing icon is visually obvious
	--- in Studio rather than crashing the panel.
	icon: string?,
	--- Boat's slot in the 1..10 progression chain (1 = starter,
	--- 10 = top-tier). Indices must be unique once all 10 boats are
	--- authored. `speedLevel` / `capacityLevel` are clamped to
	--- `ShipUpgradeConfig.MaxSpeedLevel` / `MaxCapacityLevel`
	--- (currently 10) and feed the existing level → number tables in
	--- `ShipUpgradeConfig` via `ShipStats.ResolveForBoat`.
	progressionIndex: number?,
	speedLevel: number?,
	capacityLevel: number?,
	unlock: BoatUnlock?,
	--- Internal flag — when true the entry is a Step 1 placeholder for the
	--- 10-tier progression chain. Filtered out at every iteration site that
	--- feeds the client (`ListForClient`) and rejected by every server
	--- gate that consumes a player-supplied id (`IsBoatPurchasable`) so a
	--- tampered profile or malicious remote can't promote a placeholder
	--- into a live equippable / ownable boat.
	placeholder: boolean?,
}

local DEFAULT_RIG: RigDef = {
	dockAnchorName = "DockAnchor",
	frontMarkerName = "FRONT_MARKER",
	deckAnchorName = "DeckAnchor",
	deckTopAnchorName = "DeckTopAnchor",
	deckYOffsetFallback = 15,
	deckSeatName = "DeckSeat",
	barrelStackRootName = "BarrelStackRoot",
	playerFlagName = "PlayerFlag",
	standForwardOffset = -5,
	standRightOffset = 4,
}

local TEMPLATE_RIG_OVERRIDES: { [string]: RigOverride } = {
	-- Per-template placement semantics. Override these when a hull does not match Tanker defaults.
	---
	--- Tanker uses an authored `DeckAnchor` Attachment on the foredeck
	--- (parented to the hull `Union`, sibling of `DeckTopAnchor`,
	--- `WorldPosition ≈ (15, 24.62, 1.56)` in template-local space — 10
	--- studs forward of the cabin's front wall on the open foredeck
	--- platform). `BoatDockService.resolveOwnerStandCFrame` picks
	--- `DeckAnchor` first in its `(deckAnchor → seat → barrelStackRoot)`
	--- chain, so the owner teleport lands on the foredeck instead of
	--- inside the cabin. `DeckSeat` is intentionally LEFT IN PLACE for
	--- other systems (`StraitWaypointWorldFx.raycastBoatDeckY`'s seat
	--- fallback, calibration tooling, etc.) — the new `DeckAnchor` is
	--- 16.56 studs from the seat, which is well past the sidestep
	--- guard's 6-stud trigger, so the seat is never consulted at runtime.
	---
	--- Both `standForwardOffset` and `standRightOffset` are zeroed so the
	--- player lands EXACTLY at the `DeckAnchor` XZ. The earlier in-cabin
	--- landing (with the default `(-5, +4)` offsets pointing at the seat)
	--- placed the player's HRP at `X≈31.58`, which is precisely the X-edge
	--- of the cabin ceiling slab at Y=33.88-34.50 (the slab spans
	--- X=25.31 to X=31.56). The player's head Y≈35 intersected that slab
	--- volume, and Roblox's overlap resolution ejected the character
	--- forward — the "pushed forward out of the room" symptom. The
	--- foredeck spot has open sky above (verified via column raycast),
	--- so no ejection.
	---
	--- Final landing (verified end-to-end on the template):
	---   `(X=15, Y=34.38, Z=1.56)` — feet ≈ Y=31.88 on the foredeck
	---   platform (`Part @ Y=26.38`, `size=18.75 × 0.625 × 18.75`).
	---
	--- Other ship rigs (Raft, PirateShip, Ducky, Whale) intentionally
	--- inherit the `(-5, +4)` defaults from `DEFAULT_RIG` — they have
	--- different hull layouts and DO NOT have a custom `DeckAnchor` yet,
	--- so the seat-sidestep path is still authoritative for them.
	Tanker = {
		deckYOffsetFallback = 15,
		standForwardOffset = 0,
		standRightOffset = 0,
	},
	Raft = {
		deckYOffsetFallback = 15,
	},
	PirateShip = {
		deckYOffsetFallback = 15,
	},
	Ducky = {
		deckYOffsetFallback = 15,
	},
	--- `SurfboardBoat`: small hull; match other compact decks until dock
	--- calibration is run in Studio.
	SurfboardBoat = {
		deckYOffsetFallback = 15,
	},
	Whale = {
		deckYOffsetFallback = 15,
	},
	--- Tier10Boat (Normandy): the DEFAULT_RIG `(-5, +4)` stand offsets
	--- landed the player on a sloped / deflecting section of the hull at
	--- dock teleport, immediately sliding them off. Zeroed offsets (same
	--- shape as Tanker) place the player directly at the `DeckAnchor` XZ
	--- on a flat area of the deck. If the slide persists, the next step
	--- is to reposition `DeckSeat` / `DeckAnchor` in the template to a
	--- verified-flat deck footprint.
	Tier10Boat = {
		deckYOffsetFallback = 15,
		standForwardOffset = 0,
		standRightOffset = 0,
	},
	--- Tier3Boat (lifeboat): small inflatable deck; default `(-5, +4)` sidesteps
	--- can land the owner on tube slope / thin colliders and feels like hull
	--- "collision" bugs. Match Tanker/Tier10: stand at authored `DeckAnchor` XZ.
	Tier3Boat = {
		deckYOffsetFallback = 15,
		standForwardOffset = 0,
		standRightOffset = 0,
	},
}

local function applyRigOverride(rig: RigDef, over: RigOverride?)
	if not over then
		return
	end
	if typeof(over.dockAnchorName) == "string" and over.dockAnchorName ~= "" then
		rig.dockAnchorName = over.dockAnchorName
	end
	if typeof(over.frontMarkerName) == "string" and over.frontMarkerName ~= "" then
		rig.frontMarkerName = over.frontMarkerName
	end
	if typeof(over.deckAnchorName) == "string" and over.deckAnchorName ~= "" then
		rig.deckAnchorName = over.deckAnchorName
	end
	if typeof(over.deckTopAnchorName) == "string" and over.deckTopAnchorName ~= "" then
		rig.deckTopAnchorName = over.deckTopAnchorName
	end
	if typeof(over.deckYOffsetFallback) == "number" then
		rig.deckYOffsetFallback = over.deckYOffsetFallback
	end
	if typeof(over.deckSeatName) == "string" and over.deckSeatName ~= "" then
		rig.deckSeatName = over.deckSeatName
	end
	if typeof(over.barrelStackRootName) == "string" and over.barrelStackRootName ~= "" then
		rig.barrelStackRootName = over.barrelStackRootName
	end
	if typeof(over.playerFlagName) == "string" and over.playerFlagName ~= "" then
		rig.playerFlagName = over.playerFlagName
	end
	if typeof(over.standForwardOffset) == "number" then
		rig.standForwardOffset = over.standForwardOffset
	end
	if typeof(over.standRightOffset) == "number" then
		rig.standRightOffset = over.standRightOffset
	end
end

local function buildRig(templateName: string, boatRigOverride: RigOverride?): RigDef
	local rig: RigDef = {
		dockAnchorName = DEFAULT_RIG.dockAnchorName,
		frontMarkerName = DEFAULT_RIG.frontMarkerName,
		deckAnchorName = DEFAULT_RIG.deckAnchorName,
		deckTopAnchorName = DEFAULT_RIG.deckTopAnchorName,
		deckYOffsetFallback = DEFAULT_RIG.deckYOffsetFallback,
		deckSeatName = DEFAULT_RIG.deckSeatName,
		barrelStackRootName = DEFAULT_RIG.barrelStackRootName,
		playerFlagName = DEFAULT_RIG.playerFlagName,
		standForwardOffset = DEFAULT_RIG.standForwardOffset,
		standRightOffset = DEFAULT_RIG.standRightOffset,
	}
	applyRigOverride(rig, TEMPLATE_RIG_OVERRIDES[templateName])
	applyRigOverride(rig, boatRigOverride)
	return rig
end

--- Boat progression chain.
---
--- 2026-04-22 (Step 7 consolidation): the legacy `DefaultTanker` /
--- `Ship3Skin` / `Ship4Skin` / `Ship5Skin` / `WhaleSkin` ids are
--- RETIRED. All cash boats live on the `Tier1Boat`..`Tier10Boat` chain
--- (Tier1 is the new starter, Tier9 still reuses the `Tanker` template
--- — no dedicated model). Robux boats live on premium ids (`PirateShip`,
--- `Surfboat`, `Ducky`, `Moby`, `AmericanEagleBoat`) that sort AFTER the
--- cash chain via `progressionIndex` 11..15 and reuse templates under
--- `ReplicatedStorage.Assets` (e.g. `SurfboardBoat`, `Whale`, …).
---
--- Existing v10 saves migrate via `BoatCatalog.RemapLegacyBoatId` (called
--- from `OilStateService._applyPersistedIntoState` before any catalog
--- gate runs) — Robux purchases carry forward to the new ids; cash-only
--- legacy saves drop to the starter (Tier1Boat). See the v10 → v11
--- block in `OilStateService` for the full mapping.
---
---  | idx | id                | display name    | template          | spd/cap | rarity     | unlock                       |
---  |-----|-------------------|-----------------|-------------------|---------|------------|------------------------------|
---  |  1  | Tier1Boat         | Raft            | Tier1Boat         | 1 / 1   | Common     | starter (auto-grant)         |
---  |  2  | Tier2Boat         | Row Row Row     | Tier2Boat         | 2 / 2   | Common     | cash $1,000                  |
---  |  3  | Tier3Boat         | Lifeboat        | Tier3Boat         | 3 / 3   | Uncommon   | cash $5,000                  |
---  |  4  | Tier4Boat         | SAIL            | Tier4Boat         | 4 / 4   | Uncommon   | cash $15,000                 |
---  |  5  | Tier5Boat         | Farmboat        | Tier5Boat         | 5 / 5   | Uncommon   | cash $50,000                 |
---  |  6  | Tier6Boat         | Big Blue        | Tier6Boat         | 4 / 7   | Rare       | cash $175,000                |
---  |  7  | Tier7Boat         | Green Machine   | Tier7Boat         | 6 / 5   | Rare       | cash $600,000                |
---  |  8  | Tier8Boat         | Daddy's Money   | Tier8Boat         | 7 / 6   | Rare       | cash $900,000                |
---  |  9  | Tier9Boat         | Da Rig          | Tanker            | 6 / 8   | Epic       | cash $2,200,000              |
---  | 10  | Tier10Boat        | Normandy        | Tier10Boat        | 7 / 8   | Epic       | cash $5,500,000              |
---  | 11  | PirateShip        | The Sparrow     | PirateShip        | 8 / 8   | Epic       | robux R$149  (DP 3578818285) |
---  | 12  | Surfboat          | Surfboat        | SurfboardBoat     | 8 / 8   | Epic       | robux R$199  (DP 3582274032) |
---  | 13  | Ducky             | Jet Duck        | Ducky             | 9 / 9   | Legendary  | robux R$299  (DP 3578818474) |
---  | 14  | Moby              | Moby            | Whale             | 9 / 10  | Legendary  | robux R$299  (DP 3578818669) |
---  | 15  | AmericanEagleBoat | The Patriot  | AmericanEagleBoat | 10 / 10   | Mythic  | robux R$499  (DP 3580438808)   |
---
--- Stat shape:
---   * T1..T5 are linear straight upgrades.
---   * T6..T10 are deliberate sidegrades (speed ↔ capacity tradeoffs)
---     so the late-game player picks a hull that matches their farming
---     pattern rather than always equipping the most expensive one.
---   * Robux speed/capacity go up to 9/9 on the mid-premium boats; the
---     `AmericanEagleBoat` (The Patriot) Mythic hull is 10/10.
---
--- Cost curve: cheap early (T2..T4 unlock fast in the first session), then
--- steeper steps through T7. T8–T10 stay aspirational but sit in the same
--- order of magnitude as other big sinks (e.g. full warehouse upgrades
--- ≈ $2.36M): T8 under that bar, T9 ~warehouse-scale, T10 a multi-session
--- prestige cap. Cumulative T2 → T10 ≈ $9.45M — re-tune with live
--- cash-per-shipment data if needed.
local BoatCatalog = {
	Boats = {
		-- ─────────────────────────────────────────────────────────────────
		-- Robux premium boats. They sort after the cash chain via the
		-- explicit `progressionIndex` (11..15) and use existing templates
		-- in `ReplicatedStorage.Assets`. DevProductIds match the original
		-- `Ship4Skin` / `Ship5Skin` / `WhaleSkin` listings — the v10 → v11
		-- profile remap (see `BoatCatalog.RemapLegacyBoatId` +
		-- `OilStateService._applyPersistedIntoState`) carries existing
		-- buyers' ownership forward.
		-- ─────────────────────────────────────────────────────────────────
		PirateShip = {
			displayName = "The Sparrow",
			templateName = "PirateShip",
			fxParticleScale = 1,
			rarityDisplay = "Epic",
			icon = "rbxassetid://80699672548624",
			progressionIndex = 11,
			speedLevel = 8,
			capacityLevel = 8,
			unlock = { kind = "robux", devProductId = 3578818285 },
		},
		Surfboat = {
			displayName = "Surfboat",
			templateName = "SurfboardBoat",
			fxParticleScale = 1,
			rarityDisplay = "Epic",
			icon = "rbxassetid://111201898460303",
			progressionIndex = 12,
			speedLevel = 8,
			capacityLevel = 8,
			--- Keep in sync with `MonetizationCatalog` `ship.surfboat` DevProduct id.
			unlock = { kind = "robux", devProductId = 3582274032 },
		},
		Ducky = {
			displayName = "Jet Duck",
			templateName = "Ducky",
			fxParticleScale = 1,
			rarityDisplay = "Legendary",
			icon = "rbxassetid://122817352338651",
			progressionIndex = 13,
			speedLevel = 9,
			capacityLevel = 9,
			unlock = { kind = "robux", devProductId = 3578818474 },
		},
		Moby = {
			displayName = "Moby",
			templateName = "Whale",
			fxParticleScale = 1.2,
			rarityDisplay = "Legendary",
			icon = "rbxassetid://77447218245868",
			progressionIndex = 14,
			speedLevel = 9,
			capacityLevel = 10,
			unlock = { kind = "robux", devProductId = 3578818669 },
		},

		AmericanEagleBoat = {
			displayName = "The Patriot",
			templateName = "AmericanEagleBoat",
			fxParticleScale = 1,
			rarityDisplay = "Mythic",
			icon = "rbxassetid://121375807397511",
			progressionIndex = 15,
			speedLevel = 10,
			capacityLevel = 10,
			unlock = { kind = "robux", devProductId = 3580438808 },
		},

		-- ─────────────────────────────────────────────────────────────────
		-- Tier progression chain (cash unlocks). `Tier1Boat` is the
		-- auto-granted starter; the rest cost cash. Each `templateName`
		-- matches a model in `ReplicatedStorage.Assets`, EXCEPT `Tier9Boat`
		-- which intentionally reuses the existing `Tanker` template (no
		-- dedicated Tier9 model — user decision 2026-04-22).
		--
		-- Stat shape (user spec 2026-04-22):
		--   * T1..T5 are linear straight upgrades.
		--   * T6..T10 are intentional sidegrades — speed and capacity
		--     trade off against each other so the player has to choose
		--     a hull that matches their farming pattern (e.g. T7 "Green
		--     Machine" = 6/5 favors fast trips on a small load; T9
		--     "Normandy" = 6/8 favors fewer, fuller runs).
		--   * Premium Robux boats (`PirateShip` / `Surfboat` / `Ducky` / `Moby`) are
		--     authored above and outclass the cash chain on capacity.
		--
		-- Cost curve: early tiers stay cheap so first-session players cycle
		-- through several unlocks; T6–T7 ramp hard. T8–T10 were pulled down
		-- from the original multi-million cap so they remain long-tail goals
		-- without dwarfing realistic income (warehouse + shipment loop).
		-- ─────────────────────────────────────────────────────────────────
		Tier1Boat = {
			displayName = "Raft",
			templateName = "Tier1Boat",
			fxParticleScale = 1,
			rarityDisplay = "Common",
			icon = "rbxassetid://118810475637842",
			progressionIndex = 1,
			speedLevel = 1,
			capacityLevel = 1,
			unlock = { kind = "starter" },
		},
		Tier2Boat = {
			displayName = "Row Row Row",
			templateName = "Tier2Boat",
			fxParticleScale = 1,
			rarityDisplay = "Common",
			icon = "rbxassetid://90595303892828",
			progressionIndex = 2,
			speedLevel = 2,
			capacityLevel = 2,
			unlock = { kind = "cash", cashCost = 1000 },
		},
		Tier3Boat = {
			displayName = "Lifeboat",
			templateName = "Tier3Boat",
			fxParticleScale = 1,
			rarityDisplay = "Uncommon",
			icon = "rbxassetid://101499902955059",
			progressionIndex = 3,
			speedLevel = 3,
			capacityLevel = 3,
			unlock = { kind = "cash", cashCost = 5000 },
		},
		Tier4Boat = {
			displayName = "SAIL",
			templateName = "Tier4Boat",
			fxParticleScale = 1,
			rarityDisplay = "Uncommon",
			icon = "rbxassetid://78390804508152",
			progressionIndex = 4,
			speedLevel = 4,
			capacityLevel = 4,
			unlock = { kind = "cash", cashCost = 15000 },
		},
		Tier5Boat = {
			displayName = "Farmboat",
			templateName = "Tier5Boat",
			fxParticleScale = 1,
			rarityDisplay = "Uncommon",
			icon = "rbxassetid://134264640685366",
			progressionIndex = 5,
			speedLevel = 5,
			capacityLevel = 5,
			unlock = { kind = "cash", cashCost = 50000 },
		},
		Tier6Boat = {
			-- Sidegrade: high cap, lower speed than T5. First "fewer, fuller
			-- runs" choice in the chain.
			displayName = "Big Blue",
			templateName = "Tier6Boat",
			fxParticleScale = 1,
			rarityDisplay = "Rare",
			icon = "rbxassetid://72538035960778",
			progressionIndex = 6,
			speedLevel = 4,
			capacityLevel = 7,
			unlock = { kind = "cash", cashCost = 175000 },
		},
		Tier7Boat = {
			-- Sidegrade: opposite of T6 — speed up, capacity drops back
			-- below T5. For players who want fast cycles on small loads.
			displayName = "Green Machine",
			templateName = "Tier7Boat",
			fxParticleScale = 1,
			rarityDisplay = "Rare",
			icon = "rbxassetid://137061133395778",
			progressionIndex = 7,
			speedLevel = 6,
			capacityLevel = 5,
			unlock = { kind = "cash", cashCost = 600000 },
		},
		Tier8Boat = {
			-- Balanced: best mid-tier all-rounder so far (7 spd / 6 cap).
			displayName = "Daddy's Money",
			templateName = "Tier8Boat",
			fxParticleScale = 1,
			rarityDisplay = "Rare",
			icon = "rbxassetid://93752019688739",
			progressionIndex = 8,
			speedLevel = 7,
			capacityLevel = 6,
			unlock = { kind = "cash", cashCost = 900000 },
		},
		Tier9Boat = {
			-- Cap-focused late-game hull (templateName intentionally
			-- reuses `Tanker`). List icon: classic tanker preview (same
			-- art direction as the loaded `Tanker` 3D template).
			displayName = "Da Rig",
			templateName = "Tanker",
			fxParticleScale = 1,
			rarityDisplay = "Epic",
			icon = "rbxassetid://110257950618296",
			progressionIndex = 9,
			speedLevel = 6,
			capacityLevel = 8,
			unlock = { kind = "cash", cashCost = 2200000 },
		},
		Tier10Boat = {
			-- Top of the cash chain. Capacity ties Da Rig but speed climbs
			-- back to 7 — strict upgrade over T9 once you can afford it.
			displayName = "Normandy",
			templateName = "Tier10Boat",
			fxParticleScale = 1.2,
			rarityDisplay = "Epic",
			icon = "rbxassetid://105632153359221",
			progressionIndex = 10,
			speedLevel = 7,
			capacityLevel = 8,
			unlock = { kind = "cash", cashCost = 5500000 },
		},
	} :: { [string]: BoatDef },
}

function BoatCatalog.GetBoat(boatId: string?): BoatDef
	local id = if typeof(boatId) == "string" and boatId ~= "" then boatId else "Tier1Boat"
	local b = BoatCatalog.Boats[id]
	if b then
		return b
	end
	return BoatCatalog.Boats.Tier1Boat
end

function BoatCatalog.GetRigForTemplate(templateName: string?): RigDef
	local name = if typeof(templateName) == "string" and templateName ~= "" then templateName else "Tanker"
	return buildRig(name, nil)
end

function BoatCatalog.GetRigForBoat(boatId: string?): RigDef
	local boat = BoatCatalog.GetBoat(boatId)
	return buildRig(boat.templateName, boat.rig)
end

--- Returns the set of catalog ids whose `unlock.kind == "starter"`.
--- Consumed by `OilStateService` profile load to seed `ownedBoatIds`
--- data-drivenly (instead of hardcoding `"Tier1Boat"`) and to backfill
--- the starter on every load so a catalog rename / migration can never
--- strand a player without an equippable boat. `placeholder = true`
--- entries (none today; reserved for future Step-1-style staging) are
--- filtered out so they cannot be auto-granted.
---
--- Defensive guarantee: if the catalog has *no* starter entries
--- (hand-edit error), this returns `{ Tier1Boat = true }` so the
--- player's profile still ends up with a known-good owned boat.
function BoatCatalog.GetStarterBoatIds(): { [string]: boolean }
	local out: { [string]: boolean } = {}
	for boatId, def in pairs(BoatCatalog.Boats) do
		if def.placeholder then
			continue
		end
		local unlock = def.unlock
		if typeof(unlock) == "table" and unlock.kind == "starter" then
			out[boatId] = true
		end
	end
	if next(out) == nil then
		out.Tier1Boat = true
	end
	return out
end

--- Maps retired v10 boat ids to their v11 successors. Returns `nil` for ids
--- that should be DROPPED from the player's inventory on migration (e.g.
--- `Ship3Skin`, which was a Robux item with `productId = 0` and was never
--- actually sold). Returns the input unchanged for ids that survived the
--- consolidation. Consumed by `OilStateService._applyPersistedIntoState`
--- BEFORE `IsBoatPurchasable` / `IsBoatRobuxOwned` gates run, so a v10 save
--- carrying `Ship4Skin` in `ownedBoatIds` correctly carries forward as
--- `PirateShip` (Robux purchase preserved) instead of being rejected by the
--- gate and reset to the starter.
---
--- The mapping mirrors the user-signed-off migration policy from 2026-04-22:
---   * Robux purchases survive (`Ship4Skin` → `PirateShip`,
---     `Ship5Skin` → `Ducky`, `WhaleSkin` → `Moby`).
---   * `DefaultTanker` (the old starter) → `Tier1Boat` (the new starter)
---     so anyone with the old equip auto-equips the new one.
---   * `Ship3Skin` drops silently (never sold for real money).
local LEGACY_BOAT_ID_REMAP: { [string]: string? } = {
	DefaultTanker = "Tier1Boat",
	Ship3Skin = nil :: string?,
	Ship4Skin = "PirateShip",
	Ship5Skin = "Ducky",
	WhaleSkin = "Moby",
}
local LEGACY_BOAT_ID_DROP: { [string]: boolean } = {
	Ship3Skin = true,
}

function BoatCatalog.RemapLegacyBoatId(boatId: string?): string?
	if typeof(boatId) ~= "string" or boatId == "" then
		return nil
	end
	if LEGACY_BOAT_ID_DROP[boatId] then
		return nil
	end
	local mapped = LEGACY_BOAT_ID_REMAP[boatId]
	if mapped ~= nil then
		return mapped
	end
	return boatId
end

--- Returns `true` iff `boatId` resolves to a non-placeholder catalog
--- entry. Used as a defense-in-depth gate by every server method that
--- consumes a player-supplied `boatId` (`SetEquippedBoatId`,
--- `GrantBoat`, `TryUnlockBoat`) so a tampered profile or a malicious
--- remote payload can't promote a Step 1 placeholder
--- (`Tier1Boat` … `Tier10Boat`) into a live equippable / ownable boat.
--- A future content pass will retire the placeholders entirely once
--- the 10 real entries are authored; until then this gate is the
--- single chokepoint.
function BoatCatalog.IsBoatPurchasable(boatId: string?): boolean
	if typeof(boatId) ~= "string" or boatId == "" then
		return false
	end
	local def = BoatCatalog.Boats[boatId]
	if not def then
		return false
	end
	if def.placeholder then
		return false
	end
	return true
end

--- Returns `true` iff `boatId` resolves to a Robux-unlocked,
--- non-placeholder catalog entry. Consumed by the v9 → v10 profile
--- migration in `OilStateService._applyPersistedIntoState` so that
--- Robux-purchased boats from old saves carry forward into the new
--- `ownedBoatIds`, while cash-purchased boats reset to starter
--- (intentional — see Step 6 history block in `OilStateService`).
function BoatCatalog.IsBoatRobuxOwned(boatId: string?): boolean
	if typeof(boatId) ~= "string" or boatId == "" then
		return false
	end
	local def = BoatCatalog.Boats[boatId]
	if not def or def.placeholder then
		return false
	end
	local unlock = def.unlock
	if typeof(unlock) ~= "table" then
		return false
	end
	return unlock.kind == "robux"
end

function BoatCatalog.ListForClient(): { { boatId: string, displayName: string, rarityDisplay: string? } }
	local list = {}
	for boatId, def in pairs(BoatCatalog.Boats) do
		-- Skip Step 1 placeholder tier entries — they exist for schema
		-- reference only and must not surface in the live oil snapshot,
		-- which feeds `RobuxShopPanel` / `ShipManagementPanel`.
		if def.placeholder then
			continue
		end
		table.insert(list, {
			boatId = boatId,
			displayName = def.displayName,
			rarityDisplay = def.rarityDisplay,
		})
	end
	table.sort(list, function(a, b)
		return a.displayName < b.displayName
	end)
	return list
end

return BoatCatalog
