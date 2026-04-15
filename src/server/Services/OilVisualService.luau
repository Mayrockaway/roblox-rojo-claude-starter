--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local OilConfig = require(Shared:WaitForChild("Config"):WaitForChild("OilConfig"))
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))
local OilTankConfig = require(Shared:WaitForChild("Config"):WaitForChild("OilTankConfig"))
local PlacementAnchor = require(Shared:WaitForChild("Utils"):WaitForChild("PlacementAnchor"))

local OilVisualService = {}

local DRILL_HEIGHT_OFFSET = 0
local TIER_ORDER = { "HeavyCrude", "LightSweet", "PremiumRefined" }

local function floorPositive(value: number): number
	return math.max(0, math.floor(value))
end

local function clamp(value: number, minValue: number, maxValue: number): number
	return math.max(minValue, math.min(maxValue, value))
end

local function getFirstBasePart(instance: Instance): BasePart?
	if instance:IsA("BasePart") then
		return instance
	end
	for _, child in ipairs(instance:GetDescendants()) do
		if child:IsA("BasePart") then
			return child
		end
	end
	return nil
end

local function anchorAllBaseParts(instance: Instance)
	if instance:IsA("BasePart") then
		instance.Anchored = true
		instance.CanCollide = false
		instance.CanTouch = false
		instance.CanQuery = true
	end
	for _, child in ipairs(instance:GetDescendants()) do
		if child:IsA("BasePart") then
			child.Anchored = true
			child.CanCollide = false
			child.CanTouch = false
			child.CanQuery = true
		end
	end
end

-- Catalog `visualGroundOffsetStuds` (world studs at unit scale) × placed pump scale.
local function pumpTierVisualGroundLiftStuds(tier: any, appliedScale: number): number
	if typeof(tier) ~= "string" then
		return 0
	end
	local tiers = OilConfig.PumpTiers :: { [string]: any }
	local pt = tiers[tier]
	if not pt or typeof(pt.visualGroundOffsetStuds) ~= "number" then
		return 0
	end
	local s = appliedScale
	if typeof(s) ~= "number" or s <= 0 then
		s = 1
	end
	return (pt.visualGroundOffsetStuds :: number) * s
end

local function ensureFolder(parent: Instance, name: string): Folder
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing
	end
	if existing and not existing:IsA("Folder") then
		existing:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local SELL_BACK_PROMPT = "SellBackPrompt"
local SELL_BACK_ATTACH = "SellBackPromptAttachment"

type SellPromptSpec = {
	ownerUserId: number,
	hammerKind: string,
	drillId: number?,
	cellKey: string?,
	drumId: number?,
	prospectId: number?,
}

local sellBackPromptConnections: { [ProximityPrompt]: RBXScriptConnection } = {}
local SELL_BACK_RATE_WINDOW = 2
local SELL_BACK_RATE_MAX = 15
local sellBackRateByUserId: { [number]: { start: number, count: number } } = {}

local function disconnectSellBackPrompt(prompt: ProximityPrompt)
	local c = sellBackPromptConnections[prompt]
	if c then
		c:Disconnect()
		sellBackPromptConnections[prompt] = nil
	end
end

local function sellBackRateAllow(userId: number): boolean
	local now = os.clock()
	local b = sellBackRateByUserId[userId]
	if not b or now - b.start >= SELL_BACK_RATE_WINDOW then
		sellBackRateByUserId[userId] = { start = now, count = 1 }
		return true
	end
	if b.count >= SELL_BACK_RATE_MAX then
		return false
	end
	b.count += 1
	return true
end

local function fireOilActionResult(player: Player, ok: boolean, code: string, message: string, data: any)
	local remotes = Shared:FindFirstChild("Remotes") :: Folder?
	if not remotes then
		return
	end
	local ev = remotes:FindFirstChild(RemoteNames.OilActionResult)
	if ev and ev:IsA("RemoteEvent") then
		ev:FireClient(player, { ok = ok, code = code, message = message, data = data })
	end
end

local function payloadFromSellSpec(spec: SellPromptSpec): any?
	if spec.hammerKind == "pump" or spec.hammerKind == "drill" then
		local id = spec.drillId
		if typeof(id) ~= "number" then
			return nil
		end
		return { targetKind = spec.hammerKind, targetId = id }
	elseif spec.hammerKind == "pipe" then
		if typeof(spec.cellKey) ~= "string" or spec.cellKey == "" then
			return nil
		end
		return { targetKind = "pipe", cellKey = spec.cellKey }
	elseif spec.hammerKind == "drum" then
		local id = spec.drumId
		if typeof(id) ~= "number" then
			return nil
		end
		return { targetKind = "drum", targetId = id }
	elseif spec.hammerKind == "prospector" then
		local id = spec.prospectId
		if typeof(id) ~= "number" then
			return nil
		end
		return { targetKind = "prospector", targetId = id }
	end
	return nil
end

function OilVisualService:_bindSellBackPromptServer(prompt: ProximityPrompt, spec: SellPromptSpec)
	disconnectSellBackPrompt(prompt)
	local oil = self._oilStateService
	sellBackPromptConnections[prompt] = prompt.Triggered:Connect(function(player: Player)
		if player.UserId ~= spec.ownerUserId then
			return
		end
		local payload = payloadFromSellSpec(spec)
		if not payload then
			return
		end
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if not (hrp and hrp:IsA("BasePart")) then
			fireOilActionResult(player, false, "ERR_NO_CHARACTER", "Character not ready.", nil)
			return
		end
		if not oil:IsHammerDestroyInRange(player.UserId, payload, hrp.Position) then
			fireOilActionResult(player, false, "ERR_TOO_FAR", "Move closer to salvage.", nil)
			return
		end
		if not sellBackRateAllow(player.UserId) then
			fireOilActionResult(player, false, "ERR_RATE_LIMIT", "Too many salvage requests.", nil)
			return
		end
		local ok, code, message, data = oil:TryHammerDestroy(player.UserId, payload)
		fireOilActionResult(player, ok, code, message, data)
		if ok then
			oil:PushState(player.UserId)
		end
	end)
end

local function largestBasePart(root: Instance): BasePart?
	local best: BasePart? = nil
	local bestV = 0
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then
			local v = d.Size.X * d.Size.Y * d.Size.Z
			if v > bestV then
				bestV = v
				best = d
			end
		end
	end
	return best
end

local function basePartForSellPrompt(root: Instance): BasePart?
	if not root then
		return nil
	end
	if root:IsA("BasePart") then
		return root
	end
	if root:IsA("Model") then
		local pp = root.PrimaryPart
		if pp then
			return pp
		end
		return largestBasePart(root)
	end
	return nil
end

local function configureSellBackPrompt(prompt: ProximityPrompt, spec: SellPromptSpec)
	prompt.ActionText = "Sell back (10%)"
	local objectText = "Equipment"
	if spec.hammerKind == "pump" then
		objectText = "Oil pump"
	elseif spec.hammerKind == "pipe" then
		objectText = "Pipe"
	elseif spec.hammerKind == "drill" then
		objectText = "Drill"
	elseif spec.hammerKind == "drum" then
		objectText = "Drum"
	elseif spec.hammerKind == "prospector" then
		objectText = "Prospector"
	end
	prompt.ObjectText = objectText
	prompt.HoldDuration = 0.45
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Enabled = true
	prompt:SetAttribute("OwnerUserId", spec.ownerUserId)
	prompt:SetAttribute("HammerKind", spec.hammerKind)
	if spec.drillId then
		prompt:SetAttribute("TargetDrillId", spec.drillId)
	else
		prompt:SetAttribute("TargetDrillId", nil)
	end
	if spec.cellKey and spec.cellKey ~= "" then
		prompt:SetAttribute("CellKey", spec.cellKey)
	else
		prompt:SetAttribute("CellKey", nil)
	end
	if spec.drumId then
		prompt:SetAttribute("TargetDrumId", spec.drumId)
	else
		prompt:SetAttribute("TargetDrumId", nil)
	end
	if spec.prospectId then
		prompt:SetAttribute("TargetProspectId", spec.prospectId)
	else
		prompt:SetAttribute("TargetProspectId", nil)
	end
end

local function ensureSellBackPromptOnHost(service: OilVisualService, host: Instance, spec: SellPromptSpec)
	if not host or not host.Parent then
		return
	end
	local adornee = basePartForSellPrompt(host)
	if not adornee then
		return
	end
	local att = adornee:FindFirstChild(SELL_BACK_ATTACH) :: Attachment?
	if not att then
		att = Instance.new("Attachment")
		att.Name = SELL_BACK_ATTACH
		att.Parent = adornee
	end
	att.Position = Vector3.new(0, math.min(adornee.Size.Y * 0.35 + 1.2, 5), 0)
	local prompt = att:FindFirstChild(SELL_BACK_PROMPT) :: ProximityPrompt?
	if not prompt then
		prompt = Instance.new("ProximityPrompt")
		prompt.Name = SELL_BACK_PROMPT
		prompt.Parent = att
	end
	configureSellBackPrompt(prompt, spec)
	service:_bindSellBackPromptServer(prompt, spec)
end

function OilVisualService:Init(oilStateService, plotService)
	self._oilStateService = oilStateService
	self._plotService = plotService
	self._connections = {}

	self._assetsFolder = ReplicatedStorage:FindFirstChild("Assets")
	self._barrelTemplate = self._assetsFolder and self._assetsFolder:FindFirstChild("Barrel") or nil
end

function OilVisualService:_getDrillTemplate(templateName: string?)
	if not self._assetsFolder then
		return nil
	end
	if templateName then
		local t = self._assetsFolder:FindFirstChild(templateName)
		if t then return t end
	end
	return self._assetsFolder:FindFirstChild("Drill") or self._assetsFolder:FindFirstChild("Pump")
end

function OilVisualService:Start()
	table.insert(self._connections, self._oilStateService:OnStateChanged(function(userId: number, snapshot)
		self:_syncUserVisuals(userId, snapshot)
	end))

	-- Reclone world visuals after plot assignment even if an early `PushState` missed `OnStateChanged`
	-- (startup order) or replication timing leaves the plot ready one frame later.
	table.insert(self._connections, self._plotService:OnPlotAssigned(function(userId: number, _plot: Model)
		task.defer(function()
			local snap = self._oilStateService:GetStateForClient(userId)
			if typeof(snap) == "table" then
				self:_syncUserVisuals(userId, snap)
			end
		end)
	end))

	table.insert(self._connections, self._plotService:OnPlotReleased(function(userId: number, plot: Model)
		self:_clearPlotVisuals(plot)
	end))
end

function OilVisualService:Stop()
	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	self._connections = {}
end

function OilVisualService:_syncUserVisuals(userId: number, snapshot)
	if typeof(snapshot) ~= "table" then
		return
	end
	local plot = self._plotService:GetOwnedPlot(userId)
	if not plot then
		return
	end

	local visualRoot = self:_ensureVisualRoot(plot)
	local drillsFolder = ensureFolder(visualRoot, "Drills")
	local activeDrillsFolder = ensureFolder(visualRoot, "ActiveDrills")
	local activeProspectorsFolder = ensureFolder(visualRoot, "ActiveProspectors")
	local spraysFolder = ensureFolder(visualRoot, "OilSprays")
	local barrelsFolder = ensureFolder(visualRoot, "Barrels")
	local pipesFolder = ensureFolder(visualRoot, "Pipes")
	local drumsFolder = ensureFolder(visualRoot, "Drums")

	local perf = _G.Perf
	local function run(label, fn)
		if perf then
			local h = perf:OpenSpan(label)
			fn()
			perf:CloseSpan(label, h)
		else
			fn()
		end
	end
	run("Visual.syncDrills", function() self:_syncDrills(plot, drillsFolder, snapshot.drills or {}, userId) end)
	run("Visual.syncActiveDrills", function() self:_syncActiveDrills(plot, activeDrillsFolder, snapshot.activeDrills or {}, userId) end)
	run("Visual.syncActiveProspectors", function() self:_syncActiveProspectors(plot, activeProspectorsFolder, snapshot.activeProspectors or {}, userId) end)
	run("Visual.syncOilSprays", function() self:_syncOilSprays(plot, spraysFolder, snapshot) end)
	run("Visual.syncPipes", function() self:_syncPipes(plot, pipesFolder, snapshot.pipes or {}, snapshot.drills or {}, snapshot.drums or {}, userId) end)
	run("Visual.syncDrums", function() self:_syncDrums(plot, drumsFolder, snapshot.drums or {}, userId) end)
	run("Visual.syncBarrels", function() self:_syncBarrels(plot, barrelsFolder, snapshot) end)
	run("Visual.syncOilTanks", function() self:_syncOilTanks(plot, snapshot) end)
end

function OilVisualService:_ensureVisualRoot(plot: Model): Folder
	local existing = plot:FindFirstChild("OilVisuals")
	if existing and existing:IsA("Folder") then
		return existing
	end
	if existing and not existing:IsA("Folder") then
		existing:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = "OilVisuals"
	folder.Parent = plot
	return folder
end

function OilVisualService:_clearPlotVisuals(plot: Model)
	local root = plot:FindFirstChild("OilVisuals")
	if root then
		root:Destroy()
	end
end

-- In-progress drills: spawn the tier's drill model at the tile, store StartTime/EndTime attributes
-- so clients can run a local sink+spin animation. Destroyed when the activeDrill leaves the snapshot
-- (i.e. CompleteDrill cleared it).
-- In-progress prospector placements. Same pattern as active drills but uses the Prospector
-- template and tags with prospectId so the client animates it separately.
function OilVisualService:_syncActiveProspectors(_plot: Model, folder: Folder, activeProspectors, ownerUserId: number)
	local wanted = {}
	for _, entry in pairs(activeProspectors) do
		local pid = entry.prospectId
		if typeof(pid) ~= "number" or typeof(entry.position) ~= "table" then continue end
		local name = "ActiveProspector_" .. tostring(pid)
		wanted[name] = true
		local model = folder:FindFirstChild(name)
		local justCreated = false
		if not model then
			local template = self._assetsFolder and self._assetsFolder:FindFirstChild(entry.template or "Prospector")
			if template then
				model = template:Clone()
			else
				model = Instance.new("Model")
			end
			model.Name = name
			model:SetAttribute("StartTime", tonumber(entry.startTime) or 0)
			model:SetAttribute("EndTime", tonumber(entry.endTime) or 0)
			model:SetAttribute("Duration", math.max(0.01, (tonumber(entry.endTime) or 0) - (tonumber(entry.startTime) or 0)))
			model:SetAttribute("ProspectId", pid)
			model.Parent = folder
			justCreated = true
		end
		if justCreated then
			local px = tonumber(entry.position.x) or 0
			local py = tonumber(entry.position.y) or 0
			local pz = tonumber(entry.position.z) or 0
			local halfH = 0
			if model:IsA("Model") then
				local _, bbSize = model:GetBoundingBox()
				halfH = bbSize.Y / 2
			elseif model:IsA("BasePart") then
				halfH = (model :: BasePart).Size.Y / 2
			end
			local cframe = CFrame.new(px, py + halfH, pz)
			if model:IsA("Model") then
				model:PivotTo(cframe)
			elseif model:IsA("BasePart") then
				model.CFrame = cframe
			end
			anchorAllBaseParts(model)
		end
		if model then
			ensureSellBackPromptOnHost(self, model, { ownerUserId = ownerUserId, hammerKind = "prospector", prospectId = pid })
		end
	end
	for _, child in ipairs(folder:GetChildren()) do
		if not wanted[child.Name] then child:Destroy() end
	end
end

local function activeDrillPositionXYZ(entry: any): (number?, number?, number?)
	if typeof(entry) ~= "table" then
		return nil, nil, nil
	end
	local p = (entry :: { [string]: any }).position
	if typeof(p) == "Vector3" then
		local v = p :: Vector3
		return v.X, v.Y, v.Z
	end
	if typeof(p) == "table" then
		local t = p :: { [string]: any }
		local px = tonumber(t.x) or tonumber(t.X)
		local py = tonumber(t.y) or tonumber(t.Y)
		local pz = tonumber(t.z) or tonumber(t.Z)
		if px and py and pz then
			return px, py, pz
		end
	end
	return nil, nil, nil
end

function OilVisualService:_syncActiveDrills(_plot: Model, folder: Folder, activeDrills, ownerUserId: number)
	local wanted = {}
	for _, entry in pairs(activeDrills) do
		local drillId = entry.drillId
		local px, py, pz = activeDrillPositionXYZ(entry)
		if typeof(drillId) ~= "number" or not px or not py or not pz then
			continue
		end
		local name = "ActiveDrill_" .. tostring(drillId)
		local timerName = "DrillTimer_" .. tostring(drillId)
		wanted[name] = true
		wanted[timerName] = true

		local model = folder:FindFirstChild(name)
		if model and model:GetAttribute("Template") ~= entry.template then
			model:Destroy()
			model = nil
		end
		local justCreated = false
		if not model then
			local template = self:_getDrillTemplate(entry.template)
			if template then
				model = template:Clone()
			else
				model = Instance.new("Model")
			end
			model.Name = name
			model:SetAttribute("Template", entry.template)
			model:SetAttribute("StartTime", tonumber(entry.startTime) or 0)
			model:SetAttribute("EndTime", tonumber(entry.endTime) or 0)
			model:SetAttribute("Duration", math.max(0.01, (tonumber(entry.endTime) or 0) - (tonumber(entry.startTime) or 0)))
			model:SetAttribute("OilType", entry.oilType)
			model:SetAttribute("DrillId", drillId)
			model.Parent = folder
			justCreated = true

			-- Static timer anchor Part with BillboardGui. Does NOT sink/spin with the drill.
			local anchor = Instance.new("Part")
			anchor.Name = timerName
			anchor.Size = Vector3.new(0.2, 0.2, 0.2)
			anchor.Transparency = 1
			anchor.Anchored = true
			anchor.CanCollide = false
			anchor.CanQuery = false
			anchor.CanTouch = false
			anchor.Parent = folder

			local bb = Instance.new("BillboardGui")
			bb.Name = "TimerGui"
			bb.Adornee = anchor
			bb.Size = UDim2.new(0, 140, 0, 40)
			bb.StudsOffsetWorldSpace = Vector3.new(0, 8, 0)
			bb.AlwaysOnTop = true
			bb.Parent = anchor

			local lbl = Instance.new("TextLabel")
			lbl.Name = "TimerLabel"
			lbl.Size = UDim2.fromScale(1, 1)
			lbl.BackgroundColor3 = Color3.new(0, 0, 0)
			lbl.BackgroundTransparency = 0.4
			lbl.TextColor3 = Color3.fromRGB(255, 230, 100)
			lbl.TextStrokeColor3 = Color3.new(0, 0, 0)
			lbl.TextStrokeTransparency = 0
			lbl.Font = Enum.Font.GothamBold
			lbl.TextScaled = true
			lbl.Text = "--"
			lbl.Parent = bb

			anchor:SetAttribute("StartTime", tonumber(entry.startTime) or 0)
			anchor:SetAttribute("EndTime", tonumber(entry.endTime) or 0)
		end

		-- Keep the static anchor parked at (px, py + 3) above the drill tip
		local anchor = folder:FindFirstChild(timerName)
		if anchor and anchor:IsA("BasePart") then
			anchor.Position = Vector3.new(px, py + 3, pz)
		end

		-- Only set CFrame on creation; the client's animation loop owns the CFrame after that,
		-- otherwise snapshot pushes would stomp the sink/spin every tick.
		if justCreated then
			-- Match client ghost / `PlacementAnchor` (optional `Bottom` part, else full-model bbox).
			local pivotToBottom = 0
			if model:IsA("Model") then
				pivotToBottom = PlacementAnchor.pivotYMinusBottomWorldY(model)
			elseif model:IsA("BasePart") then
				pivotToBottom = (model :: BasePart).Size.Y / 2
			end
			local cframe = CFrame.new(px, py + pivotToBottom, pz)
			if model:IsA("Model") then
				model:PivotTo(cframe)
			elseif model:IsA("BasePart") then
				model.CFrame = cframe
			end
			anchorAllBaseParts(model)
		end
		if model then
			ensureSellBackPromptOnHost(self, model, { ownerUserId = ownerUserId, hammerKind = "drill", drillId = drillId })
		end
	end
	for _, child in ipairs(folder:GetChildren()) do
		if not wanted[child.Name] then child:Destroy() end
	end
end

-- Persistent oil spray on any tile that has been drilled but doesn't yet have a pump.
-- One ParticleEmitter-bearing invisible Part per qualifying tile, colored per oil type.
function OilVisualService:_syncOilSprays(_plot: Model, folder: Folder, snapshot)
	local pumpCellKeys = {}
	for _, d in ipairs(snapshot.drills or {}) do
		if d.cellKey then pumpCellKeys[d.cellKey] = true end
	end
	local activeCellKeys = {}
	for _, a in pairs(snapshot.activeDrills or {}) do
		if a.chunkId and a.tileKey then
			activeCellKeys[a.chunkId .. ":" .. a.tileKey] = true
		end
	end
	-- Pipes: map each pipe to "chunkId:tileKey" so we can hide sprays the pipe covers.
	-- Pipe carries global (row, col). A chunk with (chunk.row, chunk.col) owns tiles
	-- localR=1..5, localC=1..5 relative to its top-left cell.
	local SUB_TILES_PER_SIDE = 5
	local pipeTileSigs = {}
	for _, pipe in ipairs(snapshot.pipes or {}) do
		if typeof(pipe.row) == "number" and typeof(pipe.col) == "number" then
			local sectionId = pipe.sectionId
			if typeof(sectionId) == "string" then
				local chunkRow = math.floor((pipe.row - 1) / SUB_TILES_PER_SIDE) + 1
				local chunkCol = math.floor((pipe.col - 1) / SUB_TILES_PER_SIDE) + 1
				local localR = pipe.row - (chunkRow - 1) * SUB_TILES_PER_SIDE
				local localC = pipe.col - (chunkCol - 1) * SUB_TILES_PER_SIDE
				if localR >= 1 and localR <= SUB_TILES_PER_SIDE and localC >= 1 and localC <= SUB_TILES_PER_SIDE then
					pipeTileSigs[sectionId .. ":T" .. localR .. localC] = true
				end
			end
		end
	end

	local wanted = {}
	for _, chunk in ipairs(snapshot.chunks or {}) do
		if chunk.tiles and chunk.unlocked then
			for tileKey, tile in pairs(chunk.tiles) do
				if tile and tile.drilled and tile.hasOil ~= false then
					local spraySig = chunk.chunkId .. ":" .. tileKey
					local hasPump = false
					for _, d in ipairs(snapshot.drills or {}) do
						if d.tileKey == tileKey and d.chunkId == chunk.chunkId then
							hasPump = true
							break
						end
					end
					local coveredByPipe = pipeTileSigs[chunk.chunkId .. ":" .. tileKey] == true
					if not hasPump and not activeCellKeys[spraySig] and not coveredByPipe then
						wanted[spraySig] = { chunk = chunk, tileKey = tileKey, tile = tile }
					end
				end
			end
		end
	end

	-- (Pruning happens AFTER spawn, at bottom, so we can strip SUPER TILE suffixes correctly)

	-- Spawn a puddle on the drilled tile (colored per oil type). Removed when pump is placed
	-- (pruning loop at the bottom of this function).
	local function spawnPuddleForTile(sig: string, info: any)
		local childName = "Puddle_" .. sig
		local part = folder:FindFirstChild(childName)
		local oilType = info.tile.oilType or "HeavyCrude"
		local color = (OilConfig.OilSprayColors and OilConfig.OilSprayColors[oilType])
			or Color3.fromRGB(30, 30, 30)
		if not part then
			local template = self._assetsFolder and self._assetsFolder:FindFirstChild("Puddle")
			if template and template:IsA("BasePart") then
				part = template:Clone()
				part.Name = childName
				part.Anchored = true; part.CanCollide = false; part.CanQuery = false; part.CanTouch = false
				part.Color = color
				part.Parent = folder
			end
		else
			part.Color = color
		end
		if part then
			local sectionModel = self._plotService:GetChunkModel(_plot, info.chunk.chunkId)
			if sectionModel then
				local tilePart = sectionModel:FindFirstChild(info.tileKey)
				if tilePart and tilePart:IsA("BasePart") then
					local topY = tilePart.Position.Y + tilePart.Size.Y / 2
					-- Puddle sits flush on the tile, scaled to fit the tile footprint (~7 studs)
					if part:IsA("BasePart") then
						part.Size = Vector3.new(6.5, part.Size.Y, 6.5)
						part.Position = Vector3.new(tilePart.Position.X, topY + part.Size.Y / 2, tilePart.Position.Z)
					end
				end
			end
		end
	end

	-- Spawn sprays. SUPER TILE drilled → emit ALL 3 oil types at once. Normal tiles → just one.
	local function spawnSprayForTile(sig: string, info: any, oilTypeOverride: string?, offset: Vector3?)
		local suffix = oilTypeOverride and ("_" .. oilTypeOverride) or ""
		local childName = "Spray_" .. sig .. suffix
		local part = folder:FindFirstChild(childName)
		if not part then
			local oilType = oilTypeOverride or info.tile.oilType or "HeavyCrude"
			local templateName = "OilSpray_" .. tostring(oilType)
			local template = self._assetsFolder and self._assetsFolder:FindFirstChild(templateName)
			if template and template:IsA("BasePart") then
				part = template:Clone()
				part.Name = childName
				part.Anchored = true
				part.CanCollide = false
				part.CanQuery = false
				part.CanTouch = false
				part.Parent = folder
			else
				part = Instance.new("Part")
				part.Name = childName
				part.Size = Vector3.new(0.4, 0.4, 0.4)
				part.Anchored = true
				part.Transparency = 1
				part.CanCollide = false
				part.CanQuery = false
				part.CanTouch = false
				part.Parent = folder
			end
		end

		local sectionModel = self._plotService:GetChunkModel(_plot, info.chunk.chunkId)
		if sectionModel then
			local tilePart = sectionModel:FindFirstChild(info.tileKey)
			if tilePart and tilePart:IsA("BasePart") then
				local topY = tilePart.Position.Y + tilePart.Size.Y / 2
				local basePos = Vector3.new(tilePart.Position.X, topY + 0.3, tilePart.Position.Z)
				part.Position = basePos + (offset or Vector3.new(0, 0, 0))
			end
		end
	end

	for sig, info in pairs(wanted) do
		if info.tile.tileName == "SUPER TILE" then
			-- Triple spray, one per oil type, slightly offset so they're visible separately
			spawnSprayForTile(sig, info, "HeavyCrude",     Vector3.new(-1.5, 0, -1.5))
			spawnSprayForTile(sig, info, "LightSweet",     Vector3.new( 1.5, 0, -1.5))
			spawnSprayForTile(sig, info, "PremiumRefined", Vector3.new( 0,   0,  1.8))
		else
			spawnSprayForTile(sig, info)
		end
		spawnPuddleForTile(sig, info)
	end

	-- Prune any sprays/puddles whose base sig is no longer wanted (pump placed → removed)
	for _, child in ipairs(folder:GetChildren()) do
		local sprayBase = child.Name:match("^Spray_(.+)")
		local puddleBase = child.Name:match("^Puddle_(.+)")
		local base = sprayBase or puddleBase
		if base then
			-- Strip the oil-type suffix on sprays before looking up wanted
			local coreSig = base:gsub("_HeavyCrude$", ""):gsub("_LightSweet$", ""):gsub("_PremiumRefined$", "")
			if not wanted[coreSig] then
				child:Destroy()
			end
		end
	end
end

function OilVisualService:_syncDrills(_plot: Model, drillsFolder: Folder, drills, ownerUserId: number)
	local wanted = {}
	for _, drill in ipairs(drills) do
		local drillId = drill.drillId
		if typeof(drillId) == "number" and typeof(drill.position) == "table" then
			local key = tostring(drillId)
			wanted[key] = true
			local drillName = "Drill_" .. key
			local templateName = drill.template
			local model = drillsFolder:FindFirstChild(drillName)
			-- If the existing model was built from a different template, rebuild it
			if model and model:GetAttribute("Template") ~= templateName then
				model:Destroy()
				model = nil
			end
			local justCreated = false
			if not model then
				model = self:_createDrillVisual(drillName, templateName)
				model:SetAttribute("Template", templateName)
				model.Parent = drillsFolder
				justCreated = true
			end

			local px = tonumber(drill.position.x) or 0
			local py = tonumber(drill.position.y) or 0
			local pz = tonumber(drill.position.z) or 0
			local scale = tonumber(drill.scale) or 1

			-- Re-resolve tile top from live plot geometry so Y is never stale / never from void raycasts.
			if typeof(drill.chunkId) == "string" and typeof(drill.tileKey) == "string" then
				local liveY = self._plotService:GetChunkTileSurfaceWorldY(_plot, drill.chunkId, drill.tileKey)
				if typeof(liveY) == "number" then
					py = liveY
					local sectionModel = self._plotService:GetChunkModel(_plot, drill.chunkId)
					if sectionModel then
						local tilePart = self._plotService:FindChunkTileBasePart(sectionModel, drill.tileKey)
						if tilePart then
							px = tilePart.Position.X
							pz = tilePart.Position.Z
						end
					end
				end
			end

			-- Apply ScaleTo before measuring vertical lift: `pivotY - bottomY` at authored scale
			-- times `scale` is NOT equal to the same delta after `Model:ScaleTo(scale)` (Roblox uses
			-- an internal authored baseline). T1 looked fine only because that delta was tiny.
			if model:IsA("Model") and model:GetAttribute("AppliedScale") ~= scale then
				model:ScaleTo(scale)
				model:SetAttribute("AppliedScale", scale)
			end

			local pivotToBottom = 0
			if model:IsA("Model") then
				pivotToBottom = PlacementAnchor.pivotYMinusBottomWorldY(model)
			elseif model:IsA("BasePart") then
				pivotToBottom = (model :: BasePart).Size.Y / 2 * scale
			end

			local extraLift = pumpTierVisualGroundLiftStuds(drill.tier, scale)
			local targetCf = CFrame.new(px, py + DRILL_HEIGHT_OFFSET + pivotToBottom + extraLift, pz)
			if model:IsA("Model") then
				model:PivotTo(targetCf)
			elseif model:IsA("BasePart") then
				model.CFrame = targetCf
			end
			anchorAllBaseParts(model)

			-- Write Connected attribute so the OilBurstSpawner script can pause emission
			model:SetAttribute("Connected", drill.connected == true)

			-- Rare cosmetic variant: add a Highlight in the variant's color
			local variant = drill.variant
			if variant ~= model:GetAttribute("AppliedVariant") then
				for _, c in ipairs(model:GetChildren()) do
					if c:IsA("Highlight") and c.Name == "VariantHighlight" then c:Destroy() end
				end
				if variant == "gold" or variant == "rainbow" then
					local hl = Instance.new("Highlight")
					hl.Name = "VariantHighlight"
					hl.FillTransparency = 0.75
					hl.OutlineTransparency = 0
					if variant == "gold" then
						hl.FillColor = OilConfig.GoldPumpHighlightColor or Color3.fromRGB(255, 215, 70)
						hl.OutlineColor = Color3.fromRGB(255, 240, 140)
					else
						hl.FillColor = OilConfig.RainbowPumpHighlightColor or Color3.fromRGB(180, 140, 255)
						hl.OutlineColor = Color3.fromRGB(255, 255, 255)
					end
					hl.Parent = model
				end
				model:SetAttribute("AppliedVariant", variant)
			end

			ensureSellBackPromptOnHost(self, model, { ownerUserId = ownerUserId, hammerKind = "pump", drillId = drillId })
		end
	end

	for _, child in ipairs(drillsFolder:GetChildren()) do
		local key = string.gsub(child.Name, "^Drill_", "")
		if not wanted[key] then
			child:Destroy()
		end
	end
end

function OilVisualService:_syncPipes(_plot: Model, pipesFolder: Folder, pipes, drills, drums, ownerUserId: number)
	-- Build a typed occupancy map: cellKey -> "pipe" | "drill" | "drum"
	-- Drills and drums should make pipe arms extend further so they visually meet the body.
	local occupancy = {}
	for _, pipe in ipairs(pipes) do
		if pipe.cellKey then occupancy[pipe.cellKey] = "pipe" end
	end
	for _, drill in ipairs(drills or {}) do
		if drill.cellKey then occupancy[drill.cellKey] = "drill" end
	end
	for _, drum in ipairs(drums or {}) do
		if drum.cellKey then occupancy[drum.cellKey] = "drum" end
	end

	local function neighborKey(row, col, dRow, dCol)
		return string.format("R%dC%d", row + dRow, col + dCol)
	end

	local subTilesPerSide = math.max(1, math.floor((tonumber(((OilConfig.Chunks or {}).Size)) or 40) / 8))
	local function rowColToChunkId(row: number, col: number): string
		local chunkRow = math.floor((row - 1) / subTilesPerSide) + 1
		local chunkCol = math.floor((col - 1) / subTilesPerSide) + 1
		return string.format("S%02d_%02d", chunkRow, chunkCol)
	end

	local function rowColToTileKey(row: number, col: number): string
		local tileRow = ((row - 1) % subTilesPerSide) + 1
		local tileCol = ((col - 1) % subTilesPerSide) + 1
		return string.format("T%d%d", tileRow, tileCol)
	end

	local wanted = {}
	for _, pipe in ipairs(pipes) do
		if pipe.cellKey and pipe.row and pipe.col then
			local key = pipe.cellKey
			wanted[key] = true
			local pipeName = "Pipe_" .. key
			local model = pipesFolder:FindFirstChild(pipeName)

			-- Compute neighbor type (nil | "pipe" | "drill" | "drum")
			local nType = occupancy[neighborKey(pipe.row, pipe.col, -1, 0)]
			local sType = occupancy[neighborKey(pipe.row, pipe.col,  1, 0)]
			local eType = occupancy[neighborKey(pipe.row, pipe.col,  0, 1)]
			local wType = occupancy[neighborKey(pipe.row, pipe.col,  0,-1)]
			local hasN, hasS, hasE, hasW = nType ~= nil, sType ~= nil, eType ~= nil, wType ~= nil

			if not model then
				model = Instance.new("Model")
				model.Name = pipeName

				-- Thin tile-wide metallic base plate (flat color, no texture)
				local body = Instance.new("Part")
				body.Name = "Body"
				body.Shape = Enum.PartType.Block
				body.Size = Vector3.new(7.6, 0.3, 7.6)
				body.Material = Enum.Material.SmoothPlastic
				body.Color = Color3.fromRGB(90, 95, 105)
				body.Anchored = true
				body.CanCollide = false
				body.CanQuery = true
				body.Reflectance = 0.15
				body:SetAttribute("PipeTile", true)
				body.Parent = model

				-- Central hub: smooth block (not a ball) for clean intersections
				local hub = Instance.new("Part")
				hub.Name = "Hub"
				hub.Shape = Enum.PartType.Block
				hub.Size = Vector3.new(1.4, 1.4, 1.4)
				hub.Material = Enum.Material.Metal
				hub.Color = Color3.fromRGB(120, 120, 130)
				hub.Anchored = true
				hub.CanCollide = false
				hub.CanQuery = true
				hub.Reflectance = 0.1
				hub.Parent = model

				-- 4 directional arm cylinders (N, E, S, W)
				local function makeArm(armName)
					local arm = Instance.new("Part")
					arm.Name = armName
					arm.Shape = Enum.PartType.Cylinder
					arm.Size = Vector3.new(4, 1.4, 1.4)
					arm.Material = Enum.Material.Metal
					arm.Color = Color3.fromRGB(120, 120, 130)
					arm.Anchored = true
					arm.CanCollide = false
					arm.CanQuery = true
					arm.Reflectance = 0.1
					arm.Parent = model
					return arm
				end
				makeArm("ArmN")
				makeArm("ArmS")
				makeArm("ArmE")
				makeArm("ArmW")

				model.PrimaryPart = hub
				model.Parent = pipesFolder
			end

			local px = tonumber(pipe.position.x) or 0
			local py = tonumber(pipe.position.y) or 6
			local pz = tonumber(pipe.position.z) or 0

			local snappedToTile = false
			if typeof(pipe.row) == "number" and typeof(pipe.col) == "number" then
				local chunkId = if typeof(pipe.sectionId) == "string" and #pipe.sectionId > 0
					then pipe.sectionId
					else rowColToChunkId(pipe.row, pipe.col)
				local tileKey = rowColToTileKey(pipe.row, pipe.col)
				local sectionModel = self._plotService:GetChunkModel(_plot, chunkId)
				if sectionModel then
					local tilePart = self._plotService:FindChunkTileBasePart(sectionModel, tileKey)
					if tilePart then
						px = tilePart.Position.X
						pz = tilePart.Position.Z
						py = tilePart.Position.Y + tilePart.Size.Y / 2
						snappedToTile = true
					end
				end
			end

			-- Fallback: nearest tile search for old/bad records with missing cell metadata.
			if not snappedToTile then
				local ground = _plot:FindFirstChild("PlotGround")
				if ground then
					local nearestTile, nearestDist = nil, math.huge
					for _, t in ipairs(ground:GetDescendants()) do
						if t:IsA("BasePart") and t.Name:match("^T%d%d$") then
							local dx = t.Position.X - px
							local dz = t.Position.Z - pz
							local d2 = dx*dx + dz*dz
							if d2 < nearestDist then
								nearestDist = d2
								nearestTile = t
							end
						end
					end
					if nearestTile then
						px = nearestTile.Position.X
						pz = nearestTile.Position.Z
						py = nearestTile.Position.Y + nearestTile.Size.Y / 2
					end
				end
			end

			-- Position the base plate flush with the tile top: plate center = py + (plate.Size.Y / 2)
			local body = model:FindFirstChild("Body")
			if body and body:IsA("BasePart") then
				body.Position = Vector3.new(px, py + body.Size.Y / 2, pz)
			end

			-- Position the hub just above the plate
			local hub = model:FindFirstChild("Hub")
			if hub and hub:IsA("BasePart") then
				hub.Position = Vector3.new(px, py + body.Size.Y + hub.Size.Y / 2, pz)
			end

			-- Position arms relative to hub center; cylinder axis is local X = stud-length axis
			local armN = model:FindFirstChild("ArmN")
			local armS = model:FindFirstChild("ArmS")
			local armE = model:FindFirstChild("ArmE")
			local armW = model:FindFirstChild("ArmW")

			local function armLengthFor(neighborType)
				if neighborType == "drill" or neighborType == "drum" then
					return 8
				end
				return 4
			end

			local armY = py + 0.7 -- level with hub center
			local function setArm(arm, neighborType, dirVec)
				if not (arm and arm:IsA("BasePart")) then return end
				if not neighborType then
					arm.Transparency = 1
					arm.CanQuery = false
					return
				end
				arm.Transparency = 0
				arm.CanQuery = true
				local len = armLengthFor(neighborType)
				arm.Size = Vector3.new(len, 1.2, 1.2)
				local hubCenter = Vector3.new(px, armY, pz)
				local center = hubCenter + dirVec * (len / 2)
				if dirVec.X ~= 0 then
					arm.CFrame = CFrame.new(center)
				else
					arm.CFrame = CFrame.new(center) * CFrame.Angles(0, math.rad(90), 0)
				end
			end

			setArm(armN, nType, Vector3.new(0, 0, -1))
			setArm(armS, sType, Vector3.new(0, 0,  1))
			setArm(armE, eType, Vector3.new(1, 0,  0))
			setArm(armW, wType, Vector3.new(-1, 0, 0))

			if pipe.isCorePipe == true then
				local prompt = model:FindFirstChild(SELL_BACK_PROMPT, true)
				if prompt and prompt:IsA("ProximityPrompt") then
					disconnectSellBackPrompt(prompt)
					prompt:Destroy()
				end
			else
				ensureSellBackPromptOnHost(self, model, { ownerUserId = ownerUserId, hammerKind = "pipe", cellKey = pipe.cellKey })
			end
		end
	end

	for _, child in ipairs(pipesFolder:GetChildren()) do
		local key = string.gsub(child.Name, "^Pipe_", "")
		if not wanted[key] then
			child:Destroy()
		end
	end

	-- Oil swell animation: pipe-colored balls slide through visible arms when oil is flowing.
	local anyProducing = false
	for _, drill in ipairs(drills or {}) do
		if drill.connected then
			anyProducing = true
			break
		end
	end

	for _, child in ipairs(pipesFolder:GetChildren()) do
		-- For each visible arm, place a moving ball that slides along the arm
		for _, armName in ipairs({"ArmN", "ArmS", "ArmE", "ArmW"}) do
			local arm = child:FindFirstChild(armName)
			if arm and arm:IsA("BasePart") and arm.Transparency < 0.5 then
				local pulseName = "Pulse_" .. armName
				local pulse = child:FindFirstChild(pulseName)
				if not pulse then
					pulse = Instance.new("Part")
					pulse.Name = pulseName
					pulse.Shape = Enum.PartType.Ball
					pulse.Size = Vector3.new(1.6, 1.6, 1.6)
					pulse.Material = Enum.Material.Metal
					pulse.Color = Color3.fromRGB(130, 130, 140) -- slightly lighter than pipe
					pulse.Reflectance = 0.15
					pulse.Anchored = true
					pulse.CanCollide = false
					pulse.CanQuery = false
					pulse.CanTouch = false
					pulse.Parent = child
				end

				if anyProducing then
					pulse.Transparency = 0
					-- Slide the ball along the arm's length. Each arm's CFrame defines its center.
					-- The ball oscillates from one end to the other based on time.
					local armLen = arm.Size.X  -- cylinder length axis
					local speed = 3
					local t = (tick() * speed + arm.Position.Magnitude * 0.3) % 2
					local travel = t < 1 and t or (2 - t) -- 0→1→0 bounce
					local offset = (travel - 0.5) * armLen * 0.8 -- ±40% of arm length from center

					-- Compute world offset along the arm's direction
					-- Arm CFrame's LookVector points along the arm (cylinder axis = local X after rotation)
					local armDir = arm.CFrame.RightVector -- cylinder local X = RightVector after CFrame construction
					pulse.Position = arm.Position + armDir * offset
				else
					pulse.Transparency = 1
				end
			else
				-- Arm is hidden, hide its pulse too
				local pulseName = "Pulse_" .. armName
				local pulse = child:FindFirstChild(pulseName)
				if pulse then
					pulse.Transparency = 1
				end
			end
		end
	end
end

function OilVisualService:_syncDrums(_plot: Model, drumsFolder: Folder, drums, ownerUserId: number)
	-- Plot art already contains the authored lab machine; avoid spawning duplicate drum rigs on top.
	if _plot:FindFirstChild("Lab Machine") then
		for _, child in ipairs(drumsFolder:GetChildren()) do
			child:Destroy()
		end
		return
	end

	local wanted = {}
	local drumTemplate = self._assetsFolder and self._assetsFolder:FindFirstChild("Drum")
	local subTilesPerSide = math.max(1, math.floor((tonumber(((OilConfig.Chunks or {}).Size)) or 40) / 8))
	local function rowColToChunkId(row: number, col: number): string
		local chunkRow = math.floor((row - 1) / subTilesPerSide) + 1
		local chunkCol = math.floor((col - 1) / subTilesPerSide) + 1
		return string.format("S%02d_%02d", chunkRow, chunkCol)
	end
	local function rowColToTileKey(row: number, col: number): string
		local tileRow = ((row - 1) % subTilesPerSide) + 1
		local tileCol = ((col - 1) % subTilesPerSide) + 1
		return string.format("T%d%d", tileRow, tileCol)
	end

	for _, drum in ipairs(drums) do
		local drumId = drum.drumId
		if typeof(drumId) == "number" and typeof(drum.position) == "table" then
			local key = tostring(drumId)
			wanted[key] = true
			local drumName = "Drum_" .. key
			local model = drumsFolder:FindFirstChild(drumName)
			if not model then
				if drumTemplate then
					model = drumTemplate:Clone()
				else
					model = Instance.new("Model")
					local p = Instance.new("Part")
					p.Name = "DrumBody"
					p.Size = Vector3.new(6, 8, 6)
					p.Material = Enum.Material.Metal
					p.Color = Color3.fromRGB(60, 60, 70)
					p.Parent = model
					model.PrimaryPart = p
				end
				model.Name = drumName
				model.Parent = drumsFolder
			end

			local px = tonumber(drum.position.x) or 0
			local py = tonumber(drum.position.y) or 0
			local pz = tonumber(drum.position.z) or 0
			local targetRotation: CFrame? = nil
			if typeof(drum.row) == "number" and typeof(drum.col) == "number" then
				local chunkId = rowColToChunkId(drum.row, drum.col)
				local tileKey = rowColToTileKey(drum.row, drum.col)
				local sectionModel = self._plotService:GetChunkModel(_plot, chunkId)
				if sectionModel then
					local tilePart = self._plotService:FindChunkTileBasePart(sectionModel, tileKey)
					if tilePart then
						px = tilePart.Position.X
						pz = tilePart.Position.Z
						targetRotation = tilePart.CFrame - tilePart.Position
					end
				end
			end
			local targetCf = CFrame.new(px, py, pz)
			if targetRotation then
				targetCf = targetCf * targetRotation
			end
			if model:IsA("Model") then
				model:PivotTo(targetCf)
			elseif model:IsA("BasePart") then
				model.CFrame = targetCf
			end
			anchorAllBaseParts(model)
			ensureSellBackPromptOnHost(self, model, { ownerUserId = ownerUserId, hammerKind = "drum", drumId = drumId })
		end
	end

	for _, child in ipairs(drumsFolder:GetChildren()) do
		local key = string.gsub(child.Name, "^Drum_", "")
		if not wanted[key] then
			child:Destroy()
		end
	end
end

function OilVisualService:_createDrillVisual(name: string, templateName: string?): Instance
	local template = self:_getDrillTemplate(templateName)
	if template then
		local clone = template:Clone()
		clone.Name = name
		clone:SetAttribute("AppliedScale", nil)
		anchorAllBaseParts(clone)
		-- Do NOT set PrimaryPart: doing so makes Roblox re-derive WorldPivot from
		-- that part's CFrame, overriding the bottom-center pivot baked into the template.
		return clone
	end

	local model = Instance.new("Model")
	model.Name = name

	local mast = Instance.new("Part")
	mast.Name = "Mast"
	mast.Size = Vector3.new(0.8, 3.8, 0.8)
	mast.Anchored = true
	mast.CanCollide = false
	mast.Material = Enum.Material.Metal
	mast.Color = Color3.fromRGB(70, 70, 76)
	mast.Parent = model

	local head = Instance.new("Part")
	head.Name = "Head"
	head.Size = Vector3.new(2.2, 0.5, 1.2)
	head.Anchored = true
	head.CanCollide = false
	head.Material = Enum.Material.Metal
	head.Color = Color3.fromRGB(92, 92, 100)
	head.Parent = model

	model.PrimaryPart = mast
	mast.CFrame = CFrame.new(0, 0, 0)
	head.CFrame = CFrame.new(0, 2.0, 0)
	return model
end

function OilVisualService:_syncBarrels(plot: Model, barrelsFolder: Folder, snapshot)
	if typeof(snapshot) ~= "table" then
		return
	end
	local oilByTier = snapshot.oilByTier or {}
	local barrelConfig = OilConfig.Barrels or {}
	local perBarrel = math.max(1, barrelConfig.PerBarrelOil or 10)
	local maxPerTier = math.max(1, barrelConfig.MaxVisualPerTier or 20)
	local barrelHeight = barrelConfig.BarrelHeight or 3.5
	local tweenSeconds = barrelConfig.ConveyorTweenSeconds or 4
	local tierTemplates = barrelConfig.TierTemplates or {}

	local staging = plot:FindFirstChild("BarrelStagingArea")
	if not staging then
		print("[OilVisualService] No BarrelStagingArea on plot")
		return
	end

	local convStart = staging:FindFirstChild("ConveyorStart")
	local convCorner = staging:FindFirstChild("ConveyorCorner")
	local convEnd = staging:FindFirstChild("ConveyorEnd")
	if not (convStart and convEnd) then return end

	-- Small Y offset so barrels sit just above the belt surface, not clipping into it
	local BELT_Y_OFFSET = Vector3.new(0, 0.2, 0)
	local startPos = convStart.Position + BELT_Y_OFFSET
	local cornerPos = (convCorner and convCorner.Position or convStart.Position) + BELT_Y_OFFSET
	local endPos = convEnd.Position + BELT_Y_OFFSET

	-- Compute segment lengths for proportional tween timing
	local seg1Len = (cornerPos - startPos).Magnitude
	local seg2Len = (endPos - cornerPos).Magnitude
	local totalLen = math.max(seg1Len + seg2Len, 1)

	-- Set drum fill level
	local drumsFolder = barrelsFolder.Parent and barrelsFolder.Parent:FindFirstChild("Drums")
	if drumsFolder then
		local avgFill = 0
		local count = 0
		for _, tier in ipairs(TIER_ORDER) do
			local oil = oilByTier[tier] or 0
			avgFill += (oil % perBarrel) / perBarrel
			count += 1
		end
		if count > 0 then avgFill = avgFill / count end
		for _, drumModel in ipairs(drumsFolder:GetChildren()) do
			drumModel:SetAttribute("DrumFillLevel", avgFill)
		end
	end

	for _, tier in ipairs(TIER_ORDER) do
		local oil = oilByTier[tier] or 0
		local desired = clamp(math.floor(oil / perBarrel), 0, maxPerTier)

		-- Count existing piled + conveyor barrels for this tier
		local piledCount = 0
		local conveyorCount = 0
		for _, child in ipairs(barrelsFolder:GetChildren()) do
			if child:GetAttribute("Tier") == tier then
				if child:GetAttribute("OnConveyor") then
					conveyorCount += 1
				else
					piledCount += 1
				end
			end
		end
		local totalVisual = piledCount + conveyorCount

		if desired > totalVisual then
			local toSpawn = desired - totalVisual
			for _ = 1, toSpawn do
				local barrel = self:_createBarrelForTier(tier, tierTemplates[tier])
				barrel:SetAttribute("Tier", tier)
				barrel:SetAttribute("OnConveyor", true)
				barrel.Parent = barrelsFolder

				-- Enable pickup prompt
				for _, d in ipairs(barrel:GetDescendants()) do
					if d:IsA("ProximityPrompt") then
						d.Enabled = true
					end
				end

				-- Barrel half-height for proper Y placement
				local barrelHalfHeight = 0
				if barrel:IsA("BasePart") then
					barrelHalfHeight = barrel.Size.Y / 2
				end

				local function moveBarrel(pos)
					local cf = CFrame.new(pos.X, pos.Y + barrelHalfHeight, pos.Z)
					if barrel:IsA("Model") then
						barrel:PivotTo(cf)
					elseif barrel:IsA("BasePart") then
						barrel.CFrame = cf
					end
				end

				moveBarrel(startPos)
				anchorAllBaseParts(barrel)

				-- Scripted lerp along the exact belt path (anchored, no physics bounce).
				-- Belt physics moves the PLAYER at the same speed — looks identical.
				local seg1Time = math.max(0.1, tweenSeconds * (seg1Len / totalLen))
				local seg2Time = math.max(0.1, tweenSeconds * (seg2Len / totalLen))

				task.spawn(function()
					local elapsed = 0
					while elapsed < seg1Time and barrel.Parent do
						local dt = task.wait()
						elapsed += dt
						moveBarrel(startPos:Lerp(cornerPos, math.min(1, elapsed / seg1Time)))
					end

					elapsed = 0
					while elapsed < seg2Time and barrel.Parent do
						local dt = task.wait()
						elapsed += dt
						moveBarrel(cornerPos:Lerp(endPos, math.min(1, elapsed / seg2Time)))
					end

					if not barrel.Parent then return end

					-- Barrel reached ConveyorEnd; animate it into the matching OilTank tube
					-- and destroy on arrival. No more on-dock pile; capacity is expressed by
					-- the tank's liquid fill level (see OilTankFx client FX).
					barrel:SetAttribute("OnConveyor", false)
					for _, d in ipairs(barrel:GetDescendants()) do
						if d:IsA("ProximityPrompt") then d.Enabled = false end
					end

					local tankCenter = endPos
					local oilTanks = plot:FindFirstChild("OilTanks")
					if oilTanks then
						for _, tube in ipairs(oilTanks:GetChildren()) do
							if tube:GetAttribute("OilType") == tier then
								local testTube = tube:FindFirstChild("test tube")
								local union = testTube and testTube:FindFirstChild("Union")
								if union and union:IsA("BasePart") then
									tankCenter = union.Position
								end
								break
							end
						end
					end

					local flyTime = 0.35
					local flyElapsed = 0
					while flyElapsed < flyTime and barrel.Parent do
						local dt = task.wait()
						flyElapsed += dt
						local alpha = math.min(1, flyElapsed / flyTime)
						moveBarrel(endPos:Lerp(tankCenter, alpha))
					end
					if barrel.Parent then
						barrel:Destroy()
					end
				end)
			end

		elseif desired < totalVisual then
			-- Remove excess barrels: pile first (top down), then conveyor
			local toRemove = totalVisual - desired
			-- Collect piled barrels sorted by pile position (highest first)
			local piledBarrels = {}
			for _, child in ipairs(barrelsFolder:GetChildren()) do
				if child:GetAttribute("Tier") == tier and not child:GetAttribute("OnConveyor") then
					table.insert(piledBarrels, child)
				end
			end
			table.sort(piledBarrels, function(a, b)
				local ay = a:IsA("BasePart") and a.Position.Y or (a:IsA("Model") and a:GetPivot().Position.Y or 0)
				local by = b:IsA("BasePart") and b.Position.Y or (b:IsA("Model") and b:GetPivot().Position.Y or 0)
				return ay > by -- highest first
			end)
			for _, barrel in ipairs(piledBarrels) do
				if toRemove <= 0 then break end
				barrel:Destroy()
				toRemove -= 1
			end
			-- If still need to remove, take from conveyor
			if toRemove > 0 then
				for _, child in ipairs(barrelsFolder:GetChildren()) do
					if toRemove <= 0 then break end
					if child:GetAttribute("Tier") == tier and child:GetAttribute("OnConveyor") then
						child:Destroy()
						toRemove -= 1
					end
				end
			end
		end
	end
end

function OilVisualService:_createBarrelForTier(tier: string, templateName: string?): Instance
	-- Try to clone from the per-type template in Assets
	if self._assetsFolder and templateName then
		local template = self._assetsFolder:FindFirstChild(templateName)
		if template then
			local clone = template:Clone()
			clone.Name = "Barrel_" .. tier .. "_" .. tostring(math.floor(tick() * 1000) % 100000)
			anchorAllBaseParts(clone)
			return clone
		end
	end

	-- Fallback: colored cylinder
	local colors = {
		HeavyCrude = Color3.fromRGB(30, 25, 20),
		LightSweet = Color3.fromRGB(220, 180, 60),
		PremiumRefined = Color3.fromRGB(200, 200, 210),
	}
	local part = Instance.new("Part")
	part.Name = "Barrel_" .. tier
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(2.2, 2, 2)
	part.Anchored = true
	part.CanCollide = false
	part.Material = Enum.Material.Metal
	part.Color = colors[tier] or Color3.fromRGB(165, 118, 46)
	part.Orientation = Vector3.new(0, 0, 90)
	return part
end

-- Returns which local axis ("x"|"y"|"z") of the part points most along world +Y or -Y,
-- plus its world-Y extent (the distance from center to top/bottom face in world-Y).
local function verticalAxis(part: BasePart): (string, number)
	local cf = part.CFrame
	local xY = math.abs(cf.RightVector.Y)
	local yY = math.abs(cf.UpVector.Y)
	local zY = math.abs(cf.LookVector.Y)
	if xY >= yY and xY >= zY then return "x", xY end
	if yY >= zY then return "y", yY end
	return "z", zY
end

-- Scale `part` so its extent along world-Y equals `newWorldYSize`, bottom anchored at `bottomWorldY`.
-- Other dimensions preserved.
local function setVerticalSize(part: BasePart, newWorldYSize: number, bottomWorldY: number)
	local axis, axisY = verticalAxis(part)
	-- Convert desired world-Y size to required local-axis size, accounting for how
	-- aligned that local axis is with world-Y (axisY is 1.0 for a perfectly-axis-aligned part).
	local requiredLocal = axisY > 1e-4 and newWorldYSize / axisY or newWorldYSize
	local s = part.Size
	if axis == "x" then
		part.Size = Vector3.new(requiredLocal, s.Y, s.Z)
	elseif axis == "y" then
		part.Size = Vector3.new(s.X, requiredLocal, s.Z)
	else
		part.Size = Vector3.new(s.X, s.Y, requiredLocal)
	end
	part.Position = Vector3.new(part.Position.X, bottomWorldY + newWorldYSize / 2, part.Position.Z)
end

local function currentWorldYExtent(part: BasePart): number
	local axis, axisY = verticalAxis(part)
	local s = part.Size
	local localSize = (axis == "x") and s.X or ((axis == "y") and s.Y or s.Z)
	return localSize * axisY
end

-- Per-plot OilTanks rig: each tube has a `liquid` Part whose world-vertical extent represents fill %.
-- Shell (Union) world-vertical extent scales linearly with tank tier. Server-authoritative so every
-- client sees consistent fill without needing per-player state replication.
function OilVisualService:_syncOilTanks(plot: Model, snapshot)
	local tanks = plot:FindFirstChild("OilTanks")
	if not tanks then return end

	local oilByTier = snapshot.oilByTier or {}
	local tankTiers = snapshot.tankTiers or {}
	local tankCapacities = snapshot.tankCapacities or {}
	local tankUpgradeCosts = snapshot.tankUpgradeCosts or {}
	local woodSignParts: { BasePart } = {}
	for _, child in ipairs(tanks:GetChildren()) do
		if child:IsA("Model") and child.Name == "Minecraft Wood Sign" then
			local signPart = child:FindFirstChild("Sign")
			if signPart and signPart:IsA("BasePart") then
				table.insert(woodSignParts, signPart)
			end
		end
	end
	local signByTube = {}
	local usedSigns = {}
	local tubeEntries = {}
	for _, tube in ipairs(tanks:GetChildren()) do
		local oilType = tube:GetAttribute("OilType")
		if typeof(oilType) ~= "string" then
			continue
		end
		local testTube = tube:FindFirstChild("test tube")
		local union = testTube and testTube:FindFirstChild("Union")
		local liquid = testTube and testTube:FindFirstChild("liquid")
		if union and union:IsA("BasePart") and liquid and liquid:IsA("BasePart") then
			table.insert(tubeEntries, { tube = tube, union = union })
		end
	end
	for _, entry in ipairs(tubeEntries) do
		local bestIdx = nil
		local bestDist = math.huge
		for idx, signPart in ipairs(woodSignParts) do
			if not usedSigns[idx] then
				local d = (signPart.Position - entry.union.Position).Magnitude
				if d < bestDist then
					bestDist = d
					bestIdx = idx
				end
			end
		end
		if bestIdx then
			usedSigns[bestIdx] = true
			signByTube[entry.tube] = woodSignParts[bestIdx]
		end
	end

	for _, tube in ipairs(tanks:GetChildren()) do
		local oilType = tube:GetAttribute("OilType")
		if typeof(oilType) ~= "string" then continue end

		local testTube = tube:FindFirstChild("test tube")
		local union = testTube and testTube:FindFirstChild("Union")
		local liquid = testTube and testTube:FindFirstChild("liquid")
		if not (union and union:IsA("BasePart") and liquid and liquid:IsA("BasePart")) then
			continue
		end

		local tier = OilTankConfig.ClampTier(tankTiers[oilType] or 1)
		local capacity = tankCapacities[oilType] or OilTankConfig.GetCapacity(tier)
		local amount = oilByTier[oilType] or 0
		local pct = capacity > 0 and math.clamp(amount / capacity, 0, 1) or 0
		-- High-capacity tanks can change by tiny percentages; keep a minimum visible
		-- fill whenever there's any oil so players can see it react.
		local visualPct = pct
		if amount > 0 then
			visualPct = math.max(visualPct, 0.04)
		end

		-- Resolve the shell's bottom Y in world: prefer authored attribute, else compute once from current state.
		local bottomY = tube:GetAttribute("UnionBottomY")
		if typeof(bottomY) ~= "number" then
			bottomY = union.Position.Y - currentWorldYExtent(union) / 2
		end

		-- Tier-scaled shell height in world-Y units.
		local targetShellY = OilTankConfig.GetShellHeight(tier)
		if math.abs(targetShellY - currentWorldYExtent(union)) > 0.05 then
			setVerticalSize(union, targetShellY, bottomY)
		end

		-- Fill: liquid world-vertical extent = shell's * pct, bottom at shell bottom.
		local liquidY = targetShellY * visualPct
		if liquidY < 0.01 then liquidY = 0.01 end -- tiny sliver so Part stays visible
		setVerticalSize(liquid, liquidY, bottomY)

		local col = OilTankConfig.OilColors[oilType]
		if col and liquid.Color ~= col then
			liquid.Color = col
		end

		-- Legacy floating sign: keep data updated but hide it from gameplay UI.
		local sign = union:FindFirstChild("TankSign")
		if sign and sign:IsA("BillboardGui") then
			sign.Enabled = false
			sign.AlwaysOnTop = true
			sign.LightInfluence = 0
		end
		local bg = sign and sign:FindFirstChild("Bg")
		if bg then
			local titleLabel = bg:FindFirstChild("Title")
			local capLabel = bg:FindFirstChild("Capacity")
			local costLabel = bg:FindFirstChild("Cost")
			if titleLabel then titleLabel.Text = oilType end
			if capLabel then
				capLabel.Text = string.format("Tier %d | %d / %d", tier, math.floor(amount), math.floor(capacity))
			end
			if costLabel then
				local cost = tankUpgradeCosts[oilType]
				if tier >= OilTankConfig.MaxTier or cost == nil then
					costLabel.Text = "MAXED"
					costLabel.TextColor3 = Color3.fromRGB(255, 180, 80)
				else
					costLabel.Text = string.format("Click to Upgrade $%d", cost)
					costLabel.TextColor3 = Color3.fromRGB(120, 220, 140)
				end
			end
		end

		-- Authoritative upgrade sign is the wood sign part near this tube.
		local woodSignPart = signByTube[tube]
		if woodSignPart and woodSignPart:IsA("BasePart") then
			-- Keep wood signs pinned to the refinery; never let physics drop them.
			woodSignPart.Anchored = true
			woodSignPart.CanCollide = false
			-- Must stay queryable so ClickDetector hover/click works.
			woodSignPart.CanQuery = true
			woodSignPart.CanTouch = false
			woodSignPart.Massless = true
			woodSignPart:SetAttribute("OilType", oilType)
			local signModel = woodSignPart.Parent
			if signModel and signModel:IsA("Model") then
				signModel:SetAttribute("OilType", oilType)
				for _, d in ipairs(signModel:GetDescendants()) do
					if d:IsA("BasePart") then
						d.Anchored = true
						d.CanCollide = false
						-- Keep all sign parts targetable for hover/click affordance.
						d.CanQuery = true
						d.CanTouch = false
						d.Massless = true
					end
				end
			end

			local signClick = woodSignPart:FindFirstChild("TankUpgradeSignClick")
			if signClick and not signClick:IsA("ClickDetector") then
				signClick:Destroy()
				signClick = nil
			end
			if not signClick then
				local cd = Instance.new("ClickDetector")
				cd.Name = "TankUpgradeSignClick"
				cd.MaxActivationDistance = 22
				cd.CursorIcon = "rbxasset://textures/Cursors/KeyboardMouse/PointingHandCursor.png"
				cd.Parent = woodSignPart
			elseif signClick:IsA("ClickDetector") then
				signClick.CursorIcon = "rbxasset://textures/Cursors/KeyboardMouse/PointingHandCursor.png"
				signClick.MaxActivationDistance = math.max(22, signClick.MaxActivationDistance)
			end

			local surfaceGui = woodSignPart:FindFirstChildOfClass("SurfaceGui")
			if surfaceGui then
				-- Let ClickDetector handle click; sign text does not need GUI input.
				surfaceGui.Active = false
				local signLabel = surfaceGui:FindFirstChild("SIGN")
				if not (signLabel and signLabel:IsA("TextLabel")) then
					for _, ui in ipairs(surfaceGui:GetDescendants()) do
						if ui:IsA("TextLabel") then
							signLabel = ui
							break
						end
					end
				end
				if signLabel and signLabel:IsA("TextLabel") then
					local cost = tankUpgradeCosts[oilType]
					if tier >= OilTankConfig.MaxTier or cost == nil then
						signLabel.Text = string.format("%s\n%d/%d\nMAXED", oilType, math.floor(amount), math.floor(capacity))
					else
						signLabel.Text = string.format(
							"%s\n%d/%d\nClick to Upgrade\n$%d",
							oilType,
							math.floor(amount),
							math.floor(capacity),
							cost
						)
					end
				end
			end
		end

		-- Legacy union click path removed.
		local unionClick = union:FindFirstChild("TankUpgradeClick")
		if unionClick and unionClick:IsA("ClickDetector") then
			unionClick:Destroy()
		end

		-- Prompt path fully removed; upgrades are sign click/tap only.
		local prompt = union:FindFirstChild("TankUpgradePrompt", true)
		if prompt and prompt:IsA("ProximityPrompt") then
			prompt:Destroy()
		end
	end
end

return OilVisualService
