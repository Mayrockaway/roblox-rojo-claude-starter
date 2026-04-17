-- Run via Studio MCP `execute_luau` (or Command Bar) to verify FTUE pointer roots + HUD wiring.
-- Expects `StarterGui.FTUEDialogueGui.Canvas.Pointers` and named `*PointerRoot` / inner `*Pointer` pairs.

local EXPECTED_ROOTS = {
	"ShipOilPointerRoot",
	"ShipBarrelPointerRoot",
	"DispatchPointerRoot",
	"StraitPointerRoot",
	"SellOilPointerRoot",
	"SellBarrelPointerRoot",
	"SellButtonPointerRoot",
	"OilPricePointerRoot",
}

local function report(title: string, msg: string)
	print("[" .. title .. "] " .. msg)
end

local sgNames = { "FTUEDialogueGui", "FtueDialogueGui" }
local dialogue: ScreenGui? = nil
for _, n in ipairs(sgNames) do
	local x = game:GetService("StarterGui"):FindFirstChild(n)
	if x and x:IsA("ScreenGui") then
		dialogue = x
		report("FOUND", n .. " under StarterGui")
		break
	end
end
if not dialogue then
	report("MISS", "No FTUEDialogueGui / FtueDialogueGui in StarterGui")
else
local canvas = dialogue:FindFirstChild("Canvas") or dialogue:FindFirstChild("canvas")
if not canvas then
	report("MISS", "Dialogue has no Canvas")
else
local ptr = canvas:FindFirstChild("Pointers") or canvas:FindFirstChild("pointers")
if not ptr then
	report("MISS", "Canvas has no Pointers folder")
else
report("OK", "Canvas.Pointers exists (" .. ptr.ClassName .. ")")

for _, name in ipairs(EXPECTED_ROOTS) do
	local fr = ptr:FindFirstChild(name)
	if fr and fr:IsA("GuiObject") then
		local innerName = name:gsub("Root$", "")
		local child = fr:FindFirstChild(innerName)
		local ok = child and child:IsA("GuiObject")
		local visInner = ok and (child :: GuiObject).Visible
		report(
			fr.Visible and "VIS" or "HID",
			name
				.. " | inner "
				.. innerName
				.. " = "
				.. (ok and child:GetFullName() or "MISSING")
				.. (ok and (" | innerVisible=" .. tostring(visInner)) or "")
		)
	else
		report("MISS", "Pointer root not found: " .. name)
	end
end

end
end
end

local hud = game:GetService("StarterGui"):FindFirstChild("HUD")
if hud and hud:IsA("ScreenGui") then
	local function findBtn(nm: string): GuiButton?
		local b = hud:FindFirstChild(nm, true)
		return b and b:IsA("GuiButton") and b or nil
	end
	for _, nm in ipairs({ "ShipOilButton", "SellOilButton", "ShopButton", "ManageShipButton" }) do
		local b = findBtn(nm)
		report(b and "HUD" or "HUD?", nm .. " = " .. (b and b:GetFullName() or "NOT FOUND"))
	end
else
	report("MISS", "StarterGui.HUD ScreenGui not found")
end

-- Modal-hosted pointers (preferred for alignment with cargo / dispatch CTA):
local ship = game:GetService("StarterGui"):FindFirstChild("ShipOilPanelGui")
if ship and ship:IsA("ScreenGui") then
	for _, name in ipairs({ "ShipBarrelPointerRoot", "DispatchPointerRoot" }) do
		local fr = ship:FindFirstChild(name, true)
		if fr and fr:IsA("GuiObject") then
			report("SHIP", name .. " under ShipOilPanelGui → " .. fr:GetFullName())
		else
			report("SHIP?", name .. " not under ShipOilPanelGui (optional; else uses FTUEDialogueGui.Canvas.Pointers)")
		end
	end
end
local sell = game:GetService("StarterGui"):FindFirstChild("SellOilPanelGui")
if sell and sell:IsA("ScreenGui") then
	for _, name in ipairs({ "SellBarrelPointerRoot", "SellButtonPointerRoot" }) do
		local fr = sell:FindFirstChild(name, true)
		if fr and fr:IsA("GuiObject") then
			report("SELL", name .. " under SellOilPanelGui → " .. fr:GetFullName())
		else
			report("SELL?", name .. " not under SellOilPanelGui (optional)")
		end
	end
end
