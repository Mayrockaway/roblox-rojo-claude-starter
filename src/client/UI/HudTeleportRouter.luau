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

--- Resolve the **live** Humanoid to use as `Camera.CameraSubject`. We can NOT trust the
--- existing `cam.CameraSubject` after a death-respawn because:
---
---   • `Players.CharacterAutoLoads = false` (set by `PlotService:Start()` so the server
---     can manually `LoadCharacter()` only after a plot is assigned). With auto-loads
---     off, Roblox's default PlayerModule does NOT automatically rebind the camera to
---     the freshly-created character on respawn — `Camera.CameraSubject` keeps pointing
---     at the **destroyed** corpse Humanoid (or whatever was set by the death-cam).
---
---   • If we then save that stale subject inside `snapCameraBehindCharacter`, set
---     `Scriptable`, snap to home, and after 0.05s restore the stale subject + `Custom`,
---     the engine's Custom camera tries to follow a destroyed Instance and falls back
---     to its last good CFrame — which is the **death position under the kill plane**.
---     That is the user-visible "1 frame at home, then camera reverts to death spot"
---     bug we were chasing.
---
--- Always resolve from `LocalPlayer.Character.Humanoid` at restore time.
local function getLiveHumanoid(): Humanoid?
	local char = LocalPlayer.Character
	if not char or not char.Parent then
		return nil
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum and hum.Parent and hum.Health > 0 then
		return hum
	end
	return nil
end

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
		--- Resolve the LIVE humanoid here (not before the snap) — see `getLiveHumanoid`
		--- comment. By the time this delay runs the new character/humanoid should be
		--- replicated. If it still isn't, leave whatever is there; we'll re-bind in the
		--- `CharacterAdded` watcher below.
		local liveHum = getLiveHumanoid()
		if liveHum then
			cam.CameraSubject = liveHum
		end
		cam.CameraType = Enum.CameraType.Custom
	end)
end

--- Camera-rebind on every respawn. Without this, a player who dies and respawns at
--- their home claim pad ends up with a camera locked at the **death position** (see
--- `getLiveHumanoid` comment). Press-Home / press-Town teleports recover via
--- `snapCameraBehindCharacter` — but we want the camera to recover even if the player
--- doesn't press anything.
---
--- Strategy: on `CharacterAdded`, wait for the new Humanoid + HRP to exist, then
--- forcibly set `Camera.CameraSubject` to the new humanoid and `CameraType = Custom`.
--- A small `task.delay(0.1)` lets the server-driven spawn teleport (PlotService home
--- claim pad) settle so we don't snap while the HRP is still at world origin.
local function rebindCameraToCharacter(character: Model)
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	local hum = character:WaitForChild("Humanoid", 5)
	if not hum or not hum:IsA("Humanoid") then
		return
	end
	character:WaitForChild("HumanoidRootPart", 5)
	task.wait(0.1)
	if cam.Parent == nil or hum.Parent == nil then
		return
	end
	cam.CameraSubject = hum
	cam.CameraType = Enum.CameraType.Custom
end

if LocalPlayer.Character then
	task.spawn(rebindCameraToCharacter, LocalPlayer.Character)
end
LocalPlayer.CharacterAdded:Connect(rebindCameraToCharacter)

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
