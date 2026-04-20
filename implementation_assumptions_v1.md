# Oil Empire: Build-Ready Assumptions (v1)

This file locks provisional decisions so implementation can proceed now.
Rows marked `ProposedDefault` in `design_clarifications_template.csv` map to these assumptions.

## Core

- Strait state is universe-wide.
- Strait rolls every 180s with +/-45s jitter.
- Price multiplier is locked at departure.
- Risk is dynamic during travel.
- If state becomes Closed mid-shipment, shipment continues with high risk floor (10% destruction floor).
- Closed state allows local sell at flat `0.5x`, quality ignored.

## Shipment

- Multiple shipments allowed; max 30 active per player.
- No shipment cooldown.
- At voyage completion, delivered barrels match the **loaded manifest** (whole units), minus any **strait barrel-loss** events that removed cargo during the trip. There is **no hull / HP delivery gate**.
- Events are RNG-driven, with no strict per-shipment max cap.
- Catastrophic events can occur in all states at different probabilities.
- Delay events can increase additional event opportunities.

## Upgrades

- Upgrades are excluded from MVP progression economy depth, but minimal hooks exist.
- Snapshot rule for shipment stats:
  - Upgrades apply to future shipments only.
  - In-flight shipments do not change after dispatch.
- Default caps for safety:
  - Pump `<=200`, Storage `<=200`, Durability `<=100`, Escort `<=100`, Quality `<=100`.

## Quality Barrels

- Quality tiers enabled in MVP:
  - Crude
  - Refined
  - Premium
- Mining sources use probability distributions to output quality tiers.
- A single pump can produce multiple tiers over time.
- Storage tracked separately per tier, with shared global capacity.
- Player manually chooses barrel composition for each shipment.
- Auto-fill order default: highest value first.
- Pricing model: multiplicative quality modifiers (per-tier multipliers).
- Damage affects quantity only, not tier downgrades.
- Closed local sell ignores quality (flat `0.5x`).
- Persist:
  - stored oil by tier
  - in-flight cargo composition by tier
  - pending payout state

## Economic Safety Bounds

- State multiplier clamp: `[0.25, 10.0]`
- Quality multiplier clamp: `[0.5, 5.0]`
- Total payout multiplier hard cap: `20.0x`

## Equipment shop & placed equipment (drills-only)

- The **only** purchasable, player-placeable equipment is the **drill** (`Drill_T1` / `T2` / `T3` shipped; `T4` / `T5` / `T6` are placeholder "Coming soon" rows, see `EquipmentCatalog.luau`).
- Drills are **consumable, one-shot** tools: equip → click an unlocked chunk tile → server starts a drill timer → tile enters "reveal pending" when the timer ends → player presses **E** on the spawned `DrillComplete` model to reveal the vein.
- **Pumps** are not purchasable and not player-placeable. A single **static center pump** is auto-spawned by the server at each unlocked chunk (see `OilStateService` + `OilVisualService:_syncDrills`) and pulls oil from any drilled tiles in that chunk. Pump **tier** + visual upgrades come from in-world proximity prompts, not the equipment shop.
- **Pipes**, **drums**, and **prospectors** were removed entirely (configs, remotes, Studio assets, Tool templates, FTUE legs, persisted state). `PipeNetworkService` and `ProspectingService` no longer exist; `RS.Assets.Pipe / Drum / Prospector` Models were deleted from Studio. Do not reintroduce them as Tools — design decisions live here, not in the codebase.
- **Barrel** assets remain — they visualize oil moving from drilled tiles → center pump → refinery storage and are **not** equipment.
- Per-stat upgrade caps elsewhere in this doc (e.g. `Pump <= 200`) refer to the **ship `PumpLevel` ladder**, not the deleted Pump tool.

## Notes

- These are provisional defaults to unblock implementation quickly.
- They can be revised with a migration pass once final balancing decisions are made.
