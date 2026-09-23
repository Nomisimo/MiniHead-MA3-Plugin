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

---

## Quick start

```bash
git clone https://github.com/Nomisimo/MiniHead-MA3-Plugin.git
```

→ Install: [docs/installation.md](docs/installation.md) (XML import, or guaranteed-working manual paste into the console's Lua editor)

Then, on the console command line:

```
Cmd('Plugin "MiniHead Control" "Help"')
```

---

## Commands

| Command | Does |
|---|---|
| `Discover [ip]` | Seed a head IP, pull `/api/heads`, scan nearby addresses for extras |
| `List` | Show the head table (status, IP, MAC, fixID, name, linked fixture, patch) |
| `Refresh` | Re-check online status and re-pull the head list |
| `SetFixID <ip> <n>` | Edit a head's fixture-ID field (local; push with `Apply`) |
| `SetFixture <ip> <n>` | Link a head to MA3 fixture number `n` |
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

Every command runs as `Cmd('Plugin "MiniHead Control" "<command>"')` — put the ones you use often on executor buttons. See [docs/installation.md](docs/installation.md) for wiring examples.

---

## Why command-driven, not a docked window

The spec calls for a native popup/dockable table view. This v1 ships as command + feedback-table + dialog driven instead: building a real MA3 window means authoring an XML Layout with MA3's own UI object classes, a console-side, trial-and-error skill that isn't something to guess blind from outside a real console. Every actual control action is fully implemented and independent of the UI shell around it — see [docs/verification-checklist.md](docs/verification-checklist.md#6-what-was-not-attempted-a-native-popuptable-window).

## Verification status

This plugin was built and unit-tested (JSON, HTTP parsing, command dispatch, persistence, all against mocked firmware responses shaped from the real `Nomisimo/MiniHead` source) without access to an actual grandMA3 console or onPC. The handful of calls into MA3's own Lua host API (networking, reading the current selection/patch, renaming a fixture) are best-effort and fail soft rather than crash — see **[docs/verification-checklist.md](docs/verification-checklist.md)** for exactly what to check first on a real console and how to fix it if something doesn't match.

The HTTP API this plugin calls was cross-checked against the actual firmware source (not just the spec) — see [docs/api-reference.md](docs/api-reference.md).

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
