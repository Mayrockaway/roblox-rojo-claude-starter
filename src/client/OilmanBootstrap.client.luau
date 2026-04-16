--!strict
-- Wires Workspace.Oilman.RodgerDodger.*.OilmanDialoguePrompt → open the
-- OilmanDialoguePanel modal locally. ProximityPrompt is created server-side;
-- we only react to its `.Triggered` signal here.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local function resolvePanel(): { bind: (PlayerGui) -> any }?
	local ps = player:WaitForChild("PlayerScripts", 30)
	local clientFolder = ps and ps:FindFirstChild("Client")
	local ui = clientFolder and clientFolder:FindFirstChild("UI")
	local hudPanels = ui and ui:FindFirstChild("HudPanels")
	local modScript = hudPanels and hudPanels:FindFirstChild("OilmanDialoguePanel")
	if not (modScript and modScript:IsA("ModuleScript")) then
		warn("[OilmanBootstrap] OilmanDialoguePanel module missing.")
		return nil
	end
	local ok, loaded = pcall(require, modScript :: ModuleScript)
	if ok and typeof(loaded) == "table" then
		return loaded :: any
	end
	warn("[OilmanBootstrap] OilmanDialoguePanel failed to load:", loaded)
	return nil
end

local panel = resolvePanel()
if not panel then
	return
end

local controller = panel.bind(playerGui)
if not controller then
	warn("[OilmanBootstrap] OilmanDialoguePanel.bind returned nil; Oilman dialogue disabled.")
	return
end

local function wirePrompt(prompt: ProximityPrompt)
	prompt.Triggered:Connect(function(triggeringPlayer)
		if triggeringPlayer ~= player then
			return
		end
		controller.Open()
	end)
end

local function findAndWire()
	local oilman = Workspace:FindFirstChild("Oilman")
	if not oilman then
		return false
	end
	-- The prompt is attached to the NPC's HumanoidRootPart/Head/Torso — scan
	-- descendants so we don't depend on the exact parent part.
	for _, d in ipairs(oilman:GetDescendants()) do
		if d:IsA("ProximityPrompt") and d.Name == "OilmanDialoguePrompt" then
			wirePrompt(d)
			return true
		end
	end
	return false
end

-- First pass may miss the prompt if it hasn't replicated yet. Retry via
-- DescendantAdded until we see it.
if not findAndWire() then
	local oilman = Workspace:FindFirstChild("Oilman")
	if oilman then
		local conn: RBXScriptConnection? = nil
		conn = oilman.DescendantAdded:Connect(function(d)
			if d:IsA("ProximityPrompt") and d.Name == "OilmanDialoguePrompt" then
				wirePrompt(d)
				if conn then conn:Disconnect() end
			end
		end)
	else
		-- Entire Oilman folder hasn't streamed yet — watch workspace root.
		local conn: RBXScriptConnection? = nil
		conn = Workspace.ChildAdded:Connect(function(child)
			if child.Name == "Oilman" then
				if conn then conn:Disconnect() end
				task.defer(function()
					if not findAndWire() then
						-- Fall back to the per-folder listener.
						local subConn: RBXScriptConnection? = nil
						subConn = child.DescendantAdded:Connect(function(d)
							if d:IsA("ProximityPrompt") and d.Name == "OilmanDialoguePrompt" then
								wirePrompt(d)
								if subConn then subConn:Disconnect() end
							end
						end)
					end
				end)
			end
		end)
	end
end
