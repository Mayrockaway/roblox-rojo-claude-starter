--!strict
-- Cosmetic world feedback for StraitWaypointEvent (SPEC §8.2). Server remains authoritative;
-- all clients spawn local copies from the same replicated packet (start aligned when server fires before hold).
--
-- Workflow: author VFX under ReplicatedStorage.Assets.StraitWaypointsFx.<eventId>/ (clone at runtime; do not Instance.new art).
-- Optional: EVENT_FX[id] for attach logic (e.g. weld to boat). No generic severity particle fallbacks.

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

-- Bounded waits: avoid infinite yield if ReplicatedStorage is slow or Shared is missing in a test place.
local ParticleFxScale: {
	ApplyToEmitter: (ParticleEmitter, number) -> (),
	ApplyToDescendants: (Instance, number) -> (),
} = {
	ApplyToEmitter = function() end,
	ApplyToDescendants = function() end,
}
local sharedFolder = ReplicatedStorage:WaitForChild("Shared", 45)
local StraitAssetManifest = nil
if sharedFolder then
	local pfsMod = sharedFolder:FindFirstChild("ParticleFxScale") or sharedFolder:WaitForChild("ParticleFxScale", 30)
	if pfsMod and pfsMod:IsA("ModuleScript") then
		local ok, loaded = pcall(require, pfsMod)
		if ok and typeof(loaded) == "table" then
			ParticleFxScale = loaded :: any
		end
	end
	local configFolder = sharedFolder:FindFirstChild("Config")
	local straitEventsFolder = configFolder and configFolder:FindFirstChild("StraitEvents")
	local manifestMod = straitEventsFolder and straitEventsFolder:FindFirstChild("AssetManifest")
	if manifestMod and manifestMod:IsA("ModuleScript") then
		local okManifest, loadedManifest = pcall(require, manifestMod)
		if okManifest and typeof(loadedManifest) == "table" then
			StraitAssetManifest = loadedManifest
		end
	end
end

-- ReplicatedStorage.Assets.StraitWaypointsFx.<CatalogEventId>/ — Models or Parts as direct children; Sounds play when cloned.
local STRAIT_FX_ASSETS_FOLDER = "StraitWaypointsFx"

local function getStraitFxRoot(): Instance?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	return assets and assets:FindFirstChild(STRAIT_FX_ASSETS_FOLDER)
end

local function getEventFxFolder(eventId: string): Instance?
	local root = getStraitFxRoot()
	return if root then root:FindFirstChild(eventId) else nil
end

local function cloneNamedDescendant(folder: Instance?, name: string): Instance?
	if not folder then
		return nil
	end
	local found = folder:FindFirstChild(name, true)
	if not found then
		return nil
	end
	return found:Clone()
end

local function validateStraitEventAssets()
	if not RunService:IsStudio() then
		return
	end
	if typeof(StraitAssetManifest) ~= "table" or typeof((StraitAssetManifest :: any).Events) ~= "table" then
		return
	end

	local events = (StraitAssetManifest :: any).Events
	local fxRoot = getStraitFxRoot()
	if not fxRoot then
		warn("[StraitWaypointWorldFx] Missing ReplicatedStorage.Assets.StraitWaypointsFx")
		return
	end

	for eventId, spec in pairs(events) do
		if typeof(spec) ~= "table" then
			continue
		end
		local folderName = if typeof(spec.folderName) == "string" and spec.folderName ~= "" then spec.folderName else eventId
		local folder = fxRoot:FindFirstChild(folderName)
		if not folder then
			warn(string.format("[StraitWaypointWorldFx] Missing asset folder for %s: %s", tostring(eventId), folderName))
			continue
		end

		local expected = spec.expectedInstances
		if typeof(expected) == "table" then
			for _, expectedName in ipairs(expected) do
				if typeof(expectedName) == "string" and expectedName ~= "" then
					local exists = folder:FindFirstChild(expectedName, true)
					if not exists then
						warn(string.format(
							"[StraitWaypointWorldFx] Missing expected asset '%s' under %s (%s).",
							expectedName,
							folderName,
							tostring(eventId)
						))
					end
				end
			end
		end
	end
end

local function particleFxScaleFromPayload(data: { [string]: any }): number
	local s = tonumber(data.particleFxScale)
	if s == nil or s ~= s or s <= 0 then
		return 1
	end
	return s
end

local function stripRuntimeScripts(root: Instance)
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("Script") or d:IsA("LocalScript") then
			d:Destroy()
		end
	end
end

local function prepareStraitFxClone(root: Instance)
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
		end
	end
end

local function setAllParticleEmittersEnabled(root: Instance, enabled: boolean)
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Beam") then
			(d :: any).Enabled = enabled
		end
	end
end

local function setParticleEmittersOnlyEnabled(root: Instance, enabled: boolean)
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("ParticleEmitter") then
			d.Enabled = enabled
		end
	end
end

local function playClonedSounds(root: Instance)
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("Sound") then
			d.RollOffMaxDistance = math.max(d.RollOffMaxDistance, 140)
			d:Play()
		end
	end
end

local function containerHasAnyBasePart(container: Instance): boolean
	for _, d in ipairs(container:GetDescendants()) do
		if d:IsA("BasePart") then
			return true
		end
	end
	return false
end

--- Clone everything under Assets.StraitWaypointsFx.<eventId> to `worldPos`. Returns true if a template was used.
local function tryPlayStraitFxFromAssets(eventId: string, worldPos: Vector3, holdSeconds: number, shipParticleFxScale: number): boolean
	local eventFolder = getEventFxFolder(eventId)
	if not (eventFolder and (eventFolder:IsA("Folder") or eventFolder:IsA("Model"))) then
		return false
	end

	local children = eventFolder:GetChildren()
	if #children == 0 then
		return false
	end

	local duration = math.clamp(holdSeconds, 0.25, 14)
	local worldCFrame = CFrame.new(worldPos)

	local container = Instance.new("Model")
	container.Name = "StraitFx_" .. eventId
	container.Parent = Workspace

	for _, child in ipairs(children) do
		local c = child:Clone()
		c.Parent = container
		if c:IsA("Model") then
			c:PivotTo(worldCFrame)
		elseif c:IsA("BasePart") then
			c.CFrame = worldCFrame
		end
	end

	if not containerHasAnyBasePart(container) then
		container:Destroy()
		return false
	end

	stripRuntimeScripts(container)
	prepareStraitFxClone(container)
	ParticleFxScale.ApplyToDescendants(container, shipParticleFxScale)
	setAllParticleEmittersEnabled(container, true)
	playClonedSounds(container)

	task.delay(duration, function()
		if container.Parent then
			setAllParticleEmittersEnabled(container, false)
		end
	end)

	local debrisAfter = duration + 4
	Debris:AddItem(container, debrisAfter)
	return true
end

local function vector3FromWorldPosition(raw: any): Vector3?
	if typeof(raw) ~= "table" then
		return nil
	end
	local x, y, z = raw.x, raw.y, raw.z
	if typeof(x) ~= "number" or typeof(y) ~= "number" or typeof(z) ~= "number" then
		return nil
	end
	if x ~= x or y ~= y or z ~= z then
		return nil
	end
	return Vector3.new(x, y, z)
end

local ROUTINE_PAPERWORK_ID = "RoutinePaperwork"
local ROUTINE_PAPERWORK_DECK_OFFSET = CFrame.new(0, 8, 0)

local function findActiveShipmentBoatByShipmentId(shipmentId: string): Model?
	if shipmentId == "" then
		return nil
	end
	for _, inst in ipairs(Workspace:GetDescendants()) do
		if inst:IsA("Model") and inst.Name == "ActiveShipmentBoat" then
			local attr = inst:GetAttribute("ShipmentId")
			if attr ~= nil and tostring(attr) == shipmentId then
				return inst
			end
		end
	end
	return nil
end

local function getBoatAttachmentPart(boat: Model): BasePart?
	if boat.PrimaryPart then
		return boat.PrimaryPart
	end
	local best: BasePart? = nil
	local bestVol = 0
	for _, d in ipairs(boat:GetDescendants()) do
		if d:IsA("BasePart") then
			local v = d.Size.X * d.Size.Y * d.Size.Z
			if v > bestVol then
				bestVol = v
				best = d
			end
		end
	end
	return best
end

local function getInstanceWorldCFrame(inst: Instance): CFrame?
	if inst:IsA("Model") then
		return inst:GetPivot()
	end
	if inst:IsA("BasePart") then
		return inst.CFrame
	end
	return nil
end

local function getInstanceWorldPosition(inst: Instance): Vector3?
	local cf = getInstanceWorldCFrame(inst)
	return if cf then cf.Position else nil
end

local function setInstanceWorldCFrame(inst: Instance, cf: CFrame)
	if inst:IsA("Model") then
		inst:PivotTo(cf)
	elseif inst:IsA("BasePart") then
		inst.CFrame = cf
	end
end

local function getInstanceHalfHeight(inst: Instance): number
	if inst:IsA("BasePart") then
		return math.max(0.5, inst.Size.Y * 0.5)
	end
	if inst:IsA("Model") then
		local _, size = inst:GetBoundingBox()
		return math.max(0.5, size.Y * 0.5)
	end

	local minY = math.huge
	local maxY = -math.huge
	for _, d in ipairs(inst:GetDescendants()) do
		if d:IsA("BasePart") then
			local p = d.Position
			local h = d.Size.Y * 0.5
			minY = math.min(minY, p.Y - h)
			maxY = math.max(maxY, p.Y + h)
		end
	end
	if minY < maxY then
		return math.max(0.5, (maxY - minY) * 0.5)
	end
	return 12
end

local function getInstanceHorizontalRadius(inst: Instance): number
	if inst:IsA("BasePart") then
		return math.max(6, math.max(inst.Size.X, inst.Size.Z) * 0.5)
	end
	if inst:IsA("Model") then
		local _, size = inst:GetBoundingBox()
		return math.max(6, math.max(size.X, size.Z) * 0.5)
	end

	local minX, maxX = math.huge, -math.huge
	local minZ, maxZ = math.huge, -math.huge
	for _, d in ipairs(inst:GetDescendants()) do
		if d:IsA("BasePart") then
			local p = d.Position
			local hX = d.Size.X * 0.5
			local hZ = d.Size.Z * 0.5
			minX = math.min(minX, p.X - hX)
			maxX = math.max(maxX, p.X + hX)
			minZ = math.min(minZ, p.Z - hZ)
			maxZ = math.max(maxZ, p.Z + hZ)
		end
	end
	if minX < maxX and minZ < maxZ then
		return math.max(6, math.max(maxX - minX, maxZ - minZ) * 0.5)
	end
	return 60
end

local function getInstanceBaseOffset(inst: Instance): number
	if inst:IsA("BasePart") then
		return math.max(0.5, inst.Size.Y * 0.5)
	end
	if inst:IsA("Model") then
		local pivot = inst:GetPivot().Position
		local minY = math.huge
		for _, d in ipairs(inst:GetDescendants()) do
			if d:IsA("BasePart") then
				local y = d.Position.Y - d.Size.Y * 0.5
				minY = math.min(minY, y)
			end
		end
		if minY < math.huge then
			return math.max(0.5, pivot.Y - minY)
		end
	end
	return getInstanceHalfHeight(inst)
end

local function getTornadoVerticalMeshLift(inst: Instance, halfHeight: number): number
	-- Do not apply static mesh lift; tornado base is corrected dynamically per-frame against water/boat surface.
	local _ = inst
	local _h = halfHeight
	return 0
end

local function scaleTornadoRoot(root: Instance, scaleFactor: number)
	if scaleFactor <= 0 or math.abs(scaleFactor - 1) < 0.001 then
		return
	end
	if root:IsA("Model") then
		pcall(function()
			(root :: Model):ScaleTo(scaleFactor)
		end)
	elseif root:IsA("BasePart") then
		root.Size *= scaleFactor
		for _, d in ipairs(root:GetDescendants()) do
			if d:IsA("SpecialMesh") then
				d.Scale *= scaleFactor
			end
		end
	end
end

local function moveRootToWorldPosition(root: Instance, worldPos: Vector3)
	if root:IsA("Model") then
		root:PivotTo(CFrame.new(worldPos))
		return
	end
	if root:IsA("BasePart") then
		root.CFrame = CFrame.new(worldPos)
		return
	end

	local parts = {}
	local centroid = Vector3.zero
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then
			table.insert(parts, d)
			centroid += d.Position
		end
	end
	if #parts == 0 then
		return
	end
	centroid /= #parts
	local delta = worldPos - centroid
	for _, p in ipairs(parts) do
		p.CFrame = p.CFrame + delta
	end
end

local function prepareKinematicFx(root: Instance)
	stripRuntimeScripts(root)
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Massless = true
		end
	end
end

local function cloneEventAsset(eventId: string, assetName: string): Instance?
	local folder = getEventFxFolder(eventId)
	return cloneNamedDescendant(folder, assetName)
end

local function cloneStormCloudTemplate(): Instance?
	local cloud = cloneEventAsset("Storm", "CloudRig")
	if not cloud then
		return nil
	end
	if cloud:IsA("Model") or cloud:IsA("BasePart") then
		return cloud
	end
	cloud:Destroy()
	return nil
end

local function cloneRenderableEventRoot(eventId: string, assetName: string): Instance?
	local root = cloneEventAsset(eventId, assetName)
	if not root then
		return nil
	end
	if root:IsA("Model") or root:IsA("BasePart") then
		return root
	end
	root:Destroy()
	return nil
end

local function cloneParticleEmitterTemplate(eventId: string, assetName: string): Instance?
	local function coerceTemplate(inst: Instance): Instance?
		if inst:IsA("ParticleEmitter") or inst:IsA("Attachment") or inst:IsA("BasePart") then
			return inst
		end

		local emitter = inst:FindFirstChildWhichIsA("ParticleEmitter", true)
		if emitter then
			local out = emitter:Clone()
			inst:Destroy()
			return out
		end

		local attachment = inst:FindFirstChildWhichIsA("Attachment", true)
		if attachment then
			local out = attachment:Clone()
			inst:Destroy()
			return out
		end

		local basePart = inst:FindFirstChildWhichIsA("BasePart", true)
		if basePart then
			local out = basePart:Clone()
			inst:Destroy()
			return out
		end

		inst:Destroy()
		return nil
	end

	local named = cloneEventAsset(eventId, assetName)
	if named then
		local coerced = coerceTemplate(named)
		if coerced then
			return coerced
		end
	end
	return nil
end

local function playSoundTemplateOn(root: Instance, eventId: string, assetName: string, volumeScale: number?)
	local template = cloneEventAsset(eventId, assetName)
	if not template or not template:IsA("Sound") then
		if template then
			template:Destroy()
		end
		return
	end
	local s = template
	s.Parent = root
	s.Volume = s.Volume * (volumeScale or 1)
	s.RollOffMaxDistance = math.max(s.RollOffMaxDistance, 220)
	s.Ended:Connect(function()
		s:Destroy()
	end)
	s:Play()
end

local function shakeCameraIfNear(center: Vector3, radius: number, intensity: number, duration: number)
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	local dist = (cam.CFrame.Position - center).Magnitude
	if dist > radius then
		return
	end
	local distFactor = 1 - math.clamp(dist / math.max(radius, 1), 0, 1)
	local amp = intensity * distFactor
	if amp <= 0 then
		return
	end
	task.spawn(function()
		local rng = Random.new()
		local elapsed = 0
		while elapsed < duration do
			local dt = task.wait()
			elapsed += dt
			local fade = 1 - math.clamp(elapsed / duration, 0, 1)
			cam.CFrame *= CFrame.new(
				rng:NextNumber(-amp, amp) * fade,
				rng:NextNumber(-amp, amp) * fade,
				0
			)
		end
	end)
end

local function buildFallbackCloudLayer(parent: Instance, center: Vector3)
	local rng = Random.new()
	for i = 1, 6 do
		local p = Instance.new("Part")
		p.Name = "StormCloudFallback"
		p.Shape = Enum.PartType.Ball
		p.Size = Vector3.new(rng:NextNumber(45, 70), rng:NextNumber(20, 28), rng:NextNumber(45, 70))
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.Material = Enum.Material.SmoothPlastic
		p.Color = Color3.fromRGB(36, 39, 47)
		p.Transparency = rng:NextNumber(0.2, 0.4)
		p.CFrame = CFrame.new(
			center + Vector3.new(rng:NextNumber(-45, 45), rng:NextNumber(48, 62), rng:NextNumber(-45, 45))
		)
		p.Parent = parent
	end
end

-- Texture IDs sourced from the CloudRig RainHandler asset (rbxassetid).
local RAIN_DROPS_TEXTURE = "rbxassetid://241868005"
local RAIN_SPLASH_TEXTURE = "rbxassetid://241576804"

local STORM_CLOUD_HEIGHT_OFFSET = 82
local STORM_RAIN_HEIGHT_OFFSET = 56

-- Mirrors the CloudRig RainHandler.Drops emitter pattern:
-- negative speed + EmissionDirection=Top = straight downfall.
-- Area coverage comes from the large host Part size, not from SpreadAngle.
local function addStormDropsEmitter(host: BasePart)
	local e = Instance.new("ParticleEmitter")
	e.Name = "StormRainDrops"
	e.Rate = 2000000
	e.Lifetime = NumberRange.new(6, 8)
	e.Speed = NumberRange.new(-110, -80)
	e.EmissionDirection = Enum.NormalId.Top
	e.SpreadAngle = Vector2.new(0, 0)
	e.VelocitySpread = 0
	e.Acceleration = Vector3.new(8, 0, 0)
	e.LightInfluence = 0
	e.LightEmission = 1
	e.Texture = RAIN_DROPS_TEXTURE
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 2.0),
		NumberSequenceKeypoint.new(0.9, 2.0),
		NumberSequenceKeypoint.new(1, 0.0),
	})
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(0.85, 0.35),
		NumberSequenceKeypoint.new(1, 1.0),
	})
	e.Color = ColorSequence.new(Color3.fromRGB(180, 195, 215))
	e.Parent = host
end

-- Fallback splash emitter when RS RainHandler has no usable emitters.
local function addFallbackSplashEmitter(host: BasePart)
	local e = Instance.new("ParticleEmitter")
	e.Name = "StormRainSplash"
	e.Rate = 5000000
	e.Lifetime = NumberRange.new(0.5, 0.5)
	e.Speed = NumberRange.new(3, 3)
	e.EmissionDirection = Enum.NormalId.Top
	e.SpreadAngle = Vector2.new(0, 0)
	e.VelocitySpread = 0
	e.LightInfluence = 0
	e.LightEmission = 1
	e.Texture = RAIN_SPLASH_TEXTURE
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.0),
		NumberSequenceKeypoint.new(0.2, 0.4),
		NumberSequenceKeypoint.new(1, 0.0),
	})
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(1, 1.0),
	})
	e.Color = ColorSequence.new(Color3.fromRGB(180, 200, 220))
	e.Parent = host
end

-- Creates two large transparent parts:
--   DropsPart  — at cloud height; emitters rain straight down across the full footprint.
--   SplashesPart — flat at water level; RS RainHandler splash emitters fire upward here.
-- This matches the CloudRig RainHandler structure (Drops + Splashes, area-based, no spread angle).
local function buildStormRainLayers(
	container: Instance,
	centerPos: Vector3,
	cloudRadius: number,
	fxScale: number
): (BasePart, BasePart)
	local areaSize = math.min(cloudRadius * 2 + 24, 340)
	local emitterCount = math.clamp(math.floor(fxScale * 4 + 0.5), 3, 6)

	-- Drops: large part at cloud/rain height, N emitters for density scaling.
	local dropsPart = Instance.new("Part")
	dropsPart.Name = "StormRainDropsPart"
	dropsPart.Size = Vector3.new(areaSize, 20, areaSize)
	dropsPart.CFrame = CFrame.new(centerPos + Vector3.new(0, STORM_RAIN_HEIGHT_OFFSET, 0))
	dropsPart.Anchored = true
	dropsPart.CanCollide = false
	dropsPart.CanQuery = false
	dropsPart.CanTouch = false
	dropsPart.Transparency = 1
	dropsPart.Parent = container
	for _ = 1, emitterCount do
		addStormDropsEmitter(dropsPart)
	end

	-- Splashes: flat part just above water/deck level.
	local splashesPart = Instance.new("Part")
	splashesPart.Name = "StormRainSplashesPart"
	splashesPart.Size = Vector3.new(areaSize, 0.05, areaSize)
	splashesPart.CFrame = CFrame.new(centerPos + Vector3.new(0, 2, 0))
	splashesPart.Anchored = true
	splashesPart.CanCollide = false
	splashesPart.CanQuery = false
	splashesPart.CanTouch = false
	splashesPart.Transparency = 1
	splashesPart.Parent = container

	-- Use RS RainHandler splash emitters (they're designed for impact-at-surface use).
	local stormFolder = getEventFxFolder("Storm")
	local rsRainHandler = stormFolder and stormFolder:FindFirstChild("RainHandler", true)
	local splashCount = 0
	local MAX_RS_SPLASH_EMITTERS = 5
	if rsRainHandler then
		for _, d in ipairs(rsRainHandler:GetDescendants()) do
			if d:IsA("ParticleEmitter") and splashCount < MAX_RS_SPLASH_EMITTERS then
				local clone = d:Clone()
				clone.Enabled = true
				clone.Parent = splashesPart
				splashCount += 1
			end
		end
	end
	if splashCount == 0 then
		addFallbackSplashEmitter(splashesPart)
	end

	return dropsPart, splashesPart
end

local function createLightningStrikeVisual(parent: Instance, top: Vector3, bottom: Vector3)
	local rng = Random.new()
	local bolt = Instance.new("Model")
	bolt.Name = "StormLightningBolt"
	bolt.Parent = parent

	local steps = rng:NextInteger(5, 8)
	local prev = top
	for i = 1, steps do
		local alpha = i / steps
		local target = top:Lerp(bottom, alpha)
		local jitterScale = (1 - alpha) * 9
		local jitter = if i == steps
			then Vector3.zero
			else Vector3.new(rng:NextNumber(-jitterScale, jitterScale), rng:NextNumber(-2, 2), rng:NextNumber(-jitterScale, jitterScale))
		local nextPos = target + jitter
		local delta = nextPos - prev
		local length = delta.Magnitude
		if length > 0.2 then
			local segment = Instance.new("Part")
			segment.Name = "StormLightningSegment"
			segment.Anchored = true
			segment.CanCollide = false
			segment.CanQuery = false
			segment.CanTouch = false
			segment.Material = Enum.Material.Neon
			segment.Color = Color3.fromRGB(235, 245, 255)
			segment.Transparency = 0.03
			segment.Size = Vector3.new(rng:NextNumber(0.75, 1.45), length, rng:NextNumber(0.75, 1.45))
			segment.CFrame = CFrame.lookAt((prev + nextPos) * 0.5, nextPos) * CFrame.Angles(math.pi / 2, 0, 0)
			segment.Parent = bolt
		end
		prev = nextPos
	end

	local glow = Instance.new("PointLight")
	glow.Color = Color3.fromRGB(230, 240, 255)
	glow.Brightness = 16
	glow.Range = 190
	glow.Parent = bolt

	local flashes = { 0.03, 0.16, 0.05, 0.11 }
	local totalFlashDuration = 0
	for _, t in ipairs(flashes) do
		totalFlashDuration += t + 0.02
	end

	task.spawn(function()
		for _, t in ipairs(flashes) do
			for _, d in ipairs(bolt:GetDescendants()) do
				if d:IsA("BasePart") then
					d.Transparency = 0.03
				end
			end
			task.wait(t)
			for _, d in ipairs(bolt:GetDescendants()) do
				if d:IsA("BasePart") then
					d.Transparency = 0.92
				end
			end
			task.wait(0.02)
		end
	end)

	Debris:AddItem(bolt, totalFlashDuration + 0.22)
end

local function collectDeckBarrelInstances(boat: Model): { Instance }
	local barrels = {}
	for _, d in ipairs(boat:GetDescendants()) do
		if d.Name == "DeckBarrel" and (d:IsA("Model") or d:IsA("BasePart")) and d.Parent then
			table.insert(barrels, d)
		end
	end
	table.sort(barrels, function(a, b)
		local ap = getInstanceWorldPosition(a) or Vector3.zero
		local bp = getInstanceWorldPosition(b) or Vector3.zero
		return ap.Y > bp.Y
	end)
	return barrels
end

local function createFallbackBarrelVisual(startPos: Vector3): BasePart
	local p = Instance.new("Part")
	p.Name = "TornadoBarrelFallback"
	p.Shape = Enum.PartType.Cylinder
	p.Size = Vector3.new(2, 3, 2)
	p.Material = Enum.Material.Metal
	p.Color = Color3.fromRGB(148, 103, 43)
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CFrame = CFrame.new(startPos) * CFrame.Angles(0, 0, math.rad(90))
	return p
end

local function horizontalDistanceXZ(a: Vector3, b: Vector3): number
	local dx = a.X - b.X
	local dz = a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

local function resolveShipmentBoatWithTimeout(shipmentId: string, timeoutSeconds: number): Model?
	if shipmentId == "" then
		return nil
	end
	local deadline = os.clock() + math.max(0, timeoutSeconds)
	repeat
		local boat = findActiveShipmentBoatByShipmentId(shipmentId)
		if boat then
			return boat
		end
		task.wait(0.05)
	until os.clock() >= deadline
	return nil
end

local function getTornadoBoatFrame(
	boat: Model?,
	fallbackPivot: Vector3,
	fallbackBounds: Vector3
): (Vector3, Vector3, CFrame?)
	if boat and boat.Parent then
		local ok, cf, size = pcall(function()
			local bbCf, bbSize = boat:GetBoundingBox()
			return bbCf, bbSize
		end)
		if ok and cf and size then
			return (cf :: CFrame).Position, (size :: Vector3), (cf :: CFrame)
		end
	end
	return fallbackPivot, fallbackBounds, nil
end

local function estimateTornadoWaterY(pivotPos: Vector3, boundsSize: Vector3, fallbackY: number): number
	local waterOffset = math.clamp(boundsSize.Y * 0.38, 2, 12)
	return math.min(fallbackY, pivotPos.Y - waterOffset)
end

local function isPointInsideBoatFootprint(point: Vector3, center: Vector3, bounds: Vector3, frame: CFrame?): boolean
	local halfX = math.max(4, bounds.X * 0.55)
	local halfZ = math.max(4, bounds.Z * 0.55)
	if frame then
		local localPos = frame:PointToObjectSpace(point)
		return math.abs(localPos.X) <= halfX and math.abs(localPos.Z) <= halfZ
	end
	return math.abs(point.X - center.X) <= halfX and math.abs(point.Z - center.Z) <= halfZ
end

local function getInstanceMinY(inst: Instance): number
	if inst:IsA("BasePart") then
		return inst.Position.Y - inst.Size.Y * 0.5
	end
	if inst:IsA("Model") then
		local minY = math.huge
		for _, d in ipairs(inst:GetDescendants()) do
			if d:IsA("BasePart") then
				minY = math.min(minY, d.Position.Y - d.Size.Y * 0.5)
			end
		end
		if minY < math.huge then
			return minY
		end
	end
	return -math.huge
end

local function sampleBoatSurfaceY(
	boat: Model,
	shipCenter: Vector3,
	point: Vector3,
	searchRadius: number,
	rayTopY: number,
	maxSurfaceY: number
): (number?, boolean)
	local _shipCenter = shipCenter
	local _searchRadius = searchRadius
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Include
	rayParams.FilterDescendantsInstances = { boat }
	rayParams.IgnoreWater = true
	local rayOrigin = Vector3.new(point.X, rayTopY, point.Z)
	local rayDir = Vector3.new(0, -math.max(160, rayTopY + 80), 0)
	local hit = Workspace:Raycast(rayOrigin, rayDir, rayParams)
	if not hit then
		return nil, false
	end
	local rayY = math.min(maxSurfaceY, hit.Position.Y)
	return rayY, true
end

local function spawnTornadoBarrelChaos(
	container: Instance,
	boat: Model,
	chaosCenter: Vector3,
	barrelsLost: number,
	maxVisualBarrels: number
)
	local rng = Random.new()
	local deckBarrels = collectDeckBarrelInstances(boat)
	local toThrow = math.min(barrelsLost, #deckBarrels, maxVisualBarrels)
	for i = 1, toThrow do
		local source = deckBarrels[i]
		local sourcePos = getInstanceWorldPosition(source)
		if not sourcePos then
			continue
		end
		local sourceStart = sourcePos

		task.spawn(function()
			task.wait((i - 1) * 0.07)

			local visual: Instance
			if source:IsA("Model") or source:IsA("BasePart") then
				visual = source:Clone()
				prepareKinematicFx(visual)
				setInstanceWorldCFrame(visual, CFrame.new(sourceStart))
			else
				visual = createFallbackBarrelVisual(sourceStart)
			end
			visual.Parent = container

			local pullTarget = chaosCenter + Vector3.new(
				rng:NextNumber(-10, 10),
				rng:NextNumber(18, 30),
				rng:NextNumber(-10, 10)
			)
			local throwTarget = chaosCenter + Vector3.new(
				rng:NextNumber(85, 150) * (if rng:NextNumber() < 0.5 then -1 else 1),
				rng:NextNumber(8, 24),
				rng:NextNumber(85, 150) * (if rng:NextNumber() < 0.5 then -1 else 1)
			)

			local pullDur = rng:NextNumber(0.32, 0.55)
			local t0 = os.clock()
			while visual.Parent and (os.clock() - t0) < pullDur do
				local a = math.clamp((os.clock() - t0) / pullDur, 0, 1)
				local eased = a * a * (3 - 2 * a)
				local p = sourceStart:Lerp(pullTarget, eased) + Vector3.new(0, math.sin(eased * math.pi) * 8, 0)
				setInstanceWorldCFrame(visual, CFrame.new(p) * CFrame.Angles(a * 8, a * 9, a * 6))
				task.wait()
			end

			local throwDur = rng:NextNumber(0.5, 0.88)
			local t1 = os.clock()
			while visual.Parent and (os.clock() - t1) < throwDur do
				local a = math.clamp((os.clock() - t1) / throwDur, 0, 1)
				local eased = a * a * (3 - 2 * a)
				local p = pullTarget:Lerp(throwTarget, eased) + Vector3.new(0, math.sin((1 - eased) * math.pi) * 10, 0)
				setInstanceWorldCFrame(visual, CFrame.new(p) * CFrame.Angles(a * 14, a * 12, a * 15))
				task.wait()
			end

			if visual.Parent then
				visual:Destroy()
			end
		end)
	end
end

--- Template lives in RS only: clone, then scale + parent/weld. Tune ParticleEmitter/Sound on the template in Studio (not in Luau).
local function getRoutinePaperworkAnchorTemplate(): BasePart?
	local folder = getEventFxFolder(ROUTINE_PAPERWORK_ID)
	local tmpl = folder and folder:FindFirstChild("RoutinePaperworkAnchor")
	if tmpl and tmpl:IsA("BasePart") then
		return tmpl
	end
	return nil
end

local function playRoutinePaperworkFx(worldPos: Vector3, holdSeconds: number, data: { [string]: any })
	local fxScale = particleFxScaleFromPayload(data)
	local duration = math.clamp(holdSeconds, 0.25, 14)

	local anchorTmpl = getRoutinePaperworkAnchorTemplate()
	if not anchorTmpl then
		warn("[StraitWaypointWorldFx] Missing ReplicatedStorage.Assets.StraitWaypointsFx.RoutinePaperwork.RoutinePaperworkAnchor")
		return
	end

	local anchor = anchorTmpl:Clone() :: BasePart
	anchor.Name = "RoutinePaperworkFxAnchor"
	anchor.Anchored = false
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Massless = true
	anchor.Transparency = 1

	local emitter = anchor:FindFirstChildOfClass("ParticleEmitter")
	local soundTmpl = anchor:FindFirstChild("RoutinePaperworkBurst")
	if not emitter then
		anchor:Destroy()
		warn("[StraitWaypointWorldFx] RoutinePaperworkAnchor has no ParticleEmitter")
		return
	end
	if not (soundTmpl and soundTmpl:IsA("Sound")) then
		soundTmpl = nil
	end

	-- Burst uses Rate=0 + Emit; keep template emitter off between bursts.
	emitter.Rate = 0
	emitter.Enabled = false
	ParticleFxScale.ApplyToEmitter(emitter, fxScale)

	local shipmentId = if typeof(data.shipmentId) == "string" then data.shipmentId else ""
	local boat = if shipmentId ~= "" then findActiveShipmentBoatByShipmentId(shipmentId) else nil
	local attachPart = if boat then getBoatAttachmentPart(boat) else nil

	if attachPart and boat then
		anchor.Parent = boat
		anchor.CFrame = attachPart.CFrame * ROUTINE_PAPERWORK_DECK_OFFSET
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = attachPart
		weld.Part1 = anchor
		weld.Parent = anchor
	else
		anchor.Anchored = true
		anchor.CFrame = CFrame.new(worldPos) * ROUTINE_PAPERWORK_DECK_OFFSET
		anchor.Parent = Workspace
	end

	local rng = Random.new()
	local deadline = os.clock() + duration

	local function playBurstSound()
		if not soundTmpl or not soundTmpl:IsA("Sound") then
			return
		end
		local s = soundTmpl:Clone()
		s.Parent = anchor
		s.RollOffMaxDistance = math.max(s.RollOffMaxDistance, 120)
		s.Ended:Connect(function()
			s:Destroy()
		end)
		s:Play()
	end

	local function burst()
		playBurstSound()
		emitter.Enabled = true
		emitter:Emit(rng:NextInteger(10, 18))
		task.delay(0.08, function()
			emitter.Enabled = false
		end)
	end

	task.spawn(function()
		-- Stagger first burst, but never spend more than a fraction of a short hold before starting.
		local firstWait = math.min(0.65, duration * 0.15)
		if firstWait > 0 and os.clock() + firstWait < deadline then
			task.wait(firstWait)
		end

		while emitter.Parent ~= nil and os.clock() < deadline do
			burst()
			if os.clock() >= deadline then
				break
			end
			local gap = rng:NextNumber(1.35, 2.85)
			if rng:NextNumber() < 0.3 then
				gap += rng:NextNumber(0.55, 1.5)
			end
			gap = math.min(gap, math.max(0, deadline - os.clock()))
			if gap <= 0 then
				break
			end
			task.wait(gap)
		end
		emitter.Enabled = false
	end)

	local maxParticleLife = 2.2
	Debris:AddItem(anchor, duration + maxParticleLife + 1.5)
end

-- Per-event Luau implementations (world position, hold seconds, full payload). Runs before generic asset-folder clone.
type EventFxFn = (Vector3, number, { [string]: any }) -> ()

local EVENT_FX: { [string]: EventFxFn } = {
	RoutinePaperwork = playRoutinePaperworkFx,
}

local TweenService = game:GetService("TweenService")

local StraitWaypointWorldFx = {}
validateStraitEventAssets()

function StraitWaypointWorldFx.OnStraitWaypointPayload(data: { [string]: any })
	local pos = vector3FromWorldPosition(data.worldPosition)
	if not pos then
		return
	end

	local pause = tonumber(data.pauseSeconds)
	local hold = if typeof(pause) == "number" and pause == pause then pause else 5

	local id = if typeof(data.eventId) == "string" then data.eventId else ""
	local fxScale = particleFxScaleFromPayload(data)

	local custom = EVENT_FX[id]
	if custom then
		custom(pos, hold, data)
		return
	end

	if id ~= "" and tryPlayStraitFxFromAssets(id, pos, hold, fxScale) then
		return
	end
end

function StraitWaypointWorldFx.OnMissileStrikePayload(data: { [string]: any })
	local launchPos = vector3FromWorldPosition(data.launchPosition)
	local targetPos = vector3FromWorldPosition(data.targetPosition)
	if not launchPos or not targetPos then return end

	local outcome = if typeof(data.outcome) == "string" then data.outcome else "miss"
	local flightSeconds = tonumber(data.flightSeconds) or 2.5
	local shipmentId = if typeof(data.shipmentId) == "string" then data.shipmentId else ""

	task.spawn(function()
		local assets = ReplicatedStorage:FindFirstChild("Assets")
		local missileTemplate = assets and assets:FindFirstChild("Missile")

		-- Clone or create missile
		local missile
		if missileTemplate then
			missile = missileTemplate:Clone()
		else
			local p = Instance.new("Part")
			p.Name = "Missile"
			p.Size = Vector3.new(1.5, 1.5, 6)
			p.Material = Enum.Material.Metal
			p.Color = Color3.fromRGB(60, 65, 70)
			missile = p
		end

		-- Setup all parts: anchored, no collide
		if missile:IsA("Model") then
			for _, d in ipairs(missile:GetDescendants()) do
				if d:IsA("BasePart") then
					d.Anchored = true
					d.CanCollide = false
					d.CanQuery = false
					d.CanTouch = false
				end
			end
		elseif missile:IsA("BasePart") then
			missile.Anchored = true
			missile.CanCollide = false
			missile.CanQuery = false
			missile.CanTouch = false
		end

		-- Find a part to attach trail FX to
		local trailHost = if missile:IsA("BasePart") then missile else missile:FindFirstChildWhichIsA("BasePart")

		-- Smoke trail
		if trailHost then
			local smoke = Instance.new("ParticleEmitter")
			smoke.Name = "MissileSmoke"
			smoke.Rate = 120
			smoke.Lifetime = NumberRange.new(0.8, 2.0)
			smoke.Speed = NumberRange.new(3, 8)
			smoke.SpreadAngle = Vector2.new(12, 12)
			smoke.Size = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(1, 5),
			})
			smoke.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.2),
				NumberSequenceKeypoint.new(1, 1),
			})
			smoke.Color = ColorSequence.new(Color3.fromRGB(220, 220, 220), Color3.fromRGB(60, 60, 60))
			smoke.Parent = trailHost

			local fire = Instance.new("ParticleEmitter")
			fire.Name = "MissileFire"
			fire.Rate = 60
			fire.Lifetime = NumberRange.new(0.15, 0.4)
			fire.Speed = NumberRange.new(2, 5)
			fire.Size = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 2),
				NumberSequenceKeypoint.new(1, 0),
			})
			fire.Color = ColorSequence.new(Color3.fromRGB(255, 200, 50), Color3.fromRGB(255, 60, 10))
			fire.LightEmission = 1
			fire.Parent = trailHost

			-- Bright engine glow
			local glow = Instance.new("PointLight")
			glow.Brightness = 4
			glow.Range = 30
			glow.Color = Color3.fromRGB(255, 160, 40)
			glow.Parent = trailHost
		end

		-- Position at launch
		local startCF = CFrame.lookAt(launchPos, targetPos)
		if missile:IsA("Model") then
			missile:PivotTo(startCF)
		else
			missile.CFrame = startCF
		end
		missile.Parent = Workspace

		-- Fly missile using PivotTo (moves entire model)
		local startTime = os.clock()
		while true do
			local elapsed = os.clock() - startTime
			local alpha = math.min(elapsed / flightSeconds, 1)

			-- Slight arc: rise in first half, descend in second half
			local arcHeight = 15 * math.sin(alpha * math.pi)
			local pos = launchPos:Lerp(targetPos, alpha) + Vector3.new(0, arcHeight, 0)
			local lookTarget = launchPos:Lerp(targetPos, math.min(alpha + 0.05, 1)) + Vector3.new(0, 15 * math.sin(math.min(alpha + 0.05, 1) * math.pi), 0)
			local cf = CFrame.lookAt(pos, lookTarget)

			if missile:IsA("Model") then
				missile:PivotTo(cf)
			else
				missile.CFrame = cf
			end

			if alpha >= 1 then break end
			task.wait()
		end

		-- Kill trail emitters
		if trailHost then
			for _, e in ipairs(trailHost:GetChildren()) do
				if e:IsA("ParticleEmitter") then e.Enabled = false end
				if e:IsA("PointLight") then e:Destroy() end
			end
		end

		-- === IMPACT ===
		if outcome == "hit" or outcome == "smallHit" then
			local isDirectHit = outcome == "hit"
			local emitScale = isDirectHit and 1.0 or 0.4

			-- Explosion anchor
			local explosion = Instance.new("Part")
			explosion.Name = "MissileExplosion"
			explosion.Size = Vector3.new(1, 1, 1)
			explosion.Position = targetPos
			explosion.Anchored = true
			explosion.CanCollide = false
			explosion.CanQuery = false
			explosion.Transparency = 1
			explosion.Parent = Workspace

			-- Roblox shockwave ring on direct hit
			if isDirectHit then
				local rx = Instance.new("Explosion")
				rx.BlastRadius = 0
				rx.BlastPressure = 0
				rx.DestroyJointRadiusPercent = 0
				rx.Position = targetPos
				rx.Parent = Workspace
			end

			-- Blinding flash
			local flash = Instance.new("PointLight")
			flash.Brightness = isDirectHit and 15 or 5
			flash.Range = isDirectHit and 160 or 60
			flash.Color = Color3.fromRGB(255, 220, 100)
			flash.Parent = explosion
			task.delay(0.1, function() if flash.Parent then flash.Brightness = flash.Brightness * 0.4 end end)
			task.delay(0.4, function() if flash.Parent then flash:Destroy() end end)

			-- Fireball
			local fireball = Instance.new("ParticleEmitter")
			fireball.Rate = 0
			fireball.Lifetime = NumberRange.new(0.4, 1.2)
			fireball.Speed = NumberRange.new(25, 70)
			fireball.SpreadAngle = Vector2.new(180, 180)
			fireball.Size = NumberSequence.new({
				NumberSequenceKeypoint.new(0, isDirectHit and 12 or 5),
				NumberSequenceKeypoint.new(0.3, isDirectHit and 22 or 9),
				NumberSequenceKeypoint.new(1, 0),
			})
			fireball.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0),
				NumberSequenceKeypoint.new(0.5, 0.3),
				NumberSequenceKeypoint.new(1, 1),
			})
			fireball.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 220)),
				ColorSequenceKeypoint.new(0.2, Color3.fromRGB(255, 200, 50)),
				ColorSequenceKeypoint.new(0.6, Color3.fromRGB(255, 80, 10)),
				ColorSequenceKeypoint.new(1, Color3.fromRGB(60, 20, 5)),
			})
			fireball.LightEmission = 1
			fireball.Parent = explosion
			fireball:Emit(math.floor(100 * emitScale))

			-- Sparks/debris
			local sparks = Instance.new("ParticleEmitter")
			sparks.Rate = 0
			sparks.Lifetime = NumberRange.new(0.8, 2.5)
			sparks.Speed = NumberRange.new(40, 100)
			sparks.SpreadAngle = Vector2.new(180, 180)
			sparks.Size = NumberSequence.new({
				NumberSequenceKeypoint.new(0, isDirectHit and 2.5 or 1),
				NumberSequenceKeypoint.new(1, 0),
			})
			sparks.Color = ColorSequence.new(Color3.fromRGB(255, 220, 120), Color3.fromRGB(255, 80, 10))
			sparks.LightEmission = 1
			sparks.Parent = explosion
			sparks:Emit(math.floor(80 * emitScale))

			-- Massive smoke cloud
			local smokeCloud = Instance.new("ParticleEmitter")
			smokeCloud.Rate = 0
			smokeCloud.Lifetime = NumberRange.new(4, 8)
			smokeCloud.Speed = NumberRange.new(10, 30)
			smokeCloud.SpreadAngle = Vector2.new(180, 180)
			smokeCloud.Size = NumberSequence.new({
				NumberSequenceKeypoint.new(0, isDirectHit and 8 or 3),
				NumberSequenceKeypoint.new(0.4, isDirectHit and 25 or 10),
				NumberSequenceKeypoint.new(1, isDirectHit and 40 or 16),
			})
			smokeCloud.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.05),
				NumberSequenceKeypoint.new(0.2, 0.2),
				NumberSequenceKeypoint.new(1, 1),
			})
			smokeCloud.Color = ColorSequence.new(Color3.fromRGB(20, 20, 20), Color3.fromRGB(50, 50, 50))
			smokeCloud.Parent = explosion
			smokeCloud:Emit(math.floor(60 * emitScale))

			-- Screen shake
			local camera = Workspace.CurrentCamera
			if camera then
				task.spawn(function()
					local intensity = isDirectHit and 4 or 1.5
					local duration = isDirectHit and 1.0 or 0.4
					local elapsed2 = 0
					local shakeRng = Random.new()
					while elapsed2 < duration do
						local dt = task.wait()
						elapsed2 += dt
						local fade = 1 - (elapsed2 / duration)
						camera.CFrame *= CFrame.new(
							shakeRng:NextNumber(-intensity, intensity) * fade,
							shakeRng:NextNumber(-intensity, intensity) * fade,
							0
						)
					end
				end)
			end

			-- Fling barrels on small hit
			if outcome == "smallHit" then
				local boat = findActiveShipmentBoatByShipmentId(shipmentId)
				if boat then
					local candidates = {}
					for _, d in ipairs(boat:GetDescendants()) do
						if d:IsA("BasePart") or d:IsA("Model") then
							local n = d.Name:lower()
							if n:find("barrel") or n:find("cargo") then
								table.insert(candidates, d)
							end
						end
					end
					local rng = Random.new()
					for i = 1, math.min(10, #candidates) do
						local src = candidates[i]
						local fling = Instance.new("Part")
						fling.Name = "FlyingBarrel"
						fling.Size = Vector3.new(2, 3, 2)
						fling.Shape = Enum.PartType.Cylinder
						fling.Material = Enum.Material.Metal
						fling.Color = Color3.fromRGB(140, 100, 30)
						fling.Anchored = false
						fling.CanCollide = false
						local srcPos = if src:IsA("Model") then src:GetPivot().Position else src.Position
						fling.CFrame = CFrame.new(srcPos) * CFrame.Angles(rng:NextNumber(-1, 1), rng:NextNumber(-1, 1), rng:NextNumber(-1, 1))
						fling.Parent = Workspace
						local bv = Instance.new("BodyVelocity")
						bv.Velocity = Vector3.new(rng:NextNumber(-40, 40), rng:NextNumber(30, 60), rng:NextNumber(-40, 40))
						bv.MaxForce = Vector3.new(1e5, 1e5, 1e5)
						bv.P = 1000
						bv.Parent = fling
						Debris:AddItem(bv, 0.3)
						Debris:AddItem(fling, 6)
					end
				end
			end

			Debris:AddItem(explosion, 12)
		else
			-- Miss: big water splash
			local splash = Instance.new("Part")
			splash.Name = "MissileSplash"
			splash.Size = Vector3.new(1, 1, 1)
			splash.Position = targetPos
			splash.Anchored = true
			splash.CanCollide = false
			splash.Transparency = 1
			splash.Parent = Workspace

			local waterUp = Instance.new("ParticleEmitter")
			waterUp.Rate = 0
			waterUp.Lifetime = NumberRange.new(0.8, 2.0)
			waterUp.Speed = NumberRange.new(30, 60)
			waterUp.SpreadAngle = Vector2.new(40, 40)
			waterUp.Size = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 2),
				NumberSequenceKeypoint.new(0.4, 5),
				NumberSequenceKeypoint.new(1, 0),
			})
			waterUp.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.1),
				NumberSequenceKeypoint.new(1, 1),
			})
			waterUp.Color = ColorSequence.new(Color3.fromRGB(80, 160, 255), Color3.fromRGB(150, 210, 255))
			waterUp.Parent = splash
			waterUp:Emit(60)

			-- Small screen shake for nearby misses
			local camera = Workspace.CurrentCamera
			if camera then
				task.spawn(function()
					local shakeRng = Random.new()
					for _ = 1, 4 do
						local dt = task.wait()
						camera.CFrame *= CFrame.new(shakeRng:NextNumber(-0.5, 0.5), shakeRng:NextNumber(-0.5, 0.5), 0)
					end
				end)
			end

			Debris:AddItem(splash, 4)
		end

		-- Clean up missile model
		Debris:AddItem(missile, 2)
	end)
end

local function buildFallbackTornadoRig(parent: Instance): Model
	local rig = Instance.new("Model")
	rig.Name = "TornadoFallbackRig"
	rig.Parent = parent
	for i = 1, 8 do
		local p = Instance.new("Part")
		p.Name = "TornadoLayer"
		p.Shape = Enum.PartType.Cylinder
		local t = (i - 1) / 7
		local radius = 5 + t * 22
		local height = 5
		p.Size = Vector3.new(radius, height, radius)
		p.Material = Enum.Material.SmoothPlastic
		p.Color = Color3.fromRGB(130, 136, 146)
		p.Transparency = 0.45 + t * 0.25
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CFrame = CFrame.new(0, i * 4, 0) * CFrame.Angles(0, 0, math.rad(90))
		p.Parent = rig
	end
	return rig
end

local function attachEmitterFromTemplate(host: BasePart, template: Instance, fallbackBuilder: (BasePart, number?) -> (), fxScale: number)
	if template:IsA("ParticleEmitter") then
		local emitter = template:Clone()
		emitter.Parent = host
	elseif template:IsA("Attachment") then
		local att = template:Clone()
		att.Parent = host
	elseif template:IsA("BasePart") then
		local partClone = template:Clone()
		prepareKinematicFx(partClone)
		partClone.CFrame = host.CFrame
		partClone.Parent = host.Parent
	else
		fallbackBuilder(host, fxScale)
		return
	end
	ParticleFxScale.ApplyToDescendants(host, fxScale)
end

local function addFallbackTornadoDebris(host: BasePart, fxScale: number?)
	local scale = if fxScale then fxScale else 1
	local e = Instance.new("ParticleEmitter")
	e.Name = "TornadoDebrisFallback"
	e.Rate = math.floor(220 * scale)
	e.Lifetime = NumberRange.new(1.2, 2.1)
	e.Speed = NumberRange.new(40, 70)
	e.SpreadAngle = Vector2.new(360, 360)
	e.Acceleration = Vector3.new(0, 42, 0)
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.6),
		NumberSequenceKeypoint.new(1, 0.15),
	})
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.15),
		NumberSequenceKeypoint.new(1, 1),
	})
	e.Color = ColorSequence.new(Color3.fromRGB(120, 120, 120), Color3.fromRGB(80, 68, 52))
	e.Parent = host
end


function StraitWaypointWorldFx.OnStormPayload(data: { [string]: any })
	local shipmentId = if typeof(data.shipmentId) == "string" then data.shipmentId else ""
	local boat = if shipmentId ~= "" then findActiveShipmentBoatByShipmentId(shipmentId) else nil
	local hull = if boat then getBoatAttachmentPart(boat) else nil

	local center = vector3FromWorldPosition(data.worldPosition)
	if not center and hull then
		center = hull.Position
	end
	if not center then
		return
	end
	local centerPos = center

	local fxScale = particleFxScaleFromPayload(data)
	local sequenceSeconds = math.clamp(tonumber(data.sequenceSeconds) or 9.5, 1.5, 30)
	local barrelsLost = math.max(0, tonumber(data.barrelsLost) or 0)
	local didBarrelLoss = data.didBarrelLoss == true and barrelsLost > 0

	task.spawn(function()
		local rng = Random.new()
		local container = Instance.new("Model")
		container.Name = "StormEventFx"
		container.Parent = Workspace

		local cloudRig = cloneStormCloudTemplate()
		local canopyRadius = 80
		if cloudRig then
			prepareKinematicFx(cloudRig)
			cloudRig.Parent = container
			moveRootToWorldPosition(cloudRig, centerPos + Vector3.new(0, STORM_CLOUD_HEIGHT_OFFSET, 0))
			canopyRadius = math.max(70, getInstanceHorizontalRadius(cloudRig) * 0.9)
		else
			buildFallbackCloudLayer(container, centerPos)
			canopyRadius = 90
		end

		local rainDropsPart, _ = buildStormRainLayers(container, centerPos, canopyRadius, fxScale)
		local rainHost = rainDropsPart
		setParticleEmittersOnlyEnabled(container, true)
		playSoundTemplateOn(rainHost, "Storm", "RainLoopSfx", 0.95)

		-- Pre-collect barrel source instances (no position snapshot — positions are read live).
		local barrelSources: { Instance } = {}
		local barrelSideDir = Vector3.new(1, 0, 0)
		if didBarrelLoss and boat then
			local deckBarrels = collectDeckBarrelInstances(boat)
			local toWash = math.min(barrelsLost, #deckBarrels, 8)
			if toWash > 0 then
				local right = if hull
					then Vector3.new(hull.CFrame.RightVector.X, 0, hull.CFrame.RightVector.Z)
					else Vector3.new(1, 0, 0)
				if right.Magnitude < 0.01 then
					right = Vector3.new(1, 0, 0)
				else
					right = right.Unit
				end
				barrelSideDir = right * (if rng:NextNumber() < 0.5 then -1 else 1)
				for i = 1, toWash do
					table.insert(barrelSources, deckBarrels[i])
				end
			end
		end

		-- Barrel wash animation: reads the barrel's LIVE position when called,
		-- so the animation starts exactly where the barrel currently is on the deck.
		local function runBarrelWashVisual(source: Instance)
			local startPos = getInstanceWorldPosition(source)
			if not startPos then
				return
			end
			local visual: Instance
			if source:IsA("Model") or source:IsA("BasePart") then
				visual = source:Clone()
				prepareKinematicFx(visual)
				setInstanceWorldCFrame(visual, CFrame.new(startPos))
			else
				visual = createFallbackBarrelVisual(startPos)
			end
			visual.Parent = container
			local edgePos = startPos + barrelSideDir * rng:NextNumber(14, 22) + Vector3.new(rng:NextNumber(-4, 4), -1, rng:NextNumber(-4, 4))
			local splashPos = edgePos + barrelSideDir * rng:NextNumber(24, 44) + Vector3.new(rng:NextNumber(-8, 8), -7, rng:NextNumber(-8, 8))
			local slideDur = rng:NextNumber(0.35, 0.55)
			local t0 = os.clock()
			while visual.Parent and (os.clock() - t0) < slideDur do
				local a = math.clamp((os.clock() - t0) / slideDur, 0, 1)
				local eased = a * a * (3 - 2 * a)
				local p = startPos:Lerp(edgePos, eased) + Vector3.new(0, math.sin(eased * math.pi) * 3, 0)
				setInstanceWorldCFrame(visual, CFrame.new(p) * CFrame.Angles(a * 4, a * 7, a * 5))
				task.wait()
			end
			local fallDur = rng:NextNumber(0.45, 0.7)
			local t1 = os.clock()
			while visual.Parent and (os.clock() - t1) < fallDur do
				local a = math.clamp((os.clock() - t1) / fallDur, 0, 1)
				local eased = a * a * (3 - 2 * a)
				local p = edgePos:Lerp(splashPos, eased) + Vector3.new(0, math.sin((1 - eased) * math.pi) * 5, 0)
				setInstanceWorldCFrame(visual, CFrame.new(p) * CFrame.Angles(a * 12, a * 10, a * 9))
				task.wait()
			end
			if visual.Parent then
				visual:Destroy()
			end
		end

		-- Last 1–2 strikes aim at barrel positions (read live at fire time); rest are atmospheric.
		local strikeCount = math.clamp(math.floor(sequenceSeconds * 0.36), 3, 7)
		local barrelTargetCount = math.min(#barrelSources, math.min(2, strikeCount))
		local atmosphericCount = strikeCount - barrelTargetCount
		local strikeWindow = math.max(1, sequenceSeconds - 0.2)
		local timeBudget = strikeWindow
		for i = 1, strikeCount do
			local remaining = strikeCount - i + 1
			local maxSlice = math.max(0.35, timeBudget / remaining)
			local waitFor = rng:NextNumber(0.35, math.max(0.65, maxSlice))
			waitFor = math.min(waitFor, timeBudget)
			if waitFor > 0 then
				task.wait(waitFor)
			end
			timeBudget -= waitFor

			local strikeBase: Vector3
			local barrelIdx = i - atmosphericCount
			if barrelIdx >= 1 and barrelIdx <= #barrelSources then
				-- Read the live position right now — boat may have moved since event fired.
				local livePos = getInstanceWorldPosition(barrelSources[barrelIdx])
				if livePos then
					strikeBase = livePos
					local src = barrelSources[barrelIdx]
					task.delay(0.25, function()
						task.spawn(runBarrelWashVisual, src)
					end)
				else
					strikeBase = centerPos + Vector3.new(rng:NextNumber(-85, 85), 0, rng:NextNumber(-85, 85))
				end
			else
				strikeBase = centerPos + Vector3.new(rng:NextNumber(-85, 85), 0, rng:NextNumber(-85, 85))
			end

			local top = strikeBase + Vector3.new(0, rng:NextNumber(72, 98), 0)
			local bottom = strikeBase + Vector3.new(0, rng:NextNumber(4, 12), 0)
			createLightningStrikeVisual(container, top, bottom)
			playSoundTemplateOn(rainHost, "Storm", "LightningSfx", 1)

			local cam = Workspace.CurrentCamera
			local thunderDelay = rng:NextNumber(0.2, 1.0)
			if cam then
				local dist = (cam.CFrame.Position - strikeBase).Magnitude
				thunderDelay = math.clamp(dist / 360, 0.15, 1.6)
			end
			task.delay(thunderDelay, function()
				if container.Parent then
					playSoundTemplateOn(rainHost, "Storm", "ThunderSfx", 1)
				end
			end)
			shakeCameraIfNear(strikeBase, 260, 1.5, 0.18)
		end

		-- Barrels beyond the targeted count wash off after the loop with staggered timing.
		for i = barrelTargetCount + 1, #barrelSources do
			local src = barrelSources[i]
			local stagger = (i - barrelTargetCount - 1) * 0.08
			task.delay(stagger, function()
				task.spawn(runBarrelWashVisual, src)
			end)
		end

		task.delay(sequenceSeconds, function()
			if container.Parent then
				setParticleEmittersOnlyEnabled(container, false)
			end
		end)
		Debris:AddItem(container, sequenceSeconds + 3.5)
	end)
end

function StraitWaypointWorldFx.OnTornadoPayload(data: { [string]: any })
	local shipmentId = if typeof(data.shipmentId) == "string" then data.shipmentId else ""
	local center = vector3FromWorldPosition(data.worldPosition)
	local payloadPivot = vector3FromWorldPosition(data.shipPivotPosition)
	local payloadBounds = vector3FromWorldPosition(data.shipBoundsSize)
	if not center then
		center = payloadPivot
	end
	if not center then
		return
	end
	local centerPos = center
	local fallbackPivot = payloadPivot or centerPos
	local fallbackBounds = payloadBounds or Vector3.new(30, 18, 30)

	local fxScale = particleFxScaleFromPayload(data)
	local sequenceSeconds = math.clamp(tonumber(data.sequenceSeconds) or 11, 1.5, 35)
	local didBarrelLoss = data.didBarrelLoss == true and (tonumber(data.barrelsLost) or 0) > 0
	local barrelsLost = math.max(0, tonumber(data.barrelsLost) or 0)
	local maxVisualBarrels = math.max(0, math.floor(tonumber(data.maxVisualBarrels) or 8))

	task.spawn(function()
		local rng = Random.new()
		local boat = resolveShipmentBoatWithTimeout(shipmentId, 1.5)
		local hull = if boat then getBoatAttachmentPart(boat) else nil

		local container = Instance.new("Model")
		container.Name = "TornadoEventFx"
		container.Parent = Workspace

		local funnel = cloneRenderableEventRoot("Tornado", "FunnelRig")
		if not funnel then
			if RunService:IsStudio() then
				warn("[StraitWaypointWorldFx] Tornado.FunnelRig missing/unusable; using fallback funnel.")
			end
			funnel = buildFallbackTornadoRig(container)
		else
			prepareKinematicFx(funnel)
			funnel.Parent = container
		end

		local initialPivotPos, initialBounds, initialFrame = getTornadoBoatFrame(boat, fallbackPivot, fallbackBounds)
		local shipSpan = math.max(initialBounds.X, initialBounds.Z)
		local tornadoScale = math.clamp(shipSpan / 32, 1.3, 2.4)
		scaleTornadoRoot(funnel, tornadoScale)
		local funnelHalfHeight = getInstanceHalfHeight(funnel)
		local funnelBaseOffset = getInstanceBaseOffset(funnel)
		local funnelVisualLift = getTornadoVerticalMeshLift(funnel, funnelHalfHeight)
		local debrisYOffset = math.max(9, math.max(funnelHalfHeight, funnelBaseOffset) * 0.52)
		local waterClearance = math.max(0.15, math.min(1.2, funnelHalfHeight * 0.016))
		local deckClearance = math.max(0.4, math.min(2.0, funnelHalfHeight * 0.034))

		local debrisHost = Instance.new("Part")
		debrisHost.Name = "TornadoDebrisHost"
		debrisHost.Size = Vector3.new(1, 1, 1)
		debrisHost.Anchored = true
		debrisHost.CanCollide = false
		debrisHost.CanQuery = false
		debrisHost.CanTouch = false
		debrisHost.Transparency = 1
		debrisHost.Parent = container

		local debrisTemplate = cloneParticleEmitterTemplate("Tornado", "DebrisEmitter")
		if debrisTemplate then
			attachEmitterFromTemplate(debrisHost, debrisTemplate, addFallbackTornadoDebris, fxScale)
			debrisTemplate:Destroy()
		else
			addFallbackTornadoDebris(debrisHost, fxScale)
		end

		playSoundTemplateOn(debrisHost, "Tornado", "WindLoopSfx", 0.9)
		ParticleFxScale.ApplyToDescendants(container, fxScale)
		setAllParticleEmittersEnabled(container, true)

		local frameForDirection = if hull then hull.CFrame else (if initialFrame then initialFrame else CFrame.new(initialPivotPos))
		local forward = Vector3.new(frameForDirection.LookVector.X, 0, frameForDirection.LookVector.Z)
		if forward.Magnitude <= 0.01 then
			forward = Vector3.new(1, 0, 0)
		else
			forward = forward.Unit
		end
		if rng:NextNumber() < 0.5 then
			forward = Vector3.new(-1, 0, 0)
		end
		local cross = Vector3.new(-forward.Z, 0, forward.X)

		local laneRadius = math.max(28, shipSpan * 0.7)
		local attackStart = initialPivotPos + cross * laneRadius
		local attackEnd = initialPivotPos - cross * laneRadius
		if not didBarrelLoss then
			local missSign = if rng:NextNumber() < 0.5 then -1 else 1
			local missOffset = cross * rng:NextNumber(26, 52) * missSign
			attackStart += missOffset
			attackEnd += missOffset
		end
		local entryStart = attackStart + cross * rng:NextNumber(68, 102) - forward * rng:NextNumber(24, 48)
		local exitPos = attackEnd - cross * rng:NextNumber(76, 118) + forward * rng:NextNumber(24, 52)

		local motionSeconds = math.max(2.4, sequenceSeconds)
		local entryFrac = 0.2
		local attackFrac = 0.6
		local attackEndFrac = entryFrac + attackFrac
		local motionStart = os.clock()
		local chaosTriggered = false
		while container.Parent and (os.clock() - motionStart) < motionSeconds do
			local alpha = math.clamp((os.clock() - motionStart) / motionSeconds, 0, 1)

			local basePathPos = attackStart
			if alpha < entryFrac then
				local phaseAlpha = math.clamp(alpha / math.max(entryFrac, 0.001), 0, 1)
				local eased = phaseAlpha * phaseAlpha * (3 - 2 * phaseAlpha)
				basePathPos = entryStart:Lerp(attackStart, eased)
			elseif alpha < attackEndFrac then
				local phaseAlpha = math.clamp((alpha - entryFrac) / math.max(attackFrac, 0.001), 0, 1)
				local eased = phaseAlpha * phaseAlpha * (3 - 2 * phaseAlpha)
				basePathPos = attackStart:Lerp(attackEnd, eased)
			else
				local exitFrac = math.max(1 - attackEndFrac, 0.001)
				local phaseAlpha = math.clamp((alpha - attackEndFrac) / exitFrac, 0, 1)
				local eased = phaseAlpha * phaseAlpha * (3 - 2 * phaseAlpha)
				basePathPos = attackEnd:Lerp(exitPos, eased)
			end

			local livePivotPos, liveBounds, liveFrame = getTornadoBoatFrame(boat, fallbackPivot, fallbackBounds)
			local shipDelta = livePivotPos - initialPivotPos

			local pathPos = basePathPos + shipDelta
			local lateralWobble = math.sin(alpha * math.pi * 5.8) * math.max(1.5, math.max(liveBounds.X, liveBounds.Z) * 0.03)
			pathPos += forward * lateralWobble

			local waterY = estimateTornadoWaterY(livePivotPos, liveBounds, centerPos.Y)
			local rayTopY = livePivotPos.Y + math.max(liveBounds.Y, 24) + 80
			local maxBoatSurfaceY = livePivotPos.Y + math.max(4, math.min(liveBounds.Y * 0.35, 10))

			local sampledSurfaceY: number? = nil
			local hitBoat = false
			if boat then
				local sampleY, didHit = sampleBoatSurfaceY(
					boat,
					livePivotPos,
					pathPos,
					math.max(10, math.max(liveBounds.X, liveBounds.Z) * 0.24),
					rayTopY,
					maxBoatSurfaceY
				)
				sampledSurfaceY = sampleY
				hitBoat = didHit
			end

			local insideFootprint = isPointInsideBoatFootprint(pathPos, livePivotPos, liveBounds, if hull then hull.CFrame else liveFrame)
			local onDeck = hitBoat and sampledSurfaceY ~= nil
			local contactY = waterY
			if onDeck and sampledSurfaceY then
				contactY = math.min(maxBoatSurfaceY, sampledSurfaceY)
			elseif insideFootprint then
				contactY = waterY
			end

			local baseY = contactY + (if onDeck then deckClearance else waterClearance)
			baseY = math.max(waterY + waterClearance, baseY)

			local funnelCenterY = baseY + funnelBaseOffset + funnelVisualLift
			local yaw = os.clock() * 8.4
			setInstanceWorldCFrame(funnel, CFrame.new(pathPos.X, funnelCenterY, pathPos.Z) * CFrame.Angles(0, yaw, 0))
			debrisHost.CFrame = CFrame.new(pathPos.X, baseY + debrisYOffset, pathPos.Z)

			if math.floor(alpha * 18) % 4 == 0 then
				shakeCameraIfNear(pathPos, 220, 0.85, 0.08)
			end

			local inAttackPhase = alpha >= entryFrac and alpha <= attackEndFrac
			local touchingDeck = inAttackPhase and onDeck and sampledSurfaceY ~= nil and sampledSurfaceY >= (waterY + 0.9)
			if didBarrelLoss and not chaosTriggered and touchingDeck and boat then
				chaosTriggered = true
				local chaosCenter = Vector3.new(pathPos.X, baseY + 1.8, pathPos.Z)
				spawnTornadoBarrelChaos(container, boat, chaosCenter, barrelsLost, maxVisualBarrels)
				shakeCameraIfNear(pathPos, 260, 1.3, 0.22)
			end
			task.wait()
		end

		if container.Parent then
			setAllParticleEmittersEnabled(container, false)
		end
		Debris:AddItem(container, 1.2)
	end)
end

function StraitWaypointWorldFx.OnMineStrikePayload(data: { [string]: any })
	local shipPos = vector3FromWorldPosition(data.worldPosition)
	if not shipPos then return end

	local didHit = data.didHit == true
	local riseSeconds = tonumber(data.riseSeconds) or 2.0
	local minePositions = data.minePositions
	local shipmentId = if typeof(data.shipmentId) == "string" then data.shipmentId else ""

	if typeof(minePositions) ~= "table" or #minePositions == 0 then return end

	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local mineTemplate = assets and assets:FindFirstChild("Mine")
	local spawnDepth = 40
	local MINE_SCALE = 0.4 -- 40% size

	-- Calculate scaled mine height
	local mineHalfHeight = 3
	if mineTemplate then
		if mineTemplate:IsA("Model") then
			local mp = mineTemplate:FindFirstChildWhichIsA("MeshPart") or mineTemplate:FindFirstChildWhichIsA("BasePart")
			if mp then mineHalfHeight = (mp.Size.Y * MINE_SCALE) / 2 end
		elseif mineTemplate:IsA("BasePart") then
			mineHalfHeight = (mineTemplate.Size.Y * MINE_SCALE) / 2
		end
	end
	-- Ocean surface ~Y=3. Top third pokes out.
	local OCEAN_SURFACE_Y = 3
	local POKE_OUT = mineHalfHeight * 0.6
	local surfaceY = OCEAN_SURFACE_Y - mineHalfHeight + POKE_OUT

	-- Spawn all mines deep underwater
	local mineObjects = {}
	local rng = Random.new()
	for i, pos in ipairs(minePositions) do
		if typeof(pos) ~= "table" then continue end
		local surfacePos = Vector3.new(pos.x or 0, surfaceY, pos.z or 0)
		local underwaterPos = surfacePos - Vector3.new(0, spawnDepth, 0)

		local mine
		if mineTemplate then
			mine = mineTemplate:Clone()
		else
			mine = Instance.new("Part")
			mine.Name = "Mine"
			mine.Shape = Enum.PartType.Ball
			mine.Size = Vector3.new(6, 6, 6)
			mine.Material = Enum.Material.Metal
			mine.Color = Color3.fromRGB(40, 45, 40)
		end

		-- Scale down + setup
		if mine:IsA("Model") then
			for _, d in ipairs(mine:GetDescendants()) do
				if d:IsA("BasePart") then
					d.Anchored = true
					d.CanCollide = false
					d.CanQuery = false
					d.CanTouch = false
					d.Size = d.Size * MINE_SCALE
				end
			end
			mine:PivotTo(CFrame.new(underwaterPos))
		elseif mine:IsA("BasePart") then
			mine.Anchored = true
			mine.CanCollide = false
			mine.CanQuery = false
			mine.CanTouch = false
			mine.Size = mine.Size * MINE_SCALE
			mine.CFrame = CFrame.new(underwaterPos)
		end

		mine.Parent = Workspace

		-- Each mine gets a random delay before it starts rising (stagger)
		local riseDelay = rng:NextNumber(0, riseSeconds * 0.4)
		table.insert(mineObjects, {
			mine = mine,
			underwaterPos = underwaterPos,
			surfacePos = surfacePos,
			index = i,
			riseDelay = riseDelay,
		})
	end

	-- Rise mines slowly with staggered start times
	task.spawn(function()
		local startTime = os.clock()
		local allDone = false
		while not allDone do
			allDone = true
			local now = os.clock()

			for _, entry in ipairs(mineObjects) do
				local elapsed = now - startTime - entry.riseDelay
				if elapsed < 0 then
					-- Not started yet
					allDone = false
					continue
				end

				local alpha = math.min(elapsed / riseSeconds, 1)
				if alpha < 1 then allDone = false end

				-- Very slow ease — starts slow, speeds up slightly, slows at end (like buoyancy)
				local eased = alpha * alpha * (3 - 2 * alpha) -- smoothstep

				local pos = entry.underwaterPos:Lerp(entry.surfacePos, eased)
				-- Gentle bobbing wobble
				local wobble = math.sin(now * 2 + entry.index * 1.7) * 0.4
				pos = pos + Vector3.new(0, wobble, 0)

				if entry.mine:IsA("Model") then
					entry.mine:PivotTo(CFrame.new(pos))
				else
					entry.mine.CFrame = CFrame.new(pos)
				end
			end

			task.wait()
		end

		-- Mines are now on the surface — check for hit
		if didHit then
			-- Find the mine closest to ship (the "collision" mine)
			local hitMine = mineObjects[1]
			local closestDist = math.huge
			for _, entry in ipairs(mineObjects) do
				local dist = (entry.surfacePos - shipPos).Magnitude
				if dist < closestDist then
					closestDist = dist
					hitMine = entry
				end
			end

			-- Small delay — ship "hits" the mine
			task.wait(0.8)

			-- MASSIVE explosion at the hit mine
			local hitPos = hitMine.surfacePos

			-- Destroy the hit mine
			if hitMine.mine.Parent then hitMine.mine:Destroy() end

			local explosion = Instance.new("Part")
			explosion.Name = "MineExplosion"
			explosion.Size = Vector3.new(1, 1, 1)
			explosion.Position = hitPos
			explosion.Anchored = true
			explosion.CanCollide = false
			explosion.Transparency = 1
			explosion.Parent = Workspace

			-- Roblox shockwave
			local rx = Instance.new("Explosion")
			rx.BlastRadius = 0
			rx.BlastPressure = 0
			rx.DestroyJointRadiusPercent = 0
			rx.Position = hitPos
			rx.Parent = Workspace

			-- Blinding flash
			local flash = Instance.new("PointLight")
			flash.Brightness = 15
			flash.Range = 180
			flash.Color = Color3.fromRGB(255, 220, 100)
			flash.Parent = explosion
			task.delay(0.15, function() if flash.Parent then flash.Brightness = 6 end end)
			task.delay(0.5, function() if flash.Parent then flash:Destroy() end end)

			-- Water column (mines are in water — huge water spray upward)
			local waterColumn = Instance.new("ParticleEmitter")
			waterColumn.Rate = 0
			waterColumn.Lifetime = NumberRange.new(1.0, 3.0)
			waterColumn.Speed = NumberRange.new(50, 100)
			waterColumn.SpreadAngle = Vector2.new(30, 30)
			waterColumn.Size = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 4),
				NumberSequenceKeypoint.new(0.3, 10),
				NumberSequenceKeypoint.new(1, 0),
			})
			waterColumn.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.1),
				NumberSequenceKeypoint.new(1, 1),
			})
			waterColumn.Color = ColorSequence.new(Color3.fromRGB(120, 190, 255), Color3.fromRGB(200, 230, 255))
			waterColumn.Parent = explosion
			waterColumn:Emit(80)

			-- Fireball
			local fireball = Instance.new("ParticleEmitter")
			fireball.Rate = 0
			fireball.Lifetime = NumberRange.new(0.4, 1.2)
			fireball.Speed = NumberRange.new(30, 70)
			fireball.SpreadAngle = Vector2.new(180, 180)
			fireball.Size = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 10),
				NumberSequenceKeypoint.new(0.3, 20),
				NumberSequenceKeypoint.new(1, 0),
			})
			fireball.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0),
				NumberSequenceKeypoint.new(0.5, 0.3),
				NumberSequenceKeypoint.new(1, 1),
			})
			fireball.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 220)),
				ColorSequenceKeypoint.new(0.3, Color3.fromRGB(255, 180, 50)),
				ColorSequenceKeypoint.new(0.7, Color3.fromRGB(255, 60, 10)),
				ColorSequenceKeypoint.new(1, Color3.fromRGB(40, 15, 5)),
			})
			fireball.LightEmission = 1
			fireball.Parent = explosion
			fireball:Emit(100)

			-- Thick black smoke
			local smoke = Instance.new("ParticleEmitter")
			smoke.Rate = 0
			smoke.Lifetime = NumberRange.new(4, 8)
			smoke.Speed = NumberRange.new(10, 25)
			smoke.SpreadAngle = Vector2.new(180, 180)
			smoke.Size = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 6),
				NumberSequenceKeypoint.new(0.4, 25),
				NumberSequenceKeypoint.new(1, 40),
			})
			smoke.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.05),
				NumberSequenceKeypoint.new(0.2, 0.2),
				NumberSequenceKeypoint.new(1, 1),
			})
			smoke.Color = ColorSequence.new(Color3.fromRGB(15, 15, 15), Color3.fromRGB(40, 40, 40))
			smoke.Parent = explosion
			smoke:Emit(60)

			-- BIG screen shake
			local camera = Workspace.CurrentCamera
			if camera then
				task.spawn(function()
					local intensity = 5
					local duration = 1.2
					local elapsed2 = 0
					local shakeRng = Random.new()
					while elapsed2 < duration do
						local dt = task.wait()
						elapsed2 += dt
						local fade = 1 - (elapsed2 / duration)
						camera.CFrame *= CFrame.new(
							shakeRng:NextNumber(-intensity, intensity) * fade,
							shakeRng:NextNumber(-intensity, intensity) * fade,
							0
						)
					end
				end)
			end

			-- Debris flying everywhere — ship parts, barrels, wood
			local boat = findActiveShipmentBoatByShipmentId(shipmentId)
			if boat then
				local rng = Random.new()
				local debrisCount = 0
				for _, d in ipairs(boat:GetDescendants()) do
					if debrisCount >= 12 then break end
					if d:IsA("BasePart") then
						local fling = Instance.new("Part")
						fling.Name = "MineDebris"
						fling.Size = Vector3.new(rng:NextNumber(1, 4), rng:NextNumber(1, 3), rng:NextNumber(1, 4))
						fling.Material = Enum.Material.Metal
						fling.Color = d.Color
						fling.Anchored = false
						fling.CanCollide = false
						fling.CFrame = CFrame.new(d.Position) * CFrame.Angles(rng:NextNumber(-2, 2), rng:NextNumber(-2, 2), rng:NextNumber(-2, 2))
						fling.Parent = Workspace
						local bv = Instance.new("BodyVelocity")
						bv.Velocity = Vector3.new(rng:NextNumber(-50, 50), rng:NextNumber(40, 80), rng:NextNumber(-50, 50))
						bv.MaxForce = Vector3.new(1e5, 1e5, 1e5)
						bv.P = 1000
						bv.Parent = fling
						Debris:AddItem(bv, 0.3)
						Debris:AddItem(fling, 6)
						debrisCount += 1
					end
				end
			end

			Debris:AddItem(explosion, 12)
		end

		-- Clean up remaining mines after a while (fade out)
		task.delay(didHit and 3 or 8, function()
			for _, entry in ipairs(mineObjects) do
				if entry.mine and entry.mine.Parent then
					entry.mine:Destroy()
				end
			end
		end)
	end)
end

-- Helper: smoothly move a Model/Part from A to B over duration, with optional Y arc
local function animateMove(obj, fromCF: CFrame, toCF: CFrame, duration: number, arcHeight: number?)
	local arc = arcHeight or 0
	local startTime = os.clock()
	while true do
		local alpha = math.min((os.clock() - startTime) / duration, 1)
		local eased = alpha * alpha * (3 - 2 * alpha) -- smoothstep
		local pos = fromCF.Position:Lerp(toCF.Position, eased)
		if arc > 0 then
			pos = pos + Vector3.new(0, arc * math.sin(eased * math.pi), 0)
		end
		local cf = CFrame.new(pos) * (fromCF - fromCF.Position):Lerp(toCF - toCF.Position, eased)
		if obj:IsA("Model") then
			obj:PivotTo(cf)
		else
			obj.CFrame = cf
		end
		if alpha >= 1 then break end
		task.wait()
	end
end

function StraitWaypointWorldFx.OnPirateRaidPayload(data: { [string]: any })
	local shipmentId = if typeof(data.shipmentId) == "string" then data.shipmentId else ""
	local barrelsStolen = math.max(0, tonumber(data.barrelsStolen) or 0)
	local approachSide = tonumber(data.approachSide) or 1

	local assets = ReplicatedStorage:FindFirstChild("Assets")
	if not assets then
		return
	end
	local pirateShipTemplate = assets:FindFirstChild("PirateShip")
	local pirateNpcTemplate = assets:FindFirstChild("Pirate")
	if not pirateShipTemplate or not pirateNpcTemplate then
		return
	end

	task.spawn(function()
		local playerBoat = findActiveShipmentBoatByShipmentId(shipmentId)
		if not playerBoat then
			return
		end
		local boatRoot = getBoatAttachmentPart(playerBoat)
		if not boatRoot then
			return
		end

		local aheadPositions = data.aheadPositions
		local aheadRaw = if typeof(aheadPositions) == "table" then aheadPositions[1] else nil
		local ahead1 = vector3FromWorldPosition(aheadRaw)
		if not ahead1 then
			return
		end

		local rootPos = boatRoot.Position
		local dir = Vector3.new(ahead1.X - rootPos.X, 0, ahead1.Z - rootPos.Z)
		if dir.Magnitude < 0.001 then
			return
		end
		local fwd = dir.Unit
		local sideSign = if approachSide >= 0 then 1 else -1
		local perp = Vector3.new(-fwd.Z, 0, fwd.X) * sideSign

		local function uprightLookAt(pos: Vector3, toward: Vector3): CFrame
			local flatToward = Vector3.new(toward.X, pos.Y, toward.Z)
			local flatDelta = Vector3.new(flatToward.X - pos.X, 0, flatToward.Z - pos.Z)
			if flatDelta.Magnitude < 0.001 then
				flatToward = pos + fwd
			end
			return CFrame.lookAt(pos, flatToward)
		end

		local function getObjectCF(obj: any): CFrame
			if obj:IsA("Model") then
				return obj:GetPivot()
			end
			return obj.CFrame
		end

		local function setObjectCF(obj: any, cf: CFrame)
			if obj:IsA("Model") then
				obj:PivotTo(cf)
			else
				obj.CFrame = cf
			end
		end

		local function prepStatic(instance: Instance)
			for _, d in ipairs(instance:GetDescendants()) do
				if d:IsA("BasePart") then
					d.Anchored = true
					d.CanCollide = false
					d.CanQuery = false
					d.CanTouch = false
				end
			end
		end

		local function movePirate(pirate, targetCF: CFrame, duration: number, arcHeight: number?)
			animateMove(pirate.npc, pirate.cf, targetCF, duration, arcHeight)
			pirate.cf = targetCF
		end

		local function runTimedParallel(tasks, minDuration: number)
			local startTime = os.clock()
			local remaining = #tasks
			if remaining == 0 then
				task.wait(minDuration)
				return
			end
			for _, fn in ipairs(tasks) do
				task.spawn(function()
					fn()
					remaining -= 1
				end)
			end
			while remaining > 0 do
				task.wait()
			end
			local elapsed = os.clock() - startTime
			if elapsed < minDuration then
				task.wait(minDuration - elapsed)
			end
		end

		local PHASE_APPROACH = 4.0
		local PHASE_BOARD = 3.0
		local PHASE_STEAL = 7.0
		local PHASE_ESCAPE = 4.0
		local PIRATE_COUNT = 5
		local PIRATE_SPACING = 1.5
		local TANKER_DECK_Y = 15
		local PIRATE_BOAT_DECK_Y = 4
		local GAP = 20
		local PIRATE_HALF_LEN = 9
		local SPAWN_AHEAD_DIST = 260
		local ZIP_SIDE_OFFSET = 5
		local ZIP_ATTACH_UP = 1.5
		local LANDING_BACK_OFFSET = 5
		local BARREL_SIDE_OFFSET = 4.5
		local BARREL_CARRY_UP = 3
		local TOSS_ARC_HEIGHT = 22
		local ESCAPE_DIST = 220

		local _, liveBoatSize = playerBoat:GetBoundingBox()
		local playerHalf = math.max(liveBoatSize.X, liveBoatSize.Y, liveBoatSize.Z) / 2
		local parkDist = playerHalf + PIRATE_HALF_LEN + GAP
		local parkPos = Vector3.new(rootPos.X, rootPos.Y, rootPos.Z) + fwd * parkDist
		local spawnPos = parkPos + fwd * SPAWN_AHEAD_DIST

		local pirateBoat = pirateShipTemplate:Clone()
		prepStatic(pirateBoat)
		pirateBoat.Parent = Workspace
		pirateBoat:PivotTo(uprightLookAt(spawnPos, rootPos))
		Debris:AddItem(pirateBoat, 30)

		local pirates = {}
		local pirateMid = (PIRATE_COUNT + 1) / 2
		for i = 1, PIRATE_COUNT do
			local npc = pirateNpcTemplate:Clone()
			prepStatic(npc)
			npc.Parent = pirateBoat
			local along = fwd * ((i - pirateMid) * PIRATE_SPACING)
			local spawnNpcPos = spawnPos + Vector3.new(0, PIRATE_BOAT_DECK_Y, 0) + along
			local spawnNpcCF = uprightLookAt(spawnNpcPos, rootPos)
			setObjectCF(npc, spawnNpcCF)
			table.insert(pirates, {
				npc = npc,
				cf = spawnNpcCF,
			})
			Debris:AddItem(npc, 30)
		end

		animateMove(pirateBoat, pirateBoat:GetPivot(), uprightLookAt(parkPos, rootPos), PHASE_APPROACH, 0)

		rootPos = boatRoot.Position
		parkPos = Vector3.new(rootPos.X, rootPos.Y, rootPos.Z) + fwd * parkDist
		pirateBoat:PivotTo(uprightLookAt(parkPos, rootPos))

		local pirateBoatPos = pirateBoat:GetPivot().Position
		local zipFromBase = Vector3.new(pirateBoatPos.X, pirateBoatPos.Y + PIRATE_BOAT_DECK_Y, pirateBoatPos.Z) + perp * ZIP_SIDE_OFFSET
		local zipToBase = Vector3.new(rootPos.X, rootPos.Y + TANKER_DECK_Y, rootPos.Z) + perp * ZIP_SIDE_OFFSET
		local ropeStart = zipFromBase + Vector3.new(0, ZIP_ATTACH_UP, 0)
		local ropeEnd = zipToBase + Vector3.new(0, ZIP_ATTACH_UP, 0)

		local zipA = Instance.new("Part")
		zipA.Name = "PirateZipAnchorA"
		zipA.Size = Vector3.new(0.4, 2, 0.4)
		zipA.Anchored = true
		zipA.CanCollide = false
		zipA.CanQuery = false
		zipA.CanTouch = false
		zipA.Material = Enum.Material.Metal
		zipA.Color = Color3.fromRGB(70, 60, 50)
		zipA.CFrame = CFrame.new(zipFromBase)
		zipA.Parent = Workspace
		Debris:AddItem(zipA, 25)

		local zipB = Instance.new("Part")
		zipB.Name = "PirateZipAnchorB"
		zipB.Size = Vector3.new(0.4, 2, 0.4)
		zipB.Anchored = true
		zipB.CanCollide = false
		zipB.CanQuery = false
		zipB.CanTouch = false
		zipB.Material = Enum.Material.Metal
		zipB.Color = Color3.fromRGB(70, 60, 50)
		zipB.CFrame = CFrame.new(zipToBase)
		zipB.Parent = Workspace
		Debris:AddItem(zipB, 25)

		local attA = Instance.new("Attachment")
		attA.Position = Vector3.new(0, ZIP_ATTACH_UP, 0)
		attA.Parent = zipA
		local attB = Instance.new("Attachment")
		attB.Position = Vector3.new(0, ZIP_ATTACH_UP, 0)
		attB.Parent = zipB

		local rope = Instance.new("Beam")
		rope.Name = "PirateZipline"
		rope.Attachment0 = attA
		rope.Attachment1 = attB
		rope.Width0 = 0.35
		rope.Width1 = 0.35
		rope.FaceCamera = true
		rope.Color = ColorSequence.new(Color3.fromRGB(90, 70, 45))
		rope.Parent = zipA

		local landingBase = Vector3.new(zipToBase.X, rootPos.Y + TANKER_DECK_Y, zipToBase.Z) - fwd * LANDING_BACK_OFFSET
		local landingPositions = {}
		for i = 1, PIRATE_COUNT do
			landingPositions[i] = landingBase + perp * ((i - pirateMid) * 1.6)
		end

		for _, pirate in ipairs(pirates) do
			local worldCF = getObjectCF(pirate.npc)
			pirate.npc.Parent = Workspace
			setObjectCF(pirate.npc, worldCF)
			pirate.cf = worldCF
		end

		local boardTasks = {}
		local BOARD_STAGGER = 0.25
		local BOARD_TO_ROPE_DUR = 0.2
		local BOARD_SLIDE_DUR = 0.6
		local BOARD_DROP_DUR = 0.2
		for i, pirate in ipairs(pirates) do
			local idx = i
			local pirateData = pirate
			table.insert(boardTasks, function()
				task.wait((idx - 1) * BOARD_STAGGER)
				movePirate(pirateData, uprightLookAt(ropeStart, ropeEnd), BOARD_TO_ROPE_DUR, 0)

				local slideStart = os.clock()
				while true do
					local alpha = math.min((os.clock() - slideStart) / BOARD_SLIDE_DUR, 1)
					local eased = alpha * alpha * (3 - 2 * alpha)
					local slidePos = ropeStart:Lerp(ropeEnd, eased)
					slidePos += Vector3.new(0, -2.5 * math.sin(eased * math.pi), 0)
					setObjectCF(pirateData.npc, uprightLookAt(slidePos, ropeEnd))
					if alpha >= 1 then
						break
					end
					task.wait()
				end

				local landPos = landingPositions[idx]
				local landCF = uprightLookAt(landPos, ropeEnd)
				animateMove(pirateData.npc, uprightLookAt(ropeEnd, landPos), landCF, BOARD_DROP_DUR, 0)
				pirateData.cf = landCF
			end)
		end
		runTimedParallel(boardTasks, PHASE_BOARD)

		local deckBarrels = {}
		for _, d in ipairs(playerBoat:GetDescendants()) do
			if d.Name == "DeckBarrel" and d.Parent then
				table.insert(deckBarrels, d)
			end
		end
		table.sort(deckBarrels, function(a, b)
			local ay = if a:IsA("Model") then a:GetPivot().Position.Y else a.Position.Y
			local by = if b:IsA("Model") then b:GetPivot().Position.Y else b.Position.Y
			return ay > by
		end)

		local toSteal = math.min(barrelsStolen, #deckBarrels)
		if toSteal <= 0 then
			task.wait(PHASE_STEAL)
		else
			local cycles = math.max(1, math.ceil(toSteal / PIRATE_COUNT))
			local cycleDur = PHASE_STEAL / cycles
			local barrelIndex = 0

			for _ = 1, cycles do
				local cycleTasks = {}
				for i, pirate in ipairs(pirates) do
					local idx = i
					local pirateData = pirate
					barrelIndex += 1
					local barrel = if barrelIndex <= toSteal then deckBarrels[barrelIndex] else nil

					table.insert(cycleTasks, function()
						if not barrel or not barrel.Parent then
							local holdPos = landingPositions[idx]
							movePirate(pirateData, uprightLookAt(holdPos, ropeEnd), cycleDur * 0.2, 0)
							return
						end

						local barrelPos = if barrel:IsA("Model") then barrel:GetPivot().Position else barrel.Position
						local standPos = Vector3.new(barrelPos.X, rootPos.Y + TANKER_DECK_Y, barrelPos.Z) + perp * BARREL_SIDE_OFFSET
						movePirate(pirateData, uprightLookAt(standPos, barrelPos), cycleDur * 0.22, 0)

						if not barrel.Parent then
							movePirate(pirateData, uprightLookAt(landingPositions[idx], ropeEnd), cycleDur * 0.15, 0)
							return
						end
						barrel:Destroy()

						local carry = Instance.new("Part")
						carry.Name = "CarriedBarrel"
						carry.Size = Vector3.new(2, 3, 2)
						carry.Shape = Enum.PartType.Cylinder
						carry.Material = Enum.Material.Metal
						carry.Color = Color3.fromRGB(140, 100, 30)
						carry.Anchored = true
						carry.CanCollide = false
						carry.CanQuery = false
						carry.CanTouch = false
						carry.CFrame = CFrame.new(standPos + Vector3.new(0, BARREL_CARRY_UP, 0))
						carry.Parent = Workspace
						Debris:AddItem(carry, 20)

						local edgeDir = Vector3.new(zipFromBase.X - standPos.X, 0, zipFromBase.Z - standPos.Z)
						if edgeDir.Magnitude < 0.001 then
							edgeDir = -fwd
						else
							edgeDir = edgeDir.Unit
						end
						local edgePos = standPos + edgeDir * 6
						edgePos = Vector3.new(edgePos.X, rootPos.Y + TANKER_DECK_Y, edgePos.Z)
						local edgeCF = uprightLookAt(edgePos, zipFromBase)

						local walkStart = os.clock()
						local walkDur = cycleDur * 0.25
						local fromCF = pirateData.cf
						while true do
							local alpha = math.min((os.clock() - walkStart) / walkDur, 1)
							local eased = alpha * alpha * (3 - 2 * alpha)
							local npcPos = fromCF.Position:Lerp(edgeCF.Position, eased)
							setObjectCF(pirateData.npc, uprightLookAt(npcPos, zipFromBase))
							carry.CFrame = CFrame.new(npcPos + Vector3.new(0, BARREL_CARRY_UP, 0))
							if alpha >= 1 then
								break
							end
							task.wait()
						end
						pirateData.cf = edgeCF

						local tossTarget = pirateBoat:GetPivot().Position
							+ Vector3.new(0, PIRATE_BOAT_DECK_Y + 1, 0)
							+ fwd * ((idx - pirateMid) * PIRATE_SPACING)
						animateMove(carry, carry.CFrame, CFrame.new(tossTarget), cycleDur * 0.28, TOSS_ARC_HEIGHT)

						local backPos = landingPositions[idx]
						movePirate(pirateData, uprightLookAt(backPos, ropeEnd), cycleDur * 0.2, 0)
					end)
				end
				runTimedParallel(cycleTasks, cycleDur)
			end
		end

		local returnTasks = {}
		local RETURN_WINDOW = 1.8
		local RETURN_STAGGER = 0.2
		local RETURN_TO_ROPE_DUR = 0.2
		local RETURN_SLIDE_DUR = 0.55
		local RETURN_DROP_DUR = 0.2
		for i, pirate in ipairs(pirates) do
			local idx = i
			local pirateData = pirate
			table.insert(returnTasks, function()
				task.wait((idx - 1) * RETURN_STAGGER)
				movePirate(pirateData, uprightLookAt(ropeEnd, ropeStart), RETURN_TO_ROPE_DUR, 0)

				local slideStart = os.clock()
				while true do
					local alpha = math.min((os.clock() - slideStart) / RETURN_SLIDE_DUR, 1)
					local eased = alpha * alpha * (3 - 2 * alpha)
					local slidePos = ropeEnd:Lerp(ropeStart, eased)
					slidePos += Vector3.new(0, -2.5 * math.sin(eased * math.pi), 0)
					setObjectCF(pirateData.npc, uprightLookAt(slidePos, ropeStart))
					if alpha >= 1 then
						break
					end
					task.wait()
				end

				local pbPos = pirateBoat:GetPivot().Position
				local returnPos = pbPos + Vector3.new(0, PIRATE_BOAT_DECK_Y, 0) + fwd * ((idx - pirateMid) * PIRATE_SPACING)
				local returnCF = uprightLookAt(returnPos, returnPos + fwd)
				animateMove(pirateData.npc, uprightLookAt(ropeStart, returnPos), returnCF, RETURN_DROP_DUR, 0)
				pirateData.cf = returnCF
			end)
		end
		runTimedParallel(returnTasks, RETURN_WINDOW)

		Debris:AddItem(zipA, 0.1)
		Debris:AddItem(zipB, 0.1)

		for _, pirate in ipairs(pirates) do
			if pirate.npc.Parent then
				local worldCF = getObjectCF(pirate.npc)
				pirate.npc.Parent = pirateBoat
				setObjectCF(pirate.npc, worldCF)
				pirate.cf = worldCF
			end
		end

		local driveAwayDur = math.max(0.2, PHASE_ESCAPE - RETURN_WINDOW)
		local escapePos = pirateBoat:GetPivot().Position + fwd * ESCAPE_DIST
		escapePos = Vector3.new(escapePos.X, rootPos.Y, escapePos.Z)
		animateMove(pirateBoat, pirateBoat:GetPivot(), uprightLookAt(escapePos, escapePos + fwd), driveAwayDur, 0)

		Debris:AddItem(pirateBoat, 2)
	end)
end

function StraitWaypointWorldFx.OnCoastGuardInspectionPayload(data: { [string]: any })
	local shipmentId   = if typeof(data.shipmentId) == "string" then data.shipmentId else ""
	local approachSide = tonumber(data.approachSide) or 1

	local assets = ReplicatedStorage:FindFirstChild("Assets")
	if not assets then return end
	local cgShipTemplate = assets:FindFirstChild("CoastGuardShip")
	local cgNpcTemplate  = assets:FindFirstChild("CoastGuard")
	if not cgShipTemplate or not cgNpcTemplate then
		warn("[StraitWaypointWorldFx] Missing CoastGuardShip or CoastGuard in ReplicatedStorage.Assets")
		return
	end

	task.spawn(function()
		local playerBoat = findActiveShipmentBoatByShipmentId(shipmentId)
		if not playerBoat then return end
		local boatRoot = getBoatAttachmentPart(playerBoat)
		if not boatRoot then return end

		-- Use bounding box center for XZ position (individual parts can be way off)
		local bbCF0, _ = playerBoat:GetBoundingBox()
		local rootPos   = bbCF0.Position

		-- Travel direction from FRONT_MARKER if present, else velocity sample
		local frontMarker = playerBoat:FindFirstChild("FRONT_MARKER", true)
		local fwd: Vector3
		if frontMarker and frontMarker:IsA("BasePart") then
			local dir = Vector3.new(frontMarker.Position.X - rootPos.X, 0, frontMarker.Position.Z - rootPos.Z)
			fwd = if dir.Magnitude > 0.5 then dir.Unit else Vector3.new(0, 0, -1)
		else
			-- Velocity sample fallback
			task.wait(0.15)
			local bbCF1, _ = playerBoat:GetBoundingBox()
			local delta = Vector3.new(bbCF1.Position.X - rootPos.X, 0, bbCF1.Position.Z - rootPos.Z)
			rootPos = bbCF1.Position
			fwd = if delta.Magnitude > 0.005 then delta.Unit else Vector3.new(0, 0, -1)
		end
		local right = Vector3.new(-fwd.Z, 0, fwd.X)
		local perp  = right * (if approachSide >= 0 then 1 else -1)

		-- Deck Y: same formula as PirateRaid — boatRoot (Union hull) sits at sea surface, +15 = deck
		local TANKER_DECK_Y   = 15
		local bbCF, bbSize    = playerBoat:GetBoundingBox()
		local deckY           = boatRoot.Position.Y + TANKER_DECK_Y
		local waterY          = boatRoot.Position.Y  -- CG boat placed at hull Y = sea surface
		local boatLenHalf     = math.max(bbSize.X, bbSize.Z) / 2 * 0.72
		local boatWidthHalf   = math.min(bbSize.X, bbSize.Z) / 2 * 0.45
		local playerHalfWidth = math.max(bbSize.X, bbSize.Z) / 2
		local deckCtr         = Vector3.new(rootPos.X, deckY, rootPos.Z)

		local function flatLookAt(pos: Vector3, toward: Vector3): CFrame
			local dx, dz = toward.X - pos.X, toward.Z - pos.Z
			if math.abs(dx) + math.abs(dz) < 0.001 then
				return CFrame.lookAt(pos, pos + fwd)
			end
			return CFrame.lookAt(pos, Vector3.new(toward.X, pos.Y, toward.Z))
		end

		local function setObjCF(obj: any, cf: CFrame)
			if obj:IsA("Model") then obj:PivotTo(cf) else obj.CFrame = cf end
		end

		local function prepStatic(inst: Instance)
			for _, d in ipairs(inst:GetDescendants()) do
				if d:IsA("BasePart") then
					d.Anchored = true; d.CanCollide = false; d.CanQuery = false; d.CanTouch = false
				end
			end
		end

		-- Walking animation: constant speed + vertical bob = looks like actual footsteps
		local WALK_SPEED   = 9   -- studs/sec on deck
		local RETURN_SPEED = 14  -- studs/sec when jogging back

		local function walkNpc(officer, targetCF: CFrame, speed: number?)
			local spd     = speed or WALK_SPEED
			local fromPos = officer.cf.Position
			local toPos   = targetCF.Position
			local dist    = (toPos - fromPos).Magnitude
			if dist < 0.3 then
				officer.cf = targetCF
				setObjCF(officer.npc, targetCF)
				return
			end
			local dur   = dist / spd
			local t0    = os.clock()
			local flat  = Vector3.new(toPos.X - fromPos.X, 0, toPos.Z - fromPos.Z)
			local lookD = if flat.Magnitude > 0.001 then flat.Unit else fwd
			while true do
				local alpha = math.min((os.clock() - t0) / dur, 1)
				local pos   = fromPos:Lerp(toPos, alpha)
				local bob   = math.abs(math.sin(os.clock() * math.pi * 2.4)) * 0.32
				setObjCF(officer.npc, CFrame.new(pos + Vector3.new(0, bob, 0), pos + lookD + Vector3.new(0, bob, 0)))
				if alpha >= 1 then break end
				task.wait()
			end
			officer.cf = targetCF
			setObjCF(officer.npc, targetCF)
		end

		local function runPar(tasks: { () -> () }, minDur: number)
			local done = 0
			if #tasks == 0 then task.wait(minDur); return end
			for _, fn in ipairs(tasks) do
				task.spawn(function() fn(); done += 1 end)
			end
			local t0 = os.clock()
			while done < #tasks do task.wait() end
			local left = minDur - (os.clock() - t0)
			if left > 0 then task.wait(left) end
		end

		-- Constants
		local PHASE_APPROACH   = 3.0
		local PHASE_BOARD_INSP = 8.5   -- board + inspect combined per officer
		local PHASE_RETURN     = 2.5
		local OFFICER_COUNT    = 6
		local OFFICER_SPACING  = 1.8
		local CG_BOAT_DECK_Y   = 5    -- calibrated: deck height above CG boat pivot
		local CG_HALF_WIDTH    = 11   -- used for zipFromPos offset on CG boat side
		local PARK_LATERAL     = 100  -- calibrated: CG boat parks 100 studs from tanker pivot
		local LAND_LATERAL     = -1   -- calibrated: lateral offset from deck center
		local LAND_FWD         = 35   -- calibrated: forward offset from deck center to zipline landing
		local SPAWN_LATERAL    = 240
		local SLIDE_DUR        = 0.6
		local BOARD_STAGGER    = 0.35
		local officerMid       = (OFFICER_COUNT + 1) / 2

		-- CG boat positions (Y = waterY so boat sits at sea level, not tanker center height)
		local parkLateral  = PARK_LATERAL
		local cgBase       = Vector3.new(rootPos.X, waterY, rootPos.Z)
		local parkPos      = cgBase + perp * parkLateral
		local spawnPos     = cgBase + perp * (parkLateral + SPAWN_LATERAL)

		-- Clone CG boat and animate approach (officers spawn AFTER park so they don't float)
		local cgBoat = cgShipTemplate:Clone()
		prepStatic(cgBoat)
		cgBoat.Parent = Workspace
		cgBoat:PivotTo(flatLookAt(spawnPos, spawnPos - perp))
		Debris:AddItem(cgBoat, 42)

		-- Siren lights + sound start immediately during approach
		local stopSiren: () -> ()
		do
			local bp = cgBoat:FindFirstChildWhichIsA("BasePart", true)
			local rL = Instance.new("PointLight"); rL.Color = Color3.fromRGB(255,50,50); rL.Brightness = 10; rL.Range = 50; rL.Parent = if bp then bp else cgBoat
			local bL = Instance.new("PointLight"); bL.Color = Color3.fromRGB(50,120,255); bL.Brightness = 10; bL.Range = 50; bL.Enabled = false; bL.Parent = if bp then bp else cgBoat
			local snd = Instance.new("Sound"); snd.SoundId = "rbxassetid://4590662766"; snd.Volume = 0.55; snd.Looped = true; snd.RollOffMaxDistance = 320; snd.Parent = cgBoat; snd:Play()
			local active = true
			stopSiren = function() active = false end
			task.spawn(function()
				while active do
					rL.Enabled = true; bL.Enabled = false; task.wait(0.38)
					if not active then break end
					rL.Enabled = false; bL.Enabled = true; task.wait(0.38)
				end
				rL.Enabled = false; bL.Enabled = false; snd:Stop()
			end)
		end

		-- Phase 1: CG boat drives laterally to park alongside tanker
		animateMove(cgBoat, cgBoat:GetPivot(), flatLookAt(parkPos, parkPos - perp), PHASE_APPROACH, 0)

		-- Snap to live boat position after approach (tanker may have sailed forward during the 3s drive)
		local snapBbCF, _ = playerBoat:GetBoundingBox()
		rootPos = snapBbCF.Position
		right   = Vector3.new(-fwd.Z, 0, fwd.X)
		perp    = right * (if approachSide >= 0 then 1 else -1)
		deckCtr = Vector3.new(rootPos.X, boatRoot.Position.Y + TANKER_DECK_Y, rootPos.Z)

		local snappedPark = Vector3.new(rootPos.X, boatRoot.Position.Y, rootPos.Z) + perp * parkLateral
		cgBoat:PivotTo(flatLookAt(snappedPark, snappedPark - perp))

		-- NOW spawn officers on the PARKED CG boat (visible standing in a row)
		local cgParkedPos = cgBoat:GetPivot().Position
		local officers = {}
		for i = 1, OFFICER_COUNT do
			local npc    = cgNpcTemplate:Clone()
			prepStatic(npc)
			local along  = fwd * ((i - officerMid) * OFFICER_SPACING)
			local npcPos = cgParkedPos + Vector3.new(0, CG_BOAT_DECK_Y, 0) + along
			local npcCF  = flatLookAt(npcPos, rootPos)
			setObjCF(npc, npcCF)
			npc.Parent = Workspace  -- world-space from the start, no re-parenting needed
			table.insert(officers, { npc = npc, cf = npcCF })
			Debris:AddItem(npc, 42)
		end

		-- Brief pause so player sees officers standing on deck
		task.wait(0.5)

		-- Zipline anchor points — spawn visible studs so you can drag them in playtest when calibrating
		local zipFromPos = cgParkedPos + Vector3.new(0, CG_BOAT_DECK_Y, 0) - perp * (CG_HALF_WIDTH * 0.7) + fwd * 2
		local zipToPos   = deckCtr + perp * LAND_LATERAL + fwd * LAND_FWD

		local sharedMod = ReplicatedStorage:FindFirstChild("Shared")
		local constMod  = sharedMod and sharedMod:FindFirstChild("Constants")
		local constData = constMod and require(constMod :: ModuleScript) :: any
		local doCalib   = constData and constData.StraitEventsDebug and constData.StraitEventsDebug.CoastGuardCalibrateAnchors

		-- Red stud = CG boat boarding anchor (zipFromPos)
		local anchorFrom = Instance.new("Part"); anchorFrom.Name = "CG_AnchorFrom"
		anchorFrom.Size = Vector3.new(2,2,2); anchorFrom.Anchored = true; anchorFrom.CanCollide = false
		anchorFrom.CanQuery = false; anchorFrom.CanTouch = false; anchorFrom.Material = Enum.Material.Neon
		anchorFrom.Color = Color3.fromRGB(255,60,60); anchorFrom.CFrame = CFrame.new(zipFromPos)
		anchorFrom.Parent = Workspace; Debris:AddItem(anchorFrom, 60)

		-- Green stud = tanker deck landing anchor (zipToPos)
		local anchorTo = Instance.new("Part"); anchorTo.Name = "CG_AnchorTo"
		anchorTo.Size = Vector3.new(2,2,2); anchorTo.Anchored = true; anchorTo.CanCollide = false
		anchorTo.CanQuery = false; anchorTo.CanTouch = false; anchorTo.Material = Enum.Material.Neon
		anchorTo.Color = Color3.fromRGB(60,255,60); anchorTo.CFrame = CFrame.new(zipToPos)
		anchorTo.Parent = Workspace; Debris:AddItem(anchorTo, 60)

		if doCalib then
			-- Pause here — drag the red and green studs in the viewport, then they'll be read below
			print("[CG Calibrate] Drag CG_AnchorFrom (RED) and CG_AnchorTo (GREEN) now. Resuming in 15s...")
			task.wait(15)
			zipFromPos = anchorFrom.Position
			zipToPos   = anchorTo.Position
			print(string.format("[CG Calibrate] zipFromPos = Vector3.new(%.2f, %.2f, %.2f)", zipFromPos.X, zipFromPos.Y, zipFromPos.Z))
			print(string.format("[CG Calibrate] zipToPos   = Vector3.new(%.2f, %.2f, %.2f)", zipToPos.X, zipToPos.Y, zipToPos.Z))
		end

		local zipA = Instance.new("Part"); zipA.Name = "CGZipA"; zipA.Size = Vector3.new(0.4,2,0.4); zipA.Anchored = true; zipA.CanCollide = false; zipA.CanQuery = false; zipA.CanTouch = false; zipA.Material = Enum.Material.Metal; zipA.Color = Color3.fromRGB(60,80,120); zipA.CFrame = CFrame.new(zipFromPos); zipA.Parent = Workspace; Debris:AddItem(zipA, 30)
		local zipB = Instance.new("Part"); zipB.Name = "CGZipB"; zipB.Size = Vector3.new(0.4,2,0.4); zipB.Anchored = true; zipB.CanCollide = false; zipB.CanQuery = false; zipB.CanTouch = false; zipB.Material = Enum.Material.Metal; zipB.Color = Color3.fromRGB(60,80,120); zipB.CFrame = CFrame.new(zipToPos); zipB.Parent = Workspace; Debris:AddItem(zipB, 30)
		local attA = Instance.new("Attachment"); attA.Position = Vector3.new(0,1,0); attA.Parent = zipA
		local attB = Instance.new("Attachment"); attB.Position = Vector3.new(0,1,0); attB.Parent = zipB
		local rope = Instance.new("Beam"); rope.Attachment0 = attA; rope.Attachment1 = attB; rope.Width0 = 0.35; rope.Width1 = 0.35; rope.FaceCamera = true; rope.Color = ColorSequence.new(Color3.fromRGB(60,100,160)); rope.Parent = zipA

		-- 6 inspection zones computed from actual boat footprint
		local zones = {
			deckCtr + fwd * boatLenHalf * 0.80,                          -- bow
			deckCtr - fwd * boatLenHalf * 0.80,                          -- stern
			deckCtr + fwd * boatLenHalf * 0.35 + right * boatWidthHalf,  -- fwd starboard
			deckCtr + fwd * boatLenHalf * 0.35 - right * boatWidthHalf,  -- fwd port
			deckCtr - fwd * boatLenHalf * 0.35 + right * boatWidthHalf,  -- aft starboard
			deckCtr - fwd * boatLenHalf * 0.35 - right * boatWidthHalf,  -- aft port
		}
		local altZones = {
			deckCtr + fwd * boatLenHalf * 0.55,
			deckCtr - fwd * boatLenHalf * 0.55,
			deckCtr,
			deckCtr + right * boatWidthHalf * 0.6,
			deckCtr - right * boatWidthHalf * 0.6,
			deckCtr + fwd * boatLenHalf * 0.6 + right * boatWidthHalf * 0.5,
		}

		-- Phase 2: Board + Inspect — each officer independently
		-- Officer walks to zipline, slides across, then immediately walks to their zones
		local rng = Random.new()
		local boardInspTasks: { () -> () } = {}
		for i, off in ipairs(officers) do
			local idx = i
			table.insert(boardInspTasks, function()
				-- Stagger boarding
				task.wait((idx - 1) * BOARD_STAGGER)

				-- Walk to zipline anchor on CG boat side
				walkNpc(off, flatLookAt(zipFromPos, zipToPos), WALK_SPEED)

				-- Slide across zipline
				local t0 = os.clock()
				while true do
					local a = math.min((os.clock() - t0) / SLIDE_DUR, 1)
					local e = a * a * (3 - 2 * a)
					local p = zipFromPos:Lerp(zipToPos, e) + Vector3.new(0, -2.5 * math.sin(e * math.pi), 0)
					setObjCF(off.npc, flatLookAt(p, zipToPos))
					if a >= 1 then break end
					task.wait()
				end
				off.cf = flatLookAt(zipToPos, zipToPos - perp)

				-- Immediately walk to primary inspection zone
				local z1 = zones[idx]
				local z2 = altZones[((idx) % #altZones) + 1]
				walkNpc(off, flatLookAt(z1, z1 + fwd * (if idx % 2 == 0 then 1 else -1)), WALK_SPEED)
				task.wait(rng:NextNumber(0.7, 1.1))

				-- Walk to secondary zone
				walkNpc(off, flatLookAt(z2, z2 + fwd * (if idx % 2 == 0 then -1 else 1)), WALK_SPEED)
				task.wait(rng:NextNumber(0.5, 0.9))
			end)
		end
		runPar(boardInspTasks, PHASE_BOARD_INSP)

		-- Phase 3: All officers jog back to zipline and slide back simultaneously
		local returnTasks: { () -> () } = {}
		for i, off in ipairs(officers) do
			local idx = i
			table.insert(returnTasks, function()
				-- Jog back to zipline tanker-side anchor
				walkNpc(off, flatLookAt(zipToPos, zipFromPos), RETURN_SPEED)

				-- Slide back across zipline
				local t0 = os.clock()
				while true do
					local a = math.min((os.clock() - t0) / SLIDE_DUR, 1)
					local e = a * a * (3 - 2 * a)
					local p = zipToPos:Lerp(zipFromPos, e) + Vector3.new(0, -2.5 * math.sin(e * math.pi), 0)
					setObjCF(off.npc, flatLookAt(p, zipFromPos))
					if a >= 1 then break end
					task.wait()
				end

				-- Walk back to row on CG boat
				local deckPos = cgParkedPos + Vector3.new(0, CG_BOAT_DECK_Y, 0) + fwd * ((idx - officerMid) * OFFICER_SPACING)
				walkNpc(off, flatLookAt(deckPos, deckPos - perp), WALK_SPEED)
			end)
		end
		runPar(returnTasks, PHASE_RETURN)

		-- Cleanup
		Debris:AddItem(zipA, 0.05)
		Debris:AddItem(zipB, 0.05)
		stopSiren()

		-- Depart
		local escapeTarget = cgBoat:GetPivot().Position + perp * 200
		animateMove(cgBoat, cgBoat:GetPivot(), flatLookAt(escapeTarget, escapeTarget - perp), 1.5, 0)
		Debris:AddItem(cgBoat, 2)
	end)
end

function StraitWaypointWorldFx.OnUSShipSlapPayload(data: { [string]: any })
	local shipmentId   = if typeof(data.shipmentId) == "string" then data.shipmentId else ""
	local approachSide = tonumber(data.approachSide) or 1

	local assets = ReplicatedStorage:FindFirstChild("Assets")
	if not assets then return end
	local usShipTemplate = assets:FindFirstChild("USShip")
	if not usShipTemplate then
		warn("[StraitWaypointWorldFx] Missing USShip in ReplicatedStorage.Assets")
		return
	end
	local armTemplate = assets:FindFirstChild("GiantArm")
	if not armTemplate then
		warn("[StraitWaypointWorldFx] Missing GiantArm in ReplicatedStorage.Assets")
		return
	end

	task.spawn(function()
		local playerBoat = findActiveShipmentBoatByShipmentId(shipmentId)
		if not playerBoat then return end
		local boatRoot = getBoatAttachmentPart(playerBoat)
		if not boatRoot then return end

		local bbCF, _ = playerBoat:GetBoundingBox()
		local rootPos   = bbCF.Position
		local TANKER_DECK_Y = 15

		local frontMarker = playerBoat:FindFirstChild("FRONT_MARKER", true)
		local fwd: Vector3
		if frontMarker and frontMarker:IsA("BasePart") then
			local dir = Vector3.new(frontMarker.Position.X - rootPos.X, 0, frontMarker.Position.Z - rootPos.Z)
			fwd = if dir.Magnitude > 0.5 then dir.Unit else Vector3.new(0, 0, -1)
		else
			task.wait(0.15)
			local bbCF1, _ = playerBoat:GetBoundingBox()
			local delta = Vector3.new(bbCF1.Position.X - rootPos.X, 0, bbCF1.Position.Z - rootPos.Z)
			rootPos = bbCF1.Position
			fwd = if delta.Magnitude > 0.005 then delta.Unit else Vector3.new(0, 0, -1)
		end
		local right = Vector3.new(-fwd.Z, 0, fwd.X)
		local perp  = right * (if approachSide >= 0 then 1 else -1)

		local waterY = boatRoot.Position.Y
		local deckY  = boatRoot.Position.Y + TANKER_DECK_Y

		local function flatLookAt(pos: Vector3, toward: Vector3): CFrame
			local dx, dz = toward.X - pos.X, toward.Z - pos.Z
			if math.abs(dx) + math.abs(dz) < 0.001 then
				return CFrame.lookAt(pos, pos + fwd)
			end
			return CFrame.lookAt(pos, Vector3.new(toward.X, pos.Y, toward.Z))
		end

		local function prepStatic(inst: Instance)
			for _, d in ipairs(inst:GetDescendants()) do
				if d:IsA("BasePart") then
					d.Anchored = true; d.CanCollide = false; d.CanQuery = false; d.CanTouch = false
				end
			end
		end

		local PARK_LATERAL  = 120
		local SPAWN_LATERAL = 300

		-- USShip: pivot is at mesh center, raise by half-height so bottom sits at waterY
		local usShip = usShipTemplate:Clone()
		prepStatic(usShip)
		usShip.Parent = Workspace
		local _, usBbSz = usShip:GetBoundingBox()
		local shipY = waterY + usBbSz.Y / 2

		local spawnPosFixed = Vector3.new(rootPos.X, shipY, rootPos.Z) + perp * (PARK_LATERAL + SPAWN_LATERAL)
		local parkPosFixed  = Vector3.new(rootPos.X, shipY, rootPos.Z) + perp * PARK_LATERAL
		usShip:PivotTo(flatLookAt(spawnPosFixed, spawnPosFixed - perp))
		Debris:AddItem(usShip, 25)

		animateMove(usShip, usShip:GetPivot(), flatLookAt(parkPosFixed, parkPosFixed - perp), 3, 0)

		-- Snap to tanker's current position after approach
		local snapCF, _ = playerBoat:GetBoundingBox()
		rootPos = snapCF.Position
		local snappedPark = Vector3.new(rootPos.X, shipY, rootPos.Z) + perp * PARK_LATERAL
		usShip:PivotTo(flatLookAt(snappedPark, snappedPark - perp))
		local usShipPos = usShip:GetPivot().Position
		local deckCtr   = Vector3.new(rootPos.X, deckY, rootPos.Z)

		-- Clone GiantArm and rise it from USShip deck
		local arm = armTemplate:Clone()
		prepStatic(arm)
		arm.Parent = Workspace
		Debris:AddItem(arm, 20)

		local _, armBbSz = arm:GetBoundingBox()
		local ARM_H = armBbSz.Y  -- ~63 studs tall

		-- XZ: slight offset from USShip toward tanker; orient so palm faces tanker
		local armXZ = usShipPos + (-perp) * 5
		-- Pivot rises from arm-fully-hidden-below-deck to arm-fully-above-deck
		local armBotY    = deckY - ARM_H / 2 - 1   -- top of arm just below deck at start
		local armRaisedY = deckY + ARM_H / 2 + 2   -- bottom of arm just above deck at end

		local armStartCF = CFrame.lookAt(
			Vector3.new(armXZ.X, armBotY, armXZ.Z),
			Vector3.new(armXZ.X + perp.X, armBotY, armXZ.Z + perp.Z)
		)
		local armRaisedCF = CFrame.lookAt(
			Vector3.new(armXZ.X, armRaisedY, armXZ.Z),
			Vector3.new(armXZ.X + perp.X, armRaisedY, armXZ.Z + perp.Z)
		)
		arm:PivotTo(armStartCF)
		animateMove(arm, armStartCF, armRaisedCF, 1.5, 0)

		-- Windup: pull arm back toward USShip (0.5s)
		local armRaisedPos = arm:GetPivot().Position
		local windupPos    = armRaisedPos + perp * 15
		local windupCF     = CFrame.lookAt(windupPos, windupPos + perp)
		animateMove(arm, arm:GetPivot(), windupCF, 0.5, 0)

		-- SLAP: arm sweeps fast through and past the tanker (0.3s)
		local slapXZ    = deckCtr - perp * (PARK_LATERAL - 10)
		local slapEndCF = CFrame.lookAt(
			Vector3.new(slapXZ.X, arm:GetPivot().Position.Y, slapXZ.Z),
			Vector3.new(slapXZ.X + perp.X, arm:GetPivot().Position.Y, slapXZ.Z + perp.Z)
		)
		animateMove(arm, arm:GetPivot(), slapEndCF, 0.3, 0)

		-- Check if local player's character is on the tanker — if so, fly with it
		local Players    = game:GetService("Players")
		local localChar  = Players.LocalPlayer and Players.LocalPlayer.Character
		local hrp        = localChar and localChar:FindFirstChild("HumanoidRootPart") :: BasePart?
		local charRelCF: CFrame? = nil
		local charHumanoid = localChar and localChar:FindFirstChildOfClass("Humanoid")
		if hrp then
			local distToBoat = (hrp.Position - playerBoat:GetPivot().Position).Magnitude
			if distToBoat < 80 then
				charRelCF = playerBoat:GetPivot():Inverse() * localChar:GetPivot()
				if charHumanoid then charHumanoid.PlatformStand = true end
			end
		end

		-- Tanker (+ character) flies off in a huge arc
		local tankerStart = playerBoat:GetPivot()
		local flyDir      = (-perp + fwd * 0.3).Unit
		local offMapPos   = tankerStart.Position + flyDir * 1500
		local tankerEndCF = CFrame.new(Vector3.new(offMapPos.X, tankerStart.Position.Y, offMapPos.Z))
			* (tankerStart - tankerStart.Position)

		if charRelCF and localChar then
			local FLY_DUR = 2
			local ARC_H   = 180
			local flyT0   = os.clock()
			task.spawn(function()
				while true do
					local alpha = math.min((os.clock() - flyT0) / FLY_DUR, 1)
					local e     = alpha * alpha * (3 - 2 * alpha)
					local pos   = tankerStart.Position:Lerp(tankerEndCF.Position, e)
					pos = pos + Vector3.new(0, ARC_H * math.sin(e * math.pi), 0)
					local cf = CFrame.new(pos) * (tankerStart - tankerStart.Position):Lerp(tankerEndCF - tankerEndCF.Position, e)
					playerBoat:PivotTo(cf)
					if localChar.Parent then
						localChar:PivotTo(cf * charRelCF)
					end
					if alpha >= 1 then break end
					task.wait()
				end
				if charHumanoid then charHumanoid.PlatformStand = false end
			end)
			task.wait(FLY_DUR + 0.1)
		else
			animateMove(playerBoat, tankerStart, tankerEndCF, 2, 180)
		end

		task.wait(0.3)
		Debris:AddItem(arm, 0.05)

		-- USShip departs
		local escapePos = snappedPark + perp * 400
		animateMove(usShip, usShip:GetPivot(), flatLookAt(escapePos, escapePos - perp), 1.5, 0)
		Debris:AddItem(usShip, 1)
	end)
end

return StraitWaypointWorldFx
