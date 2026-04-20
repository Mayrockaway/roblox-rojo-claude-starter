--!strict
-- Binds `HUD.Canvas.ActiveManifestPanel` loaded cargo rows: tier labels use **`QualityConfig.hudShortName`**.
-- Studio row names: **`LoadedRow_Crude`**, **`LoadedRow_Refined`**, **`LoadedRow_Premium`** (top → bottom).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local QualityConfig = require(Shared:WaitForChild("Config"):WaitForChild("QualityConfig"))

--- `ActiveManifestPanel` `LoadedSection.SectionBody` child `Frame` name → server manifest / oil tier key.
local LOADED_ROW_TO_TIER: { [string]: string } = {
	LoadedRow_Crude = "Crude",
	LoadedRow_Refined = "Refined",
	LoadedRow_Premium = "Premium",
}

local ATTR = "OilHudShortLabelsApplied"

local function findHud(playerGui: PlayerGui): ScreenGui?
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

local function applyLoadedRow(row: Instance)
	local tier = LOADED_ROW_TO_TIER[row.Name]
	if not tier then
		return
	end
	local oil = row:FindFirstChild("OilName")
	if oil and oil:IsA("TextLabel") then
		oil.Text = QualityConfig.hudShortLabel(tier)
	end
end

local ActiveManifestHud = {}

function ActiveManifestHud.tryBind(playerGui: PlayerGui)
	local hud = findHud(playerGui)
	local canvas = hud and hud:FindFirstChild("Canvas")
	local panel = canvas and canvas:FindFirstChild("ActiveManifestPanel")
	if not (panel and panel:IsA("GuiObject")) then
		return
	end
	if panel:GetAttribute(ATTR) == true then
		return
	end
	local loaded = panel:FindFirstChild("LoadedSection")
	local body = loaded and loaded:FindFirstChild("SectionBody")
	if not (body and body:IsA("Instance")) then
		return
	end
	for _, ch in ipairs(body:GetChildren()) do
		applyLoadedRow(ch)
	end
	panel:SetAttribute(ATTR, true)
end

return ActiveManifestHud
