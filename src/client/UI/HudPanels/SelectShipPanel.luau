--!strict
-- Select ship modal (`StarterGui.SelectShipPanelGui` → `PlayerGui`).
-- Grid + clone flow mirrors `InventoryAuraGridController` + `InventoryAuraPopulate`:
-- resolve `ScrollingFrame` + template, destroy prior catalog clones by attribute, clone → parent → Apply.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ShipSkinCatalog = require(Shared:WaitForChild("Config"):WaitForChild("ShipSkinCatalog"))
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))

local HudPanelBase = require(script.Parent.Parent.HudPanelBase)
local HudPanelTypes = require(script.Parent.Parent.HudPanelTypes)
local SelectShipPopulate = require(script.Parent.SelectShipPopulate)

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
local requestSetSelectedBoat: RemoteEvent? = nil
local lastSelectFire = 0.0

local function remotesFolder(): Folder
	return Shared:WaitForChild("Remotes") :: Folder
end

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

local function disconnectAll()
	for _, c in ipairs(connections) do
		c:Disconnect()
	end
	table.clear(connections)
	table.clear(cardSelectButtons)
	requestSetSelectedBoat = nil
	wiredScreen = nil
	selectController = nil
end

local function wireSelectShip(_playerGui: PlayerGui, screen: ScreenGui, ctrl: HudPanelTypes.HudPanelController)
	disconnectAll()
	wiredScreen = screen
	selectController = ctrl

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
		local okApply, errApply = pcall(function()
			SelectShipPopulate.Apply(clone, entry)
		end)
		if not okApply then
			warn("[SelectShipPanel] Skipped ship card (populate error):", entry.skinId, errApply)
			clone:Destroy()
			continue
		end
		if clone:IsA("Frame") then
			table.insert(cards, clone)
		end
		local selBtn = findSelectButton(clone)
		if selBtn then
			selBtn.Visible = true
			table.insert(cardSelectButtons, selBtn)
			local skinId = entry.skinId
			table.insert(connections, selBtn.Activated:Connect(function()
				local now = os.clock()
				if now - lastSelectFire < 0.35 then
					return
				end
				lastSelectFire = now
				local ev = requestSetSelectedBoat
				if ev then
					ev:FireServer({ skinId = skinId })
				end
			end))
		end
	end

	local counter = screen:FindFirstChild("ShipsOwnedCounterLabel", true)
	if counter and counter:IsA("TextLabel") then
		counter.Text = string.format("%d / %d skins", #skins, #skins)
	end

	local rf = remotesFolder()
	requestSetSelectedBoat = rf:WaitForChild(RemoteNames.RequestSetSelectedBoat) :: RemoteEvent

	local snapFn = rf:FindFirstChild(RemoteNames.RequestOilSnapshot)
	if snapFn and snapFn:IsA("RemoteFunction") then
		local okSnap, pack = pcall(function()
			return (snapFn :: RemoteFunction):InvokeServer()
		end)
		if okSnap and typeof(pack) == "table" then
			local st = (pack :: any).state
			if typeof(st) == "table" and typeof(st.shipSkinId) == "string" and ShipSkinCatalog.Skins[st.shipSkinId] then
				selectedShipSkinId = st.shipSkinId
			end
		end
	end

	local oilUp = rf:WaitForChild(RemoteNames.OilStateUpdate) :: RemoteEvent
	table.insert(connections, oilUp.OnClientEvent:Connect(function(snap: any)
		if typeof(snap) ~= "table" then
			return
		end
		local id = (snap :: any).shipSkinId
		if typeof(id) == "string" and ShipSkinCatalog.Skins[id] then
			selectedShipSkinId = id
			refreshAllCardSelection(cards)
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
