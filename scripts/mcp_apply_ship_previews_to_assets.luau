--[[
	Run in Roblox Studio (Command Bar or MCP `execute_luau`) AFTER adjusting:
	  Workspace.Map.ShipRigCalibration.ShipTemplatePreviews

	What it does:
	- Reads each `ShipPreview_<TemplateName>` model.
	- Removes temporary rig labels from the preview clone.
	- Replaces `ReplicatedStorage.Assets.<TemplateName>` with the adjusted preview.

	Notes:
	- This updates template geometry/anchor positions in-memory in Studio.
	- Save/publish after running if the result looks correct.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local assets = ReplicatedStorage:FindFirstChild("Assets")
if not assets then
	return "ERROR: ReplicatedStorage.Assets missing."
end

local map = Workspace:FindFirstChild("Map")
local rootParent: Instance = if map then map else Workspace
local calibrationFolder = rootParent:FindFirstChild("ShipRigCalibration")
if not (calibrationFolder and calibrationFolder:IsA("Folder")) then
	return "ERROR: ShipRigCalibration folder not found under " .. rootParent:GetFullName()
end

local previewFolder = calibrationFolder:FindFirstChild("ShipTemplatePreviews")
if not (previewFolder and previewFolder:IsA("Folder")) then
	return "ERROR: ShipTemplatePreviews folder not found under " .. calibrationFolder:GetFullName()
end

local function stripRigLabels(root: Instance)
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BillboardGui") and string.sub(d.Name, 1, 9) == "RigLabel_" then
			d:Destroy()
		end
	end
end

local lines = {}
local appliedCount = 0
local skippedCount = 0

for _, child in ipairs(previewFolder:GetChildren()) do
	if not child:IsA("Model") then
		skippedCount += 1
		table.insert(lines, string.format("[SKIP] %s is %s (expected Model).", child.Name, child.ClassName))
		continue
	end

	local templateName = string.match(child.Name, "^ShipPreview_(.+)$")
	if not templateName or templateName == "" then
		skippedCount += 1
		table.insert(lines, string.format("[SKIP] %s does not match ShipPreview_<TemplateName> naming.", child.Name))
		continue
	end

	local replacement = child:Clone()
	replacement.Name = templateName
	stripRigLabels(replacement)

	local existing = assets:FindFirstChild(templateName)
	if existing then
		existing:Destroy()
	end

	replacement.Parent = assets
	appliedCount += 1
	table.insert(lines, string.format("[APPLIED] %s", templateName))
end

table.insert(lines, string.format("Done. Applied=%d Skipped=%d", appliedCount, skippedCount))
table.insert(lines, "Save/publish the place if everything looks right.")
return table.concat(lines, "\n")
