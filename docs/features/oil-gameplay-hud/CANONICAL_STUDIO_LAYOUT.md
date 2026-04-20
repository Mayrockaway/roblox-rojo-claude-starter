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
   │  ├─ SellOilButton
   │  ├─ ManageShipButton
   │  └─ SettingsButton *(clone/sibling of **`ManageShipButton`** row chrome; opens **`Settings`** ScreenGui.)*
   ├─ EquipmentHotbar [Frame] *(**must** be a **direct** child of `Canvas` — not under `LeftStack`; otherwise the strip anchors in the left column. **`EquipmentHotbarController`** clones slots into `SlotStrip`.)*
   │  ├─ SlotStrip [Frame] — optional authored **`UIListLayout`** (Horizontal) for Edit preview; **Play** removes it and **centers slot clones** in Lua. Child slots are **runtime clones** only (`HotbarSlot_*`).
   │  └─ SlotTemplate [Frame] — **`Visible = false`**; **do not** parent under `SlotStrip`. Names below are **required** for wiring.
   │     ├─ **`UIAspectRatioConstraint`** — `AspectType = FitWithinMaxSize`, `AspectRatio = 1`, `DominantAxis = Height` (or Width per device test).
   │     ├─ **EquipStroke** (`UIStroke`) — `Enabled = false` default; controller enables for equipped slot.
   │     ├─ **Icon** (`ImageLabel`) — `BackgroundTransparency = 1`, `ScaleType = Fit`, image from `Tool.TextureId`.
   │     ├─ **HotkeyLabel** (`TextLabel`) — `TextScaled = true`, `BackgroundTransparency = 1`; shows `1`–`9`, `0` for first ten slots.
   │     ├─ **StackBadge** (`TextLabel`) — visible when shop stack **count > 1**; `TextScaled = true`, **`UITextSizeConstraint`** min **8** max **18**.
   │     └─ **Hit** (`ImageButton`) — `AutoButtonColor = false`, `BackgroundTransparency = 1`, **full slot** (`Size` scale `1,1`); equips bound tool on click.
   ├─ StraitControlCta [ImageButton] *(direct child of `Canvas`, top-left edge; opens `StraitControlPanelGui`. Routed via `HudPanelRouter` aliases `StraitControlCta` / `StraitControlCTA`. Hover scale by `StraitControlCtaHover`.)*
   ├─ StraitForceLockTimer [Frame] *(sibling of `StraitControlCta`, sits to its right. **Authored in Studio**, **`Visible = false`** by default. `StraitForceLockTimer` controller (`src/client/UI/StraitForceLockTimer.luau`) shows / hides + drives `TimerLabel.Text` ("M:SS") + theme color + pulse animation while a Robux strait force-open / force-close lock is active (`MonetizationCatalog` consumables `strait_open_2min` / `strait_close_2min` → `StraitStateService:ForceStateForDuration`). Required children: `UIAspectRatioConstraint` (`AspectType = FitWithinMaxSize`, `AspectRatio ≈ 2.4`, `DominantAxis = Width`), `UICorner`, `UIStroke`, `UIPadding`, **`TimerLabel` (`TextLabel`)** with **`UITextSizeConstraint`** (min ≥ 18) so the countdown reads big on phone too. **Do not** override its `Position` / `Size` / `AnchorPoint` from controllers (per `ui-architecture.mdc` §3); the controller only writes `Visible`, `BackgroundColor3`, `Text`, plus a runtime-added `UIScale` (`PulseScale`) for the pulse / opening pop animation.)*
   └─ TeleportStack [Frame]
      ├─ UIListLayout (Vertical)
      ├─ TeleportHomeButton
      ├─ TeleportShipButton
      ├─ TeleportWarehouseButton
      └─ TeleportDocksButton *(clone of another teleport row for identical layout; `HudTeleportRouter` → `RequestTeleportToDocks`.)*
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
| `TeleportStack` | Teleports | **`AnchorPoint (1, 1)`**, **`Position` scale `(1, 1)`** (offset `0,0`) — bottom-right of **Canvas**; **`Size` scale `(0.13, 0.32)`** — taller frame for **four** rows without shrinking row **`0.3`** scale; list **`Padding`** `UDim.new(0.012, 3)`; each **`GuiButton`** row height **`0.3`**; `UITextSizeConstraint` max **13** on teleports |
| `EquipmentHotbar` | Custom toolbar (replaces Core backpack strip) | **`AnchorPoint (0.5, 1)`**, **`Position` scale `(0.5, 1)`**, **`Size` scale `(0.92, 0.10)`** — sits in bottom safe band above `Canvas.UIPadding` bottom inset; **`BackgroundTransparency = 1`** or a **very high** transparency (e.g. `0.92`) so the strip is barely visible in **Edit** mode |
| `EquipmentHotbar.SlotStrip` | Row host | **`Size` scale `(1, 1)`**, **`BackgroundTransparency = 1`**; horizontal **`UIListLayout`** |

### EquipmentHotbar (Studio)

- **Edit vs Play:** Slot clones are created only by **`EquipmentHotbarController`** (a **LocalScript** chain under **Play**). In **Edit** mode you will see the empty strip (or a faint bar if authored with transparency); that is expected until you press **Play**.
- **Centered row (default-toolbar feel):** At runtime the controller **removes** `SlotStrip`’s `UIListLayout` (if present) and **positions each `HotbarSlot_*` clone** so the row is **horizontally centered** in `SlotStrip`: one slot sits in the **middle**; each added slot **grows the row** with the **visual midpoint** between adjacent slots (same idea as the default Roblox hotbar strip).
- **`EquipmentHotbarController`** (`src/client/UI/EquipmentHotbarController.luau`) resolves **`HUD` → `Canvas` → `EquipmentHotbar` → `SlotStrip` + `SlotTemplate`** using **recursive** `FindFirstChild` where needed (nested `Canvas` is OK; direct `Canvas` is still preferred).
- **`SlotTemplate` slot size:** Prefer **offset-based** width/height (or rely on the controller’s post-clone pixel sizing). A template using **only `UDim2` scale width** under a horizontal **`UIListLayout`** often renders as **0px wide** in Roblox.
- Server sets shop tool attribute **`EquipmentStackCount`** (see `Constants.EquipmentStackCountAttribute`); badge reads that sum per `EquipmentItemId` when multiple instances exist transiently.
- After this block exists in Studio, **`StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)`** runs from client bootstrap **only** when the controller binds successfully.

## Placeholder copy (scripts will replace later)

- `ShipmentProgressPanel.Hint` (`TextLabel`): leave blank or `…` — **`ShipmentProgressHud`** drives text when shipments run (see **ShipmentProgressPanel (Studio)** above).
- `OilPriceButton.PriceText`: `Oil: $--/bbl`
- `StraitText`: `Strait: Closed` (or split pill/indicator per final art)
- `CashText`: `Cash: $0`
- Buttons: `Shop`, `Ship Oil`, `Sell Oil`, `Manage Ship`, `Settings`, teleport strings as named.

## MCP read snapshot (reference only)

Captured layout dump may show odd `Position` on grandchildren of `UIListLayout` — treat **hierarchy + table above** as canonical, not every floating-point `Position` from a one-off dump.
