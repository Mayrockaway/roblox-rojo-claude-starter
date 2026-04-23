--!strict
-- Routes world `ProximityPrompt` triggers → modal HUD `ScreenGui` panels (toggle via `HudPanelRouter`).
--
-- Authoring contract (Studio / MCP):
--   - Add a `ProximityPrompt` to the trigger BasePart (warehouse terminal, NPC root, shop counter).
--   - Set instance attribute `OpensPanel` to the panel's `ScreenGui.Name`
--     (e.g. `SellOilPanelGui`, `ShipManagementPanelGui`, `ShopPanelGui`).
--   - For prompts inside `WarehouseTemplate`, also set `KeepProximityPrompt = true` so
--     `WarehouseService` does not strip them when cloning the warehouse per player.
--
-- This module never calls `Instance.new` into `StarterGui` and never wires HUD buttons —
-- it only forwards the trigger to `HudPanelRouter.openScreen(screenName)`. Per
-- `ui-architecture.mdc` §6 (clicks/input → behavior), §9 (world UI is exempt from
-- the StarterGui authoring policy).

local ProximityPromptService = game:GetService("ProximityPromptService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- `Constants` / `FtueConfig` / `getClientRemotes` requires are needed
-- again for the `WaitDocksFleetPanel` → `FleetPanelOpened` FTUE bridge
-- (replaces the deleted `ShipManagementPanelGui` → `DockmanOpened` one).
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local FtueConfig = require(Shared:WaitForChild("Config"):WaitForChild("FtueConfig"))
local HudPanelRouter = require(script.Parent.HudPanelRouter)
local getClientRemotes = require(script.Parent.Parent:WaitForChild("GetClientRemotes")) :: () -> any

local OPENS_PANEL_ATTR = "OpensPanel"
local FLEET_PANEL_GUI = "FleetPanelGui"

local ProximityPanelOpener = {}

local started = false

function ProximityPanelOpener.start()
	if started then
		return
	end
	started = true

	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, playerWhoTriggered: Player)
		if playerWhoTriggered ~= Players.LocalPlayer then
			return
		end
		local screenName = prompt:GetAttribute(OPENS_PANEL_ATTR)
		if typeof(screenName) ~= "string" or screenName == "" then
			return
		end
		local ok = HudPanelRouter.openScreen(screenName)
		if not ok then
			warn(
				"[Client] ProximityPanelOpener: no panel registered for screenName=",
				screenName,
				"prompt=",
				prompt:GetFullName()
			)
			return
		end
		--- Fleet-panel FTUE leg bridge (replaces the deleted
		--- `ShipManagementPanelGui` → `DockmanOpened` bridge). When the
		--- dockman prox prompt opens `FleetPanelGui` and the player is on
		--- `WaitDocksFleetPanel` + sub `OpenPanel`, fire `FleetPanelOpened`
		--- so the server flips the sub-step to `ClosePanel` and the
		--- `CloseButtonPointerRoot` lights up inside the modal. Server
		--- re-validates step + sub-step (see
		--- `FtueService.OnFtueDocksProgress`) so this fire is harmless
		--- outside the FTUE.
		if screenName == FLEET_PANEL_GUI then
			local plr = Players.LocalPlayer
			if
				plr
				and plr:GetAttribute(Constants.FtueStepAttribute) == FtueConfig.Step.WaitDocksFleetPanel
				and plr:GetAttribute(Constants.FtueDocksFleetPanelSubStepAttribute) == "OpenPanel"
			then
				local remotes = getClientRemotes()
				if remotes and remotes.requestFtueDocksProgress then
					remotes.requestFtueDocksProgress:FireServer("FleetPanelOpened")
				end
			end
		end
	end)

	if RunService:IsStudio() then
		print("[Client] ProximityPanelOpener: listening for `OpensPanel` ProximityPrompts.")
	end
end

return ProximityPanelOpener
