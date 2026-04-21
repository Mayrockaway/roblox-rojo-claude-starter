--!strict
-- Cosmetic world feedback for StraitWaypointEvent (SPEC §8.2). Server remains authoritative;
-- all clients spawn local copies from the same replicated packet (start aligned when server fires before hold).
--
-- Workflow: author VFX under ReplicatedStorage.Assets.StraitWaypointsFx.<eventId>/ (clone at runtime; do not Instance.new art).
-- Optional: EVENT_FX[id] for attach logic (e.g. weld to boat). No generic severity particle fallbacks.

local Debris = game:GetService("Debris")
local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

--- Serial event-voice queue (`Pirates`, `Storm`, `Coastguard`, …). Lazy
--- require so a load-order surprise never takes the cinematic FX down with
--- it — voice line is purely additive. Same shape used in
--- `src/client/UI/StraitStatusChangeFx.luau` for the Strait status flips.
local function tryEnqueueVoice(key: string)
	local ok, mod = pcall(function()
		return require(script.Parent:WaitForChild("EventVoiceQueue", 5)) :: any
	end)
	if ok and mod then
		mod.play(key)
	end
end

--- True when the local player is the owner of the shipment carrying this
--- event (matches the gating used in `ShipmentVisualClient` for HUD lines).
--- Visual cinematics still spawn for every client (the kraken / missile /
--- pirate boat needs to be visible to spectators), but voice lines + 2D
--- alarm bursts are owner-only — they're personal feedback, not public
--- ambience, and previously stacked on every player whenever someone else
--- got Pirates'd / Coastguard'd / Storm'd. Defensive against missing
--- `LocalPlayer` (e.g. test harness) by treating "no local player" as "not
--- owner" so audio simply doesn't fire.
local function isLocalOwner(data: { [string]: any }): boolean
	local lp = Players.LocalPlayer
	if not lp then return false end
	local owner = data and data.ownerUserId
	return typeof(owner) == "number" and owner == lp.UserId
end

--- Owner-gated wrapper around `tryEnqueueVoice` — call sites should use this
--- instead of `tryEnqueueVoice` so cosmetic FX are visible to spectators
--- but voice lines stay personal to the affected player.
local function tryEnqueueOwnerVoice(data: { [string]: any }, key: string)
	if not isLocalOwner(data) then return end
	tryEnqueueVoice(key)
end

--- Play a 2D one-shot Sound by asset id `count` times **serially** — the next
--- play waits on `Sound.Ended` before starting, so the user hears `count`
--- distinct hits back-to-back (no overlap). Used by the coastguard event for
--- the alarm/horn burst that fires before the `Coastguard` voice line.
---
--- `onComplete` (optional) runs after the final hit's `.Ended` — callers use
--- this to chain a follow-up (e.g. enqueue the voice line) so the voice plays
--- AFTER the burst rather than overlapping with it. Always invoked, even when
--- SFX is muted, so chained logic still progresses (with `count = 0` it fires
--- immediately on the same frame).
---
--- Lazy-requires `ClientAudioPreferences` (mirrors `tryEnqueueVoice`) so a
--- load-order surprise can't break the cinematic, and skips audio entirely
--- when the player has SFX muted. Parented to `SoundService` for non-positional
--- 2D playback (everyone within audible range hears it equally).
local function playSfxByIdRepeated(soundId: string, count: number, volume: number?, onComplete: (() -> ())?)
	local sfxOk = true
	pcall(function()
		local prefs = require(script.Parent:WaitForChild("ClientAudioPreferences", 5)) :: any
		if prefs and typeof(prefs.isSfxEnabled) == "function" then
			sfxOk = prefs.isSfxEnabled() == true
		end
	end)
	local plays = math.max(0, math.floor(count))
	if not sfxOk or plays == 0 then
		--- Fire `onComplete` immediately when there's nothing to play so chained
		--- logic (the voice line, here) still runs. `task.spawn` keeps the call
		--- async-equivalent to the audio path.
		if onComplete then task.spawn(onComplete) end
		return
	end
	task.spawn(function()
		for _ = 1, plays do
			local snd = Instance.new("Sound")
			snd.Name = "EventSfxBurst"
			snd.SoundId = soundId
			snd.Volume = volume or 0.7
			snd.Looped = false
			snd.Parent = SoundService
			snd:Play()
			--- `.Ended:Wait()` is bounded internally by Roblox's stream timeout, so a
			--- never-loaded asset can't hang the loop forever. Hard-cap with a 6s
			--- delay-destroy on each instance as a safety net.
			task.delay(6, function()
				if snd.Parent then snd:Destroy() end
			end)
			snd.Ended:Wait()
			if snd.Parent then snd:Destroy() end
		end
		if onComplete then onComplete() end
	end)
end

--- Local cosmetic NPCs (Pirate / Coast Guard): must not shove the player. `Humanoid`
--- on a freshly-parented model can re-enable `CanCollide` on body parts before our
--- next ghost sweep, so we cannot rely on `CanCollide=false` alone — anchored
--- collision still ejects unanchored characters from a part's volume per physics
--- step, observed as a continuous "pull" toward officers parked nearby (HRP velocity
--- spiked to ~20 studs/s every 0.5s sample even with per-Heartbeat sweeps).
---
--- The actual no-collide enforcement comes from the `StraitWaypointFxNpc` collision
--- group + no-collide rules, REGISTERED ON THE SERVER in
--- `OilShipmentService:Init`. Server-side `RegisterCollisionGroup` /
--- `CollisionGroupSetCollidable` writes are the only ones that take effect — the
--- engine then replicates the group + collidable matrix to every client. Tagging
--- a part with `CollisionGroup = STRAIT_FX_NPC_GROUP` from the client (in
--- `applyStraitNpcGhostParts` below) makes the engine refuse the collision
--- regardless of `CanCollide` flips.
---
--- The `ensureStraitFxNpcCollisionGroup` call below is kept as a no-op safety net:
--- on the client `RegisterCollisionGroup` silently fails (server-only), but the
--- group has already been registered server-side at OilShipmentService init.
local STRAIT_FX_NPC_GROUP = "StraitWaypointFxNpc"
local straitFxNpcGroupReady = false

local function ensureStraitFxNpcCollisionGroup()
	if straitFxNpcGroupReady then
		return
	end
	-- These are SERVER-ONLY in modern Roblox; pcalls swallow the client-side
	-- failure. The authoritative registration happens in
	-- `OilShipmentService:Init` (replicates to clients automatically).
	pcall(function()
		PhysicsService:RegisterCollisionGroup(STRAIT_FX_NPC_GROUP)
	end)
	local function noCollidePair(a: string, b: string)
		pcall(function()
			PhysicsService:CollisionGroupSetCollidable(a, b, false)
		end)
	end
	noCollidePair(STRAIT_FX_NPC_GROUP, "Default")
	noCollidePair(STRAIT_FX_NPC_GROUP, "Players")
	noCollidePair(STRAIT_FX_NPC_GROUP, "ShipmentShip")
	noCollidePair(STRAIT_FX_NPC_GROUP, "MarinaDock")
	noCollidePair(STRAIT_FX_NPC_GROUP, STRAIT_FX_NPC_GROUP)
	straitFxNpcGroupReady = true
end

-- Bounded waits: avoid infinite yield if ReplicatedStorage is slow or Shared is missing in a test place.
local ParticleFxScale: {
	ApplyToEmitter: (ParticleEmitter, number) -> (),
	ApplyToDescendants: (Instance, number) -> (),
} = {
	ApplyToEmitter = function() end,
	ApplyToDescendants = function() end,
}
type ShipRigDef = {
	dockAnchorName: string,
	frontMarkerName: string,
	deckAnchorName: string,
	deckYOffsetFallback: number,
	deckSeatName: string,
	barrelStackRootName: string,
	playerFlagName: string,
}

local DEFAULT_SHIP_RIG: ShipRigDef = {
	dockAnchorName = "DockAnchor",
	frontMarkerName = "FRONT_MARKER",
	deckAnchorName = "DeckAnchor",
	deckYOffsetFallback = 15,
	deckSeatName = "DeckSeat",
	barrelStackRootName = "BarrelStackRoot",
	playerFlagName = "PlayerFlag",
}

local ShipSkinCatalog: any = nil
local ShipRigUtil: any = nil
local OilConfig: any = nil
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
	local oilConfigMod = configFolder and configFolder:FindFirstChild("OilConfig")
	if oilConfigMod and oilConfigMod:IsA("ModuleScript") then
		local okOilConfig, loadedOilConfig = pcall(require, oilConfigMod)
		if okOilConfig and typeof(loadedOilConfig) == "table" then
			OilConfig = loadedOilConfig
		end
	end
	local skinCatalogMod = configFolder and configFolder:FindFirstChild("ShipSkinCatalog")
	if skinCatalogMod and skinCatalogMod:IsA("ModuleScript") then
		local okSkinCatalog, loadedSkinCatalog = pcall(require, skinCatalogMod)
		if okSkinCatalog and typeof(loadedSkinCatalog) == "table" then
			ShipSkinCatalog = loadedSkinCatalog
		end
	end
	local straitEventsFolder = configFolder and configFolder:FindFirstChild("StraitEvents")
	local manifestMod = straitEventsFolder and straitEventsFolder:FindFirstChild("AssetManifest")
	if manifestMod and manifestMod:IsA("ModuleScript") then
		local okManifest, loadedManifest = pcall(require, manifestMod)
		if okManifest and typeof(loadedManifest) == "table" then
			StraitAssetManifest = loadedManifest
		end
	end
	local utilsFolder = sharedFolder:FindFirstChild("Utils")
	local shipRigMod = utilsFolder and utilsFolder:FindFirstChild("ShipRig")
	if shipRigMod and shipRigMod:IsA("ModuleScript") then
		local okShipRig, loadedShipRig = pcall(require, shipRigMod)
		if okShipRig and typeof(loadedShipRig) == "table" then
			ShipRigUtil = loadedShipRig
		end
	end
end

-- ReplicatedStorage.Assets.StraitWaypointsFx.<CatalogEventId>/ — Models or Parts as direct children; Sounds play when cloned.
local STRAIT_FX_ASSETS_FOLDER = "StraitWaypointsFx"

-- Missile barrage: one-shot when a cloned missile impacts the ship (hit / smallHit, not clean miss).
local MISSILE_IMPACT_HIT_SFX_ID = "rbxassetid://111630360891423"
local MISSILE_IMPACT_HIT_VOLUME = 0.55

-- Mine field: one-shot when `didHit` — the surfacing mine detonates on the ship.
local MINE_IMPACT_HIT_SFX_ID = "rbxassetid://102050572129572"
local MINE_IMPACT_HIT_VOLUME = 0.35 -- was 0.2; hit-only SFX — keep audible vs ambient

local function getStraitFxRoot(): Instance?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	return assets and assets:FindFirstChild(STRAIT_FX_ASSETS_FOLDER)
end

local function getExpectedEventAssetNames(eventId: string): { string }?
	if typeof(StraitAssetManifest) ~= "table" or typeof((StraitAssetManifest :: any).Events) ~= "table" then
		return nil
	end
	local events = (StraitAssetManifest :: any).Events
	local spec = events[eventId]
	if typeof(spec) ~= "table" or typeof(spec.expectedInstances) ~= "table" then
		return nil
	end
	return spec.expectedInstances
end

local function scoreEventFxFolder(folder: Instance, expected: { string }?): number
	if not expected or #expected == 0 then
		return #folder:GetDescendants()
	end

	local score = 0
	for _, expectedName in ipairs(expected) do
		if typeof(expectedName) == "string" and expectedName ~= "" and folder:FindFirstChild(expectedName, true) then
			score += 1
		end
	end
	return score
end

local function getEventFxFolder(eventId: string): Instance?
	local root = getStraitFxRoot()
	if not root then
		return nil
	end

	local expected = getExpectedEventAssetNames(eventId)
	local bestFolder: Instance? = nil
	local bestScore = -1
	for _, child in ipairs(root:GetChildren()) do
		if child.Name == eventId then
			local score = scoreEventFxFolder(child, expected)
			if score > bestScore then
				bestFolder = child
				bestScore = score
			end
		end
	end

	return bestFolder
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
		local folder = getEventFxFolder(folderName)
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

--- One-time strip of legacy BodyMovers and active force/velocity constraints.
--- NPC ship templates (e.g. `PirateShipNpc`) carry leftover `BodyVelocity`/`BodyGyro`/
--- `BodyPosition` from their original self-driving NPC AI rig — useless for cosmetic
--- playback and a latent risk if a part ever loses its `Anchored` flag. Movement-causing
--- `Constraint` subclasses are stripped too; structural welds (`WeldConstraint`,
--- `Weld`, `Motor6D`) and joints like `RopeConstraint` / `RodConstraint` are kept so
--- ship hulls and rigs stay assembled.
local function stripPhysicsActuators(root: Instance)
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BodyMover") then
			d:Destroy()
		elseif d:IsA("LinearVelocity")
			or d:IsA("AngularVelocity")
			or d:IsA("VectorForce")
			or d:IsA("Torque")
			or d:IsA("LineForce")
			or d:IsA("AlignPosition")
			or d:IsA("AlignOrientation") then
			d:Destroy()
		end
	end
end

--- Remove Humanoid (it reapplies CanCollide), ghost all parts, no collision with player or ship.
--- `Seat` / `VehicleSeat` get `Disabled = true` because the engine has been observed to
--- auto-sit a passing player Humanoid into a `Seat` even with `CanTouch = false`
--- (e.g. `PirateShipNpc` has a `VehicleSeat` "Drive" and 2 `Seat`s — without this the
--- player gets welded to the cosmetic ship as it sweeps past and dragged with it).
local function applyStraitNpcGhostParts(root: Instance)
	ensureStraitFxNpcCollisionGroup()
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("Humanoid") then
			d:Destroy()
		end
	end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Massless = true
			if d:IsA("Seat") or d:IsA("VehicleSeat") then
				(d :: Seat).Disabled = true
			end
			pcall(function()
				d.CollisionGroup = STRAIT_FX_NPC_GROUP
			end)
		end
	end
end

--- Re-apply ghost for several seconds — templates / engine may re-enable collision after Parent changes.
--- Sweep cadence kept tight (every Heartbeat ≈16ms): cosmetic NPC ships sweep
--- in laterally at ~80 studs/s during the approach phase (`animateMove`), so
--- a stale ghost window even of ~120ms can let an anchored-but-CanCollide-true
--- part traverse ~10 studs through a player standing on the deck and push
--- them sideways via collision resolution. Diagnostic data captured 2026-04-18
--- (CoastGuard cinematic): player HRP velocity spiked to 18–25 studs/s exactly
--- when the CG ship was mid-approach and again when officers ziplined onto the
--- deck — both are moments when re-parented or animation-driven parts can
--- briefly miss a wider-cadence sweep. Per-frame is safe (the sweep is just
--- property writes on already-property-clean parts) and removes the race.
local function sustainStraitNpcGhosts(roots: { Instance }, durationSec: number)
	if #roots == 0 then
		return
	end
	local t0 = os.clock()
	local conn: RBXScriptConnection?
	conn = RunService.Heartbeat:Connect(function()
		if os.clock() - t0 >= durationSec then
			if conn then
				conn:Disconnect()
			end
			return
		end
		for _, r in ipairs(roots) do
			if r.Parent ~= nil then
				applyStraitNpcGhostParts(r)
			end
		end
	end)
end

--- Defensive velocity guard for the local player's character during a strait
--- event cinematic where the player ship is server-anchored.
---
--- Even with `applyStraitNpcGhostParts` and `sustainStraitNpcGhosts` running,
--- runtime captured pushes of 18–25 studs/s on the local HRP at moments
--- corresponding to (a) the cosmetic CG / pirate ship's lateral approach
--- sweep (`animateMove` PivotTo at ~80 studs/s) and (b) officers / pirates
--- landing on the deck via the zipline animation. The exact source is some
--- collision-enabled part on the cosmetic rig that briefly slips the ghost
--- pass (re-parented or added by the animateMove rig motion). Rather than
--- chase every possible offender, we treat the symptom on the client.
---
--- While the cinematic is on screen, the player's *expected* XZ velocity is
--- their own walking velocity (`Humanoid.MoveDirection * WalkSpeed`), since
--- the deck is anchored (platform velocity = 0). Any XZ velocity that
--- significantly exceeds that is an external push. We snap it back to the
--- walking expectation while preserving Y (gravity / jump unaffected). The
--- player keeps full walking control.
---
--- Server-side write of `AssemblyLinearVelocity` would not work here:
--- character physics is client-owned, so the write would not replicate.
local PUSH_TOLERANCE_STUDS_PER_SEC = 6
local function dampLocalPlayerCharacterDuringEvent(durationSec: number)
	if durationSec <= 0 then
		return
	end
	local t0 = os.clock()
	local conn: RBXScriptConnection?
	conn = RunService.Heartbeat:Connect(function()
		if os.clock() - t0 >= durationSec then
			if conn then
				conn:Disconnect()
			end
			return
		end
		local lp = Players.LocalPlayer
		local char = lp and lp.Character
		if not char then
			return
		end
		local hum = char:FindFirstChildOfClass("Humanoid")
		local hrp = char:FindFirstChild("HumanoidRootPart")
		if not (hum and hrp and hrp:IsA("BasePart")) then
			return
		end
		-- Skip while seated (a real seat weld owns the velocity entirely).
		if hum.SeatPart then
			return
		end
		local v = hrp.AssemblyLinearVelocity
		local moveDir = hum.MoveDirection
		local walkSpeed = hum.WalkSpeed
		local expectedXZ = Vector3.new(moveDir.X * walkSpeed, 0, moveDir.Z * walkSpeed)
		local actualXZ = Vector3.new(v.X, 0, v.Z)
		if (actualXZ - expectedXZ).Magnitude > PUSH_TOLERANCE_STUDS_PER_SEC then
			hrp.AssemblyLinearVelocity = Vector3.new(expectedXZ.X, v.Y, expectedXZ.Z)
		end
	end)
end

local function prepareStraitEventNpcInstance(root: Instance)
	stripRuntimeScripts(root)
	stripPhysicsActuators(root)
	applyStraitNpcGhostParts(root)
end

local function prepareStraitFxClone(root: Instance)
	stripPhysicsActuators(root)
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			if d:IsA("Seat") or d:IsA("VehicleSeat") then
				(d :: Seat).Disabled = true
			end
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
			d.Playing = false
			d:Stop()
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

local createFallbackBarrelVisual: (startPos: Vector3) -> BasePart
local collectDeckBarrelInstances: (boat: Model) -> { Instance }

local function cframeFromSerialized(raw: any): CFrame?
	if typeof(raw) ~= "table" then
		return nil
	end
	local values = table.create(12)
	for i = 1, 12 do
		local n = raw[i]
		if typeof(n) ~= "number" or n ~= n then
			return nil
		end
		values[i] = n
	end
	return CFrame.new(table.unpack(values))
end

local function getBarrelSnapshotPosition(snapshot: any): Vector3?
	if typeof(snapshot) ~= "table" then
		return nil
	end
	local pos = vector3FromWorldPosition(snapshot.position)
	if pos then
		return pos
	end
	local cf = cframeFromSerialized(snapshot.cframe)
	return if cf then cf.Position else nil
end

local function getBarrelSnapshotCFrame(snapshot: any): CFrame?
	if typeof(snapshot) ~= "table" then
		return nil
	end
	local cf = cframeFromSerialized(snapshot.cframe)
	if cf then
		return cf
	end
	local pos = vector3FromWorldPosition(snapshot.position)
	return if pos then CFrame.new(pos) else nil
end

local animateMove: (any, CFrame, CFrame, number, number?) -> ()

local function getBarrelTemplateNameForTier(tier: string?): string?
	if typeof(tier) ~= "string" or typeof(OilConfig) ~= "table" then
		return nil
	end
	local barrels = (OilConfig :: any).Barrels
	local tierTemplates = barrels and barrels.TierTemplates
	local templateName = tierTemplates and tierTemplates[tier]
	return if typeof(templateName) == "string" then templateName else nil
end

local function createBarrelVisualFromSnapshot(snapshot: any, fallbackPos: Vector3): Instance
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local templateName = if typeof(snapshot) == "table" and typeof(snapshot.templateName) == "string"
		then snapshot.templateName
		else getBarrelTemplateNameForTier(if typeof(snapshot) == "table" then snapshot.tier else nil)
	local template = if assets and templateName then assets:FindFirstChild(templateName) else nil

	local visual: Instance
	if template and (template:IsA("Model") or template:IsA("BasePart")) then
		visual = template:Clone()
	else
		visual = createFallbackBarrelVisual(fallbackPos)
	end

	prepareKinematicFx(visual)
	local cf = getBarrelSnapshotCFrame(snapshot) or CFrame.new(fallbackPos)
	setInstanceWorldCFrame(visual, cf)
	return visual
end

local function buildBarrelAnimationSources(
	boat: Model?,
	rawSnapshots: any
): { [number]: { instance: Instance?, snapshot: any? } }
	local out = {}
	if boat then
		for _, source in ipairs(collectDeckBarrelInstances(boat)) do
			table.insert(out, { instance = source })
		end
	end
	if #out > 0 then
		return out
	end
	if typeof(rawSnapshots) == "table" then
		for _, snapshot in ipairs(rawSnapshots) do
			if typeof(snapshot) == "table" and getBarrelSnapshotPosition(snapshot) then
				table.insert(out, { snapshot = snapshot })
			end
		end
	end
	return out
end

local ROUTINE_PAPERWORK_ID = "RoutinePaperwork"
local ROUTINE_PAPERWORK_DECK_OFFSET = CFrame.new(0, 8, 0)
-- After template + ParticleFxScale: bias toss upward, then let gravity/drag pull sheets down.
--- Tuned to launch the burst noticeably higher than the previous pass: speed
--- mul more than doubled and gravity damped further so a single emit reaches
--- well above the deck before falling. Spread stays tight so the silhouette
--- reads as a column shooting up rather than a ground spray.
local ROUTINE_PAPERWORK_SPEED_MUL = 2.6
local ROUTINE_PAPERWORK_GRAVITY_MUL = 0.5 -- less negative Y acceleration = longer hang before fall
local ROUTINE_PAPERWORK_SPREAD_MUL = 0.55 -- tighter cone around EmissionDirection (more "up" than sideways)

--- Same dock layout as `BoatDockService` / `ShipmentProgressHud`: **`dOCKS.Boats`** holds `ActiveShipmentBoat`.
local function getDocksRootForActiveShipmentBoat(): Instance?
	return Workspace:FindFirstChild("dOCKS")
		or Workspace:FindFirstChild("Docks")
		or Workspace:FindFirstChild("DOCKS")
		or Workspace:FindFirstChild("dOCKS", true)
end

local function findActiveShipmentBoatByShipmentId(shipmentId: string): Model?
	if shipmentId == "" then
		return nil
	end
	local docks = getDocksRootForActiveShipmentBoat()
	local boatsFolder = docks and docks:FindFirstChild("Boats")
	if not (boatsFolder and boatsFolder:IsA("Folder")) then
		return nil
	end
	for _, inst in ipairs(boatsFolder:GetChildren()) do
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

local function getBoatRigDef(boat: Model): ShipRigDef
	if ShipSkinCatalog then
		local templateName = boat:GetAttribute("ShipTemplateName")
		if typeof(templateName) == "string" and templateName ~= "" and typeof(ShipSkinCatalog.GetRigForTemplate) == "function" then
			local okTemplateRig, rigTemplate = pcall(ShipSkinCatalog.GetRigForTemplate, templateName)
			if okTemplateRig and typeof(rigTemplate) == "table" then
				return rigTemplate :: ShipRigDef
			end
		end
		local skinId = boat:GetAttribute("ShipSkinId")
		if typeof(skinId) == "string" and skinId ~= "" and typeof(ShipSkinCatalog.GetRigForSkin) == "function" then
			local okSkinRig, rigSkin = pcall(ShipSkinCatalog.GetRigForSkin, skinId)
			if okSkinRig and typeof(rigSkin) == "table" then
				return rigSkin :: ShipRigDef
			end
		end
	end
	return DEFAULT_SHIP_RIG
end

local function findRigAttachment(boat: Model, name: string): Attachment?
	if ShipRigUtil and typeof(ShipRigUtil.FindAttachment) == "function" then
		local okFind, found = pcall(ShipRigUtil.FindAttachment, boat, name)
		if okFind and found and found:IsA("Attachment") then
			return found
		end
	end
	local fallback = boat:FindFirstChild(name, true)
	if fallback and fallback:IsA("Attachment") then
		return fallback
	end
	return nil
end

local function findRigBasePart(boat: Model, name: string): BasePart?
	if ShipRigUtil and typeof(ShipRigUtil.FindBasePart) == "function" then
		local okFind, found = pcall(ShipRigUtil.FindBasePart, boat, name)
		if okFind and found and found:IsA("BasePart") then
			return found
		end
	end
	local fallback = boat:FindFirstChild(name, true)
	if fallback and fallback:IsA("BasePart") then
		return fallback
	end
	return nil
end

local function getBoatForwardMarker(boat: Model): BasePart?
	local rig = getBoatRigDef(boat)
	return findRigBasePart(boat, rig.frontMarkerName) or findRigBasePart(boat, "FRONT_MARKER")
end

local function getBoatDeckY(boat: Model, waterlineY: number): number
	local rig = getBoatRigDef(boat)
	-- DeckTopAnchor: dedicated, hand-authored Attachment on each ship template
	-- placed exactly at the walkable deck surface. Single source of truth for
	-- "where do NPC feet go on this boat."
	local deckTop = findRigAttachment(boat, rig.deckTopAnchorName)
	if deckTop then
		return deckTop.WorldPosition.Y
	end
	local barrel = boat:FindFirstChild(rig.barrelStackRootName, true)
	if barrel and barrel:IsA("BasePart") then
		return barrel.Position.Y + barrel.Size.Y / 2
	end
	local seat = boat:FindFirstChild(rig.deckSeatName, true)
	if seat and seat:IsA("BasePart") then
		return seat.Position.Y + seat.Size.Y / 2
	end
	if ShipRigUtil and typeof(ShipRigUtil.ResolveDeckWorldY) == "function" then
		local okResolve, y = pcall(ShipRigUtil.ResolveDeckWorldY, boat, rig, waterlineY)
		if okResolve and typeof(y) == "number" then
			return y
		end
	end
	local deckAnchor = findRigAttachment(boat, rig.deckAnchorName)
	if deckAnchor then
		return deckAnchor.WorldPosition.Y
	end
	return waterlineY + rig.deckYOffsetFallback
end

-- Raycasts straight down at (x, z) looking ONLY near the authored deck Y (from
-- DeckTopAnchor / BarrelStackRoot). Sails and masts are well above the deck so
-- they're excluded by starting the cast just above deck Y with a short range.
local function raycastBoatDeckY(boat: Model, x: number, z: number): number?
	local rig = getBoatRigDef(boat)
	-- Use BarrelStackRoot/DeckSeat as the canonical deck Y reference.
	local approxDeckY: number? = nil
	local bs = boat:FindFirstChild(rig.barrelStackRootName, true)
	if bs and bs:IsA("BasePart") then
		approxDeckY = bs.Position.Y + bs.Size.Y / 2
	else
		local seat = boat:FindFirstChild(rig.deckSeatName, true)
		if seat and seat:IsA("BasePart") then
			approxDeckY = seat.Position.Y + seat.Size.Y / 2
		end
	end
	if not approxDeckY then
		local bbCF, _ = boat:GetBoundingBox()
		approxDeckY = bbCF.Position.Y
	end
	-- Cast from 4 studs above expected deck, 8 studs downward. Sails/masts are
	-- tens of studs above this window so they're impossible to hit.
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { boat }
	params.IgnoreWater = true
	local origin = Vector3.new(x, approxDeckY + 4, z)
	local remaining = 8
	for _ = 1, 4 do
		if remaining <= 0 then break end
		local result = Workspace:Raycast(origin, Vector3.new(0, -remaining, 0), params)
		if not result then return nil end
		if result.Normal.Y > 0.7 then return result.Position.Y end
		local stepped = (origin.Y - result.Position.Y) + 0.1
		remaining = remaining - stepped
		origin = Vector3.new(x, result.Position.Y - 0.1, z)
	end
	return nil
end

-- Takes a desired NPC stand position (where feet should land) and returns the
-- NPC PIVOT position (feet + pivot-to-feet offset). Falls back to nil if
-- targetXZ is off the boat — caller should skip or clamp.
local function npcPivotOnDeck(boat: Model, targetXZ: Vector3, npcPivotToFeet: number): Vector3?
	local y = raycastBoatDeckY(boat, targetXZ.X, targetXZ.Z)
	if not y then return nil end
	return Vector3.new(targetXZ.X, y + npcPivotToFeet, targetXZ.Z)
end

local function getInstanceWorldCFrame(inst: Instance): CFrame?
	if inst:IsA("Model") then
		if inst.PrimaryPart then
			return inst.PrimaryPart.CFrame
		end
		for _, d in ipairs(inst:GetDescendants()) do
			if d:IsA("BasePart") then
				return d.CFrame
			end
		end
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
	stripPhysicsActuators(root)
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Massless = true
			if d:IsA("Seat") or d:IsA("VehicleSeat") then
				(d :: Seat).Disabled = true
			end
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
	s.Playing = false
	s:Stop()
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

function collectDeckBarrelInstances(boat: Model): { Instance }
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

function createFallbackBarrelVisual(startPos: Vector3): BasePart
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
	maxVisualBarrels: number,
	rawSnapshots: any?
)
	local rng = Random.new()
	local barrelSources = buildBarrelAnimationSources(boat, rawSnapshots)
	local toThrow = math.min(barrelsLost, #barrelSources, maxVisualBarrels)
	for i = 1, toThrow do
		local sourceData = barrelSources[i]
		local sourceInst = sourceData.instance
		local snapshot = sourceData.snapshot
		local sourcePos = if sourceInst and sourceInst.Parent
			then getInstanceWorldPosition(sourceInst)
			else getBarrelSnapshotPosition(snapshot)
		if not sourcePos then
			continue
		end
		local sourceStart = sourcePos

		task.spawn(function()
			task.wait((i - 1) * 0.07)

			local visual: Instance
			if sourceInst and sourceInst.Parent and (sourceInst:IsA("Model") or sourceInst:IsA("BasePart")) then
				visual = sourceInst:Clone()
				prepareKinematicFx(visual)
				setInstanceWorldCFrame(visual, getBarrelSnapshotCFrame(snapshot) or CFrame.new(sourceStart))
			else
				visual = createBarrelVisualFromSnapshot(snapshot, sourceStart)
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
	emitter.EmissionDirection = Enum.NormalId.Top
	local spd = emitter.Speed
	emitter.Speed = NumberRange.new(spd.Min * ROUTINE_PAPERWORK_SPEED_MUL, spd.Max * ROUTINE_PAPERWORK_SPEED_MUL)
	local acc = emitter.Acceleration
	if acc.Y < 0 then
		emitter.Acceleration = Vector3.new(acc.X, acc.Y * ROUTINE_PAPERWORK_GRAVITY_MUL, acc.Z)
	end
	local spread = emitter.SpreadAngle
	emitter.SpreadAngle = Vector2.new(
		math.clamp(spread.X * ROUTINE_PAPERWORK_SPREAD_MUL, 18, 88),
		math.clamp(spread.Y * ROUTINE_PAPERWORK_SPREAD_MUL, 18, 88)
	)

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

--- Explode a boat into its pieces. Clones every visible BasePart from the boat,
--- unanchors them, flings them outward with random velocity, then destroys the
--- original boat. Works with any ship model (Tanker, different skins, etc.).
--- Call from any event handler after the boat is "destroyed" server-side.
function StraitWaypointWorldFx.ExplodeBoatIntoPieces(boat: Instance, epicenter: Vector3?)
	if not boat or not boat.Parent then return end
	local center = epicenter or (boat:IsA("Model") and boat:GetPivot().Position) or Vector3.new(0, 10, 0)
	local rng = Random.new()
	local pieces = {}

	for _, d in ipairs(boat:GetDescendants()) do
		if d:IsA("BasePart") and d.Transparency < 0.9 and d.Size.Magnitude > 0.5 then
			-- Clone the visible part as debris
			local piece = Instance.new("Part")
			piece.Name = "BoatDebris"
			piece.Size = Vector3.new(
				math.min(d.Size.X, 8),
				math.min(d.Size.Y, 8),
				math.min(d.Size.Z, 8)
			)
			piece.Material = d.Material
			piece.Color = d.Color
			piece.CFrame = d.CFrame * CFrame.Angles(rng:NextNumber(-0.5, 0.5), rng:NextNumber(-0.5, 0.5), rng:NextNumber(-0.5, 0.5))
			piece.Anchored = false
			piece.CanCollide = false
			piece.CanQuery = false
			piece.CanTouch = false
			piece.Parent = Workspace

			-- Fling outward + upward from epicenter
			local awayDir = (d.Position - center)
			awayDir = Vector3.new(awayDir.X, 0, awayDir.Z)
			if awayDir.Magnitude < 1 then
				awayDir = Vector3.new(rng:NextNumber(-1, 1), 0, rng:NextNumber(-1, 1))
			end
			awayDir = awayDir.Unit

			local bv = Instance.new("BodyVelocity")
			bv.Velocity = awayDir * rng:NextNumber(30, 80) + Vector3.new(0, rng:NextNumber(20, 60), 0)
			bv.MaxForce = Vector3.new(1e5, 1e5, 1e5)
			bv.P = 1000
			bv.Parent = piece
			Debris:AddItem(bv, 0.4)
			Debris:AddItem(piece, 6)

			table.insert(pieces, piece)
			-- Cap at 25 pieces for performance
			if #pieces >= 25 then break end
		end
	end

	-- Destroy the original boat model
	boat:Destroy()
	return pieces
end

function StraitWaypointWorldFx.OnStraitWaypointPayload(data: { [string]: any })
	local pos = vector3FromWorldPosition(data.worldPosition)
	if not pos then
		return
	end

	local pause = tonumber(data.pauseSeconds)
	local hold = if typeof(pause) == "number" and pause == pause then pause else 5

	local id = if typeof(data.eventId) == "string" then data.eventId else ""
	-- Dedicated packets (StormEvent / TornadoEvent) own these visuals + audio; never clone-play RS templates here.
	if id == "Storm" or id == "Tornado" then
		return
	end

	--- Voice cue for the generic strait waypoint events that don't get their
	--- own bespoke payload (e.g. `RoutinePaperwork`). The big cinematic
	--- events (`MissileStrike`, `MineStrike`, `PirateRaid`, etc.) come in on
	--- their dedicated `On<Event>Payload` handlers below and enqueue their
	--- own voice clip there. `Storm` / `Tornado` early-returned above for
	--- the same reason — their `OnStormPayload` / `OnTornadoPayload` owns
	--- the voice cue.
	if id == "RoutinePaperwork" then
		tryEnqueueOwnerVoice(data, "Paperwork")
	elseif id == "EngineRoomSmoke" then
		tryEnqueueOwnerVoice(data, "EngineRoomSmoke")
	end
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

	--- One voice cue per missile barrage, not per missile. Server fires
	--- `MissileStrikeEvent` once per missile (4× per barrage by default —
	--- see `Catalog.MissileConfig.MissileCount`); `missileIndex == 1` marks
	--- the first one, so we only enqueue the "missile incoming" voice
	--- there. The queue's per-key dedup would catch a duplicate too, but
	--- gating on the index is cheaper than letting all 4 collide and rely
	--- on dedup to swallow them.
	local missileIndex = tonumber(data.missileIndex) or 1
	if missileIndex == 1 then
		tryEnqueueOwnerVoice(data, "Missiles")
	end

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

		-- The `Missile` asset's nose points along its local +X, not the LookVector
		-- axis produced by `CFrame.lookAt`, so apply a yaw -90° correction so
		-- the nose points along the flight direction instead of sideways.
		local MISSILE_ORIENT_FIX = CFrame.Angles(0, math.rad(-90), 0)

		-- Position at launch
		local startCF = CFrame.lookAt(launchPos, targetPos) * MISSILE_ORIENT_FIX
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
			local cf = CFrame.lookAt(pos, lookTarget) * MISSILE_ORIENT_FIX

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

			-- Impact SFX: once per cloned missile that lands a hit (direct or partial); not on splash misses.
			-- Parent to a short-lived world anchor so playback isn't cut when the explosion part cleans up.
			local sfxAnchor = Instance.new("Part")
			sfxAnchor.Name = "MissileImpactHitSfx"
			sfxAnchor.Size = Vector3.new(0.15, 0.15, 0.15)
			sfxAnchor.Transparency = 1
			sfxAnchor.Anchored = true
			sfxAnchor.CanCollide = false
			sfxAnchor.CanQuery = false
			sfxAnchor.Position = targetPos
			sfxAnchor.Parent = Workspace
			local impactHitSfx = Instance.new("Sound")
			impactHitSfx.SoundId = MISSILE_IMPACT_HIT_SFX_ID
			impactHitSfx.Volume = MISSILE_IMPACT_HIT_VOLUME
			impactHitSfx.RollOffMode = Enum.RollOffMode.InverseTapered
			impactHitSfx.RollOffMaxDistance = 2000
			impactHitSfx.Parent = sfxAnchor
			task.defer(function()
				if not impactHitSfx.Parent then
					return
				end
				if not impactHitSfx.IsLoaded then
					pcall(function()
						impactHitSfx.Loaded:Wait()
					end)
				end
				if impactHitSfx.Parent then
					impactHitSfx:Play()
				end
			end)
			Debris:AddItem(sfxAnchor, 30)

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

			-- Direct hit: explode the boat into pieces
			if isDirectHit then
				local boat = findActiveShipmentBoatByShipmentId(shipmentId)
				if boat then
					task.delay(0.3, function()
						StraitWaypointWorldFx.ExplodeBoatIntoPieces(boat, targetPos)
					end)
				end
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
	tryEnqueueOwnerVoice(data, "Storm")

	local shipmentId = if typeof(data.shipmentId) == "string" then data.shipmentId else ""
	local boat = if shipmentId ~= "" then findActiveShipmentBoatByShipmentId(shipmentId) else nil
	local hull = if boat then getBoatAttachmentPart(boat) else nil
	local stormDebug = RunService:IsStudio()

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

		local stormCenterPos = if hull then hull.Position else centerPos
		local function getLiveStormCenter(): Vector3
			if boat and boat.Parent then
				local liveHull = getBoatAttachmentPart(boat)
				if liveHull then
					hull = liveHull
					stormCenterPos = liveHull.Position
					return stormCenterPos
				end
			end
			return stormCenterPos
		end

		stormCenterPos = getLiveStormCenter()
		local cloudRig = cloneStormCloudTemplate()
		local canopyRadius = 80
		if cloudRig then
			prepareKinematicFx(cloudRig)
			scaleTornadoRoot(cloudRig, 0.5)
			cloudRig.Parent = container
			moveRootToWorldPosition(cloudRig, stormCenterPos + Vector3.new(0, STORM_CLOUD_HEIGHT_OFFSET, 0))
			canopyRadius = math.max(36, getInstanceHorizontalRadius(cloudRig) * 0.9)
		else
			buildFallbackCloudLayer(container, stormCenterPos)
			canopyRadius = 45
		end

		local rainDropsPart, rainSplashesPart = buildStormRainLayers(container, stormCenterPos, canopyRadius, fxScale)
		local rainHost = rainDropsPart
		setParticleEmittersOnlyEnabled(container, true)
		playSoundTemplateOn(rainHost, "Storm", "RainLoopSfx", 0.95)
		task.spawn(function()
			local followStart = os.clock()
			while container.Parent and (os.clock() - followStart) < sequenceSeconds do
				local liveCenter = getLiveStormCenter()
				if cloudRig and cloudRig.Parent then
					moveRootToWorldPosition(cloudRig, liveCenter + Vector3.new(0, STORM_CLOUD_HEIGHT_OFFSET, 0))
				end
				if rainDropsPart.Parent then
					rainDropsPart.CFrame = CFrame.new(liveCenter + Vector3.new(0, STORM_RAIN_HEIGHT_OFFSET, 0))
				end
				if rainSplashesPart.Parent then
					rainSplashesPart.CFrame = CFrame.new(liveCenter + Vector3.new(0, 2, 0))
				end
				task.wait(0.1)
			end
		end)

		local barrelSources = {}
		local barrelSideDir = Vector3.new(1, 0, 0)
		if didBarrelLoss then
			local availableSources = buildBarrelAnimationSources(boat, data.lostDeckBarrels)
			local toWash = math.min(barrelsLost, #availableSources, 8)
			if stormDebug then
				print(string.format(
					"[StormDebug][Client] shipment=%s barrelsLost=%d snapshotCount=%d availableSources=%d toWash=%d",
					shipmentId,
					barrelsLost,
					if typeof(data.lostDeckBarrels) == "table" then #data.lostDeckBarrels else 0,
					#availableSources,
					toWash
				))
			end
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
					table.insert(barrelSources, availableSources[i])
				end
			end
		end

		local function runBarrelWashVisual(sourceData)
			local sourceInst = sourceData.instance
			local snapshot = sourceData.snapshot
			local startPos = if sourceInst and sourceInst.Parent
				then getInstanceWorldPosition(sourceInst)
				else getBarrelSnapshotPosition(snapshot)
			if not startPos then
				return
			end
			local visual: Instance
			if sourceInst and sourceInst.Parent and (sourceInst:IsA("Model") or sourceInst:IsA("BasePart")) then
				visual = sourceInst:Clone()
				prepareKinematicFx(visual)
				setInstanceWorldCFrame(visual, getBarrelSnapshotCFrame(snapshot) or CFrame.new(startPos))
			else
				visual = createBarrelVisualFromSnapshot(snapshot, startPos)
			end
			visual.Parent = container
			local launchPos = startPos + Vector3.new(0, rng:NextNumber(6, 10), 0)
			local edgePos = launchPos + barrelSideDir * rng:NextNumber(24, 38) + Vector3.new(rng:NextNumber(-6, 6), rng:NextNumber(2, 5), rng:NextNumber(-6, 6))
			local splashPos = edgePos + barrelSideDir * rng:NextNumber(36, 60) + Vector3.new(rng:NextNumber(-10, 10), -12, rng:NextNumber(-10, 10))
			animateMove(
				visual,
				getInstanceWorldCFrame(visual) or CFrame.new(startPos),
				CFrame.new(edgePos) * CFrame.Angles(rng:NextNumber(3, 6), rng:NextNumber(4, 7), rng:NextNumber(3, 6)),
				rng:NextNumber(0.28, 0.42),
				rng:NextNumber(8, 12)
			)
			animateMove(
				visual,
				getInstanceWorldCFrame(visual) or CFrame.new(edgePos),
				CFrame.new(splashPos) * CFrame.Angles(rng:NextNumber(9, 14), rng:NextNumber(10, 16), rng:NextNumber(8, 14)),
				rng:NextNumber(0.45, 0.65),
				rng:NextNumber(5, 9)
			)
			if visual.Parent then
				visual:Destroy()
			end
		end

		-- Last 1–2 strikes aim at barrel positions (read live at fire time); rest are atmospheric.
		local strikeCount = math.max(math.clamp(math.floor(sequenceSeconds * 0.36), 3, 7), math.min(#barrelSources, 8))
		local barrelTargetCount = math.min(#barrelSources, strikeCount)
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
			local targetedBarrel = false
			local barrelIdx = i - atmosphericCount
			if barrelIdx >= 1 and barrelIdx <= #barrelSources then
				local sourceData = barrelSources[barrelIdx]
				local sourceInst = sourceData.instance
				local livePos = if sourceInst and sourceInst.Parent
					then getInstanceWorldPosition(sourceInst)
					else getBarrelSnapshotPosition(sourceData.snapshot)
				if livePos then
					strikeBase = livePos
					targetedBarrel = true
					task.delay(0.05, function()
						task.spawn(runBarrelWashVisual, sourceData)
					end)
				else
					strikeBase = stormCenterPos + Vector3.new(rng:NextNumber(-85, 85), 0, rng:NextNumber(-85, 85))
				end
			else
				strikeBase = stormCenterPos + Vector3.new(rng:NextNumber(-85, 85), 0, rng:NextNumber(-85, 85))
			end

			local top = strikeBase + Vector3.new(0, rng:NextNumber(72, 98), 0)
			local bottom = strikeBase + Vector3.new(0, if targetedBarrel then 0.5 else rng:NextNumber(4, 12), 0)
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
	tryEnqueueOwnerVoice(data, "Tornado")

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
			local touchingShip = inAttackPhase and (touchingDeck or insideFootprint)
			if didBarrelLoss and not chaosTriggered and touchingShip and boat then
				chaosTriggered = true
				local chaosCenter = if touchingDeck
					then Vector3.new(pathPos.X, baseY + 1.8, pathPos.Z)
					else Vector3.new(livePivotPos.X, math.max(waterY + 2, livePivotPos.Y), livePivotPos.Z)
				spawnTornadoBarrelChaos(container, boat, chaosCenter, barrelsLost, maxVisualBarrels, data.lostDeckBarrels)
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

	tryEnqueueOwnerVoice(data, "Mines")

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

			-- Impact SFX: once per successful mine detonation (didHit); not when the ship clears the field.
			local mineSfxAnchor = Instance.new("Part")
			mineSfxAnchor.Name = "MineImpactHitSfx"
			mineSfxAnchor.Size = Vector3.new(0.15, 0.15, 0.15)
			mineSfxAnchor.Transparency = 1
			mineSfxAnchor.Anchored = true
			mineSfxAnchor.CanCollide = false
			mineSfxAnchor.CanQuery = false
			mineSfxAnchor.Position = hitPos
			mineSfxAnchor.Parent = Workspace
			local mineImpactHitSfx = Instance.new("Sound")
			mineImpactHitSfx.SoundId = MINE_IMPACT_HIT_SFX_ID
			mineImpactHitSfx.Volume = MINE_IMPACT_HIT_VOLUME
			mineImpactHitSfx.RollOffMode = Enum.RollOffMode.InverseTapered
			mineImpactHitSfx.RollOffMaxDistance = 2000
			mineImpactHitSfx.Parent = mineSfxAnchor
			mineImpactHitSfx:Play()
			Debris:AddItem(mineSfxAnchor, 30)

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

			-- Explode the boat into pieces
			local boat = findActiveShipmentBoatByShipmentId(shipmentId)
			if boat then
				StraitWaypointWorldFx.ExplodeBoatIntoPieces(boat, hitPos)
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
animateMove = function(obj, fromCF: CFrame, toCF: CFrame, duration: number, arcHeight: number?)
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
	tryEnqueueOwnerVoice(data, "Pirates")

	local shipmentId = if typeof(data.shipmentId) == "string" then data.shipmentId else ""
	local barrelsStolen = math.max(0, tonumber(data.barrelsStolen) or 0)
	local approachSide = tonumber(data.approachSide) or 1
	local pirateDebug = RunService:IsStudio()

	local assets = ReplicatedStorage:FindFirstChild("Assets")
	if not assets then
		return
	end
	-- NPC pirate-raid hull. Renamed from `PirateShip` -> `PirateShipNpc` when the
	-- player-purchasable `Ship4Skin` claimed the `PirateShip` model name.
	local pirateShipTemplate = assets:FindFirstChild("PirateShipNpc")
	local pirateNpcTemplate = assets:FindFirstChild("Pirate")
	if not pirateShipTemplate or not pirateNpcTemplate then
		return
	end

	-- PirateRaidConfig.SequenceDuration = 20s. +1s buffer covers the server
	-- brake + unanchor tail. See `dampLocalPlayerCharacterDuringEvent`.
	dampLocalPlayerCharacterDuringEvent(21)

	task.spawn(function()
		local playerBoat = findActiveShipmentBoatByShipmentId(shipmentId)
		if not playerBoat then
			if pirateDebug then
				warn(string.format("[PirateRaidDebug][Client] shipment=%s no active boat found", shipmentId))
			end
			return
		end
		local boatRoot = getBoatAttachmentPart(playerBoat)
		if not boatRoot then
			if pirateDebug then
				warn(string.format("[PirateRaidDebug][Client] shipment=%s no boat root found", shipmentId))
			end
			return
		end

		-- Travel direction: prefer FRONT_MARKER, fall back to velocity sample (same pattern as CoastGuard/USShip)
		local bbCF0, _ = playerBoat:GetBoundingBox()
		local boatCenterPos = bbCF0.Position
		local waterlinePart0 = playerBoat:FindFirstChild("WaterlineAnchor", true)
		local rootPos = if waterlinePart0 and waterlinePart0:IsA("BasePart") then waterlinePart0.Position else boatCenterPos
		local frontMarker = getBoatForwardMarker(playerBoat)
		local fwd: Vector3
		if frontMarker and frontMarker:IsA("BasePart") then
			local dir = Vector3.new(frontMarker.Position.X - boatCenterPos.X, 0, frontMarker.Position.Z - boatCenterPos.Z)
			fwd = if dir.Magnitude > 0.5 then dir.Unit else Vector3.new(0, 0, -1)
		else
			task.wait(0.15)
			local bbCF1, _ = playerBoat:GetBoundingBox()
			local delta = Vector3.new(bbCF1.Position.X - boatCenterPos.X, 0, bbCF1.Position.Z - boatCenterPos.Z)
			boatCenterPos = bbCF1.Position
			fwd = if delta.Magnitude > 0.005 then delta.Unit else Vector3.new(0, 0, -1)
		end
		local sideSign = if approachSide >= 0 then 1 else -1
		local perp = Vector3.new(-fwd.Z, 0, fwd.X) * sideSign
		if pirateDebug then
			print(string.format(
				"[PirateRaidDebug][Client] shipment=%s barrelsStolen=%d snapshotCount=%d frontMarker=%s rootPos=(%.1f,%.1f,%.1f) fwd=(%.2f,%.2f,%.2f) perp=(%.2f,%.2f,%.2f)",
				shipmentId,
				barrelsStolen,
				if typeof(data.stolenDeckBarrels) == "table" then #data.stolenDeckBarrels else 0,
				tostring(frontMarker ~= nil),
				rootPos.X,
				rootPos.Y,
				rootPos.Z,
				fwd.X,
				fwd.Y,
				fwd.Z,
				perp.X,
				perp.Y,
				perp.Z
			))
		end

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

		local function movePirate(pirate, targetCF: CFrame, duration: number, arcHeight: number?)
			animateMove(pirate.npc, pirate.cf, targetCF, duration, arcHeight)
			pirate.cf = targetCF
		end

		-- Speed-based walking (CoastGuard pattern): duration derived from distance, with footstep bob
		local PIRATE_WALK_SPEED = 9
		local function walkPirate(pirate, targetCF: CFrame, speed: number?, carry: Instance?)
			local spd = speed or PIRATE_WALK_SPEED
			local fromPos = pirate.cf.Position
			local toPos   = targetCF.Position
			local dist    = (toPos - fromPos).Magnitude
			if dist < 0.3 then
				pirate.cf = targetCF
				setObjectCF(pirate.npc, targetCF)
				return
			end
			local dur = dist / spd
			local t0 = os.clock()
			local flat = Vector3.new(toPos.X - fromPos.X, 0, toPos.Z - fromPos.Z)
			local lookD = if flat.Magnitude > 0.001 then flat.Unit else fwd
			while true do
				local alpha = math.min((os.clock() - t0) / dur, 1)
				local pos = fromPos:Lerp(toPos, alpha)
				local bob = math.abs(math.sin(os.clock() * math.pi * 2.4)) * 0.32
				setObjectCF(pirate.npc, CFrame.lookAt(pos + Vector3.new(0, bob, 0), pos + lookD + Vector3.new(0, bob, 0)))
				if carry and carry.Parent then
					setObjectCF(carry, CFrame.new(pos + Vector3.new(0, 3, 0)))
				end
				if alpha >= 1 then break end
				task.wait()
			end
			pirate.cf = targetCF
			setObjectCF(pirate.npc, targetCF)
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
		local RETURN_WINDOW = 1.25 -- overlap: last pirates return vs escape drive (was undefined)
		local PIRATE_COUNT = 5
		local PIRATE_SPACING = 1.5
		local deckY = getBoatDeckY(playerBoat, rootPos.Y)
		-- Lift by NPC pivot-to-feet offset so pirates' feet land on deck (not buried).
		local _, pirateSize = pirateNpcTemplate:GetBoundingBox()
		local pirateLift = if pirateNpcTemplate:IsA("Model")
			then pirateNpcTemplate:GetPivot().Position.Y - (pirateNpcTemplate:GetBoundingBox().Position.Y - pirateSize.Y / 2)
			else pirateSize.Y / 2
		deckY = deckY + pirateLift
		local PIRATE_BOAT_DECK_Y = 4
		local GAP = 20
		local PIRATE_HALF_LEN = 9
		local SPAWN_AHEAD_DIST = 260
		local ZIP_SIDE_OFFSET = 5
		local ZIP_ATTACH_UP = 1.5
		local LANDING_BACK_OFFSET = 5
		-- Calibrated tanker-deck landing (same values CoastGuard uses)
		local LAND_LATERAL = -1
		local LAND_FWD     = 35
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
		prepareStraitEventNpcInstance(pirateBoat)
		pirateBoat.Parent = Workspace
		pirateBoat:PivotTo(uprightLookAt(spawnPos, rootPos))
		Debris:AddItem(pirateBoat, 30)

		local pirates = {}
		local pirateMid = (PIRATE_COUNT + 1) / 2
		for i = 1, PIRATE_COUNT do
			local npc = pirateNpcTemplate:Clone()
			prepareStraitEventNpcInstance(npc)
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

		do
			local ghostRoots: { Instance } = { pirateBoat }
			for _, p in ipairs(pirates) do
				table.insert(ghostRoots, p.npc)
			end
			-- Full sequence + escape (~22s) — keep sweeps longer than CoastGuard (42) so reparents stay ghosted
			sustainStraitNpcGhosts(ghostRoots, 62)
		end

		animateMove(pirateBoat, pirateBoat:GetPivot(), uprightLookAt(parkPos, rootPos), PHASE_APPROACH, 0)
		-- Approach can wake constraints / welds on the template — match CoastGuard: re-ghost after big moves
		applyStraitNpcGhostParts(pirateBoat)
		for _, p in ipairs(pirates) do
			applyStraitNpcGhostParts(p.npc)
		end

		local waterlinePartLive = playerBoat:FindFirstChild("WaterlineAnchor", true)
		rootPos = if waterlinePartLive and waterlinePartLive:IsA("BasePart") then waterlinePartLive.Position else boatRoot.Position
		deckY = getBoatDeckY(playerBoat, rootPos.Y) + pirateLift
		parkPos = Vector3.new(rootPos.X, rootPos.Y, rootPos.Z) + fwd * parkDist
		pirateBoat:PivotTo(uprightLookAt(parkPos, rootPos))

		local pirateBoatPos = pirateBoat:GetPivot().Position
		local zipFromBase = Vector3.new(pirateBoatPos.X, pirateBoatPos.Y + PIRATE_BOAT_DECK_Y, pirateBoatPos.Z) + perp * ZIP_SIDE_OFFSET
		-- Per-ship landing: prefer authored ZIPLINE_LAND_ANCHOR (Ship3/4/5 have one).
		-- Anchor is deck-surface; lift by NPC pivot-to-feet so pirates land standing.
		local zipToBase: Vector3
		local landAnchor = playerBoat:FindFirstChild("ZIPLINE_LAND_ANCHOR", true)
		if landAnchor and landAnchor:IsA("BasePart") then
			zipToBase = landAnchor.Position + Vector3.new(0, pirateLift, 0)
		else
			local tankerBBCF, _ = playerBoat:GetBoundingBox()
			local tankerDeckCtr = Vector3.new(tankerBBCF.Position.X, deckY, tankerBBCF.Position.Z)
			zipToBase = tankerDeckCtr + perp * LAND_LATERAL + fwd * LAND_FWD
		end
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

		local landingBase = Vector3.new(zipToBase.X, deckY, zipToBase.Z) - fwd * LANDING_BACK_OFFSET
		local landingPositions = {}
		for i = 1, PIRATE_COUNT do
			local targetXZ = landingBase + perp * ((i - pirateMid) * 1.6)
			landingPositions[i] = npcPivotOnDeck(playerBoat, targetXZ, pirateLift)
				or Vector3.new(targetXZ.X, deckY, targetXZ.Z)
		end

		for _, pirate in ipairs(pirates) do
			local worldCF = getObjectCF(pirate.npc)
			pirate.npc.Parent = Workspace
			setObjectCF(pirate.npc, worldCF)
			pirate.cf = worldCF
			applyStraitNpcGhostParts(pirate.npc)
		end

		local deckBarrels = buildBarrelAnimationSources(playerBoat, data.stolenDeckBarrels)
		local toSteal = math.min(barrelsStolen, #deckBarrels, PIRATE_COUNT)
		if pirateDebug then
			print(string.format(
				"[PirateRaidDebug][Client] shipment=%s liveDeckBarrels=%d usableTargets=%d toSteal=%d pirateCount=%d",
				shipmentId,
				#collectDeckBarrelInstances(playerBoat),
				#deckBarrels,
				toSteal,
				PIRATE_COUNT
			))
			if toSteal <= 0 then
				warn(string.format("[PirateRaidDebug][Client] shipment=%s no barrel targets resolved", shipmentId))
			end
		end

		-- Unified per-pirate flow: board → steal → return, all in parallel, no phase walls
		local BOARD_STAGGER = 0.25
		local BOARD_TO_ROPE_DUR, BOARD_SLIDE_DUR, BOARD_DROP_DUR = 0.2, 0.6, 0.2
		local RETURN_TO_ROPE_DUR, RETURN_SLIDE_DUR, RETURN_DROP_DUR = 0.2, 0.55, 0.2

		local pirateFlows = {}
		for i, pirate in ipairs(pirates) do
			local idx = i
			local pirateData = pirate
			local myBarrel = if idx <= toSteal then deckBarrels[idx] else nil
			table.insert(pirateFlows, function()
				-- Stagger so all pirates don't zipline at the exact same instant
				task.wait((idx - 1) * BOARD_STAGGER)

				-- === BOARD: slide down rope, drop to landing ===
				movePirate(pirateData, uprightLookAt(ropeStart, ropeEnd), BOARD_TO_ROPE_DUR, 0)
				local slideStart = os.clock()
				while true do
					local alpha = math.min((os.clock() - slideStart) / BOARD_SLIDE_DUR, 1)
					local eased = alpha * alpha * (3 - 2 * alpha)
					local slidePos = ropeStart:Lerp(ropeEnd, eased)
					slidePos += Vector3.new(0, -2.5 * math.sin(eased * math.pi), 0)
					setObjectCF(pirateData.npc, uprightLookAt(slidePos, ropeEnd))
					if alpha >= 1 then break end
					task.wait()
				end
				local landPos = landingPositions[idx]
				local landCF = uprightLookAt(landPos, ropeEnd)
				animateMove(pirateData.npc, uprightLookAt(ropeEnd, landPos), landCF, BOARD_DROP_DUR, 0)
				pirateData.cf = landCF

				-- === STEAL: walk to barrel, grab, walk to edge, toss ===
				if myBarrel then
					local barrelInst = myBarrel.instance
					local barrelSnapshot = myBarrel.snapshot
					local barrelPos = if barrelInst and barrelInst.Parent
						then getInstanceWorldPosition(barrelInst)
						else getBarrelSnapshotPosition(barrelSnapshot)
					if barrelPos then
						if pirateDebug then
							print(string.format(
								"[PirateRaidDebug][Client] shipment=%s pirate=%d barrelPos=(%.1f,%.1f,%.1f)",
								shipmentId,
								idx,
								barrelPos.X,
								barrelPos.Y,
								barrelPos.Z
							))
						end
						local carrySourceClone: Instance? = nil
						local carrySourceCF: CFrame? = nil
						if barrelInst and barrelInst.Parent and (barrelInst:IsA("Model") or barrelInst:IsA("BasePart")) then
							carrySourceClone = barrelInst:Clone()
							carrySourceCF = getObjectCF(barrelInst)
						end
						local standTargetXZ = Vector3.new(barrelPos.X, 0, barrelPos.Z) + perp * BARREL_SIDE_OFFSET
						local standPos = npcPivotOnDeck(playerBoat, standTargetXZ, pirateLift)
							or Vector3.new(standTargetXZ.X, deckY, standTargetXZ.Z)
						walkPirate(pirateData, uprightLookAt(standPos, barrelPos))
						if barrelInst and barrelInst.Parent then
							barrelInst:Destroy()
						end
						task.wait(0.2)

						local carry: Instance
						if carrySourceClone then
							carry = carrySourceClone
							prepareKinematicFx(carry)
							setInstanceWorldCFrame(carry, carrySourceCF or CFrame.new(barrelPos))
						else
							carry = createBarrelVisualFromSnapshot(barrelSnapshot, barrelPos)
						end
						carry.Name = "CarriedBarrel"
						prepareKinematicFx(carry)
						setObjectCF(carry, CFrame.new(standPos + Vector3.new(0, BARREL_CARRY_UP, 0)))
						carry.Parent = Workspace
						Debris:AddItem(carry, 20)

						local edgeDir = Vector3.new(zipFromBase.X - standPos.X, 0, zipFromBase.Z - standPos.Z)
						edgeDir = if edgeDir.Magnitude > 0.001 then edgeDir.Unit else fwd
						local edgeTargetXZ = Vector3.new(standPos.X + edgeDir.X * 8, 0, standPos.Z + edgeDir.Z * 8)
						local edgePos = npcPivotOnDeck(playerBoat, edgeTargetXZ, pirateLift)
							or Vector3.new(edgeTargetXZ.X, deckY, edgeTargetXZ.Z)
						walkPirate(pirateData, uprightLookAt(edgePos, zipFromBase), nil, carry)

						local tossTarget = pirateBoat:GetPivot().Position
							+ Vector3.new(0, PIRATE_BOAT_DECK_Y + 1, 0)
							+ fwd * ((idx - pirateMid) * PIRATE_SPACING)
						if pirateDebug then
							print(string.format(
								"[PirateRaidDebug][Client] shipment=%s pirate=%d standPos=(%.1f,%.1f,%.1f) edgePos=(%.1f,%.1f,%.1f) tossTarget=(%.1f,%.1f,%.1f)",
								shipmentId,
								idx,
								standPos.X,
								standPos.Y,
								standPos.Z,
								edgePos.X,
								edgePos.Y,
								edgePos.Z,
								tossTarget.X,
								tossTarget.Y,
								tossTarget.Z
							))
						end
						animateMove(carry, getObjectCF(carry), CFrame.new(tossTarget), 0.9, TOSS_ARC_HEIGHT)
						carry.Parent = pirateBoat
						setInstanceWorldCFrame(carry, CFrame.new(tossTarget))
						if pirateDebug then
							print(string.format(
								"[PirateRaidDebug][Client] shipment=%s pirate=%d mountedCarry=true",
								shipmentId,
								idx
							))
						end
					elseif pirateDebug then
						warn(string.format("[PirateRaidDebug][Client] shipment=%s pirate=%d barrelPos unresolved", shipmentId, idx))
					end
				elseif pirateDebug then
					print(string.format("[PirateRaidDebug][Client] shipment=%s pirate=%d no assigned barrel", shipmentId, idx))
				end

				-- === RETURN: walk back to landing, slide up rope, drop on pirate boat ===
				walkPirate(pirateData, uprightLookAt(landingPositions[idx], ropeEnd))
				movePirate(pirateData, uprightLookAt(ropeEnd, ropeStart), RETURN_TO_ROPE_DUR, 0)
				local upStart = os.clock()
				while true do
					local alpha = math.min((os.clock() - upStart) / RETURN_SLIDE_DUR, 1)
					local eased = alpha * alpha * (3 - 2 * alpha)
					local slidePos = ropeEnd:Lerp(ropeStart, eased)
					slidePos += Vector3.new(0, -2.5 * math.sin(eased * math.pi), 0)
					setObjectCF(pirateData.npc, uprightLookAt(slidePos, ropeStart))
					if alpha >= 1 then break end
					task.wait()
				end
				local pbPos = pirateBoat:GetPivot().Position
				local returnPos = pbPos + Vector3.new(0, PIRATE_BOAT_DECK_Y, 0) + fwd * ((idx - pirateMid) * PIRATE_SPACING)
				local returnCF = uprightLookAt(returnPos, returnPos + fwd)
				animateMove(pirateData.npc, uprightLookAt(ropeStart, returnPos), returnCF, RETURN_DROP_DUR, 0)
				pirateData.cf = returnCF
			end)
		end
		-- Wait until EVERY pirate has finished their full flow (no minimum hold)
		runTimedParallel(pirateFlows, 0)

		Debris:AddItem(zipA, 0.1)
		Debris:AddItem(zipB, 0.1)

		for _, pirate in ipairs(pirates) do
			if pirate.npc.Parent then
				local worldCF = getObjectCF(pirate.npc)
				pirate.npc.Parent = pirateBoat
				setObjectCF(pirate.npc, worldCF)
				pirate.cf = worldCF
				applyStraitNpcGhostParts(pirate.npc)
			end
		end
		applyStraitNpcGhostParts(pirateBoat)

		local driveAwayDur = math.max(0.2, PHASE_ESCAPE - RETURN_WINDOW)
		local escapePos = pirateBoat:GetPivot().Position + fwd * ESCAPE_DIST
		escapePos = Vector3.new(escapePos.X, rootPos.Y, escapePos.Z)
		animateMove(pirateBoat, pirateBoat:GetPivot(), uprightLookAt(escapePos, escapePos + fwd), driveAwayDur, 0)

		Debris:AddItem(pirateBoat, 2)
	end)
end

--- Coast guard alarm/horn burst — plays 3 times back-to-back (each waits for the
--- previous to finish via `Sound.Ended:Wait()`) when the inspection event fires.
--- The `Coastguard` voice line is enqueued in the burst's completion callback so
--- it plays AFTER the burst rather than overlapping. **Owner-only**: the
--- burst is non-spatial 2D audio piped through `SoundService`; firing it for
--- every client made spectators hear an alarm any time anyone got inspected.
--- Visual cinematic (CG boat + officers) still spawns for everyone.
local COASTGUARD_BURST_SOUND_ID = "rbxassetid://115844314196536"
local COASTGUARD_BURST_COUNT = 3
--- Volume reduced to 25% of the previous 0.35 (-3/4) so the alarm sits under
--- the voice line and doesn't blow out other ambient SFX.
local COASTGUARD_BURST_VOLUME = 0.0875

function StraitWaypointWorldFx.OnCoastGuardInspectionPayload(data: { [string]: any })
	if isLocalOwner(data) then
		playSfxByIdRepeated(COASTGUARD_BURST_SOUND_ID, COASTGUARD_BURST_COUNT, COASTGUARD_BURST_VOLUME, function()
			tryEnqueueVoice("Coastguard")
		end)
	end

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

	-- CoastGuardInspectionConfig.SequenceDuration = 16s (server pause window).
	-- +1s buffer covers the small server brake + unanchor tail before normal
	-- platform velocity resumes. See `dampLocalPlayerCharacterDuringEvent` for
	-- why this exists (anchored cosmetic CG hull / officer landing pushes).
	dampLocalPlayerCharacterDuringEvent(17)

	task.spawn(function()
		local playerBoat = findActiveShipmentBoatByShipmentId(shipmentId)
		if not playerBoat then return end
		local boatRoot = getBoatAttachmentPart(playerBoat)
		if not boatRoot then return end

		-- Use bounding box center for XZ position (individual parts can be way off)
		local bbCF0, _ = playerBoat:GetBoundingBox()
		local rootPos   = bbCF0.Position

		-- Travel direction from FRONT_MARKER if present, else velocity sample
		local frontMarker = getBoatForwardMarker(playerBoat)
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

		-- Deck Y: surface where feet should land. NPC pivots are at body center, so we
		-- lift the placement Y by the NPC's pivot-to-bottom offset (measured from template).
		local bbCF, bbSize    = playerBoat:GetBoundingBox()
		local deckY           = getBoatDeckY(playerBoat, boatRoot.Position.Y)
		local _, npcSize      = cgNpcTemplate:GetBoundingBox()
		local npcPivotToFeet  = if cgNpcTemplate:IsA("Model")
			then cgNpcTemplate:GetPivot().Position.Y - (cgNpcTemplate:GetBoundingBox().Position.Y - npcSize.Y / 2)
			else npcSize.Y / 2
		deckY = deckY + npcPivotToFeet
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
		local PHASE_RETURN     = 1.5   -- straight zipline back, no walking
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
		prepareStraitEventNpcInstance(cgBoat)
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
		-- Re-read with lift preserved — raw getBoatDeckY would sink officers on next walk.
		deckY = getBoatDeckY(playerBoat, boatRoot.Position.Y) + npcPivotToFeet
		deckCtr = Vector3.new(rootPos.X, deckY, rootPos.Z)

		local snappedPark = Vector3.new(rootPos.X, boatRoot.Position.Y, rootPos.Z) + perp * parkLateral
		cgBoat:PivotTo(flatLookAt(snappedPark, snappedPark - perp))

		-- NOW spawn officers on the PARKED CG boat (visible standing in a row)
		local cgParkedPos = cgBoat:GetPivot().Position
		local officers = {}
		for i = 1, OFFICER_COUNT do
			local npc    = cgNpcTemplate:Clone()
			prepareStraitEventNpcInstance(npc)
			local along  = fwd * ((i - officerMid) * OFFICER_SPACING)
			local npcPos = cgParkedPos + Vector3.new(0, CG_BOAT_DECK_Y, 0) + along
			local npcCF  = flatLookAt(npcPos, rootPos)
			setObjCF(npc, npcCF)
			npc.Parent = Workspace  -- world-space from the start, no re-parenting needed
			table.insert(officers, { npc = npc, cf = npcCF })
			Debris:AddItem(npc, 42)
		end

		do
			local ghostRoots: { Instance } = { cgBoat }
			for _, o in ipairs(officers) do
				table.insert(ghostRoots, o.npc)
			end
			sustainStraitNpcGhosts(ghostRoots, 42)
		end

		-- Brief pause so player sees officers standing on deck
		task.wait(0.5)

		-- Zipline anchor points — spawn visible studs so you can drag them in playtest when calibrating
		local zipFromPos = cgParkedPos + Vector3.new(0, CG_BOAT_DECK_Y, 0) - perp * (CG_HALF_WIDTH * 0.7) + fwd * 2
		-- Per-ship landing: prefer authored ZIPLINE_LAND_ANCHOR (Ship3/4/5 have one).
		-- Anchor represents deck SURFACE; lift by NPC pivot-to-feet so officers land standing,
		-- not half-buried (NPC pivot is 3 studs above feet on the CG template).
		local zipToPos: Vector3
		do
			local landAnchor = playerBoat:FindFirstChild("ZIPLINE_LAND_ANCHOR", true)
			if landAnchor and landAnchor:IsA("BasePart") then
				zipToPos = landAnchor.Position + Vector3.new(0, npcPivotToFeet, 0)
			else
				zipToPos = deckCtr + perp * LAND_LATERAL + fwd * LAND_FWD
			end
		end

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

		-- 6 inspection zones computed from actual boat footprint, then raycasted to the
		-- real deck surface at each XZ. Zones that miss the boat are dropped so NPCs
		-- can't walk off the hull. Handles bumpy/multi-level decks per-position.
		local rawZones = {
			deckCtr + fwd * boatLenHalf * 0.80,                          -- bow
			deckCtr - fwd * boatLenHalf * 0.80,                          -- stern
			deckCtr + fwd * boatLenHalf * 0.35 + right * boatWidthHalf,  -- fwd starboard
			deckCtr + fwd * boatLenHalf * 0.35 - right * boatWidthHalf,  -- fwd port
			deckCtr - fwd * boatLenHalf * 0.35 + right * boatWidthHalf,  -- aft starboard
			deckCtr - fwd * boatLenHalf * 0.35 - right * boatWidthHalf,  -- aft port
		}
		local rawAltZones = {
			deckCtr + fwd * boatLenHalf * 0.55,
			deckCtr - fwd * boatLenHalf * 0.55,
			deckCtr,
			deckCtr + right * boatWidthHalf * 0.6,
			deckCtr - right * boatWidthHalf * 0.6,
			deckCtr + fwd * boatLenHalf * 0.6 + right * boatWidthHalf * 0.5,
		}
		local function clampZonesToBoat(raw)
			local out = {}
			for _, pos in ipairs(raw) do
				local p = npcPivotOnDeck(playerBoat, pos, npcPivotToFeet)
				if p then table.insert(out, p) end
			end
			-- Safety: if everything missed (would mean sketchy hull colliders),
			-- fall back to deckCtr so officers don't land nowhere.
			if #out == 0 then
				table.insert(out, Vector3.new(deckCtr.X, deckCtr.Y, deckCtr.Z))
			end
			return out
		end
		local zones = clampZonesToBoat(rawZones)
		local altZones = clampZonesToBoat(rawAltZones)

		-- Phase 2: Board + Inspect — each officer independently
		-- Officer walks to zipline, slides across, then immediately walks to their zones
		print(string.format("[CG] Inspection start: officers=%d zones=%d altZones=%d zipFrom=%s zipTo=%s",
			#officers, #zones, #altZones, tostring(zipFromPos), tostring(zipToPos)))
		local rng = Random.new()
		local boardInspTasks: { () -> () } = {}
		for i, off in ipairs(officers) do
			local idx = i
			table.insert(boardInspTasks, function()
				print(string.format("[CG] officer[%d] start cf=%s", idx, tostring(off.cf.Position)))
				-- Stagger boarding
				task.wait((idx - 1) * BOARD_STAGGER)

				-- Walk to zipline anchor on CG boat side
				print(string.format("[CG] officer[%d] walking to zipFrom", idx))
				walkNpc(off, flatLookAt(zipFromPos, zipToPos), WALK_SPEED)
				print(string.format("[CG] officer[%d] zipline slide", idx))

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

				-- Immediately walk to primary inspection zone (clamp idx to available zones).
				local z1 = zones[((idx - 1) % math.max(1, #zones)) + 1]
				local z2 = altZones[((idx - 1) % math.max(1, #altZones)) + 1]
				print(string.format("[CG] officer[%d] walking to zone1=%s", idx, tostring(z1)))
				if not z1 then return end
				walkNpc(off, flatLookAt(z1, z1 + fwd * (if idx % 2 == 0 then 1 else -1)), WALK_SPEED)
				task.wait(rng:NextNumber(0.3, 0.5))

				-- Walk to secondary zone
				walkNpc(off, flatLookAt(z2, z2 + fwd * (if idx % 2 == 0 then -1 else 1)), WALK_SPEED)
				task.wait(rng:NextNumber(0.2, 0.4))
			end)
		end
		runPar(boardInspTasks, PHASE_BOARD_INSP)

		-- Phase 3: Officers zipline straight back to CG boat, then disappear — so it
		-- reads as "they went inside" and the CG boat leaves empty-looking.
		local returnTasks: { () -> () } = {}
		for i, off in ipairs(officers) do
			local idx = i
			table.insert(returnTasks, function()
				local startPos = off.cf.Position
				local endPos = cgParkedPos + Vector3.new(0, CG_BOAT_DECK_Y, 0) + fwd * ((idx - officerMid) * OFFICER_SPACING)
				local t0 = os.clock()
				local DUR = 1.0
				while true do
					local a = math.min((os.clock() - t0) / DUR, 1)
					local e = a * a * (3 - 2 * a)
					local p = startPos:Lerp(endPos, e) + Vector3.new(0, -2.5 * math.sin(e * math.pi), 0)
					setObjCF(off.npc, flatLookAt(p, startPos))
					if a >= 1 then break end
					task.wait()
				end
				-- Landed on CG boat → vanish (went inside).
				if off.npc and off.npc.Parent then
					off.npc:Destroy()
				end
			end)
		end
		runPar(returnTasks, PHASE_RETURN)

		-- Cleanup
		Debris:AddItem(zipA, 0.05)
		Debris:AddItem(zipB, 0.05)
		stopSiren()

		-- Depart: CG boat sails away fast so player boat can resume.
		local escapeTarget = cgBoat:GetPivot().Position + perp * 200
		animateMove(cgBoat, cgBoat:GetPivot(), flatLookAt(escapeTarget, escapeTarget - perp), 2.5, 0)
		Debris:AddItem(cgBoat, 2)
	end)
end

function StraitWaypointWorldFx.OnUSShipSlapPayload(data: { [string]: any })
	--- Catalog row id is `USShipSlap`; player-facing displayName is "Sea
	--- Monster". The voice asset hasn't been uploaded yet — the queue's
	--- `findTemplate` returns nil for it and we silently skip. The day a
	--- `SeaMonster` Sound lands under `Assets.SFX.VoiceLines`, this line
	--- starts producing audio with zero further code changes.
	tryEnqueueOwnerVoice(data, "USShipSlap")

	local shipmentId   = if typeof(data.shipmentId) == "string" then data.shipmentId else ""

	local assets = ReplicatedStorage:FindFirstChild("Assets")
	if not assets then return end
	local tentacleTemplate = assets:FindFirstChild("KrakenTentacle")
	if not tentacleTemplate then
		warn("[StraitWaypointWorldFx] Missing KrakenTentacle in ReplicatedStorage.Assets")
		return
	end

	task.spawn(function()
		local playerBoat = findActiveShipmentBoatByShipmentId(shipmentId)
		if not playerBoat then return end
		local boatRoot = getBoatAttachmentPart(playerBoat)
		if not boatRoot then return end

		-- Event is broadcast to all clients; only the victim should hear kraken / ship-break SFX (2D camera sounds were still playing for everyone).
		local ownerUid = tonumber(data.ownerUserId)
		local isVictimClient = ownerUid ~= nil and Players.LocalPlayer.UserId == ownerUid

		local bbCF, bbSz = playerBoat:GetBoundingBox()
		local rootPos = bbCF.Position
		local waterY = boatRoot.Position.Y

		-- Play kraken SFX immediately (slam synced to 4.12s in the clip) — victim only
		local krakenSfx: Sound? = nil
		if isVictimClient then
			local k = Instance.new("Sound")
			k.SoundId = "rbxassetid://97968431643666"
			k.Volume = 1.5
			k.Parent = Workspace.CurrentCamera
			k:Play()
			krakenSfx = k
		end

		local SCALE = 30
		local TENTACLE_COUNT = 6
		local RING_RADIUS = math.max(bbSz.X, bbSz.Z) * 0.6 + 20
		local SUBMERGE_DEPTH = 400
		-- Tentacles only poke out partially — base always underwater
		local RISE_TOP_Y = waterY - 40

		-- Spawn tentacles in a ring, pointing STRAIGHT UP
		local tentacles = {}
		local tentStartCFs = {}
		local tentRiseCFs = {}
		local tentSlamCFs = {}

		for i = 1, TENTACLE_COUNT do
			local angle = (i - 1) * (math.pi * 2 / TENTACLE_COUNT)
			local outward = Vector3.new(math.cos(angle), 0, math.sin(angle))
			local baseXZ = rootPos + outward * RING_RADIUS

			local tent = tentacleTemplate:Clone()
			tent.Name = "KrakenTent_" .. i
			prepareStraitEventNpcInstance(tent)
			tent:ScaleTo(SCALE)

			-- Straight vertical: tentacle points UP from underwater
			local subPos = Vector3.new(baseXZ.X, waterY - SUBMERGE_DEPTH, baseXZ.Z)
			local risePos = Vector3.new(baseXZ.X, RISE_TOP_Y, baseXZ.Z)

			-- CFrame facing inward but rotated so tentacle extends vertically
			local inward = (rootPos - baseXZ).Unit
			local startCF = CFrame.new(subPos) * CFrame.Angles(0, math.atan2(inward.X, inward.Z), 0)
			local riseCF = CFrame.new(risePos) * CFrame.Angles(0, math.atan2(inward.X, inward.Z), 0)

			-- Slam target: crash down onto the boat center
			local slamPos = Vector3.new(
				rootPos.X + outward.X * (RING_RADIUS * 0.15),
				waterY - 10,
				rootPos.Z + outward.Z * (RING_RADIUS * 0.15)
			)
			local slamCF = CFrame.new(slamPos)
				* CFrame.Angles(0, math.atan2(inward.X, inward.Z), 0)
				* CFrame.Angles(math.rad(90), 0, 0) -- tip over toward boat

			tent:PivotTo(startCF)
			tent.Parent = Workspace
			Debris:AddItem(tent, 20)

			if not isVictimClient then
				for _, d in ipairs(tent:GetDescendants()) do
					if d:IsA("Sound") then
						d.Volume = 0
						d.Playing = false
					end
				end
			end

			-- Play wiggle animation with random offset
			local animCtrl = tent:FindFirstChildOfClass("AnimationController")
			if animCtrl then
				local animator = animCtrl:FindFirstChildOfClass("Animator")
				if animator then
					local anim = Instance.new("Animation")
					anim.AnimationId = "rbxassetid://9200678338"
					local track = animator:LoadAnimation(anim)
					track:Play()
					track.TimePosition = math.random() * 2
				end
			end

			table.insert(tentacles, tent)
			table.insert(tentStartCFs, startCF)
			table.insert(tentRiseCFs, riseCF)
			table.insert(tentSlamCFs, slamCF)
		end

		-- Phase 1: Tentacles RISE straight up from the ocean (2.5s, staggered)
		local RISE_DUR = 2.5
		local riseT0 = os.clock()
		while true do
			local elapsed = os.clock() - riseT0
			if elapsed >= RISE_DUR + 0.5 then break end
			for i, tent in ipairs(tentacles) do
				local stagger = (i - 1) * 0.1
				local alpha = math.clamp((elapsed - stagger) / RISE_DUR, 0, 1)
				local e = alpha * alpha * (3 - 2 * alpha)
				tent:PivotTo(tentStartCFs[i]:Lerp(tentRiseCFs[i], e))
			end
			task.wait()
		end

		-- Menacing pause — timed so slam IMPACT hits at 4.15s into the SFX
		-- Rise loop = 3.0s, slam = 0.4s, so pause = 4.15 - 3.0 - 0.4 = 0.75s
		task.wait(0.75)

		-- Snap to boat's live position for slam accuracy
		local snapCF2, _ = playerBoat:GetBoundingBox()
		rootPos = snapCF2.Position

		-- Phase 2: ALL tentacles SLAM DOWN violently onto the ship (0.4s)
		local SLAM_DUR = 0.4
		local slamT0 = os.clock()
		local slamStartCFs = {}
		for i, tent in ipairs(tentacles) do
			table.insert(slamStartCFs, tent:GetPivot())
		end
		while true do
			local elapsed = os.clock() - slamT0
			if elapsed >= SLAM_DUR then break end
			local alpha = math.min(elapsed / SLAM_DUR, 1)
			local e = alpha * alpha * alpha -- cubic ease-in = violent acceleration
			for i, tent in ipairs(tentacles) do
				tent:PivotTo(slamStartCFs[i]:Lerp(tentSlamCFs[i], e))
			end
			task.wait()
		end

		-- Phase 3: IMPACT — everything happens INSTANTLY and in parallel
		-- Explode boat
		StraitWaypointWorldFx.ExplodeBoatIntoPieces(playerBoat, rootPos)

		-- Play ShipDestroyed SFX AFTER the kraken clip finishes (not during) — victim only
		if isVictimClient and krakenSfx then
			task.spawn(function()
				local k = krakenSfx
				local krakenSfxLength = 0
				if k.IsLoaded then
					krakenSfxLength = k.TimeLength
				else
					k.Loaded:Wait()
					krakenSfxLength = k.TimeLength
				end
				-- Wait for remaining clip time from slam impact (4.12s in) to end
				local remaining = math.max(0, krakenSfxLength - 4.12)
				task.wait(remaining)
				-- Now play ship destroyed
				local sfxFolder = ReplicatedStorage:FindFirstChild("Assets") and ReplicatedStorage.Assets:FindFirstChild("SFX")
				local shipDestroyedTemplate = sfxFolder and sfxFolder:FindFirstChild("ShipDestroyed")
				if shipDestroyedTemplate then
					local s = shipDestroyedTemplate:Clone()
					s.Parent = Workspace.CurrentCamera
					s:Play()
					Debris:AddItem(s, s.TimeLength + 1)
				end
				-- Cleanup kraken sfx after it ends
				Debris:AddItem(k, 2)
			end)
		end

		-- Sink boat underwater (parallel)
		task.spawn(function()
			local boatStart = playerBoat:GetPivot()
			local sinkTarget = boatStart + Vector3.new(0, -200, 0)
			local sinkDur = 0.8
			local sinkT = os.clock()
			while true do
				local a = math.min((os.clock() - sinkT) / sinkDur, 1)
				playerBoat:PivotTo(boatStart:Lerp(sinkTarget, a * a))
				if a >= 1 then break end
				task.wait()
			end
		end)

		-- Player head death cam (parallel — does NOT block)
		task.spawn(function()
			local Players = game:GetService("Players")
			local localPlayer = Players.LocalPlayer
			local localChar = localPlayer and localPlayer.Character
			local hrp2 = localChar and localChar:FindFirstChild("HumanoidRootPart") :: BasePart?
			if not hrp2 then return end
			if (hrp2.Position - rootPos).Magnitude > 80 then return end

			local head = localChar:FindFirstChild("Head")
			if not head or not head:IsA("BasePart") then return end

			local headClone = head:Clone()
			headClone.Anchored = true
			headClone.CanCollide = false
			headClone.Name = "KrakenHeadClone"
			headClone.CFrame = head.CFrame
			for _, child in ipairs(head:GetChildren()) do
				if child:IsA("Decal") or child:IsA("FaceInstance") then
					child:Clone().Parent = headClone
				end
			end
			headClone.Parent = Workspace
			Debris:AddItem(headClone, 8)

			local camera = Workspace.CurrentCamera
			camera.CameraType = Enum.CameraType.Scriptable

			local headStart = headClone.CFrame
			local shipDeathPos = rootPos -- where the ship was destroyed
			-- Camera rises up above the wreckage looking down
			local camStartPos = headStart.Position + Vector3.new(0, 20, 0)
			local camEndPos = shipDeathPos + Vector3.new(0, 150, 0)
			local FLY_DUR = 4
			local flyT0 = os.clock()
			-- Head sinks with the ship debris
			local headEnd = shipDeathPos + Vector3.new(0, -100, 0)
			while true do
				local alpha = math.min((os.clock() - flyT0) / FLY_DUR, 1)
				local e = alpha * alpha * (3 - 2 * alpha)
				-- Head sinks underwater
				local headPos = headStart.Position:Lerp(headEnd, e)
				headClone.CFrame = CFrame.new(headPos) * CFrame.Angles(e * 8, e * 5, e * 3)
				-- Camera rises up, always looking down at the wreckage
				local camPos = camStartPos:Lerp(camEndPos, e)
				camera.CFrame = CFrame.lookAt(camPos, shipDeathPos + Vector3.new(0, -50 * e, 0))
				if alpha >= 1 then break end
				task.wait()
			end

			local charConn
			charConn = localPlayer.CharacterAdded:Connect(function()
				camera.CameraType = Enum.CameraType.Custom
				if charConn then charConn:Disconnect() end
			end)
			task.delay(8, function()
				camera.CameraType = Enum.CameraType.Custom
				if charConn then charConn:Disconnect() end
			end)
		end)

		-- Phase 4: Tentacles sink back underwater (2s)
		task.wait(0.5)
		local SINK_DUR = 2
		local sinkT0 = os.clock()
		local sinkFromCFs = {}
		for _, tent in ipairs(tentacles) do
			table.insert(sinkFromCFs, tent:GetPivot())
		end
		while true do
			local elapsed = os.clock() - sinkT0
			if elapsed >= SINK_DUR then break end
			local alpha = math.min(elapsed / SINK_DUR, 1)
			local e = alpha * alpha
			for i, tent in ipairs(tentacles) do
				local target = sinkFromCFs[i] + Vector3.new(0, -(SUBMERGE_DEPTH + 250), 0)
				tent:PivotTo(sinkFromCFs[i]:Lerp(target, e))
			end
			task.wait()
		end

		for _, tent in ipairs(tentacles) do
			Debris:AddItem(tent, 0.1)
		end
	end)
end

return StraitWaypointWorldFx
