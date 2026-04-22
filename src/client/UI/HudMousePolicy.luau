--!strict
-- HUD modal **mouse-unlock policy**.
--
-- Problem: when the player has scrolled the camera all the way in (first-person), Roblox's
-- default `PlayerModule.MouseLockController` forces `UserInputService.MouseBehavior =
-- LockCenter` every frame and hides the cursor. Opening any HUD modal (`ShopPanelGui`,
-- `RobuxShopPanel`, `SellOilPanelGui`, etc.) inherits that lock — mouse movement keeps
-- rotating the camera and BUY / X buttons are uncliclickable until the user scrolls out.
--
-- Setting `MouseBehavior = Default` once does **not** stick: the engine's own per-frame
-- update reverts it. The reliable workaround is to override the property every frame
-- while a HUD modal is open and restore on close. This module owns that loop.
--
-- Usage:
--   local policy = require(...HudMousePolicy)
--   policy.RegisterController(ctrl)        -- bound HudPanelController (HudPanelRouter)
--   policy.RegisterScreenGui(screenGui)    -- raw runtime-built ScreenGui (dialog popups
--                                              that aren't bound through the router:
--                                              ArmyGeneralGui, PirateHireGui, Oilman
--                                              dialogue, AutoShip prompts, etc.)
--   policy.Start()                         -- once
--
-- All panels we register are tracked by reading `ctrl.IsOpen()` (or `screen.Enabled` for
-- raw ScreenGuis) on `Heartbeat`. When the aggregate "any open" state flips on we save
-- the player's prior mouse state and override. When it flips off we restore. Cheap (no
-- allocation) and immune to panels that close themselves through `screen.Enabled = false`
-- without going through the router. Registered raw ScreenGuis are auto-removed from the
-- watch list on `Destroying` so a torn-down dialog can't keep the policy "stuck open".

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local HudPanelTypes = require(script.Parent.HudPanelTypes)

local HudMousePolicy = {}

local LocalPlayer = Players.LocalPlayer

local controllers: { HudPanelTypes.HudPanelController } = {}
local screenGuis: { ScreenGui } = {}
local started = false
local heartbeatConn: RBXScriptConnection? = nil

local overriding = false

local function anyPanelOpen(): boolean
	for _, ctrl in ipairs(controllers) do
		--- Skip controllers whose ScreenGui was destroyed / re-cloned (e.g.
		--- `ResetOnSpawn = true` death respawn): `screen.Enabled` on a
		--- destroyed instance still reads cleanly and could return `true`,
		--- which would freeze the cursor unlock policy in the "open" state
		--- forever. `Parent == nil` is the orphan signal — `HudPanelRouter`
		--- rebinds these and registers the fresh controller so this entry
		--- becomes inert.
		local sg = (ctrl :: any).ScreenGui
		if typeof(sg) == "Instance" and sg.Parent == nil then
			continue
		end
		--- `IsOpen` is `() -> boolean` reading `ScreenGui.Enabled`. Wrap in pcall in case
		--- a controller's ScreenGui was destroyed (orphan teardown during respawn).
		local ok, open = pcall(ctrl.IsOpen)
		if ok and open == true then
			return true
		end
	end
	for _, sg in ipairs(screenGuis) do
		--- Runtime-built dialogs use the raw ScreenGui's parented + enabled state as the
		--- "open" signal (most don't toggle `Enabled`; they parent on open / Destroy on
		--- close). Treating `nil` parent as closed lets `Destroy()`-style teardown work
		--- without an explicit unregister call from each caller.
		if sg.Parent ~= nil and sg.Enabled then
			return true
		end
	end
	return false
end

local function beginOverride()
	if overriding then
		return
	end
	overriding = true
end

--- We deliberately do NOT save / restore `MouseBehavior` + `MouseIconEnabled`
--- on open / close. The engine's `PlayerModule.MouseLockController` writes
--- those properties every `RenderStepped` based on the **current** camera
--- mode (first-person → `LockCenter` + icon off, third-person → `Default` +
--- icon on, shift-lock → `LockCenter`). Snapshotting them on Open and
--- replaying that snapshot on Close re-applies a stale state the engine no
--- longer agrees with — most visibly: open Ship Management while in
--- first-person → save `LockCenter` → camera scrolls out to third-person
--- while the panel is open → close panel → we restore `LockCenter` → engine
--- in third-person never rewrites it → cursor stays locked to camera-look
--- with no icon. Repro: this exact bug.
---
--- Instead: on close we just nudge `MouseBehavior = Default` + icon on
--- once and step away. If the player is (still) in first-person the engine
--- flips it back to `LockCenter` on the very next frame, so this nudge is
--- harmless. If they're in third-person (the broken case before this fix)
--- the engine doesn't fight us and the cursor is correctly free.
local function endOverride()
	if not overriding then
		return
	end
	overriding = false
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
end

local function tickPolicy()
	local open = anyPanelOpen()
	if open then
		if not overriding then
			beginOverride()
		end
		--- Re-apply every frame: the engine's `MouseLockController` runs in
		--- `RenderStepped` and will keep flipping `MouseBehavior` back to
		--- `LockCenter` while the camera is in first-person.
		if UserInputService.MouseBehavior ~= Enum.MouseBehavior.Default then
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		end
		if UserInputService.MouseIconEnabled ~= true then
			UserInputService.MouseIconEnabled = true
		end
	else
		if overriding then
			endOverride()
		end
	end
end

--- Add a controller for the policy to watch. Safe to call multiple times — duplicates are ignored.
function HudMousePolicy.RegisterController(ctrl: HudPanelTypes.HudPanelController)
	if not ctrl then
		return
	end
	for _, existing in ipairs(controllers) do
		if existing == ctrl then
			return
		end
	end
	table.insert(controllers, ctrl)
end

--- Drop a controller that's been replaced (e.g. `ResetOnSpawn = true` torn
--- down its ScreenGui and `HudPanelRouter` re-bound a fresh one). The
--- destroyed-screen guard in `anyPanelOpen` already makes this a hygiene fix
--- rather than a correctness fix, but explicit removal keeps the watch list
--- bounded across many deaths.
function HudMousePolicy.UnregisterController(ctrl: HudPanelTypes.HudPanelController?)
	if not ctrl then
		return
	end
	for i, existing in ipairs(controllers) do
		if existing == ctrl then
			table.remove(controllers, i)
			return
		end
	end
end

--- Add a raw runtime-built `ScreenGui` for the policy to watch. Use this for dialogs that
--- aren't bound through `HudPanelRouter` (`ArmyGeneralGui`, `PirateHireGui`, Oilman
--- dialogue ScreenGuis, AutoShip prompt, etc.). Safe to call multiple times — duplicates
--- are ignored. The ScreenGui is auto-removed from the watch list when it's destroyed
--- so a closed dialog can never keep the policy "stuck open".
function HudMousePolicy.RegisterScreenGui(sg: ScreenGui)
	if not (sg and sg:IsA("ScreenGui")) then
		return
	end
	for _, existing in ipairs(screenGuis) do
		if existing == sg then
			return
		end
	end
	table.insert(screenGuis, sg)
	sg.Destroying:Connect(function()
		for i, existing in ipairs(screenGuis) do
			if existing == sg then
				table.remove(screenGuis, i)
				break
			end
		end
	end)
end

function HudMousePolicy.Start()
	if started then
		return
	end
	started = true
	if not LocalPlayer then
		return
	end
	heartbeatConn = RunService.Heartbeat:Connect(tickPolicy)
end

function HudMousePolicy.Stop()
	if heartbeatConn then
		heartbeatConn:Disconnect()
		heartbeatConn = nil
	end
	started = false
	endOverride()
end

return HudMousePolicy
