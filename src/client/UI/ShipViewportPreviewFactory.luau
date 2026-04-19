--!strict
-- Ultra-light hull proxies for ship `ViewportFrame`s (`ShipManagementPanel`, `SelectShipPopulate`).
-- Full gameplay hulls are often Union-heavy; see **`ShipManagementUiConfig.UseGameplayHullInViewport`**.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ShipManagementUiConfig = require(Shared:WaitForChild("Config"):WaitForChild("ShipManagementUiConfig"))

local HULL_BY_TEMPLATE: { [string]: Vector3 } = {
	Tanker = Vector3.new(6, 2.2, 18),
	Ship3 = Vector3.new(5.5, 2.2, 15),
	Ship4 = Vector3.new(6, 2.3, 16),
	Ship5 = Vector3.new(6.5, 2.4, 17),
	Whale = Vector3.new(8, 3, 22),
}

local COLOR_BY_TEMPLATE: { [string]: Color3 } = {
	Tanker = Color3.fromRGB(110, 118, 128),
	Ship3 = Color3.fromRGB(120, 100, 90),
	Ship4 = Color3.fromRGB(95, 105, 120),
	Ship5 = Color3.fromRGB(130, 120, 95),
	Whale = Color3.fromRGB(70, 85, 110),
}

local archetypes: { [string]: Model } = {}

local ShipViewportPreviewFactory = {}

function ShipViewportPreviewFactory.getArchetype(templateName: string): Model
	local existing = archetypes[templateName]
	if existing and existing.Parent == nil then
		return existing
	end
	local hullSize = HULL_BY_TEMPLATE[templateName] or Vector3.new(6, 2.2, 16)
	local color = COLOR_BY_TEMPLATE[templateName] or Color3.fromRGB(105, 110, 118)

	local m = Instance.new("Model")
	m.Name = "ViewportPreview_" .. templateName
	m:SetAttribute("IsViewportPreviewProxy", true)

	local hull = Instance.new("Part")
	hull.Name = "Hull"
	hull.Anchored = true
	hull.CanCollide = false
	hull.CanQuery = false
	hull.CanTouch = false
	hull.CastShadow = false
	hull.Material = Enum.Material.SmoothPlastic
	hull.Color = color
	hull.Size = hullSize
	hull.CFrame = CFrame.new(0, hullSize.Y * 0.5, 0)
	hull.Parent = m

	m.PrimaryPart = hull
	archetypes[templateName] = m
	return m
end

--- **`ReplicatedStorage.Assets.ShipViewportPreviews.<TemplateName>`**, then **`Assets.<TemplateName>Viewport`**,
--- then **`UseGameplayHullInViewport`** + `fullGameplayTemplate`, else **`getArchetype`**.
function ShipViewportPreviewFactory.resolveViewportSourceModel(
	assets: Instance?,
	templateName: string,
	fullGameplayTemplate: Model?
): Model
	if ShipManagementUiConfig.UseGameplayHullInViewport == true and fullGameplayTemplate then
		return fullGameplayTemplate
	end
	if assets and assets:IsA("Folder") then
		local folder = assets:FindFirstChild("ShipViewportPreviews")
		if folder and folder:IsA("Folder") then
			local authored = folder:FindFirstChild(templateName)
			if authored and authored:IsA("Model") then
				return authored
			end
		end
		local top = assets:FindFirstChild(templateName .. "Viewport")
		if top and top:IsA("Model") then
			return top
		end
	end
	return ShipViewportPreviewFactory.getArchetype(templateName)
end

return ShipViewportPreviewFactory
