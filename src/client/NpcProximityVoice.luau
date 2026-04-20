--!strict
-- Random NPC voice one-shots on ProximityPrompt activation (started from `init.client` after
-- `ClientAudioPreferences.init` so SFX state is correct). Uses preload — `Sound:Play()` on
-- unloaded assets often produces silence.

local ContentProvider = game:GetService("ContentProvider")
local ProximityPromptService = game:GetService("ProximityPromptService")
local SoundService = game:GetService("SoundService")
local Players = game:GetService("Players")

local ClientAudioPreferences = require(script.Parent:WaitForChild("ClientAudioPreferences"))

local OPENS_PANEL_ATTR = "OpensPanel"

--- Explicit allow list: dialogue prompts (no `OpensPanel`) plus equipment shop NPCs (e.g.
--- `Workspace.DocksShop.ShopTable.DrillShopMan.HumanoidRootPart.EquipmentShopPrompt`) and the
--- Boatman ship-manage prompt — name match is the belt-and-suspenders for any prompt where the
--- `OpensPanel` attribute might drift.
local NPC_PROMPT_NAMES: { [string]: boolean } = {
	OilmanDialoguePrompt = true,
	PirateHirePrompt = true,
	ArmyGeneralPrompt = true,
	DeliveryManPrompt = true,
	EquipmentShopPrompt = true,
	ManageShipPrompt = true,
}

local VOICE_IDS = {
	"rbxassetid://89531954562344",
	"rbxassetid://90371105771118",
	"rbxassetid://138131180590743",
	"rbxassetid://79816242917775",
	"rbxassetid://97435698809776",
	"rbxassetid://118898048174911",
	"rbxassetid://119794938028444",
}

local rng = Random.new()
local localPlayer = Players.LocalPlayer
local started = false

local function playRandomVoice()
	if not ClientAudioPreferences.isSfxEnabled() then
		return
	end
	local id = VOICE_IDS[rng:NextInteger(1, #VOICE_IDS)]
	local s = Instance.new("Sound")
	s.Name = "NpcProximityVoice"
	s.SoundId = id
	s.Volume = 0.75
	s.Looped = false
	s.RollOffMode = Enum.RollOffMode.Linear
	s.Parent = SoundService

	task.defer(function()
		pcall(function()
			ContentProvider:PreloadAsync({ s })
		end)
		if not s.Parent then
			return
		end
		s.Ended:Once(function()
			if s.Parent then
				s:Destroy()
			end
		end)
		pcall(function()
			s.TimePosition = 0
		end)
		s:Play()
	end)
end

local NpcProximityVoice = {}

function NpcProximityVoice.start()
	if started then
		return
	end
	started = true

	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, who: Player)
		if who ~= localPlayer then
			return
		end
		if NPC_PROMPT_NAMES[prompt.Name] == true then
			playRandomVoice()
			return
		end
		--- Any prompt authored to open a panel (`OpensPanel = "<ScreenGuiName>"`) is treated as a
		--- vendor / NPC interaction — covers DrillShopMan (`ShopPanelGui`), Boatman (`ShipManagementPanelGui`),
		--- and any future shop NPC without needing to add its prompt name above.
		local opens = prompt:GetAttribute(OPENS_PANEL_ATTR)
		if typeof(opens) == "string" and opens ~= "" then
			playRandomVoice()
		end
	end)
end

return NpcProximityVoice
