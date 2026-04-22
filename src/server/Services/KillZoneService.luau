--!strict

-- Large non-colliding volume under the map: any player character that touches it dies (Health = 0).

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Constants"))
local DevLog = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("DevLog"))
local Telemetry = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Telemetry"))

local KillZoneService = {}

-- SPEC §6.3 / §13 PR 6 — `player_died` fires from BOTH this service
-- (`cause = "killzone"`) and a `Humanoid.Died` listener wired below
-- (`cause = "unknown"` for falls / lava / future hazards). Kill zones
-- already kill the humanoid, so without dedup we'd fire the event twice
-- per kill-zone death. The first emit stamps a Humanoid attribute
-- `TelemetryDeathEmitted`; the `Humanoid.Died` listener early-returns
-- when the flag is set.
local DEATH_EMIT_ATTR = "TelemetryDeathEmitted"

function KillZoneService:Init()
	self._running = false
	self._touchConn = nil :: RBXScriptConnection?
	self._folder = nil :: Folder?
	self._connections = {} :: { RBXScriptConnection }
end

function KillZoneService:Start()
	if self._running then
		return
	end
	self._running = true

	local map = Workspace:WaitForChild("Map", 20) or Workspace

	local folder = Instance.new("Folder")
	folder.Name = "ServerKillZones"
	folder.Parent = map

	local half = Constants.KillZoneUnderMapHorizontalHalfExtent
	local thick = Constants.KillZoneUnderMapThicknessY
	local cy = Constants.KillZoneUnderMapCenterY

	local zone = Instance.new("Part")
	zone.Name = "UnderMapKillZone"
	zone.Anchored = true
	zone.CanCollide = false
	zone.CanQuery = false
	zone.CanTouch = true
	zone.Transparency = 1
	zone.Size = Vector3.new(half * 2, thick, half * 2)
	zone.CFrame = CFrame.new(0, cy, 0)
	zone.Parent = folder

	self._folder = folder

	self._touchConn = zone.Touched:Connect(function(hit: BasePart)
		if not hit then
			return
		end
		local model = hit:FindFirstAncestorOfClass("Model")
		if not model then
			return
		end
		local player = Players:GetPlayerFromCharacter(model)
		if not player then
			return
		end
		local hum = model:FindFirstChildOfClass("Humanoid")
		if not hum or hum.Health <= 0 then
			return
		end
		--- DIAG: log every kill plane hit. The under-map kill plane is supposed
		--- to fire ONCE per fall — if you see this fire repeatedly for the same
		--- player in <5s windows, the death loop is server-side (character
		--- keeps respawning, falling, and re-entering the kill plane) rather
		--- than a client-only visual artifact.
		local hrp = model:FindFirstChild("HumanoidRootPart")
		local pos = if hrp and hrp:IsA("BasePart") then hrp.Position else Vector3.zero
		local vel = if hrp and hrp:IsA("BasePart") then hrp.AssemblyLinearVelocity else Vector3.zero
		DevLog.log(string.format(
			"[KillZone] %s entered kill plane pos=(%.1f,%.1f,%.1f) vel=(%.1f,%.1f,%.1f) seatPart=%s",
			player.Name, pos.X, pos.Y, pos.Z, vel.X, vel.Y, vel.Z,
			tostring(hum.SeatPart and hum.SeatPart:GetFullName() or "nil")
		))
		-- Telemetry §6.3 `player_died` (kill-zone path). Stamp the
		-- Humanoid attribute BEFORE setting Health=0 so the
		-- `Humanoid.Died` listener (which fires synchronously from the
		-- health write below in the same frame) sees the flag and skips.
		if not hum:GetAttribute(DEATH_EMIT_ATTR) then
			hum:SetAttribute(DEATH_EMIT_ATTR, true)
			pcall(function()
				Telemetry.Track(player, "player_died", {
					cause = "killzone",
					position = { x = pos.X, y = pos.Y, z = pos.Z },
				})
			end)
		end
		hum.Health = 0
	end)

	-- Catch-all `Humanoid.Died` listener for non-kill-zone deaths (falls,
	-- lava, future hazards). Each character gets its own connection
	-- attached on `CharacterAdded`; the dedup attribute prevents a
	-- double-emit when KillZoneService already fired above.
	local function bindCharacter(player: Player, character: Model)
		local hum = character:FindFirstChildOfClass("Humanoid")
			or character:WaitForChild("Humanoid", 5)
		if not hum or not hum:IsA("Humanoid") then
			return
		end
		hum.Died:Connect(function()
			if hum:GetAttribute(DEATH_EMIT_ATTR) then
				return
			end
			hum:SetAttribute(DEATH_EMIT_ATTR, true)
			local hrp = character:FindFirstChild("HumanoidRootPart")
			local pos = if hrp and hrp:IsA("BasePart") then hrp.Position else Vector3.zero
			pcall(function()
				Telemetry.Track(player, "player_died", {
					cause = "unknown",
					position = { x = pos.X, y = pos.Y, z = pos.Z },
				})
			end)
		end)
	end

	local function bindPlayer(player: Player)
		table.insert(self._connections, player.CharacterAdded:Connect(function(character)
			bindCharacter(player, character)
		end))
		if player.Character then
			task.spawn(bindCharacter, player, player.Character)
		end
	end

	table.insert(self._connections, Players.PlayerAdded:Connect(bindPlayer))
	for _, p in ipairs(Players:GetPlayers()) do
		bindPlayer(p)
	end
end

function KillZoneService:Stop()
	self._running = false
	if self._touchConn then
		self._touchConn:Disconnect()
		self._touchConn = nil
	end
	if self._folder then
		self._folder:Destroy()
		self._folder = nil
	end
	if self._connections then
		for _, c in ipairs(self._connections) do
			c:Disconnect()
		end
		self._connections = {}
	end
end

return KillZoneService
