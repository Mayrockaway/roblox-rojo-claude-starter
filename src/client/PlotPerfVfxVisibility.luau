--!strict

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local ClientPlotVfxPreferences = require(script.Parent:WaitForChild("ClientPlotVfxPreferences"))

local player = Players.LocalPlayer

local started = false
local plotsFolder: Instance? = nil
local plotConnections: { [Instance]: { RBXScriptConnection } } = {}
local originalEnabled: { [Instance]: boolean } = {}

local function isOtherPlayersPlot(plot: Instance): boolean
	local ownerUserId = plot:GetAttribute("OwnerUserId")
	return typeof(ownerUserId) == "number" and ownerUserId > 0 and ownerUserId ~= player.UserId
end

local function isMyPlot(plot: Instance): boolean
	return plot:GetAttribute("OwnerUserId") == player.UserId
end

local function shouldHideHeavyPlotVfx(plot: Instance): boolean
	if isMyPlot(plot) then
		return not ClientPlotVfxPreferences.isMyPlotVfxEnabled()
	end
	if isOtherPlayersPlot(plot) then
		return not ClientPlotVfxPreferences.isOtherPlayersPlotVfxEnabled()
	end
	return false
end

local function applyVisualVisibility(inst: Instance, visible: boolean)
	if inst:IsA("BasePart") then
		inst.LocalTransparencyModifier = if visible then 0 else 1
		return
	end
	if
		inst:IsA("Beam")
		or inst:IsA("Trail")
		or inst:IsA("ParticleEmitter")
		or inst:IsA("Smoke")
		or inst:IsA("Fire")
		or inst:IsA("Sparkles")
		or inst:IsA("PointLight")
		or inst:IsA("SpotLight")
		or inst:IsA("SurfaceLight")
		or inst:IsA("BillboardGui")
	then
		if originalEnabled[inst] == nil then
			originalEnabled[inst] = inst.Enabled
		end
		inst.Enabled = if visible then originalEnabled[inst] else false
	end
end

local function applyBranchVisibility(root: Instance, visible: boolean)
	if root:IsA("Folder") and root.Name:sub(1, 8) == "OilTube_" then
		root:SetAttribute("ClientTubeVfxHidden", not visible)
	end
	applyVisualVisibility(root, visible)
	for _, desc in ipairs(root:GetDescendants()) do
		applyVisualVisibility(desc, visible)
	end
end

local function refreshPlot(plot: Instance)
	local visuals = plot:FindFirstChild("OilVisuals")
	if not visuals then
		return
	end

	local visible = not shouldHideHeavyPlotVfx(plot)

	local barrels = visuals:FindFirstChild("Barrels")
	local sprays = visuals:FindFirstChild("OilSprays")
	local drills = visuals:FindFirstChild("Drills")
	local activeDrills = visuals:FindFirstChild("ActiveDrills")

	if barrels then
		applyBranchVisibility(barrels, visible)
	end

	if sprays then
		for _, child in ipairs(sprays:GetChildren()) do
			if child:IsA("Folder") and child.Name:sub(1, 8) == "OilTube_" then
				applyBranchVisibility(child, visible)
			end
		end
	end

	if drills then
		applyBranchVisibility(drills, visible)
	end

	if activeDrills then
		applyBranchVisibility(activeDrills, visible)
	end
end

local function refreshAllPlots()
	local folder = plotsFolder
	if not folder then
		return
	end
	local count = 0
	for _, child in ipairs(folder:GetChildren()) do
		if child:IsA("Model") then
			refreshPlot(child)
			count += 1
		end
	end
end

local function findOwningPlot(inst: Instance): Model?
	local cursor: Instance? = inst
	while cursor and cursor ~= plotsFolder do
		if cursor:IsA("Model") and cursor.Parent == plotsFolder then
			return cursor
		end
		cursor = cursor.Parent
	end
	return nil
end

local function isManagedHeavyVfxInstance(inst: Instance): boolean
	local cursor: Instance? = inst
	while cursor and cursor ~= plotsFolder do
		if cursor.Name == "Barrels" or cursor.Name == "Drills" or cursor.Name == "ActiveDrills" then
			return true
		end
		if cursor:IsA("Folder") and cursor.Name:sub(1, 8) == "OilTube_" then
			return true
		end
		cursor = cursor.Parent
	end
	return false
end

local function disconnectPlotConnections(plot: Instance)
	local conns = plotConnections[plot]
	if not conns then
		return
	end
	for _, conn in ipairs(conns) do
		conn:Disconnect()
	end
	plotConnections[plot] = nil
end

local function trackPlot(plot: Model)
	if plotConnections[plot] then
		return
	end
	local conns = {}
	table.insert(conns, plot:GetAttributeChangedSignal("OwnerUserId"):Connect(function()
		refreshPlot(plot)
	end))
	table.insert(conns, plot.DescendantAdded:Connect(function(inst)
		if isManagedHeavyVfxInstance(inst) then
			task.defer(function()
				if plot.Parent then
					refreshPlot(plot)
				end
			end)
		end
	end))
	table.insert(conns, plot.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			disconnectPlotConnections(plot)
		end
	end))
	plotConnections[plot] = conns
	refreshPlot(plot)
end

local PlotPerfVfxVisibility = {}

function PlotPerfVfxVisibility.start()
	if started then
		return
	end
	started = true

	plotsFolder = Workspace:WaitForChild("Map"):WaitForChild("Plots")
	local livePlotsFolder = plotsFolder :: Instance
	for _, child in ipairs(livePlotsFolder:GetChildren()) do
		if child:IsA("Model") then
			trackPlot(child)
		end
	end

	livePlotsFolder.ChildAdded:Connect(function(child)
		if child:IsA("Model") then
			trackPlot(child)
		end
	end)

	livePlotsFolder.DescendantAdded:Connect(function(inst)
		local plot = findOwningPlot(inst)
		if plot and isManagedHeavyVfxInstance(inst) then
			task.defer(function()
				if plot.Parent then
					refreshPlot(plot)
				end
			end)
		end
	end)

	ClientPlotVfxPreferences.changedSignal():Connect(function()
		refreshAllPlots()
	end)

	refreshAllPlots()
end

return PlotPerfVfxVisibility
