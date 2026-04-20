--!strict

local Workspace = game:GetService("Workspace")

local HIGHLIGHT_NAME = "TankUpgradeHoverHighlight"
local HOVER_COLOR = Color3.fromRGB(255, 220, 120)
local CLICK_NAME = "TankUpgradeSignClick"

local connectionsByDetector: { [ClickDetector]: { RBXScriptConnection } } = {}

local function getSignPart(detector: ClickDetector): BasePart?
	local parent = detector.Parent
	if not (parent and parent:IsA("BasePart")) then
		return nil
	end
	if parent.Name ~= "Sign" then
		return nil
	end
	local model = parent.Parent
	if not (model and model:IsA("Model") and model.Name == "Minecraft Wood Sign") then
		return nil
	end
	return parent
end

local function getOrCreateHighlight(signPart: BasePart): Highlight
	local model = signPart.Parent
	local existing = model and model:FindFirstChild(HIGHLIGHT_NAME)
	if existing and existing:IsA("Highlight") then
		return existing
	end
	local h = Instance.new("Highlight")
	h.Name = HIGHLIGHT_NAME
	h.FillTransparency = 1
	h.OutlineTransparency = 0
	h.OutlineColor = HOVER_COLOR
	h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	h.Enabled = false
	h.Adornee = model
	h.Parent = model
	return h
end

local function cleanupDetector(detector: ClickDetector)
	local conns = connectionsByDetector[detector]
	if not conns then
		return
	end
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	connectionsByDetector[detector] = nil
end

local function hookDetector(detector: ClickDetector)
	if connectionsByDetector[detector] then
		return
	end
	if detector.Name ~= CLICK_NAME then
		return
	end

	local signPart = getSignPart(detector)
	if not signPart then
		return
	end

	local highlight = getOrCreateHighlight(signPart)
	local conns = {}
	table.insert(conns, detector.MouseHoverEnter:Connect(function()
		highlight.Enabled = true
	end))
	table.insert(conns, detector.MouseHoverLeave:Connect(function()
		highlight.Enabled = false
	end))
	table.insert(conns, detector.Destroying:Connect(function()
		highlight.Enabled = false
		cleanupDetector(detector)
	end))
	connectionsByDetector[detector] = conns
end

--- **Streaming/perf note:** this script previously did a full `Workspace:GetDescendants()`
--- walk inline at module-load time. With ~37k Workspace descendants, that walk shows
--- up as a one-shot ~50–200 ms hitch on the first frame after spawn.
---
--- The startup walk now runs after a short delay (off the join-frame critical path)
--- and the `DescendantAdded` listener is established **first**, so any tank-sign
--- click detector that arrives before the walk completes is still hooked promptly.
--- Late detectors are deduped by the `connectionsByDetector` guard inside
--- `hookDetector`, so running both paths is safe.
---
--- Longer-term, this should move to `CollectionService:GetInstanceAddedSignal(tag)`
--- with the relevant detectors tagged on the server. That removes the per-Workspace-
--- descendant Lua cost entirely, which is the real driver of multi-hundred-ms
--- hitches during streaming-chunk arrival.
Workspace.DescendantAdded:Connect(function(d)
	if d:IsA("ClickDetector") and d.Name == CLICK_NAME then
		hookDetector(d)
	end
end)

task.delay(2, function()
	for _, d in ipairs(Workspace:GetDescendants()) do
		if d:IsA("ClickDetector") and d.Name == CLICK_NAME then
			hookDetector(d)
		end
	end
end)

