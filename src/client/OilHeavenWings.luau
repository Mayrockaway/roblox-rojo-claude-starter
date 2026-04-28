--!strict
--- Oil Heaven wings: double-jump + glide. Only active while CurrentWorld == OilHeaven.
--- Wings attach to the character's back. Press jump again in the air for a
--- second jump, hold jump to glide (slow descent). Removed on return to Main.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

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

local DOUBLE_JUMP_POWER = 55
local GLIDE_FALL_SPEED = -8
local WALK_SPEED_BOOST = 24
local NORMAL_WALK_SPEED = 16

local function createWings(character: Model)
	local upperTorso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
	if not upperTorso or not upperTorso:IsA("BasePart") then return nil end

	local wings = Instance.new("Model")
	wings.Name = "HeavenWings"

	local leftWing = Instance.new("Part")
	leftWing.Name = "LeftWing"
	leftWing.Anchored = false
	leftWing.CanCollide = false
	leftWing.CastShadow = false
	leftWing.Size = Vector3.new(0.3, 3, 4)
	leftWing.Color = Color3.fromRGB(255, 255, 255)
	leftWing.Material = Enum.Material.Neon
	leftWing.Transparency = 0.3
	leftWing.Parent = wings

	local leftWeld = Instance.new("Weld")
	leftWeld.Part0 = upperTorso
	leftWeld.Part1 = leftWing
	leftWeld.C0 = CFrame.new(-1.8, 0.3, 0.8) * CFrame.Angles(0, 0, math.rad(-20))
	leftWeld.Parent = leftWing

	local rightWing = Instance.new("Part")
	rightWing.Name = "RightWing"
	rightWing.Anchored = false
	rightWing.CanCollide = false
	rightWing.CastShadow = false
	rightWing.Size = Vector3.new(0.3, 3, 4)
	rightWing.Color = Color3.fromRGB(255, 255, 255)
	rightWing.Material = Enum.Material.Neon
	rightWing.Transparency = 0.3
	rightWing.Parent = wings

	local rightWeld = Instance.new("Weld")
	rightWeld.Part0 = upperTorso
	rightWeld.Part1 = rightWing
	rightWeld.C0 = CFrame.new(1.8, 0.3, 0.8) * CFrame.Angles(0, 0, math.rad(20))
	rightWeld.Parent = rightWing

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
	bv.MaxForce = Vector3.new(0, 4000, 0)
	bv.Velocity = Vector3.new(0, GLIDE_FALL_SPEED, 0)
	bv.Parent = hrp
	glideForce = bv
end

local function cleanup()
	for _, conn in ipairs(connections) do
		conn:Disconnect()
	end
	table.clear(connections)
	stopGlide()
	removeWings()
	hasDoubleJumped = false
	active = false

	local char = LocalPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.WalkSpeed = NORMAL_WALK_SPEED
	end
end

local function activate()
	if active then return end
	active = true

	local character = LocalPlayer.Character
	if not character then return end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not humanoid or not hrp then return end

	humanoid.WalkSpeed = WALK_SPEED_BOOST
	wingModel = createWings(character)

	-- Reset on landing
	table.insert(connections, humanoid.StateChanged:Connect(function(oldState, newState)
		if newState == Enum.HumanoidStateType.Landed then
			hasDoubleJumped = false
			stopGlide()
		end
	end))

	-- Double jump: use InputBegan directly for reliability
	table.insert(connections, UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if not active then return end
		if gameProcessed then return end
		if input.KeyCode ~= Enum.KeyCode.Space then return end
		if not humanoid or not hrp then return end
		if humanoid:GetState() == Enum.HumanoidStateType.Dead then return end

		local state = humanoid:GetState()

		if state == Enum.HumanoidStateType.Freefall and not hasDoubleJumped then
			-- Double jump
			hasDoubleJumped = true
			hrp.AssemblyLinearVelocity = Vector3.new(
				hrp.AssemblyLinearVelocity.X,
				DOUBLE_JUMP_POWER,
				hrp.AssemblyLinearVelocity.Z
			)
		elseif state == Enum.HumanoidStateType.Freefall and hasDoubleJumped then
			-- Already double jumped — glide
			startGlide(hrp)
		end
	end))

	-- Stop glide on space release
	table.insert(connections, UserInputService.InputEnded:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.Space then
			stopGlide()
		end
	end))

	table.insert(connections, humanoid.Died:Connect(function()
		cleanup()
	end))
end

function OilHeavenWings.start()
	local function onWorldChanged()
		local world = LocalPlayer:GetAttribute(Constants.CurrentWorldAttribute)
		if world == Constants.WorldOilHeaven then
			task.delay(0.5, function()
				if LocalPlayer:GetAttribute(Constants.CurrentWorldAttribute) == Constants.WorldOilHeaven then
					activate()
				end
			end)
		else
			cleanup()
		end
	end

	LocalPlayer:GetAttributeChangedSignal(Constants.CurrentWorldAttribute):Connect(onWorldChanged)
	LocalPlayer.CharacterAdded:Connect(function()
		task.delay(1, function()
			if LocalPlayer:GetAttribute(Constants.CurrentWorldAttribute) == Constants.WorldOilHeaven then
				activate()
			end
		end)
	end)
	onWorldChanged()
end

return OilHeavenWings
