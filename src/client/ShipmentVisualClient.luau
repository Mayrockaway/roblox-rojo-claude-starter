--!strict
-- `Remotes.shipmentVisualEvent` — strait waypoint FX, HUD status, delivery SFX, playtest banner (owner-only).
-- Wired from `init.client` with injected deps (no god-script globals).

local StraitEventPlaytestBanner = require(script.Parent:WaitForChild("UI"):WaitForChild("StraitEventPlaytestBanner"))

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
			if isOwner then
				playEventSFX("Pirates")
			end
			local stolen = tonumber(data.barrelsStolen) or 0
			if isOwner then
				setStatus(string.format("PIRATES BOARDING! Lost %d barrels!", stolen), false)
			else
				setStatus("Pirates spotted raiding a vessel nearby!", true)
			end
			return
		end

		if kind == "CoastGuardInspectionEvent" then
			StraitWaypointWorldFx.OnCoastGuardInspectionPayload(data)
			local isOwner = data.ownerUserId == player.UserId
			if isOwner then
				playEventSFX("Coastguard")
			end
			if isOwner then
				setStatus("Coast guard boarding. Inspection in progress.", false)
			else
				setStatus("Coast guard vessel spotted inspecting a nearby ship.", true)
			end
			return
		end

		if kind == "USShipSlapEvent" then
			StraitWaypointWorldFx.OnUSShipSlapPayload(data)
			local isOwner = data.ownerUserId == player.UserId
			if isOwner then
				setStatus("SEA MONSTER! Your ship is under attack!", false)
				-- ShipDestroyed SFX is handled inside the kraken FX (plays after kraken audio ends)
			else
				setStatus("A sea monster just attacked a nearby ship!", true)
			end
			return
		end

		if kind == "StormEvent" then
			StraitWaypointWorldFx.OnStormPayload(data)
			local isOwner = data.ownerUserId == player.UserId
			if isOwner then
				playEventSFX("Storm")
			end
			local didDelay = data.didDelay == true and (tonumber(data.delaySeconds) or 0) > 0
			local lost = math.max(0, tonumber(data.barrelsLost) or 0)
			local didLoss = data.didBarrelLoss == true and lost > 0
			if isOwner then
				if didDelay and didLoss then
					setStatus(string.format("STORM: delayed %.1fs and lost %d barrels.", tonumber(data.delaySeconds) or 0, lost), false)
				elseif didDelay then
					setStatus(string.format("STORM: heavy weather delay (%.1fs).", tonumber(data.delaySeconds) or 0), false)
				elseif didLoss then
					setStatus(string.format("STORM: cargo washed overboard (-%d barrels).", lost), false)
				else
					setStatus("STORM: rough weather, no major loss.", true)
				end
			else
				setStatus("A thunderstorm hit a nearby vessel.", true)
			end
			return
		end

		if kind == "TornadoEvent" then
			StraitWaypointWorldFx.OnTornadoPayload(data)
			local isOwner = data.ownerUserId == player.UserId
			if isOwner then
				playEventSFX("Tornado")
			end
			local didDelay = data.didDelay == true and (tonumber(data.delaySeconds) or 0) > 0
			local lost = math.max(0, tonumber(data.barrelsLost) or 0)
			local didLoss = data.didBarrelLoss == true and lost > 0
			if isOwner then
				if didDelay and didLoss then
					setStatus(string.format("TORNADO: delayed %.1fs and lost %d barrels.", tonumber(data.delaySeconds) or 0, lost), false)
				elseif didDelay then
					setStatus(string.format("TORNADO: route disruption delay (%.1fs).", tonumber(data.delaySeconds) or 0), false)
				elseif didLoss then
					setStatus(string.format("TORNADO: barrels torn loose (-%d).", lost), false)
				else
					setStatus("TORNADO: near miss, shipment survived.", true)
				end
			else
				setStatus("A tornado is tearing through a nearby shipment lane.", false)
			end
			return
		end

		if kind == "MineStrikeEvent" then
			StraitWaypointWorldFx.OnMineStrikePayload(data)
			local isOwner = data.ownerUserId == player.UserId
			if isOwner then
				playEventSFX("Mines")
			end
			if data.didHit then
				if isOwner then
					task.delay(4, function()
						setStatus("MINE HIT — Ship destroyed!", false)
					end)
					task.delay(4, function()
						playEventSFX("ShipDestroyed")
					end)
				else
					setStatus("A vessel struck a mine!", false)
				end
			else
				setStatus(isOwner and "Mines spotted! Navigating through..." or "Mines surfaced near a vessel!", true)
			end
			return
		end

		if kind == "MissileStrikeEvent" then
			StraitWaypointWorldFx.OnMissileStrikePayload(data)
			local isOwner = data.ownerUserId == player.UserId
			local outcome = tostring(data.outcome or "")
			if isOwner and (outcome == "hit" or outcome == "smallHit") then
				playEventSFX("MissileStrike")
			end
			if outcome == "hit" then
				if isOwner then
					task.delay(4, function()
						setStatus("MISSILE STRIKE — Ship destroyed!", false)
					end)
					task.delay(4, function()
						playEventSFX("ShipDestroyed")
					end)
				else
					setStatus("A vessel was destroyed by a missile!", false)
				end
			elseif outcome == "smallHit" then
				setStatus(isOwner and "MISSILE NEAR HIT — Barrels lost!" or "A missile grazed a vessel nearby!", false)
			else
				setStatus(isOwner and "Missile missed!" or "A missile splashed near a vessel.", true)
			end
			return
		end

		if kind == "StraitWaypointEvent" then
			StraitWaypointWorldFx.OnStraitWaypointPayload(data)
			local name = tostring(data.displayName or data.eventId or "Strait event")
			local sev = tostring(data.severity or "?")
			local isOwner = data.ownerUserId == player.UserId
			if isOwner and (data.eventId == "RoutinePaperwork" or data.eventId == "EngineRoomSmoke") then
				playEventSFX("Paperwork")
			end
			if data.totalLoss then
				if isOwner then
					task.delay(4, function()
						setStatus(string.format("STRAIT: %s (%s) — shipment lost", name, sev), false)
						playEventSFX("ShipDestroyed")
					end)
				else
					setStatus(string.format("Strait: another vessel lost cargo (%s)", sev), false)
				end
			else
				local lost = tonumber(data.barrelsLost) or 0
				local extra = lost > 0 and string.format(" — lost %d barrel(s), %d left", lost, tonumber(data.totalLoaded) or 0) or ""
				setStatus(
					isOwner and string.format("STRAIT: %s (%s)%s", name, sev, extra)
						or string.format("Strait: event on another shipment (%s)", sev),
					true
				)
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
