--!strict
-- Shared barrel stack placement using authored contact attachments when present.
-- Falls back to bounding-box-based contacts for legacy templates.

export type StackInfo = {
	bottomLocal: Vector3,
	topLocal: Vector3,
	stackStep: number,
	footprintDiameter: number,
}

local CONTACT_GAP_FALLBACK = 0.02

local BarrelStacking = {}

local function getPivotCf(inst: Instance): CFrame?
	if inst:IsA("Model") then
		return inst:GetPivot()
	elseif inst:IsA("BasePart") then
		return inst.CFrame
	end
	return nil
end

local function contactWorldPositionFromLocal(inst: Instance, localPos: Vector3): Vector3?
	local pivotCf = getPivotCf(inst)
	if not pivotCf then
		return nil
	end
	return pivotCf:PointToWorldSpace(localPos)
end

local function getBoundingSize(inst: Instance): Vector3?
	if inst:IsA("Model") then
		local _, size = inst:GetBoundingBox()
		return size
	elseif inst:IsA("BasePart") then
		return inst.Size
	end
	return nil
end

local function setPivotCf(inst: Instance, cf: CFrame)
	if inst:IsA("Model") then
		inst:PivotTo(cf)
	elseif inst:IsA("BasePart") then
		inst.CFrame = cf
	end
end

local function findAttachment(inst: Instance, name: string): Attachment?
	local found = inst:FindFirstChild(name, true)
	return if found and found:IsA("Attachment") then found else nil
end

function BarrelStacking.ResolveStackInfo(inst: Instance): StackInfo
	local pivotCf = getPivotCf(inst)
	local size = getBoundingSize(inst)
	if not pivotCf or not size then
		return {
			bottomLocal = Vector3.zero,
			topLocal = Vector3.new(0, 1, 0),
			stackStep = 1,
			footprintDiameter = 1,
		}
	end

	local bottomAttachment = findAttachment(inst, "BottomContact")
	local topAttachment = findAttachment(inst, "TopContact")

	local bottomLocal = if bottomAttachment
		then pivotCf:PointToObjectSpace(bottomAttachment.WorldPosition)
		else Vector3.new(0, -size.Y * 0.5, 0)
	local topLocal = if topAttachment
		then pivotCf:PointToObjectSpace(topAttachment.WorldPosition)
		else Vector3.new(0, size.Y * 0.5 + CONTACT_GAP_FALLBACK, 0)

	local stackStep = topLocal.Y - bottomLocal.Y
	if stackStep <= 0 then
		stackStep = size.Y + CONTACT_GAP_FALLBACK
		topLocal = Vector3.new(bottomLocal.X, bottomLocal.Y + stackStep, bottomLocal.Z)
	end

	return {
		bottomLocal = bottomLocal,
		topLocal = topLocal,
		stackStep = stackStep,
		footprintDiameter = math.max(size.X, size.Z),
	}
end

function BarrelStacking.PlaceInstanceOnContact(inst: Instance, contactCf: CFrame): StackInfo
	local info = BarrelStacking.ResolveStackInfo(inst)
	local currentPivot = getPivotCf(inst)
	if currentPivot then
		local rotationOnly = currentPivot.Rotation
		local worldBottomOffset = rotationOnly:VectorToWorldSpace(info.bottomLocal)
		local pivotPos = contactCf.Position - worldBottomOffset
		setPivotCf(inst, CFrame.new(pivotPos) * rotationOnly)
	end
	return info
end

function BarrelStacking.PlaceInstanceAtPivot(inst: Instance, pivotCf: CFrame): StackInfo
	local info = BarrelStacking.ResolveStackInfo(inst)
	setPivotCf(inst, pivotCf)
	return info
end

function BarrelStacking.GetContactCFrame(inst: Instance, which: "Bottom" | "Top"): CFrame?
	local attachmentName = if which == "Bottom" then "BottomContact" else "TopContact"
	local attachment = findAttachment(inst, attachmentName)
	if attachment then
		return CFrame.new(attachment.WorldPosition)
	end

	local info = BarrelStacking.ResolveStackInfo(inst)
	local localPos = if which == "Bottom" then info.bottomLocal else info.topLocal
	local worldPos = contactWorldPositionFromLocal(inst, localPos)
	if worldPos then
		return CFrame.new(worldPos)
	end
	return nil
end

return BarrelStacking
