# 🎛️ MiniHead MA3 Plugin

> A grandMA3 Lua plugin for discovering, patching, and controlling [Nomisimo/MiniHead](https://github.com/Nomisimo/MiniHead) ESP32 moving heads directly from the console.

---

## What it does

- Discovers MiniHead nodes on the network (seed IP + bounded subnet scan + ongoing `/api/heads` refresh)
- Links each head to an MA3 fixture number, editable either by typing or from the current floor/command-line selection
- Pushes fixture ID + DMX patch (universe/address, read straight from MA3's own patch) to a head over HTTP — one at a time, or batch-applied across a selected fixture range matched to heads in IP order
- Identify / Blackout / Rainbow-Demo, per head and fleet-wide
- One-command shortcut to MA3's native My Network Interfaces settings (per-adapter DHCP/IP/Mask/Gateway)
- Optional, always-confirmed write-back of a head's name onto its linked MA3 fixture

Full feature spec: [`MiniHead-MA3-Plugin-Spec.md`](MiniHead-MA3-Plugin-Spec.md).

**Status: confirmed working end-to-end against real grandMA3 onPC 2.4.2.2 and real MiniHead hardware** — see [docs/verification-checklist.md](docs/verification-checklist.md) for exactly what's been tested and the one remaining soft spot (the exact property name for reading a fixture's DMX patch, which fails soft either way).

---

## Quick start

```bash
git clone https://github.com/Nomisimo/MiniHead-MA3-Plugin.git
```

→ Install: [docs/installation.md](docs/installation.md) — copy `src/MiniHead_Control.lua` + `.xml` into your `gma3_library/datapools/plugins/MiniHead_Control/` folder and import via the Plugin Pool.

Then, on the console command line (replace `4` with whatever pool slot it imported to — **use the number, not the name**; `Plugin "MiniHead Control" ...` returns `Illegal object` on this build):

```
Plugin 4 "Menu"
```

That opens the clickable UI — no typing needed from here on. Or `Plugin 4 "Help"` for the full command list if you'd rather drive it from the command line / a macro.

---

## Commands

| Command | Does |
|---|---|
| `Window` | Open the full window — table of all heads, per-row Apply/Identify, global actions (experimental, actively being live-tested) |
| `Close` / `CloseWindow` | Close the window from a macro/executor button instead of clicking its X |
| `ToggleWindow` | Open it if closed, close it if open — one button for both |
| `Macro [macro#] [plugin#]` | Auto-creates a macro that runs `ToggleWindow` — confirms before writing, **not yet live-tested** (alias: `CreateToggleMacro`) |
| `Menu` | Open the clickable menu — buttons + an editable Fix# field, no typing needed |
| `Discover [ip]` | Seed a head IP, pull `/api/heads`, scan nearby addresses for extras |
| `List` | Show the head table as plain text (status, IP, name, linked fixture, patch) |
| `Refresh` | Re-check online status and re-pull the head list |
| `SetFixture <ip> <n>` | Link a head to MA3 fixture number `n` — this is also what gets pushed to the head as its fixture ID; the two are the same number, not tracked separately |
| `UseSelection <ip>` | Fill `SetFixture` from the current MA3 floor/command-line selection |
| `Apply <ip>` | Push fixID + patch (from the linked fixture) to that head |
| `Identify <ip>` / `IdentifyAll` | Flash one head, or all heads |
| `BlackoutAll` | Blackout the whole fleet |
| `RainbowAll` / `RainbowOff` | Start/stop the rainbow demo fleet-wide |
| `Batch [range]` | Batch-link + apply a selected (or typed) fixture range, matched to heads sorted by IP |
| `Rename <ip>` | Write the head's name onto its linked MA3 fixture (confirms every time) |
| `NetworkSettings` | Open MA3's My Network Interfaces settings (per-adapter DHCP/IP/Mask/Gateway) |
| `Settings [key value]` | View/change poll interval, toasts, command-line logging, scan radius, network interface (`bindip`), window display (`display`) |
| `Help` | Print this list in-console |

Run each as `Plugin <pool-number> "<command>"`, e.g. `Plugin 4 "Apply 192.168.1.50"`. Output goes to the **Command Line History** window. See [docs/installation.md](docs/installation.md) for details and executor-button wiring.

---

## UI: two options, neither is a true docked window

The spec calls for a native popup/dockable table view. Two UI layers are built here, both click-driven rather than typed commands:

- **`Window`** (experimental) — the real thing per the spec's layout: a table of every head (status, IP, MAC, name, Fix#, U.Addr, role) with per-row Apply/Identify buttons, a header (Discover/Refresh/Settings), global actions (Identify All/Blackout All/Rainbow Demo), and a footer. Built on grandMA3's `Append('ClassName')` UI-object API — the same building blocks (`TitleBar`, `DialogFrame`, `ScrollBox`, `Button`, `LineEdit`, ...) grandMA3's own shipped dialogs are built from, confirmed by reading `message_box.uixml` directly. **Not yet seen rendered live** — see [docs/verification-checklist.md](docs/verification-checklist.md) for exactly what's confirmed vs. still open.
- **`Menu`** — a simpler, dialog-based fallback on the well-established `MessageBox` API: a main menu listing every head as a button, and a per-head dialog with an editable Fix# field plus Apply/Identify/Rename buttons.

**Neither is a true persistent dock.** Confirmed by reading grandMA3's own `add_window.lua`: dockable window types (Command Line History, the pool windows, etc.) come from a fixed, engine-built list with no Lua hook to register a new one — a plugin can only build an *overlay* that stays open for as long as its Lua task keeps running, not a window integrated into the screen's own layout grid the way built-in windows are. `Window` gets as close to "feels permanent" as a plugin can.

For one-touch access without opening either UI, put individual commands on **Macros** assigned to executor buttons — see [docs/installation.md](docs/installation.md#macros--executor-buttons-optional).

---

## Related

- [Nomisimo/MiniHead](https://github.com/Nomisimo/MiniHead) — ESP32 firmware (Art-Net build) + PC app
- [Nomisimo/MiniHead-App](https://github.com/Nomisimo/MiniHead-App) — mobile PWA control app

---

## 📜 License

**GNU General Public License v3.0** — [LICENSE](./LICENSE)

> Art-Net™ is a trademark of Artistic Licence Holdings Ltd. grandMA3 is a product of MA Lighting Technology GmbH; this project is not affiliated with or endorsed by MA Lighting.

---

*Vibe coded with [Claude Code](https://claude.ai/code)*
