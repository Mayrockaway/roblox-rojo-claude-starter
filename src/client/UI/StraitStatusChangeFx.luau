--!strict

-- Cinematic when the strait state changes: strait-colored skybox, announcement text, horn.

-- Open: no strait sky — restore authored Lighting skies only.

-- Restricted / Closed: `StraitSky` stays until the next rotation; Open clears it and restores authored skies.

--

-- **Color** comes from the six skybox face assets on `Sky_Restricted` / `Sky_Closed` (clone onto default sky),

-- not from ColorCorrection. For stronger saturation, edit those template Sky instances in Studio (face IDs).

-- Sun/moon **textures** stay from the player's current default sky; strait templates only drive the cube faces.



local TweenService = game:GetService("TweenService")

local SoundService = game:GetService("SoundService")

local Lighting = game:GetService("Lighting")

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Debris = game:GetService("Debris")

--- Single-channel serial queue for the named event voice clips
--- (`Pirates`, `StraitClosed`, `Coastguard`, …). Lives at
--- `StarterPlayerScripts.Client.EventVoiceQueue` (mounted by
--- `default.project.json` `StarterPlayer.StarterPlayerScripts.Client → src/client`).
--- Required lazily inside `trigger` so the require error doesn't take the
--- whole strait status banner down if the queue module hasn't synced yet.
local function tryRequireEventVoiceQueue()
	local ok, mod = pcall(function()
		local clientFolder = script.Parent.Parent
		return require(clientFolder:WaitForChild("EventVoiceQueue", 5)) :: any
	end)
	if ok then return mod end
	return nil
end

--- Strait state → registered voice key in `shared/Audio/EventVoiceLines`.
--- Kept tiny and local so a future copy-rename doesn't drag the whole queue
--- registry into a UI module.
local STATE_VOICE_KEY: { [string]: string } = {
	Open = "StraitOpen",
	Closed = "StraitClosed",
	Restricted = "StraitRestricted",
}



local StraitStatusChangeFx = {}



local COLOR_FOR_STATE: { [string]: Color3 } = {

	Open = Color3.fromRGB(70, 220, 90),

	Restricted = Color3.fromRGB(255, 210, 60),

	Closed = Color3.fromRGB(255, 60, 60),

}



local SKYBOX_SOURCE_NAME: { [string]: string } = {

	Restricted = "Sky_Restricted",

	Closed = "Sky_Closed",

}

local SKYBOX_FOLDER_NAME = "StraitSkyboxes"

--- Optional: set `StraitDefaultBaseSky = true` on exactly one `Sky` under Lighting so strait merges use that instance as the clone base (sun/moon + non-face defaults).
local DEFAULT_STRAIT_BASE_SKY_ATTR = "StraitDefaultBaseSky"

--- If the attribute is unset, we pick the first matching **Name** among held skies (author your main sky as one of these, or use the attribute).
local DEFAULT_SKY_NAME_PRIORITY: { string } = {
	"Default",
	"MainSky",
	"Sky",
	"GameSky",
}

local HORN_SOUND_ID = "rbxassetid://9114145977"



local SEQUENCE_DUR = 3.0

local FADE_IN_DUR = 0.4

local HOLD_DUR = 1.8

local FADE_OUT_DUR = SEQUENCE_DUR - FADE_IN_DUR - HOLD_DUR



local activeToken = 0



--- Skies pulled from Lighting while Restricted/Closed StraitSky is active (not parented).

local heldAuthorSkiesPersistent: { Instance }? = nil



local function destroyStraitSkyClone()

	local x = Lighting:FindFirstChild("StraitSky")

	if x then

		x:Destroy()

	end

end



local function pullAllSkiesFromLighting(): { Instance }

	local t = {}

	for _, c in ipairs(Lighting:GetChildren()) do

		if c:IsA("Sky") then

			c.Parent = nil

			table.insert(t, c)

		end

	end

	return t

end



local function restorePersistentHeldSkies()

	if heldAuthorSkiesPersistent then

		for _, s in ipairs(heldAuthorSkiesPersistent) do

			if s.Parent == nil then

				s.Parent = Lighting

			end

		end

		heldAuthorSkiesPersistent = nil

	end

end



local function getStraitSkyboxesFolder(): Instance?

	return ReplicatedStorage:FindFirstChild(SKYBOX_FOLDER_NAME)

end



local function getSkyTemplate(state: string): Sky?

	local srcName = SKYBOX_SOURCE_NAME[state]

	if not srcName then

		return nil

	end

	local folder = getStraitSkyboxesFolder()

	if not folder then

		return nil

	end

	local source = folder:FindFirstChild(srcName)

	if source and source:IsA("Sky") then

		return source

	end

	return nil

end



local function collectSkiesInHeld(held: { Instance }): { Sky }

	local out: { Sky } = {}

	for _, s in ipairs(held) do

		if s:IsA("Sky") then

			table.insert(out, s)

		end

	end

	return out

end

--- Which authored `Sky` to clone for `StraitSky` (sun/moon textures, etc.). Never uses `StraitSky`.

local function pickDefaultSkyForStraitBase(held: { Instance }): Sky?

	local skies = collectSkiesInHeld(held)

	if #skies == 0 then

		return nil

	end

	local tagged: { Sky } = {}

	for _, sky in ipairs(skies) do

		if sky.Name ~= "StraitSky" and sky:GetAttribute(DEFAULT_STRAIT_BASE_SKY_ATTR) == true then

			table.insert(tagged, sky)

		end

	end

	if #tagged == 1 then

		return tagged[1]

	elseif #tagged > 1 then

		warn("[StraitStatusChangeFx] Multiple Lighting Skies have StraitDefaultBaseSky=true; using first: ", tagged[1]:GetFullName())

		return tagged[1]

	end

	for _, prefName in ipairs(DEFAULT_SKY_NAME_PRIORITY) do

		for _, sky in ipairs(skies) do

			if sky.Name == prefName and sky.Name ~= "StraitSky" then

				return sky

			end

		end

	end

	local nonStrait: { Sky } = {}

	for _, sky in ipairs(skies) do

		if sky.Name ~= "StraitSky" then

			table.insert(nonStrait, sky)

		end

	end

	local pool = if #nonStrait > 0 then nonStrait else skies

	table.sort(pool, function(a, b)

		return a.Name < b.Name

	end)

	return pool[1]

end



--- Orange / red strait look: copy six skybox face Content IDs from strait templates (saturated in asset).

local SKYBOX_FACE_PROP_NAMES: { string } = {

	"SkyboxBk",

	"SkyboxDn",

	"SkyboxFt",

	"SkyboxLf",

	"SkyboxRt",

	"SkyboxUp",

}



local function applyStraitSkyboxFacesFromTemplate(out: Sky, straitTemplate: Sky)

	for _, prop in ipairs(SKYBOX_FACE_PROP_NAMES) do

		pcall(function()

			(out :: any)[prop] = (straitTemplate :: any)[prop]

		end)

	end

end



--- Non-face props from strait template (orientation, celestial, sizes).

local STRAIT_SKY_OVERLAY_PROP_NAMES: { string } = {

	"SkyboxOrientation",

	"CelestialBodiesShown",

	"SunAngularSize",

	"MoonAngularSize",

	"StarCount",

}



local function applyStraitSkyTemplateOverlayOntoDefaultClone(out: Sky, straitTemplate: Sky)

	for _, prop in ipairs(STRAIT_SKY_OVERLAY_PROP_NAMES) do

		pcall(function()

			(out :: any)[prop] = (straitTemplate :: any)[prop]

		end)

	end

end



--- Default sky clone + strait **skybox faces** from template + overlay; sun/moon **images** from default base.

local function buildStraitSkyFromDefaultAndTemplate(held: { Instance }, straitTemplate: Sky): Sky?

	local base = pickDefaultSkyForStraitBase(held)

	if not base then

		return nil

	end

	local out = base:Clone()

	out.Name = "StraitSky"

	applyStraitSkyboxFacesFromTemplate(out, straitTemplate)

	pcall(function()

		out.SunTextureId = base.SunTextureId

		out.MoonTextureId = base.MoonTextureId

	end)

	applyStraitSkyTemplateOverlayOntoDefaultClone(out, straitTemplate)

	return out

end



local function ensureScreenGui(playerGui: PlayerGui): ScreenGui

	local existing = playerGui:FindFirstChild("StraitStatusChangeFx")

	if existing and existing:IsA("ScreenGui") then

		return existing

	end

	local sg = Instance.new("ScreenGui")

	sg.Name = "StraitStatusChangeFx"

	sg.IgnoreGuiInset = true

	sg.ResetOnSpawn = false

	sg.DisplayOrder = 500

	sg.Parent = playerGui

	return sg

end



--- `customText` (optional) overrides the default "THE STRAIT IS NOW X" copy.
--- Used by `triggerForceLock` so the same banner / skybox / horn pipeline can
--- announce a Robux force-open / force-close with player attribution without
--- duplicating the FX setup. Skybox + color still come from `newState` so the
--- atmosphere matches what the strait is *now*, just the headline changes.
function StraitStatusChangeFx.trigger(playerGui: PlayerGui, newState: string, customText: string?)

	local color = COLOR_FOR_STATE[newState] or Color3.fromRGB(200, 200, 200)



	activeToken += 1

	local myToken = activeToken



	destroyStraitSkyClone()



	if newState == "Open" then

		restorePersistentHeldSkies()

	else

		local template = getSkyTemplate(newState)

		if template then

			if heldAuthorSkiesPersistent == nil then

				heldAuthorSkiesPersistent = pullAllSkiesFromLighting()

			end

			local held = heldAuthorSkiesPersistent

			if held then

				local merged = buildStraitSkyFromDefaultAndTemplate(held, template)

				if merged then

					merged.Parent = Lighting

				else

					local cloned = template:Clone()

					cloned.Name = "StraitSky"

					cloned.Parent = Lighting

				end

			end

		end

	end



	local sg = ensureScreenGui(playerGui)

	for _, c in ipairs(sg:GetChildren()) do

		c:Destroy()

	end



	local label = Instance.new("TextLabel")

	label.Name = "Announce"

	label.Size = UDim2.fromScale(0.9, 0.25)

	label.Position = UDim2.fromScale(0.05, 0.38)

	label.BackgroundTransparency = 1

	label.Text = customText or string.format("THE STRAIT IS NOW %s", string.upper(newState))

	label.Font = Enum.Font.Merriweather

	label.TextScaled = true

	-- Readability swap (test, may revert): paint the glyph fill in the strait
	-- status color (green / orange / red) and outline in **black** instead of
	-- white-on-status-color. White text wrapped in a status-tinted `UIStroke`
	-- below was washing the headline out, especially against `Sky_Restricted`
	-- and `Sky_Closed` which are themselves orange / red.
	label.TextColor3 = color

	label.TextStrokeColor3 = Color3.new(0, 0, 0)

	label.TextStrokeTransparency = 0

	label.TextTransparency = 1

	label.ZIndex = 2

	label.Parent = sg



	local stroke = Instance.new("UIStroke")

	stroke.Thickness = 5

	stroke.Color = Color3.new(0, 0, 0)

	stroke.Transparency = 1

	stroke.Parent = label



	local horn = Instance.new("Sound")

	horn.Name = "StraitHorn"

	horn.SoundId = HORN_SOUND_ID

	horn.Volume = 1.4

	horn.Parent = SoundService

	horn:Play()

	Debris:AddItem(horn, 6)

	--- Voice line for the new state ("Strait is now open / closed / restricted").
	--- Goes through the serial `EventVoiceQueue` so it never overlaps with a
	--- voice fired from a concurrent gameplay event (e.g. a Pirate raid
	--- spawning on the same trigger). The horn above is a non-voice SFX and
	--- intentionally NOT routed through the queue — the queue only serializes
	--- voice clips per the design.
	local voiceKey = STATE_VOICE_KEY[newState]
	if voiceKey then
		local queue = tryRequireEventVoiceQueue()
		if queue then
			queue.play(voiceKey)
		end
	end



	TweenService:Create(label, TweenInfo.new(FADE_IN_DUR, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {

		TextTransparency = 0,

		TextStrokeTransparency = 0,

	}):Play()

	TweenService:Create(stroke, TweenInfo.new(FADE_IN_DUR), { Transparency = 0 }):Play()



	task.delay(FADE_IN_DUR + HOLD_DUR, function()

		if myToken ~= activeToken then

			return

		end

		TweenService:Create(label, TweenInfo.new(FADE_OUT_DUR, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {

			TextTransparency = 1,

			TextStrokeTransparency = 1,

		}):Play()

		TweenService:Create(stroke, TweenInfo.new(FADE_OUT_DUR), { Transparency = 1 }):Play()

	end)



	task.delay(SEQUENCE_DUR + 0.15, function()

		if myToken ~= activeToken then

			return

		end

		if label and label.Parent then

			label:Destroy()

		end

	end)

end



--- Repurposed announcement banner for Robux force-open / force-close
--- (`MonetizationCatalog` consumables `strait_open_2min` / `strait_close_2min`
--- → `StraitStateService:ForceStateForDuration`). Same banner + horn + skybox
--- swap as a normal state rotation, but the headline is the player attribution
--- string requested by the product owner: "<NAME> HAS OPENED THE STRAIT FOR
--- 2 MINUTES!".
---
--- Driver is `StraitMarketHudClient` — it watches `globalStateUpdate` for a new
--- `forceLock.version` and calls this *instead of* `trigger` so we do not
--- stack two banners on top of each other (the activeToken in `trigger` would
--- otherwise cancel the first one mid-fade).
---
--- `byName` is `nil` when the buyer left between purchase and receipt replay;
--- we fall back to "A Player" so the banner still reads as a player action
--- rather than a system event.
function StraitStatusChangeFx.triggerForceLock(playerGui: PlayerGui, state: string, byName: string?, _durationSeconds: number)
	local verb = if state == "Open" then "OPENED" else "CLOSED"
	local who = (byName ~= nil and byName ~= "") and byName or "A PLAYER"
	-- Hard-coded "2 MINUTES" copy matches the marketed product name in
	-- `MonetizationCatalog.luau`. If `Constants.StraitForceLockSeconds` ever
	-- diverges from 120 we should derive the suffix from `_durationSeconds`
	-- here so the banner stays truthful.
	local text = string.format("%s HAS %s THE STRAIT FOR 2 MINUTES!", string.upper(who), verb)
	StraitStatusChangeFx.trigger(playerGui, state, text)
end

return StraitStatusChangeFx

