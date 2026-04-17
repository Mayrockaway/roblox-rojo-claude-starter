--!strict
-- Settings modal (`StarterGui.Settings` or `SettingsPanelGui` → `PlayerGui`). Shell + close authored in Studio; `ModalPanelShell` wires close **`GuiButton`**s.
-- Studio layout (see **`Container` → `1` → `List` → `Tab`×2**): row chrome **`Active` / `Inactive`**; hit target is **`Toggle-Container.Toggle`** (**`Frame`**, not **`GuiButton`**). **`Open`** bumps **`DisplayOrder`** above FTUE.

local UserInputService = game:GetService("UserInputService")

--- Verbose click tracing + wiring logs. Set **`true`** to trace hit targets (noisy).
local DEBUG_SETTINGS_CLICKS = false

local ClientAudioPreferences = require(script.Parent.Parent.Parent:WaitForChild("ClientAudioPreferences"))
local HudPanelBase = require(script.Parent.Parent.HudPanelBase)
local HudPanelTypes = require(script.Parent.Parent.HudPanelTypes)

--- Primary `ScreenGui` name; `SettingsPanelGui` is accepted as a Studio alias.
local SCREEN_NAME = "Settings"
local SCREEN_NAME_ALIAS = "SettingsPanelGui"

local wiredScreens: { [ScreenGui]: boolean } = {}
local clickDebugConnection: RBXScriptConnection? = nil

local function logSettings(msg: string)
	if DEBUG_SETTINGS_CLICKS then
		print("[SettingsPanel]", msg)
	end
end

local function formatGuiHitLine(go: GuiObject, index: number): string
	return string.format(
		"[%d] %s %q | Visible=%s Active=%s ZIndex=%d LayoutOrder=%d",
		index,
		go.ClassName,
		go.Name,
		tostring(go.Visible),
		tostring(go.Active),
		go.ZIndex,
		go.LayoutOrder
	)
end

--- While this **`ScreenGui`** is **`Enabled`**, log primary clicks: screen position, **`gameProcessed`**, and top **`GetGuiObjectsAtPosition`** stack (what actually received the hit test).
local function attachSettingsClickDebug(screen: ScreenGui)
	if not DEBUG_SETTINGS_CLICKS then
		return
	end
	if clickDebugConnection then
		return
	end
	local playerGui = screen.Parent
	if not (playerGui and playerGui:IsA("PlayerGui")) then
		return
	end

	clickDebugConnection = UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if not screen.Enabled then
			return
		end
		if
			input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end
		local pos: Vector2
		if input.UserInputType == Enum.UserInputType.Touch then
			pos = Vector2.new(input.Position.X, input.Position.Y)
		else
			pos = UserInputService:GetMouseLocation()
		end
		local objs = playerGui:GetGuiObjectsAtPosition(pos.X, pos.Y)
		local lines = {
			string.format(
				"[ClickDebug] pos=(%.0f,%.0f) gameProcessed=%s UserInputType=%s",
				pos.X,
				pos.Y,
				tostring(gameProcessed),
				input.UserInputType.Name
			),
		}
		if #objs == 0 then
			table.insert(lines, "[ClickDebug] GetGuiObjectsAtPosition: (empty — click did not hit any PlayerGui GuiObject)")
		else
			for i = 1, math.min(10, #objs) do
				local o = objs[i]
				if o:IsA("GuiObject") then
					table.insert(lines, "[ClickDebug] " .. formatGuiHitLine(o :: GuiObject, i))
					local inSettings = (o :: Instance):IsDescendantOf(screen)
					if i == 1 then
						table.insert(
							lines,
							string.format(
								"[ClickDebug] top object under this Settings ScreenGui=%s path=%s",
								tostring(inSettings),
								(o :: Instance):GetFullName()
							)
						)
					end
				end
			end
		end
		print(table.concat(lines, "\n"))
	end)
end

local function isLikelyCloseButton(name: string): boolean
	local ln = string.lower(name)
	return ln == "close"
		or ln == "closebutton"
		or string.sub(ln, 1, 6) == "close"
		or ln == "x"
		or ln == "exit"
		or ln == "dismiss"
end

--- `Active` / `Inactive` toggle chrome (case-insensitive; shallow children first).
--- Inactive side may be named **`Inactive`**, **`Off`**, **`Disabled`**, etc.
local function findActiveInactiveFrames(tab: GuiObject): (GuiObject?, GuiObject?)
	local activeF: GuiObject? = nil
	local inactiveF: GuiObject? = nil
	local function inactiveName(ln: string): boolean
		return ln == "inactive"
			or ln == "off"
			or ln == "disabled"
			or ln == "inactivestate"
			or ln == "unchecked"
	end
	for _, ch in ipairs(tab:GetChildren()) do
		if ch:IsA("GuiObject") then
			local ln = string.lower(ch.Name)
			if ln == "active" then
				activeF = ch
			elseif inactiveName(ln) then
				inactiveF = ch
			end
		end
	end
	if not activeF or not inactiveF then
		for _, d in ipairs(tab:GetDescendants()) do
			if d:IsA("GuiObject") then
				local ln = string.lower(d.Name)
				if not activeF and ln == "active" then
					activeF = d
				elseif not inactiveF and inactiveName(ln) then
					inactiveF = d
				end
			end
		end
	end
	return activeF, inactiveF
end

--- Row-level **`Active`** / **`Inactive`** chrome on a **`Tab`** (direct children first — avoids nested knob frames named `Active`).
local function findRowChromeActiveInactive(tab: GuiObject): (GuiObject?, GuiObject?)
	local activeF: GuiObject? = nil
	local inactiveF: GuiObject? = nil
	for _, ch in ipairs(tab:GetChildren()) do
		if ch:IsA("GuiObject") then
			local ln = string.lower(ch.Name)
			if ln == "active" then
				activeF = ch
			elseif ln == "inactive" or ln == "off" or ln == "disabled" or ln == "inactivestate" or ln == "unchecked" then
				inactiveF = ch
			end
		end
	end
	if activeF and inactiveF then
		return activeF, inactiveF
	end
	return findActiveInactiveFrames(tab)
end

local function hasNonCloseGuiButton(tab: GuiObject): boolean
	for _, d in ipairs(tab:GetDescendants()) do
		if d:IsA("GuiButton") and not isLikelyCloseButton(d.Name) then
			return true
		end
	end
	return false
end

--- Studio: **`Toggle-Container` → `Frame` `Toggle`** (not a **`GuiButton`**).
local function hasStudioFrameToggle(tab: GuiObject): boolean
	local tc = tab:FindFirstChild("Toggle-Container", true)
	if not (tc and tc:IsA("GuiObject")) then
		return false
	end
	local tgl = tc:FindFirstChild("Toggle")
	return tgl ~= nil and tgl:IsA("GuiObject")
end

--- Row must have **`Active` + `Inactive`** chrome and either a **`GuiButton`** or the frame toggle pattern above.
local function rowHasTogglePattern(tab: GuiObject): boolean
	local a, b = findRowChromeActiveInactive(tab)
	if not (a and b) then
		return false
	end
	return hasNonCloseGuiButton(tab) or hasStudioFrameToggle(tab)
end

--- Clear **`Active`** on the whole row, then enable the chain from **`tab`** down to **`target`** so **`Frame`** toggles receive input.
local function passthroughTabForInputTarget(tab: GuiObject, target: GuiObject)
	for _, d in ipairs(tab:GetDescendants()) do
		if d:IsA("GuiObject") then
			d.Active = false
		end
	end
	local p: Instance? = target
	while p and p ~= tab.Parent do
		if p:IsA("GuiObject") then
			(p :: GuiObject).Active = true
		end
		if p == tab then
			break
		end
		p = p.Parent
	end
	if target:IsA("GuiButton") then
		(target :: GuiButton).Selectable = true
	end
end

local function resolveToggleButton(tab: GuiObject): GuiButton?
	local named = { "Hit", "Toggle", "Switch", "Track" }
	for _, nm in ipairs(named) do
		local inst = tab:FindFirstChild(nm, true)
		if inst and inst:IsA("GuiButton") and not isLikelyCloseButton(inst.Name) then
			return inst
		end
	end
	local candidates: { GuiButton } = {}
	for _, d in ipairs(tab:GetDescendants()) do
		if d:IsA("GuiButton") and not isLikelyCloseButton(d.Name) then
			table.insert(candidates, d)
		end
	end
	table.sort(candidates, function(a, b)
		if a.AbsoluteSize.Y ~= b.AbsoluteSize.Y then
			return a.AbsoluteSize.Y > b.AbsoluteSize.Y
		end
		return a.LayoutOrder < b.LayoutOrder
	end)
	return candidates[1]
end

--- Prefer **`GuiButton`**; else Studio **`Toggle-Container.Toggle`** (**`Frame`**).
local function resolveToggleInputTarget(tab: GuiObject): GuiObject?
	local gb = resolveToggleButton(tab)
	if gb then
		return gb
	end
	local tc = tab:FindFirstChild("Toggle-Container", true)
	if tc then
		local tgl = tc:FindFirstChild("Toggle")
		if tgl and tgl:IsA("GuiObject") then
			return tgl
		end
	end
	return nil
end

local function applyToggleVisual(activeF: GuiObject?, inactiveF: GuiObject?, enabled: boolean)
	if activeF then
		activeF.Visible = enabled
	end
	if inactiveF then
		inactiveF.Visible = not enabled
	end
end

local function findRowByLabelKeywords(screen: ScreenGui, keywords: { string }): GuiObject?
	for _, inst in ipairs(screen:GetDescendants()) do
		if not (inst:IsA("TextLabel") or inst:IsA("TextButton")) then
			continue
		end
		local text = string.lower((inst :: TextLabel | TextButton).Text)
		for _, kw in ipairs(keywords) do
			if string.find(text, string.lower(kw), 1, true) then
				local p: Instance? = inst
				for _ = 1, 16 do
					if not p or p == screen then
						break
					end
					if p:IsA("GuiObject") then
						local go = p :: GuiObject
						if rowHasTogglePattern(go) then
							return go
						end
					end
					p = p.Parent
				end
				break
			end
		end
	end
	return nil
end

local function gatherDirectToggleChildren(container: GuiObject): { GuiObject }
	local rows: { GuiObject } = {}
	for _, ch in ipairs(container:GetChildren()) do
		if ch:IsA("GuiObject") and rowHasTogglePattern(ch) then
			table.insert(rows, ch)
		end
	end
	table.sort(rows, function(a, b)
		local ya = a.AbsolutePosition.Y
		local yb = b.AbsolutePosition.Y
		if ya ~= yb then
			return ya < yb
		end
		return a.LayoutOrder < b.LayoutOrder
	end)
	return rows
end

local function findTwoRowsByContainerScan(screen: ScreenGui): (GuiObject?, GuiObject?)
	local roots: { GuiObject } = {}
	local canvas = screen:FindFirstChild("Canvas")
	if canvas and canvas:IsA("GuiObject") then
		table.insert(roots, canvas :: GuiObject)
	end
	table.insert(roots, screen :: GuiObject)

	for _, root in ipairs(roots) do
		local rows = gatherDirectToggleChildren(root)
		if #rows >= 2 then
			return rows[1], rows[2]
		end
		for _, ch in ipairs(root:GetChildren()) do
			if ch:IsA("GuiObject") then
				rows = gatherDirectToggleChildren(ch :: GuiObject)
				if #rows >= 2 then
					return rows[1], rows[2]
				end
			end
		end
	end
	return nil, nil
end

--- Innermost `GuiObject` subtrees with a full toggle pattern (drops outer containers like `Canvas` that also match).
local function findTwoMinimalToggleRoots(screen: ScreenGui): (GuiObject?, GuiObject?)
	local candidates: { GuiObject } = {}
	for _, d in ipairs(screen:GetDescendants()) do
		if d:IsA("GuiObject") and rowHasTogglePattern(d) then
			table.insert(candidates, d)
		end
	end
	local minimal: { GuiObject } = {}
	for _, d in ipairs(candidates) do
		local hasStrictDescendantCandidate = false
		for _, e in ipairs(candidates) do
			if d ~= e and e:IsDescendantOf(d) then
				hasStrictDescendantCandidate = true
				break
			end
		end
		if not hasStrictDescendantCandidate then
			table.insert(minimal, d)
		end
	end
	if #minimal < 2 then
		return nil, nil
	end
	table.sort(minimal, function(a, b)
		local ya = a.AbsolutePosition.Y
		local yb = b.AbsolutePosition.Y
		if ya ~= yb then
			return ya < yb
		end
		return a.LayoutOrder < b.LayoutOrder
	end)
	return minimal[1], minimal[2]
end

--- Canonical Studio path: **`Container` → `1` → `List` → `Tab` ×2** (Music / SFX rows).
local function findTwoTabRowsFromCanonicalPath(screen: ScreenGui): (GuiObject?, GuiObject?)
	local container = screen:FindFirstChild("Container", true)
	if not container then
		return nil, nil
	end
	local section = container:FindFirstChild("1")
	if not (section and section:IsA("GuiObject")) then
		return nil, nil
	end
	local list = section:FindFirstChild("List")
	if not (list and list:IsA("GuiObject")) then
		return nil, nil
	end
	local rows: { GuiObject } = {}
	for _, ch in ipairs(list:GetChildren()) do
		if ch:IsA("GuiObject") and string.lower(ch.Name) == "tab" and rowHasTogglePattern(ch) then
			table.insert(rows, ch)
		end
	end
	if #rows < 2 then
		return nil, nil
	end
	table.sort(rows, function(a, b)
		local ya = a.AbsolutePosition.Y
		local yb = b.AbsolutePosition.Y
		if ya ~= yb then
			return ya < yb
		end
		return a.LayoutOrder < b.LayoutOrder
	end)
	return rows[1], rows[2]
end

--- Fallback: first **`List`** in the tree whose children are toggle rows (**`Tab`**, **`1`**, …).
local function findTwoRowsFromList(screen: ScreenGui): (GuiObject?, GuiObject?)
	local list = screen:FindFirstChild("List", true)
	if not (list and list:IsA("GuiObject")) then
		return nil, nil
	end
	local rows: { GuiObject } = {}
	for _, ch in ipairs(list:GetChildren()) do
		if ch:IsA("GuiObject") and rowHasTogglePattern(ch) then
			table.insert(rows, ch)
		end
	end
	if #rows < 2 then
		return nil, nil
	end
	table.sort(rows, function(a, b)
		local na = tonumber(a.Name)
		local nb = tonumber(b.Name)
		if na and nb and na ~= nb then
			return na < nb
		end
		local ya = a.AbsolutePosition.Y
		local yb = b.AbsolutePosition.Y
		if ya ~= yb then
			return ya < yb
		end
		return a.LayoutOrder < b.LayoutOrder
	end)
	return rows[1], rows[2]
end

local function resolveMusicAndSfxRows(screen: ScreenGui): (GuiObject?, GuiObject?)
	local s1 = screen:FindFirstChild("Settings1", true)
	local s2 = screen:FindFirstChild("Settings2", true)
	local e1 = (s1 and s1:IsA("GuiObject")) and (s1 :: GuiObject) or nil
	local e2 = (s2 and s2:IsA("GuiObject")) and (s2 :: GuiObject) or nil
	if e1 and e2 and rowHasTogglePattern(e1) and rowHasTogglePattern(e2) then
		return e1, e2
	end

	local t1, t2 = findTwoTabRowsFromCanonicalPath(screen)
	if t1 and t2 then
		return t1, t2
	end

	local lr1, lr2 = findTwoRowsFromList(screen)
	if lr1 and lr2 then
		return lr1, lr2
	end

	local music = findRowByLabelKeywords(screen, { "music" })
	local sfx = findRowByLabelKeywords(screen, { "sfx", "sound effect", "effects" })
	if music and sfx and music ~= sfx then
		return music, sfx
	end

	local a, b = findTwoRowsByContainerScan(screen)
	if a and b then
		return a, b
	end

	return findTwoMinimalToggleRoots(screen)
end

local function wireToggleRow(tab: GuiObject, getEnabled: () -> boolean, setPreference: (boolean) -> ())
	local activeF, inactiveF = findRowChromeActiveInactive(tab)
	local target = resolveToggleInputTarget(tab)
	if not target then
		warn("[SettingsPanel] No toggle hit target (expect **`GuiButton`** or **`Toggle-Container.Toggle`** `Frame`) under", tab:GetFullName())
		return
	end
	passthroughTabForInputTarget(tab, target)

	logSettings(
		"Toggle row wired: row="
			.. tab:GetFullName()
			.. " | target="
			.. target:GetFullName()
			.. " | class="
			.. target.ClassName
	)

	applyToggleVisual(activeF, inactiveF, getEnabled())

	local function onPress()
		logSettings("TOGGLE HANDLER FIRED: " .. target:GetFullName())
		local on = not getEnabled()
		setPreference(on)
		applyToggleVisual(activeF, inactiveF, on)
	end

	if target:IsA("GuiButton") then
		(target :: GuiButton).Activated:Connect(onPress)
		if DEBUG_SETTINGS_CLICKS then
			(target :: GuiButton).MouseButton1Click:Connect(function()
				logSettings("MouseButton1Click on " .. target:GetFullName())
			end)
		end
	else
		target.InputBegan:Connect(function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				if DEBUG_SETTINGS_CLICKS then
					logSettings("InputBegan on Frame toggle " .. target:GetFullName())
				end
				onPress()
			end
		end)
	end
end

local function wireSettingsToggles(screen: ScreenGui)
	if wiredScreens[screen] then
		return
	end
	wiredScreens[screen] = true

	local musicRow, sfxRow = resolveMusicAndSfxRows(screen)
	logSettings("Resolved rows: musicRow=" .. (musicRow and musicRow:GetFullName() or "nil") .. " | sfxRow=" .. (sfxRow and sfxRow:GetFullName() or "nil"))
	if not musicRow then
		warn("[SettingsPanel] Could not find music toggle row (expect `Container.1.List.Tab` or `Settings1` with Active/Inactive + Toggle-Container.Toggle or GuiButton).")
	end
	if not sfxRow then
		warn("[SettingsPanel] Could not find SFX toggle row (second `Tab` under `List`, or `Settings2`).")
	end

	if musicRow then
		wireToggleRow(musicRow, function()
			return ClientAudioPreferences.isMusicEnabled()
		end, function(on: boolean)
			ClientAudioPreferences.setMusicEnabled(on)
		end)
	end

	if sfxRow then
		wireToggleRow(sfxRow, function()
			return ClientAudioPreferences.isSfxEnabled()
		end, function(on: boolean)
			ClientAudioPreferences.setSfxEnabled(on)
		end)
	end

	attachSettingsClickDebug(screen)
	logSettings("Click debug listener attached (fires while ScreenGui.Enabled; see [ClickDebug] lines). ScreenGui=" .. screen:GetFullName())
end

local SettingsPanel = {}

--- **`FTUEDialogueGui`** often uses a higher **`DisplayOrder`** than modals, so it receives all clicks. Bump Settings above FTUE while open.
local function wrapControllerForInputStacking(playerGui: PlayerGui, ctrl: HudPanelTypes.HudPanelController)
	local sg = ctrl.ScreenGui
	local savedDisplayOrder = sg.DisplayOrder
	local innerOpen = ctrl.Open
	local innerClose = ctrl.Close
	local function findFtueScreen(): ScreenGui?
		for _, n in ipairs({ "FTUEDialogueGui", "FtueDialogueGui" }) do
			local g = playerGui:FindFirstChild(n)
			if g and g:IsA("ScreenGui") then
				return g
			end
		end
		return nil
	end
	ctrl.Open = function()
		innerOpen()
		local ftue = findFtueScreen()
		if ftue then
			sg.DisplayOrder = math.max(ftue.DisplayOrder + 250, savedDisplayOrder, 500)
			logSettings(string.format("Stacking: Settings DisplayOrder=%d (FTUE %q=%d)", sg.DisplayOrder, ftue.Name, ftue.DisplayOrder))
		else
			sg.DisplayOrder = math.max(savedDisplayOrder, 2000)
			logSettings(string.format("Stacking: Settings DisplayOrder=%d (no FTUE ScreenGui)", sg.DisplayOrder))
		end
	end
	ctrl.Close = function()
		innerClose()
		sg.DisplayOrder = savedDisplayOrder
	end
end

function SettingsPanel.bind(playerGui: PlayerGui): HudPanelTypes.HudPanelController?
	local ctrl = HudPanelBase.tryBind(playerGui, SCREEN_NAME)
	if not ctrl then
		ctrl = HudPanelBase.tryBind(playerGui, SCREEN_NAME_ALIAS)
	end
	if ctrl and ctrl.ScreenGui then
		wrapControllerForInputStacking(playerGui, ctrl)
		-- Layout may not have run yet; defer toggle wiring so `AbsolutePosition` / sizes are stable for discovery.
		local sg = ctrl.ScreenGui
		task.defer(function()
			wireSettingsToggles(sg)
		end)
	end
	return ctrl
end

function SettingsPanel.screenName(): string
	return SCREEN_NAME
end

return SettingsPanel
