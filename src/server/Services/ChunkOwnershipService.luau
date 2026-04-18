--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local BiomeConfig = require(Shared:WaitForChild("Config"):WaitForChild("BiomeConfig"))
local DevLog = require(Shared:WaitForChild("DevLog"))

local ChunkOwnershipService = {}

local FOG_COLOR = Color3.fromRGB(20, 20, 30)
local FOG_TRANSPARENCY = 0.1

function ChunkOwnershipService:Init(plotService, oilStateService)
	self._plotService = plotService
	self._oilStateService = oilStateService
	self._connections = {}
end

function ChunkOwnershipService:Start()
	table.insert(self._connections, self._plotService:OnPlotAssigned(function(userId: number, plot: Model)
		task.defer(function()
			self:_refreshAll(userId, plot)
		end)
	end))

	table.insert(self._connections, self._plotService:OnPlotReleased(function(_userId: number, plot: Model)
		self:_resetPlotVisuals(plot)
	end))

	table.insert(self._connections, self._oilStateService:OnStateChanged(function(userId: number, _snapshot)
		local plot = self._plotService:GetOwnedPlot(userId)
		if plot then
			self:_refreshAll(userId, plot)
		end
	end))

	for _, player in ipairs(Players:GetPlayers()) do
		local plot = self._plotService:GetOwnedPlot(player.UserId)
		if plot then
			task.defer(function()
				self:_refreshAll(player.UserId, plot)
			end)
		end
	end
end

function ChunkOwnershipService:Stop()
	for _, c in ipairs(self._connections) do
		c:Disconnect()
	end
	self._connections = {}
end

function ChunkOwnershipService:RefreshChunk(userId: number, chunkId: string)
	local plot = self._plotService:GetOwnedPlot(userId)
	if not plot then return end
	local sectionModel = self._plotService:GetChunkModel(plot, chunkId)
	if not sectionModel then return end
	local state = self._oilStateService:GetState(userId)
	if not state then return end
	local chunk = state.chunksById[chunkId]
	if not chunk then return end
	self:_applyChunkVisual(sectionModel, chunk)
end

function ChunkOwnershipService:_refreshAll(userId: number, plot: Model)
	local state = self._oilStateService:GetState(userId)
	if not state then
		DevLog.log(string.format("[ChunkOwnership] _refreshAll user=%d plot=%s: no state", userId, plot.Name))
		return
	end
	local ground = plot:FindFirstChild("PlotGround")
	if not (ground and ground:IsA("Model")) then
		DevLog.log(string.format("[ChunkOwnership] _refreshAll user=%d plot=%s: no PlotGround", userId, plot.Name))
		return
	end
	local applied, missed = 0, 0
	for _, sectionModel in ipairs(ground:GetChildren()) do
		if sectionModel:IsA("Model") then
			local chunkId = sectionModel:GetAttribute("ChunkId")
			if typeof(chunkId) == "string" then
				local chunk = state.chunksById[chunkId]
				if chunk then
					self:_applyChunkVisual(sectionModel, chunk)
					applied += 1
				else
					missed += 1
				end
			end
		end
	end
	-- High-frequency log removed: was firing every snapshot tick and drowning the output.
	-- If you need to debug chunk ownership, wrap this in a dev flag.
	if missed > 0 then
		DevLog.log(string.format("[ChunkOwnership] user=%d plot=%s applied=%d missed=%d (has misses)",
			userId, plot.Name, applied, missed))
	end
end

function ChunkOwnershipService:_costFor(_state, chunk): number
	local OilConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("OilConfig"))
	local rd = math.abs(chunk.row - OilConfig.Chunks.StartingRow)
	local cd = math.abs(chunk.col - OilConfig.Chunks.StartingCol)
	local dist = math.max(rd, cd)
	if dist <= 0 then return 0 end
	return math.max(0, math.floor(OilConfig.ChunkUnlockBaseCost * (1 + (dist - 1) * OilConfig.ChunkUnlockDistanceMultiplier)))
end

-- Idempotent property setters: writing the same value still triggers engine repaint
-- and network replication, which caused the "grass texture pop" every PushState.
-- These helpers skip the assignment when the value is unchanged.
local function setPartMaterial(part: BasePart, mat: Enum.Material)
	if part.Material ~= mat then part.Material = mat end
end
local function setPartColor(part: BasePart, color: Color3)
	if part.Color ~= color then part.Color = color end
end
local function setPartTransparency(part: BasePart, t: number)
	if part.Transparency ~= t then part.Transparency = t end
end
local function setAttrIfDiff(inst: Instance, name: string, value: any)
	if inst:GetAttribute(name) ~= value then inst:SetAttribute(name, value) end
end

function ChunkOwnershipService:_applyChunkVisual(sectionModel: Model, chunk)
	local overlay = sectionModel:FindFirstChild("LockOverlay")
	local sign = sectionModel:FindFirstChild("Sign")

	if chunk.unlocked then
		-- UNLOCKED: apply ground type colors to tiles (revealed immediately, no animation)
		if overlay and overlay:IsA("BasePart") then
			setPartTransparency(overlay, 1) -- hide overlay
		end
		if sign then
			self:_setSignVisible(sign, false, nil)
		end

		-- Apply per-tile materials/colors from tile type data + decorations
		if chunk.tiles then
			for _, child in ipairs(sectionModel:GetChildren()) do
				if child:IsA("BasePart") and child.Name:match("^T%d%d$") then
					local tileData = chunk.tiles[child.Name]
					if tileData then
						-- Drilled dry-hole tile (revealed, no oil) → render as dirt patch
						if tileData.drilled and tileData.hasOil == false and not tileData.revealPending then
							setPartMaterial(child, Enum.Material.Ground)
							setPartColor(child, Color3.fromRGB(72, 50, 30))
						else
							-- All tiles use ground type color (sand-colored per row)
							local matName = tileData.tileMaterial
							if matName and Enum.Material[matName] then
								setPartMaterial(child, Enum.Material[matName])
							end
							if tileData.tileColorR and tileData.tileColorG and tileData.tileColorB then
								setPartColor(child, Color3.fromRGB(tileData.tileColorR, tileData.tileColorG, tileData.tileColorB))
							end
						end
						-- Tag attributes so the client tooltip can show HAS OIL / NO OIL once prospected
						setAttrIfDiff(child, "TileName", tileData.tileName)
						setAttrIfDiff(child, "OilType", tileData.oilType)
						setAttrIfDiff(child, "Drilled", tileData.drilled == true)
						setAttrIfDiff(child, "HasOil", tileData.hasOil ~= false)
						setAttrIfDiff(child, "Prospected", chunk.prospected == true)
						self:_applyTileDecorations(child, tileData)

						-- Clean up any old highlight from earlier versions
						local hl = child:FindFirstChild("OilHighlight")
						if hl then hl:Destroy() end
					end
				end
			end
		end

		-- Obstacle spawn removed; clean up any leftover obstacle models from earlier builds
		self:_syncObstacles(sectionModel, chunk)

	elseif not chunk.unlocked then
		-- LOCKED: show ground type color (no black fog), keep buy sign
		local VeinConfig = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("VeinConfig"))
		local groundType = VeinConfig.GroundByRow[chunk.row] or VeinConfig.GroundTypes.Bronze

		if overlay and overlay:IsA("BasePart") then
			setPartTransparency(overlay, 1) -- no overlay
		end
		-- Show tiles in ground type color (visible, not hidden)
		for _, child in ipairs(sectionModel:GetChildren()) do
			if child:IsA("BasePart") and child.Name:match("^T%d%d$") then
				setPartMaterial(child, groundType.material)
				setPartColor(child, groundType.color)
			end
		end
		if sign then
			local cost = self:_costFor(nil, chunk)
			self:_setSignVisible(sign, true, cost)
			for _, d in ipairs(sign:GetDescendants()) do
				if d:IsA("TextLabel") and d.Name == "CostLabel" then
					d.Text = string.format("BUY: $%d", cost)
				end
			end
		end
	end
end

function ChunkOwnershipService:_setSignVisible(sign: Instance, visible: boolean, cost: number?)
	for _, descendant in ipairs(sign:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Transparency = visible and 0 or 1
		elseif descendant:IsA("ProximityPrompt") then
			descendant.Enabled = visible
			if visible and cost then
				descendant.ObjectText = string.format("$%d", cost)
			end
		elseif descendant:IsA("SurfaceGui") then
			descendant.Enabled = visible
		elseif descendant:IsA("TextLabel") and descendant.Name == "CostLabel" then
			if visible and cost then
				descendant.Text = string.format("BUY: $%d", cost)
			end
		end
	end
end

-- Obstacle system removed. Any lingering obstacle Parts left over from prior plots are
-- cleaned up here so old worlds don't keep rocks/pillars stuck to tiles.
-- Per-tile 3D decorations: flowers, tall grass, crack decals, magma bubbles, lake water.
-- Decorations are children of the tile Part with Name = "TileDecoration" so we can purge
-- them cleanly when the tile is drilled or the tile type changes.
local TILE_DECO_NAME = "TileDecoration"

local function clearTileDecorations(tilePart: BasePart)
	for _, child in ipairs(tilePart:GetChildren()) do
		if child.Name == TILE_DECO_NAME then
			child:Destroy()
		end
	end
end

local function buildFlower(pos: Vector3, rng: Random): Model
	local m = Instance.new("Model")
	m.Name = TILE_DECO_NAME
	local stem = Instance.new("Part")
	stem.Name = "Stem"
	stem.Shape = Enum.PartType.Cylinder
	stem.Size = Vector3.new(1.2, 0.18, 0.18)
	stem.Material = Enum.Material.Grass
	stem.Color = Color3.fromRGB(20, 130, 30)
	stem.Anchored = true; stem.CanCollide = false; stem.CanQuery = false; stem.CanTouch = false; stem.CastShadow = false
	stem.CFrame = CFrame.new(pos) * CFrame.Angles(0, 0, math.rad(90))
	stem.Parent = m
	local petal = Instance.new("Part")
	petal.Name = "Petal"
	petal.Shape = Enum.PartType.Ball
	petal.Size = Vector3.new(0.65, 0.65, 0.65)
	local flowerColors = {
		Color3.fromRGB(255, 120, 180),
		Color3.fromRGB(255, 230, 90),
		Color3.fromRGB(230, 140, 255),
		Color3.fromRGB(255, 160, 90),
		Color3.fromRGB(255, 255, 255),
	}
	petal.Color = flowerColors[rng:NextInteger(1, #flowerColors)]
	petal.Material = Enum.Material.Neon
	petal.Anchored = true; petal.CanCollide = false; petal.CanQuery = false; petal.CanTouch = false; petal.CastShadow = false
	petal.Position = pos + Vector3.new(0, 0.8, 0)
	petal.Parent = m
	m.Parent = nil
	return m
end

local function buildTallGrassBlade(pos: Vector3, rng: Random): BasePart
	local p = Instance.new("Part")
	p.Name = TILE_DECO_NAME
	p.Size = Vector3.new(0.25, 2.2 + rng:NextNumber() * 0.8, 0.25)
	p.Material = Enum.Material.Grass
	p.Color = Color3.fromRGB(25, 140, 20):Lerp(Color3.fromRGB(60, 180, 40), rng:NextNumber())
	p.Anchored = true; p.CanCollide = false; p.CanQuery = false; p.CanTouch = false; p.CastShadow = false
	p.CFrame = CFrame.new(pos + Vector3.new(0, p.Size.Y / 2, 0)) * CFrame.Angles(math.rad(rng:NextNumber(-10, 10)), math.rad(rng:NextNumber(0, 360)), math.rad(rng:NextNumber(-10, 10)))
	return p
end

function ChunkOwnershipService:_applyTileDecorations(tilePart: BasePart, tileData: any)
	-- Always clear first — idempotent (fresh chunk state)
	clearTileDecorations(tilePart)
	-- Only strip decorations for DRY HOLES (drilled + no oil = dirt patch).
	-- Drilled tiles with oil keep their visual (sand textures, obsidian decals, etc.) because
	-- the oil is spraying, not because the tile has become dirt.
	if tileData.drilled and tileData.hasOil == false then return end

	local tileName = tileData.tileName
	if not tileName then return end
	local topY = tilePart.Position.Y + tilePart.Size.Y / 2
	local topC = Vector3.new(tilePart.Position.X, topY, tilePart.Position.Z)

	-- Seed per-tile so decorations are stable between re-syncs
	local rng = Random.new(math.floor(tilePart.Position.X * 7.31 + tilePart.Position.Z * 13.17))

	if tileName == "Flower Patch Grass" then
		local count = rng:NextInteger(3, 5)
		for i = 1, count do
			local off = Vector3.new(rng:NextNumber(-2.5, 2.5), 0, rng:NextNumber(-2.5, 2.5))
			local m = buildFlower(topC + off, rng)
			m.Parent = tilePart
		end

	elseif tileName == "Tall Grass" then
		for _ = 1, rng:NextInteger(6, 10) do
			local off = Vector3.new(rng:NextNumber(-3, 3), 0, rng:NextNumber(-3, 3))
			local blade = buildTallGrassBlade(topC + off, rng)
			blade.Parent = tilePart
		end

	elseif tileName == "Cracked Stone" then
		local d = Instance.new("Decal")
		d.Name = TILE_DECO_NAME
		d.Face = Enum.NormalId.Top
		d.Texture = "rbxasset://textures/terrain/Cracked.png"
		d.Transparency = 0.25
		d.Color3 = Color3.fromRGB(15, 15, 15)
		d.Parent = tilePart

	elseif tileName == "Smooth Sand" then
		-- Material override for a smoother look regardless of config
		tilePart.Material = Enum.Material.Sandstone
		tilePart.Reflectance = 0.06

	elseif tileName == "Magma" then
		-- Replace tile visual with the workspace "lava" asset's look (Neon + lava texture on all faces),
		-- keeping tile dimensions. Plus keep the bubbling particles + point light on top.
		tilePart.Material = Enum.Material.Neon
		tilePart.Color = Color3.fromRGB(255, 0, 0)
		for _, face in ipairs({Enum.NormalId.Top, Enum.NormalId.Bottom, Enum.NormalId.Front, Enum.NormalId.Back, Enum.NormalId.Left, Enum.NormalId.Right}) do
			local d = Instance.new("Decal")
			d.Name = TILE_DECO_NAME
			d.Face = face
			d.Texture = "rbxassetid://4375276355"
			d.Parent = tilePart
		end

		local att = Instance.new("Attachment")
		att.Name = TILE_DECO_NAME
		att.Position = Vector3.new(0, tilePart.Size.Y / 2 + 0.3, 0)
		att.Parent = tilePart

		local emit = Instance.new("ParticleEmitter")
		emit.Texture = "rbxasset://textures/particles/fire_main.dds"
		emit.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 180, 80)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 70, 20)),
		})
		emit.Rate = 40
		emit.Speed = NumberRange.new(3, 6)
		emit.Lifetime = NumberRange.new(0.6, 1.2)
		emit.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.8),
			NumberSequenceKeypoint.new(0.5, 1.6),
			NumberSequenceKeypoint.new(1, 0),
		})
		emit.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.2),
			NumberSequenceKeypoint.new(1, 1),
		})
		emit.LightEmission = 0.8
		emit.EmissionDirection = Enum.NormalId.Top
		emit.Acceleration = Vector3.new(0, -4, 0)
		emit.SpreadAngle = Vector2.new(12, 12)
		emit.Parent = att

		local light = Instance.new("PointLight")
		light.Name = TILE_DECO_NAME
		light.Color = Color3.fromRGB(255, 120, 40)
		light.Brightness = 2.5
		light.Range = 10
		light.Parent = tilePart

	elseif tileName == "Obsidian" then
		-- Replace the flat tile visual with the ObsidianPillar's rock texture on all 6 faces,
		-- keeping the tile's dimensions so the grid stays perfectly aligned.
		tilePart.Material = Enum.Material.Plastic
		tilePart.Color = Color3.fromRGB(163, 162, 165)
		tilePart.Reflectance = 0
		for _, face in ipairs({Enum.NormalId.Top, Enum.NormalId.Bottom, Enum.NormalId.Front, Enum.NormalId.Back, Enum.NormalId.Left, Enum.NormalId.Right}) do
			local d = Instance.new("Decal")
			d.Name = TILE_DECO_NAME
			d.Face = face
			d.Texture = "rbxassetid://146215703"
			d.Parent = tilePart
		end

	elseif tileName == "Sand" then
		-- Use SANDMC's tiling sand texture on all 6 faces
		tilePart.Material = Enum.Material.Plastic
		tilePart.Color = Color3.fromRGB(163, 162, 165)
		for _, face in ipairs({Enum.NormalId.Top, Enum.NormalId.Bottom, Enum.NormalId.Front, Enum.NormalId.Back, Enum.NormalId.Left, Enum.NormalId.Right}) do
			local t = Instance.new("Texture")
			t.Name = TILE_DECO_NAME
			t.Face = face
			t.Texture = "rbxassetid://38349529"
			t.StudsPerTileU = 4
			t.StudsPerTileV = 4
			t.Parent = tilePart
		end

	elseif tileName == "Forrest Lake" or tileName == "Mountain Lake" then
		-- Real water material (ignore config color+material override)
		tilePart.Material = Enum.Material.Water
		tilePart.Transparency = 0.25
		if tileName == "Mountain Lake" then
			tilePart.Color = Color3.fromRGB(20, 90, 110)
		else
			tilePart.Color = Color3.fromRGB(40, 150, 200)
		end
	end
end

function ChunkOwnershipService:_syncObstacles(sectionModel: Model, _chunk)
	for _, child in ipairs(sectionModel:GetChildren()) do
		if child:GetAttribute("IsObstacle") then
			local tk = child:GetAttribute("TileKey")
			if tk then
				local origTile = sectionModel:FindFirstChild(tk)
				if origTile and origTile:IsA("BasePart") and origTile.Transparency >= 1 then
					origTile.Transparency = 0
				end
			end
			child:Destroy()
		end
	end
end

function ChunkOwnershipService:_resetPlotVisuals(plot: Model)
	local ground = plot:FindFirstChild("PlotGround")
	if not (ground and ground:IsA("Model")) then return end
	for _, sectionModel in ipairs(ground:GetChildren()) do
		if sectionModel:IsA("Model") then
			local overlay = sectionModel:FindFirstChild("LockOverlay")
			if overlay and overlay:IsA("BasePart") then
				overlay.Transparency = FOG_TRANSPARENCY
				overlay.Color = FOG_COLOR
			end
			local sign = sectionModel:FindFirstChild("Sign")
			if sign then
				self:_setSignVisible(sign, true, nil)
			end
			-- Remove obstacle models and restore hidden water tiles
			for _, child in ipairs(sectionModel:GetChildren()) do
				if child:GetAttribute("IsObstacle") then
					local tk = child:GetAttribute("TileKey")
					if tk then
						local origTile = sectionModel:FindFirstChild(tk)
						if origTile and origTile:IsA("BasePart") and origTile.Transparency >= 1 then
							origTile.Transparency = 0
						end
					end
					child:Destroy()
				end
			end
		end
	end
end

return ChunkOwnershipService
