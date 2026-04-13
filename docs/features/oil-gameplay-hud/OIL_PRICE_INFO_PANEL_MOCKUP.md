# Oil price info panel — mockup & intent

**Purpose:** Read-only **infographic** with **three barrel tiers** only:

1. **Crude** — one crude grade (single row; no separate heavy/standard split).
2. **Light sweet**
3. **Premium refined**

Opens when the player **clicks `HUD.Canvas.TopRow.OilPricePanel.Row.OilPriceButton`**. **No scrolling** for v1.

**Visual mockup (image):** `assets/oil-price-info-panel-mockup.png`.

## Track gradient (all rows use the same read)

Each **`PriceTrack`** uses a **`UIGradient`** on the bar background (or a dedicated fill **`Frame`**) with **three stops**:

| Position | Color role |
|----------|------------|
| **Left (0)** | **Red** |
| **Center (~0.5)** | **Yellow / warm neutral** (muted gold or soft amber) |
| **Right (1)** | **Green** |

So the bar reads **red → yellowish neutral → green** left to right. **Markers** still use **horizontal position** (scale **X**) for “where price sits” on the global band; only the **chromatic cue** changes from older blue→red specs.

Example **`ColorSequence`** (tune in Studio):

- `0` — `Color3.fromRGB(200, 55, 55)` (red)
- `0.5` — `Color3.fromRGB(220, 190, 100)` (yellow-neutral)
- `1` — `Color3.fromRGB(70, 160, 95)` (green)

## Style parity with `StraitInfoPanelGui`

- **`OilPriceInfoPanelGui`**: **`IgnoreGuiInset = true`**, **`ResetOnSpawn = false`**, **`Enabled = false`**, **`DisplayOrder`** e.g. **39**.
- **`Canvas`**, **`Dimmer`**, **`PanelHost`** + **`UIAspectRatioConstraint`**, **`Panel`** black + gold **`UIStroke`**, **`UICorner`** ~**0.035** scale.
- **`CloseButton`**: same pattern as **`StraitInfoPanelGui`**.
- **`Body`**: scale **`UIPadding`** + vertical **`UIListLayout`**.

## Content layout (three rows)

1. **`HeaderRow`** — **`Oil prices`**, subtitle **`Per barrel · live market`**.
2. **`StraitContextStrip`** (optional) — strait state + one short line.
3. **`CrudeRow`** — label **Crude** (or match your catalog name for the single crude tier, e.g. **Standard crude** if that is the only crude product in UI). **`PriceTrack`** + **`Marker`** + **`PriceValue`** (`$/bbl`).
4. **`LightSweetRow`** — same structure.
5. **`PremiumRow`** — same structure.
6. **`FooterDisclaimer`** — one line on multipliers / base if needed.

## Data (`PricingConfig.luau`)

- Map **Crude** row to the **one** crude **`TypeMultipliers`** entry you ship (e.g. **StandardCrude** only, or rename in catalog later). **Light sweet** → **LightSweet**, **Premium** → **PremiumRefined**.
- **Heavy crude** is **out of this panel** by design.
- Marker **X** = normalize current type price into **`[GlobalBaseMin * mult, GlobalBaseMax * mult]`** or a single global dollar band — **pick one rule** and keep it consistent across the three rows.

## Wiring (checklist)

- [ ] **`StarterGui.OilPriceInfoPanelGui`** shell like strait panel.
- [x] **`OilPriceButton`** → toggle **`OilPriceInfoPanelGui.Enabled`** (exclusive with other HUD modals); **`CloseButton`** closes (dimmer does not close).
- [ ] Runtime: **marker X** + **`PriceValue.Text`** only (disclose in PR).
