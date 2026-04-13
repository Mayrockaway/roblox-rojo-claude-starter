# Sell Oil panel — Studio layout (source of truth)

**ScreenGui:** `StarterGui.SellOilPanelGui` (`IgnoreGuiInset = true` so the dimmer covers the full viewport on notched devices)  
**Viewport root:** `SellOilPanelGui.Canvas` (full scale, centered — same pattern as `StarterGui.HUD` and `.cursor/rules/startergui-viewport-shell.mdc`)

**Authoring:** Built in Studio via MCP; **Save** the place after edits. This tree is **not** in `default.project.json` until a full `src/StarterGui/` mirror exists (same rule as `HUD`).

## Behavior (intent)

- **Open/close:** Toggle `ScreenGui.Enabled` (or `Visible` on `Canvas` + dimmer) from client when **Sell Oil** is clicked / dimmer or **Close** is pressed.
- **Runtime code** may update **text**, **Visible**, stepper counts, and **click** handlers only — no layout patches on the shell (`Position` / `Size` / `AnchorPoint` on `PanelHost` / `Panel` / `Body`).

## Panel layering (`backing` vs list)

**`Panel`** uses **`UIListLayout`** on its **scroll column**. A full-bleed **`backing`** cannot be a **direct** list sibling without **consuming a layout row**. Pattern (aligned with **`StarterGui.Inventory.Canvas.Container`** having **`backing`** beside **`Main`**):

- **`Panel`** direct children: **`UICorner`**, **`UIStroke`**, **`UIGradient`** (tints **`Panel`** fill), **`backing`** (decorative layer), **`Body`** (hosts the column).
- **`backing`**: **`ZIndex = 0`**, **`AnchorPoint (0,0)`**, **`Position`**, **`Size`** **`UDim2.fromScale(1, 1)`** — draws **over** the **`Panel`** background, **under** everything in **`Body`** (banner through **`Footer` / `SellConfirmButton`**). **Do not** put **`backing`** inside **`Body`** if it should sit behind the list.
- **`Body`**: transparent **`Frame`**, **`ZIndex = 1`**, **`Size`** / **`Position`** full scale; children: **`UIPadding`**, **`UIListLayout`**, **`Banner`**, **`HeaderDivider`**, **`WarehouseHeader`**, **`Content`**, **`Footer`**.

**Wiring paths** use **`Panel.Body.Content…`** and **`Panel.Body.Footer…`** (not **`Panel.Content`**).

## Hierarchy (stable names for wiring)

```
SellOilPanelGui [ScreenGui] DisplayOrder 40, Enabled false by default
└─ Canvas [Frame] — viewport root (scale 1,1, centered)
   ├─ Dimmer [TextButton] — full-screen dim; Text ""; wire MouseButton1Click to close if desired
   └─ PanelHost [Frame] — centered card host (`Size` on **Canvas** uses **scale**; live values ~**0.63 × 0.65** depend on mockup)
      └─ **UIAspectRatioConstraint** (child of **`PanelHost`**, same role as **`Inventory.Canvas.Container`**) — **`FitWithinMaxSize`**, **`Width`** dominant, **`AspectRatio` ~1.69** (width ÷ height, matches host so the card does not collapse to an extreme aspect when the viewport shrinks)
      └─ Panel [Frame] — navy card, gold stroke, UICorner
         ├─ UICorner, UIStroke, UIGradient (tint **`Panel`**)
         ├─ backing [Frame / ImageLabel / …] — art bed; **`ZIndex` 0**, full **`Size`** **`UDim2.fromScale(1,1)`**
         └─ Body [Frame] — **`BackgroundTransparency = 1`**, **`ZIndex` 1**; holds the vertical column only
            ├─ UIPadding (scale)
            ├─ UIListLayout (Vertical) — **`Padding` uses `UDim` scale** (e.g. **~0.0135, 0**), **not** a large **pixel** gap. **Fixed pixel** list padding (e.g. **`0, 8`**) stacked across **`Body` + `Content` + `OilRows`** lists and **did not shrink** with the card, so **`Σ(scale×H) + fixedGaps` could exceed `H`** on short viewports and pushed **`Footer` / SELL** past the panel bottom.
            ├─ Banner [Frame]
            │  ├─ BannerTitle [TextLabel] "Sell Oil"
            │  └─ CloseButton [TextButton] "X"
            ├─ HeaderDivider [Frame] — gold rule
            ├─ WarehouseHeader [Frame]
            │  ├─ WarehouseIcon [ImageLabel] — placeholder (empty Image); set Image in Studio when ready
            │  └─ WarehouseTitle [TextLabel] "Warehouse"
            ├─ Content [Frame] — **vertical** stack (rows full width; totals not beside rows)
            │  ├─ UIListLayout (Vertical) — **scale** `Padding` (same order of magnitude as **`Body`** list), not **pixel-only**
            │  ├─ OilRows [Frame] — **full width** (`Size` `UDim2.new(1, 0, 0.64, 0)`); each `OilSellRow*` **full width** (`UDim2.new(1, 0, 0.3, 0)`)
            │  │  └─ UIListLayout (Vertical) — **scale** `Padding` (matches **`Inventory`** nested lists using **scale** gaps, not tall **offset** stacks)
            │  │     ├─ `OilSellRowCrude` | `OilSellRowLightSweet` | `OilSellRowPremiumRefined` — same row chrome as before (`OilSellRow*` horizontal layout). Legacy names `OilSellRowHeavy` / `Light` / `Standard` still bind. **`SellOilPanel.luau`**: warehouse **stored** counts; Crude = Heavy+Standard barrels; prices from **`MarketPriceUpdate`**.
            │  └─ SummaryStrip [Frame] — bottom band (`Size` `UDim2.new(1, 0, 0.34, 0)`)
            │     └─ TotalsPanel [Frame] — **compact bottom-right card** on `SummaryStrip` (same *idea* as **`StarterGui.Inventory` → `Canvas.Container.Main.SidePanel`**)  
            │        ├─ **Inventory reference:** `SidePanel` has **no root `UIListLayout`** — it is a **scale-sized** `Frame` (`Size` in **scale** vs parent `Main`) with **children as fixed vertical “slots”** (each child also **scale**-sized). **`UIListLayout` only appears inside sub-panels** (e.g. `Stats`), not as the root driver for the whole card.  
            │        ├─ **Sell Oil totals:** root **`UIListLayout` was removed** from `TotalsPanel` so row heights **don’t fight list padding / flex** on tiny viewports. Rows are **manually placed** with **`AnchorPoint (0,0)`**, **`Position.Y`** and **`Size.Y`** in **scale** so the stack **always fits** the card height (same methodology as composed `SidePanel` slots).  
            │        ├─ **`AnchorPoint` (1,1)**, **`Position`** inset from `SummaryStrip` corner; **`Size`** e.g. **`UDim2.new(0.42, 0, 0.9, 0)`** — **scale only** (no `UIAspectRatioConstraint` on `SidePanel` in Inventory).  
            │        ├─ **`UIPadding`** — scale insets so padding tracks card shrink.  
            │        ├─ **Stack (example slices):** three subtotal rows **`~0.168`** height each; **divider** 1px under them; **`TotalSaleRow`** fills **remaining** height (`Size.Y` scale ≈ **1 − 3×row − rule**).  
            │        ├─ **`Subtotal*`** rows: **`LeftText` / `RightText`** — **`TextScaled`**, **`TextSize = 8`**, **`UITextSizeConstraint` 11–30**  
            │        ├─ **`SubtotalDivider`** — `UDim2.new(1, 0, 0, 1)`  
            │        └─ **`TotalSaleRow`** — **`UITextSizeConstraint` 12–40**  
            │        **`ClipsDescendants = false`**  
            │        *Runtime:* set **`RightText`** on subtotal rows (**`SubtotalCrude`** / **`SubtotalLightSweet`** / **`SubtotalPremiumRefined`**, with fallbacks **`SubtotalHeavy`** / **`SubtotalLight`** / **`SubtotalStandard`**); **`TotalSaleRow.RightText`** total. Remote **`RequestSellWarehouseBarrels`**.  
            └─ Footer [Frame]
               ├─ SellBtnDropShadow [Frame] — sibling **behind** the CTA (**`ZIndex`** one lower); rounded, **~3px** lower, slightly larger, soft black for lift-off the footer  
               └─ SellConfirmButton [ImageButton] — **`SellOil_ShellGrad`** (vertical warm gold), strong **`UIStroke`**, **`HudStyleInnerRing`**, **`HudStyleGloss`**, **`SellBtnTopSheen`**, **`UIAspectRatioConstraint`**; child **`Text`**. **`MouseButton1Click`** on **`ImageButton`**.
```

## Each oil row (`OilSellRow*`)

Horizontal **`UIListLayout`** (`SortOrder = LayoutOrder`, **`ItemLineAlignment = Stretch`**, **`Padding`** scale e.g. **`UDim.new(0.008, 0)`**). **`RowSpacer`** — transparent **`Frame`** with child **`UIFlexItem`** (**`FlexMode = Fill`**) and **`LayoutOrder = 2`** — absorbs space so **`Stepper`** stays **flush right** and **`PriceLabel`** sits **immediately left** of **`Stepper`** (order: **`OilIcon` → `InfoColumn` → `RowSpacer` → `PriceLabel` → `Stepper`**).

| Child | Role |
|-------|------|
| `OilIcon` | `ImageLabel` placeholder for barrel art |
| `InfoColumn` | `TypeName` (TextLabel), `StoredLabel` (TextLabel) |
| `RowSpacer` | Invisible flex slot; **do not** remove for layout |
| `PriceLabel` | Current $/bbl (placeholder copy until wired) |
| `Stepper` | `MinusButton`, `AmountLabel`, `PlusButton` |

**Tier mapping (code):** Crude row ↔ warehouse **`HeavyCrude` + `StandardCrude`** (one stepper, split on sell server-side). **`LightSweet`** / **`PremiumRefined`** on their rows. Server: **`OilMarketService:HandleSellWarehouseBarrels`** + **`WarehouseService:TryRemoveBarrelsByCounts`**.

## Theme (approximate RGB)

- Panel fill: `10, 22, 34`
- Row fill: `26, 43, 60`
- Gold accent / strokes: `212, 178, 122`
- Teal row/stepper stroke: `55, 95, 110`

## Aesthetic polish (Studio, HUD-aligned)

**Reference:** `StarterGui.HUD` — gold **`UIStroke`**, **`UIGradient`** depth, **`HudBtnInnerRing` / `HudBtnGloss`** on CTAs.

| Area | What was added (names stable for tweaks) |
|------|-------------------------------------------|
| **`Panel`** | **`SellOil_PanelDepthGrad`** — vertical depth on the card; only **one** **`UIGradient`** on **`Panel`** (duplicate plain **`UIGradient`** removed). **`UIAspectRatioConstraint`** on **`Panel`** removed so **`PanelHost`** owns aspect. |
| **`Dimmer`** | **`SellOil_DimmerGrad`** — slight color + transparency variation (still closes the modal). |
| **`Banner` → `BannerBacking`** | Tinted **`Frame`** + corner + **`SellOil_BannerGrad`** behind title/close (**`ZIndex`** on title/close raised). |
| **`WarehouseHeader`** | Light fill + **`SellOil_WarehouseGrad`** + soft teal **`UIStroke`**. |
| **`HeaderDivider`** | Gold **`UIStroke`**. |
| **`Content`** | Very soft navy wash (**`BackgroundTransparency` ~0.94**) + **`SellOil_ContentWash`**. |
| **`OilSellRow*`** | **`SellOil_RowDepthGrad`**; stronger teal **`UIStroke`**; **`OilIcon` → `IconRing`** (gold ring). |
| **`Stepper`** | **`SellOil_StepperGrad`** + brighter stroke. |
| **`SummaryStrip` → `StripDepth`** | Low-contrast gradient bed (**`ZIndex`** below **`TotalsPanel`**). |
| **`TotalsPanel`** | **`TotalsUnderglow`** + **`SellOil_TotalsGrad`**; **`UIStroke`** slightly opened; row **`ZIndex`** so glow stays behind. |
| **`Footer` / `SellConfirmButton`** | **`SellBtnDropShadow`** sibling; **`SellOil_ShellGrad`** on the **`ImageButton`**; thicker gold-brown **`UIStroke`**; brighter **`HudStyleInnerRing`** stroke; stronger **`HudStyleGloss`** + **`SellBtnTopSheen`**; **`Text`** on top. |

**Runtime:** still only **text**, **Visible**, clicks — no layout property scripts on these shells.

## Rebuild script

To recreate from scratch in MCP or Command Bar, keep the latest builder in repo (add when checked in) or re-run the MCP session that created `SellOilPanelGui`.
