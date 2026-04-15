--!strict
-- Shared helpers for ship rig lookup/validation across server and client.

export type RigDef = {
	dockAnchorName: string,
	frontMarkerName: string,
	deckAnchorName: string,
	deckYOffsetFallback: number,
	deckSeatName: string,
	barrelStackRootName: string,
	playerFlagName: string,
}

local ShipRig = {}

local function findNamedDescendantOfClass(model: Model, name: string, className: string): Instance?
	if name == "" then
		return nil
	end
	local found = model:FindFirstChild(name, true)
	if found and found:IsA(className) then
		return found
	end
	return nil
end

function ShipRig.FindAttachment(model: Model, name: string): Attachment?
	local found = findNamedDescendantOfClass(model, name, "Attachment")
	return if found and found:IsA("Attachment") then found else nil
end

function ShipRig.FindBasePart(model: Model, name: string): BasePart?
	local found = findNamedDescendantOfClass(model, name, "BasePart")
	return if found and found:IsA("BasePart") then found else nil
end

function ShipRig.FindSeat(model: Model, name: string): Seat?
	local found = findNamedDescendantOfClass(model, name, "Seat")
	return if found and found:IsA("Seat") then found else nil
end

function ShipRig.ValidateCore(model: Model, rig: RigDef): (boolean, { string }, { string })
	local errors = {}
	local warnings = {}

	if not model:FindFirstChildWhichIsA("BasePart", true) then
		table.insert(errors, "Model has no BasePart descendants.")
	end
	if not ShipRig.FindAttachment(model, rig.dockAnchorName) then
		table.insert(errors, string.format("Missing Attachment '%s'.", rig.dockAnchorName))
	end
	if not ShipRig.FindBasePart(model, rig.frontMarkerName) then
		table.insert(errors, string.format("Missing BasePart '%s'.", rig.frontMarkerName))
	end
	if not ShipRig.FindSeat(model, rig.deckSeatName) then
		table.insert(errors, string.format("Missing Seat '%s'.", rig.deckSeatName))
	end
	if not ShipRig.FindBasePart(model, rig.barrelStackRootName) then
		table.insert(errors, string.format("Missing BasePart '%s'.", rig.barrelStackRootName))
	end
	if not ShipRig.FindBasePart(model, rig.playerFlagName) then
		table.insert(errors, string.format("Missing BasePart '%s'.", rig.playerFlagName))
	end

	return #errors == 0, errors, warnings
end

function ShipRig.ResolveDeckWorldY(model: Model, rig: RigDef, waterlineY: number): number
	local deckAnchor = ShipRig.FindAttachment(model, rig.deckAnchorName)
	if deckAnchor then
		return deckAnchor.WorldPosition.Y
	end
	-- Prefer BarrelStackRoot as the ship's deck reference when DeckAnchor is not authored.
	local barrelStackRoot = ShipRig.FindBasePart(model, rig.barrelStackRootName)
	if barrelStackRoot then
		return barrelStackRoot.Position.Y
	end
	return waterlineY + rig.deckYOffsetFallback
end

return ShipRig
