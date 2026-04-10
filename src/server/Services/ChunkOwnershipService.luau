--!strict

local ChunkOwnershipService = {}

local LOCKED_OVERLAY_TRANS = 0.55
local UNLOCKED_OVERLAY_TRANS = 1

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
	if not plot then
		return
	end
	local sectionModel = self._plotService:GetChunkModel(plot, chunkId)
	if not sectionModel then
		return
	end
	local state = self._oilStateService:GetState(userId)
	if not state then
		return
	end
	local chunk = state.chunksById[chunkId]
	if not chunk then
		return
	end
	local cost = nil
	if not chunk.unlocked then
		cost = self:_costFor(state, chunk)
	end
	self:_applyChunkVisual(sectionModel, chunk.unlocked, cost)
end

function ChunkOwnershipService:_refreshAll(userId: number, plot: Model)
	local state = self._oilStateService:GetState(userId)
	if not state then
		return
	end
	local ground = plot:FindFirstChild("PlotGround")
	if not (ground and ground:IsA("Model")) then
		return
	end
	for _, sectionModel in ipairs(ground:GetChildren()) do
		if sectionModel:IsA("Model") then
			local chunkId = sectionModel:GetAttribute("ChunkId")
			if typeof(chunkId) == "string" then
				local chunk = state.chunksById[chunkId]
				local unlocked = chunk and chunk.unlocked or false
				local cost = nil
				if chunk and not chunk.unlocked then
					cost = self:_costFor(state, chunk)
				end
				self:_applyChunkVisual(sectionModel, unlocked, cost)
			end
		end
	end
end

function ChunkOwnershipService:_costFor(_state, chunk): number
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local OilConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("OilConfig"))
	local rd = math.abs(chunk.row - OilConfig.Chunks.StartingRow)
	local cd = math.abs(chunk.col - OilConfig.Chunks.StartingCol)
	local dist = math.max(rd, cd)
	if dist <= 0 then
		return 0
	end
	return math.max(0, math.floor(OilConfig.ChunkUnlockBaseCost * (1 + (dist - 1) * OilConfig.ChunkUnlockDistanceMultiplier)))
end

local function setSignVisible(sign: Instance, visible: boolean, cost: number?)
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

function ChunkOwnershipService:_applyChunkVisual(sectionModel: Model, unlocked: boolean, cost: number?)
	local overlay = sectionModel:FindFirstChild("LockOverlay")
	local sign = sectionModel:FindFirstChild("Sign")

	if unlocked then
		if overlay and overlay:IsA("BasePart") then
			overlay.Transparency = UNLOCKED_OVERLAY_TRANS
		end
		if sign then
			setSignVisible(sign, false, nil)
		end
	else
		if overlay and overlay:IsA("BasePart") then
			overlay.Transparency = LOCKED_OVERLAY_TRANS
		end
		if sign then
			setSignVisible(sign, true, cost)
		end
	end
end

function ChunkOwnershipService:_resetPlotVisuals(plot: Model)
	local ground = plot:FindFirstChild("PlotGround")
	if not (ground and ground:IsA("Model")) then
		return
	end
	for _, sectionModel in ipairs(ground:GetChildren()) do
		if sectionModel:IsA("Model") then
			local overlay = sectionModel:FindFirstChild("LockOverlay")
			if overlay and overlay:IsA("BasePart") then
				overlay.Transparency = LOCKED_OVERLAY_TRANS
			end
			local sign = sectionModel:FindFirstChild("Sign")
			if sign then
				setSignVisible(sign, true, nil)
			end
		end
	end
end

return ChunkOwnershipService
