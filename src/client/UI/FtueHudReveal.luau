--!strict
-- Progressive HUD reveal during the FTUE.
--
-- Hides most of `PlayerGui.HUD.Canvas` on first join and unlocks pieces as the
-- player advances through `FtueConfig.Order` so the new-player view is not
-- overwhelming. Once the FTUE finishes (`Done` or no step), all gated frames
-- are forced `Visible = true` and a property-change listener keeps them visible
-- as a safety net.
--
-- Frames not in `CHILD_REVEAL` are left alone (e.g. `ActiveManifestPanel`,
-- `StraitForceLockTimer`, templates) — their own controllers manage visibility.
--
-- Wiring lives in `src/client/init.client.luau` (called early so the HUD does
-- not flash fully visible before the gate applies).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local FtueConfig = require(Shared:WaitForChild("Config"):WaitForChild("FtueConfig"))

local FtueHudReveal = {}

type GatedEntry = {
	path: string,
	revealAt: string,
}

-- Direct children of `HUD.Canvas`. `revealAt` is the FTUE step at which the
-- frame should first become `Visible = true`. Any earlier step hides it.
--
-- Schedule (canonical):
--   Intro                 → no HUD
--   WaitDrillOil_WIP      → + EquipmentHotbar
--   WaitPlotShipment      → + CashStrip, ActiveManifestPanel
--   WaitShipment          → + TopRow, ShipmentProgressPanel
--   WaitDocksShipUpgrade  → + Buttons, CashStripPlus (robux modal; was top-level RobuxShop)
--   Done                  → + StraitControlCta, EarningsGamepass,
--                            NukeDevProduct, AutoShipButton (rest of HUD)
--
-- ShipmentProgressPanel reveals at WaitShipment so the player sees the
-- voyage progress bar / status text for their first dispatched ship —
-- without it the strait leg has no visible feedback.
--
-- `StraitForceLockTimer` is intentionally NOT gated — its own controller
-- (`StraitForceLockTimer.luau`) authors `Visible = false` and only flips it
-- on while a Robux force-lock is active. Letting it self-manage avoids
-- conflict with our gate.
local CHILD_REVEAL: { GatedEntry } = {
	{ path = "EquipmentHotbar", revealAt = FtueConfig.Step.WaitDrillOil_WIP },
	{ path = "CashStrip", revealAt = FtueConfig.Step.WaitPlotShipment },
	{ path = "ActiveManifestPanel", revealAt = FtueConfig.Step.WaitPlotShipment },
	{ path = "TopRow", revealAt = FtueConfig.Step.WaitShipment },
	{ path = "ShipmentProgressPanel", revealAt = FtueConfig.Step.WaitShipment },
	{ path = "Buttons", revealAt = FtueConfig.Step.WaitDocksShipUpgrade },
	{ path = "CashStripPlus", revealAt = FtueConfig.Step.WaitDocksShipUpgrade },
	{ path = "StraitControlCta", revealAt = FtueConfig.Step.Done },
	{ path = "EarningsGamepass", revealAt = FtueConfig.Step.Done },
	{ path = "NukeDevProduct", revealAt = FtueConfig.Step.Done },
	-- AutoShipButton is a GamePass CTA (same family as EarningsGamepass) — gated to
	-- `Done` so it doesn't appear during the FTUE reveal stages and overload the
	-- new player. Once FTUE completes, `AutoShipController` resumes its normal
	-- ownership-driven `Visible` behavior under the post-FTUE all-visible lock.
	{ path = "AutoShipButton", revealAt = FtueConfig.Step.Done },
}

-- Build step-id → ordinal index from `FtueConfig.Order`. `Done` is treated as
-- "after the last step" so any reveal anchored at `Done` only fires once the
-- player has reached the final/completed state.
local function buildStepIndex(): { [string]: number }
	local m: { [string]: number } = {}
	for i, step in ipairs(FtueConfig.Order) do
		m[step] = i
	end
	if FtueConfig.Step.Done and m[FtueConfig.Step.Done] == nil then
		m[FtueConfig.Step.Done] = #FtueConfig.Order + 1
	end
	return m
end

local STEP_INDEX = buildStepIndex()
local DONE_INDEX = STEP_INDEX[FtueConfig.Step.Done] or (#FtueConfig.Order + 1)

local function isCompletedStep(stepValue: any): boolean
	-- FtueService clears the attribute (sets it to nil/empty) once the player
	-- acknowledges the final dialogue. `Done` itself is also a "show every-
	-- thing" state because the only remaining action is the Complete button.
	if stepValue == nil or stepValue == "" then
		return true
	end
	return stepValue == FtueConfig.Step.Done
end

type Gated = {
	inst: GuiObject,
	revealIndex: number,
	lockConn: RBXScriptConnection?,
}

function FtueHudReveal.start(player: Player)
	local pg = player:WaitForChild("PlayerGui")

	-- Wait for HUD + Canvas to stream in. Hide the HUD ScreenGui while we
	-- resolve children so authored `Visible = true` defaults do not flash
	-- before the gate applies on first join.
	local hud = pg:WaitForChild("HUD", 30)
	if not hud or not hud:IsA("ScreenGui") then
		warn("[FtueHudReveal] PlayerGui.HUD missing or not a ScreenGui — bailing")
		return
	end
	local canvas = hud:WaitForChild("Canvas", 10)
	if not canvas or not canvas:IsA("GuiObject") then
		warn("[FtueHudReveal] HUD.Canvas missing — bailing")
		return
	end

	-- NOTE: We deliberately do NOT toggle `hud.Enabled` here. The entire
	-- scan + initial `applyForStep` below runs synchronously after the
	-- `WaitForChild` calls (no `task.wait` / yields), so nothing renders
	-- between iterations and no flicker is possible from this script. The
	-- loading-screen reveal is owned by `replicated_first/init.client.luau`
	-- — it sets `HUD.Enabled = false` while the loading cover is up and
	-- re-enables it after `screen:Destroy()`. If we save/restore `Enabled`
	-- here we race with that bootstrap (it could read `prevEnabled = true`
	-- before the bootstrap has had a chance to disable the HUD, then
	-- restore it back to `true` mid-loading and let the HUD peek through
	-- the cover's fade tween). Leaving `Enabled` alone makes the loading
	-- bootstrap the sole owner.

	-- `gated` holds resolved entries; `pendingByPath` tracks gated entries we
	-- still need to find. On rejoin, replication of `Canvas` children can lag
	-- the initial scan — without a `ChildAdded` watcher the missed entries
	-- would never get a lock listener attached, so a completed-FTUE player
	-- could see e.g. `EquipmentHotbar` flicker hidden later in the session.
	local gated: { Gated } = {}
	local pendingByPath: { [string]: GatedEntry } = {}

	local function tryAddEntry(entry: GatedEntry, inst: Instance): boolean
		if inst:IsA("GuiObject") then
			local revealIdx = STEP_INDEX[entry.revealAt] or DONE_INDEX
			table.insert(gated, {
				inst = inst :: GuiObject,
				revealIndex = revealIdx,
				lockConn = nil,
			})
			return true
		end
		return false
	end

	local function resolveGatedPath(path: string): GuiObject?
		local direct = canvas:FindFirstChild(path)
		if direct and direct:IsA("GuiObject") then
			return direct :: GuiObject
		end
		local deep = canvas:FindFirstChild(path, true)
		if deep and deep:IsA("GuiObject") then
			return deep :: GuiObject
		end
		return nil
	end

	for _, entry in ipairs(CHILD_REVEAL) do
		local inst = resolveGatedPath(entry.path)
		if inst and tryAddEntry(entry, inst) then
			-- resolved
		else
			pendingByPath[entry.path] = entry
		end
	end

	local function clearLock(g: Gated)
		if g.lockConn then
			g.lockConn:Disconnect()
			g.lockConn = nil
		end
	end

	local function lockVisible(g: Gated)
		g.inst.Visible = true
		if g.lockConn then
			return
		end
		g.lockConn = g.inst:GetPropertyChangedSignal("Visible"):Connect(function()
			if g.inst.Visible == false then
				g.inst.Visible = true
			end
		end)
	end

	local function applyForStep(stepValue: any)
		if isCompletedStep(stepValue) then
			for _, g in ipairs(gated) do
				lockVisible(g)
			end
			return
		end
		local idx = STEP_INDEX[stepValue]
		if not idx then
			-- Unknown step (legacy save / typo) → treat as pre-Order: hide
			-- everything gated so we never flash mid-tutorial UI.
			idx = 0
		end
		for _, g in ipairs(gated) do
			if idx >= g.revealIndex then
				-- Once a HUD piece reaches its reveal step it should never
				-- disappear again for the rest of the FTUE — lock Visible=true
				-- with the property-change watchdog so other controllers
				-- (panel openers, transient hides) cannot hide it mid-FTUE.
				lockVisible(g)
			else
				clearLock(g)
				g.inst.Visible = false
			end
		end
	end

	local function currentStepValue(): any
		if FtueConfig.Enabled == false then
			return FtueConfig.Step.Done
		end
		return player:GetAttribute(Constants.FtueStepAttribute)
	end

	-- Initial apply over whatever resolved synchronously.
	applyForStep(currentStepValue())

	-- Reactive resolution: if any gated child was missing at scan time
	-- (replication lag on rejoin, streaming, etc.), pick it up when it
	-- appears and immediately apply the current step's visibility / lock.
	if next(pendingByPath) ~= nil then
		local addedConn: RBXScriptConnection? = nil
		addedConn = canvas.ChildAdded:Connect(function(child)
			local entry = pendingByPath[child.Name]
			if entry and tryAddEntry(entry, child) then
				pendingByPath[child.Name] = nil
				applyForStep(currentStepValue())
				if next(pendingByPath) == nil and addedConn then
					addedConn:Disconnect()
					addedConn = nil
				end
			end
		end)
		-- Nested gates (e.g. `CashStripPlus` parented under `CashStrip`): resolve any time
		-- a descendant appears; `pendingByPath` keys are canonical path IDs.
		local descConn: RBXScriptConnection? = nil
		descConn = canvas.DescendantAdded:Connect(function(child)
			if not child:IsA("GuiObject") then
				return
			end
			local entry = pendingByPath[child.Name]
			if entry and tryAddEntry(entry, child) then
				pendingByPath[child.Name] = nil
				applyForStep(currentStepValue())
				if next(pendingByPath) == nil then
					if addedConn then
						addedConn:Disconnect()
						addedConn = nil
					end
					if descConn then
						descConn:Disconnect()
						descConn = nil
					end
				end
			end
		end)
		-- Sweep again in a few seconds in case ChildAdded fires before this
		-- listener attaches (defensive — listener was set up in the same
		-- frame as the scan but we want belt-and-braces for any missed
		-- entries that get parented to canvas under unusual conditions).
		task.delay(2, function()
			for path, entry in pairs(pendingByPath) do
				local inst = resolveGatedPath(path)
				if inst and tryAddEntry(entry, inst) then
					pendingByPath[path] = nil
				end
			end
			applyForStep(currentStepValue())
			if next(pendingByPath) == nil then
				if addedConn then
					addedConn:Disconnect()
					addedConn = nil
				end
				if descConn then
					descConn:Disconnect()
					descConn = nil
				end
			end
			-- After the grace period, anything still missing is a real
			-- structural absence — log once so drift is visible.
			for path in pairs(pendingByPath) do
				warn(string.format("[FtueHudReveal] HUD.Canvas...%s never appeared — gate skipped", path))
			end
		end)
	end

	player:GetAttributeChangedSignal(Constants.FtueStepAttribute):Connect(function()
		applyForStep(currentStepValue())
	end)
end

return FtueHudReveal
