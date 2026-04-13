# Strait passage — info panel (Studio)

**ScreenGui:** `StarterGui.StraitInfoPanelGui` — read-only explainer; opened from **`HUD.Canvas.TopRow.StraitStatusPanel.StraitStatusButton`** (exclusive with other HUD modals). **`DisplayOrder` 38**, **`Enabled = false`** by default. **No `ScrollingFrame`** — all copy fits in scale slices.

## Layout (mockup-aligned)

- **`Panel`**: near-black fill, **`UIStroke`** warm cream, **`UICorner`** (~**`0.035`** scale), optional **`StraitInfo_PanelGrad`** (off for flat black).
- **`CloseButton`**: child of **`Panel`**, top-right — match **`SellOilPanelGui` / `ShipOilPanelGui`** banner **`CloseButton`** look: **`TextButton`** **`X`**, **`AutoButtonColor = true`**, dark blue fill (**`BackgroundColor3`** ~**`30,42,58`**, **`BackgroundTransparency`** **0.2**), light text, **`GothamBold`**, **`TextScaled`** + **`UITextSizeConstraint`** (**12–24**), **`Size`** **scale** ~**`UDim2.new(0.095, 0, 0.095, 0)`** (square; **`UIAspectRatioConstraint`**), **`Position`** ~**`UDim2.new(1, -8, 0, 8)`**, **`AnchorPoint (1,0)`**, **`UICorner`** **8px**, gold **`UIStroke`** + thin black **`UIStroke`**.
- **`Body`**: scale **`UIPadding`**, vertical **`BodyList`** (**`UIListLayout`**): **`SortOrder = LayoutOrder`**, scale **`Padding`**, **`VerticalFlex = None`**, **`HorizontalFlex = Fill`**.
- **Order under `Body`:** **`HeaderRow`** (title) → **`OpenSection`** → **`RestrictedSection`** → **`ClosedSection`** → **`FooterDisclaimer`**.
- **Each of `OpenSection` / `RestrictedSection` / `ClosedSection`:** transparent **`Frame`**, **`Size.Y`** is a **scale** of **`Body`**. **`SectionList`** (**`UIListLayout`**, vertical) stacks **`StatusTag`** (pill **`Frame`**) then **`BodyText`** (**`TextLabel`**). Pill uses **`UICorner`** (~**`0.45`** scale). **`TagText`**: **`TextScaled`**, **`TextWrapped`**, plus **`UITextSizeConstraint`** (**`MinTextSize` 12**, **`MaxTextSize` 22**) so pill labels do not shrink unreadably on small phones. **`BodyText`**: **`TextScaled`**, **`TextWrapped`** (constraints optional per design).

## Hierarchy (wiring names)

```
StraitInfoPanelGui [ScreenGui] IgnoreGuiInset true, ResetOnSpawn false
└─ Canvas [Frame]
   ├─ Dimmer [TextButton]
   └─ PanelHost [Frame]
      ├─ PanelAspect [UIAspectRatioConstraint] ~0.58, FitWithinMaxSize, Width dominant
      └─ Panel [Frame]
         ├─ UICorner, UIStroke, StraitInfo_PanelGrad (optional)
         ├─ CloseButton [TextButton]
         └─ Body [Frame]
            ├─ UIPadding (scale)
            ├─ BodyList [UIListLayout]
            ├─ HeaderRow [Frame]  Size Y ~0.10 scale of Body
            │  └─ StraitInfoTitle [TextLabel]  Merriweather, TextScaled
            ├─ OpenSection [Frame]
            │  ├─ SectionList [UIListLayout]
            │  ├─ StatusTag [Frame] + UICorner
            │  │  └─ TagText [TextLabel]  TextScaled + UITextSizeConstraint (e.g. Min 12, Max 22)
            │  └─ BodyText [TextLabel]  TextScaled, TextWrapped, TextYAlignment Top
            ├─ RestrictedSection [Frame]  (same pattern)
            ├─ ClosedSection [Frame]  (same pattern; slightly larger Body slice if needed)
            └─ FooterDisclaimer [TextLabel]  TextScaled, centered
```

**Viewport / card:** **`Canvas`** full screen (scale). **`PanelHost`** top-right (**`AnchorPoint 1,0`**, **`Position`** ~**`UDim2.new(0.98, 0, 0.07, 0)`**, **`Size`** ~**`UDim2.new(0.44, 0, 0.58, 0)`**). **`Panel`** **`UDim2.fromScale(1,1)`** inside host. **`Panel`** must be parented under **`PanelHost`**.

## Copy (Studio strings)

**Title:** The Narrow Pass

| Section | Pill | Body |
| --- | --- | --- |
| **OpenSection** | OPEN | Only a few dark clouds. Big ships and small ones pass without much trouble. |
| **RestrictedSection** | RESTRICTED | Must keep eyes sharp. Some escorts riding close—but cargo can still move. |
| **ClosedSection** | CLOSED | Wrecks, shoals, and angry hulls ahead. Rough chop and sparks on the water. Many crews stay in port till it cools. |

**Footer:** The sea changes fast. Take this as tavern talk, not a king's word.

## Runtime (intent)

- Toggle **`ScreenGui.Enabled`** (or **`Canvas.Visible`**); close on **`CloseButton`** only (dimmer does not close).
- Optional: tint only the active section’s **`StatusTag`** / stroke — **no** runtime **`Position`/`Size`** edits on **`PanelHost`** / **`Panel`** for layout.

## Text scaling note

**`BodyText`** uses **`AutomaticSize = None`** and a **scale `Size`** inside the section so **`TextScaled`** resolves against a stable box (avoid **`TextScaled` + `AutomaticSize.Y`**, which collapses height). Different line counts can still yield **slightly different** fitted glyph sizes per label; that is normal for **`TextScaled`** per box.
