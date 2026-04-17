--!strict
-- Wires `HUD.Canvas.TeleportStack` buttons → server teleport `RemoteEvent`s (no payload).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HudTriggerHover = require(script.Parent.HudTriggerHover)
local FtueTpHomePointerSignals = require(script.Parent:WaitForChild("FtueTpHomePointerSignals"))
local RemoteNames = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Net"):WaitForChild("RemoteNames"))

local BUTTON_TO_REMOTE: { [string]: string } = {
	TeleportHomeButton = RemoteNames.RequestTeleportHome,
	TeleportShipButton = RemoteNames.RequestTeleportToShip,
	TeleportWarehouseButton = RemoteNames.RequestTeleportToWarehouse,
	TeleportDocksButton = RemoteNames.RequestTeleportToDocks,
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
	print("[Client] HudTeleportRouter: start() — waiting for HUD TeleportStack + remotes…")

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
			local stack = canvas and canvas:FindFirstChild("TeleportStack")
			if not (stack and stack:IsA("Frame")) then
				task.wait(0.5)
				continue
			end

			local function findTrigger(name: string): GuiButton?
				local b = stack:FindFirstChild(name, true)
				if b and b:IsA("GuiButton") then
					return b
				end
				b = hud:FindFirstChild(name, true)
				if b and b:IsA("GuiButton") then
					return b
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
		warn("[Client] HudTeleportRouter: timed out waiting for HUD TeleportStack.")
	end)
end

return HudTeleportRouter
