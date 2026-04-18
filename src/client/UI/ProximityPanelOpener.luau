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

local HudPanelRouter = require(script.Parent.HudPanelRouter)

local OPENS_PANEL_ATTR = "OpensPanel"

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
		end
	end)

	print("[Client] ProximityPanelOpener: listening for `OpensPanel` ProximityPrompts.")
end

return ProximityPanelOpener
