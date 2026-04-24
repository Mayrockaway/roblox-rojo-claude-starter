--!strict
-- Robux shop modal (`StarterGui.RobuxShop` → `PlayerGui.RobuxShop`). Authored in Studio;
-- this controller exposes Open/Close/IsOpen so `HudPanelRouter` includes it in the
-- modal-exclusivity group.
--
-- It also wires the three ship cards under `Ships` (`Ship1`..`Ship3`), the Patriot
-- under `Ships2` (`Ship1` only), the Featured starter pack (`Featured.Tab.EquipBest`),
-- and the Early Supporter bundle (`Featured2.Tab.EquipBest`):
--   * Each `Template/Buy` ImageButton fires `RequestPromptRobuxPurchase` with the
--     matching `MonetizationCatalog` item id (`ship.pirateship`, `ship.ducky`, …). The
--     server's `MonetizationService` opens the Roblox prompt
--     and on receipt grants the boat via `OilStateService:GrantBoat`.
--   * The Buy pill text is repainted from the catalog's `robuxPrice` so the displayed
--     price stays in sync with `MonetizationCatalog.SHIP_PLACEHOLDER_PRICE` without
--     hard-coding numbers in Studio.
--   * `oilStateUpdate.ownedBoatIds` flips owned cards to "OWNED" so the player
--     can't accidentally re-prompt for a ship they already own. (Server is
--     idempotent via `OK_ALREADY_OWNED`, but suppressing the prompt is better UX.)
--   * Failure codes from `MonetizationResult` are warned to the console; the success
--     "kaching" SFX is fired globally by `MonetizationSfxBootstrap.client.luau`.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BoatCatalog = require(Shared:WaitForChild("Config"):WaitForChild("BoatCatalog"))
local MonetizationCatalog = require(Shared:WaitForChild("Config"):WaitForChild("MonetizationCatalog"))

local HudPanelBase = require(script.Parent.Parent.HudPanelBase)
local HudPanelTypes = require(script.Parent.Parent.HudPanelTypes)
local getClientRemotes = require(script.Parent.Parent.Parent:WaitForChild("GetClientRemotes")) :: () -> any

local SCREEN_NAME = "RobuxShop"

--- UI slot name -> MonetizationCatalog item id. Keep in sync with the Studio
--- card layout under `…Main.Container.Ships` (`buildShipItem` uses
--- `ship.` .. lower(boatId)) — legacy `ship.ship4skin` ids are invalid.
--- Order: Ship1=PirateShip, Ship2=Ducky, Ship3=Moby.
local SHIP_SLOT_TO_ITEM_ID: { [string]: string } = {
	Ship1 = "ship.pirateship",
	Ship2 = "ship.ducky",
	Ship3 = "ship.moby",
}

--- `Ships2` in the same Main container: single premium hull (The Patriot).
local SHIP2_SHIP1_ITEM_ID = "ship.americaneagleboat"

--- The Featured starter pack card lives at
--- `Canvas.Container.Main.Container.Featured.Tab.EquipBest` (Studio author
--- named the Buy button "EquipBest" — kept as-is so the wiring matches the
--- live tree). The card grants a Bundle (Pirate ship + $5k cash + 2x Glizzy
--- Grinder drills) and is marketed as a one-time-only purchase
--- (`MonetizationCatalog.starter_pack.oneTimePurchase = true`):
---   * Server flips `OilStateService.purchasedOneTimeItemIds[id] = true`
---     on the verified receipt.
---   * The client snapshot's `purchasedOneTimeItemIds` set drives
---     `repaintFeatured()` below to hide the entire `Featured` frame.
---   * Click handler short-circuits in case a stale UI state slips through;
---     the server's `_handlePromptRequest` rejects with `ERR_ALREADY_PURCHASED`
---     anyway, so a double-charge is impossible even if hide fails.
local STARTER_PACK_ITEM_ID = "starter_pack"
--- `Featured2.Tab.EquipBest` — Early Supporter Bundle (see `MonetizationCatalog`).
local EARLY_SUPPORTER_ITEM_ID = "early_supporter_bundle"

local RobuxShopPanel = {}

local wiredScreen: ScreenGui? = nil
local connections: { RBXScriptConnection } = {}
local ownedBoatSet: { [string]: boolean } = { Tier1Boat = true }
local purchasedOneTimeSet: { [string]: boolean } = {}
local lastPromptFireByItemId: { [string]: number } = {}
local cardRefs: { { slotName: string, itemId: string, buy: ImageButton, label: TextLabel? } } = {}
--- Captured during `wireRobuxShop` so `repaintFeatured` can flip Visible on
--- the whole Featured row without re-walking the tree on every snapshot.
local featuredRoot: Instance? = nil
local featuredBuyRef: ImageButton? = nil
--- Same contract as `Featured` / `starter_pack`, for `Featured2` (Early Supporter).
local featured2Root: Instance? = nil
local featured2BuyRef: ImageButton? = nil

local function disconnectAll()
	for _, c in ipairs(connections) do
		c:Disconnect()
	end
	table.clear(connections)
	table.clear(cardRefs)
	table.clear(lastPromptFireByItemId)
	table.clear(purchasedOneTimeSet)
	featuredRoot = nil
	featuredBuyRef = nil
	featured2Root = nil
	featured2BuyRef = nil
	wiredScreen = nil
end

local function findMainInnerContainer(screen: ScreenGui): Instance?
	local canvas = screen:FindFirstChild("Canvas")
	local container = canvas and canvas:FindFirstChild("Container")
	local main = container and container:FindFirstChild("Main")
	return main and main:FindFirstChild("Container")
end

local function findShipsContainer(screen: ScreenGui, folderName: string): Instance?
	-- Prefer the canonical authored path; fall back to recursive lookup so a
	-- minor Studio reorg (e.g. extra wrapper Frame) doesn't silently break wiring.
	local inner = findMainInnerContainer(screen)
	local ships = inner and inner:FindFirstChild(folderName)
	if ships then
		return ships
	end
	return screen:FindFirstChild(folderName, true)
end

--- Paints the list icon on a shop card to match `BoatCatalog` (list + hero
--- icons are the same asset; larger frame in Studio = larger preview).
local function applyShipSlotIconFromBoatId(slot: Instance, boatId: string)
	local def = BoatCatalog.GetBoat(boatId)
	local url = def and def.icon
	if typeof(url) ~= "string" or url == "" then
		return
	end
	local template = slot:FindFirstChild("Template")
	if template and template:IsA("Instance") then
		local icon = template:FindFirstChild("Icon")
		if icon and icon:IsA("ImageLabel") then
			icon.Image = url
			icon.ScaleType = Enum.ScaleType.Fit
			return
		end
	end
	local any = slot:FindFirstChild("Icon", true)
	if any and any:IsA("ImageLabel") then
		any.Image = url
		any.ScaleType = Enum.ScaleType.Fit
	end
end

local function findBuyLabel(buy: ImageButton): TextLabel?
	for _, d in ipairs(buy:GetDescendants()) do
		if d:IsA("TextLabel") then
			return d
		end
	end
	return nil
end

local function priceForItemId(itemId: string): number?
	local item = MonetizationCatalog.GetItem(itemId)
	if not item then
		return nil
	end
	return item.robuxPrice
end

local function boatIdForItemId(itemId: string): string?
	local item = MonetizationCatalog.GetItem(itemId)
	if not item or item.grant.kind ~= "Ship" then
		return nil
	end
	return item.grant.boatId
end

local function repaintCard(card: { slotName: string, itemId: string, buy: ImageButton, label: TextLabel? })
	local boatId = boatIdForItemId(card.itemId)
	local owned = boatId ~= nil and ownedBoatSet[boatId] == true
	card.buy:SetAttribute("Owned", owned)

	local label = card.label
	if label then
		if owned then
			label.Text = "OWNED"
		else
			local price = priceForItemId(card.itemId)
			if typeof(price) == "number" then
				label.Text = string.format("R$%d", price)
			end
		end
	end
end

--- Hide the entire Featured row when the player has already bought the
--- one-time bundle, otherwise show it. We toggle `Visible` on the
--- `Featured` Frame itself (not just the Buy button) because the artist
--- intent is "this card disappears, the panel reflows around it" — UIList
--- layout siblings collapse the empty slot automatically. The Buy button
--- is also disabled defensively so a still-visible click during a UI
--- reflow race can't fire `requestPromptRobuxPurchase`.
local function repaintFeatured()
	local owned = purchasedOneTimeSet[STARTER_PACK_ITEM_ID] == true
	if featuredRoot and (featuredRoot:IsA("GuiObject")) then
		(featuredRoot :: GuiObject).Visible = not owned
	end
	if featuredBuyRef then
		featuredBuyRef.Active = not owned
		featuredBuyRef.AutoButtonColor = not owned
	end
end

local function repaintFeatured2()
	local owned = purchasedOneTimeSet[EARLY_SUPPORTER_ITEM_ID] == true
	if featured2Root and featured2Root:IsA("GuiObject") then
		(featured2Root :: GuiObject).Visible = not owned
	end
	if featured2BuyRef then
		featured2BuyRef.Active = not owned
		featured2BuyRef.AutoButtonColor = not owned
	end
end

local function repaintAllCards()
	for _, card in ipairs(cardRefs) do
		repaintCard(card)
	end
	repaintFeatured()
	repaintFeatured2()
end

local function readOwnedBoats(st: any): { [string]: boolean }
	local nextOwned: { [string]: boolean } = { Tier1Boat = true }
	local newOwned = (st :: any).ownedBoatIds
	if typeof(newOwned) == "table" then
		for boatId, isOwned in pairs(newOwned) do
			if typeof(boatId) == "string" and isOwned == true then
				nextOwned[boatId] = true
			end
		end
	end
	return nextOwned
end

local function readPurchasedOneTime(st: any): { [string]: boolean }
	local out: { [string]: boolean } = {}
	local raw = (st :: any).purchasedOneTimeItemIds
	if typeof(raw) == "table" then
		for itemId, isPurchased in pairs(raw) do
			if typeof(itemId) == "string" and isPurchased == true then
				out[itemId] = true
			end
		end
	end
	return out
end

local function snapshotInitialOwnership(remotes: any)
	local ok, pack = pcall(function()
		return remotes.requestOilSnapshot:InvokeServer()
	end)
	if not ok or typeof(pack) ~= "table" then
		return
	end
	local st = (pack :: any).state
	if typeof(st) ~= "table" then
		return
	end
	ownedBoatSet = readOwnedBoats(st)
	purchasedOneTimeSet = readPurchasedOneTime(st)
end

local function wireRobuxShop(_playerGui: PlayerGui, screen: ScreenGui)
	disconnectAll()
	wiredScreen = screen

	local ships = findShipsContainer(screen, "Ships")
	if not ships then
		warn("[RobuxShopPanel] Ships container not found under " .. screen:GetFullName() .. " — Buy buttons will not be wired.")
		return
	end

	local remotes = getClientRemotes()

	for slotName, itemId in pairs(SHIP_SLOT_TO_ITEM_ID) do
		local slot = ships:FindFirstChild(slotName)
		local template = slot and slot:FindFirstChild("Template")
		local buy = template and template:FindFirstChild("Buy")
		if not (buy and buy:IsA("ImageButton")) then
			warn(string.format("[RobuxShopPanel] %s/Template/Buy not found or not an ImageButton — skipping.", slotName))
			continue
		end
		local imgBuy = buy :: ImageButton
		-- Studio author had `Active = false` on these; clicks are dropped silently
		-- without this. Idempotent — flipping every bind is fine.
		imgBuy.Active = true
		imgBuy.AutoButtonColor = true

		local label = findBuyLabel(imgBuy)
		local card = { slotName = slotName, itemId = itemId, buy = imgBuy, label = label }
		table.insert(cardRefs, card)

		table.insert(connections, imgBuy.Activated:Connect(function()
			if imgBuy:GetAttribute("Owned") == true then
				return
			end
			local now = os.clock()
			local last = lastPromptFireByItemId[itemId] or 0
			if now - last < 0.6 then
				return
			end
			lastPromptFireByItemId[itemId] = now
			remotes.requestPromptRobuxPurchase:FireServer({ itemId = itemId })
		end))
	end

	-- Ships2: The Patriot (`AmericanEagleBoat`) — `Ships2.Ship1.Template.Buy`
	local ships2 = findShipsContainer(screen, "Ships2")
	if ships2 then
		local slot = ships2:FindFirstChild("Ship1")
		if slot then
			applyShipSlotIconFromBoatId(slot, "AmericanEagleBoat")
		end
		local template = slot and slot:FindFirstChild("Template")
		local buy2 = template and template:FindFirstChild("Buy")
		if buy2 and buy2:IsA("ImageButton") then
			local img2 = buy2 :: ImageButton
			img2.Active = true
			img2.AutoButtonColor = true
			local label2 = findBuyLabel(img2)
			local card2 = { slotName = "Ships2_Ship1", itemId = SHIP2_SHIP1_ITEM_ID, buy = img2, label = label2 }
			table.insert(cardRefs, card2)
			table.insert(connections, img2.Activated:Connect(function()
				if img2:GetAttribute("Owned") == true then
					return
				end
				local now = os.clock()
				local last = lastPromptFireByItemId[SHIP2_SHIP1_ITEM_ID] or 0
				if now - last < 0.6 then
					return
				end
				lastPromptFireByItemId[SHIP2_SHIP1_ITEM_ID] = now
				remotes.requestPromptRobuxPurchase:FireServer({ itemId = SHIP2_SHIP1_ITEM_ID })
			end))
		else
			warn(
				"[RobuxShopPanel] Ships2/Ship1/Template/Buy not found or not an ImageButton under "
					.. screen:GetFullName()
					.. " — Patriot buy will not be wired."
			)
		end
	else
		warn(
			"[RobuxShopPanel] Ships2 container not found under "
				.. screen:GetFullName()
				.. " — Patriot row will not be wired."
		)
	end

	local function findTabEquipBest(featuredFolderName: string): (ImageButton?, Instance?)
		local inner = findMainInnerContainer(screen)
		local featured = inner and inner:FindFirstChild(featuredFolderName)
		local tab = featured and featured:FindFirstChild("Tab")
		local buy = tab and tab:FindFirstChild("EquipBest")
		if buy and buy:IsA("ImageButton") then
			return buy :: ImageButton, featured
		end
		return nil, nil
	end

	-- Featured starter pack — `Featured.Tab.EquipBest`
	local starterBuy, featRoot = findTabEquipBest("Featured")
	if starterBuy and featRoot then
		featuredBuyRef = starterBuy
		featuredRoot = featRoot
		starterBuy.Active = true
		starterBuy.AutoButtonColor = true
		local starterLabel = findBuyLabel(starterBuy)
		if starterLabel then
			local price = priceForItemId(STARTER_PACK_ITEM_ID)
			if typeof(price) == "number" then
				starterLabel.Text = string.format("R$%d", price)
			end
		end
		table.insert(connections, starterBuy.Activated:Connect(function()
			if purchasedOneTimeSet[STARTER_PACK_ITEM_ID] == true then
				return
			end
			local now = os.clock()
			local last = lastPromptFireByItemId[STARTER_PACK_ITEM_ID] or 0
			if now - last < 0.6 then
				return
			end
			lastPromptFireByItemId[STARTER_PACK_ITEM_ID] = now
			remotes.requestPromptRobuxPurchase:FireServer({ itemId = STARTER_PACK_ITEM_ID })
		end))
	else
		warn("[RobuxShopPanel] Featured/Tab/EquipBest not found under " .. screen:GetFullName() .. " — Starter Pack will not be wired.")
	end

	-- Featured2 — Early Supporter bundle (`Featured2.Tab.EquipBest`)
	local earlyBuy, f2root = findTabEquipBest("Featured2")
	if earlyBuy and f2root then
		featured2BuyRef = earlyBuy
		featured2Root = f2root
		earlyBuy.Active = true
		earlyBuy.AutoButtonColor = true
		local earlyLabel = findBuyLabel(earlyBuy)
		if earlyLabel then
			local price = priceForItemId(EARLY_SUPPORTER_ITEM_ID)
			if typeof(price) == "number" then
				earlyLabel.Text = string.format("R$%d", price)
			end
		end
		table.insert(connections, earlyBuy.Activated:Connect(function()
			if purchasedOneTimeSet[EARLY_SUPPORTER_ITEM_ID] == true then
				return
			end
			local now = os.clock()
			local last = lastPromptFireByItemId[EARLY_SUPPORTER_ITEM_ID] or 0
			if now - last < 0.6 then
				return
			end
			lastPromptFireByItemId[EARLY_SUPPORTER_ITEM_ID] = now
			remotes.requestPromptRobuxPurchase:FireServer({ itemId = EARLY_SUPPORTER_ITEM_ID })
		end))
	else
		warn(
			"[RobuxShopPanel] Featured2/Tab/EquipBest not found under "
				.. screen:GetFullName()
				.. " — Early Supporter bundle will not be wired."
		)
	end

	snapshotInitialOwnership(remotes)
	repaintAllCards()

	-- Re-paint when ownership changes server-side (e.g. successful Robux receipt
	-- → `OilStateService:GrantBoat` → push). Cheap; we only touch labels
	-- and the Featured row's Visible. We re-read both `ownedBoatIds` and
	-- `purchasedOneTimeItemIds` on every snapshot because either can change
	-- as a side-effect of a single receipt (e.g. Starter Pack flips both the
	-- Pirate ship + the one-time set in one push).
	table.insert(connections, remotes.oilStateUpdate.OnClientEvent:Connect(function(snap: any)
		if typeof(snap) ~= "table" then
			return
		end
		ownedBoatSet = readOwnedBoats(snap)
		purchasedOneTimeSet = readPurchasedOneTime(snap)
		repaintAllCards()
	end))

	-- Surface failure codes to the console. We do NOT toast in this panel because
	-- it has no Studio-authored ErrorNotification label; the global kaching SFX
	-- on success is owned by `MonetizationSfxBootstrap.client.luau`.
	table.insert(connections, remotes.monetizationResult.OnClientEvent:Connect(function(payload: any)
		if typeof(payload) ~= "table" or payload.ok == true then
			return
		end
		local code = tostring(payload.code)
		local itemId = tostring((payload :: any).itemId or "?")
		if code == "ERR_PRODUCT_NOT_CONFIGURED" then
			warn(string.format("[RobuxShopPanel] %s — DevProduct id is 0 in MonetizationCatalog. Set the real productId from the Creator Dashboard.", itemId))
		elseif code == "ERR_MONETIZATION_DISABLED" then
			warn(string.format("[RobuxShopPanel] %s — MonetizationCatalog.Enabled is false; toggle it on to allow purchases.", itemId))
		elseif code == "ERR_PROMPT_FAILED" then
			warn(string.format("[RobuxShopPanel] %s — MarketplaceService prompt failed; user may retry.", itemId))
		elseif code == "ERR_UNKNOWN_ITEM" then
			warn(string.format("[RobuxShopPanel] %s — itemId not found in MonetizationCatalog. Check SHIP_SLOT_TO_ITEM_ID mapping.", itemId))
		elseif code == "ERR_ALREADY_PURCHASED" then
			-- Snapshot was stale (e.g. clicked between receipt-grant and
			-- the OilStateUpdate landing). Pull a fresh snapshot to flip
			-- the Featured row off without waiting for the next push.
			task.spawn(function()
				snapshotInitialOwnership(remotes)
				repaintAllCards()
			end)
		end
	end))
end

function RobuxShopPanel.bind(playerGui: PlayerGui): HudPanelTypes.HudPanelController?
	local ctrl = HudPanelBase.tryBind(playerGui, SCREEN_NAME)
	if not ctrl then
		return nil
	end
	if wiredScreen ~= ctrl.ScreenGui then
		wireRobuxShop(playerGui, ctrl.ScreenGui)
	end
	return ctrl
end

function RobuxShopPanel.screenName(): string
	return SCREEN_NAME
end

return RobuxShopPanel
