--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local BiomeConfig = require(Shared:WaitForChild("Config"):WaitForChild("BiomeConfig"))

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
	if not state then return end
	local ground = plot:FindFirstChild("PlotGround")
	if not (ground and ground:IsA("Model")) then return end
	for _, sectionModel in ipairs(ground:GetChildren()) do
		if sectionModel:IsA("Model") then
			local chunkId = sectionModel:GetAttribute("ChunkId")
			if typeof(chunkId) == "string" then
				local chunk = state.chunksById[chunkId]
				if chunk then
					self:_applyChunkVisual(sectionModel, chunk)
				end
			end
		end
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

function ChunkOwnershipService:_applyChunkVisual(sectionModel: Model, chunk)
	local overlay = sectionModel:FindFirstChild("LockOverlay")
	local sign = sectionModel:FindFirstChild("Sign")

	if chunk.unlocked and chunk.revealed then
		-- REVEALED: apply biome materials/colors to tiles + spawn obstacles
		if overlay and overlay:IsA("BasePart") then
			overlay.Transparency = 1 -- hide overlay
		end
		if sign then
			self:_setSignVisible(sign, false, nil)
		end

		-- Apply per-tile materials/colors from tile type data
		if chunk.tiles then
			for _, child in ipairs(sectionModel:GetChildren()) do
				if child:IsA("BasePart") and child.Name:match("^T%d%d$") then
					local tileData = chunk.tiles[child.Name]
					if tileData then
						-- Apply tile-specific material + color
						local matName = tileData.tileMaterial
						if matName and Enum.Material[matName] then
							child.Material = Enum.Material[matName]
						end
						if tileData.tileColorR and tileData.tileColorG and tileData.tileColorB then
							child.Color = Color3.fromRGB(tileData.tileColorR, tileData.tileColorG, tileData.tileColorB)
						end
					end
				end
			end
		end

		-- Spawn obstacle models on tiles that have them
		if chunk.tiles then
			self:_syncObstacles(sectionModel, chunk)
		end

	elseif not chunk.unlocked then
		-- LOCKED: show dark fog + buy sign
		if overlay and overlay:IsA("BasePart") then
			overlay.Transparency = FOG_TRANSPARENCY
			overlay.Color = FOG_COLOR
			overlay.Material = Enum.Material.Neon
		end
		-- Make all tiles dark/hidden under the fog
		for _, child in ipairs(sectionModel:GetChildren()) do
			if child:IsA("BasePart") and child.Name:match("^T%d%d$") then
				child.Material = Enum.Material.SmoothPlastic
				child.Color = Color3.fromRGB(30, 30, 38)
			end
		end
		if sign then
			local cost = self:_costFor(nil, chunk)
			self:_setSignVisible(sign, true, cost)
			-- Update sign text to show "?" instead of biome name
			for _, d in ipairs(sign:GetDescendants()) do
				if d:IsA("TextLabel") and d.Name == "CostLabel" then
					d.Text = string.format("? BUY: $%d", cost)
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
				descendant.Text = string.format("? BUY: $%d", cost)
			end
		end
	end
end

function ChunkOwnershipService:_syncObstacles(sectionModel: Model, chunk)
	if not chunk.tiles then return end

	local assetsFolder = ReplicatedStorage:FindFirstChild("Assets")
	if not assetsFolder then return end

	-- Remove existing obstacle models first and restore hidden water tiles
	for _, child in ipairs(sectionModel:GetChildren()) do
		if child:GetAttribute("IsObstacle") then
			-- If this was a water obstacle, restore the original tile visibility
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

	-- Spawn new obstacles
	for tileKey, tile in pairs(chunk.tiles) do
		if tile.hasObstacle and tile.obstacleType then
			local templateName = BiomeConfig.ObstacleTemplates[tile.obstacleType]
			local template = templateName and assetsFolder:FindFirstChild(templateName)

			-- Find the tile BasePart to get its position
			local tilePart = sectionModel:FindFirstChild(tileKey)
			if tilePart and tilePart:IsA("BasePart") then
				-- Water obstacles REPLACE the tile entirely instead of sitting on top
				if BiomeConfig.IsPipesOnlyObstacle(tile.obstacleType) and template then
					-- Hide the original tile
					tilePart.Transparency = 1

					-- Clone the water block(s) from template
					local waterParts = {}
					if template:IsA("Folder") or template:IsA("Model") then
						for _, child in ipairs(template:GetChildren()) do
							if child:IsA("BasePart") then
								table.insert(waterParts, child)
							end
						end
					elseif template:IsA("BasePart") then
						table.insert(waterParts, template)
					end

					for _, waterTemplate in ipairs(waterParts) do
						local waterClone = waterTemplate:Clone()
						waterClone.Name = "Obstacle_" .. tileKey
						waterClone.Anchored = true
						waterClone.CanCollide = true
						waterClone:SetAttribute("IsObstacle", true)
						waterClone:SetAttribute("TileKey", tileKey)
						waterClone:SetAttribute("ChunkId", chunk.chunkId)
						waterClone:SetAttribute("ObstacleType", tile.obstacleType)
						-- Position at tile level (replace, not on top)
						waterClone.Size = Vector3.new(tilePart.Size.X, waterTemplate.Size.Y, tilePart.Size.Z)
						waterClone.Position = tilePart.Position + Vector3.new(0, (waterTemplate.Size.Y - tilePart.Size.Y) / 2, 0)
						waterClone.Parent = sectionModel
					end
				else
					-- Normal obstacles: spawn on top of tile
					local obstacle
					if template then
						obstacle = template:Clone()
					else
						-- Fallback: generic rock
						obstacle = Instance.new("Part")
						obstacle.Shape = Enum.PartType.Ball
						obstacle.Size = Vector3.new(4, 3, 4)
						obstacle.Material = Enum.Material.Rock
						obstacle.Color = Color3.fromRGB(100, 95, 88)
					end

					obstacle.Name = "Obstacle_" .. tileKey
					obstacle:SetAttribute("IsObstacle", true)
					obstacle:SetAttribute("TileKey", tileKey)
					obstacle:SetAttribute("ChunkId", chunk.chunkId)
					obstacle:SetAttribute("ObstacleType", tile.obstacleType)

					if obstacle:IsA("BasePart") then
						obstacle.Anchored = true
						obstacle.CanCollide = true
						obstacle.CanQuery = true
						obstacle.Position = tilePart.Position + Vector3.new(0, obstacle.Size.Y / 2 + tilePart.Size.Y / 2, 0)
					elseif obstacle:IsA("Model") then
						obstacle:PivotTo(CFrame.new(tilePart.Position + Vector3.new(0, 2, 0)))
					end

					-- Add clear prompt (not for water — water can't be cleared)
					local promptHost = obstacle:IsA("BasePart") and obstacle or obstacle:FindFirstChildWhichIsA("BasePart")
					if promptHost then
						local biomeName = chunk.biome or "Dustlands"
						local cost = BiomeConfig.GetObstacleCost(biomeName, tile.obstacleType)
						local prompt = Instance.new("ProximityPrompt")
						prompt.Name = "ClearPrompt"
						prompt.ActionText = string.format("Clear ($%d)", cost)
						prompt.ObjectText = tile.obstacleType
						prompt.HoldDuration = 0.5
						prompt.MaxActivationDistance = 12
						prompt.RequiresLineOfSight = false
						prompt.Parent = promptHost
					end

					obstacle.Parent = sectionModel
				end
			end
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
