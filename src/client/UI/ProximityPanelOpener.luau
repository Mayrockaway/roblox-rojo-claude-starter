--!strict
-- Routes world `ProximityPrompt` triggers → modal HUD `ScreenGui` panels (toggle via `HudPanelRouter`).
--
-- Authoring contract (Studio / MCP):
--   - Add a `ProximityPrompt` to the trigger BasePart (warehouse terminal, NPC root, shop counter).
--   - Set instance attribute `OpensPanel` to the panel's `ScreenGui.Name`
--     (e.g. `SellOilPanelGui`, `ShipManagementPanelGui`, `ShopPanelGui`).
--   - For prompts inside `WarehouseTemplate`, also set `KeepProximityPrompt = true` so
--     `WarehouseService` does not strip them when cloning the warehouse per player.
--     Exception: `GateKeyPrompt` on warehouse gates is always preserved and
--     re-wired server-side (`WarehouseService:_wireWarehouseGateInteractions`).
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
--- World prompts that should teleport the player to Oil Heaven set this
--- boolean attribute. Wired on each plot's `heavengate` so stepping into the
--- gate fires the same `RequestTeleportToOilHeaven` remote that the HUD's
--- `RebirthButton` uses (see `HudTeleportRouter.luau`). Mutually exclusive
--- with `OpensPanel` — opening a panel and teleporting at the same time is
--- almost never what you want, so we short-circuit on the panel path first.
local TeleportFade = require(script.Parent:WaitForChild("TeleportFade"))
local gateFadePending = false
local TELEPORT_OIL_HEAVEN_ATTR = "TeleportsToOilHeaven"
--- Symmetric attribute for return-to-home teleports — wired on the OilHeaven
--- ANGELGATE so a player in their sky plot can step through to teleport
--- back to their main plot's ClaimPad. Fires `RequestTeleportHome` (same
--- remote the HUD's `HomeButton` uses).
local TELEPORT_HOME_ATTR = "TeleportsHome"
local FLEET_PANEL_GUI = "FleetPanelGui"

local ProximityPanelOpener = {}

local started = false

function ProximityPanelOpener.start()
	if started then
		return
	end
	started = true

	-- Fade from black when server confirms a gate teleport completed.
	local remotes = getClientRemotes()
	if remotes and remotes.teleportHomeApplied then
		remotes.teleportHomeApplied.OnClientEvent:Connect(function()
			if gateFadePending then
				gateFadePending = false
				task.spawn(function()
					TeleportFade.fadeFromBlack()
				end)
			end
		end)
	end

	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, playerWhoTriggered: Player)
		if playerWhoTriggered ~= Players.LocalPlayer then
			return
		end
		--- Teleport prompts (heavengate) take precedence over panel-opening so a
		--- prompt that's mis-authored with both attributes still produces a
		--- clean outcome (player ends up in Oil Heaven, no panel opens locally).
		if prompt:GetAttribute(TELEPORT_OIL_HEAVEN_ATTR) == true then
			local remotes = getClientRemotes()
			if remotes and remotes.requestTeleportToOilHeaven then
				task.spawn(function()
					TeleportFade.fadeToBlack()
					gateFadePending = true
					remotes.requestTeleportToOilHeaven:FireServer()
				end)
			end
			return
		end
		if prompt:GetAttribute(TELEPORT_HOME_ATTR) == true then
			local remotes = getClientRemotes()
			if remotes and remotes.requestTeleportHome then
				task.spawn(function()
					TeleportFade.fadeToBlack()
					gateFadePending = true
					remotes.requestTeleportHome:FireServer("gate")
				end)
			end
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
