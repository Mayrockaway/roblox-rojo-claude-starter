--!strict
-- **Player → POI `Beam`** (two `Attachment`s). Parent pattern from DevForum:
-- https://devforum.roblox.com/t/how-to-make-arrows-that-guide-player-towards-a-point-of-interest/422775
--
-- **Multi-channel:** `attachAt(beamId, player, target, style?)`, `detachAt(beamId)`, `detachAll()`.
-- Legacy **`attach` / `detach`** operate a single channel named **`"default"`** (detach clears every channel).
--
-- Instances created by this module use **`SetAttribute("PlayerToPoiBeamOwned", true)`**.

local Workspace = game:GetService("Workspace")

local ATT_TAG = "PlayerToPoiBeamOwned"

export type BeamStyle = {
	texture: string?,
	textureMode: Enum.TextureMode?,
	textureSpeed: number?,
	textureLength: number?,
	width0: number?,
	width1: number?,
	color: ColorSequence?,
	transparency: NumberSequence?,
	lightEmission: number?,
	faceCamera: boolean?,
	zOffset: number?,
	curveSize0: number?,
	curveSize1: number?,
	segments: number?,
	characterAttachOffset: Vector3?,
	targetAttachOffset: Vector3?,
}

-- **Default style:** flowing FTUE-yellow arrow chevrons (matches `FtueTutorialTileHighlight.EDGE_COLOR`).
-- Override per-channel via `BeamStyle` in `FtuePoiBeamConfig`.
local FTUE_YELLOW = Color3.fromRGB(255, 230, 55)
local DEFAULT_TEXTURE_ID = "rbxassetid://94844325087717"
local DEFAULT_STYLE: BeamStyle = {
	texture = DEFAULT_TEXTURE_ID,
	textureMode = Enum.TextureMode.Wrap,
	textureSpeed = 1.5,
	textureLength = 1.6,
	width0 = 2.4,
	width1 = 2.4,
	color = ColorSequence.new(FTUE_YELLOW, FTUE_YELLOW),
	transparency = NumberSequence.new(0),
	lightEmission = 1,
	faceCamera = true,
	zOffset = 0,
	curveSize0 = 0,
	curveSize1 = 0,
	segments = 10,
	characterAttachOffset = Vector3.new(0, 1.4, 0.2),
	targetAttachOffset = Vector3.new(0, 0, 0),
}

type ChannelState = {
	trackedPlayer: Player,
	trackedTarget: BasePart,
	lastStyle: BeamStyle?,
	activeBeam: Beam?,
	attChar: Attachment?,
	attTarget: Attachment?,
	targetAncestryConn: RBXScriptConnection?,
}

local PlayerToPoiBeam = {}

--- Asset id used by the default style; expose so callers (`PlayerToPoiBeamBootstrap`) can preload it.
PlayerToPoiBeam.DEFAULT_TEXTURE_ID = DEFAULT_TEXTURE_ID

local channels: { [string]: ChannelState } = {}
local charConn: RBXScriptConnection? = nil
local charConnPlayer: Player? = nil

local function sanitizeBeamId(beamId: string): string
	return beamId:gsub("[^%w_]", "_")
end

local function disconnectCharIfIdle()
	if charConn then
		charConn:Disconnect()
		charConn = nil
	end
	charConnPlayer = nil
end

local function ensureCharConn(player: Player)
	if charConn and charConnPlayer == player then
		return
	end
	disconnectCharIfIdle()
	charConnPlayer = player
	charConn = player.CharacterAdded:Connect(function(character)
		--- `CharacterAdded` fires the moment the Character model is parented,
		--- but `HumanoidRootPart` can be a frame or two behind on respawn /
		--- rejoin (especially with streaming). A bare `task.defer(rewire)`
		--- frequently runs while `Character:FindFirstChild("HumanoidRootPart")`
		--- is still nil — `_tryWireBeamChannel` then short-circuits (destroys
		--- visuals, returns), the FTUE beams vanish, and nothing retries
		--- until the next attribute change. Waiting for HRP first guarantees
		--- a successful rewire on every respawn.
		task.spawn(function()
			local hrp = character:WaitForChild("HumanoidRootPart", 10)
			if not hrp then
				return
			end
			task.defer(function()
				for beamId, ch in pairs(channels) do
					if ch.trackedPlayer == player and ch.trackedTarget and ch.trackedTarget.Parent then
						PlayerToPoiBeam._tryWireBeamChannel(beamId, player)
					end
				end
			end)
		end)
	end)
end

local function destroyOwned(inst: Instance?)
	if not inst then
		return
	end
	if inst:GetAttribute(ATT_TAG) == true then
		inst:Destroy()
	end
end

local function destroyChannelVisuals(ch: ChannelState)
	if ch.targetAncestryConn then
		ch.targetAncestryConn:Disconnect()
		ch.targetAncestryConn = nil
	end
	ch.activeBeam = nil
	destroyOwned(ch.attChar)
	ch.attChar = nil
	destroyOwned(ch.attTarget)
	ch.attTarget = nil
end

local function applyStyle(beam: Beam, style: BeamStyle)
	local s = style
	beam.Texture = s.texture or DEFAULT_STYLE.texture or ""
	beam.TextureMode = s.textureMode or DEFAULT_STYLE.textureMode or Enum.TextureMode.Wrap
	beam.TextureSpeed = s.textureSpeed or DEFAULT_STYLE.textureSpeed or 0
	beam.TextureLength = s.textureLength or DEFAULT_STYLE.textureLength or 1
	beam.Width0 = s.width0 or DEFAULT_STYLE.width0 or 0.2
	beam.Width1 = s.width1 or DEFAULT_STYLE.width1 or 0.2
	beam.Color = s.color or DEFAULT_STYLE.color or ColorSequence.new(Color3.new(1, 1, 1))
	beam.Transparency = s.transparency or DEFAULT_STYLE.transparency or NumberSequence.new(0.3)
	beam.LightEmission = s.lightEmission or DEFAULT_STYLE.lightEmission or 0
	beam.ZOffset = s.zOffset or DEFAULT_STYLE.zOffset or 0
	beam.CurveSize0 = s.curveSize0 or DEFAULT_STYLE.curveSize0 or 0
	beam.CurveSize1 = s.curveSize1 or DEFAULT_STYLE.curveSize1 or 0
	beam.Segments = s.segments or DEFAULT_STYLE.segments or 10
	beam.FaceCamera = if s.faceCamera == nil then (DEFAULT_STYLE.faceCamera == true) else (s.faceCamera == true)
end

function PlayerToPoiBeam._tryWireBeamChannel(beamId: string, player: Player)
	local ch = channels[beamId]
	if not ch then
		return
	end
	if not (ch.trackedTarget and ch.trackedTarget.Parent) then
		PlayerToPoiBeam.detachAt(beamId)
		return
	end
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not (hrp and hrp:IsA("BasePart")) then
		destroyChannelVisuals(ch)
		return
	end

	destroyChannelVisuals(ch)

	local style = ch.lastStyle or DEFAULT_STYLE
	local charOff = style.characterAttachOffset or DEFAULT_STYLE.characterAttachOffset or Vector3.zero
	local tgtOff = style.targetAttachOffset or DEFAULT_STYLE.targetAttachOffset or Vector3.zero
	local suffix = sanitizeBeamId(beamId)

	local a0 = Instance.new("Attachment")
	a0.Name = "PlayerToPoiBeam_Char_" .. suffix
	a0.Position = charOff
	a0:SetAttribute(ATT_TAG, true)
	a0.Parent = hrp
	ch.attChar = a0

	local a1 = Instance.new("Attachment")
	a1.Name = "PlayerToPoiBeam_Target_" .. suffix
	a1.Position = tgtOff
	a1:SetAttribute(ATT_TAG, true)
	a1.Parent = ch.trackedTarget
	ch.attTarget = a1

	local beam = Instance.new("Beam")
	beam.Name = "PlayerToPoiBeam_" .. suffix
	beam.Attachment0 = a0
	beam.Attachment1 = a1
	applyStyle(beam, style)
	beam:SetAttribute(ATT_TAG, true)
	-- LoadingBootstrap pre-warms FTUE beam textures during join, so the beam can
	-- render immediately here without its own per-attach preload path.
	beam.Enabled = true
	beam.Parent = hrp
	ch.activeBeam = beam

	ch.targetAncestryConn = ch.trackedTarget.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			PlayerToPoiBeam.detachAt(beamId)
		end
	end)
end

function PlayerToPoiBeam.detachAt(beamId: string)
	local ch = channels[beamId]
	if not ch then
		return
	end
	destroyChannelVisuals(ch)
	channels[beamId] = nil
	if next(channels) == nil then
		disconnectCharIfIdle()
	end
end

function PlayerToPoiBeam.detachAll()
	local ids: { string } = {}
	for beamId in pairs(channels) do
		table.insert(ids, beamId)
	end
	for _, beamId in ipairs(ids) do
		PlayerToPoiBeam.detachAt(beamId)
	end
end

--- Active beam channel ids (for orchestration).
function PlayerToPoiBeam.getActiveBeamIds(): { string }
	local r: { string } = {}
	for beamId in pairs(channels) do
		table.insert(r, beamId)
	end
	return r
end

--- Wire one **`Beam`** from **`HumanoidRootPart`** to **`target`** under **`beamId`** (multiple beams = multiple ids).
function PlayerToPoiBeam.attachAt(beamId: string, player: Player, target: BasePart, style: BeamStyle?)
	if beamId == "" or not (player and player.Parent) then
		return
	end
	if not (target and target:IsDescendantOf(Workspace)) then
		return
	end

	PlayerToPoiBeam.detachAt(beamId)

	local ch: ChannelState = {
		trackedPlayer = player,
		trackedTarget = target,
		lastStyle = style,
		activeBeam = nil,
		attChar = nil,
		attTarget = nil,
		targetAncestryConn = nil,
	}
	channels[beamId] = ch

	PlayerToPoiBeam._tryWireBeamChannel(beamId, player)
	ensureCharConn(player)
end

--- Clears **all** channels, then wires **`"default"`** (same as older single-beam API).
function PlayerToPoiBeam.attach(player: Player, target: BasePart, style: BeamStyle?)
	PlayerToPoiBeam.detachAll()
	PlayerToPoiBeam.attachAt("default", player, target, style)
end

function PlayerToPoiBeam.detach()
	PlayerToPoiBeam.detachAll()
end

--- Walks a Model and returns the **rig HumanoidRootPart** of the first descendant
--- `Humanoid` it finds (preferring `Humanoid.RootPart`, falling back to a sibling
--- named `HumanoidRootPart`). Used by `resolveBasePart` so beams pointed at humanoid
--- NPCs (e.g. `PirateHire` Model > `Pirate` rig, `PlotDispatch` Model > `Model > StarterCharacter`)
--- snap to the actor instead of a random nested decoration `BasePart`.
local function resolveHumanoidRigPart(model: Model): BasePart?
	for _, d in model:GetDescendants() do
		if d:IsA("Humanoid") then
			local hum = d :: Humanoid
			if hum.RootPart then
				return hum.RootPart
			end
			local rigParent = hum.Parent
			if rigParent then
				local hrp = rigParent:FindFirstChild("HumanoidRootPart")
				if hrp and hrp:IsA("BasePart") then
					return hrp
				end
			end
		end
	end
	return nil
end

function PlayerToPoiBeam.resolveBasePart(inst: Instance?): BasePart?
	if not inst then
		return nil
	end
	if inst:IsA("BasePart") then
		return inst
	end
	if inst:IsA("Model") then
		local m = inst :: Model
		local hrp = resolveHumanoidRigPart(m)
		if hrp then
			return hrp
		end
		if m.PrimaryPart then
			return m.PrimaryPart
		end
		local p = m:FindFirstChildWhichIsA("BasePart", true)
		if p and p:IsA("BasePart") then
			return p
		end
	end
	return nil
end

function PlayerToPoiBeam.findPartByName(root: Instance, name: string, recursive: boolean?): BasePart?
	local r = if recursive == true then root:FindFirstChild(name, true) else root:FindFirstChild(name)
	return PlayerToPoiBeam.resolveBasePart(r)
end

local function resolveWorldPartFromPointerGui(root: Instance, pointerGuiName: string): BasePart?
	local gui = root:FindFirstChild(pointerGuiName, true)
	if not (gui and gui:IsA("GuiObject")) then
		return nil
	end
	local bb = gui:FindFirstAncestorOfClass("BillboardGui")
	if bb then
		local ad = bb.Adornee
		if ad and ad:IsA("BasePart") then
			return ad
		end
		local par = bb.Parent
		if par and par:IsA("BasePart") then
			return par
		end
	end
	local sg = gui:FindFirstAncestorOfClass("SurfaceGui")
	if sg then
		local ad = sg.Adornee
		if ad and ad:IsA("BasePart") then
			return ad
		end
	end
	local anc = gui:FindFirstAncestorWhichIsA("BasePart")
	if anc then
		return anc
	end
	local m = gui:FindFirstAncestorWhichIsA("Model")
	if m then
		return PlayerToPoiBeam.resolveBasePart(m)
	end
	return nil
end

local function resolveFirstModelNamed(root: Instance, modelName: string): BasePart?
	for _, d in root:GetDescendants() do
		if d.Name == modelName and d:IsA("Model") then
			return PlayerToPoiBeam.resolveBasePart(d)
		end
	end
	return nil
end

local function resolveFirstWithAttribute(root: Instance, attributeName: string): BasePart?
	for _, d in root:GetDescendants() do
		if d:GetAttribute(attributeName) == true then
			local part = PlayerToPoiBeam.resolveBasePart(d)
			if part then
				return part
			end
		end
	end
	return nil
end

--- **FTUE-style POI:** tries **`pointerGuiName`** → **`attributeName`** → **`modelName`**, returning the first match.
function PlayerToPoiBeam.resolveFtueWorldPoi(root: Instance, pointerGuiName: string?, modelName: string?, attributeName: string?): BasePart?
	if typeof(pointerGuiName) == "string" and pointerGuiName ~= "" then
		local fromGui = resolveWorldPartFromPointerGui(root, pointerGuiName)
		if fromGui then
			return fromGui
		end
	end
	if typeof(attributeName) == "string" and attributeName ~= "" then
		local fromAttr = resolveFirstWithAttribute(root, attributeName)
		if fromAttr then
			return fromAttr
		end
	end
	if typeof(modelName) == "string" and modelName ~= "" then
		return resolveFirstModelNamed(root, modelName)
	end
	return nil
end

--- @deprecated Use **`resolveFtueWorldPoi(root, "FtueDockmanWorldPointerRoot", "Dockman")`**
function PlayerToPoiBeam.resolveFtueDockmanPoiPart(root: Instance): BasePart?
	return PlayerToPoiBeam.resolveFtueWorldPoi(root, "FtueDockmanWorldPointerRoot", "Dockman")
end

return PlayerToPoiBeam
