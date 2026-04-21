--!strict
-- `Remotes.shipmentVisualEvent` — strait waypoint FX, HUD status, delivery SFX, playtest banner (owner-only).
-- Wired from `init.client` with injected deps (no god-script globals).
--
-- HUD status policy (intentional after the 2026 cleanup):
--   * `setStatus` writes here are **owner-only**. Spectator chatter
--     ("Pirates spotted raiding a vessel nearby!") was removed because the
--     `Hint` line under `ShipmentProgressPanel` is reserved for the local
--     player's own ship — see `src/client/UI/ShipmentProgressHud.luau` and
--     `src/client/UI/HintLineState.luau`.
--   * `StraitWaypointEvent` does not write to the Hint at all — the strait
--     event playtest banner already handles that path.
--   * `MissileStrikeEvent` is consolidated into a single barrage outcome line
--     (worst-of all missiles in the barrage). For "ship destroyed" outcomes
--     we suppress the line entirely because `ShipmentResolved` with
--     `failureReason` already writes "Shipment lost…" with the matching FX
--     in `ShipmentProgressHud`.

local StraitEventPlaytestBanner = require(script.Parent:WaitForChild("UI"):WaitForChild("StraitEventPlaytestBanner"))

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StraitEventCatalog = require(
	ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("StraitEvents"):WaitForChild("Catalog")
)

export type StraitWaypointFxCallbacks = {
	OnStraitWaypointPayload: (data: { [string]: any }) -> (),
	OnMissileStrikePayload: (data: { [string]: any }) -> (),
	OnMineStrikePayload: (data: { [string]: any }) -> (),
	OnPirateRaidPayload: (data: { [string]: any }) -> (),
	OnCoastGuardInspectionPayload: (data: { [string]: any }) -> (),
	OnUSShipSlapPayload: (data: { [string]: any }) -> (),
	OnStormPayload: (data: { [string]: any }) -> (),
	OnTornadoPayload: (data: { [string]: any }) -> (),
}

export type ShipmentVisualDeps = {
	player: Player,
	playerGui: PlayerGui,
	straitWaypointFx: StraitWaypointFxCallbacks,
	setStatus: (message: string, ok: boolean?) -> (),
	playEventSFX: (sfxName: string, volume: number?) -> (),
}

local STRAIT_PLAYTEST_BANNER_KINDS: { [string]: boolean } = {
	StraitWaypointEvent = true,
	PirateRaidEvent = true,
	CoastGuardInspectionEvent = true,
	USShipSlapEvent = true,
	StormEvent = true,
	TornadoEvent = true,
	MineStrikeEvent = true,
	MissileStrikeEvent = true,
}

local function showStraitPlaytestBannerIfNeeded(
	player: Player,
	playerGui: PlayerGui,
	kind: string,
	data: { [string]: any }
)
	if not STRAIT_PLAYTEST_BANNER_KINDS[kind] then
		return
	end
	-- ShipmentVisualEvent is FireAllClients; show the large playtest title only to the ship owner.
	local ownerUid = data.ownerUserId or data.playerUserId
	if typeof(ownerUid) ~= "number" or ownerUid ~= player.UserId then
		return
	end
	if kind == "MissileStrikeEvent" then
		local idx = tonumber(data.missileIndex) or 1
		if idx ~= 1 then
			return
		end
	end
	local title = if typeof(data.playtestTitle) == "string" and data.playtestTitle ~= ""
		then data.playtestTitle
		elseif typeof(data.displayName) == "string" then data.displayName
		else nil
	if typeof(title) == "string" and title ~= "" then
		StraitEventPlaytestBanner.show(playerGui, title)
	end
end

--- Missile barrages fire a `MissileStrikeEvent` per missile (idx 1..N). The
--- barrage's true outcome is the **worst** outcome across all of them — but
--- we only know that after the last missile lands. To consolidate we:
---   * latch on `missileIndex == 1` and accumulate the worst outcome rank as
---     each subsequent missile event arrives,
---   * schedule a single `setStatus` after the full barrage hint window has
---     elapsed (`MissileConfig.MissileCount` × stagger + flight + pause),
---   * suppress the line entirely when the worst outcome is `"hit"` because
---     `ShipmentResolved` with `failureReason` already paints the destruction
---     line in `ShipmentProgressHud` (with matching shake / pulse).
local MISSILE_OUTCOME_RANK: { [string]: number } = { miss = 0, smallHit = 1, hit = 2 }
local missileBarrageWorstRank: number? = nil
local missileBarrageScheduled: boolean = false

local function missileBarrageHintSeconds(): number
	local m = StraitEventCatalog.MissileConfig
	local n = math.max(1, m.MissileCount)
	return (n - 1) * m.BarrageStagger + m.FlightSeconds + (m.BarragePauseAfter or 2)
end

local function handleOwnerMissileBarrageOutcome(
	data: { [string]: any },
	outcome: string,
	setStatus: (message: string, ok: boolean?) -> (),
	playEventSFX: (string, number?) -> ()
)
	local idx = tonumber(data.missileIndex) or 1
	local rank = MISSILE_OUTCOME_RANK[outcome] or 0
	if idx == 1 then
		missileBarrageWorstRank = rank
	elseif missileBarrageWorstRank ~= nil then
		missileBarrageWorstRank = math.max(missileBarrageWorstRank, rank)
	else
		missileBarrageWorstRank = rank
	end

	if idx ~= 1 or missileBarrageScheduled then
		return
	end
	missileBarrageScheduled = true
	local waitSeconds = missileBarrageHintSeconds() + 0.1
	task.delay(waitSeconds, function()
		missileBarrageScheduled = false
		local worst = missileBarrageWorstRank
		missileBarrageWorstRank = nil
		if worst == nil then
			return
		end
		if worst == 2 then
			-- Ship destroyed: play the destruction SFX (visual cinematic ends
			-- around now), but suppress the Hint text — `ShipmentResolved`
			-- with `failureReason` writes "Shipment lost…" + heavy FX in
			-- `ShipmentProgressHud`.
			playEventSFX("ShipDestroyed")
			return
		end
		if worst == 1 then
			setStatus("MISSILE BARRAGE — Barrels lost!", false)
		else
			setStatus("Missile barrage missed!", true)
		end
	end)
end

local ShipmentVisualClient = {}

function ShipmentVisualClient.connect(deps: ShipmentVisualDeps, shipmentVisualEvent: RemoteEvent): RBXScriptConnection
	local player = deps.player
	local playerGui = deps.playerGui
	local StraitWaypointWorldFx = deps.straitWaypointFx
	local setStatus = deps.setStatus
	local playEventSFX = deps.playEventSFX

	return shipmentVisualEvent.OnClientEvent:Connect(function(packet)
		if typeof(packet) ~= "table" then
			return
		end
		local kind = packet.type
		local data = packet.data
		if typeof(data) ~= "table" then
			return
		end

		showStraitPlaytestBannerIfNeeded(player, playerGui, kind, data)

		if kind == "PirateRaidEvent" then
			StraitWaypointWorldFx.OnPirateRaidPayload(data)
			local isOwner = data.ownerUserId == player.UserId
			if not isOwner then
				return
			end
			playEventSFX("Pirates")
			local stolen = tonumber(data.barrelsStolen) or 0
			setStatus(string.format("PIRATES BOARDING! Lost %d barrels!", stolen), false)
			return
		end

		if kind == "CoastGuardInspectionEvent" then
			StraitWaypointWorldFx.OnCoastGuardInspectionPayload(data)
			local isOwner = data.ownerUserId == player.UserId
			if not isOwner then
				return
			end
			playEventSFX("Coastguard")
			setStatus("Coast guard boarding. Inspection in progress.", false)
			return
		end

		if kind == "USShipSlapEvent" then
			StraitWaypointWorldFx.OnUSShipSlapPayload(data)
			local isOwner = data.ownerUserId == player.UserId
			if not isOwner then
				return
			end
			-- ShipDestroyed SFX is handled inside the kraken FX (plays after kraken audio ends)
			setStatus("SEA MONSTER! Your ship is under attack!", false)
			return
		end

		if kind == "StormEvent" then
			StraitWaypointWorldFx.OnStormPayload(data)
			local isOwner = data.ownerUserId == player.UserId
			if not isOwner then
				return
			end
			playEventSFX("Storm")
			local didDelay = data.didDelay == true and (tonumber(data.delaySeconds) or 0) > 0
			local lost = math.max(0, tonumber(data.barrelsLost) or 0)
			local didLoss = data.didBarrelLoss == true and lost > 0
			if didDelay and didLoss then
				setStatus(string.format("STORM: delayed %.1fs and lost %d barrels.", tonumber(data.delaySeconds) or 0, lost), false)
			elseif didDelay then
				setStatus(string.format("STORM: heavy weather delay (%.1fs).", tonumber(data.delaySeconds) or 0), false)
			elseif didLoss then
				setStatus(string.format("STORM: cargo washed overboard (-%d barrels).", lost), false)
			else
				setStatus("STORM: rough weather, no major loss.", true)
			end
			return
		end

		if kind == "TornadoEvent" then
			StraitWaypointWorldFx.OnTornadoPayload(data)
			local isOwner = data.ownerUserId == player.UserId
			if not isOwner then
				return
			end
			playEventSFX("Tornado")
			local didDelay = data.didDelay == true and (tonumber(data.delaySeconds) or 0) > 0
			local lost = math.max(0, tonumber(data.barrelsLost) or 0)
			local didLoss = data.didBarrelLoss == true and lost > 0
			if didDelay and didLoss then
				setStatus(string.format("TORNADO: delayed %.1fs and lost %d barrels.", tonumber(data.delaySeconds) or 0, lost), false)
			elseif didDelay then
				setStatus(string.format("TORNADO: route disruption delay (%.1fs).", tonumber(data.delaySeconds) or 0), false)
			elseif didLoss then
				setStatus(string.format("TORNADO: barrels torn loose (-%d).", lost), false)
			else
				setStatus("TORNADO: near miss, shipment survived.", true)
			end
			return
		end

		if kind == "MineStrikeEvent" then
			StraitWaypointWorldFx.OnMineStrikePayload(data)
			local isOwner = data.ownerUserId == player.UserId
			if not isOwner then
				return
			end
			playEventSFX("Mines")
			if data.didHit then
				-- "Ship destroyed" line is suppressed; `ShipmentResolved` with
				-- `failureReason` writes "Shipment lost…" with shake/pulse FX
				-- in `ShipmentProgressHud`. We still play the ShipDestroyed SFX
				-- after the visual cinematic so it lines up with the explosion.
				task.delay(4, function()
					playEventSFX("ShipDestroyed")
				end)
			else
				setStatus("Mines spotted! Navigating through...", true)
			end
			return
		end

		if kind == "MissileStrikeEvent" then
			StraitWaypointWorldFx.OnMissileStrikePayload(data)
			local isOwner = data.ownerUserId == player.UserId
			if not isOwner then
				return
			end
			local outcome = tostring(data.outcome or "")
			if outcome == "hit" or outcome == "smallHit" then
				playEventSFX("MissileStrike")
			end
			handleOwnerMissileBarrageOutcome(data, outcome, setStatus, playEventSFX)
			return
		end

		if kind == "StraitWaypointEvent" then
			-- World FX + playtest banner only — the strait banner shows the
			-- event name / severity / outcome; no need to duplicate it on the
			-- Hint line. Keep the SFX side effects.
			StraitWaypointWorldFx.OnStraitWaypointPayload(data)
			local isOwner = data.ownerUserId == player.UserId
			if not isOwner then
				return
			end
			--- Distinct voice file per minor event so the two minor-event slots
			--- are audibly different (used to share `Paperwork`). The
			--- `EngineRoomSmoke` Sound is authored via MCP at
			--- `ReplicatedStorage.Assets.SFX.VoiceLines.EngineRoomSmoke`.
			if data.eventId == "RoutinePaperwork" then
				playEventSFX("Paperwork")
			elseif data.eventId == "EngineRoomSmoke" then
				playEventSFX("EngineRoomSmoke")
			end
			if data.totalLoss then
				task.delay(4, function()
					playEventSFX("ShipDestroyed")
				end)
			end
			return
		end

		if data.ownerUserId ~= player.UserId then
			return
		end

		if kind == "ShipmentStarted" then
			local shipLabel = if typeof(data.shipDisplayName) == "string" and (data :: any).shipDisplayName ~= ""
				then (data :: any).shipDisplayName
				else tostring((data :: any).shipSkinId or (data :: any).boatTypeId or "Ship")
			setStatus(string.format("Shipment out: %s (%d barrels)", shipLabel, tonumber(data.loaded) or 0), true)
		elseif kind == "ShipmentResolved" then
			local delivered = tonumber(data.delivered) or 0
			local lost = tonumber(data.lost) or 0
			local totalLoss = delivered == 0 and lost == 0
			if not totalLoss then
				setStatus(
					string.format(
						"Shipment done. %d barrels delivered to warehouse (%d lost). Sell at market for cash.",
						delivered,
						lost
					),
					true
				)
				if lost == 0 then
					playEventSFX("DeliverySuccess")
				else
					playEventSFX("DeliveryOk")
				end
			end
		end
	end)
end

return ShipmentVisualClient
