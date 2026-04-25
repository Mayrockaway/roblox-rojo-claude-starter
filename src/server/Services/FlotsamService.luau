--!strict
--- FlotsamService
---
--- Spawns floating wooden crates ("flotsam") at random points on the strait
--- ocean. Players swim out to a crate, trigger its `ProximityPrompt`, and
--- receive a server-rolled reward (cash for MVP).
---
--- Spawn area is constrained to the rotated `Map.Ocean.StraitHormuz.Ocean`
--- union via the same `cf:PointToObjectSpace` local-bbox check we use for
--- the terrain-water fill — so crates never land on cliffs or out-of-bounds.
--- (No raycast against terrain limestone today; islands are sparse enough
--- that the occasional unreachable crate is acceptable for MVP. Add a
--- `Terrain:ReadVoxels` "is the spot water?" check here later if it becomes
--- noticeable.)
---
--- Asset pipeline: clones `ServerStorage.FlotsamCrateTemplate` (a Model with
--- a `PrimaryPart`). If that template doesn't exist yet, falls back to a
--- placeholder brown box so the spawn loop is testable without an asset.
--- Drop a real wooden-crate Model in there to switch to the production look.
---
--- Reward grants land via existing services:
---   * `Cash` -> `OilStateService:AddCash` (picks up DoubleEarnings + global
---     Cash Frenzy multipliers automatically)
--- Add Equipment/Oil branches in `_handleClaim` when those reward kinds are
--- promoted out of MVP. The Robux drill flow's
--- `EquipmentShopService:GrantFreeOwnedEquipment` is the canonical
--- equipment grant API.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local FlotsamConfig = require(Shared:WaitForChild("Config"):WaitForChild("FlotsamConfig"))
local DevLog = require(Shared:WaitForChild("DevLog"))

local FlotsamService = {}

type CrateInfo = {
	model: Model,
	position: Vector3,
	spawnedAt: number,
}

function FlotsamService:Init(oilStateService)
	self._oilStateService = oilStateService
	self._activeCrates = {} :: { [number]: CrateInfo }
	self._nextCrateId = 1
	self._connections = {} :: { RBXScriptConnection }

	-- Captured at Start time from the Ocean union — service is rotation-aware
	-- via `_oceanCFrame:PointToObjectSpace(...)` instead of a naive AABB.
	self._oceanCFrame = nil :: CFrame?
	self._oceanHalfX = 0
	self._oceanHalfZ = 0
	self._waterSurfaceY = 0
	self._runtimeFolder = nil :: Folder?
	self._rng = Random.new()
	self._running = false
end

function FlotsamService:Start()
	if not FlotsamConfig.Enabled then
		DevLog.log("[FlotsamService] Disabled via FlotsamConfig.Enabled — not spawning.")
		return
	end

	local mapFolder = Workspace:FindFirstChild("Map")
	local oceanFolder = mapFolder and mapFolder:FindFirstChild("Ocean")
	local straitFolder = oceanFolder and oceanFolder:FindFirstChild("StraitHormuz")
	local ocean = straitFolder and straitFolder:FindFirstChild("Ocean")
	if not (ocean and ocean:IsA("BasePart")) then
		warn("[FlotsamService] Workspace.Map.Ocean.StraitHormuz.Ocean not found — flotsam disabled.")
		return
	end

	self._oceanCFrame = ocean.CFrame
	self._oceanHalfX = ocean.Size.X / 2
	self._oceanHalfZ = ocean.Size.Z / 2
	self._waterSurfaceY = ocean.Position.Y + ocean.Size.Y / 2

	-- Runtime-spawned crates live in their own folder so they're easy to
	-- audit / wipe in Studio without touching authored content.
	local folder = Instance.new("Folder")
	folder.Name = "RuntimeFlotsam"
	folder.Parent = Workspace
	self._runtimeFolder = folder

	self._running = true

	-- Maintenance loop: keeps `MaxActiveCrates` alive at all times. Lazily
	-- tops up after pickups instead of pre-scheduling per-crate respawn
	-- timers — simpler, and the tick cadence (5s default) is fine for the
	-- "swim, grab, swim back to next" pacing.
	task.spawn(function()
		while self._running do
			self:_maintainSpawns()
			task.wait(FlotsamConfig.MaintenanceTickSeconds)
		end
	end)

	DevLog.log(string.format(
		"[FlotsamService] Started. Target crates: %d. Ocean center: %s",
		FlotsamConfig.MaxActiveCrates, tostring(ocean.Position)))
end

------------------------------------------------------------------------------
-- Maintenance + spawning
------------------------------------------------------------------------------

function FlotsamService:_maintainSpawns()
	local count = 0
	for _ in pairs(self._activeCrates) do
		count += 1
	end

	local target = FlotsamConfig.MaxActiveCrates
	while count < target do
		local ok = self:_spawnOneCrate()
		if not ok then
			-- Couldn't find a valid spot this tick — bail and try again next
			-- tick. Avoids a tight loop hammering RNG when the strait is
			-- temporarily packed.
			break
		end
		count += 1
	end
end

function FlotsamService:_spawnOneCrate(): boolean
	local position = self:_findRandomSpawnPoint()
	if not position then
		return false
	end

	local model = self:_buildCrateModel()
	if not model then
		warn("[FlotsamService] Failed to build crate model.")
		return false
	end

	-- Place at the chosen surface position. Use PivotTo so a Model with a
	-- PrimaryPart positions cleanly; fall back for single-part models.
	if model.PrimaryPart then
		model:PivotTo(CFrame.new(position))
	else
		local rootPart = model:FindFirstChildWhichIsA("BasePart")
		if rootPart then
			rootPart.CFrame = CFrame.new(position)
		end
	end

	local crateId = self._nextCrateId
	self._nextCrateId += 1
	model:SetAttribute("FlotsamCrateId", crateId)

	-- ProximityPrompt + claim wiring. Triggered fires server-side with the
	-- triggering player as the first arg, so no client wiring is needed for
	-- the minimum viable loop — players see the prompt automatically because
	-- the prompt instance replicates with the rest of the model.
	local prompt = self:_attachProximityPrompt(model)
	if prompt then
		local conn
		conn = prompt.Triggered:Connect(function(player)
			self:_handleClaim(crateId, player)
		end)
		table.insert(self._connections, conn)
	end

	model.Parent = self._runtimeFolder

	self._activeCrates[crateId] = {
		model = model,
		position = position,
		spawnedAt = workspace:GetServerTimeNow(),
	}

	if FlotsamConfig.VerboseLogging then
		DevLog.log(string.format("[FlotsamService] Spawned crate %d at %s", crateId, tostring(position)))
	end
	return true
end

--- Sample random world-space points inside the rotated union footprint until
--- we find one that isn't too close to an existing crate. Returns nil if no
--- valid point was found within `MaxSpawnAttempts`.
function FlotsamService:_findRandomSpawnPoint(): Vector3?
	local cf = self._oceanCFrame
	if not cf then
		return nil
	end
	local margin = FlotsamConfig.EdgeMargin
	local minSpacing = FlotsamConfig.MinSpacing
	local hx = self._oceanHalfX - margin
	local hz = self._oceanHalfZ - margin
	if hx <= 0 or hz <= 0 then
		warn("[FlotsamService] EdgeMargin larger than union half-extent — no spawn area.")
		return nil
	end

	for _ = 1, FlotsamConfig.MaxSpawnAttempts do
		-- Sample in LOCAL space so the rotated union's rectangle is honoured;
		-- then transform to world via PointToWorldSpace. This sidesteps the
		-- rotated-AABB pitfall that bit the terrain-water fill earlier.
		local localX = self._rng:NextNumber(-hx, hx)
		local localZ = self._rng:NextNumber(-hz, hz)
		local worldFlat = cf:PointToWorldSpace(Vector3.new(localX, 0, localZ))
		local world = Vector3.new(
			worldFlat.X,
			self._waterSurfaceY + FlotsamConfig.SpawnYOffset,
			worldFlat.Z
		)

		local tooClose = false
		for _, info in pairs(self._activeCrates) do
			if (info.position - world).Magnitude < minSpacing then
				tooClose = true
				break
			end
		end
		if not tooClose then
			return world
		end
	end
	return nil
end

--- Clone the designer-authored crate template if present, else build a
--- visible placeholder so the loop is testable without an asset.
function FlotsamService:_buildCrateModel(): Model?
	local template = ServerStorage:FindFirstChild("FlotsamCrateTemplate")
	if template and template:IsA("Model") then
		local clone = template:Clone()
		clone.Name = "FlotsamCrate"
		-- Force-anchor every BasePart so the crate sits where we put it
		-- (designers sometimes leave parts unanchored in the template).
		for _, d in ipairs(clone:GetDescendants()) do
			if d:IsA("BasePart") then
				d.Anchored = true
				d.CanCollide = false
			end
		end
		return clone
	end

	-- Placeholder: a single brown wood cube. Easy to spot in playtest, easy
	-- to swap out later by dropping a Model into ServerStorage.
	local model = Instance.new("Model")
	model.Name = "FlotsamCrate_Placeholder"

	local part = Instance.new("Part")
	part.Name = "Crate"
	part.Size = Vector3.new(4, 4, 4)
	part.Material = Enum.Material.WoodPlanks
	part.Color = Color3.fromRGB(120, 75, 40)
	part.Anchored = true
	part.CanCollide = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = model

	model.PrimaryPart = part
	return model
end

function FlotsamService:_attachProximityPrompt(model: Model): ProximityPrompt?
	local host = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
	if not host then
		return nil
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Open"
	prompt.ObjectText = "Flotsam"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.HoldDuration = FlotsamConfig.PromptHoldDuration
	prompt.MaxActivationDistance = FlotsamConfig.PromptDistance
	prompt.RequiresLineOfSight = false
	prompt.Style = Enum.ProximityPromptStyle.Default
	prompt.Parent = host
	return prompt
end

------------------------------------------------------------------------------
-- Claim flow
------------------------------------------------------------------------------

function FlotsamService:_handleClaim(crateId: number, player: Player)
	local info = self._activeCrates[crateId]
	if not info then
		return -- already claimed/despawned this tick
	end

	-- Atomic claim guard: first-come, first-served. The attribute write is
	-- synchronous, so a same-frame second triggerer reads the existing value
	-- and bails out.
	local model = info.model
	if model:GetAttribute("ClaimedBy") ~= nil then
		return
	end
	model:SetAttribute("ClaimedBy", player.UserId)

	-- Anti-spoof: validate the claimer's character is actually near the crate.
	-- ProximityPrompt enforces this client-side already, but a malicious
	-- client could fire the prompt's underlying signal directly. Keep the
	-- server check tight but with a small slack for one network frame.
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if hrp then
		local dist = (hrp.Position - info.position).Magnitude
		if dist > FlotsamConfig.ClaimMaxDistance then
			model:SetAttribute("ClaimedBy", nil)
			DevLog.log(string.format(
				"[FlotsamService] Rejected claim by %s (distance %.1f > %d)",
				player.Name, dist, FlotsamConfig.ClaimMaxDistance))
			return
		end
	end

	-- Roll + grant
	local reward = self:_rollReward()
	local granted = self:_grantReward(player, reward)

	if FlotsamConfig.VerboseLogging then
		DevLog.log(string.format(
			"[FlotsamService] Claimed crate %d by %s -> %s%s",
			crateId, player.Name, self:_describeReward(reward),
			granted and "" or " (grant FAILED)"))
	end

	-- Despawn the crate. Maintenance loop will respawn a replacement.
	self._activeCrates[crateId] = nil
	model:Destroy()
end

--- Weighted-random pick from the configured reward table.
function FlotsamService:_rollReward()
	local rewards = FlotsamConfig.Rewards
	local totalWeight = 0
	for _, r in ipairs(rewards) do
		totalWeight += r.weight
	end
	if totalWeight <= 0 then
		return rewards[1] -- defensive fallback
	end
	local pick = self._rng:NextNumber() * totalWeight
	local acc = 0
	for _, r in ipairs(rewards) do
		acc += r.weight
		if pick <= acc then
			return r
		end
	end
	return rewards[#rewards]
end

--- Route the rolled reward to the right grant pipeline. Returns whether the
--- grant succeeded so the claim log can flag failures.
function FlotsamService:_grantReward(player: Player, reward: any): boolean
	local kind = reward.kind
	if kind == "Cash" then
		local amount = tonumber(reward.amount) or 0
		if amount <= 0 then
			return false
		end
		self._oilStateService:AddCash(player.UserId, amount)
		self._oilStateService:PushState(player.UserId)
		return true
	end
	-- Future: "Equipment" -> EquipmentShopService:GrantFreeOwnedEquipment, etc.
	warn(string.format("[FlotsamService] Unknown reward kind %q — no grant performed.", tostring(kind)))
	return false
end

function FlotsamService:_describeReward(reward: any): string
	if reward.kind == "Cash" then
		return string.format("$%d cash", tonumber(reward.amount) or 0)
	end
	return tostring(reward.kind)
end

return FlotsamService
