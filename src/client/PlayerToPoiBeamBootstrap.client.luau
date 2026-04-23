--!strict
-- Drives **`PlayerToPoiBeam`** from **`FtuePoiBeamConfig.Rules`** (step + optional docks sub-step → one or more POI beams).
-- Edit targets and styles in **`ReplicatedStorage.Shared.Config.FtuePoiBeamConfig`**.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local FtueConfig = require(Shared:WaitForChild("Config"):WaitForChild("FtueConfig"))
local FtuePoiBeamConfig = require(Shared:WaitForChild("Config"):WaitForChild("FtuePoiBeamConfig"))
local PlayerToPoiBeam = require(script.Parent:WaitForChild("PlayerToPoiBeam"))

local PLOT_ID_ATTRIBUTE = "PlotId"

local player = Players.LocalPlayer

local workspaceWatchConn: RBXScriptConnection? = nil
local plotWatchConn: RBXScriptConnection? = nil
local warehouseWatchConn: RBXScriptConnection? = nil
local watchNames = FtuePoiBeamConfig.collectStreamingWatchNames()

local function stopWorkspaceWatch()
	if workspaceWatchConn then
		workspaceWatchConn:Disconnect()
		workspaceWatchConn = nil
	end
end

local function stopPlotWatch()
	if plotWatchConn then
		plotWatchConn:Disconnect()
		plotWatchConn = nil
	end
end

local function stopWarehouseWatch()
	if warehouseWatchConn then
		warehouseWatchConn:Disconnect()
		warehouseWatchConn = nil
	end
end

local function normStep(any: any): string
	if typeof(any) ~= "string" then
		return ""
	end
	return (any :: string):gsub("^%s+", ""):gsub("%s+$", "")
end

-- `currentDocksSub` + the `docksSubStep` branch in `ruleApplies` were
-- deleted by Step 4 of the boat-progression refactor along with the
-- `WaitDocksUpgradeShip` FTUE leg, the `FtueDocksUpgradeSubStep`
-- attribute, and the dockman beam rule. Beam rules are now keyed only
-- by `ftueStep`; if a future leg needs sub-step gating, re-introduce a
-- fresh per-leg field on `PoiBeamStepRule` rather than reviving the old
-- one (see `FtuePoiBeamConfig` header).
local function ruleApplies(rule: any, step: string): boolean
	return rule.ftueStep == step
end

local function currentRule(): any
	local step = normStep(player:GetAttribute(Constants.FtueStepAttribute))
	for _, rule in FtuePoiBeamConfig.Rules do
		if ruleApplies(rule, step) then
			return rule
		end
	end
	return nil
end

--- Resolve the local player's plot Model (`Workspace.Map.Plots.<myPlot>`). Mirrors `init.client` logic.
local function getOwnedPlot(): Model?
	local plotId = player:GetAttribute(PLOT_ID_ATTRIBUTE)
	if typeof(plotId) ~= "number" or plotId <= 0 then
		return nil
	end
	local map = Workspace:FindFirstChild("Map")
	if not map then
		return nil
	end
	local plots = map:FindFirstChild("Plots")
	if not plots then
		return nil
	end
	for _, item in ipairs(plots:GetChildren()) do
		if item:IsA("Model") then
			local id = item:GetAttribute(PLOT_ID_ATTRIBUTE)
			if typeof(id) ~= "number" then
				id = tonumber(item.Name:match("(%d+)") or "")
			end
			if typeof(id) == "number" and id == plotId then
				return item
			end
		end
	end
	return nil
end

--- Resolve the local player's warehouse visual (`Workspace.Map.FinishPlot.Warehouse_<myUserId>`).
local function getOwnedWarehouse(): Model?
	local map = Workspace:FindFirstChild("Map")
	if not map then
		return nil
	end
	local finishPlot = map:FindFirstChild("FinishPlot")
	local expected = "Warehouse_" .. tostring(player.UserId)
	if finishPlot then
		local v = finishPlot:FindFirstChild(expected)
		if v and v:IsA("Model") then
			return v
		end
	end
	-- Fallback: warehouse may be parented directly under Workspace if FinishPlot is missing.
	local v = Workspace:FindFirstChild(expected)
	if v and v:IsA("Model") then
		return v
	end
	return nil
end

local function searchRootForTarget(t: any): Instance?
	local scope = t.searchScope
	if scope == "OwnedPlot" then
		return getOwnedPlot()
	end
	if scope == "OwnedWarehouse" then
		return getOwnedWarehouse()
	end
	return Workspace
end

local function descendantMightMatchWatch(desc: Instance): boolean
	if not desc.Name or desc.Name == "" then
		return false
	end
	for _, n in watchNames do
		if desc.Name == n and (desc:IsA("GuiObject") or desc:IsA("Model") or desc:IsA("BasePart")) then
			return true
		end
	end
	return false
end

local function refresh()
	if FtueConfig.Enabled ~= true then
		stopWorkspaceWatch()
		stopPlotWatch()
		stopWarehouseWatch()
		PlayerToPoiBeam.detachAll()
		return
	end

	local rule = currentRule()
	if not rule then
		stopWorkspaceWatch()
		stopPlotWatch()
		stopWarehouseWatch()
		PlayerToPoiBeam.detachAll()
		return
	end

	local wantedIds: { [string]: boolean } = {}
	local anyMissing = false
	local needPlotWatch = false
	local needWarehouseWatch = false

	for _, t in rule.targets do
		wantedIds[t.id] = true
		local root = searchRootForTarget(t)
		if not root then
			-- Per-player container not yet bound; skip and watch.
			PlayerToPoiBeam.detachAt(t.id)
			anyMissing = true
			if t.searchScope == "OwnedPlot" then
				needPlotWatch = true
			elseif t.searchScope == "OwnedWarehouse" then
				needWarehouseWatch = true
			end
			continue
		end
		local part = PlayerToPoiBeam.resolveFtueWorldPoi(root, t.pointerGuiName, t.modelName, t.attributeName)
		if part then
			PlayerToPoiBeam.attachAt(t.id, player, part, t.style :: any)
		else
			PlayerToPoiBeam.detachAt(t.id)
			anyMissing = true
			if t.searchScope == "OwnedWarehouse" then
				needWarehouseWatch = true
			end
		end
	end

	for _, beamId in PlayerToPoiBeam.getActiveBeamIds() do
		if not wantedIds[beamId] then
			PlayerToPoiBeam.detachAt(beamId)
		end
	end

	if anyMissing then
		if not workspaceWatchConn then
			workspaceWatchConn = Workspace.DescendantAdded:Connect(function(desc)
				if descendantMightMatchWatch(desc) then
					refresh()
				end
			end)
		end
	else
		stopWorkspaceWatch()
	end

	if needPlotWatch then
		if not plotWatchConn then
			plotWatchConn = Workspace.DescendantAdded:Connect(function(desc)
				if desc:IsA("Model") and desc.Parent and desc.Parent.Name == "Plots" then
					refresh()
				end
			end)
		end
	else
		stopPlotWatch()
	end

	if needWarehouseWatch then
		if not warehouseWatchConn then
			local expected = "Warehouse_" .. tostring(player.UserId)
			warehouseWatchConn = Workspace.DescendantAdded:Connect(function(desc)
				if desc:IsA("Model") and desc.Name == expected then
					refresh()
				end
			end)
		end
	else
		stopWarehouseWatch()
	end
end

player:GetAttributeChangedSignal(Constants.FtueStepAttribute):Connect(refresh)
-- `FtueDocksUpgradeSubStepAttribute` change-listener was deleted by
-- Step 4 of the boat-progression refactor along with the leg + the
-- attribute itself.
player:GetAttributeChangedSignal(PLOT_ID_ATTRIBUTE):Connect(refresh)

--- **Rejoin / respawn:** re-resolve the rig and reattach all beams when the
--- character (re)loads. We must wait for `HumanoidRootPart` before refreshing
--- — `CharacterAdded` fires when the Character model is parented, but the
--- HRP can be 1–2 frames behind (particularly with streaming or on rejoin).
--- If `refresh()` runs too early, `attachAt` → `_tryWireBeamChannel` finds
--- no HRP, destroys the visuals, and returns without scheduling a retry —
--- so the FTUE beams visually vanish until the next attribute change kicks
--- a refresh. Waiting on HRP makes every respawn rewire deterministically.
local function refreshAfterCharacterReady(character: Model)
	task.spawn(function()
		local hrp = character:WaitForChild("HumanoidRootPart", 10)
		if not hrp then
			return
		end
		--- `task.defer` (not `task.wait(0)`) so we run after the current
		--- replication batch, giving `_tryWireBeamChannel` a stable HRP.
		task.defer(refresh)
	end)
end

player.CharacterAdded:Connect(refreshAfterCharacterReady)
if player.Character then
	refreshAfterCharacterReady(player.Character)
end
task.defer(refresh)
