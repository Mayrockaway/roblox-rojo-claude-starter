--!strict
-- Drives **`PlayerGui.HUD.Canvas.ActiveManifestPanel`** from **`ShipmentVisualEvent`**:
-- `ManifestHudSnapshot` (server-authoritative manifest + optional per-incident tier loss), `ShipmentResolved` (idle).
-- Incidents: **`IncidentsSection.SectionBody`** holds **`IncidentsScroll`** (ScrollingFrame) or SectionBody is the scroll;
-- clones **`IncidentRow_1`** archetype into **`IncidentSlot_*`**; first three slots match legacy empty stripes; 4+ append + scroll.
-- **`LossChip`** only for tiers with barrel loss > 0.
-- Allowed runtime: **`Text`**, **`Visible`**, cloning + scroll host ensure (see `ui-architecture` world/manifest exception).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local ActiveManifestHud = require(script.Parent.ActiveManifestHud)
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ManifestIncidentTitle = require(Shared:WaitForChild("Config"):WaitForChild("StraitEvents"):WaitForChild("ManifestIncidentTitle"))

local TIER_ORDER = { "Crude", "Refined", "Premium" }

local ROW_FOR_TIER: { [string]: string } = {
	Crude = "LoadedRow_Crude",
	Refined = "LoadedRow_Refined",
	Premium = "LoadedRow_Premium",
}

local TIER_CHIP_COLOR: { [string]: Color3 } = {
	Crude = Color3.fromRGB(30, 25, 20),
	Refined = Color3.fromRGB(220, 180, 60),
	Premium = Color3.fromRGB(200, 200, 210),
}

local TITLE_ACTIVE = "ACTIVE MANIFEST"
local TITLE_IDLE = "No Active Shipment"

-- Match legacy `layoutIncidentSlotStack`: three equal stripes in the incidents body (relative to scroll viewport height).
local LEGACY_VISIBLE_ROWS = 3
local ROW_STACK_GAP_SCALE = 0.008

local playerGuiRef: PlayerGui? = nil
local panelRef: Frame? = nil
local archetypeRow: Frame? = nil
local chipArchetype: Frame? = nil
local activeShipmentId: string? = nil
local hydratedShipmentId: string? = nil
local lastPerBarrel = 1

local nextIncidentSlotIndex = 0
local scrollResizeConn: RBXScriptConnection? = nil

-- Collapsed/expanded state for the manifest pill.
-- Auto behaviour: idle voyage → collapse to header band; active voyage → expand to full card.
-- Manual override: clicking the header band toggles regardless; the next idle↔active
-- transition re-applies the auto state (so a stuck-collapsed pill never traps the player).
local authoredSize: UDim2? = nil
local authoredPosition: UDim2? = nil
local authoredAnchor: Vector2? = nil
local authoredCornerRadius: UDim? = nil
local authoredHeaderSize: UDim2? = nil
local authoredHeaderPosition: UDim2? = nil
-- Title geometry inside `ManifestHeader`. The Studio author positions the title for
-- the **expanded** layout where the header is a thin top strip (~32px). When we
-- stretch the header to fill the collapsed pill, those same scale-based Position /
-- AnchorPoint values push the title toward the top of the pill instead of centering
-- it. Capture once, override on collapse, restore on expand.
local authoredTitleSize: UDim2? = nil
local authoredTitlePosition: UDim2? = nil
local authoredTitleAnchor: Vector2? = nil
local authoredTitleXAlignment: Enum.TextXAlignment? = nil

-- `UIAspectRatioConstraint` has **no** `Enabled` property; the documented way to
-- toggle a constraint is to reparent it. We hold the Lua reference here so the
-- instance survives `.Parent = nil` (no GC) and can be reattached on expand.
local authoredAspect: UIAspectRatioConstraint? = nil
-- Captured **once** the first time we see the panel rendered while expanded.
-- These are the rendered top-left of the EXPANDED panel expressed as a
-- 0-1 fraction of the parent's *inner* (UIPadding-aware) box. Stored as **Scale**
-- because the parent's inner box scales proportionally with the viewport, so the
-- collapsed pill stays anchored to the same visual slot across any viewport size.
-- The rendered top-left is **not** the same as `authoredPosition - anchor * authoredSize`
-- when a `UIAspectRatioConstraint FitWithinMaxSize` is shrinking one axis: the math
-- uses the **authored** UDim2 size, but the rendered rect is **clamped** by the
-- constraint, leaving a few pixels of drift. Sourcing from `AbsolutePosition` after
-- one layout pass avoids that drift entirely.
local expandedTopLeftFracX: number? = nil
local expandedTopLeftFracY: number? = nil
local isCollapsed = true
local wasActive = false
local headerToggleConn: RBXScriptConnection? = nil

-- Collapsed pill footprint, expressed as viewport-Scale UDim2 dimensions.
-- We want the pill to be **smaller** than the authored full panel on both axes
-- so it reads as a compact badge, while the `ManifestHeader` is stretched to
-- 100% of that footprint so the `TextScaled` title (capped at 28px by its
-- `UITextSizeConstraint`) remains as legible as the full-size header.
local COLLAPSED_X_SCALE = 0.085
local COLLAPSED_Y_SCALE = 0.045
local SECTION_NAMES = { "LoadedSection", "IncidentsSection", "DeliverySection" }

-- Incident titles: **`UITextSizeConstraint` only applies when `TextScaled` is true** — with TextScaled off,
-- Min/Max are ignored and `TextSize` is fixed px (Studio “min 1” won’t shrink anything).
-- With TextScaled on, `TextSize` is the **ceiling** for the scaled font; constraint clamps that range.
local INCIDENT_TITLE_CONSTRAINT_MIN = 6
local INCIDENT_TITLE_CONSTRAINT_MAX = 16

local function applyIncidentTitleReadability(tit: TextLabel)
	tit.AutomaticSize = Enum.AutomaticSize.None
	tit.RichText = false
	tit.TextScaled = true
	tit.TextWrapped = true
	tit.TextTruncate = Enum.TextTruncate.None
	tit.TextYAlignment = Enum.TextYAlignment.Center
	tit.TextSize = INCIDENT_TITLE_CONSTRAINT_MAX
	local c = tit:FindFirstChildOfClass("UITextSizeConstraint")
	if not c then
		c = Instance.new("UITextSizeConstraint")
		c.Parent = tit
	end
	c.MinTextSize = INCIDENT_TITLE_CONSTRAINT_MIN
	c.MaxTextSize = INCIDENT_TITLE_CONSTRAINT_MAX
end

local function findHud(playerGui: PlayerGui): ScreenGui?
	local h = playerGui:FindFirstChild("HUD")
	if h and h:IsA("ScreenGui") then
		return h
	end
	local deep = playerGui:FindFirstChild("HUD", true)
	if deep and deep:IsA("ScreenGui") then
		return deep
	end
	return nil
end

local function resolvePanel(playerGui: PlayerGui): Frame?
	local hud = findHud(playerGui)
	local canvas = hud and hud:FindFirstChild("Canvas")
	local panel = canvas and canvas:FindFirstChild("ActiveManifestPanel")
	if panel and panel:IsA("Frame") then
		return panel
	end
	return nil
end

local function oilUnitsToBarrels(oilUnits: number, perBarrel: number): number
	local p = math.max(1, math.floor(perBarrel))
	return math.max(0, math.floor(math.max(0, oilUnits) / p))
end

local function sumOil(m: { [string]: any }?): number
	if typeof(m) ~= "table" then
		return 0
	end
	local t = 0
	for _, tier in ipairs(TIER_ORDER) do
		t += math.max(0, math.floor(tonumber(m[tier]) or 0))
	end
	return t
end

local function rowHeightScale(): number
	local g = ROW_STACK_GAP_SCALE
	return (1 - g * math.max(0, LEGACY_VISIBLE_ROWS - 1)) / LEGACY_VISIBLE_ROWS
end

local function incidentRowHeightPx(scroll: ScrollingFrame): number
	local h = scroll.AbsoluteSize.Y
	local rh = rowHeightScale() * h
	return math.max(1, math.floor(rh))
end

local function configureIncidentsScroll(scroll: ScrollingFrame)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 4
	scroll.ScrollBarImageTransparency = 0.35
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	scroll.ClipsDescendants = true
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.AnchorPoint = Vector2.new(0, 0)
	scroll.Position = UDim2.new(0, 0, 0, 0)
	scroll.Size = UDim2.new(1, 0, 1, 0)
	local lay = scroll:FindFirstChild("IncidentsListLayout") :: UIListLayout?
	if not lay then
		lay = Instance.new("UIListLayout")
		lay.Name = "IncidentsListLayout"
		lay.FillDirection = Enum.FillDirection.Vertical
		lay.HorizontalAlignment = Enum.HorizontalAlignment.Center
		lay.VerticalAlignment = Enum.VerticalAlignment.Top
		lay.SortOrder = Enum.SortOrder.LayoutOrder
		lay.Parent = scroll
	end
	local gapPx = math.max(1, math.floor(scroll.AbsoluteSize.Y * ROW_STACK_GAP_SCALE))
	lay.Padding = UDim.new(0, gapPx)
end

local function refreshAllIncidentRowHeights(scroll: ScrollingFrame)
	local hPx = incidentRowHeightPx(scroll)
	local lay = scroll:FindFirstChild("IncidentsListLayout") :: UIListLayout?
	if lay then
		local gapPx = math.max(1, math.floor(scroll.AbsoluteSize.Y * ROW_STACK_GAP_SCALE))
		lay.Padding = UDim.new(0, gapPx)
	end
	for _, ch in ipairs(scroll:GetChildren()) do
		if ch:IsA("Frame") then
			local n = ch.Name
			if string.sub(n, 1, 13) == "IncidentSlot_" or string.sub(n, 1, 12) == "IncidentRow_" then
				ch.Size = UDim2.new(1, 0, 0, hPx)
			end
		end
	end
end

local function bindScrollResize(scroll: ScrollingFrame)
	if scrollResizeConn then
		scrollResizeConn:Disconnect()
		scrollResizeConn = nil
	end
	scrollResizeConn = scroll:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		refreshAllIncidentRowHeights(scroll)
	end)
end

--- SectionBody may be a Frame (legacy) or ScrollingFrame; optional child **`IncidentsScroll`** is created if missing.
local function resolveIncidentsScroll(panel: Frame): ScrollingFrame?
	local inc = panel:FindFirstChild("IncidentsSection")
	local body = inc and inc:FindFirstChild("SectionBody")
	if not body then
		return nil
	end
	if body:IsA("ScrollingFrame") then
		configureIncidentsScroll(body)
		bindScrollResize(body)
		return body
	end
	if not body:IsA("Frame") then
		return nil
	end
	local existing = body:FindFirstChild("IncidentsScroll")
	if existing and existing:IsA("ScrollingFrame") then
		configureIncidentsScroll(existing)
		bindScrollResize(existing)
		return existing
	end
	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "IncidentsScroll"
	scroll.ZIndex = body.ZIndex
	scroll.Parent = body
	configureIncidentsScroll(scroll)
	for _, moveName in ipairs({ "IncidentRow_1", "IncidentRow_2", "IncidentRow_3" }) do
		local r = body:FindFirstChild(moveName)
		if r then
			r.Parent = scroll
		end
	end
	bindScrollResize(scroll)
	return scroll
end

local function getIncidentsScroll(panel: Frame): ScrollingFrame?
	return resolveIncidentsScroll(panel)
end

local function ensureArchetypes(panel: Frame)
	if archetypeRow and archetypeRow.Parent then
		return
	end
	if archetypeRow and not archetypeRow.Parent then
		archetypeRow = nil
	end
	if chipArchetype and not chipArchetype.Parent then
		chipArchetype = nil
	end
	local scroll = getIncidentsScroll(panel)
	if not scroll then
		return
	end
	local src: Frame? = nil
	local row1 = scroll:FindFirstChild("IncidentRow_1")
	if row1 and row1:IsA("Frame") then
		src = row1
	else
		local inc = panel:FindFirstChild("IncidentsSection")
		local body = inc and inc:FindFirstChild("SectionBody")
		local altBody = body and body:IsA("Frame") and body:FindFirstChild("IncidentRow_1")
		if altBody and altBody:IsA("Frame") then
			src = altBody
		else
			local sgHud = StarterGui:FindFirstChild("HUD", true)
			local sgCanvas = sgHud and sgHud:FindFirstChild("Canvas")
			local sgPanel = sgCanvas and sgCanvas:FindFirstChild("ActiveManifestPanel")
			local sgInc = sgPanel and sgPanel:FindFirstChild("IncidentsSection")
			local sgBody = sgInc and sgInc:FindFirstChild("SectionBody")
			local underScroll = sgBody and (sgBody:FindFirstChild("IncidentsScroll") or sgBody)
			local alt = underScroll and underScroll:FindFirstChild("IncidentRow_1")
			if alt and alt:IsA("Frame") then
				src = alt
			end
		end
	end
	if not (src and src:IsA("Frame")) then
		return
	end
	archetypeRow = src:Clone()
	archetypeRow.Name = "_IncidentRowArchetype"
	archetypeRow.Visible = false
	archetypeRow.Parent = panel
	if chipArchetype and chipArchetype.Parent then
		chipArchetype:Destroy()
	end
	chipArchetype = nil
	local top0 = archetypeRow:FindFirstChild("IncidentTop", true)
	local host0 = top0 and top0:FindFirstChild("LossChipsHost")
	local chip0 = host0 and host0:FindFirstChild("LossChip")
	if chip0 and chip0:IsA("Frame") then
		chipArchetype = chip0:Clone()
		chipArchetype.Name = "_LossChipArchetype"
		chipArchetype.Visible = false
		chipArchetype.Parent = panel
	end
	local titArc = archetypeRow:FindFirstChild("IncidentTop", true)
	titArc = titArc and titArc:FindFirstChild("IncidentTitle")
	if titArc and titArc:IsA("TextLabel") then
		applyIncidentTitleReadability(titArc)
	end
end

-- Idle / between shipments: remove runtime **`IncidentSlot_*`** only (matches legacy); keep **`IncidentRow_1`** if still authored.
local function clearIncidentRuntimeSlots(panel: Frame)
	local scroll = getIncidentsScroll(panel)
	if not scroll then
		return
	end
	for _, ch in ipairs(scroll:GetChildren()) do
		if ch:IsA("Frame") and string.sub(ch.Name, 1, 13) == "IncidentSlot_" then
			ch:Destroy()
		end
	end
end

-- New shipment hydrate: strip template row + old slots before re-cloning from archetype.
local function clearIncidentHydrate(panel: Frame)
	local scroll = getIncidentsScroll(panel)
	if not scroll then
		return
	end
	for _, ch in ipairs(scroll:GetChildren()) do
		if ch:IsA("Frame") then
			local n = ch.Name
			if string.sub(n, 1, 12) == "IncidentRow_" or string.sub(n, 1, 13) == "IncidentSlot_" then
				ch:Destroy()
			end
		end
	end
end

local function layoutLossChips(host: Frame, lossOilByTier: { [string]: any }, perBarrel: number)
	for _, c in ipairs(host:GetChildren()) do
		if c.Name == "LossChip" then
			c:Destroy()
		end
	end
	if not chipArchetype then
		return
	end
	local order: { { tier: string, barrels: number } } = {}
	for _, tier in ipairs(TIER_ORDER) do
		local oil = math.max(0, math.floor(tonumber(lossOilByTier[tier]) or 0))
		local b = oilUnitsToBarrels(oil, perBarrel)
		if b > 0 then
			table.insert(order, { tier = tier, barrels = b })
		end
	end
	local n = #order
	if n == 0 then
		return
	end
	local gap = 0.012
	local padR = 0.008
	local avail = 1 - padR - gap * math.max(0, n - 1)
	local w = math.clamp(avail / n, 0.12, 0.28)
	for i, entry in ipairs(order) do
		local chip = chipArchetype:Clone()
		chip.Name = "LossChip"
		chip.Visible = true
		chip.Parent = host
		local k = n - i + 1
		local rightEdge = 1 - padR - (k - 1) * (w + gap)
		chip.AnchorPoint = Vector2.new(1, 0.5)
		chip.Position = UDim2.new(rightEdge, 0, 0.5, 0)
		chip.Size = UDim2.new(w, 0, 0.82, 0)
		local ticon = chip:FindFirstChild("TierIcon")
		if ticon and ticon:IsA("ImageLabel") then
			local col = TIER_CHIP_COLOR[entry.tier] or Color3.fromRGB(90, 90, 90)
			ticon.Image = ""
			ticon.BackgroundColor3 = col
			ticon.BackgroundTransparency = 0
		end
		local lam = chip:FindFirstChild("LossAmount")
		if lam and lam:IsA("TextLabel") then
			lam.Text = "-" .. tostring(entry.barrels)
		end
	end
end

local function clearIncidentSlotRow(row: Frame)
	local top = row:FindFirstChild("IncidentTop")
	local tit = top and top:FindFirstChild("IncidentTitle")
	if tit and tit:IsA("TextLabel") then
		tit.Text = ""
		applyIncidentTitleReadability(tit)
	end
	local host = top and top:FindFirstChild("LossChipsHost")
	if host and host:IsA("Frame") then
		layoutLossChips(host, {}, math.max(1, lastPerBarrel))
	end
end

local function ensureIncidentSlots(panel: Frame)
	if not archetypeRow then
		return
	end
	local scroll = getIncidentsScroll(panel)
	if not scroll then
		return
	end
	local hPx = incidentRowHeightPx(scroll)
	for i = 1, LEGACY_VISIBLE_ROWS do
		local row = archetypeRow:Clone()
		row.Name = "IncidentSlot_" .. tostring(i)
		row.LayoutOrder = i
		row.Visible = true
		row.Size = UDim2.new(1, 0, 0, hPx)
		row.Parent = scroll
		clearIncidentSlotRow(row)
	end
	refreshAllIncidentRowHeights(scroll)
end

local function resolveIncidentTitle(inc: { [string]: any }): string
	if inc.totalLoss == true then
		return "Total loss"
	end
	local eid = inc.eventId
	if typeof(eid) == "string" and eid ~= "" then
		return ManifestIncidentTitle.fromEventId(eid)
	end
	return ManifestIncidentTitle.fromDisplayName(tostring(inc.title or ""))
end

local function fillIncidentRow(row: Frame, inc: { [string]: any }, lossOilByTier: { [string]: any }, perBarrel: number)
	local top = row:FindFirstChild("IncidentTop")
	local tit = top and top:FindFirstChild("IncidentTitle")
	if tit and tit:IsA("TextLabel") then
		tit.Text = resolveIncidentTitle(inc)
		applyIncidentTitleReadability(tit)
	end
	local host = top and top:FindFirstChild("LossChipsHost")
	if host and host:IsA("Frame") then
		layoutLossChips(host, lossOilByTier, perBarrel)
	end
end

local function fillNextIncidentSlot(panel: Frame, inc: { [string]: any }, lossOilByTier: { [string]: any }, perBarrel: number)
	local scroll = getIncidentsScroll(panel)
	if not scroll then
		return
	end
	if not archetypeRow then
		return
	end
	nextIncidentSlotIndex += 1
	local idx = nextIncidentSlotIndex
	local cand = scroll:FindFirstChild("IncidentSlot_" .. tostring(idx))
	local row: Frame? = if cand and cand:IsA("Frame") then cand else nil
	if not row then
		row = archetypeRow:Clone()
		row.Name = "IncidentSlot_" .. tostring(idx)
		row.LayoutOrder = idx
		row.Visible = true
		row.Size = UDim2.new(1, 0, 0, incidentRowHeightPx(scroll))
		row.Parent = scroll
	end
	if row and row:IsA("Frame") then
		fillIncidentRow(row, inc, lossOilByTier, perBarrel)
	end
end

--- Snapshot the panel's authored Studio geometry once so the collapse/expand toggle
--- can restore it cleanly. Safe to call repeatedly; only the first call wins.
--- This is the **UDim2** capture (independent of layout); the rendered top-left
--- fraction is captured separately by `captureExpandedRenderedTopLeftFraction`
--- after layout has settled.
local function captureAuthoredGeometry(panel: Frame)
	if authoredSize then
		return
	end
	authoredSize = panel.Size
	authoredPosition = panel.Position
	authoredAnchor = panel.AnchorPoint
	local arc = panel:FindFirstChildOfClass("UIAspectRatioConstraint")
	if arc then
		authoredAspect = arc
	end
	local uic = panel:FindFirstChildOfClass("UICorner")
	if uic then
		authoredCornerRadius = uic.CornerRadius
	end
	local hdr = panel:FindFirstChild("ManifestHeader")
	if hdr and hdr:IsA("GuiObject") then
		authoredHeaderSize = hdr.Size
		authoredHeaderPosition = hdr.Position
		local title = hdr:FindFirstChild("ManifestTitle")
		if title and title:IsA("TextLabel") then
			local t = title :: TextLabel
			authoredTitleSize = t.Size
			authoredTitlePosition = t.Position
			authoredTitleAnchor = t.AnchorPoint
			authoredTitleXAlignment = t.TextXAlignment
		end
	end
end

--- Strip any leftover `CollapseChevron` from a prior session so it doesn't
--- linger after we removed the chevron feature. Cheap; no-op when absent.
local function removeLegacyCollapseChevron(panel: Frame)
	local hdr = panel:FindFirstChild("ManifestHeader")
	if not hdr then return end
	local chev = hdr:FindFirstChild("CollapseChevron")
	if chev then
		chev:Destroy()
	end
end

--- Convert a `UIPadding` UDim child (e.g. `PaddingLeft`) into pixels relative to the
--- containing axis size (`UIPadding` itself is configured as `UDim` per side).
local function udimToPx(u: UDim, dim: number): number
	return u.Scale * dim + u.Offset
end

--- Compute the parent's *inner* layout box (post-`UIPadding`) in viewport pixels.
--- Returns `(innerX, innerY, innerW, innerH)`. A child positioned at `Scale (sx, sy)`
--- with anchor `(0, 0)` lands at viewport `(innerX + sx * innerW, innerY + sy * innerH)`.
local function getInnerBoxPx(parentFrame: GuiObject): (number, number, number, number)
	local pad = parentFrame:FindFirstChildOfClass("UIPadding")
	local absSize = parentFrame.AbsoluteSize
	local absPos = parentFrame.AbsolutePosition
	local padL = if pad then udimToPx(pad.PaddingLeft, absSize.X) else 0
	local padR = if pad then udimToPx(pad.PaddingRight, absSize.X) else 0
	local padT = if pad then udimToPx(pad.PaddingTop, absSize.Y) else 0
	local padB = if pad then udimToPx(pad.PaddingBottom, absSize.Y) else 0
	return absPos.X + padL, absPos.Y + padT, math.max(1, absSize.X - padL - padR), math.max(1, absSize.Y - padT - padB)
end

--- Snapshot the rendered top-left of the **expanded** panel as a 0-1 fraction of the
--- parent's inner padded box. Must be called when the panel is in its expanded state
--- and after a layout pass (so `AbsolutePosition` reflects post-`UIAspectRatioConstraint`
--- geometry). Idempotent — only the first call wins.
local function captureExpandedRenderedTopLeftFraction(panel: Frame)
	if expandedTopLeftFracX ~= nil then
		return
	end
	local parent = panel.Parent
	if not (parent and parent:IsA("GuiObject")) then
		return
	end
	if panel.AbsoluteSize.X <= 0 or panel.AbsoluteSize.Y <= 0 then
		return
	end
	local innerX, innerY, innerW, innerH = getInnerBoxPx(parent :: GuiObject)
	expandedTopLeftFracX = (panel.AbsolutePosition.X - innerX) / innerW
	expandedTopLeftFracY = (panel.AbsolutePosition.Y - innerY) / innerH
end

--- Compute the **CashStrip's left-edge fraction** in the same parent inner-box
--- coordinate space the collapsed pill uses. We re-read this every collapse rather
--- than caching once because it's cheap, and reading live tracks any future
--- re-author of the cash strip (or viewport reflow that subtly shifts its absolute
--- pixel) without a stale snapshot. CashStrip is the canonical "left HUD column"
--- reference: `Cash` row at the top, `ActiveManifestPanel` collapsed pill below it,
--- so the pill's left edge stays flush with everything in that column.
local function getCashStripLeftEdgeFraction(panel: Frame): number?
	local parent = panel.Parent
	if not (parent and parent:IsA("GuiObject")) then
		return nil
	end
	local cashStrip = parent:FindFirstChild("CashStrip")
	if not (cashStrip and cashStrip:IsA("GuiObject")) then
		return nil
	end
	if cashStrip.AbsoluteSize.X <= 0 then
		return nil
	end
	local innerX, _innerY, innerW, _innerH = getInnerBoxPx(parent :: GuiObject)
	return (cashStrip.AbsolutePosition.X - innerX) / innerW
end

--- Apply the current `isCollapsed` state to the panel: shrink to header band when
--- collapsed (anchoring to the authored top edge), restore authored size+aspect
--- when expanded. Section visibility follows: hidden when collapsed; shown when
--- expanded **and** a shipment is active (idle expanded keeps sections hidden so
--- we don't reveal stale rows from the last voyage).
local function applyCollapseState(panel: Frame)
	if not (authoredSize and authoredPosition) then
		return
	end
	local sectionsVisible = (not isCollapsed) and (activeShipmentId ~= nil)
	for _, name in ipairs(SECTION_NAMES) do
		local sec = panel:FindFirstChild(name)
		if sec and sec:IsA("GuiObject") then
			sec.Visible = sectionsVisible
		end
	end
	local hdr = panel:FindFirstChild("ManifestHeader")
	-- Corner radius: authored is `UDim.new(0.1, 0)` = 10% of the smaller axis. At full
	-- card size that's ~21px (looks intentionally rounded); at the small collapsed pill
	-- size that drops to ~3-4px and reads as a square box. Scale-up to a true pill
	-- (`UDim.new(0.5, 0)` = 50% of half-height = fully round ends) when collapsed,
	-- restore the authored value on expand. Stored on a separate `UICorner` so we
	-- don't blow away other authored properties on the panel.
	local uic = panel:FindFirstChildOfClass("UICorner")
	if isCollapsed then
		-- Detach the aspect constraint so the collapsed pill isn't forced to keep
		-- the tall authored ratio (which would shrink the X axis to a sliver).
		if authoredAspect and authoredAspect.Parent ~= nil then
			authoredAspect.Parent = nil
		end
		if uic then
			uic.CornerRadius = UDim.new(0.5, 0)
		end
		-- Switch to a top-left anchor so `Position` represents the top-left corner
		-- directly, with no anchor-vs-size math to get wrong. Using **Scale** for both
		-- Position and Size keeps the pill responsive to viewport changes; the parent's
		-- inner padded box scales proportionally with the viewport so a fixed scale
		-- fraction stays anchored to the same visual slot.
		panel.AnchorPoint = Vector2.new(0, 0)
		panel.Size = UDim2.fromScale(COLLAPSED_X_SCALE, COLLAPSED_Y_SCALE)

		-- X axis: anchor to the **CashStrip's left edge**, not the expanded panel's
		-- top-left. The expanded panel is right-anchored (AnchorPoint.X = 1) so its
		-- top-left X drifts leftward as the viewport widens, dragging the collapsed
		-- pill out of the left HUD column. CashStrip is anchored top-left and lives
		-- in that column with the teleport buttons, so using its left edge keeps the
		-- collapsed pill flush with the rest of the column at any viewport width.
		--
		-- Y axis: keep the captured rendered top of the expanded panel so the pill
		-- still sits where the full panel's top edge would, preserving the vertical
		-- slot designers authored.
		local fx = getCashStripLeftEdgeFraction(panel)
		local fy = expandedTopLeftFracY
		if not fy then
			-- Lazily try once more in case the panel has now been laid out.
			captureExpandedRenderedTopLeftFraction(panel)
			fy = expandedTopLeftFracY
		end
		if not fx then
			-- Fallback: derive X from the authored panel UDim2 corner. Rare path —
			-- only triggers if the CashStrip child is missing or hasn't laid out yet.
			local anchor = authoredAnchor or panel.AnchorPoint
			fx = (authoredPosition :: UDim2).X.Scale - anchor.X * (authoredSize :: UDim2).X.Scale
		end
		if not fy then
			local anchor = authoredAnchor or panel.AnchorPoint
			fy = (authoredPosition :: UDim2).Y.Scale - anchor.Y * (authoredSize :: UDim2).Y.Scale
		end
		panel.Position = UDim2.fromScale(fx, fy)

		-- Stretch the header to fill the whole pill so the `TextScaled` title
		-- reclaims the available pixel area (capped by `UITextSizeConstraint`).
		-- Also re-anchor `ManifestTitle` to the geometric center — its authored
		-- Position / AnchorPoint targets the small expanded title strip and would
		-- otherwise push the text toward the top of the stretched pill.
		if hdr and hdr:IsA("GuiObject") then
			hdr.Size = UDim2.new(1, 0, 1, 0)
			hdr.Position = UDim2.new(0, 0, 0, 0)
			local title = hdr:FindFirstChild("ManifestTitle")
			if title and title:IsA("TextLabel") then
				local t = title :: TextLabel
				t.AnchorPoint = Vector2.new(0.5, 0.5)
				t.Position = UDim2.fromScale(0.5, 0.5)
				-- Width leaves ~14% on the right for the chevron + 4-8px insets;
				-- height fills most of the band so `TextScaled` picks the largest
				-- legible size against `UITextSizeConstraint` (if authored).
				t.Size = UDim2.fromScale(0.78, 0.85)
				t.TextXAlignment = Enum.TextXAlignment.Center
			end
		end
	else
		-- Expand: pin the **same top-left corner** as the collapsed pill (CashStrip's
		-- left edge X + captured expanded-top Y). That way the panel grows downward
		-- from a single fixed anchor instead of "jumping" to the original right-anchored
		-- authored slot, which sits ~5-20px right of the left HUD column on wide
		-- viewports because the authored AnchorPoint is (1, 0.5).
		--
		-- We reattach the aspect constraint so the card keeps its tall silhouette,
		-- restore the authored UDim2 Size, but **keep AnchorPoint at (0, 0)** and
		-- compute Position from the same X/Y fractions the collapsed branch uses.
		-- Original `authoredAnchor` / `authoredPosition` are preserved on the module
		-- (not on the instance) in case we ever need to revert to the Studio-authored
		-- right-anchored layout — they're intentionally not re-applied here.
		if authoredAspect and authoredAspect.Parent == nil then
			authoredAspect.Parent = panel
		end
		if uic and authoredCornerRadius then
			uic.CornerRadius = authoredCornerRadius
		end
		panel.AnchorPoint = Vector2.new(0, 0)
		panel.Size = authoredSize

		local fx = getCashStripLeftEdgeFraction(panel)
		local fy = expandedTopLeftFracY
		if not fy then
			captureExpandedRenderedTopLeftFraction(panel)
			fy = expandedTopLeftFracY
		end
		if not fx then
			-- Fallback: math-derived corner from the authored UDim2 + anchor.
			local anchor = authoredAnchor or panel.AnchorPoint
			fx = (authoredPosition :: UDim2).X.Scale - anchor.X * (authoredSize :: UDim2).X.Scale
		end
		if not fy then
			local anchor = authoredAnchor or panel.AnchorPoint
			fy = (authoredPosition :: UDim2).Y.Scale - anchor.Y * (authoredSize :: UDim2).Y.Scale
		end
		panel.Position = UDim2.fromScale(fx, fy)

		if hdr and hdr:IsA("GuiObject") and authoredHeaderSize and authoredHeaderPosition then
			hdr.Size = authoredHeaderSize
			hdr.Position = authoredHeaderPosition
			local title = hdr:FindFirstChild("ManifestTitle")
			if title and title:IsA("TextLabel") and authoredTitleSize and authoredTitlePosition then
				local t = title :: TextLabel
				if authoredTitleAnchor then t.AnchorPoint = authoredTitleAnchor end
				t.Position = authoredTitlePosition
				t.Size = authoredTitleSize
				if authoredTitleXAlignment then t.TextXAlignment = authoredTitleXAlignment end
			end
		end
	end
end

--- Wire a transparent click target across `ManifestHeader` so the player can
--- manually toggle the pill regardless of voyage state. Idempotent.
local function ensureHeaderToggle(panel: Frame)
	if headerToggleConn then
		return
	end
	local hdr = panel:FindFirstChild("ManifestHeader")
	if not (hdr and hdr:IsA("GuiObject")) then
		return
	end
	local btn = hdr:FindFirstChild("_HeaderToggle")
	if not (btn and btn:IsA("TextButton")) then
		local b = Instance.new("TextButton")
		b.Name = "_HeaderToggle"
		b.BackgroundTransparency = 1
		b.Text = ""
		b.AutoButtonColor = false
		b.Size = UDim2.new(1, 0, 1, 0)
		b.Position = UDim2.new(0, 0, 0, 0)
		b.ZIndex = (hdr.ZIndex or 1) + 10
		b.Parent = hdr
		btn = b
	end
	headerToggleConn = (btn :: TextButton).Activated:Connect(function()
		isCollapsed = not isCollapsed
		if panelRef then
			applyCollapseState(panelRef)
		end
	end)
end

local function setIdle(panel: Frame)
	activeShipmentId = nil
	hydratedShipmentId = nil
	nextIncidentSlotIndex = 0
	clearIncidentRuntimeSlots(panel)
	local mh = panel:FindFirstChild("ManifestHeader")
	local mtitle = mh and mh:FindFirstChild("ManifestTitle")
	if mtitle and mtitle:IsA("TextLabel") then
		mtitle.Text = TITLE_IDLE
	end
	-- Auto-collapse on every transition into idle (also covers initial bind).
	isCollapsed = true
	wasActive = false
	applyCollapseState(panel)
end

local function setActiveChrome(panel: Frame)
	local mh = panel:FindFirstChild("ManifestHeader")
	local mtitle = mh and mh:FindFirstChild("ManifestTitle")
	if mtitle and mtitle:IsA("TextLabel") then
		mtitle.Text = TITLE_ACTIVE
	end
	-- Auto-expand only on the idle → active edge so a manual collapse during an
	-- ongoing voyage isn't clobbered by every subsequent ManifestHudSnapshot.
	if not wasActive then
		isCollapsed = false
		wasActive = true
	end
	applyCollapseState(panel)
end

local function applyLoadedAndDelivery(panel: Frame, dispatched: { [string]: any }, remaining: { [string]: any }, perBarrel: number)
	local loaded = panel:FindFirstChild("LoadedSection")
	local lb = loaded and loaded:FindFirstChild("SectionBody")
	if lb then
		for tier, rowName in pairs(ROW_FOR_TIER) do
			local row = lb:FindFirstChild(rowName)
			if row and row:IsA("Frame") then
				local oil = math.max(0, math.floor(tonumber(dispatched[tier]) or 0))
				local cnt = row:FindFirstChild("BarrelCount")
				if cnt and cnt:IsA("TextLabel") then
					cnt.Text = "x" .. tostring(oilUnitsToBarrels(oil, perBarrel))
				end
			end
		end
	end
	local ds = panel:FindFirstChild("DeliverySection")
	local db = ds and ds:FindFirstChild("SectionBody")
	if db then
		local netOil = sumOil(remaining)
		local netBarrels = oilUnitsToBarrels(netOil, perBarrel)
		for _, ch in ipairs(db:GetChildren()) do
			if ch:IsA("TextLabel") then
				ch.Text = string.format("Net %d barrels", netBarrels)
				break
			end
		end
	end
end

local function onManifestHudSnapshot(player: Player, data: { [string]: any })
	local panel = panelRef or resolvePanel(playerGuiRef :: PlayerGui)
	if not panel then
		return
	end
	panelRef = panel
	local sid = data.shipmentId
	if typeof(sid) ~= "string" then
		return
	end
	activeShipmentId = sid
	lastPerBarrel = math.max(1, math.floor(tonumber(data.perBarrelOil) or 1))
	local dispatched = data.dispatchedOilByTier
	local remaining = data.remainingOilByTier
	if typeof(dispatched) ~= "table" or typeof(remaining) ~= "table" then
		return
	end
	if sid ~= hydratedShipmentId then
		hydratedShipmentId = sid
		ensureArchetypes(panel)
		clearIncidentHydrate(panel)
		ensureIncidentSlots(panel)
		nextIncidentSlotIndex = 0
	end
	setActiveChrome(panel)
	applyLoadedAndDelivery(panel, dispatched, remaining, lastPerBarrel)
	local inc = data.incident
	if typeof(inc) == "table" then
		local lossOil = inc.lossOilByTier
		if typeof(lossOil) == "table" then
			fillNextIncidentSlot(panel, inc, lossOil, lastPerBarrel)
		end
	end
end

local function onShipmentResolved(_player: Player, data: { [string]: any })
	local sid = data.shipmentId
	if typeof(sid) == "string" and activeShipmentId and sid ~= activeShipmentId then
		return
	end
	local panel = panelRef or resolvePanel(playerGuiRef :: PlayerGui)
	if not panel then
		return
	end
	setIdle(panel)
end

local ActiveManifestController = {}

function ActiveManifestController.start(playerGui: PlayerGui)
	playerGuiRef = playerGui
	ActiveManifestHud.tryBind(playerGui)
	local panel = resolvePanel(playerGui)
	if panel then
		if not panelRef then
			panelRef = panel
			captureAuthoredGeometry(panel)
			ensureHeaderToggle(panel)
			removeLegacyCollapseChevron(panel)
			-- Defer the initial collapse so the panel renders once at its expanded
			-- (post-`UIAspectRatioConstraint`) geometry first. We need that single
			-- layout pass to capture the rendered top-left fraction; without it,
			-- `AbsolutePosition` is `(0, 0)` and the captured fraction would lie.
			-- Wait until layout reports a non-zero `AbsoluteSize` before snapshotting,
			-- bounded so a stuck layout never blocks the idle state forever.
			task.spawn(function()
				for _ = 1, 60 do
					if not panel.Parent then
						return
					end
					if panel.AbsoluteSize.X > 0 and panel.AbsoluteSize.Y > 0 then
						break
					end
					task.wait()
				end
				if panel.Parent then
					captureExpandedRenderedTopLeftFraction(panel)
				end
				setIdle(panel)
				print(
					string.format(
						"[Client] ActiveManifestController: bound panel; collapsed=%s authoredSize=%s expandedTopLeftFrac=(%s, %s)",
						tostring(isCollapsed),
						tostring(authoredSize),
						tostring(expandedTopLeftFracX),
						tostring(expandedTopLeftFracY)
					)
				)
			end)
		end
	else
		warn("[Client] ActiveManifestController.start: ActiveManifestPanel not found under HUD.Canvas yet.")
	end
end

function ActiveManifestController.onVisualPacket(kind: string, data: { [string]: any }, localPlayer: Player)
	if typeof(data) ~= "table" then
		return
	end
	if kind == "ManifestHudSnapshot" then
		onManifestHudSnapshot(localPlayer, data)
	elseif kind == "ShipmentResolved" then
		onShipmentResolved(localPlayer, data)
	end
end

return ActiveManifestController
