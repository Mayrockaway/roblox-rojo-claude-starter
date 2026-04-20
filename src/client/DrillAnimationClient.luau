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

	-- Spin: integrate angular speed over time. speed(t) = BASE + PEAK * t^2  (accelerating)
	-- Integral from 0 to t = BASE*t + PEAK*t^3/3. We express in alpha so: duration * (BASE*alpha + PEAK*alpha^3/3)
	local BASE_RAD = 3   -- starting angular speed rad/s
	local PEAK_RAD = 40  -- added peak angular speed at alpha=1
	local spinAngle = duration * (BASE_RAD * alpha + PEAK_RAD * alpha * alpha * alpha / 3)

	-- Sink: smoothly descends to fully submerged at alpha=1
	local heightY = activeDrillHeights[model] or 5
	local sinkDepth = heightY * alpha * alpha  -- quadratic ease-in so it accelerates downward

	local offset = CFrame.new(0, -sinkDepth, 0) * CFrame.Angles(0, spinAngle, 0)
	local target = basePivot * offset
	if model:IsA("Model") then
		model:PivotTo(target)
	else
		(model :: BasePart).CFrame = target
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

-- Update the text on every drill's static timer billboard
local function updateDrillTimers()
	local now = workspace:GetServerTimeNow()
	for folder in pairs(_activeDrillsFolders) do
		if folder.Parent then
			for _, anchor in ipairs(folder:GetChildren()) do
				if anchor.Name:match("^DrillTimer_") and anchor:IsA("BasePart") then
					local bb = anchor:FindFirstChild("TimerGui")
					local lbl = bb and bb:FindFirstChild("TimerLabel")
					if lbl and lbl:IsA("TextLabel") then
						local endT = tonumber(anchor:GetAttribute("EndTime")) or 0
						local remaining = math.max(0, endT - now)
						if remaining >= 60 then
							lbl.Text = string.format("%dm %02ds", math.floor(remaining / 60), math.floor(remaining % 60))
						else
							lbl.Text = string.format("%.1fs", remaining)
						end
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
