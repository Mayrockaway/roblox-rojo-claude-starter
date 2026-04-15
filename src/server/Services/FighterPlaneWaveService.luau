--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DevLog = require(Shared:WaitForChild("DevLog"))
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))

local FighterPlaneWaveService = {}

type FlightRoute = {
	name: string,
	startPart: BasePart,
	endPart: BasePart,
}

type JetTemplate = Model | BasePart

type RemoteServiceLike = {
	GetEvent: (self: any, name: string) -> RemoteEvent,
}

type VectorPayload = {
	x: number,
	y: number,
	z: number,
}

type FlyoverPayload = {
	label: string,
	start: VectorPayload,
	finish: VectorPayload,
	speed: number,
	scale: number,
}

local TEMPLATE_FOLDER_NAME = "Assets"
local PRIMARY_TEMPLATE_NAME = "Jet"

local ROUTE_FOLDER_NAMES = {
	"JetScenarioStuds",
	"JetScenarios",
	"JetRoutes",
	"FlyoverRoutes",
}

local START_NAME_CANDIDATES = {
	"Start",
	"Spawn",
	"StartPoint",
}

local END_NAME_CANDIDATES = {
	"End",
	"Despawn",
	"EndPoint",
}

local MIN_WAVE_INTERVAL_SECONDS = 15
local MAX_WAVE_INTERVAL_SECONDS = 90
local MIN_JETS_PER_WAVE = 3
local MAX_JETS_PER_WAVE = 4
local LEG_STAGGER_SECONDS = 1.0
local DEBUG_WAVE_COOLDOWN_SECONDS = 5

local PLANE_SPEED_MIN = 650
local PLANE_SPEED_MAX = 900
local MIN_FLIGHT_DURATION_SECONDS = 14
local MIN_DURATION_BUFFER_SECONDS = 2
local DESPAWN_OVERSHOOT_STUDS = 1200
local SCALE_VARIANCE_MIN = 0.96
local SCALE_VARIANCE_MAX = 1.08

function FighterPlaneWaveService:Init(remoteService: RemoteServiceLike)
	self._running = false
	self._rng = Random.new()
	self._template = nil
	self._remoteService = remoteService
	self._flyoverEvent = nil
	self._lastDebugWaveAt = 0
	self._missingRoutesWarned = false
end

function FighterPlaneWaveService:Start()
	if self._running then
		return
	end
	self._running = true

	self._template = self:_resolveTemplate()
	if not self._template then
		warn("[FighterPlaneWaveService] Missing ReplicatedStorage.Assets.Jet template (Model or BasePart). Waves disabled.")
		self._running = false
		return
	end

	if not self._remoteService then
		warn("[FighterPlaneWaveService] RemoteService not available. Waves disabled.")
		self._running = false
		return
	end

	local okRemote, remoteOrErr = pcall(function()
		return self._remoteService:GetEvent(RemoteNames.FighterFlyoverEvent)
	end)
	if not okRemote then
		warn("[FighterPlaneWaveService] FighterFlyoverEvent missing: " .. tostring(remoteOrErr))
		self._running = false
		return
	end

	self._flyoverEvent = remoteOrErr :: RemoteEvent

	task.spawn(function()
		while self._running do
			local waitTime = self._rng:NextNumber(MIN_WAVE_INTERVAL_SECONDS, MAX_WAVE_INTERVAL_SECONDS)
			task.wait(waitTime)
			if not self._running then
				break
			end
			self:_spawnWave(false, false)
		end
	end)

	DevLog.log(string.format("[FighterPlaneWaveService] Started flyover waves using %s.", self._template.Name))
end

function FighterPlaneWaveService:Stop()
	self._running = false
	self._flyoverEvent = nil
end

function FighterPlaneWaveService:DebugSpawnWave(source: string?)
	if not self._running then
		warn("[FighterPlaneWaveService] DebugSpawnWave ignored: service not running.")
		return
	end
	local now = os.clock()
	if now - self._lastDebugWaveAt < DEBUG_WAVE_COOLDOWN_SECONDS then
		warn("[FighterPlaneWaveService] DebugSpawnWave cooling down.")
		return
	end
	self._lastDebugWaveAt = now
	DevLog.log(string.format("[FighterPlaneWaveService] Debug wave trigger (%s).", source or "manual"))
	self:_spawnWave(true, true)
end

function FighterPlaneWaveService:DebugSpawnOverPlayer(player: Player)
	if not self._running then
		warn("[FighterPlaneWaveService] DebugSpawnOverPlayer ignored: service not running.")
		return
	end

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		warn("[FighterPlaneWaveService] DebugSpawnOverPlayer: no HumanoidRootPart.")
		return
	end

	local center = root.Position
	local startPos = center + Vector3.new(0, 320, -900)
	local endPos = center + Vector3.new(0, 320, 900)
	self:_spawnPlane("direct_player", startPos, endPos)
end

function FighterPlaneWaveService:DebugRetargetTemplate(source: string?)
	self._template = self:_resolveTemplate()
	if self._template then
		DevLog.log(string.format("[FighterPlaneWaveService] Retargeted template (%s): %s", source or "manual", self._template.Name))
	else
		warn("[FighterPlaneWaveService] Retarget failed: ReplicatedStorage.Assets.Jet missing.")
	end
end

function FighterPlaneWaveService:_resolveTemplate(): JetTemplate?
	local assets = ReplicatedStorage:FindFirstChild(TEMPLATE_FOLDER_NAME)
	local scoped = assets and assets:FindFirstChild(PRIMARY_TEMPLATE_NAME)
	if scoped and (scoped:IsA("Model") or scoped:IsA("BasePart")) then
		return scoped
	end

	local fallback = Workspace:FindFirstChild(PRIMARY_TEMPLATE_NAME)
	if fallback and (fallback:IsA("Model") or fallback:IsA("BasePart")) then
		warn("[FighterPlaneWaveService] Using Workspace.Jet fallback; move template to ReplicatedStorage.Assets.Jet.")
		return fallback
	end

	return nil
end

function FighterPlaneWaveService:_shuffle<T>(arr: { T }): { T }
	local out = table.clone(arr)
	for i = #out, 2, -1 do
		local j = self._rng:NextInteger(1, i)
		out[i], out[j] = out[j], out[i]
	end
	return out
end

function FighterPlaneWaveService:_findNamedBasePart(container: Instance, candidates: { string }): BasePart?
	for _, candidateName in ipairs(candidates) do
		local child = container:FindFirstChild(candidateName)
		if child and child:IsA("BasePart") then
			return child
		end
	end
	return nil
end

function FighterPlaneWaveService:_getRoutesRoot(): Instance?
	for _, folderName in ipairs(ROUTE_FOLDER_NAMES) do
		local root = Workspace:FindFirstChild(folderName)
		if root and (root:IsA("Folder") or root:IsA("Model")) then
			return root
		end
	end

	local map = Workspace:FindFirstChild("Map")
	if map then
		for _, folderName in ipairs(ROUTE_FOLDER_NAMES) do
			local root = map:FindFirstChild(folderName)
			if root and (root:IsA("Folder") or root:IsA("Model")) then
				return root
			end
		end
	end

	return nil
end

function FighterPlaneWaveService:_collectRoutes(): { FlightRoute }
	local routes = {}
	local root = self:_getRoutesRoot()
	if not root then
		if not self._missingRoutesWarned then
			warn("[FighterPlaneWaveService] No route folder found. Create Workspace.JetScenarios (or Map.JetScenarios) with scenario folders containing Start + End parts.")
			self._missingRoutesWarned = true
		end
		return routes
	end

	local directStarts: { [string]: BasePart } = {}
	local directEnds: { [string]: BasePart } = {}

	for _, child in ipairs(root:GetChildren()) do
		if child:IsA("Folder") or child:IsA("Model") then
			local startPart = self:_findNamedBasePart(child, START_NAME_CANDIDATES)
			local endPart = self:_findNamedBasePart(child, END_NAME_CANDIDATES)
			if startPart and endPart then
				table.insert(routes, {
					name = child.Name,
					startPart = startPart,
					endPart = endPart,
				})
			end
		elseif child:IsA("BasePart") then
			local suffix = string.match(child.Name, "^[Ss]tart[_%s-]*(.+)$")
			if suffix and #suffix > 0 then
				directStarts[suffix] = child
			else
				suffix = string.match(child.Name, "^[Ee]nd[_%s-]*(.+)$") or string.match(child.Name, "^[Dd]espawn[_%s-]*(.+)$")
				if suffix and #suffix > 0 then
					directEnds[suffix] = child
				end
			end
		end
	end

	for suffix, startPart in pairs(directStarts) do
		local endPart = directEnds[suffix]
		if endPart then
			table.insert(routes, {
				name = suffix,
				startPart = startPart,
				endPart = endPart,
			})
		end
	end

	if #routes == 0 then
		warn("[FighterPlaneWaveService] Route folder found but no valid routes. Each scenario needs Start + End BaseParts.")
	end

	return routes
end

function FighterPlaneWaveService:_spawnWave(debugLog: boolean, forceAll: boolean?)
	if not (self._template and self._template.Parent) then
		self._template = self:_resolveTemplate()
		if not self._template then
			warn("[FighterPlaneWaveService] Missing ReplicatedStorage.Assets.Jet template; skipping wave.")
			return
		end
	end

	local routes = self:_collectRoutes()
	if #routes == 0 then
		return
	end

	local waveCount = if forceAll then #routes else self._rng:NextInteger(MIN_JETS_PER_WAVE, MAX_JETS_PER_WAVE)
	waveCount = math.min(waveCount, #routes)
	if waveCount <= 0 then
		return
	end

	local shuffledRoutes = self:_shuffle(routes)
	for i = 1, waveCount do
		local route = shuffledRoutes[i]
		local delaySeconds = (i - 1) * LEG_STAGGER_SECONDS
		task.delay(delaySeconds, function()
			if not self._running then
				return
			end
			local startPos = route.startPart.Position
			local endPos = route.endPart.Position
			if debugLog then
				DevLog.log(string.format(
					"[FighterPlaneWaveService] route=%s start=(%.0f,%.0f,%.0f) end=(%.0f,%.0f,%.0f)",
					route.name,
					startPos.X,
					startPos.Y,
					startPos.Z,
					endPos.X,
					endPos.Y,
					endPos.Z
				))
			end
			self:_spawnPlane(route.name, startPos, endPos)
		end)
	end
end

function FighterPlaneWaveService:_toVectorPayload(v: Vector3): VectorPayload
	return {
		x = v.X,
		y = v.Y,
		z = v.Z,
	}
end

function FighterPlaneWaveService:_spawnPlane(label: string, startPos: Vector3, endPos: Vector3)
	local flyoverEvent = self._flyoverEvent
	if not flyoverEvent then
		return
	end

	local routeVector = endPos - startPos
	local direction = if routeVector.Magnitude > 1 then routeVector.Unit else Vector3.new(0, 0, 1)
	local speed = self._rng:NextNumber(PLANE_SPEED_MIN, PLANE_SPEED_MAX)
	local despawnEndPos = endPos + (direction * DESPAWN_OVERSHOOT_STUDS)
	local distance = (despawnEndPos - startPos).Magnitude
	local requiredDistance = speed * (MIN_FLIGHT_DURATION_SECONDS + MIN_DURATION_BUFFER_SECONDS)
	if distance < requiredDistance then
		local extra = requiredDistance - distance
		despawnEndPos += (direction * extra)
	end

	local payload: FlyoverPayload = {
		label = label,
		start = self:_toVectorPayload(startPos),
		finish = self:_toVectorPayload(despawnEndPos),
		speed = speed,
		scale = self._rng:NextNumber(SCALE_VARIANCE_MIN, SCALE_VARIANCE_MAX),
	}

	flyoverEvent:FireAllClients(payload)
end

return FighterPlaneWaveService
