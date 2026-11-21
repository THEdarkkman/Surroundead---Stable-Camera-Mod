# SD Stable Camera

Replaces animation-driven first-person head bob with a smooth eye-level camera.
Hides the body, shows held weapons/tools, hides holstered gear, and saves camera height.

## Requirements

SurrounDead Pandemic v0.8.0 (Windows) and UE4SS v4.0.0.
Other versions have not been tested. UE4SS is not included.
https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/v4.0.0

## Install

1. Download UE4SS_v4.0.0.zip and extract it into:
   `SurrounDead\SurrounDead\Binaries\Win64\`
2. Extract the mod into `Win64\ue4ss\Mods\` so the script is located at:
   `Win64\ue4ss\Mods\SD_StableCamera\Scripts\main.lua`
3. Launch the game, load a save, and press `F6`.
   When updating, keep your existing config.ini to retain your height setting.

## Use

| Key | Action |
| --- | --- |
| `F6` | Toggle stable camera (starts off each launch). |
| `F7` / `F8` | Lower/raise height by 2 cm; changes save automatically to `config.ini`. |
| `F4` | Show/hide held weapons and tools. |
| `F9` | Write diagnostics to `Win64\ue4ss\UE4SS.log`; no window opens. |

Use the game's third-person FOV slider to adjust field of view.

Holstered items hide automatically and the body/hands are hidden.

Scopes have not been tested. (because i just started a new game lol)

## Uninstall

Close the game and remove ue4ss\Mods\SD_StableCamera.
