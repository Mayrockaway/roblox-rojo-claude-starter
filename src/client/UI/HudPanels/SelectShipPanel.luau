--!strict
-- Select ship modal (`StarterGui.SelectShipPanelGui` → `PlayerGui`).
-- Grid + clone flow mirrors `InventoryAuraGridController` + `InventoryAuraPopulate`:
-- resolve `ScrollingFrame` + template, destroy prior catalog clones by attribute, clone → parent → Apply.
--
-- Robux gating (added with `MonetizationCatalog`): unowned skins render their
-- `LockedPill` and the card's main button fires `RequestPromptRobuxPurchase`
-- instead of `RequestSetSelectedBoat`. Server `MonetizationService` claims
-- `MarketplaceService.ProcessReceipt`, calls `OilStateService:GrantShipSkin`,
-- and pushes a fresh snapshot so this panel re-paints into the owned state.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ShipSkinCatalog = require(Shared:WaitForChild("Config"):WaitForChild("ShipSkinCatalog"))

local HudPanelBase = require(script.Parent.Parent.HudPanelBase)
local HudPanelTypes = require(script.Parent.Parent.HudPanelTypes)
local SelectShipPopulate = require(script.Parent.SelectShipPopulate)
local getClientRemotes = require(script.Parent.Parent.Parent:WaitForChild("GetClientRemotes")) :: () -> any
local ClientRemotes = getClientRemotes()

local SCREEN_NAME = "SelectShipPanelGui"
local TEMPLATE_NAME = "ShipSelectCardTemplate"
local CATALOG_ATTR = "ShipSelectCatalogCard"

local GOLD_STROKE = Color3.fromRGB(212, 178, 122)
local DEFAULT_STROKE = Color3.fromRGB(55, 95, 110)

local SCROLLER_NAMES = { "ShipGridScroll", "ShipScroller", "ShipGrid", "ShipSelectScroll" }

local SelectShipPanel = {}

local wiredScreen: ScreenGui? = nil
local selectController: HudPanelTypes.HudPanelController? = nil
local connections: { RBXScriptConnection } = {}
local cardSelectButtons: { GuiButton } = {}
local selectedShipSkinId = "DefaultTanker"
--- Snapshot of `state.ownedShipSkinIds` from the most recent oil state push.
--- Re-rendered whenever it changes so a Robux purchase landed by
--- `MonetizationService` flips the affected card from locked → owned without
--- the player having to close + reopen the panel.
local ownedSkinSet: { [string]: boolean } = { DefaultTanker = true }
local lastSelectFire = 0.0
local lastPromptFire = 0.0
local liveCards: { Frame } = {}
local errorNotificationLabel: TextLabel? = nil
local errorNotificationSeq = 0

local function sortedSkinList(): { SelectShipPopulate.SkinEntry }
	local list: { SelectShipPopulate.SkinEntry } = {}
	for skinId, def in pairs(ShipSkinCatalog.Skins) do
		table.insert(list, {
			skinId = skinId,
			displayName = def.displayName,
			templateName = def.templateName,
			rarityDisplay = def.rarityDisplay,
		})
	end
	table.sort(list, function(a, b)
		return a.displayName < b.displayName
	end)
	return list
end

local function findTemplatesFolder(screen: ScreenGui): Instance?
	local direct = screen:FindFirstChild("Templates")
	if direct then
		return direct
	end
	return screen:FindFirstChild("Templates", true)
end

local function resolveTemplateRoot(templatesFolder: Instance?): GuiObject?
	if not templatesFolder then
		return nil
	end
	local tpl = templatesFolder:FindFirstChild(TEMPLATE_NAME) or templatesFolder:FindFirstChild(TEMPLATE_NAME, true)
	if tpl and tpl:IsA("GuiObject") then
		return tpl
	end
	return nil
end

local function findShipScroller(screen: ScreenGui, templatesFolder: Instance?): ScrollingFrame?
	local function eligible(s: Instance?): boolean
		if not s or not s:IsA("ScrollingFrame") then
			return false
		end
		if templatesFolder and s:IsDescendantOf(templatesFolder) then
			return false
		end
		return true
	end

	for _, name in ipairs(SCROLLER_NAMES) do
		local s = screen:FindFirstChild(name, true)
		if eligible(s) then
			return s :: ScrollingFrame
		end
	end
	for _, d in screen:GetDescendants() do
		if eligible(d) then
			for _, name in ipairs(SCROLLER_NAMES) do
				if d.Name == name then
					return d :: ScrollingFrame
				end
			end
		end
	end
	return nil
end

local function restoreLegacyShipGridHost(scroll: ScrollingFrame)
	local legacyHost = scroll:FindFirstChild("ShipGridContent")
	if not (legacyHost and legacyHost:IsA("Frame")) then
		return
	end
	local lay = legacyHost:FindFirstChild("ShipGridLayout")
	if lay and lay:IsA("UIGridLayout") then
		lay.Parent = scroll
	end
	legacyHost:Destroy()
end

local function destroyGridCards(scroller: ScrollingFrame)
	for _, ch in ipairs(scroller:GetChildren()) do
		if ch:GetAttribute(CATALOG_ATTR) == true then
			ch:Destroy()
		elseif ch:IsA("Frame") and string.sub(ch.Name, 1, #"ShipCard_") == "ShipCard_" then
			ch:Destroy()
		end
	end
	local row = scroller:FindFirstChild("ShipSelectCardRow")
	if row then
		row:Destroy()
	end
end

local function findSelectButton(card: Instance): GuiButton?
	local b = card:FindFirstChild("SelectShipCardButton", true)
	if b and b:IsA("GuiButton") then
		return b
	end
	b = card:FindFirstChild("SelectShipButton", true)
	if b and b:IsA("GuiButton") then
		return b
	end
	return nil
end

local function setCardSelectedVisual(card: Frame, selected: boolean)
	local stroke = card:FindFirstChild("CardStroke", true)
	if not (stroke and stroke:IsA("UIStroke")) then
		return
	end
	if card:GetAttribute("_CardStrokeDefaultT") == nil then
		card:SetAttribute("_CardStrokeDefaultT", stroke.Thickness)
	end
	local baseThickness = tonumber(card:GetAttribute("_CardStrokeDefaultT")) or 2
	stroke.Color = if selected then GOLD_STROKE else DEFAULT_STROKE
	stroke.Thickness = if selected then math.max(baseThickness + 3.5, 5) else baseThickness
end

local function refreshAllCardSelection(cards: { Frame })
	for _, card in ipairs(cards) do
		local id = card:GetAttribute("SkinId")
		if typeof(id) == "string" then
			setCardSelectedVisual(card, id == selectedShipSkinId)
		end
	end
end

--- Re-Apply ownership state on every card without rebuilding clones. Cheap
--- enough to call on every `oilStateUpdate` so a Robux purchase flips the
--- affected card from locked → owned in place.
local function refreshAllCardOwnership()
	for _, card in ipairs(liveCards) do
		local skinId = card:GetAttribute("SkinId")
		if typeof(skinId) == "string" then
			local entry = {
				skinId = skinId,
				displayName = ShipSkinCatalog.GetSkin(skinId).displayName,
				templateName = ShipSkinCatalog.GetSkin(skinId).templateName,
				rarityDisplay = ShipSkinCatalog.GetSkin(skinId).rarityDisplay,
			}
			SelectShipPopulate.Apply(card, entry, SelectShipPopulate.ResolveContext(skinId, ownedSkinSet))
		end
	end
end

local function findStudioErrorNotificationLabel(screen: ScreenGui): TextLabel?
	-- Mirrors the lookup pattern in ShipOilPanel / SellOilPanel: studio
	-- authors a `TextLabel` named `ErrorNotification` somewhere under the
	-- ScreenGui; we never fabricate one at runtime so the toast styling
	-- and position stay 1:1 with the authored placeholder.
	local found = screen:FindFirstChild("ErrorNotification", true)
	if found and found:IsA("TextLabel") then
		return found
	end
	return nil
end

local function hideErrorNotification()
	if errorNotificationLabel then
		errorNotificationLabel.Visible = false
	end
end

local function showErrorNotification(message: string)
	if not errorNotificationLabel then
		warn("[SelectShipPanel] No Studio-authored ErrorNotification label — not surfacing message: " .. tostring(message))
		return
	end
	errorNotificationSeq += 1
	local mySeq = errorNotificationSeq
	errorNotificationLabel.Text = message
	errorNotificationLabel.Visible = true
	task.delay(2.6, function()
		if mySeq == errorNotificationSeq and errorNotificationLabel then
			errorNotificationLabel.Visible = false
		end
	end)
end

local function disconnectAll()
	for _, c in ipairs(connections) do
		c:Disconnect()
	end
	table.clear(connections)
	table.clear(cardSelectButtons)
	table.clear(liveCards)
	wiredScreen = nil
	selectController = nil
	errorNotificationLabel = nil
	errorNotificationSeq = 0
end

local function wireSelectShip(_playerGui: PlayerGui, screen: ScreenGui, ctrl: HudPanelTypes.HudPanelController)
	disconnectAll()
	wiredScreen = screen
	selectController = ctrl
	errorNotificationLabel = findStudioErrorNotificationLabel(screen)
	hideErrorNotification()

	local templatesFolder = findTemplatesFolder(screen)
	local template = resolveTemplateRoot(templatesFolder)
	local scroller = findShipScroller(screen, templatesFolder)
	if not (template and scroller) then
		return
	end

	restoreLegacyShipGridHost(scroller)
	destroyGridCards(scroller)

	-- `ShipSelectCardTemplate` lives under `ShipTemplatesHost` (same slot as this scroller) so its
	-- `Size` scale resolves against the same rect as grid cells; keep `UIGridLayout.CellSize` in sync.
	local grid = scroller:FindFirstChildOfClass("UIGridLayout")
	if grid and template and template:IsA("GuiObject") then
		grid.CellSize = template.Size
	end

	-- Pull the latest snapshot up-front so the very first paint already
	-- shows lock state correctly (instead of flashing all-owned for a frame).
	local okSnap, pack = pcall(function()
		return ClientRemotes.requestOilSnapshot:InvokeServer()
	end)
	if okSnap and typeof(pack) == "table" then
		local st = (pack :: any).state
		if typeof(st) == "table" then
			if typeof(st.shipSkinId) == "string" and ShipSkinCatalog.Skins[st.shipSkinId] then
				selectedShipSkinId = st.shipSkinId
			end
			if typeof(st.ownedShipSkinIds) == "table" then
				ownedSkinSet = { DefaultTanker = true }
				for skinId, owned in pairs(st.ownedShipSkinIds) do
					if typeof(skinId) == "string" and owned == true then
						ownedSkinSet[skinId] = true
					end
				end
			end
		end
	end

	local skins = sortedSkinList()
	local cards: { Frame } = {}

	for i, entry in ipairs(skins) do
		if not SelectShipPopulate.ValidateSkin(entry) then
			continue
		end
		local clone = template:Clone()
		clone.Name = "ShipCard_" .. entry.skinId
		clone.Visible = true
		clone:SetAttribute(CATALOG_ATTR, true)
		clone:SetAttribute("SkinId", entry.skinId)
		clone.LayoutOrder = i
		clone.Parent = scroller
		local ctx = SelectShipPopulate.ResolveContext(entry.skinId, ownedSkinSet)
		local okApply, errApply = pcall(function()
			SelectShipPopulate.Apply(clone, entry, ctx)
		end)
		if not okApply then
			warn("[SelectShipPanel] Skipped ship card (populate error):", entry.skinId, errApply)
			clone:Destroy()
			continue
		end
		if clone:IsA("Frame") then
			table.insert(cards, clone)
			table.insert(liveCards, clone)
		end
		local selBtn = findSelectButton(clone)
		if selBtn then
			selBtn.Visible = true
			table.insert(cardSelectButtons, selBtn)
			local skinId = entry.skinId
			-- Single click handler that branches on `ShipCardOwned` (set by
			-- `SelectShipPopulate.Apply`) so the same button doubles as
			-- "Equip" when owned and "Prompt Robux purchase" when locked.
			-- Re-reading the attribute on click (not closing over `ctx.owned`)
			-- means a `MonetizationResult` push that re-renders ownership in
			-- place will immediately switch this button's behavior.
			table.insert(connections, selBtn.Activated:Connect(function()
				local ownedNow = clone:GetAttribute("ShipCardOwned") == true
				if ownedNow then
					local now = os.clock()
					if now - lastSelectFire < 0.35 then
						return
					end
					lastSelectFire = now
					ClientRemotes.requestSetSelectedBoat:FireServer({ skinId = skinId })
					return
				end
				-- Locked → request Robux purchase prompt via server. We never
				-- call `MarketplaceService` from the client so the catalog
				-- stays the only source of `productId` truth.
				local itemId = clone:GetAttribute("MonetizationItemId")
				if typeof(itemId) ~= "string" or itemId == "" then
					showErrorNotification("This ship isn't on sale yet.")
					return
				end
				local now = os.clock()
				if now - lastPromptFire < 0.6 then
					return
				end
				lastPromptFire = now
				ClientRemotes.requestPromptRobuxPurchase:FireServer({ itemId = itemId })
			end))
		end
	end

	local counter = screen:FindFirstChild("ShipsOwnedCounterLabel", true)
	if counter and counter:IsA("TextLabel") then
		local ownedCount = 0
		for _, e in ipairs(skins) do
			if ownedSkinSet[e.skinId] then
				ownedCount += 1
			end
		end
		counter.Text = string.format("%d / %d skins", ownedCount, #skins)
	end

	table.insert(connections, ClientRemotes.oilStateUpdate.OnClientEvent:Connect(function(snap: any)
		if typeof(snap) ~= "table" then
			return
		end
		local id = (snap :: any).shipSkinId
		if typeof(id) == "string" and ShipSkinCatalog.Skins[id] then
			selectedShipSkinId = id
		end
		local newOwned = (snap :: any).ownedShipSkinIds
		if typeof(newOwned) == "table" then
			local prev = ownedSkinSet
			local nextOwned: { [string]: boolean } = { DefaultTanker = true }
			local changed = false
			for skinId, owned in pairs(newOwned) do
				if typeof(skinId) == "string" and owned == true then
					nextOwned[skinId] = true
					if not prev[skinId] then
						changed = true
					end
				end
			end
			-- Detect removals too (e.g. dev wipe).
			for skinId, _ in pairs(prev) do
				if not nextOwned[skinId] then
					changed = true
				end
			end
			ownedSkinSet = nextOwned
			if changed then
				refreshAllCardOwnership()
				if counter and counter:IsA("TextLabel") then
					local ownedCount = 0
					for _, e in ipairs(skins) do
						if ownedSkinSet[e.skinId] then
							ownedCount += 1
						end
					end
					counter.Text = string.format("%d / %d skins", ownedCount, #skins)
				end
			end
		end
		refreshAllCardSelection(cards)
	end))

	-- Server → client receipt outcomes for prompts opened via this panel.
	-- Only surface failures here; success arrives implicitly as a fresh
	-- ownership push that re-renders the card via `oilStateUpdate`. The
	-- "kaching" SFX on `payload.code == "OK"` is fired globally by
	-- `MonetizationSfxBootstrap.client.luau` so future Robux-prompting panels
	-- get it for free without each one re-implementing the gating.
	table.insert(connections, ClientRemotes.monetizationResult.OnClientEvent:Connect(function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		if payload.ok == true then
			return
		end
		local code = payload.code
		if code == "ERR_PRODUCT_NOT_CONFIGURED" then
			showErrorNotification("Coming soon — not on sale yet.")
		elseif code == "ERR_MONETIZATION_DISABLED" then
			showErrorNotification("Robux purchases are temporarily disabled.")
		elseif code == "ERR_PROMPT_FAILED" then
			showErrorNotification("Couldn't open the Roblox prompt — try again.")
		elseif code == "ERR_UNKNOWN_ITEM" then
			showErrorNotification("That item isn't on the menu.")
		end
	end))

	-- `RequestSetSelectedBoat` doesn't send `OilActionResult`, but
	-- `RequestSetShipSkin` does (`PlotResourceService:_sendResult`). If the
	-- player's UI ever fires that path against a locked skin we surface the
	-- friendly error instead of a silent no-op.
	table.insert(connections, ClientRemotes.oilActionResult.OnClientEvent:Connect(function(payload: any)
		if typeof(payload) ~= "table" or payload.ok == true then
			return
		end
		if payload.code == "ERR_NOT_OWNED" then
			showErrorNotification("You don't own this ship yet.")
		end
	end))

	refreshAllCardSelection(cards)
end

function SelectShipPanel.bind(playerGui: PlayerGui): HudPanelTypes.HudPanelController?
	local ctrl = HudPanelBase.tryBind(playerGui, SCREEN_NAME)
	if not ctrl then
		return nil
	end
	if wiredScreen == ctrl.ScreenGui and selectController then
		return selectController
	end
	wireSelectShip(playerGui, ctrl.ScreenGui, ctrl)
	return ctrl
end

function SelectShipPanel.screenName(): string
	return SCREEN_NAME
end

return SelectShipPanel
