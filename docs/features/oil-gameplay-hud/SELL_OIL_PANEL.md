# Sell Oil panel — Studio layout (source of truth)

**ScreenGui:** `StarterGui.SellOilPanelGui` (`IgnoreGuiInset = true` so the dimmer covers the full viewport on notched devices)  
**Viewport root:** `SellOilPanelGui.Canvas` (full scale, centered — same pattern as `StarterGui.HUD` and `.cursor/rules/startergui-viewport-shell.mdc`)

**Authoring:** Built in Studio via MCP; **Save** the place after edits. This tree is **not** in `default.project.json` until a full `src/StarterGui/` mirror exists (same rule as `HUD`).

## Behavior (intent)

- **Open/close:** Toggle `ScreenGui.Enabled` (or `Visible` on `Canvas` + dimmer) from client when **Sell Oil** is clicked / dimmer or **Close** is pressed.
- **Runtime code** may update **text**, **Visible**, stepper counts, and **click** handlers only — no layout patches on the shell (`Position` / `Size` / `AnchorPoint` on `PanelHost` / `Panel`).

## Hierarchy (stable names for wiring)

```
SellOilPanelGui [ScreenGui] DisplayOrder 40, Enabled false by default
└─ Canvas [Frame] — viewport root (scale 1,1, centered)
   ├─ Dimmer [TextButton] — full-screen dim; Text ""; wire MouseButton1Click to close if desired
   └─ PanelHost [Frame] — centered card host (`Size` on **Canvas** uses **scale**; live values ~**0.63 × 0.65** depend on mockup)
      └─ **UIAspectRatioConstraint** (child of **`PanelHost`**, same role as **`Inventory.Canvas.Container`**) — **`FitWithinMaxSize`**, **`Width`** dominant, **`AspectRatio` ~1.69** (width ÷ height, matches host so the card does not collapse to an extreme aspect when the viewport shrinks)
      └─ Panel [Frame] — navy card, gold stroke, UICorner
         ├─ UIPadding (scale)
         ├─ UIListLayout (Vertical) — **`Padding` uses `UDim` scale** (e.g. **~0.0135, 0**), **not** a large **pixel** gap. **Fixed pixel** list padding (e.g. **`0, 8`**) stacked across **`Panel` + `Content` + `OilRows`** lists and **did not shrink** with the card, so **`Σ(scale×H) + fixedGaps` could exceed `H`** on short viewports and pushed **`Footer` / SELL** past the panel bottom.
         ├─ Banner [Frame]
         │  ├─ BannerTitle [TextLabel] "Sell Oil"
         │  └─ CloseButton [TextButton] "X"
         ├─ HeaderDivider [Frame] — gold rule
         ├─ WarehouseHeader [Frame]
         │  ├─ WarehouseIcon [ImageLabel] — placeholder (empty Image); set Image in Studio when ready
         │  └─ WarehouseTitle [TextLabel] "Warehouse"
         ├─ Content [Frame] — **vertical** stack (rows full width; totals not beside rows)
         │  ├─ UIListLayout (Vertical) — **scale** `Padding` (same order of magnitude as **`Panel`** list), not **pixel-only**
         │  ├─ OilRows [Frame] — **full width** (`Size` `UDim2.new(1, 0, 0.64, 0)`); each `OilSellRow*` **full width** (`UDim2.new(1, 0, 0.3, 0)`)
         │  │  └─ UIListLayout (Vertical) — **scale** `Padding` (matches **`Inventory`** nested lists using **scale** gaps, not tall **offset** stacks)
         │  │     ├─ OilSellRowLight — horizontal **`UIListLayout`** + **`RowSpacer`** (`**UIFlexItem.Fill**`) so **`Stepper`** is **right-aligned** and **`PriceLabel`** hugs its **left** edge
         │  │     ├─ OilSellRowStandard — same as Light
         │  │     └─ OilSellRowHeavy — same as Light
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
         │        *Runtime:* set amounts on **`SubtotalLight.RightText`**, etc.; no layout property overrides.  
         └─ Footer [Frame]
            └─ SellConfirmButton **`ImageButton`** — same idea as **`StarterGui.Inventory` → `…SidePanel.Equip`**: gold fill on the shell (`ImageTransparency = 1`), **`UIAspectRatioConstraint`** (`FitWithinMaxSize`, **`Width`** dominant, **`AspectRatio` ~4.35**), **`AnchorPoint (0.5, 0.5)`** + **`Position (0.5, 0.5)`** in **`Footer`**, **`Size`** ~**`UDim2.new(0.88, 0, 0.58, 0)`** vs footer (moderate **Y** scale so the pill stays inside the footer; avoids a **`TextButton`** using most of the footer height and drawing past the card). Child **`Text`** (`TextLabel`): **`TextScaled`**, **`UITextSizeConstraint`** (e.g. 14–30). Wire **`MouseButton1Click`** on the **`ImageButton`**; change copy on **`Text.Text`** only.
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

**Tier mapping (code):** `Light` ↔ `LightSweet`, `Standard` ↔ `StandardCrude`, `Heavy` ↔ `HeavyCrude` (see `OilConfig` barrel tiers).

## Theme (approximate RGB)

- Panel fill: `10, 22, 34`
- Row fill: `26, 43, 60`
- Gold accent / strokes: `212, 178, 122`
- Teal row/stepper stroke: `55, 95, 110`

## Rebuild script

To recreate from scratch in MCP or Command Bar, keep the latest builder in repo (add when checked in) or re-run the MCP session that created `SellOilPanelGui`.
