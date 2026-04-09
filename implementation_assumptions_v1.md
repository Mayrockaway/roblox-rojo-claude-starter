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
- Partial delivery is HP-proportional:
  - `delivered = floor(loaded * clamp(hpPercent, 0, 1))`
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
  - Heavy Crude
  - Standard Crude
  - Light Sweet
  - Premium Refined
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

## Notes

- These are provisional defaults to unblock implementation quickly.
- They can be revised with a migration pass once final balancing decisions are made.
