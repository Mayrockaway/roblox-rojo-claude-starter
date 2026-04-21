--!strict
-- Random NPC voice one-shots on ProximityPrompt activation (started from `init.client` after
-- `ClientAudioPreferences.init` so SFX state is correct). Voice content is now
-- warmed by the loading pipeline, so prompt activation itself stays lightweight.

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

--- Panels opened from inanimate vendor surfaces (terminals, kiosks, machines) that are NOT
--- voiced NPCs. Prompts that target these panels via the `OpensPanel` attribute fall through
--- the NPC-name allow list above and would otherwise hit the generic `OpensPanel` voice
--- fallback at the bottom of `start()` — this set blocks that fallback so we don't play
--- character barks for a desk/monitor interaction (e.g. warehouse `SellOilPrompt`).
local SUPPRESSED_PANEL_NAMES: { [string]: boolean } = {
	SellOilPanelGui = true,
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

	s.Ended:Once(function()
		if s.Parent then
			s:Destroy()
		end
	end)
	pcall(function()
		s.TimePosition = 0
	end)
	s:Play()
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
		if typeof(opens) == "string" and opens ~= "" and not SUPPRESSED_PANEL_NAMES[opens] then
			playRandomVoice()
		end
	end)
end

return NpcProximityVoice
