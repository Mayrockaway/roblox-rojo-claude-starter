--!strict
-- Data-only population for ship skin catalog clones (mirrors `InventoryAuraPopulate.Apply` split).
-- Card chrome / layout stays Studio-authored; this module only sets dynamic text, viewport, pills.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ShipSkinCatalog = require(Shared:WaitForChild("Config"):WaitForChild("ShipSkinCatalog"))
local ViewportShipFit = require(script.Parent.Parent.ViewportShipFit)
local ShipViewportPreviewFactory = require(script.Parent.Parent.ShipViewportPreviewFactory)

export type SkinEntry = {
	skinId: string,
	displayName: string,
	templateName: string,
	rarityDisplay: string?,
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

function SelectShipPopulate.Apply(root: Instance, entry: SkinEntry)
	local nameLabel = root:FindFirstChild("ShipCardName", true)
	if nameLabel and nameLabel:IsA("TextLabel") then
		nameLabel.Text = entry.displayName
	end
	local rarity = root:FindFirstChild("ShipCardRarity", true)
	if rarity and rarity:IsA("TextLabel") then
		local raw = entry.rarityDisplay
		local rarityDisplay = if typeof(raw) == "string" and raw ~= "" then raw else nil
		rarity.Text = if rarityDisplay then `Rarity: {rarityDisplay}` else "Rarity: —"
	end

	local locked = root:FindFirstChild("LockedPill", true)
	if locked and locked:IsA("GuiObject") then
		locked.Visible = false
	end
	local owned = root:FindFirstChild("OwnedPill", true)
	if owned and owned:IsA("GuiObject") then
		owned.Visible = true
	end

	local vp = root:FindFirstChild("ShipCardViewport", true)
	if vp and vp:IsA("ViewportFrame") then
		tryFillViewport(vp, entry.templateName)
	end
end

function SelectShipPopulate.ValidateSkin(entry: SkinEntry): boolean
	return ShipSkinCatalog.Skins[entry.skinId] ~= nil
end

return SelectShipPopulate
