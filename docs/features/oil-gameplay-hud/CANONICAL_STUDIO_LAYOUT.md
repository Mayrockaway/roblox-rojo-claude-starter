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

## Hierarchy (names must stay stable for future wiring)

```
HUD [ScreenGui]
└─ Canvas [Frame]
   ├─ UIPadding
   ├─ TopRow [Frame]
   │  ├─ UIListLayout (Horizontal)
   │  ├─ OilPricePanel
   │  │  └─ Row
   │  │     ├─ UIListLayout (Horizontal)
   │  │     ├─ PriceIndicator  (Frame, aspect 1, corner)
   │  │     └─ OilPricePill → PriceText (TextLabel, TextScaled)
   │  ├─ ShipmentProgressPanel
   │  │  ├─ ProgressTrack → ProgressFill
   │  │  └─ Hint (TextLabel)
   │  └─ StraitStatusPanel
   │     └─ StraitPill → StraitText (plus strait indicator widget if present in Studio)
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

- `OilPricePill.PriceText`: `Oil: $--/bbl`
- `StraitText`: `Strait: Closed` (or split pill/indicator per final art)
- `CashText`: `Cash: $0`
- Buttons: `Shop`, `Ship Oil`, `Sell Oil`, teleport strings as named.

## MCP read snapshot (reference only)

Captured layout dump may show odd `Position` on grandchildren of `UIListLayout` — treat **hierarchy + table above** as canonical, not every floating-point `Position` from a one-off dump.
