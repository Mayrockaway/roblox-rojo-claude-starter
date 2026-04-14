--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local OilConfig = require(Shared:WaitForChild("Config"):WaitForChild("OilConfig"))

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

	self:_syncDrills(plot, drillsFolder, snapshot.drills or {})
	self:_syncActiveDrills(plot, activeDrillsFolder, snapshot.activeDrills or {})
	self:_syncActiveProspectors(plot, activeProspectorsFolder, snapshot.activeProspectors or {})
	self:_syncOilSprays(plot, spraysFolder, snapshot)
	self:_syncPipes(plot, pipesFolder, snapshot.pipes or {}, snapshot.drills or {}, snapshot.drums or {})
	self:_syncDrums(plot, drumsFolder, snapshot.drums or {})
	self:_syncBarrels(plot, barrelsFolder, snapshot)
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
function OilVisualService:_syncActiveProspectors(_plot: Model, folder: Folder, activeProspectors)
	local wanted = {}
	for _, entry in ipairs(activeProspectors) do
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
	end
	for _, child in ipairs(folder:GetChildren()) do
		if not wanted[child.Name] then child:Destroy() end
	end
end

function OilVisualService:_syncActiveDrills(_plot: Model, folder: Folder, activeDrills)
	local wanted = {}
	for _, entry in ipairs(activeDrills) do
		local drillId = entry.drillId
		if typeof(drillId) ~= "number" or typeof(entry.position) ~= "table" then continue end
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
			local px = tonumber(entry.position.x) or 0
			local py = tonumber(entry.position.y) or 0
			local pz = tonumber(entry.position.z) or 0
			anchor.Position = Vector3.new(px, py + 3, pz)
		end

		-- Only set CFrame on creation; the client's animation loop owns the CFrame after that,
		-- otherwise snapshot pushes would stomp the sink/spin every tick.
		if justCreated then
			local px = tonumber(entry.position.x) or 0
			local py = tonumber(entry.position.y) or 0
			local pz = tonumber(entry.position.z) or 0
			-- Compute pivot→bottom offset so the model's actual bbox bottom sits on the surface,
			-- regardless of where the model's pivot is authored (fixes hovering assets).
			local pivotToBottom = 0
			if model:IsA("Model") then
				local bbCF, bbSize = model:GetBoundingBox()
				local pivotY = model:GetPivot().Position.Y
				pivotToBottom = pivotY - (bbCF.Position.Y - bbSize.Y / 2)
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
	for _, a in ipairs(snapshot.activeDrills or {}) do
		-- We'll key active drills by chunkId:tileKey (same as sprays below).
		if a.chunkId and a.tileKey then
			activeCellKeys[a.chunkId .. ":" .. a.tileKey] = true
		end
	end

	local wanted = {}
	for _, chunk in ipairs(snapshot.chunks or {}) do
		if chunk.tiles and chunk.unlocked then
			for tileKey, tile in pairs(chunk.tiles) do
				-- Dry holes (hasOil == false) never spawn a spray
				if tile and tile.drilled and tile.hasOil ~= false then
					local spraySig = chunk.chunkId .. ":" .. tileKey
					-- If a pump exists on this cell, suppress the spray. We have to map tileKey -> cellKey.
					-- For now rely on the broadcast "pumpPlaced" event + state push; the server snapshot
					-- has enough data because the newly placed pump will clear drilled visibility below
					-- via cellKey match heuristic. Simpler: check if any pump has matching tileKey.
					local hasPump = false
					for _, d in ipairs(snapshot.drills or {}) do
						if d.tileKey == tileKey and d.chunkId == chunk.chunkId then
							hasPump = true; break
						end
					end
					if not hasPump and not activeCellKeys[spraySig] then
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

function OilVisualService:_syncDrills(_plot: Model, drillsFolder: Folder, drills)
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

			-- Apply target scale. On FIRST creation, start at ~0 then tween up for the fill-up animation.
			if model:IsA("Model") and model:GetAttribute("AppliedScale") ~= scale then
				if justCreated then
					model:ScaleTo(0.01)
				else
					model:ScaleTo(scale)
					model:SetAttribute("AppliedScale", scale)
				end
			end

			-- Compute the pivot→bottom Y offset so the pump's actual bbox bottom sits on the ground,
			-- regardless of where the model's pivot is authored. Fixes pumps hovering above tiles.
			local pivotToBottom = 0
			if model:IsA("Model") then
				local bbCF, bbSize = model:GetBoundingBox()
				local pivotY = model:GetPivot().Position.Y
				local bbBottomY = bbCF.Position.Y - bbSize.Y / 2
				pivotToBottom = pivotY - bbBottomY
			elseif model:IsA("BasePart") then
				pivotToBottom = (model :: BasePart).Size.Y / 2
			end
			local targetCf = CFrame.new(px, py + DRILL_HEIGHT_OFFSET + pivotToBottom, pz)
			if model:IsA("Model") then
				model:PivotTo(targetCf)
			elseif model:IsA("BasePart") then
				model.CFrame = targetCf
			end
			anchorAllBaseParts(model)

			-- Fill-up animation for fresh placements: tween scale 0.01 → target over ~0.7s
			if justCreated and model:IsA("Model") then
				local currentScale = 0.01
				local targetScale = scale
				local startT = os.clock()
				local DUR = 0.7
				local animModel = model
				task.spawn(function()
					while animModel and animModel.Parent do
						local a = math.min((os.clock() - startT) / DUR, 1)
						-- Ease: backout — pop past target then settle
						local eased = 1 - (1 - a) * (1 - a) * (1 - a)
						local sc = currentScale + (targetScale - currentScale) * eased
						animModel:ScaleTo(sc)
						animModel:PivotTo(targetCf)
						if a >= 1 then break end
						task.wait()
					end
					if animModel and animModel.Parent then
						animModel:SetAttribute("AppliedScale", targetScale)
					end
				end)
			end

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
		end
	end

	for _, child in ipairs(drillsFolder:GetChildren()) do
		local key = string.gsub(child.Name, "^Drill_", "")
		if not wanted[key] then
			child:Destroy()
		end
	end
end

function OilVisualService:_syncPipes(_plot: Model, pipesFolder: Folder, pipes, drills, drums)
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

			-- Lookup ACTUAL tile top Y — pipe.position.y is often stale/default(6) and makes
			-- the pipe float above the real tile. Find the tile part by sectionId+row/col.
			if pipe.sectionId then
				local sectionModel = self._plotService:GetChunkModel(_plot, pipe.sectionId)
				if sectionModel then
					-- Convert global row/col to local tile name "T<localR><localC>"
					local localR = ((pipe.row - 1) % 5) + 1
					local localC = ((pipe.col - 1) % 5) + 1
					local tilePart = sectionModel:FindFirstChild(string.format("T%d%d", localR, localC))
					if tilePart and tilePart:IsA("BasePart") then
						py = tilePart.Position.Y + tilePart.Size.Y / 2
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

function OilVisualService:_syncDrums(_plot: Model, drumsFolder: Folder, drums)
	local wanted = {}
	local drumTemplate = self._assetsFolder and self._assetsFolder:FindFirstChild("Drum")

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
			if model:IsA("Model") then
				model:PivotTo(CFrame.new(px, py, pz))
			elseif model:IsA("BasePart") then
				model.CFrame = CFrame.new(px, py, pz)
			end
			anchorAllBaseParts(model)
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
	local totalOilDebug = (oilByTier.HeavyCrude or 0) + (oilByTier.LightSweet or 0) + (oilByTier.PremiumRefined or 0)
	if totalOilDebug > 0 then
		print(string.format("[_syncBarrels] called. HC=%d LS=%d PR=%d total=%d",
			oilByTier.HeavyCrude or 0,
			oilByTier.LightSweet or 0, oilByTier.PremiumRefined or 0, totalOilDebug))
	end
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

		if desired > 0 then
			print(string.format("[Barrels] %s oil=%d desired=%d", tier, oil, desired))
		end

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

					barrel:SetAttribute("OnConveyor", false)
					for _, d in ipairs(barrel:GetDescendants()) do
						if d:IsA("ProximityPrompt") then d.Enabled = false end
					end

					local pileRoot = staging:FindFirstChild("PileRoot_" .. tier)
					if pileRoot then
						local pileIdx = 0
						for _, ch in ipairs(barrelsFolder:GetChildren()) do
							if ch:GetAttribute("Tier") == tier and not ch:GetAttribute("OnConveyor") and ch ~= barrel then
								pileIdx += 1
							end
						end
						local stackPos = pileRoot.Position + Vector3.new(0, pileIdx * barrelHeight, 0)
						moveBarrel(stackPos)
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

return OilVisualService
