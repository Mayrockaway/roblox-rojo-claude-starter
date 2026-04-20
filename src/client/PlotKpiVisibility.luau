--!strict

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer

local OWN_PLOT_KPI_SHOW_DISTANCE = 180
local UPDATE_INTERVAL = 0.2

local PlotKpiVisibility = {}

local started = false
local accum = 0
local managedBillboards: { [BillboardGui]: true } = {}

local function getCharacterRoot(): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function isManagedKpiBillboard(inst: Instance): boolean
	if not inst:IsA("BillboardGui") or inst.Name ~= "HoloGui" then
		return false
	end
	local parent = inst.Parent
	if not parent then
		return false
	end
	if parent.Name == "PumpHologram" then
		return true
	end
	return string.sub(parent.Name, 1, 9) == "TankHolo_"
end

local function findOwnerPlot(inst: Instance): Model?
	local cursor: Instance? = inst
	while cursor do
		if cursor:IsA("Model") then
			local ownerUserId = cursor:GetAttribute("OwnerUserId")
			if typeof(ownerUserId) == "number" and ownerUserId > 0 then
				return cursor
			end
		end
		cursor = cursor.Parent
	end
	return nil
end

local function getBillboardWorldPosition(billboard: BillboardGui): Vector3?
	local adornee = billboard.Adornee
	if adornee and adornee:IsA("BasePart") then
		return adornee.Position
	end
	local parent = billboard.Parent
	if parent and parent:IsA("BasePart") then
		return parent.Position
	end
	return nil
end

local function shouldEnableBillboard(billboard: BillboardGui, root: BasePart?): boolean
	if not root then
		return false
	end
	local plot = findOwnerPlot(billboard)
	if not plot then
		return false
	end
	if plot:GetAttribute("OwnerUserId") ~= player.UserId then
		return false
	end
	local worldPos = getBillboardWorldPosition(billboard)
	if not worldPos then
		return false
	end
	return (worldPos - root.Position).Magnitude <= OWN_PLOT_KPI_SHOW_DISTANCE
end

local function refresh()
	local root = getCharacterRoot()
	for billboard in pairs(managedBillboards) do
		if billboard.Parent == nil then
			managedBillboards[billboard] = nil
		else
			local enabled = shouldEnableBillboard(billboard, root)
			if billboard.Enabled ~= enabled then
				billboard.Enabled = enabled
			end
		end
	end
end

local function trackIfManaged(inst: Instance)
	if isManagedKpiBillboard(inst) then
		managedBillboards[inst :: BillboardGui] = true
	end
end

function PlotKpiVisibility.start()
	if started then
		return
	end
	started = true

	for _, inst in ipairs(Workspace:GetDescendants()) do
		trackIfManaged(inst)
	end
	Workspace.DescendantAdded:Connect(trackIfManaged)
	Workspace.DescendantRemoving:Connect(function(inst)
		if inst:IsA("BillboardGui") then
			managedBillboards[inst] = nil
		end
	end)
	refresh()
	RunService.Heartbeat:Connect(function(dt)
		accum += dt
		if accum < UPDATE_INTERVAL then
			return
		end
		accum = 0
		refresh()
	end)
end

return PlotKpiVisibility
