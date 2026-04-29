--!strict
-- Rebirth modal (`StarterGui.RebirthPanelGui` → `PlayerGui`). Houses the
-- "Rebirth Now" button + cash → token preview + level readout. Opened by
-- the Jesus2 NPC prompts on each plot and on the OilHeaven landing area.
--
-- Live data sources:
--   * `CashAmount` reads `cash` off `oilStateUpdate` payloads (no attribute
--     mirror exists for cash — too many mutation sites in OilStateService to
--     bolt one on safely).
--   * `TokenCount` derives from cash via `RebirthShopConfig.CashPerToken`
--     (preview of "what you'd get if you rebirthed right now").
--   * `BalanceLabel` reads `Constants.RebirthTokensAttribute` (live mirror
--     set by `OilStateService:AddRebirthTokens`).
--   * `LevelValue` reads `Constants.RebirthCountAttribute` (live mirror set
--     by `OilStateService:IncrementRebirth`).
--
-- Rebirth Now click:
--   * cash < `CashPerToken` → ErrorNotification toast + `UiSfx.playUiDenied`.
--   * cash >= rate → no-op for now. The actual wipe-progress / cash → tokens
--     conversion lives in the rebirth-flow task (D); wiring the success path
--     before the server-side `OilStateService:Rebirth` API exists would let
--     players double-rebirth and softlock state. Comment marks the spot.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local RebirthShopConfig = require(Shared:WaitForChild("Config"):WaitForChild("RebirthShopConfig"))

local HudPanelBase = require(script.Parent.Parent.HudPanelBase)
local HudPanelTypes = require(script.Parent.Parent.HudPanelTypes)
local getClientRemotes = require(script.Parent.Parent.Parent:WaitForChild("GetClientRemotes")) :: () -> any
local UiSfx = require(script.Parent.Parent.Parent:WaitForChild("UiSfx")) :: {
	playKaching: () -> (),
	playUiDenied: () -> (),
}

local SCREEN_NAME = "RebirthPanelGui"
local ERROR_NOTIFICATION_HOLD_SECONDS = 2.5
local ERROR_NOTIFICATION_NAME = "ErrorNotification"

-- Comma formatter used by the cash + token previews. Matches the HUD's
-- CashStrip formatting (`init.client.luau` `formatCashWithCommas`) so the
-- two readouts match digit-for-digit when the panel is open.
local function formatWithCommas(amount: number): string
	local s = tostring(math.floor(math.max(0, amount)))
	-- Insert thousands separators right-to-left.
	local n = #s
	if n <= 3 then return s end
	local out = {}
	local first = ((n - 1) % 3) + 1
	table.insert(out, s:sub(1, first))
	for i = first + 1, n, 3 do
		table.insert(out, s:sub(i, i + 2))
	end
	return table.concat(out, ",")
end

local RebirthPanel = {}

function RebirthPanel.bind(playerGui: PlayerGui): HudPanelTypes.HudPanelController?
	local ctrl = HudPanelBase.tryBind(playerGui, SCREEN_NAME)
	if not ctrl then
		return nil
	end

	local screen = ctrl.ScreenGui
	local ClientRemotes = getClientRemotes()

	local function findOrWarn(path: { string }): Instance?
		local cursor: Instance? = screen
		for _, segment in ipairs(path) do
			if not cursor then return nil end
			cursor = cursor:FindFirstChild(segment, true)
		end
		if not cursor then
			warn(string.format(
				"[RebirthPanel] missing %s under %s",
				table.concat(path, "."),
				screen:GetFullName()
			))
		end
		return cursor
	end

	local cashAmount = findOrWarn({ "ConversionCard", "Row", "CashAmount" }) :: TextLabel?
	local tokenCount = findOrWarn({ "ConversionCard", "Row", "TokenCount" }) :: TextLabel?
	local levelValue = findOrWarn({ "LevelBlock", "LevelValue" }) :: TextLabel?
	local balanceLabel = findOrWarn({ "BalanceChip", "BalanceLabel" }) :: TextLabel?
	local rebirthButton = findOrWarn({ "RebirthNowButton" }) :: GuiButton?
	local errorLabel = screen:FindFirstChild(ERROR_NOTIFICATION_NAME, true) :: TextLabel?

	local subtitleLabel = screen:FindFirstChild("ConversionRateSubtitle", true)
	if subtitleLabel and subtitleLabel:IsA("TextLabel") then
		subtitleLabel.Text = string.format(
			"%s CASH = 1 REBIRTH TOKEN",
			formatWithCommas(RebirthShopConfig.CashPerToken)
		)
	end

	---------------------------------------------------------------------------
	-- Live data sources
	---------------------------------------------------------------------------

	-- Cached cash. Seeded by `RequestRebirthShopSnapshot` on bind + every open
	-- (the server's `_handleSnapshot` returns `cash` alongside the shop
	-- fields). After that, `oilStateUpdate` keeps the cache live for any
	-- subsequent server-side cash mutation. Without the seed the cache stays
	-- nil until the next state push — and pushes are sparse (only on cash
	-- changes), so the panel would render "$0" indefinitely on a quiet
	-- session.
	local cachedCash: number? = nil

	local function paintCashAndTokens()
		local cash = cachedCash or 0
		local rate = RebirthShopConfig.CashPerToken
		local tokens = if rate > 0 then math.floor(cash / rate) else 0
		if cashAmount then
			cashAmount.Text = "$" .. formatWithCommas(cash)
		end
		if tokenCount then
			tokenCount.Text = formatWithCommas(tokens)
		end
	end

	local function paintTokensBalance()
		if not balanceLabel then return end
		local plr = Players.LocalPlayer
		local tokens = plr and plr:GetAttribute(Constants.RebirthTokensAttribute) or 0
		if typeof(tokens) ~= "number" then tokens = 0 end
		balanceLabel.Text = formatWithCommas(tokens)
	end

	local function paintLevel()
		if not levelValue then return end
		local plr = Players.LocalPlayer
		local count = plr and plr:GetAttribute(Constants.RebirthCountAttribute) or 0
		if typeof(count) ~= "number" then count = 0 end
		levelValue.Text = tostring(math.floor(count))
	end

	---------------------------------------------------------------------------
	-- Cash listener (oilStateUpdate) — fires every state push, regardless of
	-- whether the panel is open. Cheap (single number read + two label
	-- writes) so we don't gate on `screen.Enabled` and leave the cache
	-- always-warm for the next open.
	---------------------------------------------------------------------------

	ClientRemotes.oilStateUpdate.OnClientEvent:Connect(function(newState: any)
		if typeof(newState) ~= "table" then return end
		local cash = newState.cash
		if typeof(cash) == "number" then
			cachedCash = math.max(0, math.floor(cash))
			paintCashAndTokens()
		end
	end)

	-- Live mirrors for tokens + level via player attributes.
	local plr = Players.LocalPlayer
	if plr then
		plr:GetAttributeChangedSignal(Constants.RebirthTokensAttribute):Connect(paintTokensBalance)
		plr:GetAttributeChangedSignal(Constants.RebirthCountAttribute):Connect(paintLevel)
	end

	---------------------------------------------------------------------------
	-- Error notification (toast) — same authoring + flow as RebirthShopPanel.
	---------------------------------------------------------------------------

	local errorNotificationSeq = 0

	local function showErrorNotification(message: string)
		if not errorLabel or not errorLabel.Parent then
			return
		end
		errorNotificationSeq += 1
		local seq = errorNotificationSeq
		errorLabel.Text = message
		errorLabel.TextTransparency = 0
		errorLabel.Visible = true
		task.delay(ERROR_NOTIFICATION_HOLD_SECONDS, function()
			if seq ~= errorNotificationSeq or not errorLabel or not errorLabel.Parent then
				return
			end
			local tw = TweenService:Create(errorLabel, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				TextTransparency = 1,
			})
			tw:Play()
			tw.Completed:Wait()
			if seq ~= errorNotificationSeq or not errorLabel or not errorLabel.Parent then
				return
			end
			errorLabel.Visible = false
			errorLabel.TextTransparency = 0
		end)
	end

	---------------------------------------------------------------------------
	-- Rebirth Now click — cash gate + error path. Success path is a TODO
	-- pinned to the rebirth-flow task (D).
	---------------------------------------------------------------------------

	-- Rebirth click debounce so a fast double-click can't fire the remote
	-- twice. Server has its own debounce too (`REBIRTH_DEBOUNCE_SECONDS`),
	-- but gating client-side avoids the wasted network round-trip + the
	-- spurious "Slow down" toast on the second click.
	local lastRebirthAttempt = 0.0
	local REBIRTH_CLICK_DEBOUNCE = 1.0

	if rebirthButton then
		rebirthButton.Active = true
		rebirthButton.Activated:Connect(function()
			local rate = RebirthShopConfig.CashPerToken
			local cash = cachedCash or 0
			if cash < rate then
				showErrorNotification(string.format(
					"You need at least $%s for one Rebirth Token.",
					formatWithCommas(rate)
				))
				UiSfx.playUiDenied()
				return
			end
			local now = os.clock()
			if now - lastRebirthAttempt < REBIRTH_CLICK_DEBOUNCE then
				return
			end
			lastRebirthAttempt = now
			ClientRemotes.requestRebirth:FireServer()
		end)
	end

	-- Listen for the rebirth result. On success: kaching, close the panel
	-- (the player is in their plot or in OilHeaven — either is fine to stay
	-- in per spec). On failure: error toast with the server-supplied message
	-- (typically `ERR_NOT_ENOUGH_CASH` if cash dropped between gate + click).
	ClientRemotes.oilActionResult.OnClientEvent:Connect(function(msg: any)
		if typeof(msg) ~= "table" or msg.action ~= "Rebirth" then
			return
		end
		if msg.ok == true then
			UiSfx.playKaching()
			-- Leave the panel open so the player can see the level bump,
			-- balance update, and zeroed cash. Cash + tokens + level all
			-- repaint via the next state push and attribute change signals
			-- — no manual paint needed here.
		else
			local reason = if typeof(msg.message) == "string" and msg.message ~= ""
				then msg.message
				else "Rebirth failed."
			showErrorNotification(reason)
			UiSfx.playUiDenied()
		end
	end)

	---------------------------------------------------------------------------
	-- Open / bind hydration. Pulls a fresh snapshot from the server so the
	-- cash readout doesn't sit at $0 waiting for the next sparse
	-- `oilStateUpdate` push. The async fetch runs in a task.spawn so the
	-- panel paints immediately from the cache and updates again when the
	-- snapshot returns.
	---------------------------------------------------------------------------

	local function fetchSnapshot()
		task.spawn(function()
			local ok, snapshot = pcall(function()
				return ClientRemotes.requestRebirthShopSnapshot:InvokeServer()
			end)
			if not ok or typeof(snapshot) ~= "table" then
				return
			end
			if typeof(snapshot.cash) == "number" then
				cachedCash = math.max(0, math.floor(snapshot.cash))
				paintCashAndTokens()
			end
		end)
	end

	local function refreshOnOpen()
		paintCashAndTokens()
		paintTokensBalance()
		paintLevel()
		fetchSnapshot()
	end

	local baseOpen = ctrl.Open
	ctrl.Open = function()
		baseOpen()
		refreshOnOpen()
	end
	screen:GetPropertyChangedSignal("Enabled"):Connect(function()
		if screen.Enabled then
			refreshOnOpen()
		end
	end)

	-- Initial paint + bind-time snapshot fetch. Tokens / level come from
	-- attributes that are already mirrored at this point; cash is fetched
	-- async via the snapshot so it's ready by the first open.
	refreshOnOpen()

	return ctrl
end

function RebirthPanel.screenName(): string
	return SCREEN_NAME
end

return RebirthPanel
