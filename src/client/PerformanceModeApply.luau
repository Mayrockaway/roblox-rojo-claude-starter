--!strict
--- Applies or reverts Lite mode rendering changes.
--- Controlled by PerformanceMode module. All changes are client-local and reversible.

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local PerformanceMode = require(script.Parent:WaitForChild("PerformanceMode"))

local LocalPlayer = Players.LocalPlayer

local savedParticleRates: { [ParticleEmitter]: number } = {}
local appliedShadowParts: { [BasePart]: boolean } = {}
local disabledPostEffects: { [Instance]: boolean } = {}
local descendantConn: RBXScriptConnection? = nil

local POST_EFFECTS_TO_DISABLE = { "Bloom", "Blur" }

local PerformanceModeApply = {}

--- Disable CastShadow on all BaseParts under a given instance (non-recursive tracking).
local function disableShadows(root: Instance)
	for _, desc in root:GetDescendants() do
		if desc:IsA("BasePart") and desc.CastShadow and not appliedShadowParts[desc] then
			desc.CastShadow = false
			appliedShadowParts[desc] = true
		end
	end
end

--- Restore CastShadow on previously disabled parts.
local function restoreShadows()
	for part in appliedShadowParts do
		if part.Parent then
			part.CastShadow = true
		end
	end
	table.clear(appliedShadowParts)
end

--- Halve particle emitter rates under a given instance.
local function halveParticles(root: Instance)
	for _, desc in root:GetDescendants() do
		if desc:IsA("ParticleEmitter") and not savedParticleRates[desc] then
			savedParticleRates[desc] = desc.Rate
			desc.Rate = math.max(1, desc.Rate * 0.5)
		end
	end
end

--- Restore particle emitter rates.
local function restoreParticles()
	for emitter, rate in savedParticleRates do
		if emitter.Parent then
			emitter.Rate = rate
		end
	end
	table.clear(savedParticleRates)
end

--- Disable Bloom + Blur post-processing effects.
local function disablePostEffects()
	for _, child in Lighting:GetChildren() do
		if child:IsA("PostEffect") then
			for _, name in POST_EFFECTS_TO_DISABLE do
				if child.Name == name and child.Enabled then
					child.Enabled = false
					disabledPostEffects[child] = true
				end
			end
		end
	end
end

--- Restore post-processing effects.
local function restorePostEffects()
	for effect in disabledPostEffects do
		if effect.Parent then
			(effect :: any).Enabled = true
		end
	end
	table.clear(disabledPostEffects)
end

--- Get the local player's userId for plot ownership check.
local function getLocalUserId(): number
	return LocalPlayer.UserId
end

--- Apply Lite mode to MapDecor and other players' plots.
local function applyLite()
	local map = Workspace:FindFirstChild("Map")
	if not map then return end

	-- MapDecor: disable shadows on all 16k+ parts
	local mapDecor = map:FindFirstChild("MapDecor")
	if mapDecor then
		disableShadows(mapDecor)
	end

	-- Other players' plots: disable shadows + halve particles
	local plots = map:FindFirstChild("Plots")
	if plots then
		local myUserId = getLocalUserId()
		for _, plot in plots:GetChildren() do
			local ownerUserId = plot:GetAttribute("OwnerUserId")
			-- Skip own plot — always full quality
			if ownerUserId == myUserId then continue end
			disableShadows(plot)
			halveParticles(plot)
		end
	end

	-- Post-processing
	disablePostEffects()

	-- Watch for new parts streaming in (MapDecor descendants arrive via streaming)
	if descendantConn then
		descendantConn:Disconnect()
	end
	descendantConn = Workspace.DescendantAdded:Connect(function(desc)
		if not PerformanceMode.isLite() then return end
		if not desc:IsA("BasePart") then return end

		-- Check if it's under MapDecor
		local mapRef = Workspace:FindFirstChild("Map")
		if not mapRef then return end
		local decorRef = mapRef:FindFirstChild("MapDecor")
		if decorRef and desc:IsDescendantOf(decorRef) then
			if desc.CastShadow and not appliedShadowParts[desc] then
				desc.CastShadow = false
				appliedShadowParts[desc] = true
			end
			return
		end

		-- Check if it's under another player's plot
		local plotsRef = mapRef:FindFirstChild("Plots")
		if plotsRef then
			for _, plot in plotsRef:GetChildren() do
				if desc:IsDescendantOf(plot) then
					local ownerUserId = plot:GetAttribute("OwnerUserId")
					if ownerUserId ~= getLocalUserId() then
						if desc.CastShadow and not appliedShadowParts[desc] then
							desc.CastShadow = false
							appliedShadowParts[desc] = true
						end
					end
					return
				end
			end
		end
	end)
end

--- Revert all Lite mode changes.
local function revertLite()
	restoreShadows()
	restoreParticles()
	restorePostEffects()
	if descendantConn then
		descendantConn:Disconnect()
		descendantConn = nil
	end
end

--- Apply the current mode.
function PerformanceModeApply.apply()
	-- Always revert first for a clean slate
	revertLite()
	if PerformanceMode.isLite() then
		applyLite()
	end
end

--- Start listening for mode changes.
function PerformanceModeApply.start()
	PerformanceMode.onChanged(function()
		PerformanceModeApply.apply()
	end)
	-- Apply initial state
	PerformanceModeApply.apply()
end

return PerformanceModeApply
