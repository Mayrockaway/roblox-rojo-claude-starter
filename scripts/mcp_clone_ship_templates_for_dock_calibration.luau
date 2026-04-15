--[[
	Run in Roblox Studio (Command Bar or MCP `execute_luau`) to create editable ship previews.

	What it does:
	- Reads all unique `templateName` values from `Shared.Config.ShipSkinCatalog`.
	- Clones each ship template from `ReplicatedStorage.Assets` into:
	  `Workspace.Map.ShipRigCalibration.ShipTemplatePreviews`
	- Anchors preview parts and lays ships out in a grid for easy editing.
	- Adds visible labels on required rig points (DockAnchor, FRONT_MARKER, DeckSeat, etc.).
	- Prints and returns a summary including missing required rig points per template.

	After you reposition anchors/markers:
	- Copy the adjusted objects back into `ReplicatedStorage.Assets.<TemplateName>`.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ShipSkinCatalog = require(Shared:WaitForChild("Config"):WaitForChild("ShipSkinCatalog"))
local ShipRig = require(Shared:WaitForChild("Utils"):WaitForChild("ShipRig"))

local function uniqueTemplateNamesFromCatalog(): { string }
	local seen = {}
	local names = {}
	for _, def in pairs(ShipSkinCatalog.Skins) do
		if typeof(def) == "table" then
			local templateName = def.templateName
			if typeof(templateName) == "string" and templateName ~= "" and not seen[templateName] then
				seen[templateName] = true
				table.insert(names, templateName)
			end
		end
	end
	if not seen.Tanker then
		table.insert(names, 1, "Tanker")
	end
	table.sort(names)
	return names
end

local function ensureFolder(parent: Instance, name: string): Folder
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local f = Instance.new("Folder")
	f.Name = name
	f.Parent = parent
	return f
end

local function makeLabel(host: Instance, text: string, color: Color3)
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "RigLabel_" .. text
	billboard.Size = UDim2.fromOffset(240, 42)
	billboard.StudsOffset = Vector3.new(0, 2.5, 0)
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.ResetOnSpawn = false
	billboard.Parent = host

	local bg = Instance.new("Frame")
	bg.Name = "Bg"
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = Color3.fromRGB(15, 18, 24)
	bg.BackgroundTransparency = 0.2
	bg.BorderSizePixel = 0
	bg.Parent = billboard

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 1.5
	stroke.Color = color
	stroke.Parent = bg

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = bg

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = color
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextWrapped = true
	label.Parent = bg

	local textConstraint = Instance.new("UITextSizeConstraint")
	textConstraint.MinTextSize = 8
	textConstraint.MaxTextSize = 18
	textConstraint.Parent = label
end

local function clearRigLabels(root: Instance)
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BillboardGui") and string.sub(d.Name, 1, 9) == "RigLabel_" then
			d:Destroy()
		end
	end
end

local function cloneAsModel(template: Instance): Model
	local c = template:Clone()
	if c:IsA("Model") then
		return c
	end
	local wrap = Instance.new("Model")
	wrap.Name = template.Name
	c.Parent = wrap
	return wrap
end

local function firstBasePart(model: Model): BasePart?
	if model.PrimaryPart then
		return model.PrimaryPart
	end
	return model:FindFirstChildWhichIsA("BasePart", true)
end

local function anchorModel(model: Model)
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = true
		end
	end
end

local function labelRigPoints(model: Model, templateName: string): { string }, { string }
	local rig = ShipSkinCatalog.GetRigForTemplate(templateName)
	local missingRequired = {}
	local missingOptional = {}

	local required = {
		{ name = rig.dockAnchorName, kind = "Attachment", label = "DockAnchor (Attachment)" },
		{ name = rig.frontMarkerName, kind = "BasePart", label = "Front Marker (BasePart)" },
		{ name = rig.deckSeatName, kind = "Seat", label = "Deck Seat (Seat)" },
		{ name = rig.barrelStackRootName, kind = "BasePart", label = "Barrel Stack Root (BasePart)" },
		{ name = rig.playerFlagName, kind = "BasePart", label = "Player Flag (BasePart)" },
	}

	local optional = {
		{ name = rig.deckAnchorName, kind = "Attachment", label = "Deck Anchor (Attachment)" },
	}

	for _, item in ipairs(required) do
		local inst: Instance? = nil
		if item.kind == "Attachment" then
			inst = ShipRig.FindAttachment(model, item.name)
		elseif item.kind == "Seat" then
			inst = ShipRig.FindSeat(model, item.name)
		else
			inst = ShipRig.FindBasePart(model, item.name)
		end
		if inst then
			makeLabel(inst, item.label .. " [" .. item.name .. "]", Color3.fromRGB(86, 255, 159))
		else
			table.insert(missingRequired, item.name .. " (" .. item.kind .. ")")
		end
	end

	for _, item in ipairs(optional) do
		local inst: Instance? = nil
		if item.kind == "Attachment" then
			inst = ShipRig.FindAttachment(model, item.name)
		elseif item.kind == "Seat" then
			inst = ShipRig.FindSeat(model, item.name)
		else
			inst = ShipRig.FindBasePart(model, item.name)
		end
		if inst then
			makeLabel(inst, item.label .. " [" .. item.name .. "]", Color3.fromRGB(126, 206, 255))
		else
			table.insert(missingOptional, item.name .. " (" .. item.kind .. ")")
		end
	end

	return missingRequired, missingOptional
end

local map = Workspace:FindFirstChild("Map")
local rootParent: Instance = if map then map else Workspace
local calibrationFolder = ensureFolder(rootParent, "ShipRigCalibration")
local previewFolder = ensureFolder(calibrationFolder, "ShipTemplatePreviews")
previewFolder:ClearAllChildren()

local assets = ReplicatedStorage:FindFirstChild("Assets")
if not assets then
	return "ERROR: ReplicatedStorage.Assets missing."
end

local templateNames = uniqueTemplateNamesFromCatalog()
local lines = {}
table.insert(lines, string.format("Ship rig preview clone start. templates=%d", #templateNames))
table.insert(lines, "Target folder: " .. previewFolder:GetFullName())

local origin = Vector3.new(0, 12, 0)
local spacingX = 230
local spacingZ = 260
local cols = 3

for i, templateName in ipairs(templateNames) do
	local template = assets:FindFirstChild(templateName)
	if not template then
		table.insert(lines, string.format("[MISSING TEMPLATE] %s (not found under ReplicatedStorage.Assets)", templateName))
		continue
	end
	if not (template:IsA("Model") or template:IsA("BasePart")) then
		table.insert(lines, string.format("[SKIP] %s exists but is %s (expected Model/BasePart)", templateName, template.ClassName))
		continue
	end

	local clone = cloneAsModel(template)
	clone.Name = string.format("ShipPreview_%s", templateName)
	clearRigLabels(clone)
	anchorModel(clone)

	local row = math.floor((i - 1) / cols)
	local col = (i - 1) % cols
	local targetPos = origin + Vector3.new(col * spacingX, 0, row * spacingZ)
	clone:PivotTo(CFrame.new(targetPos))
	clone.Parent = previewFolder

	local root = firstBasePart(clone)
	if root then
		makeLabel(root, "Template: " .. templateName, Color3.fromRGB(255, 226, 122))
	end

	local missingRequired, missingOptional = labelRigPoints(clone, templateName)
	if #missingRequired == 0 and #missingOptional == 0 then
		table.insert(lines, string.format("[OK] %s", templateName))
	elseif #missingRequired == 0 then
		table.insert(lines, string.format(
			"[WARN] %s optional missing: %s",
			templateName,
			table.concat(missingOptional, ", ")
		))
	else
		table.insert(lines, string.format(
			"[ERROR] %s required missing: %s%s",
			templateName,
			table.concat(missingRequired, ", "),
			if #missingOptional > 0 then " | optional missing: " .. table.concat(missingOptional, ", ") else ""
		))
	end
end

table.insert(lines, "Done. Move anchors/markers in ShipRigCalibration, then copy back to ReplicatedStorage.Assets templates.")
return table.concat(lines, "\n")
