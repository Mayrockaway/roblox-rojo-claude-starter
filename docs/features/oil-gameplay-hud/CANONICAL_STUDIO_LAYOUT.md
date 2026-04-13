# Oil gameplay HUD — canonical Studio layout

**ScreenGui name in Studio:** `StarterGui.HUD`  
**Viewport root:** `HUD.Canvas` (full scale, centered — see `.cursor/rules/startergui-viewport-shell.mdc`)

This document is the **repo source of truth** for structure and **author-intent** geometry when Studio’s layout solver has rewritten some child `Position`/`Size` values (common under `UIListLayout`).

## After any MCP / Studio edit

1. **Save** the place in Studio.
2. If you moved anchors or shell sizes, **update this file** to match intent (or re-run the dump in `scripts/mcp_dump_startergui_hud.luau` and fold intentional changes in).
3. Optionally run **`scripts/mcp_normalize_startergui_hud.luau`** via MCP `execute_luau` to re-apply the **fixed** `LeftStack` / `TeleportStack` anchors (below).

**Do not** add a partial `src/StarterGui/HUD` path to `default.project.json` until the **entire** HUD hierarchy is mirrored on disk — a partial Rojo subtree can **delete** undocumented children on sync.

**Sell Oil modal:** `StarterGui.SellOilPanelGui` — see `SELL_OIL_PANEL.md` for hierarchy and wiring names.

**Ship Oil modal:** `StarterGui.ShipOilPanelGui` — see `SHIP_OIL_PANEL.md` (cargo + **Run Upgrades** placeholder cards + **Insurance** row + dispatch footer; tanker on Ship Management).

**Ship Management modal:** `StarterGui.ShipManagementPanelGui` — see `SHIP_MANAGEMENT_PANEL.md` (60/40 hero viewport + stats / upgrades placards + cosmetics row).

**Select Ship modal:** `StarterGui.SelectShipPanelGui` — see `SELECT_SHIP_PANEL.md` (grid of **`ShipSelectCardTemplate`** clones, owned counter, close; opened from **Change Ship**).

**Strait passage info:** `StarterGui.StraitInfoPanelGui` — see `docs/features/strait-waypoint-events/STRAIT_STATUS_INFO_PANEL.md` (read-only explainer; anchor top-right near HUD Strait control).

## Hierarchy (names must stay stable for future wiring)

```
HUD [ScreenGui]
└─ Canvas [Frame]
   ├─ UIPadding
   ├─ ShipmentProgressPanel *(may be a direct child of `Canvas` instead of under `TopRow` — `ShipmentProgressHud` finds it by **name** anywhere under `Canvas` or `HUD`.)*
   │  ├─ ProgressTrack → ProgressFill (Studio: rounded trough + fill bevel — `UICorner`, `UIStroke` on track + fill, `UIGradient` on fill for depth; `ClipsDescendants` on track if **Hint** is **not** inside the track. Runtime animates **fill X scale** and may tint fill / gradient; may add **`UIScale` `HintFxScale`** under **Hint** for pulse / celebration only.)
   │  └─ **Hint** — **`TextLabel`** or **`TextButton`** (or a **Frame** named `Hint` containing one) as a **sibling** of `ProgressTrack` **or nested under `ProgressTrack`**. **Author this in Studio**; `ShipmentProgressHud` only updates **Text** / **TextColor3** / **RichText**. See **§ ShipmentProgressPanel (Studio)** below.
   ├─ TopRow [Frame]
   │  ├─ UIListLayout (Horizontal)
   │  ├─ OilPricePanel  (click: **`OilPriceButton`** opens read-only **`OilPriceInfoPanelGui`** — see `OIL_PRICE_INFO_PANEL_MOCKUP.md`)
   │  │  └─ Row
   │  │     ├─ UIListLayout (Horizontal)
   │  │     ├─ PriceIndicator  (Frame, aspect 1, corner)
   │  │     └─ OilPriceButton (`TextButton`) → PriceText (TextLabel, TextScaled)
   │  └─ StraitStatusPanel
   │     └─ StraitStatusButton (`TextButton`) → StraitText (plus strait indicator widget if present in Studio); opens **`StraitInfoPanelGui`**
   ├─ LeftStack [Frame]
   │  ├─ UIListLayout (Vertical)
   │  ├─ CashStrip → CashIcon, CashText
   │  ├─ ShopButton
   │  ├─ ShipOilButton
   │  └─ SellOilButton
   └─ TeleportStack [Frame]
      ├─ UIListLayout (Vertical)
      ├─ TeleportHomeButton
      ├─ TeleportShipButton
      └─ TeleportWarehouseButton
```

## ShipmentProgressPanel (Studio)

Author this block **in Studio** (not via `ShipmentProgressHud` creating instances). Names are what the client binds to.

**Where it runs:** Anything under **`StarterGui`** clones into **`PlayerGui`** when the player loads — that is normal and preferred. You do **not** need a purely runtime-built ScreenGui for this feature; `ShipmentProgressHud` resolves **`HUD`** / **`ShipmentProgressPanel`** under **`PlayerGui`** (including nested ScreenGuis if your place uses them).

1. Under **`HUD` → `Canvas`**, keep **`ShipmentProgressPanel`** (a `Frame`). It may sit beside **`TopRow`** or elsewhere under `Canvas`; the script finds it by name anywhere under **`PlayerGui`** / **`HUD`** / **`Canvas`**.
2. **Children of `ShipmentProgressPanel`** (recommended order if you use **`UIListLayout` (Vertical)** on the panel):
   - **`ProgressTrack`** (`Frame`): holds **`ProgressFill`** (`Frame` or `ImageLabel`). `ProgressFill` uses **scale-based width** on the X axis; the script sets `Size.X.Scale` for progress.
   - **`Hint`**: either
     - a **`TextLabel`** named **`Hint`**, or  
     - a **`Frame`** (or `Folder`) named **`Hint`** whose first deep **`TextLabel`** is the line to drive.
3. **`Hint`** may be a **sibling** of **`ProgressTrack`** or a **`TextLabel` nested under `ProgressTrack`** (subtitle-under-bar layouts); the client binds the named **`Hint`** first, then the first suitable **`TextLabel`**. If you have **several** panels named `ShipmentProgressPanel`, remove duplicates so only the live HUD instance remains.
4. **Hint (`TextLabel`) properties** (starting point — tune in Studio):
   - **Text:** leave empty or `…`; `ShipmentProgressHud` sets copy on shipment events.
   - **RichText:** `true` (success / partial-loss messages use markup).
   - **TextScaled:** `true`; add **`UITextSizeConstraint`** (e.g. min **10**, max **22**).
   - **TextWrapped:** `true`; **TextXAlignment:** Center; **BackgroundTransparency:** 1.
   - **Active:** `false` (script also forces this) so the strip does not eat clicks.
   - Optional: **`UIStroke`** on the label for legibility over water.
5. Remove any old placeholder **`TextLabel`** that is **not** the canonical **`Hint`** (e.g. duplicate route text), so only one status line updates.

## Author-intent geometry (re-apply if Studio drifts)

| Instance | Role | Canonical settings |
|----------|------|----------------------|
| `HUD` | ScreenGui | `ResetOnSpawn = false`, `ZIndexBehavior = Sibling`, `IgnoreGuiInset = false`, `DisplayOrder = 15` (or as agreed) |
| `Canvas` | Viewport root | `Size` scale `(1,1)`, `Position` scale `(0.5,0.5)`, `AnchorPoint (0.5,0.5)`, `BackgroundTransparency = 1` |
| `Canvas.UIPadding` | Safe areas | Top `0.012`, Bottom `0.14` (toolbar reserve), Left/Right `0.018` scale |
| `TopRow` | Top strip | `Size` `(1,0), (0.092,0)`, under `Canvas` after padding |
| `LeftStack` | Cash + shop + sell/ship | **`AnchorPoint (0.5, 0.5)`**, **`Position` scale `(0.25, 0.5)`** — vertically centered, centered in **left half**; **`Size` scale `(0.22, 0.46)`** |
| `TeleportStack` | Teleports | **`AnchorPoint (1, 1)`**, **`Position` scale `(1, 1)`** (offset `0,0`) — bottom-right of **Canvas**; **`Size` scale `(0.13, 0.17)`**; list **`Padding`** `UDim.new(0.012, 3)` (scale + px gap between teleports); each **`TextButton`** height **`0.3`** relative to stack; `UITextSizeConstraint` max **13** on teleports |

## Placeholder copy (scripts will replace later)

- `ShipmentProgressPanel.Hint` (`TextLabel`): leave blank or `…` — **`ShipmentProgressHud`** drives text when shipments run (see **ShipmentProgressPanel (Studio)** above).
- `OilPriceButton.PriceText`: `Oil: $--/bbl`
- `StraitText`: `Strait: Closed` (or split pill/indicator per final art)
- `CashText`: `Cash: $0`
- Buttons: `Shop`, `Ship Oil`, `Sell Oil`, teleport strings as named.

## MCP read snapshot (reference only)

Captured layout dump may show odd `Position` on grandchildren of `UIListLayout` — treat **hierarchy + table above** as canonical, not every floating-point `Position` from a one-off dump.
