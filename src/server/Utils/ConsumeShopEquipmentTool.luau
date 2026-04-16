--!strict
-- Removes one **shop** tool use (`EquipmentShopConsumable`) after a successful placement / drill / prospect.
-- Prefers the equipped tool on `Character`, then `Backpack`.
-- Decrements **`EquipmentStackCount`** when present; destroys the `Tool` when count reaches **0** (legacy tools without the attribute behave as a single use).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local STACK_ATTR = Constants.EquipmentStackCountAttribute

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

local function consumeOneStackUnit(tool: Tool): (boolean, string?)
	local itemId = tool:GetAttribute("EquipmentItemId")
	local idStr = if typeof(itemId) == "string" and itemId ~= "" then itemId :: string else nil
	local raw = tool:GetAttribute(STACK_ATTR)
	if typeof(raw) == "number" and raw == raw and raw > 1 then
		tool:SetAttribute(STACK_ATTR, math.floor(raw) - 1)
		return true, idStr
	end
	if typeof(raw) == "number" and raw == 1 then
		tool:Destroy()
		return true, idStr
	end
	-- Legacy: no stack attribute → one physical tool = one use
	tool:Destroy()
	return true, idStr
end

--- True if the player has any matching shop tool with at least one stack unit available.
-- Checked before charging cash on placement so shop-bought tools don't double-charge.
function ConsumeShopEquipmentTool.hasMatching(player: Player, toolKind: string, tierFilter: string?): boolean
	local function checkContainer(container: Instance?): boolean
		if not container then return false end
		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("Tool") and toolMatches(child, toolKind, tierFilter) then
				return true
			end
		end
		return false
	end
	if checkContainer(player.Character) then return true end
	local bp = player:FindFirstChild("Backpack")
	if bp and bp:IsA("Backpack") then
		return checkContainer(bp)
	end
	return false
end

--- Consume one matching shop stack unit (character first, then backpack). Returns **consumed**, **`EquipmentItemId`** if any.
function ConsumeShopEquipmentTool.consumeMatching(player: Player, toolKind: string, tierFilter: string?): (boolean, string?)
	local function tryContainer(container: Instance?): (boolean, string?)
		if not container then
			return false, nil
		end
		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("Tool") and toolMatches(child, toolKind, tierFilter) then
				return consumeOneStackUnit(child :: Tool)
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
