--!strict
-- Shared HUD modal controller shape (per-panel modules extend behavior here later).

export type HudPanelController = {
	ScreenName: string,
	ScreenGui: ScreenGui,
	Open: () -> (),
	Close: () -> (),
	IsOpen: () -> boolean,
}

return {}
