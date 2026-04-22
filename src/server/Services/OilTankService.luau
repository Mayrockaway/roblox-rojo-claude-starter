--!strict
-- OilTankService: upgrade interactions for plot OilTanks.
-- Runtime source of truth is the authored wood sign part:
--   <plot>.OilTanks."Minecraft Wood Sign".Sign
-- Sign clicks/taps upgrade the mapped oil tank.
-- Legacy ProximityPrompt / union click paths are disabled.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))

local OilTankService = {}

local function debugLog(msg: string)
	if RunService:IsStudio() then
		print("[OilTankService] " .. msg)
	end
end

local function findOilTypeOnAncestors(instance: Instance?): string?
	local cur = instance
	while cur do
		local t = cur:GetAttribute("OilType")
		if typeof(t) == "string" and t ~= "" then
			return t
		end
		cur = cur.Parent
	end
	return nil
end

local function plotOwnerOf(instance: Instance): number?
	local cur: Instance? = instance
	while cur do
		if cur:IsA("Model") and cur.Name:match("^Plot_") then
			local owner = cur:GetAttribute("OwnerUserId")
			if typeof(owner) == "number" then return owner end
			return nil
		end
		cur = cur.Parent
	end
	return nil
end

local function isWoodSignPart(part: BasePart): boolean
	if part.Name ~= "Sign" then
		return false
	end
	local mdl = part.Parent
	if not (mdl and mdl:IsA("Model") and mdl.Name == "Minecraft Wood Sign") then
		return false
	end
	return true
end

-- The warehouse upgrade sign reuses the same `Minecraft Wood Sign` template
-- (and the same `TankUpgradeSignClick` ClickDetector name) as the refinery
-- tank upgrade signs. Without this guard, OilTankService also hooks the
-- warehouse sign, picks the geometrically nearest tank via
-- `resolveOilTypeForWoodSign`, and fires "Premium tank upgraded" alongside
-- WarehouseService's correct "Upgraded to tier N." — so the player sees the
-- wrong status line. WarehouseService parents its sign under
-- `WarehouseWoodSignRig` and stamps `WarehouseOwnerUserId` on it, so check
-- both (the attribute may not be stamped yet if OilTankService scans first
-- on plot spawn).
local function isWarehouseSignPart(signPart: BasePart): boolean
	if signPart:GetAttribute("WarehouseOwnerUserId") ~= nil then
		return true
	end
	local p: Instance? = signPart.Parent
	while p do
		if p.Name == "WarehouseWoodSignRig" then
			return true
		end
		p = p.Parent
	end
	return false
end

local function resolveOilTypeForWoodSign(signPart: BasePart): string?
	local direct = findOilTypeOnAncestors(signPart)
	if direct then
		return direct
	end
	local cur: Instance? = signPart
	local tanksModel: Model? = nil
	while cur do
		if cur:IsA("Model") and cur.Name == "OilTanks" then
			tanksModel = cur
			break
		end
		cur = cur.Parent
	end
	if not tanksModel then
		return nil
	end
	local bestOilType: string? = nil
	local bestDist = math.huge
	for _, child in ipairs(tanksModel:GetChildren()) do
		if child:IsA("Model") and child.Name ~= "Minecraft Wood Sign" then
			local oilType = child:GetAttribute("OilType")
			if typeof(oilType) == "string" and oilType ~= "" then
				local testTube = child:FindFirstChild("test tube")
				local union = testTube and testTube:FindFirstChild("Union")
				if union and union:IsA("BasePart") then
					local d = (union.Position - signPart.Position).Magnitude
					if d < bestDist then
						bestDist = d
						bestOilType = oilType
					end
				end
			end
		end
	end
	return bestOilType
end

local function oilTypeFromPayload(payload: any): string?
	if typeof(payload) ~= "table" then
		return nil
	end
	local source = payload.source
	if typeof(source) == "Instance" and source:IsA("Instance") and source:IsDescendantOf(workspace) then
		local t = findOilTypeOnAncestors(source)
		if t then
			return t
		end
	end
	local raw = payload.oilType
	if typeof(raw) == "string" and raw ~= "" then
		return raw
	end
	return nil
end

local function ownerFromPayload(payload: any): number?
	if typeof(payload) ~= "table" then
		return nil
	end
	local source = payload.source
	if typeof(source) == "Instance" and source:IsA("Instance") and source:IsDescendantOf(workspace) then
		return plotOwnerOf(source)
	end
	return nil
end

function OilTankService:Init(remoteService, oilStateService)
	self._remoteService = remoteService
	self._oilStateService = oilStateService
	self._connections = {}
	self._hookedSignParts = {}
	self._hookedClickDetectors = {}
end

function OilTankService:_upgrade(player: Player, oilType: string)
	local ok, code, message, data = self._oilStateService:TryUpgradeTank(player.UserId, oilType)
	self._remoteService:GetEvent(RemoteNames.OilActionResult):FireClient(player, {
		action = "UpgradeOilTank",
		ok = ok,
		code = code,
		message = message,
		data = data,
	})
end

function OilTankService:_hookSignPart(signPart: BasePart)
	if self._hookedSignParts[signPart] then
		return
	end
	if isWarehouseSignPart(signPart) then
		return
	end
	self._hookedSignParts[signPart] = true

	-- Ensure this part remains mouse-targetable for ClickDetector and hover affordance.
	signPart.CanQuery = true
	signPart.CanTouch = false
	signPart.CanCollide = false
	signPart.Anchored = true

	-- Defensive: the authored template historically shipped with
	-- `Sign.SurfaceGui.Active = true`, which causes the GUI face to soak
	-- pointer events so the ClickDetector underneath never fires. The
	-- template is now corrected, but we also flip it here at hook-time so
	-- a fresh-claimed plot is clickable the moment its sign is parented
	-- (instead of waiting for the next OilVisualService snapshot tick to
	-- reach that plot — that wait was the "works for me, not for friend"
	-- failure mode where the owner had stored oil and got a sync but the
	-- friend's empty plot did not).
	local signModel = signPart.Parent
	if signModel and signModel:IsA("Model") then
		for _, d in ipairs(signModel:GetDescendants()) do
			if d:IsA("SurfaceGui") then
				d.Active = false
				for _, gui in ipairs(d:GetDescendants()) do
					if gui:IsA("GuiObject") then
						gui.Active = false
					end
				end
			end
		end
	end

	local click = signPart:FindFirstChild("TankUpgradeSignClick")
	if click and not click:IsA("ClickDetector") then
		click:Destroy()
		click = nil
	end
	if not click then
		local cd = Instance.new("ClickDetector")
		cd.Name = "TankUpgradeSignClick"
		-- 28 (was 22): friend reports of unreliable taps were partly the
		-- SurfaceGui-soaks-input bug above and partly being just past the
		-- old 22-stud reach on mobile / wider FOV. 28 stays well inside
		-- "right next to the refinery" without making clicks land from
		-- across the plot.
		cd.MaxActivationDistance = 28
		cd.CursorIcon = "rbxasset://textures/Cursors/KeyboardMouse/PointingHandCursor.png"
		cd.Parent = signPart
		click = cd
	end
	if click and click:IsA("ClickDetector") then
		click.CursorIcon = "rbxasset://textures/Cursors/KeyboardMouse/PointingHandCursor.png"
		click.MaxActivationDistance = math.max(28, click.MaxActivationDistance)
	end
	if click and click:IsA("ClickDetector") and not self._hookedClickDetectors[click] then
		self._hookedClickDetectors[click] = true
		table.insert(self._connections, click.MouseClick:Connect(function(player)
			if isWarehouseSignPart(signPart) then
				return
			end
			local oilType = resolveOilTypeForWoodSign(signPart)
			if not oilType then
				debugLog(string.format("click ignored: no oil type for %s", signPart:GetFullName()))
				return
			end
			local ownerUserId = plotOwnerOf(signPart)
			debugLog(string.format(
				"click user=%d oilType=%s owner=%s part=%s",
				player.UserId,
				tostring(oilType),
				tostring(ownerUserId),
				signPart:GetFullName()
			))
			if ownerUserId and ownerUserId ~= player.UserId then
				self._remoteService:GetEvent(RemoteNames.OilActionResult):FireClient(player, {
					action = "UpgradeOilTank",
					ok = false,
					code = "NOT_OWNER",
					message = "This is not your plot.",
				})
				return
			end
			self:_upgrade(player, oilType)
		end))
	end
end

function OilTankService:_hookPrompt(prompt: ProximityPrompt)
	-- Prompt path removed; keep disabled so no hold-E UI appears.
	prompt.Enabled = false
end

function OilTankService:Start()
	local upgradeEvent = self._remoteService:GetEvent(RemoteNames.RequestUpgradeOilTank)
	table.insert(self._connections, upgradeEvent.OnServerEvent:Connect(function(player, payload)
		local ownerUserId = ownerFromPayload(payload)
		if ownerUserId and ownerUserId ~= player.UserId then
			self._remoteService:GetEvent(RemoteNames.OilActionResult):FireClient(player, {
				action = "UpgradeOilTank",
				ok = false,
				code = "NOT_OWNER",
				message = "This is not your plot.",
			})
			return
		end
		local oilType = oilTypeFromPayload(payload)
		if not oilType then return end
		self:_upgrade(player, oilType)
	end))

	-- Hook all existing TankUpgradePrompts + any added later (plot clones, re-spawns).
	local function scan(root: Instance)
		for _, d in ipairs(root:GetDescendants()) do
			if d:IsA("BasePart") and isWoodSignPart(d) then
				self:_hookSignPart(d)
			elseif d:IsA("ProximityPrompt") and d.Name == "TankUpgradePrompt" then
				self:_hookPrompt(d)
			end 
		end
	end
	scan(workspace)
	table.insert(self._connections, workspace.DescendantAdded:Connect(function(d)
		if d:IsA("BasePart") and isWoodSignPart(d) then
			self:_hookSignPart(d)
		elseif d:IsA("ProximityPrompt") and d.Name == "TankUpgradePrompt" then
			self:_hookPrompt(d)
		end
	end))
end

function OilTankService:Stop()
	for _, c in ipairs(self._connections) do c:Disconnect() end
	self._connections = {}
	self._hookedSignParts = {}
	self._hookedClickDetectors = {}
end

return OilTankService
