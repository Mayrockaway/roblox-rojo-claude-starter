--!strict
-- Removes one **shop** tool (`EquipmentShopConsumable`) after a successful placement / drill / prospect.
-- Prefers the equipped tool on `Character`, then `Backpack`.

local ConsumeShopEquipmentTool = {}

local function toolMatches(tool: Tool, toolKind: string, tierFilter: string?): boolean
	if tool:GetAttribute("EquipmentShopConsumable") ~= true then
		return false
	end
	if tool:GetAttribute("ToolKind") ~= toolKind then
		return false
	end
	if typeof(tierFilter) == "string" and tierFilter ~= "" then
		if tool:GetAttribute("Tier") ~= tierFilter then
			return false
		end
	end
	return true
end

--- Destroy the first matching shop tool (character first, then backpack). Returns **removed**, **`EquipmentItemId`** if any.
function ConsumeShopEquipmentTool.consumeMatching(player: Player, toolKind: string, tierFilter: string?): (boolean, string?)
	local function tryContainer(container: Instance?): (boolean, string?)
		if not container then
			return false, nil
		end
		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("Tool") and toolMatches(child, toolKind, tierFilter) then
				local itemId = child:GetAttribute("EquipmentItemId")
				local idStr = if typeof(itemId) == "string" and itemId ~= "" then itemId :: string else nil
				child:Destroy()
				return true, idStr
			end
		end
		return false, nil
	end

	local ok, id = tryContainer(player.Character)
	if ok then
		return true, id
	end
	local bp = player:FindFirstChild("Backpack")
	if bp and bp:IsA("Backpack") then
		return tryContainer(bp)
	end
	return false, nil
end

return ConsumeShopEquipmentTool
