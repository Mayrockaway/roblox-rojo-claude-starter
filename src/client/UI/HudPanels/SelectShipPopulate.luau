--!strict
-- Data-only population for ship skin catalog clones (mirrors `InventoryAuraPopulate.Apply` split).
-- Card chrome / layout stays Studio-authored; this module only sets dynamic text, viewport, pills.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ShipSkinCatalog = require(Shared:WaitForChild("Config"):WaitForChild("ShipSkinCatalog"))
local MonetizationCatalog = require(Shared:WaitForChild("Config"):WaitForChild("MonetizationCatalog"))
-- Reuse the rarity color palette from the vein crate config so ship cards,
-- crate cards, and any future loot UI all read the same color for the same
-- rarity word ("Epic" purple, "Legendary" gold, etc.). Avoids drift from a
-- second hand-rolled palette in this module.
local VeinCrateConfig = require(Shared:WaitForChild("Config"):WaitForChild("VeinCrateConfig"))
local ViewportShipFit = require(script.Parent.Parent.ViewportShipFit)
local ShipViewportPreviewFactory = require(script.Parent.Parent.ShipViewportPreviewFactory)

export type SkinEntry = {
	skinId: string,
	displayName: string,
	templateName: string,
	rarityDisplay: string?,
}

--- `Apply` context — ownership + Robux pricing fed by `SelectShipPanel`.
--- Kept optional so legacy callers don't need to change immediately; the
--- helper degrades to "always owned" when ctx is nil (matches pre-Robux
--- behavior) so a half-wired panel stays at least navigable.
export type ApplyContext = {
	owned: boolean,
	robuxPrice: number?,
	monetizationItemId: string?,
}

local function gameplayHullForTemplate(templateName: string): Model?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	if not assets then
		return nil
	end
	local byName = assets:FindFirstChild(templateName)
	if byName and byName:IsA("Model") then
		return byName
	end
	local tanker = assets:FindFirstChild("Tanker")
	if tanker and tanker:IsA("Model") then
		return tanker
	end
	return nil
end

local function tryFillViewport(vp: ViewportFrame, templateName: string)
	for _, c in ipairs(vp:GetChildren()) do
		if c:IsA("Model") or c:IsA("BasePart") then
			c:Destroy()
		end
	end
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local full = gameplayHullForTemplate(templateName)
	local source = ShipViewportPreviewFactory.resolveViewportSourceModel(assets, templateName, full)
	local clone = source:Clone()
	clone.Parent = vp
	if clone:IsA("Model") and not clone.PrimaryPart then
		local pp = clone:FindFirstChildWhichIsA("BasePart", true)
		if pp and pp:IsA("BasePart") then
			clone.PrimaryPart = pp
		end
	end
	if clone:IsA("Model") and clone.PrimaryPart then
		clone:SetPrimaryPartCFrame(CFrame.new(0, 0, 0))
	end
	if clone:IsA("Model") and clone.PrimaryPart then
		local function applyFit()
			ViewportShipFit.frameModelInViewport(vp, clone :: Model, nil)
		end
		applyFit()
		-- Viewport `AbsoluteSize` can be 0 on the first frame after parenting the clone.
		task.defer(applyFit)
	end
end

local SelectShipPopulate = {}

local function setLockedPriceLabel(locked: GuiObject, robuxPrice: number?)
	-- Authoring fallback: Studio template can include a `LockedPriceLabel` /
	-- `PriceLabel` / `Robux` text under `LockedPill`. We populate whichever
	-- exists with "R$ <price>"; if none exist that's fine — the locked pill
	-- itself is still visible and the click target is still wired.
	local candidates = { "LockedPriceLabel", "PriceLabel", "Robux", "RobuxLabel" }
	for _, name in ipairs(candidates) do
		local child = locked:FindFirstChild(name, true)
		if child and child:IsA("TextLabel") then
			if typeof(robuxPrice) == "number" and robuxPrice > 0 then
				child.Text = string.format("R$ %d", math.floor(robuxPrice))
			else
				child.Text = "R$ —"
			end
			break
		end
	end
end

function SelectShipPopulate.Apply(root: Instance, entry: SkinEntry, ctx: ApplyContext?)
	local nameLabel = root:FindFirstChild("ShipCardName", true)
	if nameLabel and nameLabel:IsA("TextLabel") then
		nameLabel.Text = entry.displayName
	end
	local rarity = root:FindFirstChild("ShipCardRarity", true)
	if rarity and rarity:IsA("TextLabel") then
		local raw = entry.rarityDisplay
		local rarityDisplay = if typeof(raw) == "string" and raw ~= "" then raw else nil
		rarity.Text = if rarityDisplay then `Rarity: {rarityDisplay}` else "Rarity: —"
		-- Tint the label to the rarity's text color (Common white, Uncommon
		-- green, Rare blue, Epic purple, Legendary gold — see
		-- `VeinCrateConfig.RarityStyles`). Falls back to Common white when
		-- the skin def has no `rarityDisplay` so the label never reads as a
		-- broken color on `"Rarity: —"`.
		rarity.TextColor3 = VeinCrateConfig.GetRarityTextColor(rarityDisplay or "Common")
	end

	local owned: boolean = if ctx and typeof(ctx.owned) == "boolean" then ctx.owned else true
	local robuxPrice: number? = ctx and ctx.robuxPrice or nil
	-- Stamp the resolved state on the card so `SelectShipPanel`'s click
	-- handler can branch (equip vs prompt purchase) without re-resolving.
	root:SetAttribute("ShipCardOwned", owned)
	if ctx and typeof(ctx.monetizationItemId) == "string" and ctx.monetizationItemId ~= "" then
		root:SetAttribute("MonetizationItemId", ctx.monetizationItemId)
	else
		root:SetAttribute("MonetizationItemId", nil)
	end

	local lockedPill = root:FindFirstChild("LockedPill", true)
	if lockedPill and lockedPill:IsA("GuiObject") then
		lockedPill.Visible = not owned
		if not owned then
			setLockedPriceLabel(lockedPill, robuxPrice)
		end
	end
	local ownedPill = root:FindFirstChild("OwnedPill", true)
	if ownedPill and ownedPill:IsA("GuiObject") then
		ownedPill.Visible = owned
	end

	-- `ShipCardViewport` is authored as a `ViewportFrame` (legacy 3D preview)
	-- or an `ImageLabel` (post-swap icon shell). Branch on the actual class so
	-- both authoring paths render correctly without requiring the panel to be
	-- rebuilt during the migration. When a skin has no `icon` (e.g. Raft
	-- pending art) the slot stays as the empty grey shell.
	local vp = root:FindFirstChild("ShipCardViewport", true)
	if vp and vp:IsA("ViewportFrame") then
		tryFillViewport(vp, entry.templateName)
	elseif vp and vp:IsA("ImageLabel") then
		local iconAsset = ShipSkinCatalog.GetSkin(entry.skinId).icon
		vp.Image = if typeof(iconAsset) == "string" then iconAsset else ""
	end
end

function SelectShipPopulate.ValidateSkin(entry: SkinEntry): boolean
	return ShipSkinCatalog.Skins[entry.skinId] ~= nil
end

--- Resolve the Robux pricing context for a skin id from `MonetizationCatalog`.
--- Centralized here so both `SelectShipPanel.wireSelectShip` (initial paint)
--- and the `oilStateUpdate` re-render path stay in sync. Starter tanker (no
--- monetization entry) returns nil so the caller treats it as always-owned.
function SelectShipPopulate.ResolveContext(skinId: string, ownedSet: { [string]: boolean }?): ApplyContext
	local owned = ownedSet ~= nil and ownedSet[skinId] == true
	-- Starter tanker is always owned even if the snapshot hasn't seeded the
	-- ownership map yet (avoids first-frame "locked" flash on join).
	if skinId == "DefaultTanker" then
		owned = true
	end
	local item = MonetizationCatalog.GetShipItemBySkinId(skinId)
	return {
		owned = owned,
		robuxPrice = item and item.robuxPrice or nil,
		monetizationItemId = item and item.id or nil,
	}
end

return SelectShipPopulate
