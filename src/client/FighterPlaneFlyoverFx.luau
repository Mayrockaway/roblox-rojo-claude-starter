--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local FighterPlaneFlyoverFx = {}

type JetTemplate = Model | BasePart

type VectorPayload = {
	x: number,
	y: number,
	z: number,
}

type FlyoverPayload = {
	label: string?,
	start: VectorPayload?,
	finish: VectorPayload?,
	speed: number?,
	scale: number?,
}

local TEMPLATE_FOLDER_NAME = "Assets"
local PRIMARY_TEMPLATE_NAME = "Jet"
local SPAWN_FOLDER_NAME = "_AmbientFighterWavesClient"
local DEFAULT_SPEED = 1200

local spawnFolder: Folder? = nil
local remoteConnection: RBXScriptConnection? = nil
local warnedMissingTemplate = false

local function ensureSpawnFolder(): Folder
	if spawnFolder and spawnFolder.Parent then
		return spawnFolder
	end

	local found = Workspace:FindFirstChild(SPAWN_FOLDER_NAME)
	if found and found:IsA("Folder") then
		spawnFolder = found
		return found
	end

	local created = Instance.new("Folder")
	created.Name = SPAWN_FOLDER_NAME
	created.Parent = Workspace
	spawnFolder = created
	return created
end

local function resolveTemplate(): JetTemplate?
	local assets = ReplicatedStorage:FindFirstChild(TEMPLATE_FOLDER_NAME)
	local scoped = assets and assets:FindFirstChild(PRIMARY_TEMPLATE_NAME)
	if scoped and (scoped:IsA("Model") or scoped:IsA("BasePart")) then
		return scoped
	end

	local fallback = Workspace:FindFirstChild(PRIMARY_TEMPLATE_NAME)
	if fallback and (fallback:IsA("Model") or fallback:IsA("BasePart")) then
		warn("[FighterPlaneFlyoverFx] Using Workspace.Jet fallback; move template to ReplicatedStorage.Assets.Jet.")
		return fallback
	end

	if not warnedMissingTemplate then
		warn("[FighterPlaneFlyoverFx] Missing ReplicatedStorage.Assets.Jet; flyovers hidden.")
		warnedMissingTemplate = true
	end
	return nil
end

local function toVector3(raw: any): Vector3?
	if typeof(raw) ~= "table" then
		return nil
	end
	local x = raw.x
	local y = raw.y
	local z = raw.z
	if typeof(x) ~= "number" or typeof(y) ~= "number" or typeof(z) ~= "number" then
		return nil
	end
	if x ~= x or y ~= y or z ~= z then
		return nil
	end
	return Vector3.new(x, y, z)
end

local function getPivot(instance: JetTemplate): CFrame
	return (instance :: any):GetPivot()
end

local function pivotTo(instance: JetTemplate, cframe: CFrame)
	(instance :: any):PivotTo(cframe)
end

local function getCenterOffsetLocal(instance: JetTemplate): Vector3
	if instance:IsA("Model") then
		local pivot = getPivot(instance)
		local bboxCFrame = instance:GetBoundingBox()
		return pivot:PointToObjectSpace(bboxCFrame.Position)
	end
	return Vector3.zero
end

local function prepareCloneForFlyover(clone: JetTemplate)
	if clone:IsA("Model") then
		for _, descendant in ipairs(clone:GetDescendants()) do
			if descendant:IsA("Script") or descendant:IsA("LocalScript") then
				descendant.Disabled = true
			elseif descendant:IsA("BasePart") then
				descendant.Anchored = true
				descendant.CanCollide = false
				descendant.CanTouch = false
				descendant.CanQuery = false
			end
		end
	else
		clone.Anchored = true
		clone.CanCollide = false
		clone.CanTouch = false
		clone.CanQuery = false
		for _, descendant in ipairs(clone:GetDescendants()) do
			if descendant:IsA("Script") or descendant:IsA("LocalScript") then
				descendant.Disabled = true
			end
		end
	end
end

local function applyScale(clone: JetTemplate, factor: number)
	if clone:IsA("Model") then
		pcall(function()
			clone:ScaleTo(clone:GetScale() * factor)
		end)
	elseif clone:IsA("BasePart") then
		clone.Size = clone.Size * factor
	end
end

local function spawnFlyover(payload: FlyoverPayload)
	local template = resolveTemplate()
	if not template then
		return
	end

	local startPos = toVector3(payload.start)
	local finishPos = toVector3(payload.finish)
	if not (startPos and finishPos) then
		return
	end

	local routeVector = finishPos - startPos
	if routeVector.Magnitude < 1 then
		return
	end

	local speed = tonumber(payload.speed) or DEFAULT_SPEED
	if speed < 10 then
		speed = DEFAULT_SPEED
	end

	local scale = tonumber(payload.scale) or 1
	if scale <= 0 then
		scale = 1
	end

	local rawClone = template:Clone()
	if not (rawClone:IsA("Model") or rawClone:IsA("BasePart")) then
		rawClone:Destroy()
		return
	end
	local clone: JetTemplate = rawClone

	clone.Name = "FighterPlaneFlyover_" .. tostring(payload.label or "route")
	applyScale(clone, scale)
	prepareCloneForFlyover(clone)

	local centerOffsetLocal = getCenterOffsetLocal(clone)
	local duration = routeVector.Magnitude / speed
	local startedAt = os.clock()

	pivotTo(clone, CFrame.lookAt(startPos, finishPos))
	clone.Parent = ensureSpawnFolder()

	local conn: RBXScriptConnection? = nil
	conn = RunService.RenderStepped:Connect(function()
		if not clone.Parent then
			if conn then
				conn:Disconnect()
			end
			return
		end

		local alpha = (os.clock() - startedAt) / duration
		if alpha >= 1 then
			if conn then
				conn:Disconnect()
			end
			clone:Destroy()
			return
		end

		local position = startPos:Lerp(finishPos, alpha)
		local desired = CFrame.lookAt(position, finishPos)
		local visualCenter = desired:PointToWorldSpace(centerOffsetLocal)
		local correction = position - visualCenter
		pivotTo(clone, desired + correction)
	end)
end

function FighterPlaneFlyoverFx.Start(flyoverEvent: RemoteEvent)
	if remoteConnection then
		remoteConnection:Disconnect()
		remoteConnection = nil
	end

	remoteConnection = flyoverEvent.OnClientEvent:Connect(function(payload)
		if typeof(payload) ~= "table" then
			return
		end
		task.spawn(function()
			spawnFlyover(payload :: FlyoverPayload)
		end)
	end)
end

function FighterPlaneFlyoverFx.Stop()
	if remoteConnection then
		remoteConnection:Disconnect()
		remoteConnection = nil
	end
end

return FighterPlaneFlyoverFx