# Pimax Cover Changer

A small Windows tool for setting custom library images (cover art) in **Pimax Play**, especially for games you added with **Import**, which otherwise show the default gamepad tile.

## Download

Grab **`PimaxCoverChanger.exe`** from this repo and run it. It asks for admin rights because it restarts the Pimax service so the new image shows up.

Windows SmartScreen or Defender may warn about it as an unrecognized app. If you'd rather not run the exe, use the script instead (see below). It's the same code.

## How to use

1. Pick a game from your Pimax library on the left.
2. Paste an image link (for example from [SteamGridDB](https://www.steamgriddb.com/)) or click **Browse...** for an image file. Click **Preview** to check it.
3. Click **Apply image**. The tool saves the image, updates the game's entry, and restarts Pimax Play.

Wide banner images (about 460x215 or 920x430) fit Pimax tiles best.

- **Restore original** puts a game back to its original image.
- **Restart Pimax Play** restarts Pimax without changing anything.

## How it works

Pimax Play keeps each library entry as a JSON file in `%APPDATA%\Pimax\manifest`. The tile image comes from the entry's `icon` field, which accepts a web link or a local file path. This tool:

- copies your image to `%APPDATA%\Pimax\covers` so it keeps working if you move or delete the original,
- backs up the original entry to `%APPDATA%\Pimax\cover-backups` the first time you change it,
- writes the entry back as UTF-8 **without a BOM** (Pimax silently drops entries saved with one),
- restarts the `PiServiceLauncher` service and Pimax Play, because the service keeps entries in memory until it restarts.

## Notes

- Custom images on Steam games may be reset when Pimax rescans your library. Imported games keep theirs.
- Tested with Pimax Play 2.x. A future Pimax update could change how this works.

## Run from the script

Double-click `Pimax Cover Changer.bat`, or run:

```powershell
powershell -ExecutionPolicy Bypass -File .\PimaxCoverChanger.ps1
```

## Build the exe yourself

```powershell
Install-Module ps2exe -Scope CurrentUser
Invoke-ps2exe .\PimaxCoverChanger.ps1 .\PimaxCoverChanger.exe -noConsole -requireAdmin -STA -title "Pimax Cover Changer" -version 1.0.0
```

Not affiliated with Pimax.
