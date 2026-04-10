--!strict
-- Scale ParticleEmitter visuals from a ship footprint + optional per-boat-type multiplier.

local BoatConfig = require(script.Parent.Config.BoatConfig)
local ShipmentFxConfig = require(script.Parent.Config.ShipmentFxConfig)

local ParticleFxScale = {}

local function scaleNumberSequence(ns: NumberSequence, factor: number): NumberSequence
	local keypoints = table.create(#ns.Keypoints)
	for i, kp in ipairs(ns.Keypoints) do
		keypoints[i] = NumberSequenceKeypoint.new(kp.Time, kp.Value * factor)
	end
	return NumberSequence.new(keypoints)
end

function ParticleFxScale.ComputePayloadScale(boat: Instance, boatTypeId: string?): number
	local raw = 1
	if boat:IsA("Model") then
		local ext = boat:GetExtentsSize()
		local horiz = math.max(ext.X, ext.Z)
		local ref = ShipmentFxConfig.ReferenceShipHorizontalExtentStuds
		if ref > 1e-3 then
			raw = horiz / ref
		end
	end

	local typeMul = 1
	if typeof(boatTypeId) == "string" then
		local def = BoatConfig.Boats[boatTypeId]
		local m = if def then (def :: any).fxParticleScale else nil
		if typeof(m) == "number" and m == m and m > 0 then
			typeMul = m
		end
	end

	return math.clamp(
		raw * typeMul,
		ShipmentFxConfig.ParticleFxScaleMin,
		ShipmentFxConfig.ParticleFxScaleMax
	)
end

function ParticleFxScale.ApplyToEmitter(emitter: ParticleEmitter, factor: number)
	if factor >= 0.999 and factor <= 1.001 then
		return
	end
	emitter.Size = scaleNumberSequence(emitter.Size, factor)
	local spd = emitter.Speed
	emitter.Speed = NumberRange.new(spd.Min * factor, spd.Max * factor)
	local life = emitter.Lifetime
	local lifeMul = math.sqrt(factor)
	emitter.Lifetime = NumberRange.new(life.Min * lifeMul, life.Max * lifeMul)
	local acc = emitter.Acceleration
	emitter.Acceleration = acc * factor
end

function ParticleFxScale.ApplyToDescendants(root: Instance, factor: number)
	if factor >= 0.999 and factor <= 1.001 then
		return
	end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("ParticleEmitter") then
			ParticleFxScale.ApplyToEmitter(d, factor)
		end
	end
end

return ParticleFxScale
