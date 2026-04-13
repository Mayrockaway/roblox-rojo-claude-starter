--!strict
-- `ProgressFill.Size` X scale from server `voyageStartTime` / `voyageEndTime` on `ShipmentStarted`.
-- Visual chrome (Hint size, corners, gradients, strokes) lives in **Studio** on `StarterGui.HUD` — see `CANONICAL_STUDIO_LAYOUT.md`.
-- Wired from `ShipmentProgressBootstrap.client.luau`.

local RunService = game:GetService("RunService")

export type Packet = { [string]: any }

local playerGuiRef: PlayerGui? = nil
local voyageTickConn: RBXScriptConnection? = nil
local hudChildConn: RBXScriptConnection? = nil

local progressFill: GuiObject? = nil
local hintLabel: TextLabel? = nil

local voyageStartTime: number? = nil
local voyageEndTime: number? = nil
local activeShipmentId: string? = nil
local clearTask: thread? = nil

local function findControls(root: PlayerGui): (GuiObject?, TextLabel?)
	local hud = root:FindFirstChild("HUD")
	local canvas = hud and hud:FindFirstChild("Canvas")
	local topRow = canvas and canvas:FindFirstChild("TopRow")
	local panel = topRow and topRow:FindFirstChild("ShipmentProgressPanel")
	local track = panel and panel:FindFirstChild("ProgressTrack")
	local fill = track and track:FindFirstChild("ProgressFill")
	local hint = if panel then panel:FindFirstChild("Hint") else nil
	if not hint and track then
		hint = track:FindFirstChild("Hint")
	end
	local fillGo: GuiObject? = nil
	if fill and fill:IsA("GuiObject") then
		fillGo = fill
	end
	local h: TextLabel? = nil
	if hint and hint:IsA("TextLabel") then
		h = hint
	elseif hint then
		local tl = hint:FindFirstChildWhichIsA("TextLabel", true)
		if tl and tl:IsA("TextLabel") then
			h = tl
		end
	end
	return fillGo, h
end

local function setFillScaleX(alpha: number)
	local fill = progressFill
	if not (fill and fill.Parent) then
		return
	end
	local a = math.clamp(alpha, 0, 1)
	fill.Size = UDim2.new(a, 0, 1, 0)
end

local function tryResolve()
	local pg = playerGuiRef
	if not pg then
		return
	end
	local fill, hint = findControls(pg)
	progressFill = fill
	hintLabel = hint
end

local function stopVoyageTick()
	if voyageTickConn then
		voyageTickConn:Disconnect()
		voyageTickConn = nil
	end
end

local function voyageTick()
	if not (voyageStartTime and voyageEndTime) then
		return
	end
	if not progressFill or not progressFill.Parent then
		tryResolve()
	end
	if not progressFill then
		return
	end
	local now = workspace:GetServerTimeNow()
	if now < voyageStartTime then
		setFillScaleX(0)
	elseif now >= voyageEndTime then
		setFillScaleX(1)
	else
		local span = voyageEndTime - voyageStartTime
		if span <= 0 then
			setFillScaleX(1)
		else
			setFillScaleX((now - voyageStartTime) / span)
		end
	end
end

local function startVoyageTick()
	stopVoyageTick()
	voyageTickConn = RunService.RenderStepped:Connect(voyageTick)
end

local function stopClearTask()
	if clearTask then
		task.cancel(clearTask)
		clearTask = nil
	end
end

local ShipmentProgressHud = {}

function ShipmentProgressHud.init(playerGui: PlayerGui)
	playerGuiRef = playerGui
	tryResolve()
	setFillScaleX(0)
	if not hudChildConn then
		hudChildConn = playerGui.ChildAdded:Connect(function(child)
			if child.Name == "HUD" then
				tryResolve()
				setFillScaleX(0)
			end
		end)
	end
	task.spawn(function()
		for _ = 1, 40 do
			tryResolve()
			setFillScaleX(0)
			if progressFill then
				break
			end
			task.wait(0.25)
		end
	end)
end

function ShipmentProgressHud.onVisualPacket(kind: string, data: Packet, localPlayer: Player)
	if typeof(data.ownerUserId) ~= "number" or data.ownerUserId ~= localPlayer.UserId then
		return
	end
	if kind == "ShipmentStarted" then
		stopClearTask()
		local voyageStart = tonumber(data.voyageStartTime)
		local voyageEnd = tonumber(data.voyageEndTime)
		if typeof(voyageStart) ~= "number" or typeof(voyageEnd) ~= "number" then
			return
		end
		voyageStartTime = voyageStart
		voyageEndTime = voyageEnd
		activeShipmentId = if typeof(data.shipmentId) == "string" then data.shipmentId :: string else nil
		tryResolve()
		setFillScaleX(0)
		if hintLabel and hintLabel.Parent then
			hintLabel.Text = "Shipment in transit…"
		end
		startVoyageTick()
	elseif kind == "ShipmentResolved" then
		local sid = if typeof(data.shipmentId) == "string" then data.shipmentId :: string else nil
		if activeShipmentId and sid and sid ~= activeShipmentId then
			return
		end
		stopVoyageTick()
		voyageStartTime = nil
		voyageEndTime = nil
		activeShipmentId = nil
		setFillScaleX(1)
		if hintLabel and hintLabel.Parent then
			hintLabel.Text = ""
		end
		stopClearTask()
		clearTask = task.delay(2.5, function()
			clearTask = nil
			setFillScaleX(0)
		end)
	end
end

return ShipmentProgressHud
