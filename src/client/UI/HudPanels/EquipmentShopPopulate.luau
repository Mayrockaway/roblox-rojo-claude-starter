--!strict
-- Fills Studio-authored equipment cards under `ShopPanelGui` … `EquipmentSection`
-- (paths discovered via Studio hierarchy: DRILLSRow / COLLECTORSRow / ProspectorPipesRow).
--
-- Studio template (see MCP / place): title lines are often default-named `TextLabel` siblings
-- under each card; `BuyButton` may be an `ImageButton`; optional `IconPlacard` should not supply lines.

export type CatalogRow = {
	id: string,
	displayName: string,
	cost: number,
	available: boolean,
	subtitle: string?,
	--- Rotating-shop remaining count. `nil` = non-rotating / unlimited;
	--- a number = "X left this rotation". Zero = sold out.
	stock: number?,
}

--- Resolve the line-2 text: stock overrides subtitle when rotating.
local function formatSubtitle(row: CatalogRow?): string
	if not row then
		return ""
	end
	if typeof(row.stock) == "number" then
		if row.stock <= 0 then
			return "Sold out"
		end
		return string.format("%d left", row.stock)
	end
	if not row.available then
		return "Unavailable"
	end
	if typeof(row.subtitle) == "string" and row.subtitle ~= "" then
		return row.subtitle
	end
	return "In stock"
end

--- Anything we can set `.Text` on for shop copy.
type TextCapable = TextLabel | TextButton | TextBox

-- Pairs of instance names to treat as title + subtitle (each row is two strings).
local TITLE_NAME_PAIRS: { { string } } = {
	{ "Title", "Subtitle" },
	{ "ItemTitle", "ItemSubtitle" },
	{ "NameLabel", "DescLabel" },
	{ "ItemName", "ItemDesc" },
}

local function sortTextCandidates(labels: { TextCapable })
	table.sort(labels, function(a, b)
		if a.LayoutOrder ~= b.LayoutOrder then
			return a.LayoutOrder < b.LayoutOrder
		end
		return a.Name < b.Name
	end)
end

local function sortTextLabels(labels: { TextLabel })
	table.sort(labels, function(a, b)
		if a.LayoutOrder ~= b.LayoutOrder then
			return a.LayoutOrder < b.LayoutOrder
		end
		return a.Name < b.Name
	end)
end

local function findTextCapableByName(root: GuiObject, name: string): TextCapable?
	local inst = root:FindFirstChild(name, true)
	if inst and (inst:IsA("TextLabel") or inst:IsA("TextButton") or inst:IsA("TextBox")) then
		return inst :: TextCapable
	end
	return nil
end

local function resolveNamedTitlePair(card: GuiObject): (TextCapable?, TextCapable?)
	for _, pair in ipairs(TITLE_NAME_PAIRS) do
		local t = findTextCapableByName(card, pair[1])
		local s = findTextCapableByName(card, pair[2])
		if t ~= nil or s ~= nil then
			return t, s
		end
	end
	return nil, nil
end

--- Anonymous `TextLabel` lines (canonical Studio cards): skip price, buy chrome, and icon placard.
local function collectAnonymousLineLabels(card: GuiObject): { TextLabel }
	local labels: { TextLabel } = {}
	for _, d in ipairs(card:GetDescendants()) do
		if not d:IsA("TextLabel") then
			continue
		end
		if d.Name == "CashPrice" then
			continue
		end
		if d:FindFirstAncestor("BuyButton") ~= nil then
			continue
		end
		if d:FindFirstAncestor("IconPlacard") ~= nil then
			continue
		end
		table.insert(labels, d)
	end
	sortTextLabels(labels)
	return labels
end

--- Fallback: any text-capable descendant not under buy / not price (covers TextButton-only titles).
local function collectTitleTextFallback(card: GuiObject): { TextCapable }
	local labels: { TextCapable } = {}
	for _, d in ipairs(card:GetDescendants()) do
		if (d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox")) and d.Name ~= "CashPrice" and d.Name ~= "BuyButton" then
			if d:FindFirstAncestor("BuyButton") ~= nil then
				continue
			end
			if d:FindFirstAncestor("IconPlacard") ~= nil then
				continue
			end
			table.insert(labels, d :: TextCapable)
		end
	end
	sortTextCandidates(labels)
	return labels
end

local EquipmentShopPopulate = {}

function EquipmentShopPopulate.ApplyCard(card: GuiObject, row: CatalogRow?)
	local cash = card:FindFirstChild("CashPrice", true)
	if cash and (cash:IsA("TextLabel") or cash:IsA("TextButton") or cash:IsA("TextBox")) then
		if row then
			cash.Text = if row.available then string.format("$%d", row.cost) else "—"
		else
			cash.Text = "—"
		end
	end

	local subtitleText = formatSubtitle(row)

	local tNamed, sNamed = resolveNamedTitlePair(card)
	if tNamed or sNamed then
		if tNamed then
			tNamed.Text = if row then row.displayName else "—"
		end
		if sNamed then
			sNamed.Text = subtitleText
		end
	else
		local lines = collectAnonymousLineLabels(card)
		if #lines == 0 then
			local fb = collectTitleTextFallback(card)
			if fb[1] then
				fb[1].Text = if row then row.displayName else "—"
			end
			if fb[2] then
				fb[2].Text = subtitleText
			end
		else
			if lines[1] then
				lines[1].Text = if row then row.displayName else "—"
			end
			if lines[2] then
				lines[2].Text = subtitleText
			end
		end
	end

	if row then
		card:SetAttribute("EquipmentShopItemId", row.id)
	else
		card:SetAttribute("EquipmentShopItemId", nil)
	end
end

return EquipmentShopPopulate
