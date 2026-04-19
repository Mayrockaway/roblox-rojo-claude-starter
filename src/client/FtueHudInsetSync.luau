--!strict
--- FTUE overlays / pointer ScreenGuis must match **`HUD.IgnoreGuiInset`** or scale-based positions
--- sit in a different viewport (safe-area vs full screen) and look misaligned next to HUD.
--- Modal `ScreenGuis` pointed at during FTUE (e.g. Ship Oil) must use the **same** inset as the pointer layer
--- (`FTUEDialogueGui`) or authored `UDim2` positions will not line up in play vs devices with safe areas.

local FtueHudInsetSync = {}

function FtueHudInsetSync.start(playerGui: PlayerGui)
	local function syncFtueOverlayInsetWithHud()
		local hud = playerGui:FindFirstChild("HUD", true)
		if not (hud and hud:IsA("ScreenGui")) then
			return
		end
		local inset = hud.IgnoreGuiInset
		-- FTUE pointers live under `Canvas.Pointers` inside `FTUEDialogueGui` (not separate top-level ScreenGuis).
		for _, n in ipairs({
			"FTUEDialogueGui",
			"FtueDialogueGui",
			"ShipOilPanelGui",
			"SellOilPanelGui",
		}) do
			local sg = playerGui:FindFirstChild(n, true)
			if sg and sg:IsA("ScreenGui") then
				sg.IgnoreGuiInset = inset
			end
		end
	end

	task.defer(syncFtueOverlayInsetWithHud)
	task.spawn(function()
		for _ = 1, 120 do
			syncFtueOverlayInsetWithHud()
			local hud = playerGui:FindFirstChild("HUD", true)
			if hud and hud:IsA("ScreenGui") then
				break
			end
			task.wait(0.25)
		end
	end)
	playerGui.ChildAdded:Connect(function(ch)
		if ch:IsA("ScreenGui") then
			task.defer(syncFtueOverlayInsetWithHud)
		end
	end)
end

return FtueHudInsetSync
