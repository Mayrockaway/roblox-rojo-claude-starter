--!strict
-- Shows a one-shot gold notification on the shared shipment-hint line whenever
-- the equipment shop's rotating stock just refreshed (server-side
-- `EquipmentShopService:_rollShopStock` → `EquipmentShopStockUpdate` with
-- `reason = "rotation"`). The same broadcast also fires on every successful
-- purchase — `reason` is `nil` in that case so we don't pop a banner per buy.
--
-- Display contract (matches the contractor "your hit landed" alert in
-- `PirateHireClient`):
--   * `ClientPlotGrid.setStatusLocked(message, GOLD, HOLD_SECONDS)` paints the
--     `ShipmentProgressPanel.Hint` text in bright gold and locks the line so
--     cruise dots / drilling chatter cannot clobber it for the hold window.
--   * `ensureBlackTextStroke` adds a 2px black `UIStroke` (round joins) to the
--     Hint TextLabel so the gold reads cleanly against any background. The
--     stroke is idempotent and tweens with the existing
--     `ClientPlotGrid.scheduleHintFade` machinery (it iterates `UIStroke`
--     children of the line and fades them with the text — see
--     `ClientPlotGrid.luau` § shipment-hint auto-fade).
--
-- Started from `init.client.luau` once `ClientPlotGrid` is loaded.

local Players = game:GetService("Players")

local HOLD_SECONDS = 5
local GOLD = Color3.fromRGB(255, 200, 60)
local STROKE_NAME = "ShipmentHintBlackStroke"
local MESSAGE = "Equipment shop just refreshed!"

export type Deps = {
	--- Resolved by `ClientPlotGrid` (same helper used by `PirateHireClient` for
	--- gold contractor alerts). Required.
	setStatusLocked: (message: string, color: Color3, holdSeconds: number) -> (),
	--- The `EquipmentShopStockUpdate` `RemoteEvent` resolved by `ClientRemotes`
	--- (`Remotes.equipmentShopStockUpdate`). Re-using the existing wait avoids
	--- a second `WaitForChild` race against `RemoteService:Init()`.
	stockUpdateEvent: RemoteEvent,
}

local ShopRefreshNotification = {}

local started = false

--- Walks `PlayerGui` for the live `ShipmentProgressPanel.Hint` TextLabel /
--- TextButton. We don't cache it because Studio rebuilds + `ShipmentProgressHud`
--- runtime fallbacks can recreate the label; resolving on demand stays cheap
--- (called at most once per shop rotation, ~3 minutes apart).
local function resolveHintLine(): (TextLabel | TextButton)?
	local lp = Players.LocalPlayer
	if not lp then
		return nil
	end
	local pg = lp:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return nil
	end
	local panel = pg:FindFirstChild("ShipmentProgressPanel", true)
	if not panel then
		return nil
	end
	local hint = panel:FindFirstChild("Hint", true)
	if hint and (hint:IsA("TextLabel") or hint:IsA("TextButton")) then
		return hint :: any
	end
	if hint then
		local inner = hint:FindFirstChildWhichIsA("TextLabel", true)
			or hint:FindFirstChildWhichIsA("TextButton", true)
		if inner then
			return inner :: any
		end
	end
	return nil
end

--- Idempotent — only adds the stroke if it's not already present. Same Thickness
--- / Color / LineJoinMode pattern as the lootbox NEXT button stroke (see
--- `VeinCrateOpener.luau`) so legibility reads consistently across the HUD.
local function ensureBlackTextStroke(line: TextLabel | TextButton)
	local existing = line:FindFirstChild(STROKE_NAME)
	if existing and existing:IsA("UIStroke") then
		return
	end
	local stroke = Instance.new("UIStroke")
	stroke.Name = STROKE_NAME
	stroke.Thickness = 2
	stroke.Color = Color3.fromRGB(0, 0, 0)
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	stroke.Transparency = 0
	stroke.Parent = line
end

local function showRefreshBanner(deps: Deps)
	local line = resolveHintLine()
	if line then
		ensureBlackTextStroke(line)
	end
	deps.setStatusLocked(MESSAGE, GOLD, HOLD_SECONDS)
end

function ShopRefreshNotification.start(deps: Deps)
	if started then
		return
	end
	if typeof(deps) ~= "table" or typeof(deps.setStatusLocked) ~= "function" then
		warn("[Client] ShopRefreshNotification.start: missing `setStatusLocked` dep — banner disabled.")
		return
	end
	local stockUpdate = deps.stockUpdateEvent
	if typeof(stockUpdate) ~= "Instance" or not stockUpdate:IsA("RemoteEvent") then
		warn("[Client] ShopRefreshNotification.start: missing `stockUpdateEvent` dep — banner disabled.")
		return
	end
	started = true

	stockUpdate.OnClientEvent:Connect(function(msg: any)
		if typeof(msg) ~= "table" then
			return
		end
		if tostring(msg.reason) ~= "rotation" then
			return
		end
		showRefreshBanner(deps)
	end)
end

return ShopRefreshNotification
