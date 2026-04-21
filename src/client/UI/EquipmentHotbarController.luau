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
local EquipmentCatalog = require(Shared:WaitForChild("Config"):WaitForChild("EquipmentCatalog"))

local STACK_ATTR = Constants.EquipmentStackCountAttribute

--- Resolve the player-facing label for a tool slot. Prefer the catalog
--- `displayName` (e.g. "Sundae Driller") over the internal `Tool.Name`
--- (e.g. "Drill_T4") so flavor names show up in the hotbar without
--- renaming the Tool instances that server / animation code looks up.
--- Falls back to `Tool.Name` when the tool has no `EquipmentItemId`
--- attribute or the id isn't in the catalog (hammer, future tools).
local function resolveDisplayName(tool: Tool): string
	local id = tool:GetAttribute("EquipmentItemId")
	if typeof(id) == "string" and id ~= "" then
		local row = EquipmentCatalog.getRowById(id)
		if row and typeof(row.displayName) == "string" and row.displayName ~= "" then
			return row.displayName
		end
	end
	return tool.Name
end

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
local playerBackpackGuardConn: RBXScriptConnection? = nil
local characterConns: { RBXScriptConnection } = {}
local hotbarStrip: Frame? = nil
local slotTemplate: GuiObject? = nil
local slotToTool: { [GuiObject]: Tool } = {}
local slotToStroke: { [GuiObject]: UIStroke } = {}
local stripAbsConn: RBXScriptConnection? = nil
local characterAddedConn: RBXScriptConnection? = nil
local keyboardConn: RBXScriptConnection? = nil

--- Roblox-style hotbar: `toolBySlot[i]` is the `Tool` bound to keys `1..9` and `0` (slot 10). Nil = empty.
local MAX_HOTBAR_SLOTS = 10
local toolBySlot: { Tool? } = {}

--- Forward declared so `rebuild` (defined further down) can wire each slot's
--- `Activated` handler to the same equip / toggle helper that the keyboard
--- path uses. Without this forward declaration Luau parses the reference
--- inside `rebuild`'s click closure as a **global** (because the `local
--- function equipOrToggleHotbarTool` declaration is lexically below `rebuild`),
--- which resolves to `nil` at runtime — every left click / tap on a slot then
--- silently calls `nil` and the tool never equips even though the strip looks
--- correct (the `1`–`9` / `0` keyboard handler still works because it lives
--- after the local declaration). Keep this **above** every function that wants
--- to invoke the helper (currently `rebuild` and `equipSlotIndex`).
local equipOrToggleHotbarTool: (Player, Tool) -> ()

local function prefersTouchHotbar(): boolean
	return UserInputService.TouchEnabled
end

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
	hotbar.ClipsDescendants = false
	strip.ClipsDescendants = false
	-- Slots are positioned in Lua (centered row). `UIListLayout` fights manual `Position` on clones.
	local list = strip:FindFirstChildOfClass("UIListLayout")
	if list then
		list:Destroy()
	end
	return strip :: Frame, template :: GuiObject
end

local function computeSlotSidePx(strip: Frame): number
	local h = strip.AbsoluteSize.Y
	if prefersTouchHotbar() then
		h = math.max(h, 82)
	end
	if h < 6 then
		return if prefersTouchHotbar() then 72 else 56
	end
	local inset = math.max(4, math.floor(h * 0.08))
	if prefersTouchHotbar() then
		return math.clamp(h - inset, 64, 132)
	end
	return math.clamp(h - inset, 40, 120)
end

local function gapBetweenSlotsPx(strip: Frame): number
	if prefersTouchHotbar() then
		return math.max(8, math.floor(math.max(strip.AbsoluteSize.Y, 82) * 0.12))
	end
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

	local unassigned: { Tool } = {}
	for _, t in ipairs(desiredReps) do
		if t.Parent ~= nil and assigned[t] ~= true then
			table.insert(unassigned, t)
		end
	end
	if #unassigned > 0 then
		local sample = {}
		for i = 1, math.min(5, #unassigned) do
			local t = unassigned[i]
			local id = t:GetAttribute("EquipmentItemId")
			table.insert(
				sample,
				string.format("%s (itemId=%s)", t.Name, typeof(id) == "string" and id or "?")
			)
		end
		warn(
			string.format(
				"[EquipmentHotbar] %d tool row(s) exceed max %d slots — extra tools stay in Backpack only. Examples: %s",
				#unassigned,
				MAX_HOTBAR_SLOTS,
				table.concat(sample, "; ")
			)
		)
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
		if icon and icon:IsA("ImageLabel") then
			-- Pin canonical icon geometry: icon fills the entire slot edge to
			-- edge. ScaleType=Fit preserves aspect ratio so the rbxthumb is
			-- not stretched. Defensive against manual Studio edits to the
			-- template (sizes/positions get re-asserted on every clone).
			icon.Size = UDim2.fromScale(1, 1)
			icon.Position = UDim2.fromScale(0.5, 0.5)
			icon.AnchorPoint = Vector2.new(0.5, 0.5)
			icon.ScaleType = Enum.ScaleType.Fit
			icon.BackgroundTransparency = 1
			local tid = entry.tool.TextureId
			local resolved: string? = nil
			if typeof(tid) == "string" and tid ~= "" then
				if tid:match("^rbxthumb://") or tid:match("^rbxasset://") or tid:match("^http") then
					resolved = tid
				else
					local id = tid:match("rbxassetid://(%d+)") or tid:match("^(%d+)$")
					resolved = id and string.format("rbxthumb://type=Asset&id=%s&w=150&h=150", id) or tid
				end
			end
			if resolved then
				icon.Image = resolved
				icon.ImageTransparency = 0
			else
				icon.Image = ""
				icon.ImageTransparency = 1
			end
		end

		-- Label sits INSIDE the slot at the bottom, text-only (no background
		-- strip). Slot clips descendants so the text stays inside the slot's
		-- rounded corners. TextStroke gives legibility over any icon.
		clone.ClipsDescendants = true
		local nameLabel = clone:FindFirstChild("NameLabel")
		if nameLabel and nameLabel:IsA("TextLabel") then
			nameLabel.AnchorPoint = Vector2.new(0.5, 1)
			nameLabel.Position = UDim2.fromScale(0.5, 1)
			nameLabel.Size = UDim2.fromScale(1, 0.22)
			nameLabel.BackgroundTransparency = 1
			nameLabel.TextScaled = true
			nameLabel.TextColor3 = Color3.new(1, 1, 1)
			-- ZIndex 3: above Icon (1) so the text reads on top of it, below
			-- Hit (5) so taps on the text area still equip the slot.
			nameLabel.ZIndex = 3
			nameLabel.Text = resolveDisplayName(entry.tool)
			nameLabel.Visible = true
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
			-- Defensive: `Activated` fires for **mouse click + touch tap +
			-- gamepad A** on every `GuiButton`, but only when the button is
			-- `Active = true`. Authored `Hit` button already ships `Active =
			-- true`, but force it here so a future Studio re-author (or a clone
			-- whose Hit button got toggled inactive) still equips on tap.
			clickTarget.Active = true
			clickTarget.Selectable = true
			clickTarget.AutoButtonColor = false
			clickTarget.Activated:Connect(function()
				local t = slotToTool[clone]
				if not t then
					return
				end
				equipOrToggleHotbarTool(player, t)
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

--- Same slot / key again while that tool is equipped → unequip (default
--- backpack-style toggle). Bound to the forward declaration near the top of
--- this module so `rebuild`'s click closure can resolve it; do **not**
--- redeclare with `local function` here or the upvalue stays `nil`.
function equipOrToggleHotbarTool(player: Player, tool: Tool)
	if tool.Parent == nil then
		return
	end
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum then
		return
	end
	if getEquippedTool(char) == tool then
		pcall(function()
			hum:UnequipTools()
		end)
	else
		pcall(function()
			hum:EquipTool(tool)
		end)
	end
	updateEquippedHighlight(char)
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
	if not tool then
		return
	end
	equipOrToggleHotbarTool(player, tool)
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

--- After `HUD` is recreated (ResetOnSpawn, late replication, teleport flows), strip refs go stale but `started`
--- stayed true — `tryStart` must tear down and rebind instead of returning early.
local function disconnectAndResetHotbarBinding()
	refreshToken += 1
	disconnectList(backpackConns)
	if playerBackpackGuardConn then
		playerBackpackGuardConn:Disconnect()
		playerBackpackGuardConn = nil
	end
	disconnectList(characterConns)
	clearToolAttrConns()
	if stripAbsConn then
		stripAbsConn:Disconnect()
		stripAbsConn = nil
	end
	if characterAddedConn then
		characterAddedConn:Disconnect()
		characterAddedConn = nil
	end
	if keyboardConn then
		keyboardConn:Disconnect()
		keyboardConn = nil
	end
	local strip = hotbarStrip
	if strip and strip.Parent then
		pcall(function()
			clearStrip(strip)
		end)
	end
	hotbarStrip = nil
	slotTemplate = nil
	clearToolBySlotAssignments()
	table.clear(slotToTool)
	table.clear(slotToStroke)
	started = false
end

local function isHotbarBindingAliveForPlayerGui(playerGui: PlayerGui): boolean
	if not started or not hotbarStrip or not slotTemplate then
		return false
	end
	if hotbarStrip.Parent == nil or slotTemplate.Parent == nil then
		return false
	end
	if not hotbarStrip:IsDescendantOf(playerGui) or not slotTemplate:IsDescendantOf(playerGui) then
		return false
	end
	return true
end

local function wireBackpackOnce(player: Player, bp: Backpack)
	disconnectList(backpackConns)
	local function onBackpackToolChanged()
		scheduleFullRebuild(player)
	end
	local function hookBackpackTool(t: Tool)
		table.insert(backpackConns, t:GetAttributeChangedSignal(STACK_ATTR):Connect(onBackpackToolChanged))
		table.insert(backpackConns, t:GetPropertyChangedSignal("Parent"):Connect(onBackpackToolChanged))
	end
	for _, ch in ipairs(bp:GetChildren()) do
		if ch:IsA("Tool") then
			hookBackpackTool(ch :: Tool)
		end
	end
	table.insert(backpackConns, bp.ChildAdded:Connect(function(child)
		if child:IsA("Tool") then
			hookBackpackTool(child :: Tool)
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
		if isHotbarBindingAliveForPlayerGui(playerGui) then
			return true
		end
		disconnectAndResetHotbarBinding()
	end
	if bindWait then
		local deadline = os.clock() + 30
		while bindWait and not started and os.clock() < deadline do
			task.wait(0.05)
		end
		if started then
			return true
		end
		--- Another `start()` was mid-flight (or timed out waiting); continue so this caller can bind.
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
				if playerBackpackGuardConn then
					playerBackpackGuardConn:Disconnect()
					playerBackpackGuardConn = nil
				end
				playerBackpackGuardConn = player.ChildAdded:Connect(function(ch)
					if ch:IsA("Backpack") then
						wireBackpackOnce(player, ch :: Backpack)
						scheduleFullRebuild(player)
					end
				end)

				local function onCharacterAdded(character: Model)
					clearToolBySlotAssignments()
					wireCharacterTools(player, character)
					scheduleFullRebuild(player)
					updateEquippedHighlight(character)
					--- After death/respawn, tools + GUI layout can replicate a few frames late — refresh slots.
					task.delay(0.12, function()
						if player.Character == character and hotbarStrip then
							scheduleFullRebuild(player)
						end
					end)
					task.delay(0.4, function()
						if player.Character == character and hotbarStrip then
							scheduleFullRebuild(player)
						end
					end)
				end

				if player.Character then
					onCharacterAdded(player.Character)
				end
				if characterAddedConn then
					characterAddedConn:Disconnect()
				end
				characterAddedConn = player.CharacterAdded:Connect(onCharacterAdded)

				if keyboardConn then
					keyboardConn:Disconnect()
				end
				keyboardConn = UserInputService.InputBegan:Connect(function(input, gameProcessed)
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
				task.defer(function()
					scheduleFullRebuild(player)
				end)

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

--- After shop purchase / stack merge (no **`ChildAdded`**), or replication lag — safe to call multiple times.
function EquipmentHotbarController.requestRebuild()
	local p = Players.LocalPlayer
	if not p then
		return
	end
	scheduleFullRebuild(p)
	task.defer(function()
		scheduleFullRebuild(p)
	end)
	task.delay(0.15, function()
		scheduleFullRebuild(p)
	end)
end

return EquipmentHotbarController
