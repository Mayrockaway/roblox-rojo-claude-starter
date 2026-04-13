# Ship Management panel — Studio layout (source of truth)

**ScreenGui:** `StarterGui.ShipManagementPanelGui` — same responsive shell pattern as **`SellOilPanelGui`** / **`ShipOilPanelGui`**: **`Canvas`** full viewport, **`PanelHost`** + **`UIAspectRatioConstraint`** (**`FitWithinMaxSize`**, width-dominant, **`AspectRatio` ~1.78** for wide card), **`Panel`** (**`UICorner`**, **`UIStroke`**, **`ShipMgmt_PanelDepthGrad`**), **`Body`** vertical **`UIListLayout`** with **scale** **`Padding`** (**`~UDim.new(0.0135, 0)`**), **`UIPadding`** on **`Body`** in **scale**.

**Banner title:** **`SHIP MANAGEMENT`** (`Banner.BannerTitle`).

## Body hierarchy (wiring names)

```
ShipManagementPanelGui [ScreenGui]
└─ Canvas
   ├─ Dimmer
   └─ PanelHost
      └─ Panel
         └─ Body
            ├─ UIListLayout (vertical, scale Padding)
            ├─ UIPadding
            ├─ Banner → BannerTitle, CloseButton, BannerBacking…
            ├─ HeaderDivider
            └─ MainSplit  (UIFlexItem Fill — uses remaining height)
               └─ MainSplitLayout  (horizontal, scale Padding, ItemLineAlignment.Stretch)
                  ├─ LeftColumn  (UIFlexItem Fill, GrowRatio **6** ~60%)
                  │  └─ LeftHeroBacking  (navy card, UICorner, teal UIStroke)
                  │     ├─ UIListLayout (vertical, scale Padding)
                  │     ├─ UIPadding
                  │     ├─ ShipNameHeader  ("Ship Name")
                  │     ├─ ShipViewportHolder  → **ShipViewport** [ViewportFrame] + Camera (populate model later)
                  │     ├─ YourShipBanner  → vertical stack: **YourShipTopRule** (teal hairline) + **YourShipText** ("YOUR SHIP") + **YourShipBottomRule**
                  │     ├─ StatsRow  (horizontal, centered)
                  │     └─ **ChangeShipRow**  → **`ChangeShipButton`** [ImageButton] + child **`Text`** = **"Change Ship"** (gold stroke, depth gradient); wire **`MouseButton1Click`** on the **`ImageButton`**
                  │        ├─ SpeedStatPill  → StatIcon, StatTitle "SPEED", **SpeedValueLabel** ("25/10" placeholder)
                  │        └─ CapacityStatPill  → … **CapacityValueLabel** ("3/10" placeholder)
                  └─ RightColumn  (UIFlexItem Fill, GrowRatio **4** ~40%)
                     └─ UIListLayout (vertical)
                        ├─ UpgradesBlock  (~**0.70** Y scale)
                        │  ├─ UIListLayout
                        │  ├─ UpgradesHeader  ("UPGRADES")
                        │  └─ UpgradePlacards  (UIFlexItem Fill)
                        │     └─ UIListLayout (vertical, scale Padding)
                        │        ├─ SpeedUpgradePlacard
                        │        │  ├─ PlacardBuyButton  [ImageButton] + green gradient + Text child "BUY"
                        │        │  ├─ PlacardMainRow  → PlacardIcon, PlacardTextColumn (**TierLabel**, **PlacardTitle**, **PlacardDescription**)
                        │        │  └─ PlacardCostRow  → **CostPill** → CoinIcon, **SpeedUpgradeCostLabel**
                        │        └─ CapacityUpgradePlacard  (same pattern, **CapacityUpgradeCostLabel** = **900** placeholder)
                        └─ CosmeticsBlock  (~**0.28** Y scale)
                           ├─ CosmeticsHeader  ("COSMETICS")
                           └─ CosmeticsRow  (UIFlexItem Fill; horizontal list **ItemLineAlignment.Stretch**)
                              ├─ CosmeticTrailTile  → CosmeticIcon, CosmeticName, **CosmeticTrailTileCostLabel**, CosmeticBuyHost → **CosmeticBuyButton**
                              ├─ CosmeticFlagTile  (locked styling, **LOCKED**)
                              └─ CosmeticLightsTile  (locked)
```

## Runtime (intent)

- **Viewport:** mount preview ship model under **`ShipViewport`** (client); do not resize **`PanelHost`** / **`Body`** shells from scripts.
- **Change ship:** **`ChangeShipButton`** opens **`StarterGui.SelectShipPanelGui`** (see **`SELECT_SHIP_PANEL.md`**); no layout overrides on this panel’s shell.
- **Stats / costs / BUY / LOCKED:** update **`Text`**, **`Visible`**, **`Image`** only; keep layout authored in Studio.
- **Placard / tile clicks:** **`MouseButton1Click`** on **`ImageButton`** instances.

## Reference

- **`SELL_OIL_PANEL.md`**, **`SHIP_OIL_PANEL.md`** — list padding, flex split, CTA styling.
