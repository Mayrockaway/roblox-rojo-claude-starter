--!strict
--- Oil Heaven wings: double-jump + glide. Only active while CurrentWorld == OilHeaven.
--- Wings attach to the character's back. Press jump again in the air for a
--- second jump, hold jump to glide (slow descent). Removed on return to Main.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local LocalPlayer = Players.LocalPlayer

local OilHeavenWings = {}

local active = false
local wingModel: Model? = nil
local glideForce: BodyVelocity? = nil
local hasDoubleJumped = false
local isGliding = false
local connections: { RBXScriptConnection } = {}
local savedJumpHeight: number? = nil

local DOUBLE_JUMP_POWER = 110
local GLIDE_FALL_SPEED = -6
local GLIDE_FORWARD_BOOST = 20
--- Heaven gives a 10% jump-height boost on top of `StarterPlayer.CharacterJumpHeight`.
--- Saved at activate-time so cleanup restores the player's authored value
--- (in case the project's StarterPlayer setting changes mid-session).
local HEAVEN_JUMP_HEIGHT_MULTIPLIER = 1.1
-- WALK_SPEED_BOOST / NORMAL_WALK_SPEED were removed. WalkSpeed now stays at
-- whatever `StarterPlayer.CharacterWalkSpeed` sets (default 16) regardless of
-- world. The wings mechanic (double jump + glide) is independent of WalkSpeed —
-- it uses `JumpRequest` + `BodyVelocity`, not movement speed — so removing the
-- per-world override doesn't change flight feel.

local function createWings(character: Model)
	-- Visual wings are now handled by server-side Angel accessories
	-- (ServerStorage.HeavenAccessories). This function only creates a
	-- tracking Model so the flight mechanics code can check if "wings"
	-- are active.
	local wings = Instance.new("Model")
	wings.Name = "HeavenWings"
	wings.Parent = character
	return wings
end

local function removeWings()
	if wingModel then
		wingModel:Destroy()
		wingModel = nil
	end
end

local function stopGlide()
	if glideForce then
		glideForce:Destroy()
		glideForce = nil
	end
	isGliding = false
end

local function startGlide(hrp: BasePart)
	if isGliding then return end
	isGliding = true
	local bv = Instance.new("BodyVelocity")
	bv.Name = "GlideForce"
	bv.MaxForce = Vector3.new(50000, 50000, 50000)
	-- Push down slowly + forward in look direction
	local look = hrp.CFrame.LookVector
	bv.Velocity = Vector3.new(
		look.X * GLIDE_FORWARD_BOOST,
		GLIDE_FALL_SPEED,
		look.Z * GLIDE_FORWARD_BOOST
	)
	bv.Parent = hrp
	glideForce = bv

	-- Update glide direction as player turns
	task.spawn(function()
		while isGliding and hrp and hrp.Parent do
			local l = hrp.CFrame.LookVector
			bv.Velocity = Vector3.new(
				l.X * GLIDE_FORWARD_BOOST,
				GLIDE_FALL_SPEED,
				l.Z * GLIDE_FORWARD_BOOST
			)
			task.wait()
		end
	end)
end

--- Lifecycle is now driven externally by `OilHeavenAmbient` based on the
--- player's HRP position relative to the SkyBox bounds — wings activate when
--- the player is *physically inside* OilHeaven, not just when the world
--- attribute is set. That way falling off the cloud edge instantly removes
--- wings (cleanup runs), preventing players from gliding indefinitely back
--- to the main world. Re-entering bounds (e.g. coming back through ANGELGATE)
--- re-activates them. Both functions are idempotent.
function OilHeavenWings.cleanup()
	for _, conn in ipairs(connections) do
		conn:Disconnect()
	end
	table.clear(connections)
	stopGlide()
	removeWings()
	hasDoubleJumped = false
	active = false
	-- Restore saved JumpHeight from before the heaven boost. Read from the
	-- live humanoid (might have respawned since activate); if no save exists,
	-- skip — the new humanoid spawned with StarterPlayer's value already.
	if savedJumpHeight ~= nil then
		local char = LocalPlayer.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if hum then
			hum.JumpHeight = savedJumpHeight
		end
		savedJumpHeight = nil
	end
	-- WalkSpeed restore was removed alongside the per-world boost. The
	-- player keeps whatever speed StarterPlayer set; nothing to undo here.
end

function OilHeavenWings.activate()
	if active then return end
	active = true

	local character = LocalPlayer.Character
	if not character then return end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not humanoid or not hrp then return end

	-- WalkSpeed deliberately not touched — speed stays at whatever
	-- `StarterPlayer.CharacterWalkSpeed` sets (default 16) so it's
	-- consistent across worlds. Wings = jump + glide, not faster running.
	-- JumpHeight gets a +10% boost while in heaven. Saved here, restored on
	-- cleanup. Idempotent — re-activate without prior cleanup keeps the
	-- earlier saved baseline so we never compound the multiplier.
	if savedJumpHeight == nil then
		savedJumpHeight = humanoid.JumpHeight
	end
	humanoid.JumpHeight = savedJumpHeight * HEAVEN_JUMP_HEIGHT_MULTIPLIER
	wingModel = createWings(character)

	-- Reset on landing
	table.insert(connections, humanoid.StateChanged:Connect(function(oldState, newState)
		if newState == Enum.HumanoidStateType.Landed then
			hasDoubleJumped = false
			stopGlide()
		elseif newState == Enum.HumanoidStateType.Freefall and hasDoubleJumped then
			-- After double jump, auto-start glide if space is held
			if UserInputService:IsKeyDown(Enum.KeyCode.Space) then
				startGlide(hrp)
			end
		end
	end))

	-- Double jump via JumpRequest (fires even when gameProcessed)
	table.insert(connections, UserInputService.JumpRequest:Connect(function()
		if not active then return end
		if not humanoid or not hrp then return end
		if humanoid:GetState() == Enum.HumanoidStateType.Dead then return end

		if humanoid:GetState() == Enum.HumanoidStateType.Freefall and not hasDoubleJumped then
			hasDoubleJumped = true
			hrp.AssemblyLinearVelocity = Vector3.new(
				hrp.AssemblyLinearVelocity.X,
				DOUBLE_JUMP_POWER,
				hrp.AssemblyLinearVelocity.Z
			)
			-- Start glide immediately since player is holding space
			task.delay(0.3, function()
				if active and hasDoubleJumped and humanoid:GetState() == Enum.HumanoidStateType.Freefall then
					if UserInputService:IsKeyDown(Enum.KeyCode.Space) then
						startGlide(hrp)
					end
				end
			end)
		end
	end))

	-- Also start glide if space pressed while falling after double jump
	table.insert(connections, UserInputService.InputBegan:Connect(function(input, gpe)
		if gpe then return end
		if input.KeyCode == Enum.KeyCode.Space and hasDoubleJumped then
			if humanoid:GetState() == Enum.HumanoidStateType.Freefall and hrp then
				startGlide(hrp)
			end
		end
	end))

	-- Stop glide on space release
	table.insert(connections, UserInputService.InputEnded:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.Space then
			stopGlide()
		end
	end))

	table.insert(connections, humanoid.Died:Connect(function()
		OilHeavenWings.cleanup()
	end))

	-- SkyBox exit detection was REMOVED. It polled HRP position against the
	-- shared SkyBox bounds and locally set `CurrentWorld = Main` on exit —
	-- which on the server (and via the world-changed listener above) ran
	-- `cleanup()`, snapping `WalkSpeed` back to 16 and stripping wings.
	-- Two problems:
	--   1. `DOUBLE_JUMP_POWER = 110` easily punches the player above the
	--      ceiling for a frame on every double-jump, triggering the exit
	--      and resetting walk speed mid-flight.
	--   2. The check writes the attribute client-side only, leaving the
	--      server's view inconsistent (server still thinks the player is
	--      in OilHeaven; client thinks they left).
	-- World transitions are now driven exclusively by explicit teleport
	-- remotes (`RequestTeleportToOilHeaven`, `RequestTeleportHome`,
	-- `RequestTeleportToRebirthTarget`), which set `CurrentWorld` server-
	-- side authoritatively. Falling out of OilHeaven is handled by the
	-- KillZone layer the same way as falling off any plot.
end

--- Bootstrap stub — kept for back-compat with `OilHeavenWingsBootstrap.client.luau`
--- so the require + start() call there doesn't error. The actual lifecycle
--- (activate / cleanup) is now driven by `OilHeavenAmbient`'s bounds polling,
--- which already runs `transitionToHeaven` / `transitionToMain` based on HRP
--- vs SkyBox bounds. No listeners to install here anymore.
function OilHeavenWings.start()
	-- intentional no-op
end

return OilHeavenWings
