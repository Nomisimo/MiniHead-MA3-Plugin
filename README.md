# 🎛️ MiniHead MA3 Plugin

> A grandMA3 Lua plugin for discovering, patching, and controlling [Nomisimo/MiniHead](https://github.com/Nomisimo/MiniHead) ESP32 moving heads directly from the console.

---

## What it does

- Discovers MiniHead nodes on the network (seed IP + bounded subnet scan + ongoing `/api/heads` refresh)
- Links each head to an MA3 fixture number, editable either by typing or from the current floor/command-line selection
- Pushes fixture ID + DMX patch (universe/address, read straight from MA3's own patch) to a head over HTTP — one at a time, or batch-applied across a selected fixture range matched to heads in IP order
- Identify / Blackout / Rainbow-Demo, per head and fleet-wide
- One-command shortcut to MA3's native Art-Net Connector Configuration menu
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
| `NetworkSettings` | Open MA3's Art-Net Connector Configuration menu |
| `Settings [key value]` | View/change poll interval, toasts, command-line logging, scan radius |
| `Help` | Print this list in-console |

Run each as `Plugin <pool-number> "<command>"`, e.g. `Plugin 4 "Apply 192.168.1.50"`. Output goes to the **Command Line History** window. See [docs/installation.md](docs/installation.md) for details and executor-button wiring.

---

## UI: clickable, not a persistent docked window

The spec calls for a native popup/dockable table view that stays open. What's here instead is a real point-and-click UI (`Menu`) built on grandMA3's `MessageBox` API — a main menu listing every head as a button, and a per-head dialog with an editable Fix# field plus Apply/Identify/Rename buttons — rather than typed commands. It's not a *persistent* docked window: each screen is a modal dialog you click through, not something left open on a screen permanently while patching.

A true always-on docked table would mean authoring an MA3 **Layout View** or **UI Layout** — real, Lua-drivable features (community plugins like [Build-A-Layout](https://addondesk.com/product/build-a-layout/) generate Layout Views programmatically), but a separate, larger research task from what's built here. See [docs/verification-checklist.md](docs/verification-checklist.md).

For one-touch access without opening the menu at all, put individual commands on **Macros** assigned to executor buttons — see [docs/installation.md](docs/installation.md#macros--executor-buttons-optional).

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
