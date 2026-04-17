--!strict
-- FTUE dialogue portraits: one entry per image imported in Studio (Home → Asset Manager → Images).
-- For each row, select the image → … → **Copy ID**, then paste the numeric id into `rbxassetid://` below.
-- Until you replace these, values fall back to the previous FTUE portrait assets so nothing breaks at runtime.

local FtuePortraitAssets = {
	OilManOilHead = "rbxassetid://117354032272168",
	OilmanDrilling = "rbxassetid://131292942155578",
	OilmanCelebrate = "rbxassetid://102986258112911",
	OilmanSalute = "rbxassetid://103622018966974",
	OilmanPointAngry = "rbxassetid://120154416475695",
	OilmanBurger = "rbxassetid://88150735271199",
}

return FtuePortraitAssets
