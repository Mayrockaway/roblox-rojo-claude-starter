# Roblox Rojo + VS Code Starter

This project is set up for Roblox development with Rojo, GitHub, and AI-assisted editing in VS Code.

## Quick start

1. Install Rojo CLI and Studio plugin.
2. Run `rojo serve` from this folder.
3. In Roblox Studio, open the Rojo plugin and connect to `localhost:34872`.
4. Edit Luau files in `src/` from VS Code.

## Structure

- `src/server` -> `ServerScriptService/Server`
- `src/client` -> `StarterPlayer/StarterPlayerScripts/Client`
- `src/shared` -> `ReplicatedStorage/Shared`

## Commands

- `rojo serve`
- `rojo build default.project.json --output place.rbxlx`