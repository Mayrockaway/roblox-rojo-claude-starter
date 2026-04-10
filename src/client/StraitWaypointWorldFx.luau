--!strict
-- Cosmetic world feedback for StraitWaypointEvent (SPEC §8.2). Server remains authoritative;
-- all clients spawn local copies from the same replicated packet (start aligned when server fires before hold).
--
-- Workflow: author VFX under ReplicatedStorage.Assets.StraitWaypointsFx.<eventId>/ (clone at runtime; do not Instance.new art).
-- Optional: EVENT_FX[id] for attach logic (e.g. weld to boat). No generic severity particle fallbacks.

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
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
if sharedFolder then
	local pfsMod = sharedFolder:FindFirstChild("ParticleFxScale") or sharedFolder:WaitForChild("ParticleFxScale", 30)
	if pfsMod and pfsMod:IsA("ModuleScript") then
		local ok, loaded = pcall(require, pfsMod)
		if ok and typeof(loaded) == "table" then
			ParticleFxScale = loaded :: any
		end
	end
end

-- ReplicatedStorage.Assets.StraitWaypointsFx.<CatalogEventId>/ — Models or Parts as direct children; Sounds play when cloned.
local STRAIT_FX_ASSETS_FOLDER = "StraitWaypointsFx"

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
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local fxRoot = assets and assets:FindFirstChild(STRAIT_FX_ASSETS_FOLDER)
	local eventFolder = fxRoot and fxRoot:FindFirstChild(eventId)
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

--- Template lives in RS only: clone, then scale + parent/weld. Tune ParticleEmitter/Sound on the template in Studio (not in Luau).
local function getRoutinePaperworkAnchorTemplate(): BasePart?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local fxRoot = assets and assets:FindFirstChild(STRAIT_FX_ASSETS_FOLDER)
	local folder = fxRoot and fxRoot:FindFirstChild(ROUTINE_PAPERWORK_ID)
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
	local hull = if boat then getBoatAttachmentPart(boat) else nil

	if hull and boat then
		anchor.Parent = boat
		anchor.CFrame = hull.CFrame * ROUTINE_PAPERWORK_DECK_OFFSET
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = hull
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

local StraitWaypointWorldFx = {}

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

return StraitWaypointWorldFx
