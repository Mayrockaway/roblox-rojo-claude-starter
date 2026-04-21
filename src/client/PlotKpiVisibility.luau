--!strict

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer

local OWN_PLOT_KPI_SHOW_DISTANCE = 180
local UPDATE_INTERVAL = 0.2

-- Both pump and tank billboards scale UP with camera distance so they stay
-- readable from across the plot. 1x at close range, up to 2x at the far edge.
local SCALE_NEAR_DIST = 20   -- studs: 1x below this
local SCALE_FAR_DIST  = 120  -- studs: 2x at this distance and beyond
local SCALE_MIN = 1.0
local SCALE_MAX = 2.0

local PlotKpiVisibility = {}

local started = false
local accum = 0
local managedBillboards: { [BillboardGui]: true } = {}
-- Store each billboard's original pixel size (captured on first tick).
local originalSizes: { [BillboardGui]: { w: number, h: number } } = {}

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
	local cam = Workspace.CurrentCamera
	local camPos = cam and cam.CFrame.Position or Vector3.zero
	for billboard in pairs(managedBillboards) do
		if billboard.Parent == nil then
			managedBillboards[billboard] = nil
			originalSizes[billboard] = nil
		else
			local enabled = shouldEnableBillboard(billboard, root)
			if billboard.Enabled ~= enabled then
				billboard.Enabled = enabled
			end
			-- Scale UP with camera distance: 1x close, lerp to 2x at plot edge.
			if enabled and cam then
				local orig = originalSizes[billboard]
				if not orig then
					local sz = billboard.Size
					orig = { w = sz.X.Offset, h = sz.Y.Offset }
					if orig.w > 0 and orig.h > 0 then
						originalSizes[billboard] = orig
					else
						continue
					end
				end
				local worldPos = getBillboardWorldPosition(billboard)
				if worldPos then
					local dist = (camPos - worldPos).Magnitude
					local t = math.clamp((dist - SCALE_NEAR_DIST) / (SCALE_FAR_DIST - SCALE_NEAR_DIST), 0, 1)
					local scale = SCALE_MIN + t * (SCALE_MAX - SCALE_MIN)
					local newSize = UDim2.new(0, math.round(orig.w * scale), 0, math.round(orig.h * scale))
					if billboard.Size ~= newSize then
						billboard.Size = newSize
					end
				end
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
