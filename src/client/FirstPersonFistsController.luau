--!strict

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local localPlayer = Players.LocalPlayer

export type PunchContext = {
	character: Model?,
	humanoidRootPart: BasePart?,
	cameraCFrame: CFrame?,
	origin: Vector3,
	lookVector: Vector3,
	input: InputObject?,
}

type PunchHandler = (PunchContext) -> ()

local FirstPersonFistsController = {}

local handlers: { [number]: PunchHandler } = {}
local nextHandlerId = 0
local forcedSessionCount = 0
local manualFistsOut = false
local started = false
local inputConn: RBXScriptConnection? = nil
local renderConn: RBXScriptConnection? = nil
local characterConn: RBXScriptConnection? = nil
local punchCooldownSeconds = 0.5
local lastPunchAt = -999

local viewmodel: Model? = nil
local rightUpper: BasePart? = nil
local rightLower: BasePart? = nil
local rightHand: BasePart? = nil
local leftUpper: BasePart? = nil
local leftLower: BasePart? = nil
local leftHand: BasePart? = nil
local punchStart = -999
local punchDuration = 0.34
local punchIsLeft = false -- alternates each punch

-- Preloaded whoosh sound — plays on every punch globally
local punchWhooshSound = Instance.new("Sound")
punchWhooshSound.SoundId = "rbxassetid://123445279537923"
punchWhooshSound.Volume = 1
punchWhooshSound.Parent = game:GetService("SoundService")

local function getEquippedTool(): Tool?
	local character = localPlayer.Character
	if not character then
		return nil
	end
	for _, child in ipairs(character:GetChildren()) do
		if child:IsA("Tool") then
			return child
		end
	end
	return nil
end

local function toolLooksLikeFists(tool: Tool): boolean
	local kind = tool:GetAttribute("ToolKind")
	if typeof(kind) == "string" then
		local lower = string.lower(kind)
		if lower == "fists" or lower == "fist" or lower == "punch" or lower == "melee" then
			return true
		end
	end

	local name = string.lower(tool.Name)
	return string.find(name, "fist", 1, true) ~= nil
		or string.find(name, "punch", 1, true) ~= nil
end

local function fistsAreOut(): boolean
	if forcedSessionCount > 0 or manualFistsOut then
		return true
	end

	local tool = getEquippedTool()
	if tool == nil then
		return true
	end
	return toolLooksLikeFists(tool)
end

local function cameraIsFirstPersonLike(): boolean
	local camera = Workspace.CurrentCamera
	local character = localPlayer.Character
	if not camera or not character then
		return false
	end
	local head = character:FindFirstChild("Head")
	local focus = if head and head:IsA("BasePart") then head else character:FindFirstChild("HumanoidRootPart")
	return focus ~= nil and focus:IsA("BasePart") and (camera.CFrame.Position - focus.Position).Magnitude <= 2.25
end

local function destroyViewmodel()
	if viewmodel then
		viewmodel:Destroy()
		viewmodel = nil
	end
	rightUpper = nil
	rightLower = nil
	rightHand = nil
	leftUpper = nil
	leftLower = nil
	leftHand = nil
end

local function findCharacterPart(names: { string }): BasePart?
	local character = localPlayer.Character
	if not character then
		return nil
	end
	for _, name in ipairs(names) do
		local part = character:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			return part
		end
	end
	return nil
end

local function cloneAvatarPart(names: { string }, fallbackName: string, fallbackSize: Vector3, fallbackColor: Color3): BasePart
	local source = findCharacterPart(names)
	local clone: BasePart
	if source then
		clone = source:Clone() :: BasePart
	else
		local part = Instance.new("Part")
		part.Size = fallbackSize
		part.Color = fallbackColor
		part.Material = Enum.Material.SmoothPlastic
		clone = part
	end

	clone.Name = "Viewmodel" .. fallbackName
	clone.Anchored = true
	clone.CanCollide = false
	clone.CanQuery = false
	clone.CanTouch = false
	clone.CastShadow = false
	clone.Massless = true
	clone.Transparency = 0
	clone.LocalTransparencyModifier = 0
	for _, descendant in ipairs(clone:GetDescendants()) do
		if descendant:IsA("JointInstance") or descendant:IsA("Constraint") or descendant:IsA("Attachment") then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.CastShadow = false
			descendant.Transparency = 0
			descendant.LocalTransparencyModifier = 0
		end
	end
	return clone
end

local function ensureViewmodel()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	if viewmodel and viewmodel.Parent == camera then
		return
	end

	destroyViewmodel()
	local model = Instance.new("Model")
	model.Name = "FirstPersonFistsViewmodel"
	model.Parent = camera
	viewmodel = model

	local fallbackSkin = Color3.fromRGB(226, 176, 132)
	rightUpper = cloneAvatarPart({ "RightUpperArm", "Right Arm" }, "RightUpperArm", Vector3.new(0.32, 0.55, 0.32), fallbackSkin)
	rightLower = cloneAvatarPart({ "RightLowerArm", "Right Arm" }, "RightLowerArm", Vector3.new(0.3, 0.55, 0.3), fallbackSkin)
	rightHand = cloneAvatarPart({ "RightHand", "Right Arm" }, "RightHand", Vector3.new(0.34, 0.28, 0.34), fallbackSkin)
	leftUpper = cloneAvatarPart({ "LeftUpperArm", "Left Arm" }, "LeftUpperArm", Vector3.new(0.32, 0.55, 0.32), fallbackSkin)
	leftLower = cloneAvatarPart({ "LeftLowerArm", "Left Arm" }, "LeftLowerArm", Vector3.new(0.3, 0.55, 0.3), fallbackSkin)
	leftHand = cloneAvatarPart({ "LeftHand", "Left Arm" }, "LeftHand", Vector3.new(0.34, 0.28, 0.34), fallbackSkin)

	for _, part in ipairs({ rightUpper, rightLower, rightHand, leftUpper, leftLower, leftHand }) do
		if part then
			part.Parent = model
		end
	end
end

local function cframeAlongY(fromWorld: Vector3, toWorld: Vector3, cameraCF: CFrame): CFrame
	local up = toWorld - fromWorld
	if up.Magnitude < 0.01 then
		up = cameraCF.LookVector
	end
	up = up.Unit
	local right = cameraCF.RightVector
	local back = right:Cross(up)
	if back.Magnitude < 0.01 then
		back = cameraCF.LookVector
	end
	back = back.Unit
	right = up:Cross(back).Unit
	return CFrame.fromMatrix(fromWorld:Lerp(toWorld, 0.5), right, up, back)
end

local function placeArm(upper: BasePart, lower: BasePart, hand: BasePart, shoulderLocal: Vector3, elbowLocal: Vector3, wristLocal: Vector3, fistLocal: Vector3)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local shoulderWorld = camera.CFrame:PointToWorldSpace(shoulderLocal)
	local elbowWorld = camera.CFrame:PointToWorldSpace(elbowLocal)
	local wristWorld = camera.CFrame:PointToWorldSpace(wristLocal)
	local fistWorld = camera.CFrame:PointToWorldSpace(fistLocal)
	upper.CFrame = cframeAlongY(shoulderWorld, elbowWorld, camera.CFrame)
	lower.CFrame = cframeAlongY(elbowWorld, wristWorld, camera.CFrame)
	hand.CFrame = CFrame.lookAt(fistWorld, fistWorld + camera.CFrame.LookVector, camera.CFrame.UpVector)
end

local function renderViewmodel()
	if not fistsAreOut() or not cameraIsFirstPersonLike() then
		destroyViewmodel()
		return
	end

	local alpha = math.clamp((os.clock() - punchStart) / punchDuration, 0, 1)

	-- Only show viewmodel fist during the actual punch swing, not at idle
	if alpha >= 1 then
		destroyViewmodel()
		return
	end

	ensureViewmodel()
	if not (rightUpper and rightLower and rightHand and leftUpper and leftLower and leftHand) then
		return
	end

	local out = math.sin(alpha * math.pi)
	local recoil = math.sin(math.min(alpha * 2, 1) * math.pi) * 0.08

	-- Only show the punching arm, hide the other
	if punchIsLeft then
		for _, part in ipairs({ rightUpper, rightLower, rightHand }) do
			if part then part.Transparency = 1 end
		end
		for _, part in ipairs({ leftUpper, leftLower, leftHand }) do
			if part then part.Transparency = 0 end
		end
		placeArm(
			leftUpper,
			leftLower,
			leftHand,
			Vector3.new(-0.58, -0.58, -0.55),
			Vector3.new(-0.5 + out * 0.08, -0.68 + out * 0.12 + recoil, -0.9 - out * 0.38),
			Vector3.new(-0.4 + out * 0.18, -0.56 + out * 0.14 + recoil, -1.22 - out * 0.9),
			Vector3.new(-0.34 + out * 0.2, -0.5 + out * 0.16 + recoil, -1.42 - out * 1.08)
		)
	else
		for _, part in ipairs({ leftUpper, leftLower, leftHand }) do
			if part then part.Transparency = 1 end
		end
		for _, part in ipairs({ rightUpper, rightLower, rightHand }) do
			if part then part.Transparency = 0 end
		end
		placeArm(
			rightUpper,
			rightLower,
			rightHand,
			Vector3.new(0.58, -0.58, -0.55),
			Vector3.new(0.5 - out * 0.08, -0.68 + out * 0.12 + recoil, -0.9 - out * 0.38),
			Vector3.new(0.4 - out * 0.18, -0.56 + out * 0.14 + recoil, -1.22 - out * 0.9),
			Vector3.new(0.34 - out * 0.2, -0.5 + out * 0.16 + recoil, -1.42 - out * 1.08)
		)
	end
end

local function buildPunchContext(input: InputObject?): PunchContext
	local character = localPlayer.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	local camera = Workspace.CurrentCamera
	local lookVector = if camera then camera.CFrame.LookVector else Vector3.new(0, 0, -1)
	local origin = if camera then camera.CFrame.Position + lookVector * 3 else Vector3.zero
	return {
		character = character,
		humanoidRootPart = if hrp and hrp:IsA("BasePart") then hrp else nil,
		cameraCFrame = if camera then camera.CFrame else nil,
		origin = origin,
		lookVector = lookVector,
		input = input,
	}
end

local function firePunch(input: InputObject?)
	if not fistsAreOut() then
		return
	end
	local now = os.clock()
	if now - lastPunchAt < punchCooldownSeconds then
		return
	end
	lastPunchAt = now
	punchStart = now
	punchIsLeft = not punchIsLeft -- alternate each punch
	punchWhooshSound:Play()
	ensureViewmodel()

	-- Animate real character arm for third-person visibility (R15 + R6)
	local character = localPlayer.Character
	if character then
		local TweenService = game:GetService("TweenService")
		local shoulder: Motor6D? = nil

		-- Find the shoulder Motor6D by name anywhere in the character.
		-- R15: lives on RightUpperArm/LeftUpperArm (not UpperTorso).
		-- R6: lives on Torso as "Right Shoulder"/"Left Shoulder".
		local shoulderName = if punchIsLeft then "LeftShoulder" else "RightShoulder"
		local shoulderNameR6 = if punchIsLeft then "Left Shoulder" else "Right Shoulder"
		for _, d in ipairs(character:GetDescendants()) do
			if d:IsA("Motor6D") and (d.Name == shoulderName or d.Name == shoulderNameR6) then
				shoulder = d
				break
			end
		end

		if shoulder then
			warn("[FistsPunch] SWING " .. shoulder:GetFullName())
			local originalC0 = shoulder.C0
			local punchC0 = originalC0 * CFrame.Angles(math.rad(90), 0, 0)
			local tweenOut = TweenService:Create(shoulder, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { C0 = punchC0 })
			tweenOut:Play()
			task.delay(0.18, function()
				local tweenBack = TweenService:Create(shoulder, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { C0 = originalC0 })
				tweenBack:Play()
			end)
		end
	end

	local context = buildPunchContext(input)
	for _, handler in pairs(handlers) do
		local ok, err = pcall(handler, context)
		if not ok then
			warn("[FirstPersonFistsController] punch handler failed: ", err)
		end
	end
end

function FirstPersonFistsController.start()
	if started then
		return
	end
	started = true
	inputConn = UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			firePunch(input)
		end
	end)
	renderConn = RunService.RenderStepped:Connect(renderViewmodel)
	characterConn = localPlayer.CharacterAdded:Connect(function()
		destroyViewmodel()
	end)
end

function FirstPersonFistsController.stop()
	if inputConn then
		inputConn:Disconnect()
		inputConn = nil
	end
	if renderConn then
		renderConn:Disconnect()
		renderConn = nil
	end
	if characterConn then
		characterConn:Disconnect()
		characterConn = nil
	end
	started = false
	destroyViewmodel()
end

function FirstPersonFistsController.setFistsOut(enabled: boolean)
	manualFistsOut = enabled
	if not enabled then
		destroyViewmodel()
	end
end

function FirstPersonFistsController.connectPunch(handler: PunchHandler): any
	nextHandlerId += 1
	local id = nextHandlerId
	handlers[id] = handler
	local disconnected = false
	return {
		Disconnect = function()
			if disconnected then
				return
			end
			disconnected = true
			handlers[id] = nil
		end,
	}
end

function FirstPersonFistsController.beginSession(options: { onPunch: PunchHandler?, cooldownSeconds: number? }?): any
	FirstPersonFistsController.start()
	forcedSessionCount += 1
	local previousCooldown = punchCooldownSeconds
	if options and typeof(options.cooldownSeconds) == "number" then
		punchCooldownSeconds = math.max(0.05, options.cooldownSeconds)
	end
	local handlerConn = if options and options.onPunch then FirstPersonFistsController.connectPunch(options.onPunch) else nil
	local disconnected = false
	return {
		Disconnect = function()
			if disconnected then
				return
			end
			disconnected = true
			if handlerConn then
				handlerConn:Disconnect()
			end
			forcedSessionCount = math.max(0, forcedSessionCount - 1)
			punchCooldownSeconds = previousCooldown
			if forcedSessionCount <= 0 and not manualFistsOut then
				destroyViewmodel()
			end
		end,
	}
end

return FirstPersonFistsController
