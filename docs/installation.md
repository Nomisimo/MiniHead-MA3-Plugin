# Installation

Confirmed working on grandMA3 onPC 2.4.2.2. Uses the file-based plugin import method (not manual copy-paste into the console's Lua editor — that also works, but the XML+file method is quicker to update and is what's documented here).

## 1. Copy the plugin files into place

grandMA3 loads plugins from `gma3_library/datapools/plugins/<PluginFolderName>/` on the same drive as the running installation:

- **macOS:** `~/MALightingTechnology/gma3_library/datapools/plugins/`
- **Windows:** `C:\ProgramData\MALightingTechnology\gma3_library\datapools\plugins\`

Create a folder there called `MiniHead_Control` and copy both files from this repo's [`src/`](../src/) into it:

```
gma3_library/datapools/plugins/MiniHead_Control/MiniHead_Control.lua
gma3_library/datapools/plugins/MiniHead_Control/MiniHead_Control.xml
```

## 2. Import it in the console

1. Open the **Plugin Pool**.
2. Select an empty slot → **Import**.
3. Navigate to `MiniHead_Control.xml` in the folder above → select it → **Import**.
4. The plugin appears in the pool as **MiniHead Control**, at whatever slot number you imported it to.

## 3. Run it

Plugins on this build are invoked **by pool number**, not by name — `Plugin "MiniHead Control" ...` (name in quotes) returned `Illegal object` in testing, even though it's documented as valid syntax. Use the number shown on its pool tile:

```
Plugin 4 "Help"
```

(replace `4` with your plugin's actual slot number) — this prints the full command list to the **Command Line History** window. If you don't have that window open: `Menu "Addwindow"` → add a Command Line History window, or check the console's default screen layout, since that's where all of this plugin's output goes (not the on-screen command line's single input row, and not the System Monitor).

## Commands

See the table in the [README](../README.md#commands), or just run `Plugin <n> "Help"`. Per-head commands take the head's IP, e.g.:

```
Plugin 4 "Discover 192.168.1.50"
Plugin 4 "List"
Plugin 4 "SetFixture 192.168.1.50 12"
Plugin 4 "Apply 192.168.1.50"
```

For convenience, put the ones you use often on executor buttons or a macro page instead of retyping them.

## First run

Invoking the plugin with no argument (`Plugin 4`) before anything is known walks you through first-run setup automatically: it prompts for one head's IP via a text-input dialog, connects, pulls the rest of the fleet from that head's `/api/heads`, and does a bounded scan of nearby addresses for anything not in that list. After that, the head list is saved into the showfile via grandMA3's Global Variables — no rediscovery needed next time you open it.

## Auto-refresh (optional)

`Refresh` re-checks online status and re-pulls the head list — it's a plain command, not a background timer. To get periodic polling, put `Plugin <n> "Refresh"` on a macro or executor with MA3's own timer/loop functionality, at whatever interval you set via `Settings poll <seconds>` (default 20s).

## Updating the plugin after editing the `.lua` file

If you edit `MiniHead_Control.lua` on disk after importing it, the console's copy won't update automatically. Either:
- Delete the plugin from the pool and re-import (guaranteed to pick up the new file), or
- Try the `ReloadAllPlugins` keyword on the command line first (faster if it works for your setup).

## Uninstall

Delete the plugin object from the Plugin Pool. The two Global Variables it stores data in (`MiniHead_Settings`, `MiniHead_Heads`) are harmless leftover strings in the showfile if you don't clean them up.
