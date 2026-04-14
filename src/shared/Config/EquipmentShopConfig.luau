--!strict
-- Purchasable one-shot equipment. Each entry maps to a `Tool` **template** under **ServerStorage**
-- in folder `EquipmentShopConfig.TemplateFolderName` (see `EquipmentShopService`).
-- Rows come from `EquipmentCatalog` (single source with placement + shop prices).

local EquipmentCatalog = require(script.Parent:WaitForChild("EquipmentCatalog"))

export type EquipmentShopItem = {
	--- Stable id sent from client on purchase.
	id: string,
	--- Shown in catalog UI when wired.
	displayName: string,
	--- Cash deducted per **one** granted tool (`OilStateService` cash).
	cost: number,
	--- `Tool` instance name under the template folder (must be a `Tool`, not a `Model`).
	toolTemplateName: string,
	--- Copied to granted tool attributes so `init.client` placement logic matches dev tools.
	toolKind: string,
	--- Tier for drills/pumps; omit for Pipe / Prospector.
	tier: string?,
	--- Second line on shop cards (from `EquipmentCatalog.shopSubtitle`).
	subtitle: string?,
}

local EquipmentShopConfig = {
	--- `ServerStorage:WaitForChild(TemplateFolderName)` must contain each `toolTemplateName` as a `Tool`.
	TemplateFolderName = "EquipmentShopTemplates",

	--- Max tools granted in a single purchase request (spam / UX guard).
	MaxQuantityPerPurchase = 20,

	Items = (function(): { EquipmentShopItem }
		local out: { EquipmentShopItem } = {}
		for _, row in ipairs(EquipmentCatalog.buildShopItems()) do
			table.insert(out, {
				id = row.id,
				displayName = row.displayName,
				cost = row.cost,
				toolTemplateName = row.toolTemplateName,
				toolKind = row.toolKind,
				tier = row.tier,
				subtitle = row.subtitle,
			})
		end
		return out
	end)() :: { EquipmentShopItem },
}

return EquipmentShopConfig
