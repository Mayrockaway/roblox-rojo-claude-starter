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

local DOUBLE_JUMP_POWER = 110
local GLIDE_FALL_SPEED = -6
local GLIDE_FORWARD_BOOST = 20
local WALK_SPEED_BOOST = 20
local NORMAL_WALK_SPEED = 16

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
		cleanup()
	end))

	-- Sky box exit detection: find the shared SkyBox in Workspace
	task.spawn(function()
		local skyBox = Workspace:WaitForChild("SkyBox", 10)
		if not skyBox then return end

		local floor = skyBox:FindFirstChild("Floor")
		local ceiling = skyBox:FindFirstChild("Ceiling")
		local wallPosX = skyBox:FindFirstChild("WallPosX")
		local wallNegX = skyBox:FindFirstChild("WallNegX")
		local wallPosZ = skyBox:FindFirstChild("WallPosZ")
		local wallNegZ = skyBox:FindFirstChild("WallNegZ")
		if not (floor and ceiling and wallPosX and wallNegX and wallPosZ and wallNegZ) then return end

		local minY = floor.Position.Y
		local maxY = ceiling.Position.Y
		local minX = wallNegX.Position.X
		local maxX = wallPosX.Position.X
		local minZ = wallNegZ.Position.Z
		local maxZ = wallPosZ.Position.Z

		while active and hrp and hrp.Parent do
			local pos = hrp.Position
			if pos.X < minX or pos.X > maxX
				or pos.Y < minY or pos.Y > maxY
				or pos.Z < minZ or pos.Z > maxZ
			then
				LocalPlayer:SetAttribute(Constants.CurrentWorldAttribute, Constants.WorldMain)
				break
			end
			task.wait(0.2)
		end
	end)
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
