--!strict
-- Global kaching SFX on successful Robux purchases.
--
-- `MonetizationService` (server) sends `MonetizationResult` events with two
-- `ok = true` shapes:
--   * `code = "PROMPT_OPENED"` — the Roblox purchase prompt just opened
--     (NOT a successful purchase yet; user still has to confirm).
--   * `code = "OK"` — `MarketplaceService.ProcessReceipt` granted the item;
--     this is the only "money actually changed hands" outcome.
--
-- We listen once globally so any panel that fires
-- `RequestPromptRobuxPurchase` (today: `FleetPanel` boat unlocks,
-- `RobuxShopPanel`; future: `ArmyGeneralService` Robux nuke, etc.) gets
-- the SFX automatically without each panel duplicating this gating.
--
-- Cash-side equipment shop purchases are handled in `EquipmentShopPanel.luau`
-- because they ride `oilActionResult` (a multi-purpose channel where we need
-- per-handler discrimination via `data.itemId`).

local Players = game:GetService("Players")

local playerScripts = Players.LocalPlayer:WaitForChild("PlayerScripts")
local clientFolder = playerScripts:WaitForChild("Client")
local getClientRemotes = require(clientFolder:WaitForChild("GetClientRemotes")) :: () -> any
local UiSfx = require(clientFolder:WaitForChild("UiSfx")) :: {
	playKaching: () -> (),
}

local monetizationResult = getClientRemotes().monetizationResult :: RemoteEvent

monetizationResult.OnClientEvent:Connect(function(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	if payload.ok ~= true then
		return
	end
	if payload.code ~= "OK" then
		return
	end
	UiSfx.playKaching()
end)
