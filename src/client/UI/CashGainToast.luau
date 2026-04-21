--!strict
-- Small green status pop-up shown above `HUD.Canvas.CashStrip` whenever the
-- local player gains cash. Authored shell: `StarterGui.HUD.Canvas.CashStrip
-- .CashGainToastTemplate` (Frame, `Visible = false`) — see
-- `docs/features/oil-gameplay-hud/CANONICAL_STUDIO_LAYOUT.md`.
--
-- Behavior:
--   * `notifyGain(playerGui, amount)` clones the template, sets the label to
--     `"+$X,XXX"`, makes it `Visible = true`, then **fades out + lifts** over
--     ~`FADE_SECONDS` and destroys the clone.
--   * Concurrent gains stack: each newer toast is offset upward by an
--     additional `STACK_LIFT_SCALE` so a rapid burst (e.g. selling several
--     barrels in one click) does not overwrite a previous one.
--   * All sizing uses **scale** of `CashStrip` (per `ui-scaling-responsive.mdc`)
--     so the toast follows the strip's responsive layout on phone/desktop.

local TweenService = game:GetService("TweenService")

local CashGainToast = {}

local TEMPLATE_NAME = "CashGainToastTemplate"
local CLONE_NAME = "CashGainToastClone"
local LABEL_NAME = "Amount"

--- Total time the clone lives — opacity ramps up briefly, then fades to 1.
local POP_IN_SECONDS = 0.12
local HOLD_SECONDS = 1.1
local FADE_SECONDS = 1.3

--- Each successive concurrent toast lifts by this additional `Y` scale of
--- the parent CashStrip. Keeps a stack of "+$200" "+$50" rapid pops readable
--- instead of overlapping.
local STACK_LIFT_SCALE = 0.65

--- Final upward travel during the fade (in scale of CashStrip's height).
local FADE_LIFT_SCALE = 0.45

local activeStackCount: number = 0

local function formatCashWithCommas(amount: number): string
	local n = math.floor(math.max(0, amount))
	local s = tostring(n)
	local segments = {}
	local i = #s
	while i > 0 do
		local startIdx = math.max(1, i - 2)
		table.insert(segments, 1, string.sub(s, startIdx, i))
		i = startIdx - 1
	end
	return table.concat(segments, ",")
end

local function findTemplate(playerGui: PlayerGui): Frame?
	local hud = playerGui:FindFirstChild("HUD")
	local canvas = hud and hud:FindFirstChild("Canvas")
	local strip = canvas and canvas:FindFirstChild("CashStrip")
	if not strip then
		strip = hud and hud:FindFirstChild("CashStrip", true)
	end
	if not strip then
		return nil
	end
	local tmpl = strip:FindFirstChild(TEMPLATE_NAME)
	if tmpl and tmpl:IsA("Frame") then
		return tmpl
	end
	return nil
end

--- Public: pop a "+$amount" toast above the CashStrip and fade it out.
function CashGainToast.notifyGain(playerGui: PlayerGui, amount: number)
	if typeof(amount) ~= "number" or amount <= 0 then
		return
	end
	local template = findTemplate(playerGui)
	if not template then
		-- Template missing (Studio not synced yet). Silent return — re-checked
		-- on every notify so the next gain after sync still pops.
		return
	end

	local clone = template:Clone()
	clone.Name = CLONE_NAME
	clone.Visible = true
	clone.Parent = template.Parent

	-- Stack offset: clones above an active stack lift up by N * STACK_LIFT_SCALE.
	-- The base toast position (anchor 1,1; `Y = -0.06` scale of CashStrip) keeps
	-- the toast just above the strip; each additional concurrent toast subtracts
	-- another lift so the older ones float higher as new ones appear underneath.
	local stackIndex = activeStackCount
	activeStackCount += 1

	local basePosition = clone.Position
	local startPosition = UDim2.new(
		basePosition.X.Scale,
		basePosition.X.Offset,
		basePosition.Y.Scale - (stackIndex * STACK_LIFT_SCALE),
		basePosition.Y.Offset
	)
	clone.Position = startPosition

	local label = clone:FindFirstChild(LABEL_NAME)
	if label and label:IsA("TextLabel") then
		label.Text = "+$" .. formatCashWithCommas(amount)
		label.TextTransparency = 1
		local stroke = label:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Transparency = 1
		end

		-- Pop in: opacity 1 → 0 (text fully visible), tiny upward nudge.
		local popIn = TweenService:Create(
			label,
			TweenInfo.new(POP_IN_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ TextTransparency = 0 }
		)
		popIn:Play()
		if stroke then
			TweenService
				:Create(
					stroke,
					TweenInfo.new(POP_IN_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{ Transparency = 0 }
				)
				:Play()
		end

		-- After hold, fade out the text + stroke and lift the whole clone.
		task.delay(POP_IN_SECONDS + HOLD_SECONDS, function()
			if not clone.Parent then
				return
			end
			local fadeInfo = TweenInfo.new(FADE_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			local labelInst = clone:FindFirstChild(LABEL_NAME)
			if labelInst and labelInst:IsA("TextLabel") then
				TweenService:Create(labelInst, fadeInfo, { TextTransparency = 1 }):Play()
				local s = labelInst:FindFirstChildOfClass("UIStroke")
				if s then
					TweenService:Create(s, fadeInfo, { Transparency = 1 }):Play()
				end
			end
			local liftPosition = UDim2.new(
				startPosition.X.Scale,
				startPosition.X.Offset,
				startPosition.Y.Scale - FADE_LIFT_SCALE,
				startPosition.Y.Offset
			)
			TweenService:Create(clone, fadeInfo, { Position = liftPosition }):Play()

			task.delay(FADE_SECONDS + 0.05, function()
				if clone and clone.Parent then
					clone:Destroy()
				end
				activeStackCount = math.max(0, activeStackCount - 1)
			end)
		end)
	else
		-- Template malformed: still drop the clone after a short delay so the
		-- stack counter doesn't leak.
		task.delay(POP_IN_SECONDS + HOLD_SECONDS + FADE_SECONDS + 0.1, function()
			if clone and clone.Parent then
				clone:Destroy()
			end
			activeStackCount = math.max(0, activeStackCount - 1)
		end)
	end
end

return CashGainToast
