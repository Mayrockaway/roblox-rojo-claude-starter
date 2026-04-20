--!strict
-- Shared helpers for ship rig lookup/validation across server and client.

export type RigDef = {
	dockAnchorName: string,
	frontMarkerName: string,
	deckAnchorName: string,
	deckTopAnchorName: string,
	deckYOffsetFallback: number,
	deckSeatName: string,
	barrelStackRootName: string,
	playerFlagName: string,
	standForwardOffset: number,
	standRightOffset: number,
}

local ShipRig = {}

local function findNamedDescendantOfClass(model: Model, name: string, className: string): Instance?
	if typeof(name) ~= "string" or name == "" then
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
	-- DeckTopAnchor is a soft requirement: code falls back to BarrelStackRoot/DeckSeat,
	-- but missing it on a new ship template will degrade NPC walking precision.
	if not ShipRig.FindAttachment(model, rig.deckTopAnchorName) then
		table.insert(warnings, string.format("Missing Attachment '%s' (NPCs will use fallback deck-Y).", rig.deckTopAnchorName))
	end

	return #errors == 0, errors, warnings
end

function ShipRig.ResolveDeckWorldY(model: Model, rig: RigDef, waterlineY: number): number
	-- Authoritative: DeckTopAnchor is hand-authored at the walkable deck surface.
	local deckTop = ShipRig.FindAttachment(model, rig.deckTopAnchorName)
	if deckTop then
		return deckTop.WorldPosition.Y
	end
	local deckAnchor = ShipRig.FindAttachment(model, rig.deckAnchorName)
	if deckAnchor then
		return deckAnchor.WorldPosition.Y
	end
	local barrelStackRoot = ShipRig.FindBasePart(model, rig.barrelStackRootName)
	if barrelStackRoot then
		return barrelStackRoot.Position.Y
	end
	return waterlineY + rig.deckYOffsetFallback
end

return ShipRig
