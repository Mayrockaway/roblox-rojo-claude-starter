--!strict
--- ResponsiveScreenScale
---
--- Cross-platform sizing for **runtime-built `ScreenGui` panels** (NPC
--- dialogues like `ArmyGeneralGui` / `PirateHireGui`, the `VeinCrateOpener`
--- spinner, etc.) — the `ScreenGui` analog of `ResponsiveBillboard`.
---
--- ### Why this exists
---
--- Several runtime panels in this project are built with `Frame.Size =
--- UDim2.fromOffset(W, H)` because their layout is pixel-precise (icon stacks,
--- multi-column buttons, fixed gutters). On a 1366 × 768 desktop a 520 × 420
--- panel is comfortable; on a 750 × 420 phone it overflows the viewport,
--- buttons get truncated, and the dialogue is unusable.
---
--- ### How this works
---
--- 1. Build the panel at its design-target offset size as usual.
--- 2. Call `Attach(rootFrame, refW, refH, fitFraction?)` once after parenting:
---    * Creates a `UIScale` named `ResponsiveScreenScale` as a child of `root`.
---    * Computes `scale = min(1, min((vp.X * fit) / refW, (vp.Y * fit) / refH))`
---      so the panel only ever shrinks (never grows past the authored size).
---    * Re-applies on every `Camera.ViewportSize` change (window resize,
---      device rotation, Studio device emulator) and detaches when the panel
---      tears down (the parent `ScreenGui` is destroyed).
---
--- ### Default `fitFraction`
---
--- `0.85` — leaves ~15% margin so the panel is comfortably inset from the
--- viewport edges on phones (avoids notches, system gestures, the bottom
--- mobile nav inset). Override per-panel when needed (e.g. the lootbox
--- spinner uses `0.92` to feel cinematic).
---
--- ### Server vs client
---
--- Client-only — the camera viewport doesn't exist server-side. Calling
--- `Attach` from the server is a no-op and emits no warning (so server-shared
--- code paths can call it unconditionally).

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local ResponsiveScreenScale = {}

ResponsiveScreenScale.DEFAULT_FIT_FRACTION = 0.85

local SCALE_NAME = "ResponsiveScreenScale"

--- Attach a viewport-aware `UIScale` to `root`. Returns the `UIScale`
--- (created or pre-existing) so callers that want to read / animate `Scale`
--- can do so. Idempotent — calling twice on the same root replaces nothing,
--- it just re-binds the camera signal.
function ResponsiveScreenScale.Attach(
	root: GuiObject,
	refW: number,
	refH: number,
	fitFraction: number?
): UIScale?
	if not root or not root:IsA("GuiObject") then
		return nil
	end
	if RunService:IsServer() and not RunService:IsClient() then
		return nil
	end

	local fit = fitFraction or ResponsiveScreenScale.DEFAULT_FIT_FRACTION

	local existing = root:FindFirstChild(SCALE_NAME)
	local scale: UIScale
	if existing and existing:IsA("UIScale") then
		scale = existing
	else
		if existing then
			existing:Destroy()
		end
		scale = Instance.new("UIScale")
		scale.Name = SCALE_NAME
		scale.Scale = 1
		scale.Parent = root
	end

	local function apply()
		local cam = Workspace.CurrentCamera
		if not cam then
			return
		end
		local vp = cam.ViewportSize
		if vp.X <= 0 or vp.Y <= 0 then
			return
		end
		local sx = (vp.X * fit) / refW
		local sy = (vp.Y * fit) / refH
		scale.Scale = math.min(1, math.min(sx, sy))
	end

	apply()

	local cam = Workspace.CurrentCamera
	local viewportConn: RBXScriptConnection? = nil
	if cam then
		viewportConn = cam:GetPropertyChangedSignal("ViewportSize"):Connect(apply)
	end

	-- Re-bind on `CurrentCamera` swaps so cinematic / spectator camera
	-- changes don't strand the listener on a dead camera.
	local cameraConn: RBXScriptConnection? = nil
	cameraConn = Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		if viewportConn then
			viewportConn:Disconnect()
			viewportConn = nil
		end
		local newCam = Workspace.CurrentCamera
		if newCam then
			viewportConn = newCam:GetPropertyChangedSignal("ViewportSize"):Connect(apply)
		end
		apply()
	end)

	-- Detach when the panel tears down so listeners don't outlive the UI.
	root.Destroying:Connect(function()
		if viewportConn then
			viewportConn:Disconnect()
			viewportConn = nil
		end
		if cameraConn then
			cameraConn:Disconnect()
			cameraConn = nil
		end
	end)

	return scale
end

return ResponsiveScreenScale
