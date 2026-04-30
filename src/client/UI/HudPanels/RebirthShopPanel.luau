--!strict
-- Rebirth shop modal (`StarterGui.RebirthShopPanelGui` → `PlayerGui`).
-- Opened by the HeavenShop Angel ProximityPrompt via `ProximityPanelOpener`
-- (`OpensPanel = "RebirthShopPanelGui"`). No HUD button — world-prompt only.
--
-- On open: fetches a `{ tokens, drills, bonusTotals }` snapshot from the
-- server (`RequestRebirthShopSnapshot`), hydrates the boost row, balance
-- chip, and card prices from `RebirthShopConfig`, then default-selects Drill
-- and paints the right column. Tokens + drills also live on player
-- attributes (`Constants.Rebirth(Tokens|Drills)Attribute`) — the balance
-- chip listens to those for live updates after a purchase confirmation
-- without needing a re-fetch.
--
-- Buy click → `RequestRebirthShopPurchase`. Server replies on
-- `OilActionResult` with `action = "RebirthShopPurchase"`; on `ok = false`
-- (today: `ERR_INSUFFICIENT_TOKENS`, `ERR_BAD_ITEM`, `ERR_NOT_AVAILABLE`)
-- we surface the message via the panel-local `ErrorNotification` label
-- (same authoring contract as `ShipOilPanel`) and play `UiSfx.playUiDenied`.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local RebirthShopConfig = require(Shared:WaitForChild("Config"):WaitForChild("RebirthShopConfig"))

local HudPanelBase = require(script.Parent.Parent.HudPanelBase)
local HudPanelTypes = require(script.Parent.Parent.HudPanelTypes)
local getClientRemotes = require(script.Parent.Parent.Parent:WaitForChild("GetClientRemotes")) :: () -> any
local UiSfx = require(script.Parent.Parent.Parent:WaitForChild("UiSfx")) :: {
	playKaching: () -> (),
	playUiDenied: () -> (),
}

local SCREEN_NAME = "RebirthShopPanelGui"
local PURCHASE_DEBOUNCE_SECONDS = 0.35
local ERROR_NOTIFICATION_HOLD_SECONDS = 2.5

local function formatBoostAmount(amount: number): string
	local whole = math.round(amount)
	if math.abs(amount - whole) < 0.001 then
		return tostring(whole)
	end
	return string.format("%.1f", amount)
end

-- Boost row card name → bonusTotals key + display formatter.
local BOOST_ROW_FORMATTERS: { [string]: (any) -> string } = {
	ShipSpeedBoost = function(bonusTotals)
		return string.format("+%s%%", formatBoostAmount(bonusTotals.shipSpeedPct or 0))
	end,
	WarehouseBoost = function(bonusTotals)
		return string.format("+%s%%", formatBoostAmount(bonusTotals.warehouseCapacityPct or 0))
	end,
	EarningsBoost = function(bonusTotals)
		return string.format("+%s%%", formatBoostAmount(bonusTotals.goldEarnPct or 0))
	end,
	LuckBoost = function(bonusTotals)
		return string.format("+%s%%", formatBoostAmount(bonusTotals.luckPct or 0))
	end,
}

-- Card hover + press animations. Adds a private `UIScale` child and tweens
-- between rest / hover / press states. Skips `UIStroke` entirely so it can't
-- fight `SelectionStroke` (which the panel drives manually for selection
-- state). Idempotent via the bound attribute.
local HOVER_SCALE = 1.05
local PRESS_SCALE = 0.96
local REST_SCALE = 1.0
local HOVER_PRESS_TWEEN = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function attachHoverPress(btn: GuiButton)
	if btn:GetAttribute("RebirthShopHoverPressBound") == true then
		return
	end
	btn:SetAttribute("RebirthShopHoverPressBound", true)
	local existing = btn:FindFirstChild("RebirthShopHoverScale")
	if existing and not existing:IsA("UIScale") then
		existing:Destroy()
		existing = nil
	end
	local scale: UIScale
	if existing then
		scale = existing :: UIScale
	else
		scale = Instance.new("UIScale")
		scale.Name = "RebirthShopHoverScale"
		scale.Scale = REST_SCALE
		scale.Parent = btn
	end

	local hovering = false
	local pressing = false

	local function tweenTo(target: number)
		TweenService:Create(scale, HOVER_PRESS_TWEEN, { Scale = target }):Play()
	end

	btn.MouseEnter:Connect(function()
		hovering = true
		if not pressing then
			tweenTo(HOVER_SCALE)
		end
	end)
	btn.MouseLeave:Connect(function()
		hovering = false
		if not pressing then
			tweenTo(REST_SCALE)
		end
	end)
	btn.MouseButton1Down:Connect(function()
		pressing = true
		tweenTo(PRESS_SCALE)
	end)
	btn.MouseButton1Up:Connect(function()
		pressing = false
		tweenTo(if hovering then HOVER_SCALE else REST_SCALE)
	end)
end

-- SelectionStroke styling: read DrillCard's stroke as the "selected" style and
-- any other card's as the "rest" style — keeps the visual definition in
-- Studio. Card-click then tweens between the two (Color3 / Thickness /
-- Transparency). Returns nil if either stroke is missing.
type StrokeStyle = { color: Color3, thickness: number, transparency: number }
local STROKE_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function readStrokeStyle(stroke: UIStroke?): StrokeStyle?
	if not stroke then
		return nil
	end
	return {
		color = stroke.Color,
		thickness = stroke.Thickness,
		transparency = stroke.Transparency,
	}
end

local function applyStrokeStyle(stroke: UIStroke?, style: StrokeStyle?)
	if not stroke or not style then
		return
	end
	TweenService:Create(stroke, STROKE_TWEEN, {
		Color = style.color,
		Thickness = style.thickness,
		Transparency = style.transparency,
	}):Play()
end

-- Studio-authored ErrorNotification label (matches the `ShipOilPanel` pattern
-- — same name + same Text/Visible/TextTransparency-only mutation contract).
local ERROR_NOTIFICATION_NAME = "ErrorNotification"

local function findErrorNotificationLabel(screen: ScreenGui): TextLabel?
	local found = screen:FindFirstChild(ERROR_NOTIFICATION_NAME, true)
	if found and found:IsA("TextLabel") then
		return found
	end
	return nil
end

local RebirthShopPanel = {}

function RebirthShopPanel.bind(playerGui: PlayerGui): HudPanelTypes.HudPanelController?
	local ctrl = HudPanelBase.tryBind(playerGui, SCREEN_NAME)
	if not ctrl then
		return nil
	end

	local screen = ctrl.ScreenGui
	local ClientRemotes = getClientRemotes()

	-- Resolve all the hydration anchors up front. Missing nodes are warned
	-- once but don't crash the bind — Studio authoring may legitimately omit
	-- some labels during in-progress redesigns and we'd rather degrade
	-- gracefully than blow up the panel open.
	local function findOrWarn(path: { string }): Instance?
		local cursor: Instance? = screen
		for _, segment in ipairs(path) do
			if not cursor then return nil end
			cursor = cursor:FindFirstChild(segment, true)
		end
		if not cursor then
			warn(string.format(
				"[RebirthShopPanel] missing %s under %s",
				table.concat(path, "."),
				screen:GetFullName()
			))
		end
		return cursor
	end

	local balanceLabel = findOrWarn({ "BalanceChip", "BalanceLabel" }) :: TextLabel?
	local heroIcon = findOrWarn({ "RightColumn", "Hero", "HeroIcon" }) :: TextLabel?
	local detailTitle = findOrWarn({ "RightColumn", "DetailTitle" }) :: TextLabel?
	local detailDescription = findOrWarn({ "RightColumn", "DetailDescription" }) :: TextLabel?
	local detailPrice = findOrWarn({ "RightColumn", "PriceRow", "Price" }) :: TextLabel?
	local buyButton = findOrWarn({ "RightColumn", "BuyButton" }) :: GuiButton?
	local errorLabel = findErrorNotificationLabel(screen)

	local upgradeGrid = screen:FindFirstChild("UpgradeGrid", true)
	local cardsByItemId: { [string]: { card: GuiButton, stroke: UIStroke? } } = {}
	if upgradeGrid then
		for _, item in pairs(RebirthShopConfig.Items) do
			local cardInst = upgradeGrid:FindFirstChild(item.cardName)
			if cardInst and cardInst:IsA("GuiButton") then
				local card = cardInst :: GuiButton
				cardsByItemId[item.id] = {
					card = card,
					stroke = card:FindFirstChild("SelectionStroke") :: UIStroke?,
				}
			end
		end
	end

	-- Selection-stroke style probe: DrillCard is the "selected" template
	-- (Q-spec: "DrillCard has a light blue uistroke that is thicker than the
	-- others, make that the selected visual state"). Pull the rest style from
	-- any other card that exists.
	local selectedStrokeStyle: StrokeStyle? = nil
	local restStrokeStyle: StrokeStyle? = nil
	if cardsByItemId.drill then
		selectedStrokeStyle = readStrokeStyle(cardsByItemId.drill.stroke)
	end
	for itemId, slot in pairs(cardsByItemId) do
		if itemId ~= "drill" then
			restStrokeStyle = readStrokeStyle(slot.stroke)
			if restStrokeStyle then
				break
			end
		end
	end

	-- Boost row anchors: walk `BoostsRow` once and grab each `<Card>.Percent`
	-- TextLabel keyed by the formatter map.
	local boostsRow = screen:FindFirstChild("BoostsRow", true)
	local boostPercentLabels: { [string]: TextLabel } = {}
	if boostsRow then
		for cardName in pairs(BOOST_ROW_FORMATTERS) do
			local cardInst = boostsRow:FindFirstChild(cardName)
			if cardInst then
				local percent = cardInst:FindFirstChild("Percent")
				if percent and percent:IsA("TextLabel") then
					boostPercentLabels[cardName] = percent
				end
			end
		end
	end

	---------------------------------------------------------------------------
	-- Card / right-column hydration helpers
	---------------------------------------------------------------------------

	local function hydrateCardStatic(item: RebirthShopConfig.RebirthShopItem)
		local slot = cardsByItemId[item.id]
		if not slot then return end
		local card = slot.card
		local title = card:FindFirstChild("Title")
		if title and title:IsA("TextLabel") then
			title.Text = string.upper(item.displayName)
		end
		local iconFrame = card:FindFirstChild("IconFrame")
		local iconLabel = iconFrame and iconFrame:FindFirstChild("Icon")
		if iconLabel and iconLabel:IsA("TextLabel") then
			iconLabel.Text = item.heroGlyph
		end
		local priceRow = card:FindFirstChild("PriceRow")
		local priceLabel = priceRow and priceRow:FindFirstChild("Price")
		if priceLabel and priceLabel:IsA("TextLabel") then
			priceLabel.Text = if item.available then tostring(item.tokenCost) else "—"
		end
	end

	local function hydrateRightColumn(item: RebirthShopConfig.RebirthShopItem)
		if heroIcon then heroIcon.Text = item.heroGlyph end
		if detailTitle then detailTitle.Text = string.upper(item.displayName) end
		if detailDescription then detailDescription.Text = item.description end
		if detailPrice then
			detailPrice.Text = if item.available then tostring(item.tokenCost) else "—"
		end
		if buyButton then
			-- Inert state for coming-soon: kill input, no scale/press/click.
			buyButton.Active = item.available
			buyButton.AutoButtonColor = item.available
			-- The label inside the BuyButton is named `Text`.
			local txt = buyButton:FindFirstChild("Text")
			if txt and txt:IsA("TextLabel") then
				txt.Text = if item.available then "BUY" else "COMING SOON"
			end
		end
	end

	---------------------------------------------------------------------------
	-- Selection state — moves the "selected" stroke style between cards.
	---------------------------------------------------------------------------

	local selectedItemId: string? = nil

	local function applySelection(itemId: string)
		if selectedItemId == itemId then
			-- Re-hydrate anyway to recover from a partial paint, but skip the
			-- stroke transition.
			local item = RebirthShopConfig.GetItem(itemId)
			if item then
				hydrateRightColumn(item)
			end
			return
		end
		local previousId = selectedItemId
		selectedItemId = itemId

		if previousId then
			local prevSlot = cardsByItemId[previousId]
			if prevSlot then
				applyStrokeStyle(prevSlot.stroke, restStrokeStyle)
			end
		end
		local newSlot = cardsByItemId[itemId]
		if newSlot then
			applyStrokeStyle(newSlot.stroke, selectedStrokeStyle)
		end
		local item = RebirthShopConfig.GetItem(itemId)
		if item then
			hydrateRightColumn(item)
		end
	end

	---------------------------------------------------------------------------
	-- Error notification (toast) — copy of `ShipOilPanel`'s pattern, scoped
	-- to this panel's own label so the two don't fight over Visible state.
	---------------------------------------------------------------------------

	local errorNotificationSeq = 0

	local function showErrorNotification(message: string)
		if not errorLabel or not errorLabel.Parent then
			return
		end
		errorNotificationSeq += 1
		local seq = errorNotificationSeq
		errorLabel.Text = message
		errorLabel.TextTransparency = 0
		errorLabel.Visible = true
		task.delay(ERROR_NOTIFICATION_HOLD_SECONDS, function()
			if seq ~= errorNotificationSeq or not errorLabel or not errorLabel.Parent then
				return
			end
			local tw = TweenService:Create(errorLabel, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				TextTransparency = 1,
			})
			tw:Play()
			tw.Completed:Wait()
			if seq ~= errorNotificationSeq or not errorLabel or not errorLabel.Parent then
				return
			end
			errorLabel.Visible = false
			errorLabel.TextTransparency = 0
		end)
	end

	---------------------------------------------------------------------------
	-- Wiring: hover/press, card click, buy click, attribute live updates.
	---------------------------------------------------------------------------

	-- Hide the ComingSoonOverlay if the item is available, show + disable the
	-- card otherwise. Also hydrate static card content (icon / title / price).
	for itemId, slot in pairs(cardsByItemId) do
		local item = RebirthShopConfig.GetItem(itemId)
		if not item then
			continue
		end
		hydrateCardStatic(item)
		local overlay = slot.card:FindFirstChild("ComingSoonOverlay")
		if overlay and overlay:IsA("GuiObject") then
			overlay.Visible = not item.available
		end
		if item.available then
			attachHoverPress(slot.card)
			-- Clicking a card swaps selection / right-column. Only available
			-- items respond — coming-soon cards are fully inert (Q4).
			slot.card.Active = true
			slot.card.Activated:Connect(function()
				applySelection(item.id)
			end)
		else
			-- Fully inert: no hover lift, no click, no scale. The overlay
			-- visually communicates the disabled state.
			slot.card.Active = false
			slot.card.AutoButtonColor = false
		end
	end

	if buyButton then
		attachHoverPress(buyButton)
	end

	-- Buy click → server purchase. Insufficient-tokens and unavailable cases
	-- short-circuit to the error toast without round-tripping the server (the
	-- server still validates authoritatively — this is just UX).
	local lastPurchaseAttempt = 0.0
	local function tryBuy()
		if not selectedItemId then return end
		local item = RebirthShopConfig.GetItem(selectedItemId)
		if not item then return end
		if not item.available then
			-- BuyButton in inert state shouldn't fire (we set Active = false),
			-- but defend against direct gamepad activation paths.
			showErrorNotification("Coming soon.")
			UiSfx.playUiDenied()
			return
		end
		local now = os.clock()
		if now - lastPurchaseAttempt < PURCHASE_DEBOUNCE_SECONDS then
			return
		end
		lastPurchaseAttempt = now

		local plr = Players.LocalPlayer
		local tokens = (plr and plr:GetAttribute(Constants.RebirthTokensAttribute) or 0) :: number
		if typeof(tokens) ~= "number" then tokens = 0 end
		if tokens < item.tokenCost then
			showErrorNotification("Not enough Rebirth Tokens.")
			UiSfx.playUiDenied()
			return
		end
		ClientRemotes.requestRebirthShopPurchase:FireServer({ itemId = item.id })
	end

	if buyButton then
		buyButton.Activated:Connect(tryBuy)
	end

	-- Server purchase result handler. We listen unconditionally (not gated on
	-- `screen.Enabled`) because the server can reply slightly after the panel
	-- closes if the click happened on the close-frame edge — we still want to
	-- play kaching / refresh the wallet attribute drives.
	ClientRemotes.oilActionResult.OnClientEvent:Connect(function(msg: any)
		if typeof(msg) ~= "table" or msg.action ~= "RebirthShopPurchase" then
			return
		end
		if msg.ok == true then
			UiSfx.playKaching()
			-- Tokens / drills are mirrored to player attributes by the server,
			-- so the balance chip + Backpack tool sync without re-fetching the
			-- snapshot. No extra work needed here.
		else
			-- Surface the server-supplied message; fall back to a generic
			-- string for unknown codes so the toast never looks empty.
			local reason = if typeof(msg.message) == "string" and msg.message ~= ""
				then msg.message
				else "Purchase failed."
			showErrorNotification(reason)
			UiSfx.playUiDenied()
		end
	end)

	-- Live balance chip — listen to the mirrored attribute so post-purchase
	-- updates land without a remote roundtrip.
	local function refreshBalance()
		if not balanceLabel then return end
		local plr = Players.LocalPlayer
		local tokens = plr and plr:GetAttribute(Constants.RebirthTokensAttribute) or 0
		if typeof(tokens) ~= "number" then tokens = 0 end
		balanceLabel.Text = tostring(math.floor(tokens))
	end

	local plr = Players.LocalPlayer
	if plr then
		plr:GetAttributeChangedSignal(Constants.RebirthTokensAttribute):Connect(refreshBalance)
	end

	---------------------------------------------------------------------------
	-- Open: snapshot → boost row hydration → default-select Drill.
	---------------------------------------------------------------------------

	local function refreshOnOpen()
		refreshBalance()
		-- Default selection (Q5).
		applySelection(RebirthShopConfig.DefaultSelectedItemId)
		-- Boost percentages — fetched fresh on open (Q7 — open-time snapshot).
		task.spawn(function()
			local ok, snapshot = pcall(function()
				return ClientRemotes.requestRebirthShopSnapshot:InvokeServer()
			end)
			if not ok or typeof(snapshot) ~= "table" then
				warn("[RebirthShopPanel] snapshot fetch failed:", snapshot)
				return
			end
			local bonusTotals = snapshot.bonusTotals or {}
			for cardName, formatter in pairs(BOOST_ROW_FORMATTERS) do
				local label = boostPercentLabels[cardName]
				if label then
					label.Text = formatter(bonusTotals)
				end
			end
		end)
	end

	-- Wrap Open so a hard-coded "screen.Enabled = true" path (e.g. a stray
	-- Studio-authored script) still triggers refresh — the panel router and
	-- ProximityPanelOpener both come through `ctrl.Open`.
	local baseOpen = ctrl.Open
	ctrl.Open = function()
		baseOpen()
		refreshOnOpen()
	end

	-- Also listen to direct Enabled flips (mirrors EquipmentShopPanel's
	-- defensive pattern).
	screen:GetPropertyChangedSignal("Enabled"):Connect(function()
		if screen.Enabled then
			refreshOnOpen()
		end
	end)

	-- If the panel happens to be open at bind time (rare), paint immediately.
	if screen.Enabled then
		task.defer(refreshOnOpen)
	end

	return ctrl
end

function RebirthShopPanel.screenName(): string
	return SCREEN_NAME
end

return RebirthShopPanel
