--!strict
-- Purchasable one-shot equipment. Each entry maps to a `Tool` **template** under **ServerStorage**
-- in folder `EquipmentShopConfig.TemplateFolderName` (see `EquipmentShopService`).
-- Add rows when art/templates exist; empty `Items` = shop has nothing to sell yet.

export type EquipmentShopItem = {
	--- Stable id sent from client on purchase.
	id: string,
	--- Shown in catalog UI when wired.
	displayName: string,
	--- Cash deducted per **one** granted tool (`OilStateService` cash).
	cost: number,
	--- `Tool` instance name under the template folder (must be a `Tool`, not a `Model`).
	toolTemplateName: string,
}

local EquipmentShopConfig = {
	--- `ServerStorage:WaitForChild(TemplateFolderName)` must contain each `toolTemplateName` as a `Tool`.
	TemplateFolderName = "EquipmentShopTemplates",

	--- Max tools granted in a single purchase request (spam / UX guard).
	MaxQuantityPerPurchase = 20,

	Items = {} :: { EquipmentShopItem },
}

return EquipmentShopConfig
