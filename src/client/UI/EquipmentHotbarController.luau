--!strict
-- Custom equipment hotbar under `PlayerGui.HUD.Canvas.EquipmentHotbar`: mirrors Backpack + Character tools,
-- merges shop stacks by `EquipmentItemId`, keyboard 1–9 / 0, equipped `UIStroke` emphasis.
-- Slot / key policy follows Roblox `BackpackScript` (CoreScripts): fixed indices 1..10, key `0` = slot 10,
-- reparenting Backpack↔Character keeps the same slot, **new** tools fill the **lowest empty** slot.
-- **Runtime:** clones `SlotTemplate`, sets `Text` / `Image` / `Visible` / `UIStroke.Enabled` only (see `ui-architecture`).

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local STACK_ATTR = Constants.EquipmentStackCountAttribute

export type SlotEntry = {
	tool: Tool,
	stackDisplay: number,
	showStackBadge: boolean,
}

local EquipmentHotbarController = {}

local started = false
local bindWait = false
local refreshToken = 0
local toolAttrConns: { RBXScriptConnection } = {}
local backpackConns: { RBXScriptConnection } = {}
local characterConns: { RBXScriptConnection } = {}
local hotbarStrip: Frame? = nil
local slotTemplate: GuiObject? = nil
local slotToTool: { [GuiObject]: Tool } = {}
local slotToStroke: { [GuiObject]: UIStroke } = {}
local stripAbsConn: RBXScriptConnection? = nil

--- Roblox-style hotbar: `toolBySlot[i]` is the `Tool` bound to keys `1..9` and `0` (slot 10). Nil = empty.
local MAX_HOTBAR_SLOTS = 10
local toolBySlot: { Tool? } = {}

local function findHudScreen(playerGui: PlayerGui): ScreenGui?
	local h = playerGui:FindFirstChild("HUD")
	if h and h:IsA("ScreenGui") then
		return h
	end
	local deep = playerGui:FindFirstChild("HUD", true)
	if deep and deep:IsA("ScreenGui") then
		return deep
	end
	return nil
end

local function findCanvasUnderHud(hud: ScreenGui): Frame?
	local direct = hud:FindFirstChild("Canvas")
	if direct and direct:IsA("Frame") then
		return direct
	end
	local nested = hud:FindFirstChild("Canvas", true)
	if nested and nested:IsA("Frame") then
		return nested
	end
	return nil
end

--- Prefer **`Canvas` direct child** so we never bind a stray `EquipmentHotbar` nested under `LeftStack` etc.
--- (Recursive search was picking wrong instances and pinning the strip to the left column.)
local function findEquipmentHotbarOnCanvas(canvas: Frame): Frame?
	for _, ch in ipairs(canvas:GetChildren()) do
		if ch.Name == "EquipmentHotbar" and ch:IsA("Frame") then
			return ch
		end
	end
	local nested = canvas:FindFirstChild("EquipmentHotbar", true)
	if nested and nested:IsA("Frame") then
		warn(
			"[Client] EquipmentHotbar: using nested `EquipmentHotbar` under "
				.. nested.Parent:GetFullName()
				.. " — move it to a **direct child** of `HUD.Canvas` (bottom-centered bar)."
		)
		return nested
	end
	return nil
end

local function findStripAndTemplate(hotbar: Frame): (Frame?, GuiObject?)
	local strip = hotbar:FindFirstChild("SlotStrip")
	if not (strip and strip:IsA("Frame")) then
		strip = hotbar:FindFirstChild("SlotStrip", true)
	end
	local template = hotbar:FindFirstChild("SlotTemplate")
	if not (template and template:IsA("GuiObject")) then
		template = hotbar:FindFirstChild("SlotTemplate", true)
	end
	if strip and strip:IsA("Frame") and template and template:IsA("GuiObject") then
		return strip :: Frame, template :: GuiObject
	end
	return nil, nil
end

local function resolveHotbar(playerGui: PlayerGui): (Frame?, GuiObject?)
	local hud = findHudScreen(playerGui)
	if not hud then
		return nil, nil
	end
	local canvas = findCanvasUnderHud(hud)
	if not canvas then
		return nil, nil
	end
	local hotbar = findEquipmentHotbarOnCanvas(canvas)
	if not hotbar then
		return nil, nil
	end
	local strip, template = findStripAndTemplate(hotbar)
	if not strip or not template then
		return nil, nil
	end
	-- Keep above other Canvas siblings (teleports, stacks) so slots receive input.
	hotbar.ZIndex = math.max(hotbar.ZIndex, 25)
	strip.ZIndex = math.max(strip.ZIndex, hotbar.ZIndex)
	-- Slots are positioned in Lua (centered row). `UIListLayout` fights manual `Position` on clones.
	local list = strip:FindFirstChildOfClass("UIListLayout")
	if list then
		list:Destroy()
	end
	return strip :: Frame, template :: GuiObject
end

local function computeSlotSidePx(strip: Frame): number
	local h = strip.AbsoluteSize.Y
	if h < 6 then
		return 56
	end
	local inset = math.max(4, math.floor(h * 0.08))
	return math.clamp(h - inset, 40, 120)
end

local function gapBetweenSlotsPx(strip: Frame): number
	return math.max(4, math.floor(strip.AbsoluteSize.Y * 0.08))
end

--- Center the slot row in `strip` (default Roblox-style: one slot centered; two slots grow symmetrically).
local function layoutCenteredSlots(strip: Frame, clones: { GuiObject }, gapPx: number, sidePx: number)
	if #clones == 0 then
		return
	end
	local w = strip.AbsoluteSize.X
	if w < 2 then
		return
	end
	local total = #clones * sidePx + math.max(0, #clones - 1) * gapPx
	local startX = (w - total) / 2
	for i, cl in ipairs(clones) do
		cl.AnchorPoint = Vector2.new(0.5, 0.5)
		local cx = startX + (i - 0.5) * sidePx + (i - 1) * gapPx
		cl.Position = UDim2.new(0, math.floor(cx + 0.5), 0.5, 0)
	end
end

local function collectSlotClonesSorted(strip: Frame): { GuiObject }
	local clones: { GuiObject } = {}
	for _, ch in ipairs(strip:GetChildren()) do
		if ch:IsA("GuiObject") and string.match(ch.Name, "^HotbarSlot_%d+$") then
			table.insert(clones, ch)
		end
	end
	table.sort(clones, function(a, b)
		local na = tonumber(string.match(a.Name, "%d+")) or 0
		local nb = tonumber(string.match(b.Name, "%d+")) or 0
		return na < nb
	end)
	return clones
end

local function relayoutExistingSlots(strip: Frame)
	local clones = collectSlotClonesSorted(strip)
	if #clones == 0 then
		return
	end
	local sidePx = computeSlotSidePx(strip)
	for _, cl in ipairs(clones) do
		cl.Size = UDim2.fromOffset(sidePx, sidePx)
	end
	layoutCenteredSlots(strip, clones, gapBetweenSlotsPx(strip), sidePx)
end

local function stackCountForTool(tool: Tool): number
	if tool:GetAttribute("EquipmentShopConsumable") == true then
		local id = tool:GetAttribute("EquipmentItemId")
		if typeof(id) == "string" and id ~= "" then
			local v = tool:GetAttribute(STACK_ATTR)
			if typeof(v) == "number" and v > 0 then
				return math.floor(v)
			end
			return 1
		end
	end
	return 1
end

local function isShopStackTool(tool: Tool): (boolean, string?)
	if tool:GetAttribute("EquipmentShopConsumable") ~= true then
		return false, nil
	end
	local id = tool:GetAttribute("EquipmentItemId")
	if typeof(id) == "string" and id ~= "" then
		return true, id
	end
	return false, nil
end

local function getEquippedTool(character: Model?): Tool?
	if not character then
		return nil
	end
	for _, c in ipairs(character:GetChildren()) do
		if c:IsA("Tool") then
			return c
		end
	end
	return nil
end

--- All tool instances for stack math (order only used for summing shop ids).
local function gatherToolsBackpackThenCharacter(player: Player): { Tool }
	local ordered: { Tool } = {}
	local bp = player:FindFirstChild("Backpack")
	if bp and bp:IsA("Backpack") then
		for _, c in ipairs(bp:GetChildren()) do
			if c:IsA("Tool") then
				table.insert(ordered, c :: Tool)
			end
		end
	end
	local char = player.Character
	if char then
		for _, c in ipairs(char:GetChildren()) do
			if c:IsA("Tool") then
				table.insert(ordered, c :: Tool)
			end
		end
	end
	return ordered
end

--- One representative per logical row, in **discovery** order (Backpack children, then Character tools).
--- Used to order **new** tools when assigning them to the lowest empty Roblox-style slot (1..10).
local function computeDesiredRepsDiscoveryOrder(player: Player): { Tool }
	local ordered = gatherToolsBackpackThenCharacter(player)
	local shopFirstRep: { [string]: Tool } = {}
	local shopRowDone: { [string]: boolean } = {}
	local reps: { Tool } = {}
	for _, t in ipairs(ordered) do
		local isShop, id = isShopStackTool(t)
		if isShop and id then
			if shopFirstRep[id] == nil then
				shopFirstRep[id] = t
			end
			if shopRowDone[id] then
				continue
			end
			shopRowDone[id] = true
			table.insert(reps, shopFirstRep[id])
		else
			table.insert(reps, t)
		end
	end
	return reps
end

local function buildEntryForRep(rep: Tool, allInstances: { Tool }): SlotEntry
	local isShop, id = isShopStackTool(rep)
	if isShop and id then
		local sum = 0
		for _, u in ipairs(allInstances) do
			local is2, id2 = isShopStackTool(u)
			if is2 and id2 == id then
				sum += stackCountForTool(u)
			end
		end
		return {
			tool = rep,
			stackDisplay = sum,
			showStackBadge = sum > 1,
		}
	end
	return {
		tool = rep,
		stackDisplay = 1,
		showStackBadge = false,
	}
end

local function clearToolBySlotAssignments()
	for i = 1, MAX_HOTBAR_SLOTS do
		toolBySlot[i] = nil
	end
end

local function findLowestEmptySlotIndex(): number?
	for i = 1, MAX_HOTBAR_SLOTS do
		local t = toolBySlot[i]
		if t == nil then
			return i
		end
	end
	return nil
end

type SlotRow = {
	slotIndex: number,
	entry: SlotEntry,
}

--- Align with Roblox `BackpackScript`: keep `tool→slot` on reparent; clear on true removal; new tools → lowest empty index.
local function reconcileRobloxToolbarSlotsAndBuildRows(player: Player): { SlotRow }
	local desiredReps = computeDesiredRepsDiscoveryOrder(player)
	local inDesired: { [Tool]: boolean } = {}
	for _, t in ipairs(desiredReps) do
		if t.Parent ~= nil then
			inDesired[t] = true
		end
	end

	for i = 1, MAX_HOTBAR_SLOTS do
		local t = toolBySlot[i]
		if t ~= nil and (t.Parent == nil or inDesired[t] ~= true) then
			toolBySlot[i] = nil
		end
	end

	local assigned: { [Tool]: boolean } = {}
	for i = 1, MAX_HOTBAR_SLOTS do
		local t = toolBySlot[i]
		if t and inDesired[t] == true then
			assigned[t] = true
		end
	end

	for _, t in ipairs(desiredReps) do
		if t.Parent == nil then
			continue
		end
		if assigned[t] == true then
			continue
		end
		local j = findLowestEmptySlotIndex()
		if j then
			toolBySlot[j] = t
			assigned[t] = true
		end
	end

	local allInstances = gatherToolsBackpackThenCharacter(player)
	local rows: { SlotRow } = {}
	for i = 1, MAX_HOTBAR_SLOTS do
		local t = toolBySlot[i]
		if t and t.Parent ~= nil and inDesired[t] == true then
			table.insert(rows, {
				slotIndex = i,
				entry = buildEntryForRep(t, allInstances),
			})
		end
	end
	return rows
end

local function hotkeyTextForIndex(index: number): string
	if index <= 0 or index > 10 then
		return ""
	end
	if index <= 9 then
		return tostring(index)
	end
	return "0"
end

local function findEquipStroke(root: GuiObject): UIStroke?
	local named = root:FindFirstChild("EquipStroke")
	if named and named:IsA("UIStroke") then
		return named
	end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("UIStroke") then
			return d
		end
	end
	return nil
end

local function clearToolAttrConns()
	for _, c in ipairs(toolAttrConns) do
		c:Disconnect()
	end
	table.clear(toolAttrConns)
end

local function clearStrip(strip: Frame)
	for _, ch in ipairs(strip:GetChildren()) do
		if string.match(ch.Name, "^HotbarSlot_%d+$") then
			ch:Destroy()
		end
	end
	table.clear(slotToTool)
	table.clear(slotToStroke)
end

local function updateEquippedHighlight(character: Model?)
	local equipped = getEquippedTool(character)
	for slot, tool in pairs(slotToTool) do
		local stroke = slotToStroke[slot]
		if stroke then
			stroke.Enabled = equipped ~= nil and equipped == tool
		end
	end
end

local function rebuild(player: Player)
	local strip = hotbarStrip
	local template = slotTemplate
	if not strip or not template then
		return
	end

	clearToolAttrConns()
	clearStrip(strip)

	local rows = reconcileRobloxToolbarSlotsAndBuildRows(player)
	local char = player.Character
	local sidePx = computeSlotSidePx(strip)
	local gapPx = gapBetweenSlotsPx(strip)
	local clones: { GuiObject } = {}

	for _, row in ipairs(rows) do
		local slotIndex = row.slotIndex
		local entry = row.entry
		local clone = template:Clone()
		clone.Visible = true
		clone.Name = "HotbarSlot_" .. tostring(slotIndex)
		clone.Parent = strip
		clone.Size = UDim2.fromOffset(sidePx, sidePx)
		table.insert(clones, clone)
		if strip.AbsoluteSize.Y < 6 or strip.AbsoluteSize.X < 6 then
			task.defer(function()
				if clone.Parent == strip then
					local s2 = computeSlotSidePx(strip)
					clone.Size = UDim2.fromOffset(s2, s2)
					layoutCenteredSlots(strip, collectSlotClonesSorted(strip), gapBetweenSlotsPx(strip), s2)
				end
			end)
		end

		local icon = clone:FindFirstChild("Icon")
		local hasTexture = false
		if icon and icon:IsA("ImageLabel") then
			local tid = entry.tool.TextureId
			if typeof(tid) == "string" and tid ~= "" then
				icon.Image = tid
				hasTexture = true
				icon.ImageTransparency = 0
			else
				icon.Image = ""
				icon.ImageTransparency = 1
			end
		end
		if not hasTexture then
			-- Shop tools often have no `TextureId`; show name on the clone (not StarterGui authoring).
			local stub = Instance.new("TextLabel")
			stub.Name = "ToolNameStub"
			stub.BackgroundTransparency = 1
			stub.Font = Enum.Font.GothamMedium
			stub.TextColor3 = Color3.fromRGB(235, 235, 240)
			stub.TextScaled = true
			stub.TextWrapped = true
			stub.Text = entry.tool.Name
			stub.Size = UDim2.fromScale(0.88, 0.55)
			stub.Position = UDim2.fromScale(0.5, 0.52)
			stub.AnchorPoint = Vector2.new(0.5, 0.5)
			stub.ZIndex = (icon and icon.ZIndex or 0) + 1
			local tsc = Instance.new("UITextSizeConstraint")
			tsc.MaxTextSize = 14
			tsc.MinTextSize = 8
			tsc.Parent = stub
			stub.Parent = clone
		end

		local hotkey = clone:FindFirstChild("HotkeyLabel")
		if hotkey and hotkey:IsA("TextLabel") then
			hotkey.Text = hotkeyTextForIndex(slotIndex)
		end

		local badge = clone:FindFirstChild("StackBadge")
		if badge and badge:IsA("TextLabel") then
			if entry.showStackBadge then
				badge.Visible = true
				badge.Text = tostring(entry.stackDisplay)
			else
				badge.Visible = false
				badge.Text = ""
			end
		end

		local hit = clone:FindFirstChild("Hit")
		local clickTarget: GuiButton? = nil
		if hit and hit:IsA("ImageButton") then
			clickTarget = hit
		elseif clone:IsA("GuiButton") then
			clickTarget = clone
		end

		if clickTarget then
			clickTarget.MouseButton1Click:Connect(function()
				local t = slotToTool[clone]
				if not t or t.Parent == nil then
					return
				end
				local char = player.Character
				local hum = char and char:FindFirstChildOfClass("Humanoid")
				if not hum then
					return
				end
				if getEquippedTool(char) == t then
					return
				end
				pcall(function()
					hum:EquipTool(t)
				end)
				updateEquippedHighlight(char)
			end)
		end

		local stroke = findEquipStroke(clone)
		if stroke then
			stroke.Enabled = false
		end
		slotToTool[clone] = entry.tool
		if stroke then
			slotToStroke[clone] = stroke
		end

		table.insert(toolAttrConns, entry.tool:GetAttributeChangedSignal(STACK_ATTR):Connect(function()
			refreshToken += 1
			local tok = refreshToken
			task.defer(function()
				if tok ~= refreshToken then
					return
				end
				rebuild(player)
				updateEquippedHighlight(player.Character)
			end)
		end))
	end

	layoutCenteredSlots(strip, clones, gapPx, sidePx)
	task.defer(function()
		if hotbarStrip == strip then
			local s2 = computeSlotSidePx(strip)
			for _, cl in ipairs(clones) do
				if cl.Parent == strip then
					cl.Size = UDim2.fromOffset(s2, s2)
				end
			end
			layoutCenteredSlots(strip, collectSlotClonesSorted(strip), gapBetweenSlotsPx(strip), s2)
		end
	end)

	updateEquippedHighlight(char)
end

local function scheduleFullRebuild(player: Player)
	refreshToken += 1
	local tok = refreshToken
	task.defer(function()
		if tok ~= refreshToken then
			return
		end
		rebuild(player)
	end)
end

local function equipSlotIndex(player: Player, index: number)
	local strip = hotbarStrip
	if not strip then
		return
	end
	local slot = strip:FindFirstChild("HotbarSlot_" .. tostring(index))
	if not (slot and slot:IsA("GuiObject")) then
		return
	end
	local tool = slotToTool[slot]
	if not tool or tool.Parent == nil then
		return
	end
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum then
		return
	end
	if getEquippedTool(char) == tool then
		return
	end
	pcall(function()
		hum:EquipTool(tool)
	end)
	updateEquippedHighlight(char)
end

local KEY_TO_INDEX: { [Enum.KeyCode]: number } = {
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
	[Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four] = 4,
	[Enum.KeyCode.Five] = 5,
	[Enum.KeyCode.Six] = 6,
	[Enum.KeyCode.Seven] = 7,
	[Enum.KeyCode.Eight] = 8,
	[Enum.KeyCode.Nine] = 9,
	[Enum.KeyCode.Zero] = 10,
}

local function disconnectList(list: { RBXScriptConnection })
	for _, c in ipairs(list) do
		c:Disconnect()
	end
	table.clear(list)
end

local function wireBackpackOnce(player: Player, bp: Backpack)
	disconnectList(backpackConns)
	table.insert(backpackConns, bp.ChildAdded:Connect(function(child)
		if child:IsA("Tool") then
			scheduleFullRebuild(player)
		end
	end))
	table.insert(backpackConns, bp.ChildRemoved:Connect(function(child)
		if child:IsA("Tool") then
			scheduleFullRebuild(player)
		end
	end))
end

local function wireCharacterTools(player: Player, character: Model)
	disconnectList(characterConns)
	table.insert(characterConns, character.ChildAdded:Connect(function(ch)
		if ch:IsA("Tool") then
			scheduleFullRebuild(player)
			updateEquippedHighlight(character)
		end
	end))
	table.insert(characterConns, character.ChildRemoved:Connect(function(ch)
		if ch:IsA("Tool") then
			scheduleFullRebuild(player)
			updateEquippedHighlight(character)
		end
	end))
end

function EquipmentHotbarController.start(playerGui: PlayerGui): boolean
	if started then
		return true
	end
	if bindWait then
		local deadline = os.clock() + 30
		while bindWait and not started and os.clock() < deadline do
			task.wait(0.05)
		end
		return started
	end
	bindWait = true

	local player = Players.LocalPlayer

	for _ = 1, 120 do
		local strip, template = resolveHotbar(playerGui)
		if strip and template then
			local innerOk, innerErr = pcall(function()
				hotbarStrip = strip
				slotTemplate = template

				local bp = player:WaitForChild("Backpack")
				if bp:IsA("Backpack") then
					wireBackpackOnce(player, bp)
				end

				local function onCharacterAdded(character: Model)
					clearToolBySlotAssignments()
					wireCharacterTools(player, character)
					scheduleFullRebuild(player)
					updateEquippedHighlight(character)
				end

				if player.Character then
					onCharacterAdded(player.Character)
				end
				player.CharacterAdded:Connect(onCharacterAdded)

				UserInputService.InputBegan:Connect(function(input, gameProcessed)
					if gameProcessed then
						return
					end
					if UserInputService:GetFocusedTextBox() ~= nil then
						return
					end
					if input.UserInputType ~= Enum.UserInputType.Keyboard then
						return
					end
					local idx = KEY_TO_INDEX[input.KeyCode]
					if idx then
						equipSlotIndex(player, idx)
					end
				end)

				rebuild(player)
				if stripAbsConn then
					stripAbsConn:Disconnect()
					stripAbsConn = nil
				end
				stripAbsConn = strip:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
					if hotbarStrip then
						relayoutExistingSlots(hotbarStrip)
					end
				end)
				started = true
			end)
			bindWait = false
			if innerOk then
				return true
			end
			warn("[Client] EquipmentHotbarController: bind failed: ", innerErr)
			return false
		end
		task.wait(0.5)
	end

	bindWait = false
	warn(
		"[Client] EquipmentHotbarController: timed out waiting for HUD → Canvas → EquipmentHotbar (SlotStrip + SlotTemplate). "
			.. "Ensure names match docs; slots only fill during Play (LocalScript)."
	)
	return false
end

--- Call when `PlayerGui.HUD` is cloned in late (e.g. after first defer). Safe to call multiple times.
function EquipmentHotbarController.tryStart(playerGui: PlayerGui): boolean
	return EquipmentHotbarController.start(playerGui)
end

return EquipmentHotbarController
