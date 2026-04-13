# Select Ship panel — Studio layout (source of truth)

**ScreenGui:** `StarterGui.SelectShipPanelGui` — same responsive shell pattern as **`SellOilPanelGui`** / **`ShipManagementPanelGui`**: **`Canvas`** (full viewport, centered), **`Dimmer`**, **`PanelHost`** + **`UIAspectRatioConstraint`** (**`AspectRatio` ~0.72**, height-dominant, **`FitWithinMaxSize`**), **`Panel`** (**gold `UIStroke`**, **`UICorner`**, **`SelectShip_PanelDepthGrad`**), **`Body`** vertical **`UIListLayout`** with **scale** **`Padding`** + **`UIPadding`** in **scale**.

**DisplayOrder:** **46** (above Ship Management when both exist). **`Enabled = false`** by default; toggle from client when **Change Ship** is pressed.

## Hierarchy (wiring names)

```
SelectShipPanelGui [ScreenGui] IgnoreGuiInset true
└─ Canvas
   ├─ Dimmer [TextButton] — full-screen; wire close if desired
   └─ PanelHost
      ├─ UIAspectRatioConstraint
      └─ Panel
         ├─ UICorner, PanelGoldStroke (UIStroke), SelectShip_PanelDepthGrad
         ├─ Body
         │  ├─ UIListLayout (vertical, scale Padding)
         │  ├─ UIPadding
         │  ├─ SelectShipHeader
         │  │  ├─ HeaderCloseButton [TextButton] "X" — top-right (absolute on header)
         │  │  └─ HeaderContent
         │  │     ├─ UIListLayout (vertical)
         │  │     ├─ TitleTopRule (gold hairline)
         │  │     ├─ TitleRow → SelectShipTitle ("SELECT SHIP")
         │  │     ├─ TitleBottomRule
         │  │     └─ SelectShipSubtitle ("Choose a ship to manage")
         │  ├─ ShipGridScroll [ScrollingFrame] — UIFlexItem Fill; **AutomaticCanvasSize Y**
         │  │  └─ ShipGridLayout [UIGridLayout] — **FillDirectionMaxCells = 3**, CellPadding; **CellSize** uses offset for stable card size (tune in Studio)
         │  ├─ OwnedCounterStrip → ShipsOwnedCounterLabel ("3 / 6 ships owned" placeholder)
         │  └─ CloseFooter → ClosePanelButton [ImageButton] + child **Text** "CLOSE"
         └─ Templates (Folder)
            └─ **ShipSelectCardTemplate** [Frame] — **`Visible = true`** in Studio so you can see it while authoring (sits above **`Body`** via **`ZIndex`**); **clone** into **`ShipGridScroll`** per ship at runtime (clones inherit visibility — set **`Visible`** on each clone if needed).
                  ├─ CardStroke (UIStroke, teal)
                  ├─ CardViewportHolder → ShipCardViewport [ViewportFrame] + Camera
                  ├─ ShipCardName
                  ├─ **ShipCardRarity** — e.g. **`Rarity: —`** (runtime sets tier / color if desired)
                  └─ ShipCardBottomBar
                     ├─ UIListLayout (horizontal)
                     ├─ OwnedPill → OwnedText ("OWNED")
                     ├─ BottomBarSpacer + UIFlexItem Fill
                     ├─ SelectShipCardButton [TextButton] "SELECT" (gold text)
                     └─ LockedPill (hidden by default) → LockedText — show for unowned; hide **OwnedPill** / **SelectShipCardButton** when locked
```

## Runtime (intent)

- **Populate grid:** `ShipSelectCardTemplate:Clone()` → parent to **`ShipGridScroll`**; set name / **`ShipCardRarity.Text`** / viewport model; toggle **Owned** vs **Locked** vs **SELECT** visibility; **gold `CardStroke`** on selected card (author default teal).
- **Counter:** **`ShipsOwnedCounterLabel.Text`** from server or client inventory.
- **Close:** **`HeaderCloseButton`** and **`ClosePanelButton`** → disable **`SelectShipPanelGui`** (and optionally refocus Ship Management).
- **No** runtime edits to **`PanelHost` / Panel / Body** layout shells.

## Reference

- **`SHIP_MANAGEMENT_PANEL.md`** — **Change Ship** opens this panel.
- **`SELL_OIL_PANEL.md`** — scale list padding pattern.
