--!strict
-- Robux strait control shell (`StarterGui.StraitControlPanelGui` → `PlayerGui`).
-- Open from **`StraitControlCta`** (`HudPanelRouter`; accepts `StraitControlCTA` spelling); `ModalPanelShell` wires **`CloseButton`** (any casing).
--
-- Wires the two body CTAs to the monetization pipeline:
--   * `OpenStraitCta`  → fires `RequestPromptRobuxPurchase` with `consumable.strait_open_2min`
--   * `CloseStraitCta` → fires `RequestPromptRobuxPurchase` with `consumable.strait_close_2min`
-- Server-side handlers are registered in `MonetizationService:Init` and apply
-- the force-state via `StraitStateService:ForceStateForDuration`. The price
-- subtitle is repainted from `MonetizationCatalog.robuxPrice` so the displayed
-- amount stays in sync with the catalog without hard-coded numbers in Studio.
--
-- Failure codes from `MonetizationResult` are warned to the console; the
-- success "kaching" SFX is fired globally by `MonetizationSfxBootstrap.client.luau`.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MonetizationCatalog = require(Shared:WaitForChild("Config"):WaitForChild("MonetizationCatalog"))

local HudPanelBase = require(script.Parent.Parent.HudPanelBase)
local HudPanelTypes = require(script.Parent.Parent.HudPanelTypes)
local getClientRemotes = require(script.Parent.Parent.Parent:WaitForChild("GetClientRemotes")) :: () -> any

local SCREEN_NAME = "StraitControlPanelGui"

--- CTA button name -> MonetizationCatalog item id. Keep aligned with the
--- Studio layout under `Canvas.PanelHost.Panel.Body`.
local CTA_TO_ITEM_ID: { [string]: string } = {
	OpenStraitCta = "consumable.strait_open_2min",
	CloseStraitCta = "consumable.strait_close_2min",
}

local StraitControlPanel = {}

local wiredScreen: ScreenGui? = nil
local connections: { RBXScriptConnection } = {}
local lastFireByItemId: { [string]: number } = {}

local function disconnectAll()
	for _, c in ipairs(connections) do
		c:Disconnect()
	end
	table.clear(connections)
	table.clear(lastFireByItemId)
	wiredScreen = nil
end

local function findBodyContainer(screen: ScreenGui): Instance?
	-- Canonical authored path; recursive fallback so a small Studio reorg
	-- (extra wrapper Frame) doesn't silently break wiring.
	local canvas = screen:FindFirstChild("Canvas")
	local panelHost = canvas and canvas:FindFirstChild("PanelHost")
	local panel = panelHost and panelHost:FindFirstChild("Panel")
	local body = panel and panel:FindFirstChild("Body")
	if body then
		return body
	end
	return screen:FindFirstChild("Body", true)
end

local function findPriceLabel(cta: ImageButton): TextLabel?
	-- Authored child name is "Text" (see Studio dump). Use direct child first;
	-- fall back to first descendant text label so a future rename still binds.
	local direct = cta:FindFirstChild("Text")
	if direct and direct:IsA("TextLabel") then
		return direct
	end
	for _, d in ipairs(cta:GetDescendants()) do
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

local function repaintPrice(cta: ImageButton, itemId: string)
	local label = findPriceLabel(cta)
	if not label then
		return
	end
	local price = priceForItemId(itemId)
	if typeof(price) ~= "number" then
		return
	end
	local current = label.Text or ""
	local nextPrice = string.format("R$%d", price)
	if string.find(current, "R%$%d+") then
		-- Replace only the price substring so descriptive copy ("Open the
		-- Strait — R$99") survives the swap when the catalog price changes.
		local rebuilt = string.gsub(current, "R%$%d+", nextPrice)
		if rebuilt ~= current then
			label.Text = rebuilt
		end
	elseif string.find(current:lower(), "buy") or string.find(current:lower(), "robux") then
		-- Fallback for older labels that say "Buy" / "Robux" but don't yet
		-- include a numeric price suffix — overwrite with the bare price tag.
		label.Text = nextPrice
	end
	-- Otherwise the label is purely descriptive (no price affordance) — leave
	-- it alone rather than inject an unexpected R$ tag.
end

local function wireCtas(_playerGui: PlayerGui, screen: ScreenGui)
	disconnectAll()
	wiredScreen = screen

	local body = findBodyContainer(screen)
	if not body then
		warn("[StraitControlPanel] Body container not found under " .. screen:GetFullName() .. " — CTAs will not be wired.")
		return
	end

	local remotes = getClientRemotes()

	for ctaName, itemId in pairs(CTA_TO_ITEM_ID) do
		local cta = body:FindFirstChild(ctaName)
		if not (cta and cta:IsA("ImageButton")) then
			warn(string.format("[StraitControlPanel] %s not found or not an ImageButton — skipping.", ctaName))
			continue
		end
		local btn = cta :: ImageButton
		-- Idempotent: clicks were dropped silently if Studio author left these
		-- inert. Flipping every bind is fine.
		btn.Active = true
		btn.AutoButtonColor = true

		repaintPrice(btn, itemId)

		table.insert(connections, btn.Activated:Connect(function()
			local now = os.clock()
			local last = lastFireByItemId[itemId] or 0
			if now - last < 0.6 then
				return
			end
			lastFireByItemId[itemId] = now
			remotes.requestPromptRobuxPurchase:FireServer({ itemId = itemId })
		end))
	end

	-- Surface failure codes to the console (no toast — matches RobuxShopPanel pattern).
	table.insert(connections, remotes.monetizationResult.OnClientEvent:Connect(function(payload: any)
		if typeof(payload) ~= "table" or payload.ok == true then
			return
		end
		local itemId = tostring((payload :: any).itemId or "?")
		if itemId ~= "consumable.strait_open_2min" and itemId ~= "consumable.strait_close_2min" then
			return
		end
		local code = tostring(payload.code)
		if code == "ERR_PRODUCT_NOT_CONFIGURED" then
			warn(string.format("[StraitControlPanel] %s — DevProduct id is 0 in MonetizationCatalog. Set the real productId from the Creator Dashboard.", itemId))
		elseif code == "ERR_MONETIZATION_DISABLED" then
			warn(string.format("[StraitControlPanel] %s — MonetizationCatalog.Enabled is false; toggle it on to allow purchases.", itemId))
		elseif code == "ERR_PROMPT_FAILED" then
			warn(string.format("[StraitControlPanel] %s — MarketplaceService prompt failed; user may retry.", itemId))
		elseif code == "ERR_UNKNOWN_ITEM" then
			warn(string.format("[StraitControlPanel] %s — itemId not found in MonetizationCatalog.", itemId))
		end
	end))
end

function StraitControlPanel.bind(playerGui: PlayerGui): HudPanelTypes.HudPanelController?
	local ctrl = HudPanelBase.tryBind(playerGui, SCREEN_NAME)
	if not ctrl then
		return nil
	end
	if wiredScreen ~= ctrl.ScreenGui then
		wireCtas(playerGui, ctrl.ScreenGui)
	end
	return ctrl
end

function StraitControlPanel.screenName(): string
	return SCREEN_NAME
end

return StraitControlPanel
