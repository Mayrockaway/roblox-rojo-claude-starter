--!strict
-- Tuning for strait / shipment world FX (particles, etc.) vs ship footprint.
-- Calibrate `ReferenceShipHorizontalExtentStuds` once your "medium" hull is final:
-- in Studio, select the boat Model → note the larger of X / Z from Bounding Box / Extents.

local ShipmentFxConfig = {
	--- Horizontal size (studs) that maps to particleFxScale = 1.0 (max of model extent X vs Z).
	ReferenceShipHorizontalExtentStuds = 28,
	ParticleFxScaleMin = 0.45,
	ParticleFxScaleMax = 2.75,
}

return ShipmentFxConfig
