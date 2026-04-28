--!strict
-- Wires HUD modal-toggle buttons to `ScreenGui`s (exclusive group; second press closes).
-- Buttons live in authored regions of `HUD.Canvas` (see live Studio layout):
--   * `TopRow`         — OilPriceButton, StraitStatusButton
--   * `Canvas` direct  — StraitControlCta (aliases `StraitControlCTA`); Robux shop
--     opener is `CashStripPlus` inside `CashStrip` (aliases `RobuxShop` on Canvas)
--   * `Canvas.Buttons` — DailyButton, SettingsButton
-- Shop / ship oil / sell / manage-ship entrypoints are **not** required here when those
-- buttons were removed or moved (e.g. world `ProximityPrompt` + `openScreen`). `openScreen` lazy-binds
-- any `SCREEN_BIND` panel so prompts do not depend on this loop finishing first.
-- Retries until every **mapped** button is wired or attempts exhaust.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local getClientRemotes = require(script.Parent.Parent:WaitForChild("GetClientRemotes")) :: () -> any

--- Verbose HUD modal traces. On by default in Studio; set `HudModalDebug` = false on LocalPlayer
--- to silence. Outside Studio, set `HudModalDebug` = true on the client to trace the same lines.
local function hudModalDebugEnabled(): boolean
	local lp = Players.LocalPlayer
	if lp and lp:GetAttribute("HudModalDebug") == false then
		return false
	end
	if RunService:IsStudio() then
		return true
	end
	return lp ~= nil and lp:GetAttribute("HudModalDebug") == true
end

local function dbgModal(...)
	if not hudModalDebugEnabled() then
		return
	end
	print("[HudModalDebug]", ...)
end

local function formatHudGuiHitLine(go: GuiObject, index: number): string
	-- `Interactable` was added in a later GuiObject version; older instances
	-- raise on the read, so we wrap in pcall. The string we hand `%s` MUST
	-- be a string — Luau's `string.format` rejects raw booleans (which is
	-- what the previous `... and interactVal or "?"` expression would
	-- collapse to when the property read succeeded). `tostring` gives us
	-- "true" / "false" cleanly, with "?" as the fallback when the read
	-- raised or returned a non-boolean.
	local interactStr = "?"
	local interactableOk, interactVal = pcall(function()
		return (go :: any).Interactable
	end)
	if interactableOk and typeof(interactVal) == "boolean" then
		interactStr = tostring(interactVal)
	end
	return string.format(
		"[%d] %s %q | Visible=%s Active=%s Interactable=%s ZIndex=%d LayoutOrder=%d",
		index,
		go.ClassName,
		go.Name,
		tostring(go.Visible),
		tostring(go.Active),
		interactStr,
		go.ZIndex,
		go.LayoutOrder
	)
end

local function logGuiStackBelowCursor(playerGui: PlayerGui, tag: string, maxLen: number)
	local pos = UserInputService:GetMouseLocation()
	local ok, objs = pcall(function()
		return playerGui:GetGuiObjectsAtPosition(pos.X, pos.Y)
	end)
	if not ok or typeof(objs) ~= "table" then
		dbgModal(tag .. " GetGuiObjectsAtPosition failed:", tostring(objs))
		return
	end
	dbgModal(tag, string.format(" mouse=(%.0f,%.0f) hits=%d", pos.X, pos.Y, #objs))
	for i = 1, math.min(maxLen, #objs) do
		local o = objs[i]
		if o:IsA("GuiObject") then
			dbgModal(" ", formatHudGuiHitLine(o :: GuiObject, i))
		end
	end
end

local function describeModalHudButton(btn: GuiButton): string
	local sg = btn:FindFirstAncestorWhichIsA("ScreenGui")
	local sge = "?"
	local dor = "?"
	local sn = "?"
	if sg and sg:IsA("ScreenGui") then
		local s = sg :: ScreenGui
		sn = s.Name
		sge = tostring(s.Enabled)
		dor = tostring(s.DisplayOrder)
	end
	return string.format(
		"%s | Btn Visible=%s Active=%s | ScreenGui=%s Enabled=%s DisplayOrder=%s",
		btn:GetFullName(),
		tostring(btn.Visible),
		tostring(btn.Active),
		sn,
		sge,
		dor
	)
end

--- One-shot: every GuiButton under HUD whose name suggests store/Robux/cash "+" (screenshot STORE vs CashStrip wiring).
local function dbgDumpHudStoreRelatedButtons(hud: Instance)
	dbgModal("HudButton name scan under HUD (substrings store, robux, plus):")
	local lines: { string } = {}
	for _, d in ipairs(hud:GetDescendants()) do
		if d:IsA("GuiButton") then
			local nm = string.lower(d.Name)
			if
				string.find(nm, "store", 1, true)
				or string.find(nm, "robux", 1, true)
				or string.find(nm, "plus", 1, true)
			then
				table.insert(lines, describeModalHudButton(d))
			end
		end
	end
	table.sort(lines)
	for _, ln in ipairs(lines) do
		dbgModal(" ", ln)
	end
	dbgModal("Matching GuiButtons count:", #lines)
end

local ActiveManifestController = require(script.Parent.ActiveManifestController)
local DailyPanel = require(script.Parent.HudPanels.DailyPanel)
local EquipmentShopPanel = require(script.Parent.HudPanels.EquipmentShopPanel)
local FleetPanel = require(script.Parent.HudPanels.FleetPanel)
local OilPriceInfoPanel = require(script.Parent.HudPanels.OilPriceInfoPanel)
local RobuxShopPanel = require(script.Parent.HudPanels.RobuxShopPanel)
local SellOilPanel = require(script.Parent.HudPanels.SellOilPanel)
local ShipOilPanel = require(script.Parent.HudPanels.ShipOilPanel)
local StraitControlPanel = require(script.Parent.HudPanels.StraitControlPanel)
local SettingsPanel = require(script.Parent.HudPanels.SettingsPanel)
local StraitInfoPanel = require(script.Parent.HudPanels.StraitInfoPanel)
local HudMousePolicy = require(script.Parent.HudMousePolicy)
local HudPanelTypes = require(script.Parent.HudPanelTypes)
local HudTriggerHover = require(script.Parent.HudTriggerHover)

local STRAIT_CONTROL_CTA_ALIASES = { "StraitControlCta", "StraitControlCTA" }

-- Robux modal openers moved from Canvas root into `CashStrip` (Plus). Try the
-- new name first, then legacy top-level `RobuxShop`, so StarterGui mismatches warn once.
local ROBUX_SHOP_TRIGGER_ALIASES = { "CashStripPlus", "RobuxShop" }

-- Maps **HUD GuiButton.Name** → **target ScreenGui name**. `findHudModalButton`
-- searches `Canvas` direct children, then `Canvas.Buttons`, then `Canvas.TopRow`,
-- then a recursive HUD scan as a last resort.
-- Legacy TopRow / grid names (`ShopButton`, `ManageShipButton`, `ShipOilButton`, `SellOilButton`)
-- are intentionally omitted — open those modals from authored prompts / HUD v2.
local BUTTON_TO_SCREEN: { [string]: string } = {
	OilPriceButton = OilPriceInfoPanel.screenName(),
	StraitStatusButton = StraitInfoPanel.screenName(),
	StraitControlCta = StraitControlPanel.screenName(),
	DailyButton = DailyPanel.screenName(),
	SettingsButton = SettingsPanel.screenName(),
	RobuxShop = RobuxShopPanel.screenName(),
}

-- Buttons that should get the same `HudTriggerHover` lift as modal triggers but
-- don't open a `ScreenGui` here — typically because they fire something else
-- and that wiring lives elsewhere (e.g. `EarningsGamepassController` owns the
-- pulsing rainbow active-state chrome on `EarningsGamepass`, but the
-- *purchase prompt* still routes through the generic `ROBUX_PURCHASE_HUD_BUTTONS`
-- wiring below). Empty by default; add names here if a HUD button needs only
-- the lift treatment with no other behavior.
local HOVER_ONLY_BUTTON_NAMES: { string } = { "AutoShipButton" }

-- HUD buttons that fire `RequestPromptRobuxPurchase` directly (no modal).
-- Keys = `GuiButton.Name`, values = `MonetizationCatalog` item id. The wiring
-- pass below attaches Activated → fire prompt, plus the same `HudTriggerHover`
-- lift modal triggers get. Debounced per item id so spam-clicks don't multi-prompt.
--
-- `EarningsGamepass` is wired here even though `EarningsGamepassController`
-- attaches the active-state visuals on top — the controller listens to
-- `MonetizationResult` for ownership changes and never connects `Activated`,
-- so the click → prompt flow stays owned by this router. Also: the catalog
-- entry has `productId = 0` until the Roblox Creator Dashboard GamePass is
-- created; until then `MonetizationService` returns `ERR_PRODUCT_NOT_CONFIGURED`
-- and the click silently no-ops (handled below).
local ROBUX_PURCHASE_HUD_BUTTONS: { [string]: string } = {
	NukeDevProduct = "consumable.nuke_x1",
	EarningsGamepass = "gamepass.double_earnings",
}

local SCREEN_BIND: { [string]: (PlayerGui) -> HudPanelTypes.HudPanelController? } = {
	[OilPriceInfoPanel.screenName()] = OilPriceInfoPanel.bind,
	[StraitControlPanel.screenName()] = StraitControlPanel.bind,
	[StraitInfoPanel.screenName()] = StraitInfoPanel.bind,
	[EquipmentShopPanel.screenName()] = EquipmentShopPanel.bind,
	[ShipOilPanel.screenName()] = ShipOilPanel.bind,
	-- Fleet panel (`FleetPanelGui`) — single-modal replacement for the
	-- legacy `ShipManagementPanelGui` + `SelectShipPanelGui` split. Bound
	-- here so `HudPanelRouter.start()` calls `FleetPanel.bind()` once
	-- `PlayerGui` has the modal, which (a) runs `wireFleetPanel` so the
	-- catalog grid populates and the card-click router attaches, and (b)
	-- lets `HudPanelBase.bindScreenGui` wire the `CloseButton` via
	-- `ModalPanelShell.bindCloseControls`. Open from elsewhere via
	-- `HudPanelRouter.openScreen("FleetPanelGui")` — today the dockman
	-- `ManageShipPrompt.OpensPanel` attribute drives this through
	-- `ProximityPanelOpener`.
	[FleetPanel.screenName()] = FleetPanel.bind,
	[SettingsPanel.screenName()] = SettingsPanel.bind,
	[SellOilPanel.screenName()] = SellOilPanel.bind,
	[DailyPanel.screenName()] = DailyPanel.bind,
	[RobuxShopPanel.screenName()] = RobuxShopPanel.bind,
}

local HudPanelRouter = {}

local started = false

-- Module-scoped registry: filled from `start()` and lazily from `openScreen` when a `ScreenGui` appears later.
-- Exposed via `openScreen` / `closeAll` for non-HUD-button triggers (e.g. ProximityPrompts).
local controllersByScreen: { [string]: HudPanelTypes.HudPanelController? } = {}
local controllersList: { HudPanelTypes.HudPanelController } = {}

--- A cached controller is stale when its bound `ScreenGui` is no longer
--- parented to the live `PlayerGui` — this happens when the modal had
--- `ResetOnSpawn = true` and the player died: the engine destroys the old
--- clone and re-clones a fresh `ScreenGui` from `StarterGui`, but the
--- closures inside the controller (`Open` / `Close` / `IsOpen`) still point
--- at the destroyed instance. `Open()` then writes `Enabled = true` to a
--- dead instance and the panel never appears (repro: open Ship Management
--- via the dockman prompt after dying once). The fix is to detect the
--- orphan here and re-run the binder against the fresh `ScreenGui` instead
--- of returning the dead controller. Cheap (one parent check on each
--- `openScreen`) and keeps the cache when the screen is healthy.
local function isControllerStale(ctrl: HudPanelTypes.HudPanelController, playerGui: PlayerGui): boolean
	local sg = (ctrl :: any).ScreenGui
	if typeof(sg) ~= "Instance" then
		return true
	end
	return sg.Parent ~= playerGui
end

local function dropStaleController(ctrl: HudPanelTypes.HudPanelController, screenName: string)
	controllersByScreen[screenName] = nil
	for i, c in ipairs(controllersList) do
		if c == ctrl then
			table.remove(controllersList, i)
			break
		end
	end
	HudMousePolicy.UnregisterController(ctrl)
end

local function bindPanelForScreen(playerGui: PlayerGui, screenName: string): HudPanelTypes.HudPanelController?
	local existing = controllersByScreen[screenName]
	if existing then
		if not isControllerStale(existing, playerGui) then
			return existing
		end
		dropStaleController(existing, screenName)
	end
	local binder = SCREEN_BIND[screenName]
	if not binder then
		return nil
	end
	local ctrl = binder(playerGui)
	if ctrl then
		controllersByScreen[screenName] = ctrl
		table.insert(controllersList, ctrl)
		--- Mouse-unlock-while-open policy: see `HudMousePolicy.luau`. Without this any HUD modal
		--- opened from first-person leaves the cursor locked to camera-look so BUY / X are dead.
		HudMousePolicy.RegisterController(ctrl)
	end
	return ctrl
end

local function closeAllExceptCtrl(keep: HudPanelTypes.HudPanelController?)
	for _, c in ipairs(controllersList) do
		if c ~= keep then
			c.Close()
		end
	end
end

--- Conventional name for a "this control is gated / WIP" cover authored as a
--- child of a HUD button. Mirrors `ShipOilPanel.wireRunUpgradeCard1`'s rule:
--- as long as the overlay is parented to the button, treat the underlying
--- control as unavailable. Removing the overlay in Studio re-enables the
--- press path live (the in-handler check below re-evaluates each click).
local COMING_SOON_OVERLAY_NAME = "ComingSoonOverlay"

local function isComingSoonGated(btn: GuiButton): boolean
	return btn:FindFirstChild(COMING_SOON_OVERLAY_NAME) ~= nil
end

--- `CashStripPlus` may be authored as a sizing `Frame` with the real hit target as a child
--- `GuiButton`. `FindFirstChild` returns the Frame — convert to the clickable button.
local function coerceRobuxShopModalTrigger(raw: Instance?): GuiButton?
	if not raw then
		return nil
	end
	if raw:IsA("GuiButton") then
		return raw :: GuiButton
	end
	if raw:IsA("Frame") then
		-- Invisible Frames often ship `Active=true` and swallow hits before any child GuiButton receives them.
		(raw :: Frame).Active = false
		local direct = raw:FindFirstChildWhichIsA("GuiButton", false)
		if direct and direct:IsA("GuiButton") then
			return direct :: GuiButton
		end
		local deep = raw:FindFirstChildWhichIsA("GuiButton", true)
		if deep and deep:IsA("GuiButton") then
			return deep :: GuiButton
		end
	end
	return nil
end

local function passthroughDecorationsToTrigger(btn: GuiButton)
	for _, d in ipairs(btn:GetDescendants()) do
		if d:IsA("GuiObject") and not d:IsA("GuiButton") then
			-- Skip the coming-soon cover so it stays input-active and visually
			-- "owns" the button. Without this `passthrough` would set the
			-- overlay's `Active = false`, which is the opposite of what we
			-- want — even with the press handler skipped (see `wireTrigger`),
			-- a future `Active = true` button restoration would let clicks
			-- bleed straight through the cover otherwise.
			if d.Name == COMING_SOON_OVERLAY_NAME then
				continue
			end
			d.Active = false
		end
	end
end

local function expectedButtonCount(): number
	local n = 0
	for _ in pairs(BUTTON_TO_SCREEN) do
		n += 1
	end
	return n
end

function HudPanelRouter.start(playerGui: PlayerGui)
	if started then
		return
	end
	if RunService:IsStudio() then
		print("[Client] HudPanelRouter: start() — waiting for HUD + modal ScreenGuis (HUD buttons optional)…")
	end
	--- Idempotent — safe to call before any controllers are registered; the
	--- per-frame tick is a no-op until at least one panel reports `IsOpen() == true`.
	HudMousePolicy.Start()

	task.spawn(function()
		local needButtons = expectedButtonCount()
		local wiredButton: { [string]: boolean } = {}
		local warnedMissingButton: { [string]: boolean } = {}

		for attempt = 1, 120 do
			if started then
				return
			end
			local hud = playerGui:FindFirstChild("HUD")
			if not (hud and hud:IsA("ScreenGui")) then
				task.wait(0.5)
				continue
			end
			local canvas = hud:FindFirstChild("Canvas")
			-- We only require `Canvas` to exist. `TopRow` and `Buttons` are each looked up
			-- per-button in `findHudModalButton`; missing either is fine (e.g. some
			-- StarterGui presets ship without the right-side grid).
			if not (canvas and canvas:IsA("Frame")) then
				task.wait(0.5)
				continue
			end
			local topRow = canvas:FindFirstChild("TopRow")
			local buttonsFrame = canvas:FindFirstChild("Buttons")

			ActiveManifestController.start(playerGui)

			for screenName in pairs(SCREEN_BIND) do
				bindPanelForScreen(playerGui, screenName)
			end

			local closeAllExcept = closeAllExceptCtrl
			local byScreen = controllersByScreen

			local function wireTrigger(btn: GuiButton, screenName: string)
				-- Coming-soon gate: when the button has a `ComingSoonOverlay`
				-- child the press path stays disabled entirely (no click, no
				-- hover lift). Mirrors the ShipOilPanel run-upgrade-card
				-- convention so a single Studio author action (parent the
				-- overlay onto the button) is enough to disable the modal
				-- without touching code. Currently used for `DailyButton`;
				-- removing the overlay in Studio re-enables the wire on the
				-- next router retry tick (or live, via the in-handler check
				-- below if the overlay is re-added after we've already wired).
				if isComingSoonGated(btn) then
					btn.Active = false
					btn.AutoButtonColor = false
					dbgModal("wireTrigger SKIPPED (ComingSoonOverlay):", screenName, btn:GetFullName())
					return
				end
				-- Defensive: ensure the button itself receives input. Many StarterGui HUD
				-- buttons ship with `Active = false`, which lets any overlapping GuiObject
				-- (FTUE pointer, hotbar strip, popups) swallow the click before it reaches
				-- the trigger — manifests as "modal sometimes doesn't open".
				btn.Active = true
				btn.Selectable = true
				btn.Interactable = true
				passthroughDecorationsToTrigger(btn)
				dbgModal("wireTrigger CONNECT:", screenName, describeModalHudButton(btn))
				local armed = false
				local function onPress(inputKind: string)
					dbgModal(string.format(
						"modal press BEGIN kind=%s screen=%s target=%s",
						inputKind,
						screenName,
						btn:GetFullName()
					))
					if screenName == "RobuxShop" then
						logGuiStackBelowCursor(playerGui, "[RobuxShop] top GuiObjects under cursor @ handler]", 12)
					end
					-- Live coming-soon recheck: if the overlay was added to
					-- the button after wiring (Studio edit, runtime authoring
					-- pass), this short-circuits the press without requiring
					-- a router restart. Pair with the wire-time gate above so
					-- the overlay can be toggled either way and behavior
					-- tracks immediately.
					if isComingSoonGated(btn) then
						dbgModal("  SKIPPED overlay gate at handler time:", screenName)
						return
					end
					if armed then
						dbgModal("  SKIPPED armed debounce (duplicate Activated+M1?):", screenName)
						return
					end
					armed = true
					task.defer(function()
						armed = false
					end)
					-- Always resolve the **current** controller for `screenName`.
					-- `bindPanelForScreen` rebinds when a `ResetOnSpawn = true`
					-- death wiped the prior `ScreenGui` — capturing `ctrl` in
					-- this closure once would silently keep operating on the
					-- destroyed instance and the press would no-op.
					local ctrl = bindPanelForScreen(playerGui, screenName)
					if not ctrl then
						dbgModal("  SKIPPED bindPanelForScreen(nil):", screenName, "Does PlayerGui have this ScreenGui?")
						return
					end
					if ctrl.IsOpen() then
						dbgModal("  CLOSE modal (already open):", screenName)
						ctrl.Close()
						return
					end
					dbgModal("  OPEN modal:", screenName)
					closeAllExcept(nil)
					ctrl.Open()
				end
				btn.Activated:Connect(function()
					onPress("Activated")
				end)
				btn.MouseButton1Click:Connect(function()
					onPress("MouseButton1Click")
				end)
				HudTriggerHover.attach(btn)
			end

			local function findHudModalButton(name: string): GuiButton?
				local names: { string }
				if name == "StraitControlCta" then
					names = STRAIT_CONTROL_CTA_ALIASES
				elseif name == "RobuxShop" then
					names = ROBUX_SHOP_TRIGGER_ALIASES
				else
					names = { name }
				end
				-- Search order:
				--   1. Direct child of `Canvas`  (e.g. `StraitControlCta`)
				--   2. `Canvas.Buttons`           (right-side grid: DailyButton, SettingsButton)
				--   3. `Canvas.TopRow`            (status bar: OilPriceButton, StraitStatusButton)
				--   4. Recursive `HUD` fallback   (anywhere else in the HUD)
				local roots: { Instance } = {}
				if canvas then table.insert(roots, canvas) end
				if buttonsFrame and buttonsFrame:IsA("GuiObject") then table.insert(roots, buttonsFrame) end
				if topRow and topRow:IsA("GuiObject") then table.insert(roots, topRow) end
				table.insert(roots, hud)
				for _, tryName in ipairs(names) do
					for i, root in ipairs(roots) do
						-- Direct child first when the root is `Canvas` so we don't recurse
						-- into `Buttons` / `TopRow` / etc. and grab the wrong one.
						local raw: Instance? = if i == 1 and root == canvas
							then root:FindFirstChild(tryName)
							else root:FindFirstChild(tryName, true)
						if not raw then
							continue
						end
						if name == "RobuxShop" then
							local robuxBtn = coerceRobuxShopModalTrigger(raw)
							if robuxBtn then
								dbgModal(
									"RobuxHudButton resolver:",
									string.format(
										"tryName=%q raw=%s -> clickTarget=%s",
										tryName,
										raw:GetFullName(),
										robuxBtn:GetFullName()
									)
								)
								return robuxBtn
							elseif hudModalDebugEnabled() then
								dbgModal(
									"RobuxHudButton resolver: SKIP (not a clickable GuiButton after coerce) raw=",
									raw:GetFullName(),
									raw.ClassName
								)
							end
						elseif raw:IsA("GuiButton") then
							return raw :: GuiButton
						end
					end
				end
				return nil
			end

			-- Hover-only decoration pass. Runs every retry tick so any button that
			-- streams in late still picks up the lift; `HudTriggerHover.attach`
			-- guards itself with the `HudTriggerHoverBound` attribute so re-calls
			-- are no-ops. We disable `AutoButtonColor` first so Roblox's built-in
			-- press-tint doesn't fight the hover `ImageColor3` darken tween.
			local function decorateHoverOnly(name: string)
				local roots: { Instance } = { canvas }
				if buttonsFrame and buttonsFrame:IsA("GuiObject") then
					table.insert(roots, buttonsFrame)
				end
				if topRow and topRow:IsA("GuiObject") then
					table.insert(roots, topRow)
				end
				for _, root in ipairs(roots) do
					for _, ch in ipairs(root:GetChildren()) do
						if ch.Name == name and ch:IsA("GuiButton") then
							local btn = ch :: GuiButton
							if btn:IsA("ImageButton") then
								(btn :: ImageButton).AutoButtonColor = false
							end
							HudTriggerHover.attach(btn)
						end
					end
				end
			end
			for _, name in ipairs(HOVER_ONLY_BUTTON_NAMES) do
				decorateHoverOnly(name)
			end

			-- Robux purchase HUD buttons: wire `Activated` → fire
			-- `RequestPromptRobuxPurchase` with the catalog item id. Idempotent
			-- via the `RobuxPurchaseWired` attribute so re-runs don't stack
			-- multiple click handlers on the same button. Lift hover applied
			-- the same way as modal triggers.
			local function wireRobuxButton(name: string, itemId: string)
				local roots: { Instance } = { canvas }
				if buttonsFrame and buttonsFrame:IsA("GuiObject") then
					table.insert(roots, buttonsFrame)
				end
				if topRow and topRow:IsA("GuiObject") then
					table.insert(roots, topRow)
				end
				for _, root in ipairs(roots) do
					for _, ch in ipairs(root:GetChildren()) do
						if ch.Name == name and ch:IsA("GuiButton") then
							local btn = ch :: GuiButton
							if btn:IsA("ImageButton") then
								(btn :: ImageButton).AutoButtonColor = false
							end
							HudTriggerHover.attach(btn)
							if btn:GetAttribute("RobuxPurchaseWired") ~= true then
								btn:SetAttribute("RobuxPurchaseWired", true)
								local lastFire = 0
								btn.Activated:Connect(function()
									local now = os.clock()
									if now - lastFire < 0.6 then
										return
									end
									lastFire = now
									local remotes = getClientRemotes()
									remotes.requestPromptRobuxPurchase:FireServer({ itemId = itemId })
								end)
							end
						end
					end
				end
			end
			for name, itemId in pairs(ROBUX_PURCHASE_HUD_BUTTONS) do
				wireRobuxButton(name, itemId)
			end

			for buttonName, screenName in pairs(BUTTON_TO_SCREEN) do
				if wiredButton[buttonName] then
					continue
				end

				-- Special case: RobuxShop has TWO authored triggers in the HUD
				-- and the player should be able to use either. The previous
				-- implementation called `findHudModalButton(buttonName)` which
				-- short-circuits on the first alias match — `CashStripPlus`
				-- always wins (deep-search hits it under `CashStrip`) and the
				-- legacy `Canvas.RobuxShop` STORE button never gets wired.
				-- Symptom the player sees: clicking the big STORE button does
				-- nothing and there's no hover lift. Fix: iterate every alias
				-- explicitly, wire each unique button we find, and dedupe via
				-- `seenButtons` so a coerce that resolves to the same instance
				-- doesn't double-bind.
				if buttonName == "RobuxShop" then
					local ctrl = byScreen[screenName]
					if not ctrl then
						continue
					end
					local wiredAny = false
					local seenButtons: { [GuiButton]: boolean } = {}
					for _, alias in ipairs(ROBUX_SHOP_TRIGGER_ALIASES) do
						-- Same search precedence as `findHudModalButton`:
						-- direct on Canvas, then Buttons, then TopRow, then a
						-- recursive HUD fallback.
						local raw: Instance? = canvas:FindFirstChild(alias)
						if not raw and buttonsFrame and buttonsFrame:IsA("GuiObject") then
							raw = buttonsFrame:FindFirstChild(alias, true)
						end
						if not raw and topRow and topRow:IsA("GuiObject") then
							raw = topRow:FindFirstChild(alias, true)
						end
						if not raw then
							raw = hud:FindFirstChild(alias, true)
						end
						if raw then
							local btn = coerceRobuxShopModalTrigger(raw)
							if btn and not seenButtons[btn] then
								seenButtons[btn] = true
								wireTrigger(btn, screenName)
								wiredAny = true
								dbgModal("RobuxHud wired alias:", alias, "->", btn:GetFullName())
							end
						end
					end
					if wiredAny then
						wiredButton[buttonName] = true
					elseif not warnedMissingButton[buttonName] then
						warnedMissingButton[buttonName] = true
						warn(
							"[Client] HudPanelRouter: no HUD button matched any RobuxShop alias",
							table.concat(ROBUX_SHOP_TRIGGER_ALIASES, " / "),
							"(modal still openable via openScreen). Skipping wire."
						)
					end
					continue
				end

				local btn = findHudModalButton(buttonName)
				local ctrl = byScreen[screenName]
				if not (btn and btn:IsA("GuiButton")) then
					if not warnedMissingButton[buttonName] then
						warnedMissingButton[buttonName] = true
						warn(
							"[Client] HudPanelRouter: no HUD button named",
							buttonName,
							"(modal still openable via ProximityPrompt / openScreen). Skipping wire."
						)
					end
					continue
				end
				if not ctrl then
					continue
				end
				-- `ctrl` is only used here as a "panel exists" gate so we
				-- don't wire a button before its `ScreenGui` has streamed in.
				-- The press handler re-resolves the live controller per click
				-- via `bindPanelForScreen` so death-time `ResetOnSpawn` rebinds
				-- are picked up automatically.
				wireTrigger(btn, screenName)
				wiredButton[buttonName] = true
			end

			local wired = 0
			for _ in pairs(wiredButton) do
				wired += 1
			end

			if wired >= needButtons then
				started = true
				if hudModalDebugEnabled() then
					dbgDumpHudStoreRelatedButtons(hud)
				end
				if RunService:IsStudio() then
					print("[Client] HudPanelRouter: HUD modal buttons wired (" .. tostring(wired) .. "/" .. tostring(needButtons) .. ").")
				end
				return
			end

			if RunService:IsStudio() and (attempt == 1 or attempt % 10 == 0) then
				local missingPanels: { string } = {}
				for sn in pairs(SCREEN_BIND) do
					if not byScreen[sn] then
						table.insert(missingPanels, sn)
					end
				end
				table.sort(missingPanels)
				print(
					"[Client] HudPanelRouter: HUD buttons",
					wired,
					"/",
					needButtons,
					" | ScreenGuis not yet in PlayerGui:",
					#missingPanels > 0 and table.concat(missingPanels, ", ") or "(none)"
				)
			end

			task.wait(0.5)
		end

		started = true
		local wired = 0
		for _ in pairs(wiredButton) do
			wired += 1
		end
		warn(
			"[Client] HudPanelRouter: timed out; wired ",
			wired,
			"/",
			needButtons,
			" — add missing StarterGui ScreenGuis to PlayerGui (Rojo does not sync StarterGui)."
		)
	end)
end

--- Toggle a modal panel by its `ScreenGui.Name` (matches `<Panel>.screenName()` strings),
--- closing all other panels first. Returns true when a panel was toggled, false when the
--- name is unknown or the `ScreenGui` is not in `PlayerGui` yet.
function HudPanelRouter.openScreen(screenName: string): boolean
	local plr = Players.LocalPlayer
	if not plr then
		return false
	end
	local playerGui = plr:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return false
	end
	local ctrl = bindPanelForScreen(playerGui, screenName)
	if not ctrl then
		return false
	end
	if ctrl.IsOpen() then
		ctrl.Close()
		return true
	end
	closeAllExceptCtrl(nil)
	ctrl.Open()
	return true
end

function HudPanelRouter.closeAll()
	closeAllExceptCtrl(nil)
end

return HudPanelRouter
