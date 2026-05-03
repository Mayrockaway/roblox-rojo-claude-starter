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

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local FlotsamConfig = require(Shared:WaitForChild("Config"):WaitForChild("FlotsamConfig"))
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))
local DevLog = require(Shared:WaitForChild("DevLog"))

local FlotsamService = {}

type CrateInfo = {
	model: Model,
	position: Vector3,
	spawnedAt: number,
	templateName: string,
	connection: RBXScriptConnection?,
}

function FlotsamService:Init(oilStateService)
	self._oilStateService = oilStateService
	self._straitStateService = nil
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
	self._currentTargetCrates = FlotsamConfig.MaxActiveCrates
end

function FlotsamService:SetStraitStateService(straitStateService)
	self._straitStateService = straitStateService
end

--- Roll a random crate count for the current strait state.
function FlotsamService:_rollTargetCrateCount(): number
	local state = "Open"
	if self._straitStateService then
		state = self._straitStateService:GetCurrentState() or "Open"
	end
	local range = FlotsamConfig.CrateCountRanges and FlotsamConfig.CrateCountRanges[state]
	if range then
		return self._rng:NextInteger(range.min, range.max)
	end
	return FlotsamConfig.MaxActiveCrates
end

function FlotsamService:SetEquipmentShopService(equipmentShopService)
	self._equipmentShopService = equipmentShopService
end

function FlotsamService:SetWarehouseService(warehouseService)
	self._warehouseService = warehouseService
end

function FlotsamService:SetRemoteService(remoteService)
	self._remoteService = remoteService
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
	self._recycling = false
	self._currentTargetCrates = self:_rollTargetCrateCount()
	self._lastRecycledState = nil :: string? -- debounce: don't recycle if state didn't change

	-- Maintenance loop: keeps `MaxActiveCrates` alive at all times. Lazily
	-- tops up after pickups instead of pre-scheduling per-crate respawn
	-- timers — simpler, and the tick cadence (5s default) is fine for the
	-- "swim, grab, swim back to next" pacing.
	task.spawn(function()
		while self._running do
			if not self._recycling then
				self:_maintainSpawns()
			end
			task.wait(FlotsamConfig.MaintenanceTickSeconds)
		end
	end)

	-- Listen for strait state changes — despawn all crates (sink animation)
	-- and respawn with new tier weights.
	-- Record initial state so first broadcast doesn't trigger a recycle
	self._lastRecycledState = self._straitStateService and self._straitStateService:GetCurrentState() or "Open"

	if self._straitStateService then
		self._straitStateService:OnStateChanged(function(snapshot)
			local newState = snapshot and snapshot.state or "?"

			-- Debounce: skip if state hasn't actually changed
			if newState == self._lastRecycledState then
				return
			end
			if self._recycling then
				return
			end

			self._recycling = true
			self._lastRecycledState = newState
			self._currentTargetCrates = self:_rollTargetCrateCount()
			DevLog.log("[FlotsamService] Strait changed to " .. tostring(newState) .. " — recycling. New target: " .. self._currentTargetCrates .. " crates.")

			self:_destroyAllCrates()
			task.wait(1)
			self:_maintainSpawns()

			local newCount = 0
			for _ in pairs(self._activeCrates) do newCount += 1 end
			DevLog.log("[FlotsamService] Recycle complete. Active crates: " .. newCount)
			self._recycling = false
		end)
	end

	DevLog.log(string.format(
		"[FlotsamService] Started. Target crates: %d. Ocean center: %s",
		self._currentTargetCrates, tostring(ocean.Position)))
end

------------------------------------------------------------------------------
-- Maintenance + spawning
------------------------------------------------------------------------------

function FlotsamService:_maintainSpawns()
	local count = 0
	for _ in pairs(self._activeCrates) do
		count += 1
	end

	local target = self._currentTargetCrates or FlotsamConfig.MaxActiveCrates
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

--- Pick a crate tier based on the current strait state and configured weights.
function FlotsamService:_rollCrateTier(): (string, string)
	local state = "Open"
	if self._straitStateService then
		state = self._straitStateService:GetCurrentState() or "Open"
	end
	local weights = FlotsamConfig.CrateSpawnWeights[state] or FlotsamConfig.CrateSpawnWeights.Open
	local tiers = FlotsamConfig.CrateTiers

	local totalWeight = 0
	for _, w in ipairs(weights) do
		totalWeight += w
	end
	local pick = self._rng:NextNumber() * totalWeight
	local acc = 0
	for i, w in ipairs(weights) do
		acc += w
		if pick <= acc and tiers[i] then
			return tiers[i].templateName, tiers[i].displayName
		end
	end
	return tiers[1].templateName, tiers[1].displayName
end

function FlotsamService:_spawnOneCrate(): boolean
	local position = self:_findRandomSpawnPoint()
	if not position then
		return false
	end

	local templateName, displayName = self:_rollCrateTier()
	local model = self:_buildCrateModel(templateName)
	if not model then
		warn("[FlotsamService] Failed to build crate model for " .. templateName)
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
	local promptConn: RBXScriptConnection? = nil
	if prompt then
		promptConn = prompt.Triggered:Connect(function(player)
			self:_handleClaim(crateId, player)
		end)
	end

	model.Parent = self._runtimeFolder

	self._activeCrates[crateId] = {
		model = model,
		position = position,
		spawnedAt = workspace:GetServerTimeNow(),
		templateName = templateName,
		connection = promptConn,
	}

	if FlotsamConfig.VerboseLogging then
		DevLog.log(string.format("[FlotsamService] Spawned %s (crate %d) at %s", displayName, crateId, tostring(position)))
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

--- Destroy all active crates instantly. Called on strait state change.
function FlotsamService:_destroyAllCrates()
	for _, info in pairs(self._activeCrates) do
		if info.connection then
			info.connection:Disconnect()
		end
		if info.model and info.model.Parent then
			info.model:Destroy()
		end
	end
	self._activeCrates = {}
end

--- Clone the named crate template from ServerStorage.FlotsamCrates.
--- Falls back to old FlotsamCrateTemplate, then to a placeholder box.
function FlotsamService:_buildCrateModel(templateName: string?): Model?
	local name = templateName or "BaseCrate"

	-- Primary: look in FlotsamCrates folder
	local folder = ServerStorage:FindFirstChild("FlotsamCrates")
	local template = folder and folder:FindFirstChild(name)

	-- Fallback: legacy single-template location
	if not template then
		template = ServerStorage:FindFirstChild("FlotsamCrateTemplate")
	end

	if template and template:IsA("Model") then
		local clone = template:Clone()
		clone.Name = "FlotsamCrate_" .. name
		for _, d in ipairs(clone:GetDescendants()) do
			if d:IsA("BasePart") then
				d.Anchored = true
				d.CanCollide = false
			end
		end
		return clone
	end

	-- Placeholder: brown wood cube for testing
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
	local tierInfo = nil
	for _, t in ipairs(FlotsamConfig.CrateTiers) do
		if model.Name == "FlotsamCrate_" .. t.templateName then
			tierInfo = t
			break
		end
	end
	prompt.ActionText = "Open"
	prompt.ObjectText = tierInfo and tierInfo.displayName or "Crate"
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

	-- Roll + grant using tier-specific reward table
	local reward = self:_rollReward(info.templateName)
	local granted = self:_grantReward(player, reward)

	-- Fire client UI for the crate opening carousel
	if granted then
		self:_fireClientReward(player, info.templateName, reward)
		-- Mark first crate claimed so the "FREE LOOT!" pointer never shows again
		pcall(function()
			self._oilStateService:MarkFlotsamCratePointerDone(player.UserId)
		end)
	end

	if FlotsamConfig.VerboseLogging then
		DevLog.log(string.format(
			"[FlotsamService] Claimed %s (crate %d) by %s -> %s%s",
			info.templateName, crateId, player.Name, self:_describeReward(reward),
			granted and "" or " (grant FAILED)"))
	end

	-- Despawn the crate. Maintenance loop will respawn a replacement.
	if info.connection then
		info.connection:Disconnect()
	end
	self._activeCrates[crateId] = nil
	model:Destroy()
end

--- Weighted-random pick from the tier-specific reward table.
function FlotsamService:_rollReward(templateName: string?)
	local name = templateName or "BaseCrate"
	local rewards = FlotsamConfig.Rewards[name] or FlotsamConfig.Rewards.BaseCrate
	local totalWeight = 0
	for _, r in ipairs(rewards) do
		totalWeight += r.weight
	end
	if totalWeight <= 0 then
		return rewards[1]
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
		if amount <= 0 then return false end
		self._oilStateService:AddCash(player.UserId, amount)
		self._oilStateService:PushState(player.UserId)
		return true
	elseif kind == "Drill" then
		if not self._equipmentShopService then
			warn("[FlotsamService] EquipmentShopService not injected — cannot grant drill.")
			return false
		end
		local drillId = reward.drillId
		local qty = tonumber(reward.qty) or 1
		self._equipmentShopService:GrantFreeOwnedEquipment(player, drillId, qty)
		return true
	elseif kind == "Oil" then
		if not self._warehouseService then
			warn("[FlotsamService] WarehouseService not injected — cannot grant oil.")
			return false
		end
		local oilType = reward.oilType
		local qty = tonumber(reward.qty) or 1
		local manifest = { [oilType] = qty }
		self._warehouseService:DeliverHitBarrels(player.UserId, manifest)
		return true
	end
	warn(string.format("[FlotsamService] Unknown reward kind %q — no grant performed.", tostring(kind)))
	return false
end

--- Fire the client remote so the crate opener UI shows the reward.
function FlotsamService:_fireClientReward(player: Player, crateTier: string, reward: any)
	if not self._remoteService then
		warn("[FlotsamService] _remoteService not injected — cannot fire client reward.")
		return
	end
	local ok, err = pcall(function()
		local event = self._remoteService:GetEvent(RemoteNames.FlotsamCrateReward)
		event:FireClient(player, {
			crateTier = crateTier,
			reward = reward,
		})
	end)
	if not ok then
		warn("[FlotsamService] Failed to fire FlotsamCrateReward: " .. tostring(err))
	end
end

function FlotsamService:_describeReward(reward: any): string
	if reward.kind == "Cash" then
		return string.format("$%d cash", tonumber(reward.amount) or 0)
	elseif reward.kind == "Drill" then
		return string.format("%dx %s", tonumber(reward.qty) or 1, tostring(reward.drillId))
	elseif reward.kind == "Oil" then
		return string.format("%dx %s oil", tonumber(reward.qty) or 1, tostring(reward.oilType))
	end
	return tostring(reward.kind)
end

return FlotsamService
