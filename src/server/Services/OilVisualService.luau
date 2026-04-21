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
local OIL_REVEAL_SPRAY_SECONDS = 2.0
local OIL_TUBE_REVEAL_DURATION = 1.5
local OIL_TUBE_VISIBLE_TRANSPARENCY = 0.5
local OIL_TUBE_ENDPOINT_EPSILON = 0.05
local BARREL_CONVEYOR_MIN_EJECT_INTERVAL = 0.25
local IGNORE_FOR_VISUAL_BOUNDS_ATTR = "IgnoreForVisualBounds"
local TIER_ORDER = { "Crude", "Refined", "Premium" }
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
local function shouldIgnoreForVisualBounds(part: BasePart): boolean
	if part:GetAttribute(IGNORE_FOR_VISUAL_BOUNDS_ATTR) == true then
		return true
	end
	-- Backward-compatible safety for tiny invisible helper anchors even when the
	-- explicit attribute hasn't been authored yet.
	if part.Transparency >= 1 and part.Size.Magnitude < 2 then
		return true
	end
	return false
end
local function ensureBarrelMultiplierGui(instance: Instance, multiplier: number)
	if multiplier <= 1 then
		return
	end
	local adornee = getFirstBasePart(instance)
	if not adornee then
		return
	end
	local gui = adornee:FindFirstChild("BarrelMultiplierGui")
	if gui and not gui:IsA("BillboardGui") then
		gui:Destroy()
		gui = nil
	end
	local bb = if gui and gui:IsA("BillboardGui") then gui else Instance.new("BillboardGui")
	bb.Name = "BarrelMultiplierGui"
	bb.Size = UDim2.fromOffset(110, 42)
	bb.StudsOffsetWorldSpace = Vector3.new(0, 4.2, 0)
	bb.AlwaysOnTop = true
	bb.MaxDistance = 180
	bb.Parent = adornee

	local label = bb:FindFirstChild("Label")
	if label and not label:IsA("TextLabel") then
		label:Destroy()
		label = nil
	end
	local text = if label and label:IsA("TextLabel") then label else Instance.new("TextLabel")
	text.Name = "Label"
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.GothamBlack
	text.TextScaled = true
	text.Text = string.format("x%d", multiplier)
	text.TextColor3 = Color3.fromRGB(255, 212, 74)
	text.TextStrokeTransparency = 0
	text.TextStrokeColor3 = Color3.fromRGB(72, 48, 10)
	text.Parent = bb
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
local function stripBarrelProximityPrompts(root: Instance)
	local toDestroy: { ProximityPrompt } = {}
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("ProximityPrompt") then
			table.insert(toDestroy, d)
		end
	end
	for _, p in ipairs(toDestroy) do
		p:Destroy()
	end
end
-- Catalog `visualGroundOffsetStuds` (world studs at unit scale) Ã— placed pump scale.
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
local function stripOilVisualSuffix(sig: string): string
	local coreSig = sig:gsub("_end$", "")
	coreSig = coreSig:gsub("_Crude$", "")
	coreSig = coreSig:gsub("_Refined$", "")
	coreSig = coreSig:gsub("_Premium$", "")
	return coreSig
end
local function getHighestBasePartTopPosition(instance: Instance?): Vector3?
	if not instance then
		return nil
	end
	local bestTop = -math.huge
	local bestPos = nil :: Vector3?
	local function considerPart(part: BasePart)
		if shouldIgnoreForVisualBounds(part) then return end
		local topY = part.Position.Y + part.Size.Y / 2
		if topY > bestTop then
			bestTop = topY
			bestPos = Vector3.new(part.Position.X, topY, part.Position.Z)
		end
	end
	if instance:IsA("BasePart") then
		considerPart(instance)
	end
	for _, d in ipairs(instance:GetDescendants()) do
		if d:IsA("BasePart") then
			considerPart(d)
		end
	end
	return bestPos
end
local function getBasePartWorldHalfHeight(part: BasePart): number
	local sx, sy, sz = part.Size.X / 2, part.Size.Y / 2, part.Size.Z / 2
	local cf = part.CFrame
	return math.abs(cf.RightVector.Y) * sx + math.abs(cf.UpVector.Y) * sy + math.abs(cf.LookVector.Y) * sz
end
local function getInstanceBottomOffset(instance: Instance): number
	if instance:IsA("BasePart") then
		return getBasePartWorldHalfHeight(instance)
	end
	local pivot = instance:GetPivot()
	local boundsCf, boundsSize = instance:GetBoundingBox()
	if boundsSize.Y <= 0 then
		return 0
	end
	local boundsBottomY = boundsCf.Position.Y - boundsSize.Y / 2
	return math.max(0, pivot.Position.Y - boundsBottomY)
end
local function getInstanceFootprint(instance: Instance): number
	if instance:IsA("BasePart") then
		return math.max(instance.Size.X, instance.Size.Z)
	end
	local _, size = instance:GetBoundingBox()
	return math.max(size.X, size.Z)
end
local function conveyorPathPosition(startPos: Vector3, cornerPos: Vector3, endPos: Vector3, seg1Len: number, seg2Len: number, distance: number): Vector3
	local startToCorner = cornerPos - startPos
	local startDir = startToCorner.Magnitude > 1e-4 and startToCorner.Unit or Vector3.new(0, 0, -1)
	if distance <= 0 then
		return startPos + startDir * distance
	end
	if seg1Len > 1e-4 and distance < seg1Len then
		return startPos:Lerp(cornerPos, distance / seg1Len)
	end
	local seg2Distance = distance - seg1Len
	if seg2Len > 1e-4 and seg2Distance < seg2Len then
		return cornerPos:Lerp(endPos, math.max(0, seg2Distance) / seg2Len)
	end
	return endPos
end
local PUMP_ENDPOINT_Y_OFFSET = -2.4 -- tubes enter inside the pump body
local function getCenterPumpEndpoint(plot: Model, sectionModel: Instance, centerTile: BasePart, drills: { any }?, chunkId: string): Vector3
	local fallback = Vector3.new(centerTile.Position.X, centerTile.Position.Y + centerTile.Size.Y / 2 + 7, centerTile.Position.Z)
	local visualRoot = plot:FindFirstChild("OilVisuals")
	local drillsFolder = visualRoot and visualRoot:FindFirstChild("Drills")
	if drillsFolder then
		for _, drill in ipairs(drills or {}) do
			if drill.isCenterPump == true and drill.chunkId == chunkId and typeof(drill.drillId) == "number" then
				local pumpVisual = drillsFolder:FindFirstChild("Drill_" .. tostring(drill.drillId))
				local topPos = getHighestBasePartTopPosition(pumpVisual)
				if topPos then
					return topPos + Vector3.new(0, PUMP_ENDPOINT_Y_OFFSET, 0)
				end
			end
		end
	end
	local pumpModel = sectionModel:FindFirstChild("CenterPump")
	local topPos = getHighestBasePartTopPosition(pumpModel)
	if topPos then
		return topPos + Vector3.new(0, PUMP_ENDPOINT_Y_OFFSET, 0)
	end
	return fallback
end
local function getTubeRevealStartedAt(visualsStartedAt: any, now: number): number
	if typeof(visualsStartedAt) == "number" then
		return (visualsStartedAt :: number) + OIL_REVEAL_SPRAY_SECONDS
	end
	return now - OIL_TUBE_REVEAL_DURATION
end
local SELL_BACK_PROMPT = "SellBackPrompt"
local SELL_BACK_ATTACH = "SellBackPromptAttachment"
type SellPromptSpec = {
	ownerUserId: number,
	hammerKind: string,
	drillId: number?,
	cellKey: string?,
	--- FTUE tutorial placements: no sell-back prompt (and server rejects hammer salvage).
	noSellback: boolean?,
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
	if spec.hammerKind == "drill" then
		local id = spec.drillId
		if typeof(id) ~= "number" then
			return nil
		end
		return { targetKind = "drill", targetId = id }
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
			fireOilActionResult(player, false, "ERR_TOO_FAR", "Move closer to sell back.", nil)
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
	prompt.ObjectText = if spec.hammerKind == "drill" then "Drill" else "Equipment"
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
end
local function removeSellBackPromptFromHost(host: Instance)
	local adornee = basePartForSellPrompt(host)
	if not adornee then
		return
	end
	local att = adornee:FindFirstChild(SELL_BACK_ATTACH) :: Attachment?
	if not att then
		return
	end
	local prompt = att:FindFirstChild(SELL_BACK_PROMPT)
	if prompt and prompt:IsA("ProximityPrompt") then
		disconnectSellBackPrompt(prompt)
		prompt:Destroy()
	end
end
local function ensureSellBackPromptOnHost(service: OilVisualService, host: Instance, spec: SellPromptSpec)
	-- Sell-back/removal prompts disabled â€” center pump system, no removable equipment
	removeSellBackPromptFromHost(host)
	do return end
	if not host or not host.Parent then
		return
	end
	if spec.noSellback == true then
		removeSellBackPromptFromHost(host)
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
	local spraysFolder = ensureFolder(visualRoot, "OilSprays")
	local barrelsFolder = ensureFolder(visualRoot, "Barrels")

	-- Drills-only refactor: nuke any leftover ActiveProspectors / Pipes / Drums folders so
	-- existing places shed legacy visuals on next snapshot.
	for _, leftover in ipairs({ "ActiveProspectors", "Pipes", "Drums" }) do
		local f = visualRoot:FindFirstChild(leftover)
		if f then
			f:Destroy()
		end
	end

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
	run("Visual.syncDrills", function() self:_syncDrills(plot, drillsFolder, snapshot.drills or {}, userId, snapshot) end)
	run("Visual.syncActiveDrills", function() self:_syncActiveDrills(plot, activeDrillsFolder, snapshot.activeDrills or {}, userId) end)
	run("Visual.syncOilSprays", function() self:_syncOilSprays(plot, spraysFolder, snapshot) end)
	run("Visual.syncBarrels", function() self:_syncBarrels(plot, barrelsFolder, snapshot) end)
	run("Visual.syncOilTanks", function() self:_syncOilTanks(plot, snapshot) end)
	self:_ensureDepthBanners(plot)
end
function OilVisualService:_ensureDepthBanners(plot: Model)
	local bannersFolder = plot:FindFirstChild("DepthBanners")
	if bannersFolder then return end -- already created
	bannersFolder = Instance.new("Folder")
	bannersFolder.Name = "DepthBanners"
	bannersFolder.Parent = plot

	local VeinConfig = require(Shared:WaitForChild("Config"):WaitForChild("VeinConfig"))
	local ground = plot:FindFirstChild("PlotGround")
	if not ground then return end

	-- Row layout: S01_01-S01_03 (row 1), S02_01-S02_03 (row 2), etc.
	for row = 1, 4 do
		local groundDef = VeinConfig.GroundByRow[row]
		if not groundDef then continue end

		-- Find the 3 sections in this row and compute bounding box
		local minX, maxX, minZ, maxZ, avgY = math.huge, -math.huge, math.huge, -math.huge, 0
		local sectionCount = 0
		for col = 1, 3 do
			local sectionId = string.format("S%02d_%02d", row, col)
			local section = ground:FindFirstChild(sectionId)
			if section and section:IsA("Model") then
				local cf, size = section:GetBoundingBox()
				local pos = cf.Position
				minX = math.min(minX, pos.X - size.X / 2)
				maxX = math.max(maxX, pos.X + size.X / 2)
				minZ = math.min(minZ, pos.Z - size.Z / 2)
				maxZ = math.max(maxZ, pos.Z + size.Z / 2)
				avgY = avgY + pos.Y
				sectionCount += 1
			end
		end
		if sectionCount == 0 then continue end
		avgY = avgY / sectionCount

		local bannerWidth = maxX - minX
		local bannerHeight = 8
		local centerX = (minX + maxX) / 2
		local centerZ = (minZ + maxZ) / 2

		local banner = Instance.new("Part")
		banner.Name = "DepthBanner_Row" .. row
		banner.Size = Vector3.new(bannerWidth, bannerHeight, 0.2)
		banner.Position = Vector3.new(centerX, avgY + 45, centerZ)
		banner.Anchored = true
		banner.CanCollide = false
		banner.CanQuery = false
		banner.CanTouch = false
		banner.Transparency = 0.65
		banner.Material = Enum.Material.Neon
		banner.Color = groundDef.color
		banner.Parent = bannersFolder

		local surfaceGui = Instance.new("SurfaceGui")
		surfaceGui.Name = "BannerGui"
		surfaceGui.Face = Enum.NormalId.Front
		surfaceGui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		surfaceGui.PixelsPerStud = 20
		surfaceGui.Parent = banner

		local label = Instance.new("TextLabel")
		label.Name = "DepthLabel"
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.GothamBold
		label.TextScaled = true
		label.TextColor3 = Color3.fromRGB(255, 255, 255)
		label.TextStrokeTransparency = 0
		label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
		label.Text = string.format("OIL AT %s meters", tostring(groundDef.depthMeters or groundDef.drillSeconds))
		label.Parent = surfaceGui

		-- Back face too so it's readable from both sides
		local backGui = surfaceGui:Clone()
		backGui.Face = Enum.NormalId.Back
		backGui.Parent = banner
	end
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
-- (drills-only refactor) Removed: _syncActiveProspectors. Prospecting was deleted.
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

local function highestWorldYOfPartOBB(part: BasePart): number
	local cf, sz = part.CFrame, part.Size
	local hx, hy, hz = sz.X / 2, sz.Y / 2, sz.Z / 2
	local highestY = -math.huge
	for _, o in ipairs({
		Vector3.new(hx, hy, hz),
		Vector3.new(-hx, hy, hz),
		Vector3.new(hx, -hy, hz),
		Vector3.new(-hx, -hy, hz),
		Vector3.new(hx, hy, -hz),
		Vector3.new(-hx, hy, -hz),
		Vector3.new(hx, -hy, -hz),
		Vector3.new(-hx, -hy, -hz),
	}) do
		local wy = (cf * o).Y
		if wy > highestY then
			highestY = wy
		end
	end
	return highestY
end

local function getActiveDrillTimerAnchorPosition(model: Instance, fallbackPosition: Vector3): Vector3
			if model:IsA("Model") then
		local topY = -math.huge
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") and not shouldIgnoreForVisualBounds(d) then
				topY = math.max(topY, highestWorldYOfPartOBB(d))
			end
		end
		if topY > -math.huge then
			local bbCf, _ = model:GetBoundingBox()
			return Vector3.new(bbCf.Position.X, topY + 0.5, bbCf.Position.Z)
		end
	elseif model:IsA("BasePart") then
		local topY = highestWorldYOfPartOBB(model)
		return Vector3.new(model.Position.X, topY + 0.5, model.Position.Z)
	end
	return fallbackPosition
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
			model:SetAttribute("DepthMeters", tonumber(entry.depthMeters) or 0)
			model:SetAttribute("MetersPerSecond", tonumber(entry.metersPerSecond) or 1)
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
			anchor:SetAttribute(IGNORE_FOR_VISUAL_BOUNDS_ATTR, true)
			anchor.Parent = folder
			local bb = Instance.new("BillboardGui")
			bb.Name = "TimerGui"
			bb.Adornee = anchor
			bb.Size = UDim2.new(0, 160, 0, 60)
			bb.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
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
			lbl.TextWrapped = false
			lbl.TextTruncate = Enum.TextTruncate.None
			lbl.Text = "--"
			lbl.Parent = bb
			local lblCorner = Instance.new("UICorner")
			lblCorner.CornerRadius = UDim.new(0, 6)
			lblCorner.Parent = lbl
			-- NOTE: do NOT add UIPadding or UITextSizeConstraint here.
			-- TextScaled lets the label fill the full 160x60 box; padding +
			-- a low MaxTextSize cap previously shrank the depth/timer text to
			-- almost-illegible — keep the box wide-open so 2-line text still
			-- renders large.
			anchor:SetAttribute("StartTime", tonumber(entry.startTime) or 0)
			anchor:SetAttribute("EndTime", tonumber(entry.endTime) or 0)
			anchor:SetAttribute("DepthMeters", tonumber(entry.depthMeters) or 0)
			anchor:SetAttribute("MetersPerSecond", tonumber(entry.metersPerSecond) or 1)
		end
		model:SetAttribute("StartTime", tonumber(entry.startTime) or 0)
		model:SetAttribute("EndTime", tonumber(entry.endTime) or 0)
		model:SetAttribute("Duration", math.max(0.01, (tonumber(entry.endTime) or 0) - (tonumber(entry.startTime) or 0)))
		model:SetAttribute("OilType", entry.oilType)
		model:SetAttribute("DrillId", drillId)
		model:SetAttribute("DepthMeters", tonumber(entry.depthMeters) or 0)
		model:SetAttribute("MetersPerSecond", tonumber(entry.metersPerSecond) or 1)
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
		local anchor = folder:FindFirstChild(timerName)
		if anchor and anchor:IsA("BasePart") then
			anchor:SetAttribute("StartTime", tonumber(entry.startTime) or 0)
			anchor:SetAttribute("EndTime", tonumber(entry.endTime) or 0)
			anchor:SetAttribute("DepthMeters", tonumber(entry.depthMeters) or 0)
			anchor:SetAttribute("MetersPerSecond", tonumber(entry.metersPerSecond) or 1)
			anchor.Position = getActiveDrillTimerAnchorPosition(model, Vector3.new(px, py + 3, pz))

			-- Strip stale TimerLabel padding/cap from labels created by an earlier
			-- code path so existing live drills get the larger depth/timer text
			-- without needing a server restart.
			local timerBb = anchor:FindFirstChild("TimerGui")
			local timerLbl = timerBb and timerBb:FindFirstChild("TimerLabel")
			if timerLbl and timerLbl:IsA("TextLabel") then
				local stalePad = timerLbl:FindFirstChildOfClass("UIPadding")
				if stalePad then stalePad:Destroy() end
				local staleConstraint = timerLbl:FindFirstChildOfClass("UITextSizeConstraint")
				if staleConstraint then staleConstraint:Destroy() end
			end
		end
		if model then
			ensureSellBackPromptOnHost(self, model, {
				ownerUserId = ownerUserId,
				hammerKind = "drill",
				drillId = drillId,
				noSellback = entry.ftueFreeNoSellback == true,
			})
		end
	end
	for _, child in ipairs(folder:GetChildren()) do
		if not wanted[child.Name] then child:Destroy() end
	end
end
-- Persistent oil spray on any tile that has been drilled but doesn't yet have a pump.
-- One ParticleEmitter-bearing invisible Part per qualifying tile, colored per oil type.
function OilVisualService:_syncOilSprays(_plot: Model, folder: Folder, snapshot)
	local now = workspace:GetServerTimeNow()
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
	local subTilesPerSide = 5
	local pipeTileSigs = {}
	for _, pipe in ipairs(snapshot.pipes or {}) do
		if typeof(pipe.row) == "number" and typeof(pipe.col) == "number" then
			local sectionId = pipe.sectionId
			if typeof(sectionId) == "string" then
				local chunkRow = math.floor((pipe.row - 1) / subTilesPerSide) + 1
				local chunkCol = math.floor((pipe.col - 1) / subTilesPerSide) + 1
				local localR = pipe.row - (chunkRow - 1) * subTilesPerSide
				local localC = pipe.col - (chunkCol - 1) * subTilesPerSide
				if localR >= 1 and localR <= subTilesPerSide and localC >= 1 and localC <= subTilesPerSide then
					pipeTileSigs[sectionId .. ":T" .. localR .. localC] = true
				end
			end
		end
	end

	local wantedSprays = {}
	local wantedPuddles = {}
	local wantedTubes = {}
	for _, chunk in ipairs(snapshot.chunks or {}) do
		if chunk.tiles and chunk.unlocked then
			for tileKey, tile in pairs(chunk.tiles) do
				if tile and tile.drilled and tile.hasOil ~= false and not tile.revealPending then
					local sig = chunk.chunkId .. ":" .. tileKey
					local hasPump = false
					for _, d in ipairs(snapshot.drills or {}) do
						if d.tileKey == tileKey and d.chunkId == chunk.chunkId then
							hasPump = true
							break
						end
					end
					local coveredByPipe = pipeTileSigs[sig] == true
					if not hasPump and not activeCellKeys[sig] and not coveredByPipe then
						local info = { chunk = chunk, tileKey = tileKey, tile = tile }
						wantedPuddles[sig] = info
						local visualsStartedAt = tile.visualsStartedAt
						if typeof(visualsStartedAt) == "number" then
							if now < (visualsStartedAt :: number) + OIL_REVEAL_SPRAY_SECONDS then
								wantedSprays[sig] = info
							else
								wantedTubes[sig] = info
							end
						end
					end
				end
			end
		end
	end

	local function spawnPuddleForTile(sig: string, info: any)
		local childName = "Puddle_" .. sig
		local part = folder:FindFirstChild(childName)
		local oilType = info.tile.oilType or "Crude"
		local color = (OilConfig.OilSprayColors and OilConfig.OilSprayColors[oilType])
			or Color3.fromRGB(30, 30, 30)
		if part and not part:IsA("BasePart") then
			part:Destroy()
			part = nil
		end
		if not part then
			local template = self._assetsFolder and self._assetsFolder:FindFirstChild("Puddle")
			if template and template:IsA("BasePart") then
				part = template:Clone()
				part.Name = childName
				part.Anchored = true
				part.CanCollide = false
				part.CanQuery = false
				part.CanTouch = false
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
						part.Size = Vector3.new(6.5, part.Size.Y, 6.5)
						part.Position = Vector3.new(tilePart.Position.X, topY + part.Size.Y / 2, tilePart.Position.Z)
					end
				end
			end
		end

	local function eachTileVisualVariant(info: any, callback: (string?, Vector3?, string?) -> ())
		local veinResult = info.tile.veinResult
		if veinResult and typeof(veinResult) == "table" and typeof(veinResult.veins) == "table" and #veinResult.veins > 0 then
			local VeinConfig = require(Shared:WaitForChild("Config"):WaitForChild("VeinConfig"))
			local offsets = {
				[1] = { Vector3.new(0, 0, 0) },
				[2] = { Vector3.new(-1.25, 0, 0), Vector3.new(1.25, 0, 0) },
				[3] = { Vector3.new(-1.5, 0, -1), Vector3.new(1.5, 0, -1), Vector3.new(0, 0, 1.7) },
			}
			local count = math.clamp(#veinResult.veins, 1, 3)
			for index, vein in ipairs(veinResult.veins) do
				local internalOil = VeinConfig.GetInternalOilName(vein.oilType)
				callback(internalOil, offsets[count][index] or Vector3.new(0, 0, 0), vein.streamType)
			end
			return
		end
		if info.tile.tileName == "SUPER TILE" then
			callback("Crude", Vector3.new(-1.5, 0, -1.5), "Stream")
			callback("Refined", Vector3.new(1.5, 0, -1.5), "Burst")
			callback("Premium", Vector3.new(0, 0, 1.8), "Geyser")
			return
		end
		callback(nil, nil, nil)
	end

	local function syncSprayForTile(sig: string, info: any, oilTypeOverride: string?, offset: Vector3?, _streamTypeOverride: string?)
		local suffix = oilTypeOverride and ("_" .. oilTypeOverride) or ""
		local childName = "Spray_" .. sig .. suffix
		local part = folder:FindFirstChild(childName)
		if part and not part:IsA("BasePart") then
			part:Destroy()
			part = nil
		end
		if not part then
			local oilType = oilTypeOverride or info.tile.oilType or "Crude"
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
				for _, emitter in ipairs(part:GetDescendants()) do
					if emitter:IsA("ParticleEmitter") then
						emitter.Enabled = true
					end
				end
			end
		end
	end

	local function syncTubeForTile(sig: string, info: any, oilTypeOverride: string?, offset: Vector3?, streamTypeOverride: string?)
		local sectionModel = self._plotService:GetChunkModel(_plot, info.chunk.chunkId)
		if not sectionModel then
			return
		end
		local tilePart = sectionModel:FindFirstChild(info.tileKey)
		local centerTile = sectionModel:FindFirstChild("T33")
		if not (tilePart and tilePart:IsA("BasePart") and centerTile and centerTile:IsA("BasePart")) then
			return
		end
		if info.tileKey == "T33" then
			return
		end
		local baseOffset = offset or Vector3.new(0, 0, 0)
		local tileTopY = tilePart.Position.Y + tilePart.Size.Y / 2
		local startPos = Vector3.new(tilePart.Position.X, tileTopY, tilePart.Position.Z) + baseOffset
		local endPos = getCenterPumpEndpoint(_plot, sectionModel, centerTile, snapshot.drills or {}, info.chunk.chunkId)
		local oilType = oilTypeOverride or info.tile.oilType or "Crude"
		local tubeColor = Color3.fromRGB(60, 50, 35)
		local isRainbow = false
		if oilType == "Refined" or oilType == "GoodOil" then
			tubeColor = Color3.fromRGB(255, 200, 50)
		elseif oilType == "Premium" or oilType == "GoldOil" then
			isRainbow = true
			tubeColor = Color3.fromRGB(255, 100, 100)
		end
		local streamType = streamTypeOverride or "Stream"
		local veinResult = info.tile.veinResult
		if not streamTypeOverride and veinResult and typeof(veinResult) == "table" and veinResult.veins and typeof(veinResult.veins) == "table" and #veinResult.veins > 0 then
			streamType = veinResult.veins[1].streamType or "Stream"
		end
		local actualDiameter = 0.55
		if streamType == "Dribble" then
			actualDiameter = 0.25
		elseif streamType == "Burst" then
			actualDiameter = 3
		elseif streamType == "Geyser" then
			actualDiameter = 8
		end
		local arcMult = 1
		if streamType == "Dribble" then
			arcMult = 0.4
		elseif streamType == "Burst" then
			arcMult = 1.5
		elseif streamType == "Geyser" then
			arcMult = 6
		end
		local horizDist = (Vector3.new(startPos.X, 0, startPos.Z) - Vector3.new(endPos.X, 0, endPos.Z)).Magnitude
		local arcHeight = math.clamp(horizDist * 1.5 * arcMult, 5, 120)
		local controlXZ = startPos:Lerp(endPos, 0.5)
		local controlPos = Vector3.new(controlXZ.X, math.max(startPos.Y, endPos.Y) + arcHeight, controlXZ.Z)
		local tubeName = "OilTube_" .. sig .. (oilTypeOverride and ("_" .. oilTypeOverride) or "")
		local existing = folder:FindFirstChild(tubeName)
		if existing and not existing:IsA("Folder") then
			existing:Destroy()
			existing = nil
		end
		local revealStartedAt = getTubeRevealStartedAt(info.tile.visualsStartedAt, now)
		local needsRebuild = true
		if existing and existing:IsA("Folder") then
			local endX = existing:GetAttribute("EndX")
			local endY = existing:GetAttribute("EndY")
			local endZ = existing:GetAttribute("EndZ")
			local storedReveal = existing:GetAttribute("RevealStartedAt")
			local storedDuration = existing:GetAttribute("RevealDuration")
			if typeof(endX) == "number" and typeof(endY) == "number" and typeof(endZ) == "number" and typeof(storedReveal) == "number" and typeof(storedDuration) == "number" then
				local storedEnd = Vector3.new(endX, endY, endZ)
				needsRebuild = (storedEnd - endPos).Magnitude > OIL_TUBE_ENDPOINT_EPSILON
					or math.abs((storedReveal :: number) - revealStartedAt) > 0.01
					or math.abs((storedDuration :: number) - OIL_TUBE_REVEAL_DURATION) > 0.01
			end
		end
		if not needsRebuild then
			return
		end
		if existing then
			existing:Destroy()
		end
		local tubeFolder = Instance.new("Folder")
		tubeFolder.Name = tubeName
		tubeFolder:SetAttribute("Rainbow", isRainbow)
		tubeFolder:SetAttribute("RevealStartedAt", revealStartedAt)
		tubeFolder:SetAttribute("RevealDuration", OIL_TUBE_REVEAL_DURATION)
		tubeFolder:SetAttribute("EndX", endPos.X)
		tubeFolder:SetAttribute("EndY", endPos.Y)
		tubeFolder:SetAttribute("EndZ", endPos.Z)
		tubeFolder.Parent = folder
		local segCount = 16
		local bezierPositions = {}
		for i = 0, segCount do
			local alpha = i / segCount
			local oneMinus = 1 - alpha
			bezierPositions[i] = oneMinus * oneMinus * startPos + 2 * oneMinus * alpha * controlPos + alpha * alpha * endPos
		end
		local revealProgress = math.clamp((now - revealStartedAt) / OIL_TUBE_REVEAL_DURATION, 0, 1)
		local prevRot = nil
		local prevTangent = nil
		for i = 0, segCount - 1 do
			local p0 = bezierPositions[i]
			local p1 = bezierPositions[i + 1]
			local midP = (p0 + p1) / 2
			local segLen = (p1 - p0).Magnitude
			if segLen < 0.05 then
				continue
			end
			local tangent = (p1 - p0).Unit
			local cf
			if not prevRot then
				cf = CFrame.lookAt(midP, p1) * CFrame.Angles(0, math.rad(90), 0)
				prevRot = cf - cf.Position
			else
				local dot = math.clamp(prevTangent:Dot(tangent), -1, 1)
				local angle = math.acos(dot)
				local axis = prevTangent:Cross(tangent)
				if angle > 0.0001 and axis.Magnitude > 0.0001 then
					prevRot = CFrame.fromAxisAngle(axis.Unit, angle) * prevRot
				end
				cf = CFrame.new(midP) * prevRot
			end
			prevTangent = tangent
			local seg = Instance.new("Part")
			seg.Name = "Seg_" .. i
			seg.Shape = Enum.PartType.Cylinder
			seg.Size = Vector3.new(segLen * 1.15, actualDiameter, actualDiameter)
			seg.Color = tubeColor
			seg.Material = Enum.Material.SmoothPlastic
			seg.Transparency = if revealProgress >= 1 or (i / segCount) <= revealProgress then OIL_TUBE_VISIBLE_TRANSPARENCY else 1
			seg.Anchored = true
			seg.CanCollide = false
			seg.CanQuery = false
			seg.CanTouch = false
			seg.CFrame = cf
			seg.Parent = tubeFolder
		end
	end

	for sig, info in pairs(wantedSprays) do
		eachTileVisualVariant(info, function(oilTypeOverride, offset, streamTypeOverride)
			syncSprayForTile(sig, info, oilTypeOverride, offset, streamTypeOverride)
		end)
	end
	for sig, info in pairs(wantedTubes) do
		eachTileVisualVariant(info, function(oilTypeOverride, offset, streamTypeOverride)
			syncTubeForTile(sig, info, oilTypeOverride, offset, streamTypeOverride)
		end)
	end
	for sig, info in pairs(wantedPuddles) do
		spawnPuddleForTile(sig, info)
	end

	for _, child in ipairs(folder:GetChildren()) do
		local sprayBase = child.Name:match("^Spray_(.+)")
		if sprayBase then
			if not wantedSprays[stripOilVisualSuffix(sprayBase)] then
				child:Destroy()
			end
			continue
		end
		local puddleBase = child.Name:match("^Puddle_(.+)")
		if puddleBase then
			if not wantedPuddles[stripOilVisualSuffix(puddleBase)] then
				child:Destroy()
			end
			continue
		end
		local tubeBase = child.Name:match("^OilTube_(.+)")
		if tubeBase then
			if not wantedTubes[stripOilVisualSuffix(tubeBase)] then
				child:Destroy()
			end
		end
	end
end

function OilVisualService:_syncDrills(_plot: Model, drillsFolder: Folder, drills, ownerUserId: number, snapshot: any?)
	local function getFlowRate(drill: any): number
		if drill.isCenterPump ~= true or typeof(snapshot) ~= "table" or typeof(snapshot.chunks) ~= "table" then
			return drill.flowBase or 0.2
		end
		local VeinCrateConfig = require(Shared:WaitForChild("Config"):WaitForChild("VeinCrateConfig"))
		local VeinConfig = require(Shared:WaitForChild("Config"):WaitForChild("VeinConfig"))
		local pumpDef = VeinConfig.PumpUpgrades[drill.tier] or VeinConfig.PumpUpgrades.T1
		local pumpMult = pumpDef and pumpDef.flowMult or 1
		local total = 0
		for _, chunk in ipairs(snapshot.chunks) do
			if chunk.chunkId == drill.chunkId and typeof(chunk.tiles) == "table" then
				for tileKey, tile in pairs(chunk.tiles) do
					if tileKey ~= "T33" and tile.drilled == true and tile.hasOil ~= false and typeof(tile.visualsStartedAt) == "number" and typeof(tile.veinTypeId) == "string" then
						local def = VeinCrateConfig.GetById(tile.veinTypeId)
						if def and not def.isUnlucky then
							total += (def.barrelsPerSecond or 0) * pumpMult
						end
					end
				end
			end
		end
		return total
	end
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

			-- Float-down animation for newly placed center pumps
			if justCreated and drill.isCenterPump then
				local startCf = CFrame.new(px, py + 60 + pivotToBottom + extraLift, pz)
			if model:IsA("Model") then
					model:PivotTo(startCf)
			elseif model:IsA("BasePart") then
					model.CFrame = startCf
			end
			anchorAllBaseParts(model)
				-- Sparkle particles during descent
				local emitter = Instance.new("ParticleEmitter")
				emitter.Name = "PumpDropFx"
				emitter.Rate = 40
				emitter.Lifetime = NumberRange.new(0.5, 1.2)
				emitter.Speed = NumberRange.new(2, 6)
				emitter.SpreadAngle = Vector2.new(30, 30)
				emitter.Color = ColorSequence.new(Color3.fromRGB(255, 230, 100))
				emitter.Size = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 0.8),
					NumberSequenceKeypoint.new(1, 0),
				})
				emitter.Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 0),
					NumberSequenceKeypoint.new(1, 1),
				})
				emitter.LightEmission = 1
				local emitterPart = model:FindFirstChildWhichIsA("BasePart")
				if emitterPart then emitter.Parent = emitterPart end
				-- Tween down over 1.5 seconds
				task.spawn(function()
					local FLOAT_TIME = 1.5
					local t0 = os.clock()
					while os.clock() - t0 < FLOAT_TIME do
						local alpha = math.min(1, (os.clock() - t0) / FLOAT_TIME)
						local eased = 1 - (1 - alpha) ^ 2
						local currentCf = startCf:Lerp(targetCf, eased)
						if model:IsA("Model") then
							model:PivotTo(currentCf)
						elseif model:IsA("BasePart") then
							model.CFrame = currentCf
						end
						task.wait()
					end
					if model:IsA("Model") then
						model:PivotTo(targetCf)
					elseif model:IsA("BasePart") then
						model.CFrame = targetCf
					end
					-- Clean up particles after landing
					task.wait(1.5)
					if emitter and emitter.Parent then
						emitter.Enabled = false
						task.wait(1.5)
						emitter:Destroy()
					end
				end)
			else
				if model:IsA("Model") then
					model:PivotTo(targetCf)
				elseif model:IsA("BasePart") then
					model.CFrame = targetCf
			end
			end
			anchorAllBaseParts(model)
			-- Write Connected attribute so the OilBurstSpawner script can pause emission
			model:SetAttribute("Connected", drill.connected == true)
			-- Glass fill: when connected, slowly fill with oil; when not connected, empty glass.
			-- Tag fill parts on first encounter so we can find them again after transparency changes.
			local isConnected = drill.connected == true
			local oilType = drill.tileOilType or "Crude"
			if justCreated or isConnected then
				print("[PumpFill] drillId=" .. tostring(drill.drillId) .. " tileOilType=" .. tostring(drill.tileOilType) .. " resolved=" .. oilType .. " connected=" .. tostring(isConnected))
			end
			local fillColor
			if oilType == "Refined" then
				fillColor = Color3.fromRGB(240, 200, 70)
			elseif oilType == "Premium" then
				fillColor = Color3.fromRGB(180, 80, 255)
			else
				fillColor = Color3.fromRGB(30, 30, 30)
			end
			for _, part in ipairs(model:GetDescendants()) do
				if part:IsA("BasePart") and part.Material == Enum.Material.Glass then
					local isFill = part:GetAttribute("IsPumpFill") == true
					if not isFill and part.Transparency < 0.1 and part.Color.R < 0.3 and part.Color.G < 0.3 and part.Color.B < 0.3 then
						part:SetAttribute("IsPumpFill", true)
						isFill = true
					end
					if isFill then
						part.Color = fillColor
						local targetTrans = isConnected and 0 or 1
						local wasConnected = model:GetAttribute("WasConnected")
						if wasConnected ~= isConnected then
							-- Animate fill/drain over 1.5 seconds
							TweenService:Create(part, TweenInfo.new(1.5, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), {
								Transparency = targetTrans,
							}):Play()
						elseif part.Transparency ~= targetTrans then
							part.Transparency = targetTrans
						end
					end
				end
			end
			model:SetAttribute("WasConnected", isConnected)
			-- Hologram text above pump: oil type + output rate
			local holoName = "PumpHologram"
			local holoPart = model:FindFirstChild(holoName)
			if not holoPart then
				local topPos = getHighestBasePartTopPosition(model)
				local topY = topPos and topPos.Y or model:GetPivot().Position.Y
				holoPart = Instance.new("Part")
				holoPart.Name = holoName
				holoPart.Size = Vector3.new(1, 1, 1)
				holoPart.Transparency = 1
				holoPart.Anchored = true
				holoPart.CanCollide = false
				holoPart.CanQuery = false
				holoPart.CanTouch = false
				holoPart:SetAttribute(IGNORE_FOR_VISUAL_BOUNDS_ATTR, true)
				holoPart.Position = Vector3.new(model:GetPivot().Position.X, topY + 3.6, model:GetPivot().Position.Z)
				holoPart.Parent = model
				local billboard = Instance.new("BillboardGui")
				billboard.Name = "HoloGui"
				billboard.Size = UDim2.fromOffset(220, 56)
				billboard.StudsOffsetWorldSpace = Vector3.new(0, 0.2, 0)
				billboard.AlwaysOnTop = true
				billboard.LightInfluence = 0
				billboard.MaxDistance = 180
				billboard.Parent = holoPart
				local backdrop = Instance.new("Frame")
				backdrop.Name = "Backdrop"
				backdrop.AnchorPoint = Vector2.new(0.5, 0.5)
				backdrop.Position = UDim2.fromScale(0.5, 0.5)
				backdrop.Size = UDim2.fromScale(1, 1)
				backdrop.BackgroundColor3 = Color3.fromRGB(8, 18, 28)
				backdrop.BackgroundTransparency = 0.28
				backdrop.BorderSizePixel = 0
				backdrop.Parent = billboard
				local backdropCorner = Instance.new("UICorner")
				backdropCorner.CornerRadius = UDim.new(0, 10)
				backdropCorner.Parent = backdrop
				local label = Instance.new("TextLabel")
				label.Name = "Info"
				label.Size = UDim2.fromScale(1, 1)
				label.BackgroundTransparency = 1
				label.Font = Enum.Font.LuckiestGuy
				-- TextScaled (no UIPadding, no UITextSizeConstraint) so the
				-- label fills the full 220x56 box. The BillboardGui is
				-- distance-scaled by the engine, so this gives the same
				-- on-screen proportion across phone / desktop / console.
				-- Fixed `TextSize` was readable at one resolution but left
				-- mobile players with relatively tiny text — do not re-add it.
				label.TextScaled = true
				label.TextWrapped = false
				label.TextTruncate = Enum.TextTruncate.None
				label.TextTransparency = 0.05
				label.TextStrokeTransparency = 0
				label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
				label.ZIndex = 2
				label.Parent = billboard
			end
			-- Update hologram text + reposition
			local holoGui = holoPart:FindFirstChild("HoloGui")
			local infoLabel = holoGui and holoGui:FindFirstChild("Info", true)
			if infoLabel then
				local topPos = getHighestBasePartTopPosition(model)
				local topY2 = topPos and topPos.Y or model:GetPivot().Position.Y
				holoPart.Position = Vector3.new(model:GetPivot().Position.X, topY2 + 3.6, model:GetPivot().Position.Z)

				-- Strip stale font-shrink artifacts on labels created by an
				-- earlier code path (UIPadding on the parent + a low-cap
				-- UITextSizeConstraint) so existing live drills get the
				-- distance-scaling TextScaled treatment without needing a
				-- server restart.
				local backdrop = infoLabel.Parent
				if backdrop and backdrop:IsA("GuiObject") then
					local stalePad = backdrop:FindFirstChildOfClass("UIPadding")
					if stalePad then stalePad:Destroy() end
				end
				local staleConstraint = infoLabel:FindFirstChildOfClass("UITextSizeConstraint")
				if staleConstraint then staleConstraint:Destroy() end
				if infoLabel:IsA("TextLabel") and not infoLabel.TextScaled then
					infoLabel.TextScaled = true
				end

				local flowRate = getFlowRate(drill)
				infoLabel.Text = string.format("%.2f bbl/sec", flowRate)
				-- Color by production threshold
				if flowRate >= 2 then
					-- Excellent: rainbow cycle handled client-side, use gold as static fallback
					infoLabel.TextColor3 = Color3.fromRGB(255, 170, 60)
				elseif flowRate >= 1 then
					-- Good: green
					infoLabel.TextColor3 = Color3.fromRGB(80, 220, 80)
				elseif flowRate >= 0.5 then
					-- OK: yellow
					infoLabel.TextColor3 = Color3.fromRGB(240, 200, 70)
				else
					-- Low: white
					infoLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
				end
			end
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
			ensureSellBackPromptOnHost(self, model, {
				ownerUserId = ownerUserId,
				hammerKind = "pump",
				drillId = drillId,
				noSellback = drill.ftueFreeNoSellback == true,
			})
			-- Center pump upgrade prompt
			if drill.isCenterPump then
				local VeinConfigVis = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("VeinConfig"))
				local gt2 = "Bronze"
				local stateForUpg = self._oilStateService and self._oilStateService:GetState(ownerUserId)
				if stateForUpg and stateForUpg.chunksById then
					local chunk2 = stateForUpg.chunksById[drill.chunkId]
					if chunk2 then gt2 = chunk2.groundType or chunk2.biome or "Bronze" end
				end
				local nextTier, cost = VeinConfigVis.GetUpgradeCost(drill.tier, gt2)
				local existingUpg = model:FindFirstChild("UpgradePrompt")
				if nextTier and cost then
					if not existingUpg then
						local upgPrompt = Instance.new("ProximityPrompt")
						upgPrompt.Name = "UpgradePrompt"
						upgPrompt.ActionText = string.format("Upgrade to %s ($%d)", nextTier, cost)
						upgPrompt.ObjectText = "Center Pump"
						upgPrompt.KeyboardKeyCode = Enum.KeyCode.E
						upgPrompt.MaxActivationDistance = 10
						upgPrompt.RequiresLineOfSight = false
						upgPrompt.HoldDuration = 0.5
						local root = model:FindFirstChildWhichIsA("BasePart")
						if root then upgPrompt.Parent = root end
						local chunkIdForUpg = drill.chunkId
						upgPrompt.Triggered:Connect(function(trigPlayer)
							local ok, code, msg = self._oilStateService:TryUpgradeCenterPump(trigPlayer.UserId, chunkIdForUpg)
							local resultEv = game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Remotes"):FindFirstChild("OilActionResult")
							if resultEv then
								resultEv:FireClient(trigPlayer, { action = "UpgradePump", ok = ok, code = code, message = msg })
							end
						end)
					else
						-- Update text in case tier changed
						existingUpg.ActionText = string.format("Upgrade to %s ($%d)", nextTier, cost)
					end
				elseif existingUpg then
					-- Max tier, remove prompt
					existingUpg:Destroy()
				end
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
	local BELT_Y_OFFSET = Vector3.new(0, 0.45, 0)
	local startPos = convStart.Position + BELT_Y_OFFSET
	local cornerPos = (convCorner and convCorner.Position or convStart.Position) + BELT_Y_OFFSET
	local endPos = convEnd.Position + BELT_Y_OFFSET
	-- Compute segment lengths for proportional tween timing
	local seg1Len = (cornerPos - startPos).Magnitude
	local seg2Len = (endPos - cornerPos).Magnitude
	local totalLen = math.max(seg1Len + seg2Len, 1)
	local beltSpeed = totalLen / math.max(0.1, tweenSeconds)
	local now = workspace:GetServerTimeNow()
	local nextEjectAt = tonumber(barrelsFolder:GetAttribute("NextEjectAt")) or 0
	local bootstrapped = barrelsFolder:GetAttribute("VisualStateBootstrapped") == true

	-- Freshly recreated plot visuals should reconcile to the current stored oil state,
	-- not replay every historical barrel through the conveyor as if it was newly produced.
	-- We only animate deltas that happen after this initial snapshot has been established.
	if not bootstrapped then
		for _, child in ipairs(barrelsFolder:GetChildren()) do
			child:Destroy()
		end
		barrelsFolder:SetAttribute("NextEjectAt", now)
		for _, tier in ipairs(TIER_ORDER) do
			local oil = oilByTier[tier] or 0
			local currentBarrels = math.max(0, math.floor(oil / perBarrel))
			barrelsFolder:SetAttribute("PendingEject_" .. tier, 0)
			barrelsFolder:SetAttribute("ScheduledBarrels_" .. tier, currentBarrels)
			barrelsFolder:SetAttribute(
				"BarrelRevision_" .. tier,
				math.max(1, math.floor(tonumber(barrelsFolder:GetAttribute("BarrelRevision_" .. tier)) or 0) + 1)
			)
		end
		barrelsFolder:SetAttribute("VisualStateBootstrapped", true)
		nextEjectAt = now
		bootstrapped = true
	end
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
		local currentBarrels = math.max(0, math.floor(oil / perBarrel))
		local pendingAttr = "PendingEject_" .. tier
		local scheduledAttr = "ScheduledBarrels_" .. tier
		local revisionAttr = "BarrelRevision_" .. tier
		local pendingCount = math.max(0, math.floor(tonumber(barrelsFolder:GetAttribute(pendingAttr)) or 0))
		local scheduledCount = math.max(0, math.floor(tonumber(barrelsFolder:GetAttribute(scheduledAttr)) or 0))
		local revision = math.max(0, math.floor(tonumber(barrelsFolder:GetAttribute(revisionAttr)) or 0))
		local delta = currentBarrels - scheduledCount
		if delta > 0 then
			local remainingToRepresent = delta
			local multiplier = if delta > maxPerTier then math.ceil(delta / maxPerTier) else 1
			local spawnCount = math.ceil(delta / multiplier)
			barrelsFolder:SetAttribute(scheduledAttr, currentBarrels)
			for _ = 1, spawnCount do
				local representedUnits = math.min(multiplier, remainingToRepresent)
				remainingToRepresent -= representedUnits
				local previewBarrel = self:_createBarrelForTier(tier, tierTemplates[tier])
				local queueSpacing = math.max(4, getInstanceFootprint(previewBarrel) + 0.75)
				previewBarrel:Destroy()
				local ejectInterval = math.max(BARREL_CONVEYOR_MIN_EJECT_INTERVAL, queueSpacing / math.max(beltSpeed, 0.1))
				local scheduledEjectAt = math.max(now, nextEjectAt)
				local capturedRevision = revision
				nextEjectAt = scheduledEjectAt + ejectInterval
				pendingCount += 1
				barrelsFolder:SetAttribute(pendingAttr, pendingCount)

				task.delay(math.max(0, scheduledEjectAt - now), function()
					if not barrelsFolder.Parent then
						return
					end
					local liveRevision = math.max(0, math.floor(tonumber(barrelsFolder:GetAttribute(revisionAttr)) or 0))
					if liveRevision ~= capturedRevision then
						local latestPending = math.max(0, math.floor(tonumber(barrelsFolder:GetAttribute(pendingAttr)) or 0))
						barrelsFolder:SetAttribute(pendingAttr, math.max(0, latestPending - 1))
						return
					end
					local latestPending = math.max(0, math.floor(tonumber(barrelsFolder:GetAttribute(pendingAttr)) or 0))
					barrelsFolder:SetAttribute(pendingAttr, math.max(0, latestPending - 1))

				local barrel = self:_createBarrelForTier(tier, tierTemplates[tier])
				barrel:SetAttribute("Tier", tier)
				barrel:SetAttribute("OnConveyor", true)
					barrel:SetAttribute("RepresentedUnits", representedUnits)
				barrel.Parent = barrelsFolder
					ensureBarrelMultiplierGui(barrel, representedUnits)
					local barrelBottomOffset = getInstanceBottomOffset(barrel)
				local function moveBarrel(pos)
						local cf = CFrame.new(pos.X, pos.Y + barrelBottomOffset, pos.Z)
					if barrel:IsA("Model") then
						barrel:PivotTo(cf)
					elseif barrel:IsA("BasePart") then
						barrel.CFrame = cf
					end
				end
				moveBarrel(startPos)
				anchorAllBaseParts(barrel)

				task.spawn(function()
						local distance = 0
						while distance < totalLen and barrel.Parent do
						local dt = task.wait()
							distance += beltSpeed * dt
							moveBarrel(conveyorPathPosition(startPos, cornerPos, endPos, seg1Len, seg2Len, distance))
						end
						if not barrel.Parent then
							return
						end
					barrel:SetAttribute("OnConveyor", false)
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
				end)
			end
			barrelsFolder:SetAttribute("NextEjectAt", nextEjectAt)
		elseif delta < 0 then
			revision += 1
			barrelsFolder:SetAttribute(revisionAttr, revision)
			barrelsFolder:SetAttribute(scheduledAttr, currentBarrels)
			if pendingCount > 0 then
				barrelsFolder:SetAttribute(pendingAttr, 0)
				pendingCount = 0
			end
				for _, child in ipairs(barrelsFolder:GetChildren()) do
				if child:GetAttribute("Tier") == tier then
						child:Destroy()
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
		Crude = Color3.fromRGB(30, 25, 20),
		Refined = Color3.fromRGB(220, 180, 60),
		Premium = Color3.fromRGB(200, 200, 210),
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
		-- Hologram: barrel count above each tank
			local shellTopY = bottomY + targetShellY
			local holoName = "TankHolo_" .. oilType
			local holoPart = tube:FindFirstChild(holoName)
			if not holoPart then
				holoPart = Instance.new("Part")
				holoPart.Name = holoName
				holoPart.Size = Vector3.new(0.5, 0.5, 0.5)
				holoPart.Transparency = 1
				holoPart.Anchored = true
				holoPart.CanCollide = false
				holoPart.CanQuery = false
				holoPart.CanTouch = false
				holoPart:SetAttribute(IGNORE_FOR_VISUAL_BOUNDS_ATTR, true)
				holoPart.Position = Vector3.new(union.Position.X, shellTopY + 4, union.Position.Z)
				holoPart.Parent = tube

				local bb = Instance.new("BillboardGui")
				bb.Name = "HoloGui"
				bb.Size = UDim2.fromOffset(200, 60)
				bb.AlwaysOnTop = false
				bb.LightInfluence = 0
				bb.Parent = holoPart

				local lbl = Instance.new("TextLabel")
				lbl.Name = "Info"
				lbl.Size = UDim2.fromScale(1, 1)
				lbl.BackgroundTransparency = 1
				lbl.Font = Enum.Font.LuckiestGuy
				lbl.TextSize = 28
				lbl.TextStrokeTransparency = 0
				lbl.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
				lbl.Parent = bb
			end

			local holoGui = holoPart:FindFirstChild("HoloGui")
			local infoLabel = holoGui and holoGui:FindFirstChild("Info")
			if infoLabel then
				local currentAmt = math.floor(amount)
				local maxAmt = math.floor(capacity)
				if currentAmt >= maxAmt and maxAmt > 0 then
					infoLabel.Text = "FULL!\nUpgrade"
					infoLabel.TextColor3 = Color3.fromRGB(255, 80, 80)
					infoLabel.TextSize = 32
				else
					infoLabel.Text = string.format("%d / %d", currentAmt, maxAmt)
					infoLabel.TextColor3 = col or Color3.fromRGB(200, 200, 200)
					infoLabel.TextSize = 28
				end
				-- Reposition above tank top (scales with tier upgrade height)
				holoPart.Position = Vector3.new(union.Position.X, shellTopY + 4, union.Position.Z)
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
				surfaceGui.Enabled = true
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
