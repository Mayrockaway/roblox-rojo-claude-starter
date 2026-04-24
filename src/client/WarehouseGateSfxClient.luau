--!strict
-- Listens for `WarehouseGateLocalSfx` (server → owner only) and plays gate
-- open/close one-shots under `CurrentCamera` so audio is **not** spatial /
-- world-replicated to other players.

local Workspace = game:GetService("Workspace")

local ClientAudioPreferences = require(script.Parent:WaitForChild("ClientAudioPreferences"))

-- Matches `WarehouseTemplate.Gate.Open` / `Gate.Close` in Studio.
local OPEN_ID = "rbxassetid://4416840411"
local CLOSE_ID = "rbxassetid://9116673944"
local VOLUME = 0.275

local started = false

local function playOneShot(assetId: string)
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	local snd = Instance.new("Sound")
	snd.SoundId = assetId
	snd.Volume = VOLUME
	snd.Parent = cam
	task.defer(function()
		if not snd.Parent then
			return
		end
		if not snd.IsLoaded then
			pcall(function()
				snd.Loaded:Wait()
			end)
		end
		if snd.Parent then
			snd:Play()
		end
		snd.Ended:Once(function()
			snd:Destroy()
		end)
	end)
end

local WarehouseGateSfxClient = {}

function WarehouseGateSfxClient.start(remotes: { warehouseGateLocalSfx: RemoteEvent })
	if started then
		return
	end
	started = true

	remotes.warehouseGateLocalSfx.OnClientEvent:Connect(function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		if not ClientAudioPreferences.isSfxEnabled() then
			return
		end
		local kind = payload.kind
		if kind == "open" then
			playOneShot(OPEN_ID)
		elseif kind == "close" then
			playOneShot(CLOSE_ID)
		end
	end)
end

return WarehouseGateSfxClient
