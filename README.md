# 🎛️ MiniHead MA3 Plugin

A grandMA3 Lua plugin for discovering, patching, and controlling [Nomisimo/MiniHead](https://github.com/Nomisimo/MiniHead) ESP32 moving heads directly from the console.

Confirmed working on grandMA3 onPC 2.4.2.2 with real MiniHead hardware.

---

## What it does

- Discovers MiniHead nodes on the network and keeps a live head list
- Links each head to an MA3 fixture number, then pushes fixture ID + DMX patch to it over HTTP — one at a time or batch-applied across a range
- Identify / Blackout / Rainbow-Demo, per head and fleet-wide
- A full on-console window (table of all heads, per-row controls, global actions) plus a simpler click-through menu — see `Window` / `Menu` below
- One-command shortcut to MA3's own network interface settings

---

## Install

1. Copy both files from [`src/`](src/) into `gma3_library/datapools/plugins/MiniHead_Control/`:
   - **macOS:** `~/MALightingTechnology/gma3_library/datapools/plugins/`
   - **Windows:** `C:\ProgramData\MALightingTechnology\gma3_library\datapools\plugins\`
2. In grandMA3: **Plugin Pool** → an empty slot → **Import** → select `MiniHead_Control.xml`.
3. Note the pool number it imported to (shown on its tile) — plugins run **by number, not by name**.

If you edit `MiniHead_Control.lua` after importing, the console won't pick up the change automatically — delete and re-import, or try `ReloadAllPlugins` on the command line.

## Run

```
Plugin 4 "Window"
```

(replace `4` with your plugin's actual pool number) opens the full on-screen window. `Plugin 4 "Menu"` opens the simpler click-through version instead, and `Plugin 4 "Help"` prints the full command list. Output goes to the **Command Line History** window (`Menu "Addwindow"` if you don't have one open).

Running the plugin with no argument (`Plugin 4`) on a fresh show walks you through first-run discovery automatically — no setup needed beforehand.

For one-touch access to a single action (e.g. Blackout All on a show button), put the command on a **Macro** assigned to an executor: `Plugin 4 "BlackoutAll"`.

---

## Commands

| Command | Does |
|---|---|
| `Window` | Open the full window — table of all heads, per-row Apply/Identify, global actions |
| `Close` / `CloseWindow` | Close the window from a macro/executor button instead of clicking its X |
| `ToggleWindow` | Open it if closed, close it if open — one button for both |
| `Macro [macro#] [plugin#]` | Auto-creates a macro that runs `ToggleWindow` (confirms before writing) |
| `Menu` | Open the clickable menu — buttons + an editable Fix# field, no typing needed |
| `Discover [ip]` | Seed a head IP, pull `/api/heads`, scan nearby addresses for extras |
| `List` | Show the head table as plain text (status, IP, name, linked fixture, patch) |
| `Refresh` | Re-check online status and re-pull the head list |
| `SetFixture <ip> <n>` | Link a head to MA3 fixture number `n` — this is also the fixture ID pushed to the head, same number |
| `UseSelection <ip>` | Fill `SetFixture` from the current MA3 floor/command-line selection |
| `Apply <ip>` | Push fixID + patch (from the linked fixture) to that head |
| `Identify <ip>` / `IdentifyAll` | Flash one head, or all heads |
| `BlackoutAll` | Blackout the whole fleet |
| `RainbowAll` / `RainbowOff` | Start/stop the rainbow demo fleet-wide |
| `Batch [range]` | Batch-link + apply a selected (or typed) fixture range, matched to heads sorted by IP |
| `Rename <ip>` | Write the head's name onto its linked MA3 fixture (confirms every time) |
| `NetworkSettings` | Open MA3's My Network Interfaces settings (per-adapter DHCP/IP/Mask/Gateway) |
| `Settings [key value]` | View/change poll interval, toasts, logging, scan radius, network interface (`bindip`), window display (`display`) |
| `Help` | Print this list in-console |

Run each as `Plugin <pool-number> "<command>"`, e.g. `Plugin 4 "Apply 192.168.1.50"`.

---

## Related

- [Nomisimo/MiniHead](https://github.com/Nomisimo/MiniHead) — ESP32 firmware (Art-Net build) + PC app
- [Nomisimo/MiniHead-App](https://github.com/Nomisimo/MiniHead-App) — mobile PWA control app

## 📜 License

**GNU General Public License v3.0** — [LICENSE](./LICENSE)

> Art-Net™ is a trademark of Artistic Licence Holdings Ltd. grandMA3 is a product of MA Lighting Technology GmbH; this project is not affiliated with or endorsed by MA Lighting.

---

*Vibe coded with [Claude Code](https://claude.ai/code)*
