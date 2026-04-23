--!strict
-- Ship management panel v2 (`StarterGui.FleetPanelGui` → `PlayerGui`).
-- Replaces the legacy `ShipManagementPanel` flow's split (manage + select)
-- with a single inline modal: 3-column scroll grid of all owned + buyable
-- boats on the left, hero preview + segment bars + action button on the
-- right.
--
-- Data flow (matches `SelectShipPanel`):
--   1. Studio authoring is the source of truth for layout, chrome, strokes,
--      prototype state frames (`StateGold` / `StateRobux` / `StateEquip`
--      / `StateEquipped` / `StateBuy`). See `FleetPanelPopulate.luau`
--      docstring for the full set.
--   2. On `bind` we pull a fresh oil-state snapshot, build the catalog
--      list (`FleetPanelPopulate.SortedBoatList`), clone the
--      `BoatCardTemplate` once per non-placeholder boat, and apply state
--      via `FleetPanelPopulate.Apply` / `.HydrateRightColumn`.
--   3. We listen to `oilStateUpdate` so a Robux purchase (server pushes
--      a fresh `ownedBoatIds`) re-paints the affected card from BUY → OWNED
--      and an equip action flips the gold halo + hero preview without
--      having to close + reopen.
--
-- Click routing:
--   * Card press OR right-column ACTION button when state is `Equip` →
--     fires `RequestSetSelectedBoat({ boatId })` (same remote
--     `SelectShipPanel` uses).
--   * Card press OR right-column action when state is `Buy` and unlock is
--     `robux` → `RequestPromptRobuxPurchase({ itemId })`.
--   * Card press OR right-column action when state is `Buy` and unlock is
--     `cash` → `RequestUnlockBoat({ boatId })`. Server gates the cash
--     spend in `OilStateService:TryUnlockBoat`.
--   * State `Equipped` → no-op (visual feedback only).
--
-- Wired through `HudPanelRouter` (see `SCREEN_BIND`); the dockman
-- `ManageShipPrompt.OpensPanel = "FleetPanelGui"` attribute opens it via
-- `ProximityPanelOpener`. `FleetPanel.openForTesting()` is a convenience
-- for design-time previews from the command bar.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

-- FTUE bridge: closing `FleetPanelGui` while on `WaitDocksFleetPanel` +
-- sub `ClosePanel` advances the FTUE to `WaitDocksHire`. See
-- `FtueService.OnFtueDocksProgress("FleetPanelClosed")`. Required imports
-- live below the existing `Shared`/`HudPanelBase` block.
local Constants = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Constants"))
local FtueConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("FtueConfig"))

-- Card hover / selection feedback. Three visual states a card can be in:
--   * `idle`     — base navy, scale 1.00
--   * `hover`    — slightly brighter navy + tiny lift (scale 1.02)
--   * `selected` — slightly darker navy + depressed (scale 0.96)
-- The equipped gold halo (`RarityStroke`) is left untouched in all three
-- states so designers can tell "equipped" apart from "currently being
-- previewed in the right column" at a glance — they can co-exist (an
-- equipped card can also be the selected one, in which case it shows
-- gold halo + depressed scale + darker bg).
local CARD_BG_IDLE = Color3.fromRGB(15, 28, 48)
local CARD_BG_HOVER = Color3.fromRGB(24, 42, 66)
local CARD_BG_SELECTED = Color3.fromRGB(8, 16, 30)
local CARD_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local CARD_HOVER_SCALE = 1.02
local CARD_SELECTED_SCALE = 0.96
-- Stamped on each card root via `SetAttribute` so re-renders by `Apply`
-- (which mutates lots of attributes) don't lose the per-card UIScale.
local CARD_HOVER_ATTR = "FleetCardHovered"

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BoatCatalog = require(Shared:WaitForChild("Config"):WaitForChild("BoatCatalog"))
local HudPanelBase = require(script.Parent.Parent.HudPanelBase)
local HudPanelTypes = require(script.Parent.Parent.HudPanelTypes)
local FleetPanelPopulate = require(script.Parent.FleetPanelPopulate)
local getClientRemotes = require(script.Parent.Parent.Parent:WaitForChild("GetClientRemotes")) :: () -> any
local ClientRemotes = getClientRemotes()
-- SFX parity with the deleted `ShipManagementPanel` + `SelectShipPanel`:
--   * `playSetSail` on equip — the legacy flow had no equip SFX (equip was
--     a side-effect of ship selection); we add it here to match
--     `ShipOilPanel.dispatchSelected` ("set sail") so the player gets a
--     positive audio confirmation when a new boat actually goes live.
--   * `playKaching` / `playUiDenied` on the cash unlock receipt
--     (`oilActionResult` with `action = "UnlockBoat"`). The Robux unlock
--     path is already covered by `MonetizationSfxBootstrap.client.luau`
--     (global listener on `monetizationResult` → kaching on `code = "OK"`),
--     so we don't double-fire here.
local UiSfx = require(script.Parent.Parent.Parent:WaitForChild("UiSfx")) :: {
	playSetSail: () -> (),
	playKaching: () -> (),
	playUiDenied: () -> (),
}

local SCREEN_NAME = "FleetPanelGui"
local TEMPLATE_NAME = "BoatCardTemplate"
local CATALOG_ATTR = "FleetCatalogCard"
-- Names previously used by the design-time MCP authoring pass; kept as a
-- list so a future re-author with a different scroller name doesn't break
-- the binder. Add to this list if the Studio name changes.
local SCROLLER_NAMES = { "FleetGrid", "BoatGrid", "ShipGrid" }
-- Studio authors `ErrorNotification` somewhere under the panel
-- (canonically `Canvas.PanelHost.ErrorNotification`) — same name +
-- placement convention as `SellOilPanel`/`ShipOilPanel`. Runtime only
-- mutates `Text` / `Visible` / `TextTransparency` so the Studio look
-- (color, stroke, position, aspect) stays 1:1 with the authored design.
local ERROR_NOTIFICATION_NAME = "ErrorNotification"

local FleetPanel = {}

local wiredScreen: ScreenGui? = nil
local connections: { RBXScriptConnection } = {}
-- The card root used to be `Frame`. The authored template is now an
-- `ImageButton` (so `MouseButton1Click` works without overlay tricks),
-- so we widen to `GuiObject` — both classes are accepted by
-- `FleetPanelPopulate.Apply` (it only reads children + attributes).
local liveCards: { [string]: GuiObject } = {}
-- Snapshot of `state.ownedBoatIds` from the most recent push. Re-rendered
-- whenever it changes so a Robux purchase landed by `MonetizationService`
-- flips the affected card from BUY → OWNED in place.
local ownedBoatSet: { [string]: boolean } = { Tier1Boat = true }
local equippedBoatId: string = "Tier1Boat"
-- Card-click selection. Drives the right-column hero / bars / action
-- button independently of `equippedBoatId`, so a player can preview any
-- boat (owned, unowned, or placeholder) without having to equip it first.
-- Defaults to the equipped boat on bind so the panel opens already
-- showing the player's current ship.
local selectedBoatId: string = "Tier1Boat"
local lastEquipFire = 0.0
local lastBuyFire = 0.0
-- Right-column controller dependencies cached during bind so re-renders
-- (e.g. after `oilStateUpdate`) don't re-traverse the panel each tick.
local rightCol: Frame? = nil
local rightActionButton: TextButton? = nil
local rightCostPill: GuiObject? = nil
-- Equipped-accent color sampled from the panel's gold stroke at bind time
-- so a designer rotating the panel's gold tone in Studio propagates to
-- every "equipped" indicator (rarity halo, owned chip stroke, lit segments).
local equippedAccent: Color3 = Color3.fromRGB(217, 177, 76)
-- Studio-authored ephemeral red label (`Canvas.PanelHost.ErrorNotification`).
-- `errorNotificationSeq` lets late-firing fade tweens detect they were
-- superseded by a newer error message and bail out instead of stomping
-- the now-current text. Same pattern as `SellOilPanel`.
local errorNotificationLabel: TextLabel? = nil
local errorNotificationSeq = 0

--- Studio-authored ephemeral red label, located anywhere under the panel
--- (canonically `Canvas.PanelHost.ErrorNotification`). Runtime ONLY mutates
--- `Text` / `Visible` / `TextTransparency` — appearance + placement stay 1:1
--- with the Studio placeholder. If Studio hasn't authored one, we surface
--- a single warn so it's caught (no fabricated fallback that drifts visually).
local function findStudioErrorNotificationLabel(screen: ScreenGui): TextLabel?
	local found = screen:FindFirstChild(ERROR_NOTIFICATION_NAME, true)
	if found and found:IsA("TextLabel") then
		return found
	end
	return nil
end

local function hideErrorNotification()
	errorNotificationSeq += 1
	if errorNotificationLabel then
		errorNotificationLabel.Visible = false
	end
end

--- Show `message` for `holdSeconds`, then fade out over 0.35s. Re-entrant:
--- a second call before the first's fade completes wins (the older fade's
--- closure sees `seq ~= errorNotificationSeq` and bails without touching
--- the now-visible newer text). No-op if Studio hasn't authored a label.
local function showErrorNotification(message: string, holdSeconds: number)
	local label = errorNotificationLabel
	if not label or not label.Parent then
		return
	end
	errorNotificationSeq += 1
	local seq = errorNotificationSeq
	label.Text = message
	label.TextTransparency = 0
	label.Visible = true
	task.delay(holdSeconds, function()
		if seq ~= errorNotificationSeq or not label.Parent then
			return
		end
		local tw = TweenService:Create(label, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			TextTransparency = 1,
		})
		tw:Play()
		tw.Completed:Wait()
		if seq ~= errorNotificationSeq or not label.Parent then
			return
		end
		label.Visible = false
		label.TextTransparency = 0
	end)
end

local function disconnectAll()
	for _, c in ipairs(connections) do
		c:Disconnect()
	end
	table.clear(connections)
	table.clear(liveCards)
	rightCol = nil
	rightActionButton = nil
	rightCostPill = nil
	hideErrorNotification()
	errorNotificationLabel = nil
	wiredScreen = nil
end

local function findFleetGrid(panel: Instance): ScrollingFrame?
	for _, name in ipairs(SCROLLER_NAMES) do
		local s = panel:FindFirstChild(name, true)
		if s and s:IsA("ScrollingFrame") then
			return s :: ScrollingFrame
		end
	end
	return nil
end

local function findRightColumn(panel: Instance): Frame?
	-- The MainSplit pattern lives at `Body.MainSplit.RightColumn`; use a
	-- recursive descendant search so a future layout shuffle that puts the
	-- right column under a different parent still binds.
	local rc = panel:FindFirstChild("RightColumn", true)
	if rc and rc:IsA("Frame") then
		return rc :: Frame
	end
	return nil
end

local function destroyOldClones(scroller: ScrollingFrame)
	for _, ch in ipairs(scroller:GetChildren()) do
		if ch:GetAttribute(CATALOG_ATTR) == true then
			ch:Destroy()
		elseif ch:IsA("Frame") and string.sub(ch.Name, 1, #"BoatCard_") == "BoatCard_" then
			ch:Destroy()
		end
	end
end

--- The FleetGrid scroller is authored with a `UIAspectRatioConstraint`
--- (1.336 = HD 732/548 ratio) so its `AbsoluteSize` is a stable shape
--- across every viewport. The card template carries its own
--- `UIAspectRatioConstraint` (≈1.069 W:H). Together that means cell
--- height MUST match `cellWidth / cardAspect` — otherwise the card
--- shrinks-to-fit aspect inside a too-tall cell and `FitWithinMaxSize`
--- centers it, leaving empty space above the first row (the bug we
--- chased on mobile).
---
--- Resolved at bind time (and on viewport changes) as a fixed-pixel
--- offset. Using fixed pixels keeps `CellSize.Y` immune to the
--- canvas-vs-viewport feedback loop that bit us when this was authored
--- as `{0.42 scale, 0}` against a script-grown CanvasSize.
local FLEET_CELL_WIDTH_SCALE = 0.32
local FLEET_CARD_ASPECT = 1.069 -- W:H, matches BoatCardTemplate.UIAspectRatioConstraint
local FLEET_CELL_X_PADDING_SCALE = 0.02
local FLEET_CELL_Y_PADDING_SCALE = 0.025

local function maintainScroll(scroller: ScrollingFrame)
	-- Replaces the standalone `FleetGridScrollMaintainer` LocalScript
	-- (deleted on bind below). We own three things: cell sizing
	-- (recomputed from the aspect-locked scroller width), canvas size
	-- (grown from `AbsoluteContentSize`), and the scroll-to-top reset.
	scroller.AutomaticCanvasSize = Enum.AutomaticSize.None
	scroller.ScrollingDirection = Enum.ScrollingDirection.Y
	-- Reset scroll-to-top on every bind. StarterGui can persist a stale
	-- `CanvasPosition` from a prior Play session (UIGridLayout's old
	-- content size + the player having scrolled), which on small mobile
	-- viewports made the first row appear partway down the
	-- FleetGridCard at panel-open before any user interaction.
	scroller.CanvasPosition = Vector2.new(0, 0)
	local layout = scroller:FindFirstChildOfClass("UIGridLayout")
	if not layout then return end

	-- Recompute cell sizing from current viewport. Fixed-pixel result
	-- means the next `AbsoluteContentSize` change won't cycle back into
	-- another cell-size change → no feedback loop with `refreshCanvas`.
	local function recomputeCells()
		local viewport = scroller.AbsoluteSize
		if viewport.X <= 0 or viewport.Y <= 0 then return end
		local cellW = viewport.X * FLEET_CELL_WIDTH_SCALE
		local cellH = math.floor(cellW / FLEET_CARD_ASPECT)
		local newCellSize = UDim2.new(FLEET_CELL_WIDTH_SCALE, 0, 0, cellH)
		local newCellPad = UDim2.new(FLEET_CELL_X_PADDING_SCALE, 0, 0, math.floor(viewport.Y * FLEET_CELL_Y_PADDING_SCALE))
		-- Avoid a no-op write that would still trigger property
		-- changed signals and cascade pointlessly.
		if layout.CellSize ~= newCellSize then
			layout.CellSize = newCellSize
		end
		if layout.CellPadding ~= newCellPad then
			layout.CellPadding = newCellPad
		end
	end

	-- Grow `CanvasSize.Y` to fit the laid-out content, but never let it
	-- collapse below the viewport (keeps the scroll area visually
	-- present even when only one row of cards is loaded).
	local function refreshCanvas()
		local content = layout.AbsoluteContentSize
		local viewport = scroller.AbsoluteSize
		local needY = content.Y + 12 -- breathing room below the last row
		local minY = viewport.Y
		scroller.CanvasSize = UDim2.new(0, 0, 0, math.max(needY, minY))
	end

	-- Viewport change → cells may need re-sizing → canvas needs re-fit.
	-- Content change (cards added / removed) → canvas re-fit only.
	table.insert(connections, scroller:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		recomputeCells()
		refreshCanvas()
	end))
	table.insert(connections, layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(refreshCanvas))
	recomputeCells()
	refreshCanvas()
end

local function pullSnapshot()
	local ok, pack = pcall(function()
		return ClientRemotes.requestOilSnapshot:InvokeServer()
	end)
	if not ok then return end
	if typeof(pack) ~= "table" then return end
	local st = (pack :: any).state
	if typeof(st) ~= "table" then return end
	local id = (st :: any).equippedBoatId
	if typeof(id) == "string" and BoatCatalog.Boats[id] and not BoatCatalog.Boats[id].placeholder then
		equippedBoatId = id
	end
	local owned = (st :: any).ownedBoatIds
	if typeof(owned) == "table" then
		ownedBoatSet = { Tier1Boat = true }
		for boatId, isOwned in pairs(owned) do
			if typeof(boatId) == "string" and isOwned == true then
				ownedBoatSet[boatId] = true
			end
		end
	end
end

local function fireEquip(boatId: string)
	local now = os.clock()
	if now - lastEquipFire < 0.35 then return end
	lastEquipFire = now
	-- "Set sail" sting plays optimistically. `RequestSetSelectedBoat`
	-- doesn't round-trip through `oilActionResult` (see
	-- `PlotResourceService` — equip writes server state and pushes
	-- `oilStateUpdate`, no result envelope), so we don't have a server
	-- ack to gate on. The only failure mode is `OwnsBoat == false` which
	-- the client UI already gates against (Equip button only appears for
	-- owned boats), so a false-positive sting is effectively unreachable.
	UiSfx.playSetSail()
	ClientRemotes.requestSetSelectedBoat:FireServer({ boatId = boatId })
end

local function firePurchase(boatId: string, monetizationItemId: string?, unlockKind: string?)
	local now = os.clock()
	if now - lastBuyFire < 0.6 then return end
	lastBuyFire = now
	if unlockKind == "robux" then
		if typeof(monetizationItemId) ~= "string" or monetizationItemId == "" then
			-- Robux unlock authored but no `MonetizationCatalog` entry yet
			-- (e.g. catalog says `kind = "robux"` with `devProductId` 0).
			-- Silent no-op rather than crash; designer sees `R$ —` on the
			-- pill so this is visible at design time.
			return
		end
		-- Server: `MonetizationService` opens the Roblox prompt; on a
		-- verified receipt it calls `OilStateService:GrantBoat`, which
		-- pushes a fresh `oilStateUpdate` (caught by our listener below)
		-- → cards + right column flip BUY → OWNED → EQUIP automatically.
		ClientRemotes.requestPromptRobuxPurchase:FireServer({ itemId = monetizationItemId })
	elseif unlockKind == "cash" then
		-- Server: `PlotResourceService.RequestUnlockBoat` →
		-- `OilStateService:TryUnlockBoat` debits cash, calls `GrantBoat`,
		-- then pushes an `oilStateUpdate` snapshot. Same UI-refresh path
		-- as the Robux branch — no client-side optimism needed.
		ClientRemotes.requestUnlockBoat:FireServer({ boatId = boatId })
	end
end

--- Repaint the right column for `selectedBoatId` (the boat the player
--- last clicked on the left grid; defaults to `equippedBoatId` on bind).
--- This is what makes the right column dynamic — every card click +
--- every server `oilStateUpdate` re-runs this, so the hero / bars /
--- action button always reflect the currently selected boat's *latest*
--- ownership + equipped state.
local function repaintRightColumn()
	if not rightCol then return end
	local boatId = selectedBoatId
	if typeof(boatId) ~= "string" or boatId == "" or not BoatCatalog.Boats[boatId] then
		boatId = equippedBoatId
		selectedBoatId = boatId
	end
	local def = BoatCatalog.GetBoat(boatId)
	local entry: FleetPanelPopulate.BoatEntry = {
		boatId = boatId,
		displayName = def.displayName,
		templateName = def.templateName,
		rarityDisplay = def.rarityDisplay,
		icon = def.icon,
		speedLevel = def.speedLevel,
		capacityLevel = def.capacityLevel,
	}
	local ctx = FleetPanelPopulate.ResolveContext(boatId, ownedBoatSet, equippedBoatId)
	FleetPanelPopulate.HydrateRightColumn(rightCol :: Frame, entry, ctx, equippedAccent)
end

local function repaintAllCards()
	for boatId, card in pairs(liveCards) do
		local def = BoatCatalog.GetBoat(boatId)
		local entry: FleetPanelPopulate.BoatEntry = {
			boatId = boatId,
			displayName = def.displayName,
			templateName = def.templateName,
			rarityDisplay = def.rarityDisplay,
			icon = def.icon,
			speedLevel = def.speedLevel,
			capacityLevel = def.capacityLevel,
		}
		local ctx = FleetPanelPopulate.ResolveContext(boatId, ownedBoatSet, equippedBoatId)
		FleetPanelPopulate.Apply(card, entry, ctx, equippedAccent)
	end
end

--- Get-or-create a `UIScale` child on the card so hover / selection
--- tweens can shrink-and-restore the card without fighting the authored
--- `Size` (which is owned by `UIGridLayout`'s `CellSize`).
local function ensureCardScale(card: GuiObject): UIScale
	local s = card:FindFirstChildOfClass("UIScale")
	if not s then
		s = Instance.new("UIScale")
		s.Scale = 1
		s.Parent = card
	end
	return s
end

--- Tween a single card to its target visual state based on the current
--- `selectedBoatId` + a passed-in `hovered` flag. Selection wins over
--- hover (a hovered+selected card stays depressed; a hovered-only card
--- lifts). Idempotent — safe to call repeatedly.
local function applyCardVisual(card: GuiObject, boatId: string, hovered: boolean)
	if not card:IsA("GuiObject") then return end
	local scale = ensureCardScale(card)
	local isSelected = (selectedBoatId == boatId)
	local targetBg: Color3
	local targetScale: number
	if isSelected then
		targetBg = CARD_BG_SELECTED
		targetScale = CARD_SELECTED_SCALE
	elseif hovered then
		targetBg = CARD_BG_HOVER
		targetScale = CARD_HOVER_SCALE
	else
		targetBg = CARD_BG_IDLE
		targetScale = 1.0
	end
	TweenService:Create(card, CARD_TWEEN, { BackgroundColor3 = targetBg }):Play()
	TweenService:Create(scale, CARD_TWEEN, { Scale = targetScale }):Play()
end

--- Re-tween every live card's selection state. Called whenever
--- `selectedBoatId` changes so the *previously* selected card pops back
--- up and the *new* selected card depresses, in one consistent pass.
--- Reads each card's current `FleetCardHovered` attribute so a card the
--- mouse is hovering over keeps its hover bg if it just lost selection.
local function repaintAllCardSelection()
	for boatId, card in pairs(liveCards) do
		applyCardVisual(card, boatId, card:GetAttribute(CARD_HOVER_ATTR) == true)
	end
end

--- Resolve the card's clickable target. Mirrors
--- `InventoryAuraGridController.getAuraCardHitButton` — the canonical
--- working pattern for the project's StarterGui card grids:
---   * If the card root itself is a `GuiButton` (the authored
---     `BoatCardTemplate` is now an `ImageButton`), wire clicks on it.
---   * Otherwise, fall back to the first descendant `ImageButton` /
---     `TextButton` so a future re-author that splits hit target from
---     visual root keeps working without touching this controller.
local function getCardHitButton(root: Instance): GuiButton?
	if root:IsA("GuiButton") then
		return root :: GuiButton
	end
	local img = root:FindFirstChildWhichIsA("ImageButton", true)
	if img then return img end
	local txt = root:FindFirstChildWhichIsA("TextButton", true)
	if txt then return txt end
	return nil
end

--- Card click → set this boat as the right-column selection. The card
--- itself never fires an equip / purchase remote anymore — that's the
--- right-column **action button**'s job. The card click is a pure
--- "preview this boat in detail" gesture, so the player can browse the
--- whole grid (owned, unowned, even placeholder tiers) without
--- accidentally equipping or initiating a Robux prompt.
---
--- Earlier revisions tried `ClickShell` overlays + `Active=true` +
--- `InputBegan` on a Frame root. Both fight the authored `UIListLayout`
--- inside `BoatCardTemplate` (overlay gets sized as a layout slot;
--- InputBegan is unreliable inside a `ScrollingFrame` that captures
--- drag-scroll input). The working sibling
--- `InventoryAuraGridController` instead authors the template root as
--- a `GuiButton` and wires `MouseButton1Click` on it — that's the
--- pattern we mirror here.
local function attachCardClick(card: Instance, boatId: string)
	-- Idempotent cleanup of the obsolete overlay so re-binds don't leave
	-- a dead instance behind that would steal layout slots.
	local stale = card:FindFirstChild("ClickShell")
	if stale then
		stale:Destroy()
	end
	local target = getCardHitButton(card)
	if not target then
		warn("[FleetPanel] BoatCardTemplate has no clickable GuiButton — re-author the template as an ImageButton (root) or add an inner hit ImageButton/TextButton.")
		return
	end
	table.insert(connections, target.MouseButton1Click:Connect(function()
		-- Selecting the same boat twice is a cheap no-op — repaint would
		-- redraw the identical right column. Skip to avoid the visual
		-- flicker of `HydrateRightColumn` swapping prototype frames in
		-- place even though nothing changed.
		if selectedBoatId == boatId then
			return
		end
		selectedBoatId = boatId
		repaintRightColumn()
		-- Re-tween every card so the previously selected one pops back
		-- up and the new one depresses in the same animation tick.
		repaintAllCardSelection()
	end))

	-- Hover feedback. We wire on the same hit button (the card root for
	-- the current `ImageButton` template). Stamp `FleetCardHovered`
	-- onto the card root so `applyCardVisual` can read the flag without
	-- threading state through every call site (e.g. the
	-- `repaintAllCardSelection` pass after a click reads it back to
	-- decide if a now-deselected hovered card stays in the hover bg).
	local cardObj = card :: GuiObject
	table.insert(connections, target.MouseEnter:Connect(function()
		cardObj:SetAttribute(CARD_HOVER_ATTR, true)
		applyCardVisual(cardObj, boatId, true)
	end))
	table.insert(connections, target.MouseLeave:Connect(function()
		cardObj:SetAttribute(CARD_HOVER_ATTR, false)
		applyCardVisual(cardObj, boatId, false)
	end))
end

--- Right-column action button click → execute the action that matches
--- the *currently selected* boat's state (which `HydrateRightColumn`
--- stamps onto the button as `State` / `BoatId` / `UnlockKind` /
--- `MonetizationItemId` attributes whenever the right column repaints).
--- "Equipped" is a no-op (visual only); "Equip" fires the equip remote;
--- "Buy" routes to the Robux prompt or the cash unlock remote based on
--- `UnlockKind`. Placeholder catalog entries (`Tier1Boat..Tier10Boat`)
--- render with a Buy button at design time, but the server rejects them
--- via `IsBoatPurchasable`, so we short-circuit the click here so the
--- panel doesn't fire a doomed remote.
local function attachActionButton(actionBtn: TextButton)
	table.insert(connections, actionBtn.Activated:Connect(function()
		local state = actionBtn:GetAttribute("State")
		local boatId = actionBtn:GetAttribute("BoatId")
		if typeof(boatId) ~= "string" or boatId == "" then return end
		local def = BoatCatalog.GetBoat(boatId)
		if def.placeholder then return end
		if state == "Equipped" then
			-- Player tapped the Equipped pill expecting Equip; nothing to
			-- send to the server (no state change), but a silent no-op
			-- left them confused. Surface the dedicated copy + deny sting
			-- so the click is acknowledged. Throttled implicitly by the
			-- single-shot `errorNotificationSeq` — repeat clicks just
			-- restart the toast, they don't pile up.
			UiSfx.playUiDenied()
			showErrorNotification("Already equipped — pick another ship to swap.", 3.0)
			return
		elseif state == "Equip" then
			fireEquip(boatId)
		elseif state == "Buy" then
			local kind = actionBtn:GetAttribute("UnlockKind")
			local itemId = actionBtn:GetAttribute("MonetizationItemId")
			firePurchase(
				boatId,
				if typeof(itemId) == "string" then itemId else nil,
				if typeof(kind) == "string" then kind else "starter"
			)
		end
	end))
end

local function sampleEquippedAccent(panel: Instance)
	-- Sample from the panel's authored gold stroke (`HeaderDivider` is the
	-- canonical gold accent in the live design). Fallback stays the
	-- module-default if the divider is missing.
	local divider = panel:FindFirstChild("HeaderDivider", true)
	if divider and divider:IsA("GuiObject") then
		equippedAccent = divider.BackgroundColor3
		return
	end
	local stroke = panel:FindFirstChild("UIStroke", true)
	if stroke and stroke:IsA("UIStroke") then
		equippedAccent = stroke.Color
	end
end

local function wireFleetPanel(screen: ScreenGui)
	disconnectAll()
	wiredScreen = screen

	-- The temporary design-time `FleetGridScrollMaintainer` LocalScript was
	-- the right shape for editor-time layout iteration but the controller
	-- now owns scroll maintenance; remove it on bind so the same logic
	-- doesn't run twice. Idempotent — also fine if the script was never
	-- created (post-cleanup builds).
	local panelRoot = screen:FindFirstChild("Canvas") and screen.Canvas:FindFirstChild("PanelHost")
	local panel = panelRoot and panelRoot:FindFirstChild("Panel")
	if not (panel and panel:IsA("Frame")) then
		warn("[FleetPanel] Panel not found under FleetPanelGui.Canvas.PanelHost — bind aborted.")
		return
	end
	local maintainer = panel:FindFirstChild("FleetGridScrollMaintainer", true)
	if maintainer and maintainer:IsA("LocalScript") then
		maintainer:Destroy()
	end

	sampleEquippedAccent(panel)

	-- Studio authors `ErrorNotification` somewhere under the panel
	-- (canonically `Canvas.PanelHost.ErrorNotification`) with `Visible = true`
	-- so the designer can position + restyle in Edit mode. We hide it on
	-- wire and only swap `.Text` at runtime — placement + look stay 1:1
	-- with the Studio authoring (matches `SellOilPanel`).
	errorNotificationLabel = findStudioErrorNotificationLabel(screen)
	if errorNotificationLabel then
		errorNotificationLabel.Visible = false
		errorNotificationLabel.TextTransparency = 0
	else
		warn(
			"[FleetPanel] No `ErrorNotification` TextLabel found under "
				.. screen:GetFullName()
				.. " — author one in Studio (recommended path: Canvas.PanelHost.ErrorNotification). Errors will be silent until added."
		)
	end

	local scroller = findFleetGrid(panel)
	if not scroller then
		warn("[FleetPanel] FleetGrid ScrollingFrame not found — bind aborted.")
		return
	end
	rightCol = findRightColumn(panel)

	local template = scroller:FindFirstChild(TEMPLATE_NAME)
	-- Accept either the legacy `Frame` root or the current `ImageButton`
	-- root (matches the working sample's `AuraInventoryCardTemplate`).
	if not (template and template:IsA("GuiObject")) then
		warn("[FleetPanel] BoatCardTemplate missing under FleetGrid — bind aborted.")
		return
	end
	-- Hide the template (keep it in tree as the prototype). All clones are
	-- visible; the template stays invisible so designers can still grab it
	-- in Studio without it duplicating the first card visually at runtime.
	(template :: GuiObject).Visible = false

	destroyOldClones(scroller)
	maintainScroll(scroller)

	pullSnapshot()
	-- Seed the right-column selection from the player's equipped boat so
	-- the panel opens already showing their current ship's hero card +
	-- bars + Equipped chip. Subsequent card clicks override this.
	selectedBoatId = equippedBoatId

	local boats = FleetPanelPopulate.SortedBoatList()
	for i, entry in ipairs(boats) do
		local clone = template:Clone()
		clone.Name = "BoatCard_" .. entry.boatId
		clone.Visible = true
		clone:SetAttribute(CATALOG_ATTR, true)
		clone.LayoutOrder = i
		clone.Parent = scroller
		local ctx = FleetPanelPopulate.ResolveContext(entry.boatId, ownedBoatSet, equippedBoatId)
		FleetPanelPopulate.Apply(clone, entry, ctx, equippedAccent)
		-- Authoring sets `BackgroundColor3` to a navy that matches
		-- `CARD_BG_IDLE`; force it explicitly so a designer-side gradient
		-- bake or stale Studio property doesn't drift the idle baseline
		-- (the tween loop then takes over from this known state).
		clone.BackgroundColor3 = CARD_BG_IDLE
		liveCards[entry.boatId] = clone
		attachCardClick(clone, entry.boatId)
	end
	-- Initial selection paint — the equipped boat starts as the
	-- selected one (`selectedBoatId = equippedBoatId` above), so its
	-- card opens already depressed to mirror the right column.
	repaintAllCardSelection()

	-- Cache + wire the right-column action button. Done after grid
	-- population so the action's catalog state matches the equipped boat
	-- the cards just stamped.
	if rightCol then
		local actionRow = (rightCol :: Frame):FindFirstChild("ActionRow")
		if actionRow then
			local btn = actionRow:FindFirstChild("ActionButton")
			if btn and btn:IsA("TextButton") then
				rightActionButton = btn
				attachActionButton(btn)
			end
			local pill = actionRow:FindFirstChild("CostPill")
			if pill and pill:IsA("GuiObject") then
				rightCostPill = pill
			end
		end
		repaintRightColumn()
	end

	-- Live updates from the server. Re-paint cards whenever ownership or
	-- equipped state changes; cheap because we only mutate visuals on
	-- existing clones.
	table.insert(connections, ClientRemotes.oilStateUpdate.OnClientEvent:Connect(function(snap: any)
		if typeof(snap) ~= "table" then return end
		local changed = false
		local newId = (snap :: any).equippedBoatId
		if typeof(newId) == "string" and BoatCatalog.Boats[newId] and not BoatCatalog.Boats[newId].placeholder then
			if newId ~= equippedBoatId then
				equippedBoatId = newId
				changed = true
			end
		end
		local newOwned = (snap :: any).ownedBoatIds
		if typeof(newOwned) == "table" then
			local nextOwned: { [string]: boolean } = { Tier1Boat = true }
			for boatId, isOwned in pairs(newOwned) do
				if typeof(boatId) == "string" and isOwned == true then
					nextOwned[boatId] = true
				end
			end
			-- Detect any add/remove (cheap diff against the previous map).
			for k, _ in pairs(nextOwned) do
				if not ownedBoatSet[k] then changed = true end
			end
			for k, _ in pairs(ownedBoatSet) do
				if not nextOwned[k] then changed = true end
			end
			ownedBoatSet = nextOwned
		end
		if changed then
			repaintAllCards()
			-- Right column re-renders against `selectedBoatId`, so the
			-- action button reflects the selected boat's *new* state
			-- (e.g. a Buy → Equip flip after a successful purchase, or
			-- an Equip → Equipped flip after the equip remote lands).
			repaintRightColumn()
			-- `repaintAllCards` re-applies static visuals (rarity stroke,
			-- icon, cost pill) but leaves BackgroundColor3 + UIScale
			-- alone so the hover/selection tween state survives the
			-- re-render. Re-affirm selection paint here in case
			-- `Apply` ever starts touching the bg in a future change.
			repaintAllCardSelection()
		end
	end))

	-- Cash-unlock receipts. `PlotResourceService._handleUnlockBoatRequest`
	-- tags every result with `action = "UnlockBoat"` (success or failure):
	--   * `ok = true`  → kaching SFX (the `oilStateUpdate` path above
	--     handles the BUY → OWNED card flip; we just mark the win audibly).
	--   * `ok = false` → deny SFX + red toast. Server `message` is preferred
	--     ("Need $X to unlock this boat." / "You already own this boat." /
	--     etc.) so cost copy stays in sync with `OilStateService:TryUnlockBoat`;
	--     fallback to the Studio-authored placeholder text only if the
	--     server omitted a message. `ERR_RATE_LIMIT` is suppressed (the
	--     player spam-clicked; surfacing the rate-limit copy in red would
	--     be more confusing than the click-eaten silence).
	-- Robux unlocks are NOT handled here — `MonetizationSfxBootstrap`
	-- already plays kaching globally on `monetizationResult` `code = "OK"`,
	-- and the Robux failure path doesn't ride `oilActionResult` at all.
	--- FTUE fleet-panel leg bridge: closing the modal while on
	--- `WaitDocksFleetPanel` + sub `ClosePanel` fires `FleetPanelClosed`,
	--- which the server validates + uses to advance to `WaitDocksHire`.
	--- Server re-checks step + sub-step (see
	--- `FtueService.OnFtueDocksProgress`) so this fire is harmless outside
	--- the FTUE. Hooked via `Enabled` change so it covers every close path
	--- (named close button, `HudPanelRouter.closeAll`, programmatic close).
	table.insert(connections, screen:GetPropertyChangedSignal("Enabled"):Connect(function()
		if screen.Enabled then
			return
		end
		local plr = Players.LocalPlayer
		if not plr then
			return
		end
		if plr:GetAttribute(Constants.FtueStepAttribute) ~= FtueConfig.Step.WaitDocksFleetPanel then
			return
		end
		if plr:GetAttribute(Constants.FtueDocksFleetPanelSubStepAttribute) ~= "ClosePanel" then
			return
		end
		ClientRemotes.requestFtueDocksProgress:FireServer("FleetPanelClosed")
	end))

	table.insert(connections, ClientRemotes.oilActionResult.OnClientEvent:Connect(function(payload: any)
		if typeof(payload) ~= "table" then return end
		if (payload :: any).action ~= "UnlockBoat" then return end
		if payload.ok == true then
			hideErrorNotification()
			UiSfx.playKaching()
			return
		end
		if payload.ok ~= false then return end
		local code = (payload :: any).code
		if code == "ERR_RATE_LIMIT" then return end
		UiSfx.playUiDenied()
		local msg = typeof((payload :: any).message) == "string" and (payload :: any).message
		if typeof(msg) ~= "string" or msg == "" then
			msg = if code == "ERR_NOT_ENOUGH_CASH"
				then "Not enough cash to afford!"
				elseif code == "ERR_ALREADY_OWNED" then "You already own this ship."
				else "Couldn't unlock this ship."
		end
		showErrorNotification(msg, 4.0)
	end))
end

function FleetPanel.bind(playerGui: PlayerGui): HudPanelTypes.HudPanelController?
	local ctrl = HudPanelBase.tryBind(playerGui, SCREEN_NAME)
	if not ctrl then
		return nil
	end
	if ctrl.ScreenGui == wiredScreen then
		return ctrl
	end
	wireFleetPanel(ctrl.ScreenGui)
	return ctrl
end

function FleetPanel.screenName(): string
	return SCREEN_NAME
end

--- Convenience for design-time previews. Bind + open the panel from the
--- LocalPlayer's PlayerGui without going through `HudPanelRouter` (the
--- panel is intentionally not yet registered there). Safe to call from a
--- LocalScript or the command bar in the local-test session.
function FleetPanel.openForTesting(): boolean
	local plr = Players.LocalPlayer
	if not plr then return false end
	local pg = plr:FindFirstChildOfClass("PlayerGui")
	if not pg then return false end
	local ctrl = FleetPanel.bind(pg)
	if not ctrl then return false end
	ctrl.Open()
	return true
end

return FleetPanel
