--!strict
-- Single source of truth for the named "event voice line" clips that play in
-- response to gameplay state changes (strait status flip, shipment outcome,
-- random event start, etc.). Sounds live under
-- `ReplicatedStorage.Assets.SFX.VoiceLines.<soundName>` (Studio-authored,
-- routed through `SoundService.EventVoice` SoundGroup) so designers can swap
-- audio without editing code.
--
-- Caller contract (`EventVoiceQueue.play(key)`):
--   * `key` is the LOGICAL identifier (left column below).
--   * The queue resolves `key` → `Defs[key].soundName` → Sound instance.
--   * If the Sound instance is missing, the queue silently no-ops (so a key
--     can be registered before the audio is uploaded — see `USShipSlap`).
--
-- Adding a new voice line:
--   1. Author the Sound under `ReplicatedStorage.Assets.SFX.VoiceLines` in
--      Studio with the `EventVoice` SoundGroup.
--   2. Add a row to `EventVoiceLines.Defs` with the right priority.
--   3. Call `EventVoiceQueue.play("YourKey")` from the gameplay system that
--      should trigger it.

export type Priority = "Critical" | "Normal" | "Low"

export type VoiceLineDef = {
	--- Logical key callers use (`EventVoiceQueue.play("Pirates")`).
	key: string,
	--- Name of the Sound instance under `Assets.SFX.VoiceLines`. Often equal
	--- to `key` but kept separate so renames in Studio don't force callsite
	--- churn (e.g. `Nuke` → `TacNuke`).
	soundName: string,
	priority: Priority,
}

local EventVoiceLines = {}

-- Pre-baked queue policy per priority bucket. The queue reads these instead
-- of hardcoding numbers, so tuning lives next to the registry.
EventVoiceLines.PriorityPolicy = {
	Critical = {
		preempts = true,    -- cuts off a Normal/Low currently playing
		maxQueueAgeSeconds = math.huge, -- never drop critical for being old
	},
	Normal = {
		preempts = false,
		maxQueueAgeSeconds = 8,
	},
	Low = {
		preempts = false,
		maxQueueAgeSeconds = 4,
	},
}

EventVoiceLines.Defs = {
	-- Critical: must-hear; preempt the current line.
	-- `USShipSlap` is the catalog id for the "Sea Monster" event
	-- (`Catalog.Events` row, displayName = "Sea Monster"). Voice asset has not
	-- been uploaded yet — registered now so the gameplay wiring can land
	-- without code churn the day the file ships.
	USShipSlap    = { key = "USShipSlap",    soundName = "SeaMonster",      priority = "Critical" },
	ShipDestroyed = { key = "ShipDestroyed", soundName = "ShipDestroyed",   priority = "Critical" },
	Nuke          = { key = "Nuke",          soundName = "TacNuke",         priority = "Critical" },

	-- Normal: queue in arrival order.
	StraitOpen       = { key = "StraitOpen",       soundName = "StraitOpen",       priority = "Normal" },
	StraitClosed     = { key = "StraitClosed",     soundName = "StraitClosed",     priority = "Normal" },
	StraitRestricted = { key = "StraitRestricted", soundName = "StraitRestricted", priority = "Normal" },
	DeliverySuccess  = { key = "DeliverySuccess",  soundName = "DeliverySuccess",  priority = "Normal" },
	DeliveryOk       = { key = "DeliveryOk",       soundName = "DeliveryOk",       priority = "Normal" },
	Pirates          = { key = "Pirates",          soundName = "Pirates",          priority = "Normal" },
	Coastguard       = { key = "Coastguard",       soundName = "Coastguard",       priority = "Normal" },
	Missiles         = { key = "Missiles",         soundName = "MissileStrike",    priority = "Normal" },
	Mines            = { key = "Mines",            soundName = "Mines",            priority = "Normal" },
	Airstrike        = { key = "Airstrike",        soundName = "Airstrike",        priority = "Normal" },
	Storm            = { key = "Storm",            soundName = "Storm",            priority = "Normal" },
	Tornado          = { key = "Tornado",          soundName = "Tornado",          priority = "Normal" },
	Paperwork        = { key = "Paperwork",        soundName = "Paperwork",        priority = "Normal" },
	--- "Engine room smoke" generic StraitWaypoint event. Distinct voice file
	--- from `Paperwork` so the two minor-event slots are audibly different
	--- (previously both routed to `Paperwork`). Sound asset lives at
	--- `ReplicatedStorage.Assets.SFX.VoiceLines.EngineRoomSmoke`
	--- (`SoundId = rbxassetid://117439392997255`, authored via MCP).
	EngineRoomSmoke  = { key = "EngineRoomSmoke",  soundName = "EngineRoomSmoke",  priority = "Normal" },

	-- Low: nice-to-have; first to age out under load.
	JoinGame         = { key = "JoinGame",         soundName = "JoinGame",         priority = "Low" },
} :: { [string]: VoiceLineDef }

function EventVoiceLines.Get(key: string): VoiceLineDef?
	return EventVoiceLines.Defs[key]
end

--- Reverse-lookup: given the underlying Sound's name (the value that was
--- historically passed to `playEventSFX("ShipDestroyed")`), return the
--- registered voice def. Used by `init.client.playEventSFX` to auto-route
--- legacy callsites through the serial `EventVoiceQueue` instead of the
--- old fire-and-forget direct play. Built lazily and cached on first use.
local _byName: { [string]: VoiceLineDef }? = nil
function EventVoiceLines.GetByName(soundName: string): VoiceLineDef?
	if _byName == nil then
		local t: { [string]: VoiceLineDef } = {}
		for _, def in pairs(EventVoiceLines.Defs) do
			t[def.soundName] = def
		end
		_byName = t
	end
	return _byName[soundName]
end

return EventVoiceLines
