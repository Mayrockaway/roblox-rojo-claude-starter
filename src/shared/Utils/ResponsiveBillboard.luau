--!strict
--- ResponsiveBillboard
---
--- Cross-platform sizing for `BillboardGui`s in this game.
---
--- ### Why this module exists
---
--- `BillboardGui.Size` (Offset mode) is a *world-pixel* size, not a viewport-
--- relative size. The engine distance-scales it via 3D perspective (closer =
--- larger, further = smaller — exactly what world-anchored UI wants), but it
--- does **not** account for viewport DPI / resolution. A `220 x 56` pump
--- label reads:
---
--- | Viewport             | % of screen width |
--- |----------------------|-------------------|
--- | Phone (~1024 px)     | ~21%  (too big)   |
--- | 1080p (1920 px)      | ~11%              |
--- | 4K (3840 px)         | ~6%   (too small) |
---
--- `Scale` mode on `BillboardGui` is the wrong fix — it bypasses distance
--- scaling and would make a label 200 studs away the same screen size as
--- one right next to the camera.
---
--- ### How this works
---
--- 1. Whoever creates the `BillboardGui` calls `Mark(bb, baseW, baseH)`,
---    which stamps two attributes on the billboard (the design-target pixel
---    size at the reference viewport) and sets an initial `Size`.
--- 2. The client-side controller (`StartClient()`) scans workspace +
---    PlayerGui at startup and listens to `DescendantAdded` for new ones.
--- 3. Whenever the camera's `ViewportSize` changes (or a billboard is added),
---    every tagged `BillboardGui` is rescaled to `base * scale`, where
---    `scale = clamp(viewport.X / REF_VIEWPORT_WIDTH, MIN_SCALE, MAX_SCALE)`.
---
--- ### Net result
---
--- One design-target pixel size per billboard reads at the same on-screen
--- proportion on phone, laptop, 1080p desktop, and 4K. Distance falloff
--- (the natural 3D perspective shrink) stays intact because `Size` is still
--- in offset units.
---
--- ### Author/server vs runtime/client split
---
--- * Server (or client author) calls `Mark(...)` once at creation time. This
---   is `safe to call on either side` — it only sets attributes + an initial
---   `Size`.
--- * Client owns the per-viewport size. The server should NOT re-assert
---   `bb.Size` after creation (that would clobber the client's locally-
---   resized billboard every tick). For idempotent server-side cleanup
---   passes, call `EnsureMarked(bb, baseW, baseH)` instead — it stamps
---   attributes if missing but does not touch `Size` once it exists.

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local ResponsiveBillboard = {}

ResponsiveBillboard.ATTR_BASE_W = "RespBillboardBaseW"
ResponsiveBillboard.ATTR_BASE_H = "RespBillboardBaseH"

-- Reference viewport width in pixels. A billboard tagged with `(220, 56)` will
-- render at exactly `220 x 56` on a viewport this wide. 1366 = "laptop class"
-- because that is the rough mid-point between modern phone width (~900-1100
-- rendered) and 1080p desktop (1920) — keeps both ends within the clamp.
ResponsiveBillboard.REF_VIEWPORT_WIDTH = 1366

-- Clamps prevent extreme phones (very narrow rendered width) from going so
-- small the billboard becomes unreadable, and prevent 4K / ultrawide from
-- blowing the billboard up to silly proportions.
--   * `MIN_SCALE = 0.55` → ~750 px viewport (small phone) shows ~`120 x 31`
--     for a `220 x 56` base. Still readable.
--   * `MAX_SCALE = 1.6`  → 4K (3840 px) caps at `352 x 90`. Bigger than the
--     base 220x56 but not absurd.
ResponsiveBillboard.MIN_SCALE = 0.55
ResponsiveBillboard.MAX_SCALE = 1.6

--- Compute the viewport-aware scale factor. Pure function (no side effects).
function ResponsiveBillboard.ScaleForViewport(viewportWidth: number): number
	if typeof(viewportWidth) ~= "number" or viewportWidth <= 0 then
		return 1
	end
	local s = viewportWidth / ResponsiveBillboard.REF_VIEWPORT_WIDTH
	if s < ResponsiveBillboard.MIN_SCALE then
		s = ResponsiveBillboard.MIN_SCALE
	end
	if s > ResponsiveBillboard.MAX_SCALE then
		s = ResponsiveBillboard.MAX_SCALE
	end
	return s
end

--- Tag a `BillboardGui` as responsive and seed its initial `Size`.
---
--- Safe on server or client. Sets `RespBillboardBaseW` / `RespBillboardBaseH`
--- attributes (the design-target pixel size at `REF_VIEWPORT_WIDTH`) and
--- writes an initial `Size = UDim2.fromOffset(baseW, baseH)` so any client
--- that has not yet booted the controller still sees a sane size.
function ResponsiveBillboard.Mark(bb: BillboardGui, baseW: number, baseH: number)
	if not bb or not bb:IsA("BillboardGui") then
		return
	end
	bb:SetAttribute(ResponsiveBillboard.ATTR_BASE_W, baseW)
	bb:SetAttribute(ResponsiveBillboard.ATTR_BASE_H, baseH)
	bb.Size = UDim2.fromOffset(baseW, baseH)
end

--- Stamp the responsive attributes only if they are missing. Use from
--- server-side idempotent cleanup passes (`_sync` style) so existing
--- billboards from older code paths get tagged on the next tick without
--- overwriting `Size` (which the client controller now owns).
function ResponsiveBillboard.EnsureMarked(bb: BillboardGui, baseW: number, baseH: number)
	if not bb or not bb:IsA("BillboardGui") then
		return
	end
	if bb:GetAttribute(ResponsiveBillboard.ATTR_BASE_W) == nil then
		bb:SetAttribute(ResponsiveBillboard.ATTR_BASE_W, baseW)
	end
	if bb:GetAttribute(ResponsiveBillboard.ATTR_BASE_H) == nil then
		bb:SetAttribute(ResponsiveBillboard.ATTR_BASE_H, baseH)
	end
end

local function getBase(bb: BillboardGui): (number?, number?)
	local baseW = bb:GetAttribute(ResponsiveBillboard.ATTR_BASE_W)
	local baseH = bb:GetAttribute(ResponsiveBillboard.ATTR_BASE_H)
	if typeof(baseW) ~= "number" or typeof(baseH) ~= "number" then
		return nil, nil
	end
	return baseW, baseH
end

--- Apply the current viewport scale to one tagged `BillboardGui`. Client only.
function ResponsiveBillboard.ApplyTo(bb: BillboardGui, viewportWidth: number?)
	if not bb or not bb:IsA("BillboardGui") then
		return
	end
	local baseW, baseH = getBase(bb)
	if baseW == nil or baseH == nil then
		return
	end
	local vw = viewportWidth
	if vw == nil then
		local cam = Workspace.CurrentCamera
		vw = cam and cam.ViewportSize.X or ResponsiveBillboard.REF_VIEWPORT_WIDTH
	end
	local s = ResponsiveBillboard.ScaleForViewport(vw)
	bb.Size = UDim2.fromOffset(math.floor(baseW * s + 0.5), math.floor(baseH * s + 0.5))
end

local _started = false

--- Bootstrap the client-side auto-resize controller. Idempotent.
---
--- Scans `Workspace` and the local `PlayerGui` for tagged `BillboardGui`s
--- and rescales them to the current viewport. Listens to
--- `DescendantAdded` on both roots so future billboards get picked up
--- automatically, and to `Camera:GetPropertyChangedSignal("ViewportSize")`
--- so window resizes / orientation changes immediately re-apply.
function ResponsiveBillboard.StartClient()
	if _started then
		return
	end
	_started = true
	if RunService:IsServer() and not RunService:IsClient() then
		return
	end

	local tracked: { [BillboardGui]: true } = {}
	local cam: Camera? = Workspace.CurrentCamera
	local viewportConn: RBXScriptConnection? = nil

	local function applyAll()
		local vw = cam and cam.ViewportSize.X or ResponsiveBillboard.REF_VIEWPORT_WIDTH
		for bb in pairs(tracked) do
			if bb.Parent then
				ResponsiveBillboard.ApplyTo(bb, vw)
			else
				tracked[bb] = nil
			end
		end
	end

	local function track(bb: BillboardGui)
		if tracked[bb] then
			return
		end
		tracked[bb] = true
		bb.Destroying:Connect(function()
			tracked[bb] = nil
		end)
		local vw = cam and cam.ViewportSize.X or ResponsiveBillboard.REF_VIEWPORT_WIDTH
		ResponsiveBillboard.ApplyTo(bb, vw)
	end

	local function consider(d: Instance)
		if d:IsA("BillboardGui") and d:GetAttribute(ResponsiveBillboard.ATTR_BASE_W) ~= nil then
			track(d)
		end
	end

	local function scanRoot(root: Instance?)
		if not root then
			return
		end
		for _, d in ipairs(root:GetDescendants()) do
			consider(d)
		end
	end

	local function bindCamera()
		if viewportConn then
			viewportConn:Disconnect()
			viewportConn = nil
		end
		cam = Workspace.CurrentCamera
		if cam then
			viewportConn = cam:GetPropertyChangedSignal("ViewportSize"):Connect(applyAll)
		end
		applyAll()
	end

	scanRoot(Workspace)
	local lp = Players.LocalPlayer
	if lp then
		local pg = lp:FindFirstChildOfClass("PlayerGui") or lp:WaitForChild("PlayerGui", 5)
		scanRoot(pg)
		if pg then
			pg.DescendantAdded:Connect(consider)
		end
	end

	Workspace.DescendantAdded:Connect(consider)
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(bindCamera)
	bindCamera()
end

return ResponsiveBillboard
