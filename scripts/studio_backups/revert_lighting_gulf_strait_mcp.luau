-- Paste the entire file into Roblox Studio MCP `execute_luau` to restore Lighting
-- from `lighting_before_gulf_strait_preset.json` (saved when the Gulf preset was applied).

local HttpService = game:GetService("HttpService")
local Lighting = game:GetService("Lighting")

local json = [===[{"colorCorrection":{"Enabled":true,"Saturation":0.10000000149011612,"Contrast":0.10000000149011612,"TintColor":{"b":0.7686275243759155,"g":0.9411765336990356,"_t":"C3","r":1},"Brightness":0},"lighting":{"ExposureCompensation":0,"ColorShift_Bottom":{"b":0,"g":0,"_t":"C3","r":0},"FogColor":{"b":0.7529411911964417,"g":0.7529411911964417,"_t":"C3","r":0.7529411911964417},"FogEnd":100000,"FogStart":0,"EnvironmentDiffuseScale":1,"EnvironmentSpecularScale":0.4000000059604645,"ShadowSoftness":0.5,"GeographicLatitude":41.733299255371097,"Ambient":{"b":0.27450981736183169,"g":0.27450981736183169,"_t":"C3","r":0.27450981736183169},"OutdoorAmbient":{"b":0.8823529481887817,"g":1,"_t":"C3","r":0.8666666746139526},"GlobalShadows":true,"Brightness":1,"ColorShift_Top":{"b":0,"g":0,"_t":"C3","r":0},"ClockTime":7},"bloom":{"Threshold":2,"Enabled":true,"Intensity":0.5,"Size":24},"sunrays":null,"atmosphere":{"Density":0.21400000154972077,"Haze":0.0010000000474974514,"Color":{"b":1,"g":1,"_t":"C3","r":1},"Decay":{"b":0.14901961386203767,"g":0.32156863808631899,"_t":"C3","r":0.38823533058166506},"Glare":0.800000011920929,"Offset":0.125}}]===]

local function c3(t)
	return Color3.new(t.r, t.g, t.b)
end

local snap = HttpService:JSONDecode(json)

for name, v in pairs(snap.lighting) do
	if typeof(v) == "table" and v._t == "C3" then
		Lighting[name] = c3(v)
	elseif typeof(v) == "number" or typeof(v) == "boolean" then
		Lighting[name] = v
	end
end

local atm = Lighting:FindFirstChildOfClass("Atmosphere")
if snap.atmosphere then
	if not atm then
		atm = Instance.new("Atmosphere")
		atm.Parent = Lighting
	end
	local a = snap.atmosphere
	atm.Density = a.Density
	atm.Offset = a.Offset
	atm.Color = c3(a.Color)
	atm.Decay = c3(a.Decay)
	atm.Glare = a.Glare
	atm.Haze = a.Haze
elseif atm then
	atm:Destroy()
end

local bloom = Lighting:FindFirstChildOfClass("BloomEffect")
if snap.bloom then
	if not bloom then
		bloom = Instance.new("BloomEffect")
		bloom.Parent = Lighting
	end
	local b = snap.bloom
	bloom.Enabled = b.Enabled
	bloom.Intensity = b.Intensity
	bloom.Size = b.Size
	bloom.Threshold = b.Threshold
elseif bloom then
	bloom:Destroy()
end

local cc = Lighting:FindFirstChildOfClass("ColorCorrectionEffect")
if snap.colorCorrection then
	if not cc then
		cc = Instance.new("ColorCorrectionEffect")
		cc.Parent = Lighting
	end
	local c = snap.colorCorrection
	cc.Enabled = c.Enabled
	cc.Brightness = c.Brightness
	cc.Contrast = c.Contrast
	cc.Saturation = c.Saturation
	cc.TintColor = c3(c.TintColor)
elseif cc then
	cc:Destroy()
end

if snap.sunrays == nil then
	for _, child in ipairs(Lighting:GetChildren()) do
		if child:IsA("SunRaysEffect") then
			child:Destroy()
		end
	end
else
	local sr = Lighting:FindFirstChildOfClass("SunRaysEffect")
	if not sr then
		sr = Instance.new("SunRaysEffect")
		sr.Parent = Lighting
	end
	local s = snap.sunrays
	sr.Enabled = s.Enabled
	sr.Intensity = s.Intensity
	sr.Spread = s.Spread
end

return "Lighting reverted from backup (see scripts/studio_backups/lighting_before_gulf_strait_preset.json)"
