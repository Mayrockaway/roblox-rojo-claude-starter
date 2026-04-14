--!strict
-- At-most-two-word titles for Active Manifest incident rows, derived from catalog display names.

local Catalog = require(script.Parent:WaitForChild("Catalog"))

local ManifestIncidentTitle = {}

local function twoWordsFromDisplayName(displayName: string): string
	local words = {}
	for w in string.gmatch(displayName, "%S+") do
		table.insert(words, w)
		if #words >= 2 then
			break
		end
	end
	if #words == 0 then
		return "Event"
	end
	return table.concat(words, " ")
end

function ManifestIncidentTitle.fromDisplayName(displayName: string): string
	return twoWordsFromDisplayName(displayName)
end

function ManifestIncidentTitle.fromEventId(eventId: string): string
	local def = Catalog.GetById(eventId)
	if def then
		return twoWordsFromDisplayName(def.displayName)
	end
	return twoWordsFromDisplayName(eventId)
end

return ManifestIncidentTitle
