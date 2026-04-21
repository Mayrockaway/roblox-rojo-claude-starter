--!strict
-- Wires HUD teleport buttons → server teleport `RemoteEvent`s (no payload).
-- All buttons live in `HUD.Canvas.Buttons` (right-side grid):
--   `BuyButton`, `SellButton`, `HomeButton`, `ShipButton`, `HireButton`
-- DAILY / SETTINGS in `Canvas.Buttons` open modal panels via `HudPanelRouter` (not here).
--
-- Also owns the **camera snap on `TeleportHomeApplied`**: when the server pivots the character
-- on a Home teleport, the default follow camera keeps its internal yaw (so the player ends up
-- looking at the back of their own head). On the server signal we briefly switch to
-- `Scriptable`, place the camera behind the character on the pad's LookVector, then hand back
-- to `Custom` so the PlayerModule re-initializes from the new CFrame.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local HudTriggerHover = require(script.Parent.HudTriggerHover)
local FtueTpHomePointerSignals = require(script.Parent:WaitForChild("FtueTpHomePointerSignals"))
local RemoteNames = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Net"):WaitForChild("RemoteNames"))
local getClientRemotes = require(script.Parent.Parent:WaitForChild("GetClientRemotes")) :: () -> any
local ClientRemotes = getClientRemotes()

local LocalPlayer = Players.LocalPlayer

--- Distance the camera sits behind the character after a Home teleport. Tuned to match the
--- default Roblox follow camera's typical eye-distance so the snap is barely perceptible
--- (it just rotates around the character, the zoom level stays familiar).
local CAMERA_BEHIND_DISTANCE = 14
local CAMERA_HEAD_OFFSET = Vector3.new(0, 2, 0)

local function snapCameraBehindCharacter(targetCFrame: CFrame)
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	local char = LocalPlayer.Character
	local hrp: BasePart? = if char then char:FindFirstChild("HumanoidRootPart") :: BasePart? else nil
	--- Anchor on the server-authoritative target CFrame (we may receive this packet before the
	--- replicated HRP CFrame catches up on the client). Use HRP only as a refinement.
	local focal = targetCFrame.Position + CAMERA_HEAD_OFFSET
	local look = targetCFrame.LookVector
	if hrp then
		focal = hrp.Position + CAMERA_HEAD_OFFSET
		look = hrp.CFrame.LookVector
	end
	local desiredPos = focal - look * CAMERA_BEHIND_DISTANCE + Vector3.new(0, 3, 0)

	local subject = cam.CameraSubject
	cam.CameraType = Enum.CameraType.Scriptable
	cam.CFrame = CFrame.lookAt(desiredPos, focal)
	cam.Focus = CFrame.new(focal)

	--- Two-frame interlude: the PlayerModule's CameraInput reads `Camera.CFrame` when it
	--- transitions back into `Custom` and uses that as its new yaw/pitch baseline. One frame
	--- is usually enough; two is belt-and-suspenders against a missed Heartbeat tick.
	task.delay(0.05, function()
		if cam.Parent == nil then
			return
		end
		cam.CameraSubject = subject
		cam.CameraType = Enum.CameraType.Custom
	end)
end

ClientRemotes.teleportHomeApplied.OnClientEvent:Connect(function(targetCFrame)
	if typeof(targetCFrame) ~= "CFrame" then
		return
	end
	snapCameraBehindCharacter(targetCFrame)
end)

-- Each entry maps a HUD button name to the *typed* RemoteEvent on `ClientRemotes`.
-- Keeping it as a function table (not a name string) means a typo here is a *type*
-- error at module-load time instead of a silent `WaitForChild` timeout at runtime.
local BUTTON_TO_REMOTE: { [string]: RemoteEvent } = {
	BuyButton = ClientRemotes.requestTeleportToDocks,         -- "front of Shop" = DocksTeleportTarget
	SellButton = ClientRemotes.requestTeleportToWarehouse,    -- player warehouse spawn
	HomeButton = ClientRemotes.requestTeleportHome,
	ShipButton = ClientRemotes.requestTeleportToShip,
	HireButton = ClientRemotes.requestTeleportToHire,         -- Workspace.HireTeleportTarget
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

function HudTeleportRouter.start(playerGui: PlayerGui)
	if started then
		return
	end
	print("[Client] HudTeleportRouter: start() — waiting for HUD Canvas…")

	task.spawn(function()
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
			if not (canvas and canvas:IsA("Frame")) then
				task.wait(0.5)
				continue
			end
			local buttonsFrame = canvas:FindFirstChild("Buttons")

			local function findTrigger(name: string): GuiButton?
				-- Search order:
				--   1. `Buttons` grid   — primary location for all teleport buttons
				--   2. recursive HUD    — fallback for any future relocation
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
			for buttonName, remote in pairs(BUTTON_TO_REMOTE) do
				local btn = findTrigger(buttonName)
				if not (btn and btn:IsA("GuiButton")) then
					warn("[Client] HudTeleportRouter: missing button", buttonName)
					continue
				end
				wireTrigger(btn, remote)
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
