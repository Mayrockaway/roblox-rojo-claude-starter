--!strict
--[[
	DrillAnimationClient — extracted from init.client.luau

	Handles per-frame drill spin+sink animation, drill timer
	billboard updates, and SUPER TILE rainbow pulse.

	Usage:
		local DrillAnimationClient = require(resolveClientModule(script, "DrillAnimationClient"))
		DrillAnimationClient.start()
		-- then each frame: DrillAnimationClient.tick()
]]

local M = {}

-- ===================== caches =====================
-- Cache each active drill model's initial pivot + initial height so we can apply sink offsets
local activeDrillBasePivots: { [Instance]: CFrame } = {}
local activeDrillHeights: { [Instance]: number } = {}

-- PERF: per-frame lookups used to call workspace:GetDescendants() (14k-instance walk).
-- Cached sets, maintained via DescendantAdded/Removing — O(1) instead of O(workspace).
local _activeDrillsFolders: { [Folder]: true } = {}
local _superTileSet: { [BasePart]: true } = {}

-- ===================== internal helpers =====================

local function animateActiveDrill(model: Instance)
	if not model:IsA("Model") and not model:IsA("BasePart") then return end
	local startTime = tonumber(model:GetAttribute("StartTime"))
	local endTime = tonumber(model:GetAttribute("EndTime"))
	if not startTime or not endTime or endTime <= startTime then return end

	local basePivot = activeDrillBasePivots[model]
	if not basePivot then
		basePivot = model:IsA("Model") and model:GetPivot() or (model :: BasePart).CFrame
		activeDrillBasePivots[model] = basePivot

		local bbSizeY = 1
		if model:IsA("Model") then
			local _, bbSize = model:GetBoundingBox()
			bbSizeY = math.max(1, bbSize.Y)
		else
			bbSizeY = math.max(1, (model :: BasePart).Size.Y)
		end
		activeDrillHeights[model] = bbSizeY
	end

	local duration = endTime - startTime
	local alpha = math.clamp((workspace:GetServerTimeNow() - startTime) / duration, 0, 1)
	local templateName = model:GetAttribute("Template") or ""

	if templateName == "Drill_T6" then
		-- T6 FIST DRILL: pound animation — jump up then slam down, repeat
		local heightY = activeDrillHeights[model] or 5
		local sinkDepth = heightY * alpha * alpha
		local elapsed = workspace:GetServerTimeNow() - startTime
		local poundCycle = 1.2 -- seconds per pound
		local cycleAlpha = (elapsed % poundCycle) / poundCycle

		-- Rise phase (0-0.4): fist lifts up
		-- Slam phase (0.4-0.55): fist slams down fast
		-- Hold phase (0.55-1.0): fist stays at ground level
		local poundHeight
		if cycleAlpha < 0.4 then
			-- Rising: ease out
			local riseAlpha = cycleAlpha / 0.4
			poundHeight = riseAlpha * riseAlpha * 8
		elseif cycleAlpha < 0.55 then
			-- Slamming down: fast ease in
			local slamAlpha = (cycleAlpha - 0.4) / 0.15
			poundHeight = 8 * (1 - slamAlpha * slamAlpha)
		else
			-- Hold at ground
			poundHeight = 0
		end

		-- Dust burst at slam moment (cycleAlpha ~0.55)
		if cycleAlpha >= 0.53 and cycleAlpha < 0.58 then
			-- Check if we already emitted dust this cycle
			local lastDust = model:GetAttribute("_lastDustCycle")
			local currentCycle = math.floor(elapsed / poundCycle)
			if lastDust ~= currentCycle then
				model:SetAttribute("_lastDustCycle", currentCycle)
				-- Spawn dust puff
				local dustPart = model:FindFirstChildWhichIsA("BasePart")
				if dustPart then
					local emitter = Instance.new("ParticleEmitter")
					emitter.Rate = 0
					emitter.Speed = NumberRange.new(8, 15)
					emitter.SpreadAngle = Vector2.new(80, 80)
					emitter.Lifetime = NumberRange.new(0.4, 0.8)
					emitter.Color = ColorSequence.new(Color3.fromRGB(180, 160, 130))
					emitter.Size = NumberSequence.new({
						NumberSequenceKeypoint.new(0, 1.5),
						NumberSequenceKeypoint.new(1, 4),
					})
					emitter.Transparency = NumberSequence.new({
						NumberSequenceKeypoint.new(0, 0.3),
						NumberSequenceKeypoint.new(1, 1),
					})
					emitter.Parent = dustPart
					emitter:Emit(12)
					task.delay(1, function()
						if emitter.Parent then emitter:Destroy() end
					end)
				end
			end
		end

		local offset = CFrame.new(0, -sinkDepth + poundHeight, 0)
		local target = basePivot * offset
		if model:IsA("Model") then
			model:PivotTo(target)
		else
			(model :: BasePart).CFrame = target
		end
	else
		-- T1-T5: normal spin + sink animation
		local BASE_RAD = 3
		local PEAK_RAD = 40
		local spinAngle = duration * (BASE_RAD * alpha + PEAK_RAD * alpha * alpha * alpha / 3)

		local heightY = activeDrillHeights[model] or 5
		local sinkDepth = heightY * alpha * alpha

		local offset = CFrame.new(0, -sinkDepth, 0) * CFrame.Angles(0, spinAngle, 0)
		local target = basePivot * offset
		if model:IsA("Model") then
			model:PivotTo(target)
		else
			(model :: BasePart).CFrame = target
		end
	end
end

local function forEachActiveDrill(fn: (Instance) -> ())
	for folder in pairs(_activeDrillsFolders) do
		if folder.Parent then
			for _, m in ipairs(folder:GetChildren()) do
				if m.Name:match("^ActiveDrill_") then
					fn(m)
				end
			end
		end
	end
end

-- Update the text on every drill's static timer billboard.
-- Also scales the BillboardGui based on camera distance so it behaves like a
-- fixed-size world object instead of a constant screen-pixel overlay.
local TIMER_BASE_W = 180
local TIMER_BASE_H = 70
local TIMER_REF_DIST = 25 -- studs at which the billboard renders at full base size
local TIMER_MIN_SCALE = 0.25
local TIMER_MAX_SCALE = 1.0

local function updateDrillTimers()
	local now = workspace:GetServerTimeNow()
	local cam = workspace.CurrentCamera
	local camPos = cam and cam.CFrame.Position or Vector3.zero
	for folder in pairs(_activeDrillsFolders) do
		if folder.Parent then
			for _, anchor in ipairs(folder:GetChildren()) do
				if anchor.Name:match("^DrillTimer_") and anchor:IsA("BasePart") then
					local bb = anchor:FindFirstChild("TimerGui")
					local lbl = bb and bb:FindFirstChild("TimerLabel")
					if lbl and lbl:IsA("TextLabel") then
						local startT = tonumber(anchor:GetAttribute("StartTime")) or 0
						local endT = tonumber(anchor:GetAttribute("EndTime")) or 0
						local depthMeters = tonumber(anchor:GetAttribute("DepthMeters")) or 0
						local mps = tonumber(anchor:GetAttribute("MetersPerSecond")) or 1
						local elapsed = math.max(0, now - startT)
						local remaining = math.max(0, endT - now)
						local remainSecs = math.ceil(remaining)
						local timeStr = string.format("%ds", remainSecs)
						if depthMeters > 0 then
							local currentDepth = math.min(depthMeters, math.floor(elapsed * mps))
							lbl.Text = string.format("%dm / %dm\n%s", currentDepth, depthMeters, timeStr)
						else
							lbl.Text = timeStr
						end
					end
					-- Scale billboard to simulate world-space sizing.
					if bb and bb:IsA("BillboardGui") then
						local dist = (camPos - anchor.Position).Magnitude
						local scale = math.clamp(TIMER_REF_DIST / math.max(dist, 1), TIMER_MIN_SCALE, TIMER_MAX_SCALE)
						bb.Size = UDim2.new(0, math.round(TIMER_BASE_W * scale), 0, math.round(TIMER_BASE_H * scale))
					end
				end
			end
		end
	end
end

-- ===================== public API =====================

--- Wire up DescendantAdded/Removing listeners on workspace to maintain
--- the cached folder/super-tile sets. Call once at startup.
function M.start()
	local function consider(d: Instance)
		if d:IsA("Folder") then
			if d.Name == "ActiveDrills" then _activeDrillsFolders[d] = true end
		elseif d:IsA("BasePart") and d:GetAttribute("TileName") == "SUPER TILE" then
			_superTileSet[d] = true
		end
	end
	for _, d in ipairs(workspace:GetDescendants()) do consider(d) end
	workspace.DescendantAdded:Connect(consider)
	workspace.DescendantRemoving:Connect(function(d)
		_activeDrillsFolders[d] = nil
		_superTileSet[d] = nil
	end)

	-- Clean up pivot cache when models are destroyed (otherwise leaked references)
	workspace.DescendantRemoving:Connect(function(inst)
		if activeDrillBasePivots[inst] then
			activeDrillBasePivots[inst] = nil
		end
	end)
end

--- Per-frame tick: animate drills, update timers, pulse super tiles.
--- Call from the host's RenderStepped handler.
function M.tick()
	forEachActiveDrill(animateActiveDrill)
	updateDrillTimers()

	-- SUPER TILE: pulse HSV rainbow on every tile tagged with TileName = "SUPER TILE".
	-- Use cached set built once + maintained by attribute change listener — was scanning the
	-- entire workspace tree every frame which dominated frame time.
	local t = workspace:GetServerTimeNow()
	for tilePart in pairs(_superTileSet) do
		if tilePart.Parent then
			local hue = (t * 0.6 + tilePart.Position.X * 0.02 + tilePart.Position.Z * 0.02) % 1
			tilePart.Color = Color3.fromHSV(hue, 1, 1)
		end
	end
end

return M
