# Ship Oil panel — Studio layout (source of truth)

**ScreenGui:** `StarterGui.ShipOilPanelGui` — same responsive shell as **`SellOilPanelGui`**: **`Canvas`** viewport root, **`PanelHost`** + **`UIAspectRatioConstraint`**, **`Panel`** (**`UICorner` / `UIStroke` / `UIGradient` / optional `backing` / `Body`**), **`Body`** vertical **`UIListLayout`** with **scale** `Padding` (**`~UDim.new(0.0135, 0)`**), **no** stacked **pixel-only** list gaps (see **`SELL_OIL_PANEL.md`** + **`ui-scaling-responsive.mdc`**).

**Banner title:** **`Ship Oil`** (`Banner.BannerTitle`).

**Layout (live Studio):** **`Body`** `LayoutOrder` chain **`1`–`7`**: **`Banner`** → **`HeaderDivider`** → **`CargoSection`** (~**`0.40`** Y scale) → **`RunUpgradesSection`** (~**`0.26`**) → **`InsuranceSection`** (~**`0.085`**) → **`ShipmentCostBand`** (~**`0.042`**) → **`Footer`** (**`~0.115`**). **`TotalBarrelsLabel`** stays **only** in **`Footer`** (manual positions — do not nudge for shipment cost). Tune Y scales in Studio if content feels tight on short viewports.

## Hierarchy (wiring names)

```
ShipOilPanelGui [ScreenGui]
└─ Canvas
   ├─ Dimmer
   └─ PanelHost
      └─ Panel
         └─ Body  (vertical UIListLayout, scale Padding)
            ├─ Banner → BannerTitle "Ship Oil", CloseButton, …
            ├─ HeaderDivider
            ├─ CargoSection
            │  ├─ CargoHeader  ("Cargo")
            │  ├─ CargoRows  (vertical list, scale Padding)
            │  │  └─ **Canonical:** `ShipCargoRowCrude` | `ShipCargoRowRefined` | `ShipCargoRowPremium` — tiers **Crude**, **Refined**, **Premium** (`ShipOilPanel.luau` → `Crude` / `Refined` / `Premium`). Renamed rows can still resolve via the `ShipOilTier` attribute or the row's title text.
            │  │        **`OilIcon`** (`ImageLabel`, square `UIAspectRatioConstraint`; `Image` from **`QualityConfig.Tiers.<Tier>.iconAssetId`**), NameColumn / `<Tier>Title` (e.g. `CrudeTitle` / `RefinedTitle` / `PremiumTitle`), RowSpacer+UIFlexItem.Fill,
            │  │        InventoryCount, Stepper
            │  └─ CargoSubtotalBand  — horizontal row (scale height matches former subtotal row)
            │        ├─ WarehouseCapacityLabel  — gold **`TextLabel`**, placeholder **`— / —`** (stored / capacity); **`TextScaled`** + **`UITextSizeConstraint`** (8–16) + thin **`UIStroke`** — wire later
            │        └─ CargoSubtotalRow  — right-aligned subtotal copy (unchanged; nested under band)
            ├─ RunUpgradesSection
            │  ├─ RunUpgradesHeader  ("Run Upgrades") — `TextScaled` + `UITextSizeConstraint`
            │  └─ RunUpgradeCards  — **horizontal** `UIListLayout`, scale `Padding`, `ItemLineAlignment.Stretch`
            │        ├─ RunUpgradeCard1 … RunUpgradeCard3  — **one row**: each `Size` **`UDim2.new(0,0,1,0)`** + **`RowFlex`** (`UIFlexItem` `Fill`, `GrowRatio` 1) → **equal thirds**
            │        │     Per card: **`CardMainLayout`** (horizontal) — **`IconColumn`** (~0.28 width) → square **`IconWell`** + **`PlaceholderIcon`**; **`RightColumn`** (`UIFlexItem` fill) with **`RightVerticalLayout`** (`HorizontalAlignment = Right`): **`TitleLabel`**, **`DescriptionLabel`**, flex spacer, **`CostBuyRow`** (horizontal, right-aligned): **`CostPill`** (gold gradient, stadium **`UICorner`**, **`CoinIcon`** + **`CostLabelN`**) + **`BuyButton`** (green gradient pill)
            │        │     Chrome: `ShipOil_RowDepthGrad`, teal `UIStroke`, `UICorner`
            │        └─ …
            ├─ InsuranceSection  — **purple-tinted shell** (soft fill + **`UICorner`** + lavender **`UIStroke`**) so the block reads separately from teal cargo / run-upgrade rows
            │  └─ InsuranceRow  — deeper **violet** fill, **lavender `UIStroke`** (not cargo teal); optional **`Insurance_RowDepthGrad`** (purple depth)
            │        `InsuranceTitle` ("Insurance"), `RowSpacer` + `UIFlexItem.Fill`,
            │        `InsuranceCostLabel`, `InsuranceBuyButton` [ImageButton + `Text`] — **`InsuranceBuyGrad`** + lavender **`UIStroke`** (insurance-only CTA)
            ├─ ShipmentCostBand  (thin row; does **not** alter **`Footer`** layout slots)
            │  └─ `ShipmentCostLabel` — e.g. **`Shipment Cost: —`** (gold-tint; runtime sets amount)
            └─ Footer  (manual layout)
               ├─ DispatchDropShadow
               ├─ `TotalBarrelsLabel` — **authoritative placement**; do not resize/reposition for other copy
               └─ DispatchShipmentButton  [ImageButton] + `ShipOil_DispatchShellGrad`
```

**BUY buttons:** small **`ImageButton`**s reuse **`ShipOil_StepperGrad`** (cloned from cargo stepper) for the teal shell; **`MouseButton1Click`** on the **`ImageButton`**.

## Runtime (intent)

- **Cargo:** **`InventoryCount`** = whole barrels at the **home refinery** from **`OilStateUpdate.state.oilByTier`** (not strait **`WarehouseService`** barrels). Dispatch manifest uses **oil units** (`barrels × OilConfig.Barrels.PerBarrelOil`). Implementation: **`ShipOilPanel.luau`**.
- **Run upgrades:**
  - **`RunUpgradeCard1` — Security Personnel (live):** wired by **`ShipOilPanel.luau`** (`wireRunUpgradeCard1`). Reads **`MonetizationCatalog.GetItem("consumable.security_personnel_x1")`** for `displayName` (`TitleLabel`), `subtitle` (`DescriptionLabel` base copy), and `robuxPrice` (`CostPill.CostLabel1` → `R$%d`). `BuyButton.Activated` → **`requestPromptRobuxPurchase`** with `{ itemId = "consumable.security_personnel_x1" }`. Owned-stack count rides on **`OilStateUpdate.runUpgradeOwnedByItemId.security_personnel`** and re-paints the description as **`Ready ×N • <subtitle>`** in the same frame the server pushes (Robux receipt grant or `_handleDispatch` consume). Stacking allowed — buying N protects the next N dispatches.
  - **`RunUpgradeCard2` / `RunUpgradeCard3`:** keep their **`ComingSoonOverlay`** in Studio; intentionally **not** wired. When a future product lands, give the card its own `wireRunUpgradeCard*` analog and remove the overlay in Studio.
- **Insurance:** **`InsuranceCostLabel`**, **`InsuranceBuyButton`** (distinct **purple** CTA — do not reuse run-supply green styling).
- **Shipment cost:** **`Body.ShipmentCostBand.ShipmentCostLabel.Text`** (e.g. fees + upgrades + insurance) — server-authoritative when wired.
- **Dispatch:** **`Footer.DispatchShipmentButton`** — unchanged role; **no** shell layout patches from scripts.

## Reference GUI

- **`SELL_OIL_PANEL.md`** — list padding, **`Body`** pattern, CTA polish.
- **`StarterGui.HUD.Canvas.LeftStack.ShipOilButton`** — dispatch green reference.
