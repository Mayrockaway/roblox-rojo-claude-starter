--!strict
-- Sell-back prompts are created on the server (`OilVisualService`). Only the plot owner should see them enabled;
-- activation (hold E) is handled by `ProximityPrompt.Triggered` on the server — no client FireServer path.

local Players = game:GetService("Players")

local SELL_BACK_PROMPT = "SellBackPrompt"
local hooked: { [ProximityPrompt]: boolean } = {}

local function syncPromptOwnership(prompt: ProximityPrompt)
	local lp = Players.LocalPlayer
	local owner = prompt:GetAttribute("OwnerUserId")
	prompt.Enabled = typeof(owner) == "number" and owner == lp.UserId
end

local function hookPrompt(prompt: ProximityPrompt)
	if prompt.Name ~= SELL_BACK_PROMPT or hooked[prompt] then
		return
	end
	hooked[prompt] = true
	syncPromptOwnership(prompt)
	prompt:GetAttributeChangedSignal("OwnerUserId"):Connect(function()
		syncPromptOwnership(prompt)
	end)
end

local function scan(inst: Instance)
	if inst:IsA("ProximityPrompt") then
		hookPrompt(inst)
	end
	for _, d in ipairs(inst:GetDescendants()) do
		if d:IsA("ProximityPrompt") then
			hookPrompt(d)
		end
	end
end

task.defer(function()
	local map = workspace:FindFirstChild("Map")
	if map then
		scan(map)
	end
end)

workspace.DescendantAdded:Connect(function(inst)
	if inst:IsA("ProximityPrompt") and inst.Name == SELL_BACK_PROMPT then
		hookPrompt(inst)
	end
end)
