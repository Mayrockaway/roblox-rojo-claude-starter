--!strict
-- Binds the pinned `FreeDailyDrillCard` in `ShopPanelGui.DRILLSRow` to the
-- server-authoritative daily-drill state (`EquipmentShopService` →
-- `DailyDrillUpdate`). The server picks the drill deterministically per UTC
-- cycle (see `DailyDrillConfig`), persists claimed state per player, and
-- grants the drill via `EquipmentShopService:GrantFreeOwnedEquipment` when
-- `RequestClaimDailyDrill` fires.
--
-- Client responsibilities (this file):
--   * Paint the card from `DailyDrillUpdate` payloads (itemId, claimed).
--   * Tick a 1Hz countdown to the next UTC cycle boundary.
--   * Pulse + rainbow while unclaimed; freeze + grey-out after claim.
--   * Fire `RequestClaimDailyDrill` on CLAIM click. The server responds with
--     a follow-up `DailyDrillUpdate` (and an `OilActionResult` toast), which
--     the listener here translates back into `setClaimed(true)`.
--
-- Repopulation invariant: the rolled drill ONLY changes at UTC cycle rollover
-- (24h). The rotating equipment-shop refresh (`EquipmentShopStockUpdate`) does
-- not touch this card — the host row preserves it via `IsPinnedShopCard` in
-- `EquipmentShopPopulate.clearClonesIn`, and `applyDrillToCard` is only
-- invoked on (a) first paint, (b) a `DailyDrillUpdate` where `itemId`
-- differs, and (c) the 1Hz local fallback when the countdown hits zero.
--
-- FTUE gate: the card stays `Visible = false` while the player is still in
-- the tutorial (any non-nil `FtueStep` player attribute). It flips on when
-- the server clears `FtueStep` on the Done → complete transition.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SharedConfig = Shared:WaitForChild("Config")
local EquipmentCatalog = require(SharedConfig:WaitForChild("EquipmentCatalog"))
local DailyDrillConfig = require(SharedConfig:WaitForChild("DailyDrillConfig"))
local ShopPanelTemplates = require(SharedConfig:WaitForChild("ShopPanelTemplates"))
local FtueConfig = require(SharedConfig:WaitForChild("FtueConfig"))
local Constants = require(Shared:WaitForChild("Constants"))

--- `GetClientRemotes` lives at `PlayerScripts.Client.GetClientRemotes`. This
--- file is `PlayerScripts.Client.UI.FreeDailyDrillController`, so walk up one
--- level to find it.
local getClientRemotes = require(script.Parent.Parent:WaitForChild("GetClientRemotes")) :: () -> any

local M = {}

local PULSE_PERIOD_SEC = 1.6
local PULSE_AMPLITUDE = 0.015
local RAINBOW_CYCLE_SECONDS = 3
local CLAIMED_TEXT = "CLAIMED"
local READY_TEXT = "CLAIM"

local function toImageUri(raw: string?): string?
	if typeof(raw) ~= "string" or raw == "" then
		return nil
	end
	if raw:match("^rbxthumb://") or raw:match("^rbxasset://") or raw:match("^http") then
		return raw
	end
	local id = raw:match("rbxassetid://(%d+)") or raw:match("^(%d+)$")
	if id then
		return string.format("rbxthumb://type=Asset&id=%s&w=150&h=150", id)
	end
	return raw
end

local function findRole(card: Instance, role: string): Instance?
	for _, d in ipairs(card:GetDescendants()) do
		if d:GetAttribute("Role") == role then
			return d
		end
	end
	return nil
end

local function formatHMS(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	local h = math.floor(s / 3600)
	local m = math.floor((s % 3600) / 60)
	local sec = s % 60
	return string.format("%02d:%02d:%02d", h, m, sec)
end

local function findCard(playerGui: PlayerGui): GuiObject?
	local shop = playerGui:FindFirstChild("ShopPanelGui")
	if not shop then
		return nil
	end
	for _, d in ipairs(shop:GetDescendants()) do
		if d:IsA("GuiObject") and d:GetAttribute("IsFreeDailyDrillCard") == true then
			return d
		end
	end
	return nil
end

local function toGray(c: Color3): Color3
	local luma = c.R * 0.299 + c.G * 0.587 + c.B * 0.114
	local g = luma * 0.6
	return Color3.new(g, g, g)
end

local function applyDrillToCard(card: GuiObject, itemId: string)
	local row = EquipmentCatalog.getRowById(itemId)
	if not row then
		warn("[FreeDailyDrill] catalog row not found for id=" .. tostring(itemId))
		return
	end
	card:SetAttribute("FreeDailyDrillItemId", itemId)

	local rarityStyle = ShopPanelTemplates.GetRarityStyle(row.rarity)
	local stripe = findRole(card, "RarityStripe")
	if stripe and stripe:IsA("GuiObject") then
		stripe.BackgroundColor3 = rarityStyle.stripeColor
		stripe.BackgroundTransparency = 0
	end
	local rarityLbl = findRole(card, "RarityTag")
	if rarityLbl and rarityLbl:IsA("TextLabel") then
		rarityLbl.Text = rarityStyle.label or "RARITY"
		rarityLbl.TextColor3 = rarityStyle.tagColor
	end
	local nameLbl = findRole(card, "Name")
	if nameLbl and (nameLbl:IsA("TextLabel") or nameLbl:IsA("TextButton")) then
		nameLbl.Text = "Daily Free Drill"
	end
	local descLbl = findRole(card, "Description")
	if descLbl and descLbl:IsA("TextLabel") then
		descLbl.Text = string.format(
			"Claim your free %s today! Check back every 24 hours!",
			row.displayName
		)
	end
	local iconLbl = findRole(card, "Icon")
	local iconHint = findRole(card, "IconHint")
	local iconUri = toImageUri(row.iconAssetId)
	if iconLbl and iconLbl:IsA("ImageLabel") then
		if iconUri then
			iconLbl.Image = iconUri
			iconLbl.ImageTransparency = 0
			iconLbl.Visible = true
		else
			iconLbl.Image = ""
			iconLbl.ImageTransparency = 1
			iconLbl.Visible = false
		end
	end
	if iconHint and iconHint:IsA("GuiObject") then
		iconHint.Visible = (iconUri == nil)
	end
end

type ColorSnapshot = {
	node: Instance,
	bg: Color3?,
	fg: Color3?,
	stroke: Color3?,
}

local function snapshotColors(card: GuiObject): { ColorSnapshot }
	local out: { ColorSnapshot } = {}
	for _, d in ipairs(card:GetDescendants()) do
		if d:IsA("UIStroke") then
			table.insert(out, { node = d, stroke = d.Color })
		elseif d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox") then
			table.insert(out, { node = d, bg = d.BackgroundColor3, fg = d.TextColor3 })
		elseif d:IsA("ImageLabel") or d:IsA("ImageButton") then
			table.insert(out, { node = d, bg = d.BackgroundColor3, fg = d.ImageColor3 })
		elseif d:IsA("Frame") then
			table.insert(out, { node = d, bg = d.BackgroundColor3 })
		end
	end
	if card:IsA("Frame") then
		table.insert(out, { node = card, bg = card.BackgroundColor3 })
	end
	return out
end

local function applyGray(snap: { ColorSnapshot })
	for _, s in ipairs(snap) do
		local n = s.node
		if not n.Parent then continue end
		if s.stroke and n:IsA("UIStroke") then
			n.Color = toGray(s.stroke)
		end
		if s.bg and n:IsA("GuiObject") then
			(n :: any).BackgroundColor3 = toGray(s.bg)
		end
		if s.fg then
			if n:IsA("TextLabel") or n:IsA("TextButton") or n:IsA("TextBox") then
				(n :: any).TextColor3 = toGray(s.fg)
			elseif n:IsA("ImageLabel") or n:IsA("ImageButton") then
				(n :: any).ImageColor3 = toGray(s.fg)
			end
		end
	end
end

local function restoreColors(snap: { ColorSnapshot })
	for _, s in ipairs(snap) do
		local n = s.node
		if not n.Parent then continue end
		if s.stroke and n:IsA("UIStroke") then
			n.Color = s.stroke
		end
		if s.bg and n:IsA("GuiObject") then
			(n :: any).BackgroundColor3 = s.bg
		end
		if s.fg then
			if n:IsA("TextLabel") or n:IsA("TextButton") or n:IsA("TextBox") then
				(n :: any).TextColor3 = s.fg
			elseif n:IsA("ImageLabel") or n:IsA("ImageButton") then
				(n :: any).ImageColor3 = s.fg
			end
		end
	end
end

--- FTUE gate: hide the Daily Free Drill card while the player is still in the
--- tutorial content. Mirrors the server-side `FtueService` contract (see
--- the `step == FtueConfig.Step.Done or step == nil` check there):
---   * `FtueConfig.Enabled == false` — FTUE globally off, always complete.
---   * `step == nil`                  — fully acknowledged, tutorial over.
---   * `step == FtueConfig.Step.Done` — player reached the final congrats
---                                      dialog but hasn't dismissed it yet;
---                                      gameplay is unlocked, so show the
---                                      card. Without this, players who
---                                      rejoin while "Done" is persisted
---                                      would never see the Daily Free
---                                      Drill until they clicked through
---                                      the completion dialog again.
---   * any other step                 — still in a content leg, hide.
local function isFtueComplete(): boolean
	if FtueConfig.Enabled ~= true then
		return true
	end
	local plr = Players.LocalPlayer
	if not plr then
		return false
	end
	local step = plr:GetAttribute(Constants.FtueStepAttribute)
	return step == nil or step == FtueConfig.Step.Done
end

function M.start(playerGui: PlayerGui)
	local Remotes = getClientRemotes()
	if not Remotes then
		warn("[FreeDailyDrill] could not resolve ClientRemotes")
		return
	end

	local card: GuiObject? = findCard(playerGui)
	if not card then
		local deadline = os.clock() + 15
		while not card and os.clock() < deadline do
			task.wait(0.25)
			card = findCard(playerGui)
		end
	end
	if not card then
		warn("[FreeDailyDrill] FreeDailyDrillCard not found in PlayerGui.ShopPanelGui")
		return
	end

	-- FTUE visibility: hide the card until the tutorial is complete, then flip
	-- it on when the attribute clears (if the player finishes mid-session).
	-- `ShopPanelGui.ResetOnSpawn` is set `false` (authored in Studio) so the
	-- card reference survives character respawns — without that, the listener
	-- below would keep writing `Visible` to a detached instance after death.
	-- If the ScreenGui is ever regenerated anyway, we re-resolve the card
	-- lazily via `findCard` inside the listener.
	local function applyFtueVisibility(reason: string?)
		local live = card.Parent and card or findCard(playerGui)
		if not live then
			if RunService:IsStudio() then
				warn(string.format("[FreeDailyDrill] FTUE gate (%s): card not found", tostring(reason)))
			end
			return
		end
		card = live
		local plr = Players.LocalPlayer
		local step = plr and plr:GetAttribute(Constants.FtueStepAttribute)
		local complete = isFtueComplete()
		if RunService:IsStudio() then
			print(string.format(
				"[FreeDailyDrill] FTUE gate (%s): step=%s complete=%s -> Visible=%s cardParent=%s",
				tostring(reason), tostring(step), tostring(complete), tostring(complete),
				card.Parent and card.Parent:GetFullName() or "<nil>"
			))
		end
		card.Visible = complete
	end
	applyFtueVisibility("initial")
	local localPlr = Players.LocalPlayer
	if localPlr and FtueConfig.Enabled == true then
		localPlr:GetAttributeChangedSignal(Constants.FtueStepAttribute):Connect(function()
			applyFtueVisibility("attr-change")
		end)
	end

	local timerLbl = findRole(card, "ResetTimer")
	local pulseScale = card:FindFirstChild("PulseScale") :: UIScale?
	local claimBtn = findRole(card, "Claim") :: GuiButton?
	local claimText = findRole(card, "ClaimText") :: TextLabel?

	local rainbowGrads: { UIGradient } = {}
	for _, d in ipairs(card:GetDescendants()) do
		if d:IsA("UIGradient") and d:GetAttribute("IsRainbowAnim") == true then
			table.insert(rainbowGrads, d)
		end
	end

	--- Authoritative state comes from the server. Until the first payload
	--- arrives, paint from the client's mirror of the deterministic roll
	--- (same algorithm, same result, so the card doesn't flash blank).
	local currentItemId: string = DailyDrillConfig.GetCurrentDrill()
	local claimed = false
	--- Server pushes `secondsRemaining`; we snapshot it + the `os.clock()`
	--- we received it, then tick locally. When a fresh update arrives we
	--- reset the baseline so drift doesn't accumulate.
	local secondsRemainingAtPush = DailyDrillConfig.GetSecondsRemaining()
	local pushedAt = os.clock()

	applyDrillToCard(card, currentItemId)
	local colorSnapshot = snapshotColors(card)

	local function readyText(): string
		if claimText and claimText:IsA("TextLabel") then
			local r = claimText:GetAttribute("ReadyText")
			if typeof(r) == "string" and r ~= "" then return r end
		end
		return READY_TEXT
	end
	local function claimedLabel(): string
		if claimText and claimText:IsA("TextLabel") then
			local c = claimText:GetAttribute("ClaimedText")
			if typeof(c) == "string" and c ~= "" then return c end
		end
		return CLAIMED_TEXT
	end

	local function setClaimed(flag: boolean)
		claimed = flag
		if flag then
			applyGray(colorSnapshot)
			for _, g in ipairs(rainbowGrads) do g.Enabled = false end
			if pulseScale then pulseScale.Scale = 1 end
			if claimBtn then
				claimBtn.AutoButtonColor = false
				claimBtn.Active = false
			end
			if claimText then claimText.Text = claimedLabel() end
		else
			restoreColors(colorSnapshot)
			for _, g in ipairs(rainbowGrads) do g.Enabled = true end
			if claimBtn then
				claimBtn.AutoButtonColor = true
				claimBtn.Active = true
			end
			if claimText then claimText.Text = readyText() end
		end
	end

	--- Apply a fresh server payload. Repaint if the rolled drill changed
	--- (cycle rollover or hot-patched config) and update the claimed state.
	local function applyServerPayload(payload: any)
		if typeof(payload) ~= "table" then return end
		if typeof(payload.itemId) == "string" and payload.itemId ~= currentItemId then
			currentItemId = payload.itemId
			applyDrillToCard(card, currentItemId)
			colorSnapshot = snapshotColors(card)
		end
		if typeof(payload.secondsRemaining) == "number" then
			secondsRemainingAtPush = payload.secondsRemaining
			pushedAt = os.clock()
		end
		local serverClaimed = payload.claimed == true
		if serverClaimed ~= claimed then
			setClaimed(serverClaimed)
		end
	end

	-- Server → client state updates.
	Remotes.dailyDrillUpdate.OnClientEvent:Connect(applyServerPayload)

	-- Server → client action results (toast-level feedback). Not strictly
	-- required for correctness — the companion `dailyDrillUpdate` already
	-- flips the card to claimed — but we treat an explicit failure as a
	-- belt-and-braces unlock so the player can retry.
	Remotes.oilActionResult.OnClientEvent:Connect(function(result: any)
		if typeof(result) ~= "table" then return end
		if result.action ~= "ClaimDailyDrill" then return end
		if result.ok == true then
			-- Success is handled by the follow-up DailyDrillUpdate.
		else
			if RunService:IsStudio() then
				print("[FreeDailyDrill] claim failed: " .. tostring(result.code) .. " — " .. tostring(result.message))
			end
			-- If we greyed the card pre-emptively on click, un-grey it here.
			if claimed then
				setClaimed(false)
			end
		end
	end)

	-- CLAIM button → fire server request. We do NOT optimistically grey the
	-- card — the follow-up `dailyDrillUpdate` from the server flips it, which
	-- keeps UI state tied to server truth and avoids a flash-of-grey-then-
	-- unclaimed on failure.
	--
	-- Decorative descendants of a GuiButton (the inner `Text` label, gradients,
	-- strokes, etc.) are `Active = true` by default and eat the click before
	-- it reaches the button's `Activated` signal. Mirror `EquipmentShopPanel`'s
	-- `passthroughBuyDecorations` helper to disable `Active` on every
	-- descendant of the Claim button.
	if claimBtn and claimBtn:IsA("GuiButton") then
		for _, d in ipairs(claimBtn:GetDescendants()) do
			if d:IsA("GuiObject") then
				d.Active = false
			end
		end
		claimBtn.Active = true
		claimBtn.Activated:Connect(function()
			if RunService:IsStudio() then
				print("[FreeDailyDrill] CLAIM clicked; claimed=" .. tostring(claimed))
			end
			if claimed then return end
			Remotes.requestClaimDailyDrill:FireServer()
		end)
	else
		warn("[FreeDailyDrill] Claim button not found (Role='Claim')")
	end

	-- Per-frame: pulse + rainbow, gated on unclaimed state.
	RunService.Heartbeat:Connect(function(_dt)
		if not card.Parent then return end
		if claimed then return end
		local t = os.clock()
		if pulseScale then
			pulseScale.Scale = 1 + PULSE_AMPLITUDE * math.sin(t * 2 * math.pi / PULSE_PERIOD_SEC)
		end
		local phase = (t / RAINBOW_CYCLE_SECONDS) % 1
		for _, g in ipairs(rainbowGrads) do
			g.Offset = Vector2.new(phase, 0)
		end
	end)

	-- 1Hz tick: countdown + local cycle-rollover guard. Server will also push
	-- a new DailyDrillUpdate at rollover; this local path just keeps the card
	-- visually live if that push is delayed.
	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt)
		accumulator += dt
		if accumulator < 1.0 then return end
		accumulator = 0
		if not card.Parent then return end
		local localSecondsLeft = math.max(0, secondsRemainingAtPush - (os.clock() - pushedAt))
		if timerLbl and timerLbl:IsA("TextLabel") then
			timerLbl.Text = formatHMS(localSecondsLeft)
		end
		-- Client-side fallback if no server push yet: cross-check the
		-- deterministic config so the card doesn't stall on a stale drill
		-- after a local-midnight flip.
		if localSecondsLeft <= 0 then
			local rolled = DailyDrillConfig.GetCurrentDrill()
			if rolled ~= currentItemId then
				currentItemId = rolled
				applyDrillToCard(card, currentItemId)
				colorSnapshot = snapshotColors(card)
				setClaimed(false)
			end
			secondsRemainingAtPush = DailyDrillConfig.GetSecondsRemaining()
			pushedAt = os.clock()
		end
	end)
end

return M
