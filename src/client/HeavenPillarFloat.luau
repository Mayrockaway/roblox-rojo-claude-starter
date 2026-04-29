--!strict
--- Subtle zero-gravity floating animation for Greek Pillars in Oil Heaven.
--- Each pillar bobs up/down and drifts with a unique phase so they feel
--- independently weightless. Only runs while the player is in heaven.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

local HeavenPillarFloat = {}

local running = false
local connection: RBXScriptConnection? = nil

-- Per-pillar animation state
local pillarStates: { { part: BasePart, baseCF: CFrame, phaseY: number, phaseX: number, phaseZ: number, phaseRot: number, ampY: number, ampXZ: number, ampRot: number } } = {}

local function collectPillars()
	table.clear(pillarStates)
	for _, plot in ipairs(Workspace:GetChildren()) do
		if plot:IsA("Model") and string.match(plot.Name, "^OilHeavenPlot_%d%d$") then
			local pillarsFolder = plot:FindFirstChild("Pillars")
			if pillarsFolder then
				for i, child in ipairs(pillarsFolder:GetChildren()) do
					if child:IsA("BasePart") then
						-- Each pillar gets unique random phases and amplitudes
						local seed = i * 137 + string.len(plot.Name) * 31
						local rng = Random.new(seed)
						table.insert(pillarStates, {
							part = child,
							baseCF = child.CFrame,
							phaseY = rng:NextNumber() * math.pi * 2,
							phaseX = rng:NextNumber() * math.pi * 2,
							phaseZ = rng:NextNumber() * math.pi * 2,
							phaseRot = rng:NextNumber() * math.pi * 2,
							ampY = 1.5 + rng:NextNumber() * 1.5,      -- 1.5-3 studs vertical bob
							ampXZ = 0.3 + rng:NextNumber() * 0.5,     -- 0.3-0.8 studs horizontal drift
							ampRot = math.rad(1 + rng:NextNumber() * 2), -- 1-3 degrees tilt
						})
					end
				end
			end
		end
	end
end

local function startAnimation()
	if running then return end
	running = true
	collectPillars()
	if #pillarStates == 0 then
		running = false
		return
	end

	connection = RunService.Heartbeat:Connect(function()
		local t = os.clock()
		for _, state in ipairs(pillarStates) do
			if not state.part.Parent then continue end
			-- Slow, slightly different frequencies per axis for organic feel
			local oY = math.sin(t * 0.8 + state.phaseY) * state.ampY
			local oX = math.sin(t * 0.5 + state.phaseX) * state.ampXZ
			local oZ = math.cos(t * 0.6 + state.phaseZ) * state.ampXZ
			local rotX = math.sin(t * 0.3 + state.phaseRot) * state.ampRot
			local rotZ = math.cos(t * 0.4 + state.phaseRot * 1.3) * state.ampRot

			state.part.CFrame = state.baseCF
				* CFrame.new(oX, oY, oZ)
				* CFrame.Angles(rotX, 0, rotZ)
		end
	end)
end

local function stopAnimation()
	if not running then return end
	running = false
	if connection then
		connection:Disconnect()
		connection = nil
	end
	-- Restore original positions
	for _, state in ipairs(pillarStates) do
		if state.part.Parent then
			state.part.CFrame = state.baseCF
		end
	end
	table.clear(pillarStates)
end

function HeavenPillarFloat.start()
	startAnimation()
end

function HeavenPillarFloat.stop()
	stopAnimation()
end

function HeavenPillarFloat.refresh()
	if running then
		collectPillars()
	end
end

return HeavenPillarFloat
