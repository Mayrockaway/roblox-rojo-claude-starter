--!strict
-- Single-channel serial queue for the named event voice clips registered in
-- `shared/Audio/EventVoiceLines`. Guarantees that two voice lines never play
-- on top of each other when concurrent gameplay events fire (e.g. a Pirate
-- raid begins on the same frame the strait flips to Closed).
--
-- Policy summary (per `EventVoiceLines.PriorityPolicy`):
--   * Critical → preempts the currently playing line; jumps the head of the
--     pending list. Never aged out.
--   * Normal   → queued FIFO; dropped if it has waited more than ~8s by the
--     time its turn comes up (gameplay context has moved on).
--   * Low      → queued FIFO behind Normal; dropped after ~4s wait.
--
-- Other behaviors:
--   * Sound resolution: looks up `Sound` instance by `def.soundName` under
--     `ReplicatedStorage.Assets.SFX.VoiceLines`. Missing instance = silent
--     no-op (lets us register a key before the audio file ships — e.g. the
--     `USShipSlap` "Sea Monster" line).
--   * Per-key dedup: `play(key)` is rejected when the same key is currently
--     playing OR already at the head of the pending list.
--   * SFX preference gate: respects `ClientAudioPreferences.isSfxEnabled`.
--   * SoundGroup: every cloned Sound is routed through
--     `SoundService.EventVoice` (already authored via MCP) so a future "voice
--     volume" slider has a single knob.
--
-- Caller surface:
--   * `EventVoiceQueue.start()`              — bind once from `init.client`.
--   * `EventVoiceQueue.play(key, opts?)`     — enqueue (returns true if accepted).
--   * `EventVoiceQueue.stop()`               — silence current + clear pending.
--   * `EventVoiceQueue.isPlaying(): boolean` — diagnostic.
--
-- This module ONLY plays clips; it does not hook into game events itself.
-- Each gameplay system that fires a voice line calls `play(key)` from its
-- existing client-side handler (see `StraitStatusChangeFx.trigger` for the
-- worked example).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local ClientAudioPreferences = require(script.Parent:WaitForChild("ClientAudioPreferences"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local EventVoiceLines = require(Shared:WaitForChild("Audio"):WaitForChild("EventVoiceLines"))

type Priority = EventVoiceLines.Priority
type VoiceLineDef = EventVoiceLines.VoiceLineDef

export type PlayOpts = {
	--- Default true. When true, reject the request if the same key is already
	--- playing or already next in line.
	dedup: boolean?,
}

type PendingItem = {
	def: VoiceLineDef,
	enqueuedAt: number,
}

local VOICE_FOLDER_PATH = { "Assets", "SFX", "VoiceLines" }

local EventVoiceQueue = {}

local started = false
local pending: { PendingItem } = {}
local current: Sound? = nil
local currentDef: VoiceLineDef? = nil
local voiceFolder: Folder? = nil
local soundGroup: SoundGroup? = nil

--- Lazy-resolve the `VoiceLines` folder. We don't `WaitForChild` from module
--- top-level because `init.client` must be allowed to keep booting if the
--- audio assets haven't synced yet — we just no-op until they appear.
local function getVoiceFolder(): Folder?
	if voiceFolder and voiceFolder.Parent then
		return voiceFolder
	end
	local node: Instance? = ReplicatedStorage
	for _, name in ipairs(VOICE_FOLDER_PATH) do
		if not node then return nil end
		node = node:FindFirstChild(name)
	end
	if node and node:IsA("Folder") then
		voiceFolder = node :: Folder
		return voiceFolder
	end
	return nil
end

local function getSoundGroup(): SoundGroup?
	if soundGroup and soundGroup.Parent then
		return soundGroup
	end
	local g = SoundService:FindFirstChild("EventVoice")
	if g and g:IsA("SoundGroup") then
		soundGroup = g :: SoundGroup
		return soundGroup
	end
	return nil
end

local function findTemplate(soundName: string): Sound?
	local folder = getVoiceFolder()
	if not folder then return nil end
	local s = folder:FindFirstChild(soundName)
	if s and s:IsA("Sound") then
		return s :: Sound
	end
	return nil
end

local function isOldEnoughToDrop(item: PendingItem, now: number): boolean
	local policy = EventVoiceLines.PriorityPolicy[item.def.priority]
	if not policy then return false end
	local maxAge = policy.maxQueueAgeSeconds
	if maxAge == math.huge then return false end
	return (now - item.enqueuedAt) > maxAge
end

local function pruneStale()
	local now = os.clock()
	local kept: { PendingItem } = {}
	for _, item in ipairs(pending) do
		if not isOldEnoughToDrop(item, now) then
			table.insert(kept, item)
		end
	end
	pending = kept
end

--- Forward declaration so `playNext` and `stopCurrent` can call each other.
local playNext

local function clearCurrent()
	local s = current
	current = nil
	currentDef = nil
	if s then
		pcall(function() s:Stop() end)
		s:Destroy()
	end
end

playNext = function()
	if current then return end -- something is already playing
	pruneStale()
	local item = table.remove(pending, 1)
	if not item then return end

	if not ClientAudioPreferences.isSfxEnabled() then
		return -- silent gate; no need to recurse, queue stays empty
	end

	local template = findTemplate(item.def.soundName)
	if not template then
		-- Asset missing for this key (e.g. SeaMonster not uploaded yet).
		-- Treat as no-op and keep draining the queue.
		playNext()
		return
	end

	local s = template:Clone()
	s.Name = "EventVoice_" .. item.def.key
	s.Looped = false
	s.Playing = false
	local group = getSoundGroup()
	if group then s.SoundGroup = group end
	s.Parent = SoundService
	current = s
	currentDef = item.def

	s.Ended:Once(function()
		if current == s then
			clearCurrent()
			playNext()
		else
			s:Destroy()
		end
	end)
	-- `Stopped` fires on preempt path (we call s:Stop()); chain into next item.
	s.Stopped:Once(function()
		if current == s then
			clearCurrent()
			playNext()
		end
	end)

	pcall(function() s.TimePosition = 0 end)
	s:Play()
end

local function isQueuedOrPlaying(key: string): boolean
	if currentDef and currentDef.key == key then return true end
	local headItem = pending[1]
	if headItem and headItem.def.key == key then return true end
	return false
end

--- Return true if `def` should preempt whatever is currently playing.
local function shouldPreempt(def: VoiceLineDef): boolean
	if not current or not currentDef then return false end
	local incomingPolicy = EventVoiceLines.PriorityPolicy[def.priority]
	if not incomingPolicy or not incomingPolicy.preempts then return false end
	-- Don't preempt another Critical — let it finish (rare; FIFO within bucket).
	return currentDef.priority ~= "Critical"
end

local function priorityRank(p: Priority): number
	if p == "Critical" then return 0 end
	if p == "Normal" then return 1 end
	return 2
end

--- Insert `item` into `pending` at the right position by priority. FIFO
--- within the same bucket; Critical jumps to the front (after any other
--- already-pending Critical), Normal sits before any Low, Low appends.
local function enqueueByPriority(item: PendingItem)
	local rank = priorityRank(item.def.priority)
	for i, existing in ipairs(pending) do
		if priorityRank(existing.def.priority) > rank then
			table.insert(pending, i, item)
			return
		end
	end
	table.insert(pending, item)
end

--- Public: enqueue a voice line by its registered key.
--- Returns true if the request was accepted (currently playing or queued).
function EventVoiceQueue.play(key: string, opts: PlayOpts?): boolean
	if not started then return false end
	local def = EventVoiceLines.Get(key)
	if not def then
		warn("[EventVoiceQueue] unknown key: " .. tostring(key))
		return false
	end
	if not ClientAudioPreferences.isSfxEnabled() then return false end

	local dedup = opts == nil or opts.dedup ~= false
	if dedup and isQueuedOrPlaying(key) then
		return false
	end

	if shouldPreempt(def) then
		-- Push the new item to the front, then stop current — its `Stopped`
		-- handler will drain the queue and pick our item up.
		table.insert(pending, 1, { def = def, enqueuedAt = os.clock() })
		local s = current
		current = nil
		currentDef = nil
		if s then
			pcall(function() s:Stop() end)
			-- s:Destroy is handled by the Stopped:Once → clearCurrent path,
			-- but we've already nilled `current` so guard against re-entry:
			task.defer(function()
				if s and s.Parent then s:Destroy() end
			end)
		end
		playNext()
		return true
	end

	enqueueByPriority({ def = def, enqueuedAt = os.clock() })
	if not current then
		playNext()
	end
	return true
end

function EventVoiceQueue.stop()
	pending = {}
	clearCurrent()
end

function EventVoiceQueue.isPlaying(): boolean
	return current ~= nil
end

function EventVoiceQueue.start()
	if started then return end
	started = true
	-- Warm up the folder + group references so first play() has them ready.
	getVoiceFolder()
	getSoundGroup()
end

return EventVoiceQueue
