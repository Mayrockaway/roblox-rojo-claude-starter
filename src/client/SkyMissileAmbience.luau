--!strict
-- Client-side ambient sky missiles. Pure cosmetic, spawned relative to the
-- local camera. Zero server cost, zero network.

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

--- Looped flyby for ambient sky missiles (spatial, follows missile).
local AMBIENT_MISSILE_FLYBY_SOUND_ID = "rbxassetid://113742210459217"
local AMBIENT_MISSILE_FLYBY_VOLUME = 0.4

local SkyMissileAmbience = {}

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local LocalPlayer = Players.LocalPlayer

local SPAWN_FOLDER_NAME = "_AmbientSkyMissilesClient"
local TEMPLATE_FOLDER_NAME = "Assets"
local TEMPLATE_NAME = "Missile_Ambient"

local MIN_INTERVAL = 0.8
local MAX_INTERVAL = 2.2
local MAX_CONCURRENT = 6

-- Horizontal ring around camera.
local HORIZONTAL_MIN = 200
local HORIZONTAL_MAX = 500

-- Launch/land altitude above camera (below apex; arc carries them higher).
local ALT_MIN = 60
local ALT_MAX = 140

-- Extra vertical lift at the peak of the arc (on top of ALT values).
-- This is what makes them "thrown like footballs".
local ARC_PEAK_MIN = 140
local ARC_PEAK_MAX = 260

-- Flight duration range (seconds). Slow, heavy-feeling trajectories.
local FLIGHT_MIN = 6.0
local FLIGHT_MAX = 10.0

-- Odds a missile explodes mid-air vs. flies off-map.
local EXPLODE_CHANCE = 0.65
-- Fraction of flight where it detonates. Wide range → some early, some late.
local EXPLODE_FRACTION_MIN = 0.25
local EXPLODE_FRACTION_MAX = 0.95

-- Missile body (Y axis = length).
local BODY_SIZE = Vector3.new(1.2, 10, 1.2)
local BODY_COLOR = Color3.fromRGB(200, 200, 205)
local NOSE_COLOR = Color3.fromRGB(235, 60, 40)
local NOSE_SIZE = Vector3.new(1.4, 1.4, 1.4)

local TRAIL_COLOR_SEQ = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 245, 210)),
	ColorSequenceKeypoint.new(0.25, Color3.fromRGB(255, 150, 70)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(40, 40, 45)),
})
local TRAIL_TRANSPARENCY_SEQ = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0.1),
	NumberSequenceKeypoint.new(1, 1),
})

local EXPLOSION_COLOR_SEQ = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 240, 180)),
	ColorSequenceKeypoint.new(0.4, Color3.fromRGB(255, 120, 40)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(80, 40, 30)),
})
local EXPLOSION_SIZE_SEQ = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 10),
	NumberSequenceKeypoint.new(0.4, 24),
	NumberSequenceKeypoint.new(1, 38),
})
local EXPLOSION_TRANSPARENCY_SEQ = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0.05),
	NumberSequenceKeypoint.new(0.7, 0.5),
	NumberSequenceKeypoint.new(1, 1),
})

local FLAME_COLOR_SEQ = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 250, 220)),
	ColorSequenceKeypoint.new(0.4, Color3.fromRGB(255, 160, 60)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(140, 40, 20)),
})
local FLAME_SIZE_SEQ = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 2.6),
	NumberSequenceKeypoint.new(0.5, 1.4),
	NumberSequenceKeypoint.new(1, 0.2),
})
local FLAME_TRANSPARENCY_SEQ = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0.1),
	NumberSequenceKeypoint.new(1, 1),
})

local activeCount = 0
local running = false
local rng = Random.new()
local spawnFolder: Folder? = nil

local function isOilHeavenActive(): boolean
	return LocalPlayer ~= nil and LocalPlayer:GetAttribute(Constants.CurrentWorldAttribute) == Constants.WorldOilHeaven
end

local function getAmbientMissileFlybyVolume(): number
	if isOilHeavenActive() then
		return 0
	end
	return AMBIENT_MISSILE_FLYBY_VOLUME
end

local function refreshAmbientMissileFlybySounds()
	local folder = spawnFolder or Workspace:FindFirstChild(SPAWN_FOLDER_NAME)
	if not folder or not folder:IsA("Folder") then
		return
	end
	for _, desc in ipairs(folder:GetDescendants()) do
		if desc:IsA("Sound") and desc.Name == "AmbientMissileFlyby" then
			desc.Volume = getAmbientMissileFlybyVolume()
		end
	end
end

local function ensureFolder(): Folder
	if spawnFolder and spawnFolder.Parent then
		return spawnFolder
	end
	local existing = Workspace:FindFirstChild(SPAWN_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		spawnFolder = existing
		return existing
	end
	local f = Instance.new("Folder")
	f.Name = SPAWN_FOLDER_NAME
	f.Parent = Workspace
	spawnFolder = f
	return f
end

local function randomHorizontalOffset(): Vector3
	local angle = rng:NextNumber(0, math.pi * 2)
	local dist = rng:NextNumber(HORIZONTAL_MIN, HORIZONTAL_MAX)
	return Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist)
end

local function spawnExplosion(position: Vector3)
	local host = Instance.new("Part")
	host.Name = "SkyMissileExplosion"
	host.Size = Vector3.new(1, 1, 1)
	host.Transparency = 1
	host.CanCollide = false
	host.CanTouch = false
	host.CanQuery = false
	host.Anchored = true
	host.CFrame = CFrame.new(position)

	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = "rbxasset://textures/particles/smoke_main.dds"
	emitter.Color = EXPLOSION_COLOR_SEQ
	emitter.Size = EXPLOSION_SIZE_SEQ
	emitter.Transparency = EXPLOSION_TRANSPARENCY_SEQ
	emitter.Lifetime = NumberRange.new(1.3, 1.9)
	emitter.Speed = NumberRange.new(18, 40)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Rotation = NumberRange.new(-180, 180)
	emitter.RotSpeed = NumberRange.new(-60, 60)
	emitter.LightEmission = 0.7
	emitter.LightInfluence = 0
	emitter.Rate = 0
	emitter.Parent = host

	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 200, 120)
	light.Range = 80
	light.Brightness = 8
	light.Parent = host

	host.Parent = ensureFolder()
	emitter:Emit(30)

	task.delay(0.1, function()
		if light.Parent then
			light.Brightness = 3
			light.Range = 55
		end
	end)
	task.delay(0.3, function()
		if light.Parent then
			light:Destroy()
		end
	end)

	Debris:AddItem(host, 2.5)
end

local function resolveTemplate(): (Model | BasePart)?
	local assets = ReplicatedStorage:FindFirstChild(TEMPLATE_FOLDER_NAME)
	local found = assets and assets:FindFirstChild(TEMPLATE_NAME)
	if found and (found:IsA("Model") or found:IsA("BasePart")) then
		return found
	end
	return nil
end

local TEMPLATE_SCALE = 0.5

local function prepareClone(clone: Model | BasePart)
	if clone:IsA("Model") then
		-- Clear PrimaryPart so PivotTo uses the model's natural pivot (whose
		-- axes match the original orientation) rather than a potentially
		-- misaligned part's local frame.
		(clone :: Model).PrimaryPart = nil
		pcall(function()
			(clone :: Model):ScaleTo(TEMPLATE_SCALE)
		end)
	elseif clone:IsA("BasePart") then
		clone.Anchored = true
		clone.CanCollide = false
		clone.CanTouch = false
		clone.CanQuery = false
		clone.CastShadow = false
		clone.Size = clone.Size * TEMPLATE_SCALE
	end
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("Script") or d:IsA("LocalScript") then
			d.Disabled = true
		elseif d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanTouch = false
			d.CanQuery = false
			d.CastShadow = false
		end
	end
end

local function getBodyPart(clone: Model | BasePart): BasePart?
	if clone:IsA("BasePart") then
		return clone
	end
	local model = clone :: Model
	if model.PrimaryPart then
		return model.PrimaryPart
	end
	return model:FindFirstChildWhichIsA("BasePart", true)
end

local function attachAmbientFlybySound(host: BasePart): Sound
	local existing = host:FindFirstChild("AmbientMissileFlyby")
	if existing and existing:IsA("Sound") then
		return existing
	end
	local s = Instance.new("Sound")
	s.Name = "AmbientMissileFlyby"
	s.SoundId = AMBIENT_MISSILE_FLYBY_SOUND_ID
	s.Volume = getAmbientMissileFlybyVolume()
	s.Looped = true
	s.RollOffMode = Enum.RollOffMode.InverseTapered
	s.RollOffMaxDistance = 1200
	s.EmitterSize = 25
	s.Parent = host
	task.defer(function()
		if not s.Parent then
			return
		end
		if not s.IsLoaded then
			pcall(function()
				s.Loaded:Wait()
			end)
		end
		if s.Parent then
			s.Volume = getAmbientMissileFlybyVolume()
			s:Play()
		end
	end)
	return s
end

local function addFxToTemplateBody(body: BasePart)
	if body:FindFirstChild("_AmbientFxInstalled") then
		return
	end
	local marker = Instance.new("BoolValue")
	marker.Name = "_AmbientFxInstalled"
	marker.Parent = body

	local tailAtt = Instance.new("Attachment")
	tailAtt.Name = "Tail"
	tailAtt.Position = Vector3.new(0, -body.Size.Y * 0.5, 0)
	tailAtt.Parent = body

	local tailAtt2 = Instance.new("Attachment")
	tailAtt2.Name = "TailInner"
	tailAtt2.Position = Vector3.new(0, -body.Size.Y * 0.5 + 0.6, 0)
	tailAtt2.Parent = body

	local trail = Instance.new("Trail")
	trail.Attachment0 = tailAtt2
	trail.Attachment1 = tailAtt
	trail.Color = TRAIL_COLOR_SEQ
	trail.Transparency = TRAIL_TRANSPARENCY_SEQ
	trail.Lifetime = 2.8
	trail.MinLength = 0
	trail.WidthScale = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 4),
		NumberSequenceKeypoint.new(1, 0.4),
	})
	trail.LightEmission = 0.85
	trail.FaceCamera = true
	trail.Parent = body

	local flame = Instance.new("ParticleEmitter")
	flame.Name = "Flame"
	flame.Texture = "rbxasset://textures/particles/fire_main.dds"
	flame.Color = FLAME_COLOR_SEQ
	flame.Size = FLAME_SIZE_SEQ
	flame.Transparency = FLAME_TRANSPARENCY_SEQ
	flame.Lifetime = NumberRange.new(0.18, 0.32)
	flame.Rate = 100
	flame.Speed = NumberRange.new(8, 14)
	flame.SpreadAngle = Vector2.new(10, 10)
	flame.LightEmission = 0.9
	flame.LightInfluence = 0
	flame.Rotation = NumberRange.new(-180, 180)
	flame.Parent = tailAtt

	attachAmbientFlybySound(body)
end

local function buildMissileBody(): (BasePart, BasePart, Attachment)
	-- Body = long thin block, Y-axis is length.
	local body = Instance.new("Part")
	body.Name = "SkyMissileBody"
	body.Size = BODY_SIZE
	body.Material = Enum.Material.SmoothPlastic
	body.Color = BODY_COLOR
	body.Anchored = true
	body.CanCollide = false
	body.CanTouch = false
	body.CanQuery = false
	body.CastShadow = false
	body.TopSurface = Enum.SurfaceType.Smooth
	body.BottomSurface = Enum.SurfaceType.Smooth

	-- Bright nose tip: helps silhouette against sky + reads as "missile warhead".
	local nose = Instance.new("Part")
	nose.Name = "SkyMissileNose"
	nose.Shape = Enum.PartType.Ball
	nose.Size = NOSE_SIZE
	nose.Material = Enum.Material.Neon
	nose.Color = NOSE_COLOR
	nose.Anchored = true
	nose.CanCollide = false
	nose.CanTouch = false
	nose.CanQuery = false
	nose.CastShadow = false
	nose.Parent = body

	-- Tail attachment: Trail anchors + flame emitter live here.
	local tailAtt = Instance.new("Attachment")
	tailAtt.Name = "Tail"
	tailAtt.Position = Vector3.new(0, -BODY_SIZE.Y * 0.5, 0)
	tailAtt.Parent = body

	local tailAtt2 = Instance.new("Attachment")
	tailAtt2.Name = "TailInner"
	tailAtt2.Position = Vector3.new(0, -BODY_SIZE.Y * 0.5 + 0.6, 0)
	tailAtt2.Parent = body

	local trail = Instance.new("Trail")
	trail.Attachment0 = tailAtt2
	trail.Attachment1 = tailAtt
	trail.Color = TRAIL_COLOR_SEQ
	trail.Transparency = TRAIL_TRANSPARENCY_SEQ
	trail.Lifetime = 2.8
	trail.MinLength = 0
	trail.WidthScale = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 4),
		NumberSequenceKeypoint.new(1, 0.4),
	})
	trail.LightEmission = 0.85
	trail.FaceCamera = true
	trail.Parent = body

	local flame = Instance.new("ParticleEmitter")
	flame.Name = "Flame"
	flame.Texture = "rbxasset://textures/particles/fire_main.dds"
	flame.Color = FLAME_COLOR_SEQ
	flame.Size = FLAME_SIZE_SEQ
	flame.Transparency = FLAME_TRANSPARENCY_SEQ
	flame.Lifetime = NumberRange.new(0.18, 0.32)
	flame.Rate = 100
	flame.Speed = NumberRange.new(8, 14)
	flame.SpreadAngle = Vector2.new(10, 10)
	flame.LightEmission = 0.9
	flame.LightInfluence = 0
	flame.Rotation = NumberRange.new(-180, 180)
	flame.Parent = tailAtt

	-- Subtle body glow so it isn't invisible against a bright sky.
	local bodyLight = Instance.new("PointLight")
	bodyLight.Color = Color3.fromRGB(255, 200, 140)
	bodyLight.Range = 16
	bodyLight.Brightness = 1.5
	bodyLight.Parent = body

	attachAmbientFlybySound(body)

	return body, nose, tailAtt
end

local function orientMissile(body: BasePart, nose: BasePart, pos: Vector3, target: Vector3)
	-- CFrame.lookAt → LookVector points at target. Rotate -90° around local X
	-- so the block's local +Y aligns with the look direction (i.e. nose points
	-- forward). This matches the working "bullet" rig.
	local cf = CFrame.lookAt(pos, target) * CFrame.Angles(math.rad(-90), 0, 0)
	body.CFrame = cf
	-- Nose sits slightly ahead of the body along its length (+Y local).
	nose.CFrame = cf * CFrame.new(0, BODY_SIZE.Y * 0.5 + NOSE_SIZE.Y * 0.25, 0)
end

local function launchMissile()
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	local camPos = cam.CFrame.Position

	local startOffset = randomHorizontalOffset()
	local startAlt = rng:NextNumber(ALT_MIN, ALT_MAX)
	local endAlt = rng:NextNumber(ALT_MIN, ALT_MAX)
	local startPos = camPos + startOffset + Vector3.new(0, startAlt, 0)

	local endOffset = -startOffset * rng:NextNumber(0.9, 1.2) + Vector3.new(
		rng:NextNumber(-400, 400), 0, rng:NextNumber(-400, 400)
	)
	local endPos = camPos + endOffset + Vector3.new(0, endAlt, 0)

	local routeVec = endPos - startPos
	if routeVec.Magnitude < 80 then
		return
	end
	local horizontalDir = Vector3.new(routeVec.X, 0, routeVec.Z)
	if horizontalDir.Magnitude < 1 then
		horizontalDir = Vector3.new(0, 0, 1)
	else
		horizontalDir = horizontalDir.Unit
	end

	local willExplode = rng:NextNumber(0, 1) < EXPLODE_CHANCE
	local flightDuration = rng:NextNumber(FLIGHT_MIN, FLIGHT_MAX)
	local explodeFraction = if willExplode
		then rng:NextNumber(EXPLODE_FRACTION_MIN, EXPLODE_FRACTION_MAX)
		else math.huge
	local arcPeak = rng:NextNumber(ARC_PEAK_MIN, ARC_PEAK_MAX)

	-- Parabolic "football toss" trajectory. alpha in [0, 1+] → position along
	-- lerp(start, end) + vertical arc that peaks at alpha=0.5.
	-- For fly-off missiles we keep extending past alpha=1 in a straight line
	-- horizontally, since the arc has already grounded by then.
	local function trajectory(alpha: number): Vector3
		if alpha <= 1 then
			local flat = startPos:Lerp(endPos, alpha)
			local arcY = arcPeak * 4 * alpha * (1 - alpha)
			return flat + Vector3.new(0, arcY, 0)
		else
			-- Past endpoint: coast forward along horizontal direction, slight
			-- gentle descent.
			local extra = (alpha - 1) * (endPos - startPos).Magnitude
			return endPos + horizontalDir * extra - Vector3.new(0, extra * 0.15, 0)
		end
	end

	-- Try template first; fall back to built primitive if missing.
	local template = resolveTemplate()
	local body: BasePart
	local nose: BasePart? = nil
	local rootVisual: Instance
	local useTemplate = false
	do
		local initialTangent = (trajectory(0.01) - trajectory(0)).Unit
		if template then
			local clone = template:Clone()
			prepareClone(clone)
			local bodyPart = getBodyPart(clone)
			if not bodyPart then
				clone:Destroy()
				return
			end
			body = bodyPart
			addFxToTemplateBody(body)
			rootVisual = clone
			useTemplate = true
			-- Template's long axis is its own local +X → yaw +90° so local +X aligns with tangent.
			local initCF = CFrame.lookAt(startPos, startPos + initialTangent) * CFrame.Angles(0, math.rad(-90), 0)
			if clone:IsA("Model") then
				(clone :: Model):PivotTo(initCF)
			else
				(clone :: BasePart).CFrame = initCF
			end
			clone.Parent = ensureFolder()
		else
			local b, n, _ = buildMissileBody()
			body = b
			nose = n
			orientMissile(body, (nose :: BasePart), startPos, startPos + initialTangent)
			body.Parent = ensureFolder()
			rootVisual = body
		end
	end

	local startedAt = os.clock()
	activeCount += 1

	local function placeAt(alpha: number)
		local pos = trajectory(alpha)
		-- Tangent from a tiny step ahead so the missile pitches up/down along
		-- the arc (up on ascent, flat at apex, down on descent).
		local ahead = trajectory(math.min(alpha + 0.01, 2.0))
		local tangent = ahead - pos
		if tangent.Magnitude < 0.001 then
			tangent = Vector3.new(0, 0, 1)
		end
		if useTemplate then
			-- Template: long axis = local +X → yaw +90°.
			local cf = CFrame.lookAt(pos, pos + tangent) * CFrame.Angles(0, math.rad(-90), 0)
			if rootVisual:IsA("Model") then
				(rootVisual :: Model):PivotTo(cf)
			else
				(rootVisual :: BasePart).CFrame = cf
			end
		else
			-- Primitive: long axis = local +Y → pitch -90°.
			local cf = CFrame.lookAt(pos, pos + tangent) * CFrame.Angles(math.rad(-90), 0, 0)
			body.CFrame = cf
			if nose then
				nose.CFrame = cf * CFrame.new(0, BODY_SIZE.Y * 0.5 + NOSE_SIZE.Y * 0.25, 0)
			end
		end
	end

	local function hideAndCleanup(lifetime: number)
		for _, d in ipairs(rootVisual:GetDescendants()) do
			if d:IsA("Sound") then
				d:Stop()
				d:Destroy()
			end
			if d:IsA("ParticleEmitter") or d:IsA("Trail") then
				d.Enabled = false
			end
			if d:IsA("BasePart") then
				d.Transparency = 1
			end
		end
		if rootVisual:IsA("BasePart") then
			(rootVisual :: BasePart).Transparency = 1
		end
		Debris:AddItem(rootVisual, lifetime)
		activeCount = math.max(0, activeCount - 1)
	end

	-- Fly-off missiles coast past the endpoint, so we let alpha go up to 1.8.
	local maxAlpha = if willExplode then 1.0 else 1.8

	local conn: RBXScriptConnection? = nil
	conn = RunService.RenderStepped:Connect(function()
		if not rootVisual.Parent then
			if conn then conn:Disconnect() end
			return
		end
		local alpha = (os.clock() - startedAt) / flightDuration

		if willExplode and alpha >= explodeFraction then
			if conn then conn:Disconnect() end
			spawnExplosion(trajectory(math.min(alpha, 1)))
			hideAndCleanup(2.5)
			return
		end

		if not willExplode and alpha >= maxAlpha then
			if conn then conn:Disconnect() end
			hideAndCleanup(3.0)
			return
		end

		placeAt(alpha)
	end)
end

function SkyMissileAmbience.Start()
	if running then
		return
	end
	running = true
	refreshAmbientMissileFlybySounds()
	if RunService:IsStudio() then
		print("[SkyMissileAmbience] started — ambient sky missiles active")
	end

	task.spawn(function()
		task.wait(1.0)
		if RunService:IsStudio() then
			print("[SkyMissileAmbience] loop entering, MAX_CONCURRENT=" .. MAX_CONCURRENT)
		end
		while running do
			if activeCount < MAX_CONCURRENT then
				local ok, err = pcall(launchMissile)
				if not ok then
					warn("[SkyMissileAmbience] launch failed:", err)
				end
			end
			task.wait(rng:NextNumber(MIN_INTERVAL, MAX_INTERVAL))
		end
	end)
end

function SkyMissileAmbience.Stop()
	running = false
end

if LocalPlayer then
	LocalPlayer:GetAttributeChangedSignal(Constants.CurrentWorldAttribute):Connect(refreshAmbientMissileFlybySounds)
end

return SkyMissileAmbience

