--!strict
-- Fit a ship (or any Model) inside a ViewportFrame using the viewport Camera FOV + rect aspect.
-- Uses a bounding sphere from `Model:GetBoundingBox()` (oriented box half-diagonal = tight enough, rotation-invariant).

export type FitOptions = {
	-- Extra margin beyond tight fit (1.0 = none).
	padding: number?,
	-- World-space offset direction from model center toward camera (normalized internally).
	viewDirection: Vector3?,
}

local DEFAULT_PADDING = 1.12
local DEFAULT_DIR = Vector3.new(1, 0.42, 1)

local ViewportShipFit = {}

local function orientedBoxBoundingRadius(size: Vector3): number
	local sx = math.max(size.X, 1e-4)
	local sy = math.max(size.Y, 1e-4)
	local sz = math.max(size.Z, 1e-4)
	return 0.5 * math.sqrt(sx * sx + sy * sy + sz * sz)
end

-- Minimum camera distance so a sphere of `radius` at the look target fits both vertical and horizontal FOV cones.
local function distanceToFitSphere(radius: number, verticalFovDegrees: number, aspectWidthOverHeight: number): number
	local vfov = math.rad(verticalFovDegrees)
	local tanHalfV = math.tan(vfov * 0.5)
	local dVert = radius / math.max(tanHalfV, 1e-5)

	local hfov = 2 * math.atan(tanHalfV * aspectWidthOverHeight)
	local tanHalfH = math.tan(hfov * 0.5)
	local dHorz = radius / math.max(tanHalfH, 1e-5)

	return math.max(dVert, dHorz)
end

function ViewportShipFit.getViewportCamera(viewport: ViewportFrame): Camera?
	local cam = viewport.CurrentCamera
	if cam and cam:IsA("Camera") then
		return cam
	end
	local child = viewport:FindFirstChildOfClass("Camera")
	if child and child:IsA("Camera") then
		return child
	end
	return nil
end

-- Aim `camera` so `model` (already parented under `viewport`) is fully in frame.
function ViewportShipFit.frameModelInViewport(viewport: ViewportFrame, model: Model, options: FitOptions?)
	if not model.PrimaryPart then
		return
	end

	local cam = ViewportShipFit.getViewportCamera(viewport)
	if not cam then
		return
	end

	local cf, size = model:GetBoundingBox()
	local center = cf.Position
	local radius = orientedBoxBoundingRadius(size)

	local pad = DEFAULT_PADDING
	local dir = DEFAULT_DIR
	if options then
		if typeof(options.padding) == "number" and options.padding == options.padding and options.padding >= 1 then
			pad = options.padding
		end
		if typeof(options.viewDirection) == "Vector3" then
			local v = options.viewDirection
			if v.Magnitude > 1e-4 then
				dir = v
			end
		end
	end

	local aspect = viewport.AbsoluteSize.X / math.max(viewport.AbsoluteSize.Y, 1)
	if aspect ~= aspect or aspect <= 0 then
		aspect = 1
	end

	local dist = distanceToFitSphere(radius * pad, cam.FieldOfView, aspect)
	local lookFrom = center + dir.Unit * dist
	cam.CFrame = CFrame.lookAt(lookFrom, center, Vector3.yAxis)
end

return ViewportShipFit
