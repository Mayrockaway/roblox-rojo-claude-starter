--!strict
-- Wires HUD teleport buttons → server teleport `RemoteEvent`s (no payload).
-- Buttons live in two authored regions of `HUD.Canvas`:
--   * `TeleportStack`           → `TeleportHomeButton`, `TeleportShipButton`
--   * `Buttons` (right-side grid) → `BuyButton`, `SellButton`, `HireButton`
-- DAILY / SETTINGS / RobuxShop in the same `Buttons` grid open modal panels and
-- are wired by `HudPanelRouter`, not here.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HudTriggerHover = require(script.Parent.HudTriggerHover)
local FtueTpHomePointerSignals = require(script.Parent:WaitForChild("FtueTpHomePointerSignals"))
local RemoteNames = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Net"):WaitForChild("RemoteNames"))

local BUTTON_TO_REMOTE: { [string]: string } = {
	TeleportHomeButton = RemoteNames.RequestTeleportHome,
	TeleportShipButton = RemoteNames.RequestTeleportToShip,
	BuyButton = RemoteNames.RequestTeleportToDocks,        -- "front of Shop" = DocksTeleportTarget
	SellButton = RemoteNames.RequestTeleportToWarehouse,   -- player warehouse spawn
	HireButton = RemoteNames.RequestTeleportToHire,        -- Workspace.HireTeleportTarget
}

local HudTeleportRouter = {}

local started = false

local function passthroughDecorationsToTrigger(btn: GuiButton)
	for _, d in ipairs(btn:GetDescendants()) do
		if d:IsA("GuiObject") and not d:IsA("GuiButton") then
			d.Active = false
		end
	end
end

local function waitRemotesFolder(): Folder?
	local shared = ReplicatedStorage:WaitForChild("Shared", 60)
	if not shared then
		return nil
	end
	return shared:WaitForChild("Remotes", 60) :: Folder?
end

function HudTeleportRouter.start(playerGui: PlayerGui)
	if started then
		return
	end
	print("[Client] HudTeleportRouter: start() — waiting for HUD Canvas + remotes…")

	task.spawn(function()
		local remotesFolder = waitRemotesFolder()
		if not remotesFolder then
			warn("[Client] HudTeleportRouter: Shared.Remotes not found.")
			return
		end

		local events: { [string]: RemoteEvent } = {}
		for _, remoteName in pairs(BUTTON_TO_REMOTE) do
			local ev = remotesFolder:WaitForChild(remoteName, 30)
			if ev and ev:IsA("RemoteEvent") then
				events[remoteName] = ev
			else
				warn("[Client] HudTeleportRouter: missing RemoteEvent", remoteName)
			end
		end

		for attempt = 1, 120 do
			if started then
				return
			end
			local hud = playerGui:FindFirstChild("HUD")
			if not (hud and hud:IsA("ScreenGui")) then
				task.wait(0.5)
				continue
			end
			local canvas = hud:FindFirstChild("Canvas")
			-- We only require `Canvas` here. `TeleportStack` (legacy left-side stack) and the
			-- new `Buttons` grid are each consulted in `findTrigger`; either may be missing.
			if not (canvas and canvas:IsA("Frame")) then
				task.wait(0.5)
				continue
			end
			local stack = canvas:FindFirstChild("TeleportStack")
			local buttonsFrame = canvas:FindFirstChild("Buttons")

			local function findTrigger(name: string): GuiButton?
				-- Search order:
				--   1. `TeleportStack`  — TeleportHomeButton / TeleportShipButton
				--   2. `Buttons` grid   — BuyButton / SellButton / HireButton
				--   3. recursive HUD   — fallback for any future relocation
				if stack and stack:IsA("GuiObject") then
					local b = stack:FindFirstChild(name, true)
					if b and b:IsA("GuiButton") then
						return b :: GuiButton
					end
				end
				if buttonsFrame and buttonsFrame:IsA("GuiObject") then
					local b = buttonsFrame:FindFirstChild(name, true)
					if b and b:IsA("GuiButton") then
						return b :: GuiButton
					end
				end
				local fb = hud:FindFirstChild(name, true)
				if fb and fb:IsA("GuiButton") then
					return fb :: GuiButton
				end
				return nil
			end

			local function wireTrigger(btn: GuiButton, remote: RemoteEvent)
				passthroughDecorationsToTrigger(btn)
				local armed = false
				local function onPress()
					if armed then
						return
					end
					armed = true
					task.defer(function()
						armed = false
					end)
					remote:FireServer()
					if remote.Name == RemoteNames.RequestTeleportHome then
						FtueTpHomePointerSignals.fireTeleportHomePressed()
					end
				end
				btn.Activated:Connect(onPress)
				btn.MouseButton1Click:Connect(onPress)
				HudTriggerHover.attach(btn)
			end

			local wired = 0
			for buttonName, remoteName in pairs(BUTTON_TO_REMOTE) do
				local btn = findTrigger(buttonName)
				local ev = events[remoteName]
				if not (btn and btn:IsA("GuiButton")) then
					warn("[Client] HudTeleportRouter: missing button", buttonName)
					continue
				end
				if not ev then
					warn("[Client] HudTeleportRouter: missing event for", remoteName)
					continue
				end
				wireTrigger(btn, ev)
				wired += 1
			end

			if wired == 0 then
				if attempt == 1 or attempt % 10 == 0 then
					print("[Client] HudTeleportRouter: retry wired=0 attempt=", attempt)
				end
				task.wait(0.5)
				continue
			end

			started = true
			print("[Client] HudTeleportRouter: teleport buttons wired (" .. tostring(wired) .. ").")
			return
		end
		warn("[Client] HudTeleportRouter: timed out waiting for HUD Canvas / teleport buttons.")
	end)
end

return HudTeleportRouter
