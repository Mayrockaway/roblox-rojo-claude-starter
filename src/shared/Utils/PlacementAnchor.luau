--!strict
--[[
	World-space offset: model pivot Y minus the Y of the "ground contact" used for placement.

	If the model contains a `BasePart` named exactly `Bottom` or `bottom`, the lowest world Y
	of that part's oriented bounding box is used (good when `GetBoundingBox()` on the whole
	model misses mesh that extends past part hulls). Otherwise falls back to `Model:GetBoundingBox()`.

	Author one anchor per rig; keep it non-overlapping with sibling special names.
]]

local PlacementAnchor = {}

local function lowestWorldYOfPartOBB(part: BasePart): number
	local cf, sz = part.CFrame, part.Size
	local hx, hy, hz = sz.X / 2, sz.Y / 2, sz.Z / 2
	local lowestY = math.huge
	for _, o in ipairs({
		Vector3.new(hx, hy, hz),
		Vector3.new(-hx, hy, hz),
		Vector3.new(hx, -hy, hz),
		Vector3.new(-hx, -hy, hz),
		Vector3.new(hx, hy, -hz),
		Vector3.new(-hx, hy, -hz),
		Vector3.new(hx, -hy, -hz),
		Vector3.new(-hx, -hy, -hz),
	}) do
		local wy = (cf * o).Y
		if wy < lowestY then
			lowestY = wy
		end
	end
	return lowestY
end

function PlacementAnchor.findBottomAnchorPart(model: Model): BasePart?
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") and (d.Name == "Bottom" or d.Name == "bottom") then
			return d
		end
	end
	return nil
end

function PlacementAnchor.pivotYMinusBottomWorldY(model: Model): number
	local pivotY = model:GetPivot().Position.Y
	local anchor = PlacementAnchor.findBottomAnchorPart(model)
	if anchor then
		return pivotY - lowestWorldYOfPartOBB(anchor)
	end
	local bbCF, bbSize = model:GetBoundingBox()
	return pivotY - (bbCF.Position.Y - bbSize.Y / 2)
end

return PlacementAnchor
