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

local TweenService = game:GetService("TweenService")

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

return StraitWaypointWorldFx
