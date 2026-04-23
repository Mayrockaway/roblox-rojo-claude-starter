--!strict
-- Data-only population for `FleetPanelGui` boat cards + the right-column hero.
-- Mirrors the `SelectShipPopulate` split: card chrome / layout / strokes are
-- authored in Studio (`StarterGui.FleetPanelGui.Canvas.PanelHost.Panel.Body
-- .MainSplit.LeftColumn.FleetGridCard.FleetGrid.BoatCardTemplate`); this
-- module only writes dynamic text, visibility, colors, icon assets, and the
-- `Currency` / `State` attributes the click router reads.
--
-- The card template carries six prototype frames the controller reads from
-- (so designers can re-tint state visuals in Studio without touching code):
--   * `BoatCardTemplate.CostPill.StateGold`   — cash cost styling
--   * `BoatCardTemplate.CostPill.StateRobux`  — robux cost styling
--   * `RightColumn.ActionRow.ActionButton.StateEquip`     — bright green CTA
--   * `RightColumn.ActionRow.ActionButton.StateEquipped`  — darker pressed green
--   * `RightColumn.ActionRow.ActionButton.StateBuy`       — distinct buy color
--   * `RightColumn.ActionRow.CostPill.{StateGold,StateRobux}` — same pill swap as cards
-- The "Owned" pill state has no prototype because it's a neutral navy chip
-- with the panel's gold stroke — applied inline below.
--
-- IMPORTANT: this module assumes the catalog is the source of truth (no
-- dummy data). Every entry comes from `BoatCatalog.Boats` filtered through
-- `placeholder = false` (mirrors `SelectShipPanel.sortedBoatList`).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BoatCatalog = require(Shared:WaitForChild("Config"):WaitForChild("BoatCatalog"))
local MonetizationCatalog = require(Shared:WaitForChild("Config"):WaitForChild("MonetizationCatalog"))
local VeinCrateConfig = require(Shared:WaitForChild("Config"):WaitForChild("VeinCrateConfig"))
local ShipUpgradeConfig = require(Shared:WaitForChild("Config"):WaitForChild("ShipUpgradeConfig"))

export type BoatEntry = {
	boatId: string,
	displayName: string,
	templateName: string,
	rarityDisplay: string?,
	icon: string?,
	speedLevel: number?,
	capacityLevel: number?,
	placeholder: boolean?,
}

export type ApplyContext = {
	owned: boolean,
	equipped: boolean,
	cashCost: number?,
	robuxPrice: number?,
	monetizationItemId: string?,
	unlockKind: string?,
}

-- The Fleet panel was authored with hand-tuned navy chrome, a soft-gold
-- equipped accent, and a navy-on-gold "OWNED" chip. These are sampled from
-- the live panel so future re-tints in Studio that rotate the gold stroke
-- on the panel's `HeaderDivider` propagate via `EquippedAccentColor` rather
-- than being duplicated here.
local DEFAULT_EQUIPPED_GOLD = Color3.fromRGB(217, 177, 76)
local DEFAULT_OWNED_TEXT = Color3.fromHex("#f3d77a")
local DEFAULT_OWNED_BG = Color3.fromHex("#102035")
-- Asset id of the gold coin shown in `HUD.Canvas.CashStrip` (sampled live —
-- if a designer changes the strip's icon, update this constant so cash boat
-- cost pills stay in lockstep). Used by `applyCostPill` cash branch + the
-- right-column action row's cost pill.
local CASH_COIN_ASSET = "rbxassetid://81632778317714"
local DEFAULT_RARITY_STROKE_TRANSPARENCY = 0.15
local EQUIPPED_STROKE_TRANSPARENCY = 0
local SEG_EMPTY_COLOR = Color3.fromRGB(40, 50, 62)

local FleetPanelPopulate = {}

local function rarityStrokeColor(rarity: string?): Color3
	-- The rarity panel and crate UI share `VeinCrateConfig.RarityStyles`
	-- so a single source of truth drives card border tinting too.
	-- `bgStart` is the brighter rarity color (used by the crate header
	-- glow) and reads cleanly as a 1-2px hairline against the navy card.
	local style = VeinCrateConfig.RarityStyles[rarity or "Common"]
	if style then
		return style.bgStart
	end
	return VeinCrateConfig.RarityStyles.Common.bgStart
end

local function rarityPillBackground(rarity: string?): Color3
	local style = VeinCrateConfig.RarityStyles[rarity or "Common"]
	if style then
		return style.bgEnd
	end
	return VeinCrateConfig.RarityStyles.Common.bgEnd
end

local function rarityPillTextColor(rarity: string?): Color3
	return VeinCrateConfig.GetRarityTextColor(rarity or "Common")
end

local function formatCash(amount: number): string
	if amount >= 1_000_000 then
		local m = amount / 1_000_000
		if m == math.floor(m) then
			return string.format("%dM", math.floor(m))
		end
		return string.format("%.1fM", m)
	elseif amount >= 1_000 then
		return string.format("%dK", math.floor(amount / 1_000))
	end
	return tostring(math.floor(amount))
end

local function copyStateProto(target: GuiObject, proto: Instance?, copyText: boolean)
	if not proto then return end
	if proto:IsA("GuiObject") then
		target.BackgroundColor3 = (proto :: GuiObject).BackgroundColor3
	end
	-- Stroke can be either `Stroke` (cards/pills) or the action button's
	-- main `UIStroke` direct child.
	local protoStroke = proto:FindFirstChild("Stroke")
	if protoStroke and protoStroke:IsA("UIStroke") then
		local mainStroke = target:FindFirstChild("Stroke")
		if mainStroke and mainStroke:IsA("UIStroke") then
			mainStroke.Color = protoStroke.Color
			mainStroke.Transparency = protoStroke.Transparency
		else
			-- Fall back to the first non-text UIStroke child (action button case).
			for _, child in ipairs(target:GetChildren()) do
				if child:IsA("UIStroke") and child.Name ~= "TextStroke" then
					child.Color = protoStroke.Color
					child.Transparency = protoStroke.Transparency
					break
				end
			end
		end
	end
	local protoIcon = proto:FindFirstChild("Icon")
	if protoIcon and protoIcon:IsA("ImageLabel") then
		local targetIcon = target:FindFirstChild("Icon")
		if targetIcon and targetIcon:IsA("ImageLabel") then
			targetIcon.Image = protoIcon.Image
			targetIcon.ImageColor3 = protoIcon.ImageColor3
			targetIcon.Visible = true
		end
	end
	local protoLabel = proto:FindFirstChild("Label") or proto:FindFirstChild("Amount")
	if copyText and protoLabel and protoLabel:IsA("TextLabel") then
		if target:IsA("TextButton") then
			-- Bind to a local TextButton to dodge a Luau "ambiguous syntax"
			-- parse: two consecutive `(target :: TextButton).Field = ...`
			-- statements get read as `protoLabel.Text(target :: TextButton).Field`,
			-- which fails to load the whole module (cascades through
			-- `FleetPanel` → `HudPanelRouter` → entire HUD wiring).
			local tb = target :: TextButton
			tb.Text = protoLabel.Text
			tb.TextColor3 = protoLabel.TextColor3
		else
			local targetLabel = target:FindFirstChild("Label") or target:FindFirstChild("Amount")
			if targetLabel and targetLabel:IsA("TextLabel") then
				targetLabel.Text = protoLabel.Text
				targetLabel.TextColor3 = protoLabel.TextColor3
			end
		end
	elseif protoLabel and protoLabel:IsA("TextLabel") then
		-- Always copy color even when the caller wants to set its own text.
		local targetLabel = target:FindFirstChild("Amount") or target:FindFirstChild("Label")
		if targetLabel and targetLabel:IsA("TextLabel") then
			targetLabel.TextColor3 = protoLabel.TextColor3
		end
	end
end

--- Reusable "icon hidden, label spans full pill" layout for the chip
--- variants (Owned, Equipped). The cost variants restore the icon + the
--- 78% width text in `applyCostPill`. Keeping this helper local means the
--- two chip states stay visually consistent (same height, padding, label
--- placement) and only differ in fill / text / stroke color.
local function applyChipLayout(pill: GuiObject, bg: Color3, strokeColor: Color3, strokeTransparency: number, label: string, labelColor: Color3, currencyAttr: string)
	pill.Visible = true
	pill:SetAttribute("Currency", currencyAttr)
	pill.BackgroundColor3 = bg
	local stroke = pill:FindFirstChild("Stroke")
	if stroke and stroke:IsA("UIStroke") then
		stroke.Color = strokeColor
		stroke.Transparency = strokeTransparency
	end
	local icon = pill:FindFirstChild("Icon")
	if icon and icon:IsA("ImageLabel") then
		icon.Visible = false
	end
	local amount = pill:FindFirstChild("Amount")
	if amount and amount:IsA("TextLabel") then
		amount.Text = label
		amount.TextColor3 = labelColor
		-- Icon hidden, so let the label own the full pill width and center.
		amount.Size = UDim2.fromScale(1, 1)
		amount.Position = UDim2.fromScale(0, 0)
	end
end

local function applyOwnedChip(pill: GuiObject, equippedAccent: Color3)
	-- Navy bg + gold text + soft gold stroke. Reads as "you have it, click
	-- to equip" — distinct from the equipped chip's saturated gold fill so
	-- the player can tell the active boat apart from the rest of the
	-- collection at a glance.
	applyChipLayout(pill, DEFAULT_OWNED_BG, equippedAccent, 0.35, "OWNED", DEFAULT_OWNED_TEXT, "Owned")
end

local function applyEquippedChip(pill: GuiObject, equippedAccent: Color3)
	-- Saturated gold fill + deep navy text + bright gold stroke. Pairs with
	-- the gold `RarityStroke` halo on the equipped card so the chip reads
	-- as "this is the boat the right column is showing right now". Same
	-- pill geometry as Owned / Cost — only the colors change — so the
	-- card layout doesn't shift between state transitions.
	applyChipLayout(pill, equippedAccent, equippedAccent, 0, "EQUIPPED", DEFAULT_OWNED_BG, "Equipped")
end

local function applyCostPill(pill: GuiObject, ctx: ApplyContext)
	local icon = pill:FindFirstChild("Icon")
	local amount = pill:FindFirstChild("Amount")

	if ctx.unlockKind == "robux" then
		-- Robux pill: purple chrome + Robux glyph + `R$ N` label, with the
		-- icon parked at the left and the label taking the right 78%.
		pill:SetAttribute("Currency", "Robux")
		copyStateProto(pill, pill:FindFirstChild("StateRobux"), false)
		if icon and icon:IsA("ImageLabel") then
			-- `copyStateProto` already set the Robux icon Image + Visible from
			-- the StateRobux prototype, but harden Visible here in case a card
			-- arrived from a previously-hidden Owned/Equipped chip render.
			icon.Visible = true
		end
		if amount and amount:IsA("TextLabel") then
			amount.Size = UDim2.fromScale(0.78, 1)
			amount.Position = UDim2.fromScale(0.22, 0)
			if typeof(ctx.robuxPrice) == "number" and (ctx.robuxPrice :: number) > 0 then
				amount.Text = string.format("R$ %d", math.floor(ctx.robuxPrice :: number))
			else
				-- Catalog says "robux" but `MonetizationCatalog` has no price
				-- (placeholder Robux entries with `productId = 0`). Render
				-- `R$ —` so designers see the entry rather than mistaking
				-- it for missing data.
				amount.Text = "R$ —"
			end
		end
	else
		-- Cash pill: green text on the navy chip, with the same gold coin
		-- icon `HUD.Canvas.CashStrip` uses parked at the left of the pill.
		-- We restore the asset explicitly because `StateGold` has no `Icon`
		-- prototype, so `copyStateProto` would leave whatever the last
		-- render set (Robux glyph after a Robux→Cash transition; nothing
		-- on a fresh card). Treat anything that isn't `robux` as cash;
		-- `starter` is always owned so it never reaches this branch
		-- (see `Apply` below).
		pill:SetAttribute("Currency", "Gold")
		copyStateProto(pill, pill:FindFirstChild("StateGold"), false)
		if icon and icon:IsA("ImageLabel") then
			icon.Image = CASH_COIN_ASSET
			icon.ImageColor3 = Color3.new(1, 1, 1)
			icon.Visible = true
		end
		if amount and amount:IsA("TextLabel") then
			-- Icon takes the left ~22%, label takes the right 78% — same
			-- left-icon / right-label split the Robux branch uses so the
			-- two states feel symmetric.
			amount.Size = UDim2.fromScale(0.78, 1)
			amount.Position = UDim2.fromScale(0.22, 0)
			local cash = if typeof(ctx.cashCost) == "number" then ctx.cashCost :: number else 0
			amount.Text = formatCash(cash)
		end
	end
end

--- Apply per-card visuals + state pills. The card is expected to be a clone
--- of `BoatCardTemplate` (so all the prototype frames + child names are
--- present) and parented into `FleetGrid` already. The template root is an
--- `ImageButton` (matches the working sample's `AuraInventoryCardTemplate`)
--- but `GuiObject` keeps the door open for a designer-side rebuild as a
--- different `GuiButton` subclass without touching this module.
function FleetPanelPopulate.Apply(card: GuiObject, entry: BoatEntry, ctx: ApplyContext, equippedAccent: Color3?)
	local accent = equippedAccent or DEFAULT_EQUIPPED_GOLD

	-- Stash state on the card so the click router (FleetPanel) can read it
	-- without re-resolving the catalog on every press.
	card:SetAttribute("BoatId", entry.boatId)
	card:SetAttribute("Rarity", entry.rarityDisplay or "Common")
	card:SetAttribute("IsOwned", ctx.owned)
	card:SetAttribute("IsEquipped", ctx.equipped)
	card:SetAttribute("UnlockKind", ctx.unlockKind or "starter")
	-- Click handler in FleetPanel reads this and no-ops so a press on a
	-- Tier*Boat tile doesn't fire a remote the server would reject
	-- (`BoatCatalog.IsBoatPurchasable` rejects placeholders).
	card:SetAttribute("Placeholder", entry.placeholder == true)
	if ctx.monetizationItemId then
		card:SetAttribute("MonetizationItemId", ctx.monetizationItemId)
	else
		card:SetAttribute("MonetizationItemId", nil)
	end

	-- Icon. The legacy `IconHost.EquippedTag` corner badge was removed
	-- from the authored template — equipped boats now read as such via
	-- (a) the gold `RarityStroke` halo on the card, and (b) the
	-- `EQUIPPED` chip rendered by `applyEquippedChip` below. Defensively
	-- destroy a stray `EquippedTag` if a clone surfaces with one (e.g.
	-- rolled-back StarterGui save) so the duplicate badge can't ghost
	-- back in.
	local iconHost = card:FindFirstChild("IconHost")
	if iconHost then
		local icon = iconHost:FindFirstChild("Icon")
		if icon and icon:IsA("ImageLabel") then
			icon.Image = entry.icon or ""
		end
		local stray = iconHost:FindFirstChild("EquippedTag")
		if stray then
			stray:Destroy()
		end
	end

	-- Display name
	local nameLabel = card:FindFirstChild("NameLabel")
	if nameLabel and nameLabel:IsA("TextLabel") then
		nameLabel.Text = string.upper(entry.displayName)
	end

	-- Rarity stroke (gold halo for equipped, rarity-tinted otherwise)
	local rarityStroke = card:FindFirstChild("RarityStroke")
	if rarityStroke and rarityStroke:IsA("UIStroke") then
		if ctx.equipped then
			rarityStroke.Color = accent
			rarityStroke.Transparency = EQUIPPED_STROKE_TRANSPARENCY
		else
			rarityStroke.Color = rarityStrokeColor(entry.rarityDisplay)
			rarityStroke.Transparency = DEFAULT_RARITY_STROKE_TRANSPARENCY
		end
	end

	-- Rarity pill (background + label + text color from VeinCrateConfig)
	local rarityPill = card:FindFirstChild("RarityPill")
	if rarityPill and rarityPill:IsA("GuiObject") then
		rarityPill.BackgroundColor3 = rarityPillBackground(entry.rarityDisplay)
		local lbl = rarityPill:FindFirstChild("Label")
		if lbl and lbl:IsA("TextLabel") then
			lbl.Text = string.upper(entry.rarityDisplay or "Common")
			lbl.TextColor3 = rarityPillTextColor(entry.rarityDisplay)
		end
	end

	-- Cost pill: ALWAYS present in the same slot under the rarity pill so
	-- the card's vertical rhythm stays identical across all three states.
	-- Only the fill / label / stroke change:
	--   Equipped -> gold-fill EQUIPPED chip (matches RarityStroke halo)
	--   Owned    -> navy-fill OWNED chip with gold accent
	--   Unowned  -> Gold cost (ImageLabel + amount) or Robux (purple)
	local costPill = card:FindFirstChild("CostPill")
	if costPill and costPill:IsA("GuiObject") then
		if ctx.equipped then
			applyEquippedChip(costPill, accent)
		elseif ctx.owned then
			applyOwnedChip(costPill, accent)
		else
			costPill.Visible = true
			applyCostPill(costPill, ctx)
		end
	end
end

--- Hydrate the right column with the equipped boat's hero tile + bars +
--- action button. `entry` here is the **equipped** boat; `ctx` is its
--- `ApplyContext`. When the player owns no equippable boat (impossible in
--- practice — starter is auto-granted on profile load), the right column
--- collapses to a "BUY" prompt for the catalog's first non-starter entry.
function FleetPanelPopulate.HydrateRightColumn(rightCol: Frame, entry: BoatEntry, ctx: ApplyContext, equippedAccent: Color3?)
	local accent = equippedAccent or DEFAULT_EQUIPPED_GOLD

	local heroTitle = rightCol:FindFirstChild("HeroTitle")
	if heroTitle and heroTitle:IsA("TextLabel") then
		heroTitle.Text = string.upper(entry.displayName)
	end

	local heroCard = rightCol:FindFirstChild("HeroCard")
	if not heroCard then return end

	local rarityBadge = heroCard:FindFirstChild("RarityBadge")
	if rarityBadge and rarityBadge:IsA("GuiObject") then
		rarityBadge.BackgroundColor3 = rarityPillBackground(entry.rarityDisplay)
		local lbl = rarityBadge:FindFirstChild("Label")
		if lbl and lbl:IsA("TextLabel") then
			lbl.Text = string.upper(entry.rarityDisplay or "Common")
			lbl.TextColor3 = rarityPillTextColor(entry.rarityDisplay)
		end
	end

	local heroIconHost = heroCard:FindFirstChild("HeroIconHost")
	if heroIconHost then
		local heroIcon = heroIconHost:FindFirstChild("HeroIcon")
		if heroIcon and heroIcon:IsA("ImageLabel") then
			heroIcon.Image = entry.icon or ""
		end
	end

	-- Segment bars: light `level` of `MaxLevel` segments. The bars are
	-- authored at 10 segments each (`Seg_01..Seg_10`); `ShipUpgradeConfig`
	-- caps speed/capacity at 10 too.
	local barsHost = heroCard:FindFirstChild("BarsHost")
	local function paintBar(barName: string, level: number, maxLevel: number)
		local bar = barsHost and barsHost:FindFirstChild(barName)
		if not bar then return end
		local segHost = bar:FindFirstChild("Segments")
		if not segHost then return end
		local lit = segHost:GetAttribute("LitColor")
		if typeof(lit) ~= "Color3" then
			lit = accent
		end
		local clamped = math.clamp(math.floor(level), 0, maxLevel)
		for i = 1, 10 do
			local seg = segHost:FindFirstChild(string.format("Seg_%02d", i))
			if seg and seg:IsA("GuiObject") then
				if i <= clamped then
					seg.BackgroundColor3 = lit :: Color3
				else
					seg.BackgroundColor3 = SEG_EMPTY_COLOR
				end
			end
		end
		local header = bar:FindFirstChild("Header")
		local levelLabel = header and header:FindFirstChild("LevelLabel")
		if levelLabel and levelLabel:IsA("TextLabel") then
			levelLabel.Text = string.format("Lv %d/%d", clamped, maxLevel)
		end
	end
	paintBar("SpeedBar", entry.speedLevel or 1, ShipUpgradeConfig.MaxSpeedLevel)
	paintBar("CargoBar", entry.capacityLevel or 1, ShipUpgradeConfig.MaxCapacityLevel)

	-- Action button + cost pill
	local actionRow = rightCol:FindFirstChild("ActionRow")
	if not actionRow then return end
	local actionBtn = actionRow:FindFirstChild("ActionButton")
	local costPill = actionRow:FindFirstChild("CostPill")

	-- Resolve which state the button should read. Per the agreed spec:
	--   * Equipped → button shows EQUIPPED (darker pressed green); pill hides.
	--   * Owned + not equipped → button shows EQUIP (bright green); pill hides
	--                             because the only purchase action is "Buy".
	--   * Unowned → button shows BUY (distinct color); pill shows cost.
	local stateName: string
	if ctx.equipped then
		stateName = "Equipped"
	elseif ctx.owned then
		stateName = "Equip"
	else
		stateName = "Buy"
	end

	if actionBtn and actionBtn:IsA("TextButton") then
		actionBtn:SetAttribute("State", stateName)
		actionBtn:SetAttribute("BoatId", entry.boatId)
		actionBtn:SetAttribute("UnlockKind", ctx.unlockKind or "starter")
		actionBtn:SetAttribute("MonetizationItemId", ctx.monetizationItemId or nil)
		copyStateProto(actionBtn, actionBtn:FindFirstChild("State" .. stateName), true)
	end

	if costPill and costPill:IsA("GuiObject") then
		if ctx.owned or ctx.equipped then
			costPill.Visible = false
			if actionBtn then
				(actionBtn :: GuiObject).Size = UDim2.fromScale(1, 1)
			end
		else
			costPill.Visible = true
			if actionBtn then
				(actionBtn :: GuiObject).Size = UDim2.fromScale(0.68, 1)
			end
			costPill.Size = UDim2.fromScale(0.30, 1)
			applyCostPill(costPill, ctx)
		end
	end
end

--- Build the catalog → `BoatEntry` list and sort ascending by rarity rank
--- (then progression index, then displayName).
---
--- Unlike `SelectShipPanel.sortedBoatList`, this list **includes Step 1
--- placeholder tier entries** (`Tier1Boat..Tier10Boat`). The Fleet panel is
--- the full ship-management view; its job is to show the entire 1..10
--- progression chain — including future content slots — so a player can
--- see what's coming. Placeholders are rendered the same way as real
--- entries (rarity, cost, etc. all authored), but the click router in
--- `FleetPanel.luau` short-circuits on `card:GetAttribute("Placeholder")`
--- so equip / buy presses no-op rather than firing a remote the server
--- would reject (`BoatCatalog.IsBoatPurchasable` returns false for
--- placeholders). When the content pass replaces the placeholder set with
--- the 10 real boats (header notes Step 5 was skipped), the panel will
--- still show 10 cards — same UI, real entries.
local RARITY_RANK: { [string]: number } = {
	Common = 1,
	Uncommon = 2,
	Rare = 3,
	Epic = 4,
	Legendary = 5,
}
function FleetPanelPopulate.SortedBoatList(): { BoatEntry }
	local list: { BoatEntry } = {}
	for boatId, def in pairs(BoatCatalog.Boats) do
		table.insert(list, {
			boatId = boatId,
			displayName = def.displayName,
			templateName = def.templateName,
			rarityDisplay = def.rarityDisplay,
			icon = def.icon,
			speedLevel = def.speedLevel,
			capacityLevel = def.capacityLevel,
			placeholder = def.placeholder == true,
		})
	end
	table.sort(list, function(a, b)
		local ra = RARITY_RANK[a.rarityDisplay or "Common"] or 99
		local rb = RARITY_RANK[b.rarityDisplay or "Common"] or 99
		if ra ~= rb then return ra < rb end
		local pa = BoatCatalog.GetBoat(a.boatId).progressionIndex or 99
		local pb = BoatCatalog.GetBoat(b.boatId).progressionIndex or 99
		if pa ~= pb then return pa < pb end
		-- Real entries before placeholder entries within the same rarity +
		-- progression slot, so the live boats win the visible slot order.
		if (a.placeholder == true) ~= (b.placeholder == true) then
			return not (a.placeholder == true)
		end
		return a.displayName < b.displayName
	end)
	return list
end

--- Resolve ownership + pricing context for `boatId` from the latest oil-state
--- snapshot. `ownedSet` and `equippedId` are passed by `FleetPanel` so this
--- module stays free of remote / state dependencies (matches
--- `SelectShipPopulate.ResolveContext` design).
function FleetPanelPopulate.ResolveContext(boatId: string, ownedSet: { [string]: boolean }?, equippedId: string?): ApplyContext
	local def = BoatCatalog.GetBoat(boatId)
	local owned = ownedSet ~= nil and ownedSet[boatId] == true
	-- Starter is always owned even before the first snapshot lands.
	if def.unlock and def.unlock.kind == "starter" then
		owned = true
	end
	-- `Tier1Boat` is the canonical starter id; harden the same way
	-- `SelectShipPopulate` does so the panel doesn't flash "BUY" on join.
	if boatId == "Tier1Boat" then
		owned = true
	end
	local equipped = equippedId == boatId

	local item = MonetizationCatalog.GetShipItemByBoatId(boatId)
	local cashCost: number? = nil
	local unlockKind: string? = "starter"
	if def.unlock then
		unlockKind = def.unlock.kind
		if def.unlock.kind == "cash" then
			cashCost = def.unlock.cashCost
		end
	end

	return {
		owned = owned,
		equipped = equipped,
		cashCost = cashCost,
		robuxPrice = item and item.robuxPrice or nil,
		monetizationItemId = item and item.id or nil,
		unlockKind = unlockKind,
	}
end

return FleetPanelPopulate
