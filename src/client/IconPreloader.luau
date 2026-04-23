--!strict
-- Pre-warms `ContentProvider` with every icon URI the player will see in
-- common UI surfaces (hotbar slots, equipment shop cards, ship management /
-- select-ship cards). Without this the first frame each panel is opened can
-- show an empty grey square for ~half a second while the asset is fetched.
--
-- All catalog ids are normalized through `toImageUri` so Decal-uploaded ids
-- (the default for Studio's image upload path) get converted to a
-- `rbxthumb://` URI that always renders. This is the same conversion
-- `EquipmentShopPopulate` and `EquipmentHotbarController` use at display
-- time, so we are warming exactly the URIs the UI will request.
--
-- Runs once per client login, in a background thread, so a slow CDN never
-- blocks gameplay startup.

local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SharedConfig = Shared:WaitForChild("Config")
local EquipmentCatalog = require(SharedConfig:WaitForChild("EquipmentCatalog"))
local BoatCatalog = require(SharedConfig:WaitForChild("BoatCatalog"))

local IconPreloader = {}

local started = false

--- Convert a catalog asset id (`rbxassetid://N`, bare number, or already a
--- `rbxthumb://` / `rbxasset://` / `http*` URI) into a URI that
--- `ImageLabel.Image` will reliably render. See `EquipmentShopPopulate.luau`
--- for the same conversion -- duplicated here (rather than imported) to keep
--- this preloader free of UI-module dependencies.
local function toImageUri(raw: string?): string?
	if typeof(raw) ~= "string" or raw == "" then
		return nil
	end
	if raw:match("^rbxthumb://") or raw:match("^rbxasset://") or raw:match("^http") then
		return raw
	end
	local id = raw:match("rbxassetid://(%d+)") or raw:match("^(%d+)$")
	if id then
		return string.format("rbxthumb://type=Asset&id=%s&w=150&h=150", id)
	end
	return raw
end

local function collectUris(): { string }
	local seen: { [string]: boolean } = {}
	local out: { string } = {}

	local function add(raw: string?)
		local uri = toImageUri(raw)
		if uri and not seen[uri] then
			seen[uri] = true
			table.insert(out, uri)
		end
	end

	for _, row in pairs(EquipmentCatalog.ITEMS) do
		add((row :: any).iconAssetId)
	end

	for _, boat in pairs(BoatCatalog.Boats) do
		add((boat :: any).icon)
	end

	return out
end

--- Build temporary `ImageLabel` instances with `Image` set and pass them to
--- `ContentProvider:PreloadAsync`. Passing instances (rather than raw URI
--- strings) lets the engine resolve `rbxthumb://` URIs the same way the
--- displaying `ImageLabel` will, which is the format we actually need
--- cached. The temp instances are parented to a hidden `Folder` and torn
--- down when the call returns.
function IconPreloader.start()
	if started then
		return
	end
	started = true

	task.spawn(function()
		local uris = collectUris()
		if #uris == 0 then
			return
		end

		local holder = Instance.new("Folder")
		holder.Name = "IconPreloadHolder"
		holder.Parent = ReplicatedStorage

		local labels: { ImageLabel } = {}
		for _, uri in ipairs(uris) do
			local lbl = Instance.new("ImageLabel")
			lbl.Name = "Preload"
			lbl.Image = uri
			lbl.Visible = false
			lbl.Parent = holder
			table.insert(labels, lbl)
		end

		local ok, err = pcall(function()
			ContentProvider:PreloadAsync(labels)
		end)
		if not ok then
			warn("[IconPreloader] PreloadAsync failed: " .. tostring(err))
		end

		holder:Destroy()
	end)
end

return IconPreloader
