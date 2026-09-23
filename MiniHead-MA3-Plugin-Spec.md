# MiniHead grandMA3 Plugin — Build Spec

Target: grandMA3 Lua plugin (full-size console, Compact, and onPC).
Companion firmware: Nomisimo/MiniHead (Art-Net build, HTTP config API always active on port 80).
Visual style: match native grandMA3 UI (dark theme, MA3 widget conventions — not a custom look).

---

## 1. Scope (v1)

- Head discovery (manual IP seed + subnet-scan suggestion + ongoing `/api/heads` refresh)
- Fixture ID set (editable, defaults to head's own stored fixID)
- DMX patch set (universe + address), pulled from MA3's own show patch
- Single-head apply AND batch apply (fixture range → multiple heads)
- Identify / Blackout / Rainbow-Demo controls — per-head row buttons + a global "all heads" section
- One-click shortcut to MA3's native Connector Configuration menu (Art-Net network/universe setup)
- Optional write-back: MA3 fixture renamed to match head's name — **only with an explicit checkbox confirmation each time**, never automatic

Out of scope for v1: cue system, sequencer, full phone-app parity.

---

## 2. Layout

- **Popup by default**, with a dockable mode the user can toggle (so it can live on a screen permanently while patching).
- Structure, top to bottom:
  1. **Header row**: "Discover Heads" button · global refresh-interval setting (see §6) · settings gear (feedback toggle, poll interval)
  2. **Head list / table**, one row per discovered head:
     - Status dot (online = normal, offline = greyed out, stays in list)
     - IP, MAC, head name, current fixID (editable field)
     - MA3 fixture number field (editable — auto-fills from MA3 floor selection if one is active, see §4)
     - Universe.Address (read-only, auto-pulled from the MA3 patch of the linked fixture)
     - Per-row buttons: **Identify**, **Apply** (push fixID + patch to this head)
  3. **Batch bar** (appears when a fixture range is selected in MA3): "Apply to N heads in IP order" button — see §5
  4. **Global controls section**: Identify All · Blackout All · Rainbow Demo (all heads)
  5. **Footer**: "Open Art-Net Network Settings" button → runs `Cmd('Menu "ConnectorConfig"')`

---

## 3. Discovery

- **First run / no IP configured**: prompt for a head IP. Also run a one-time subnet scan (HTTP probe of `/api/status` across the local subnet) and suggest any heads found as pickable options.
- **After a head IP is known**: use that head's `/api/heads` endpoint to enumerate all heads on the network (leader returns full list — MAC, IP, fixID, name, role).
- **Persistence**: the discovered head list (IP, MAC, last-known fixID/name) is saved into the showfile, same as the seed IP, so it's remembered between sessions — no rediscovery needed on reopen.
- **Ongoing status**: poll each known head at a configurable interval (default 15–30s, adjustable in plugin settings) to mark online/offline. Manual refresh always available via the header button.

---

## 4. Linking a head to an MA3 fixture

- **Matching key**: the head's own `fixID` (stored on the ESP), shown editable in the row — user can override it.
- **Fixture number field**: fillable two ways, both always active —
  - Type a fixture number directly into the row
  - Select fixture(s) on the MA3 floor first; the plugin reads the current command-line selection and fills the field (still editable after)
- **Unpatched fixture**: if the typed/selected fixture number isn't patched in MA3, show an error inline with two buttons: **Cancel** or **Apply Anyway** (applies fixID only; patch/address is skipped or left as typed).
- **DMX breaks**: not relevant — MiniHead is always single-break, always reads the fixture's one address/universe.

---

## 5. Batch apply

- Select a fixture range in MA3 (e.g. `Fixture 1 Thru 8`).
- Plugin matches that range against discovered heads **sorted by IP address**, in order, one-to-one.
- Shows a preview list (Fixture N ↔ Head @ IP) before committing — apply button confirms all at once.
- Same per-row Apply logic underneath (fixID + patch pushed via HTTP for each match).

---

## 6. Feedback & error handling

- Failed HTTP calls (offline head, timeout): shown **both** as an in-plugin toast/message and as command-line log output — each togglable independently in plugin settings.
- Offline heads: greyed out, kept in the list (not removed), status re-checked on the polling interval.
- Poll interval: default 15–30s, user-adjustable value in plugin settings.

---

## 7. Network settings button

- Single button, opens MA3's native menu directly:
  ```lua
  Cmd('Menu "ConnectorConfig"')
  ```
- No custom universe/port editing UI in the plugin — keeps this low-risk and always in sync with MA3's own network config screen.
- Covers Art-Net **output** setup (which console network port sends which universe) — MA3's native menu handles input the same way if ever needed.

---

## 8. Head control endpoints (from MiniHead firmware, confirmed)

| Action | Endpoint |
|---|---|
| Set fixture ID | `POST /api/config/fixid` `{"fixID": n}` |
| Set patch | `POST /api/config/patch` `{"universe": n, "startAddr": n}` |
| List all heads (leader) | `GET /api/heads` |
| List patched fixtures | `GET /api/fixtures` |
| Identify on/off | `POST /api/heads/<mac>/identify` `{"on": bool}` |
| Blackout | `POST /api/blackout` |
| Rainbow demo | `POST /api/rainbow` |
| Status probe (for subnet scan) | `GET /api/status` |

All confirmed always-active regardless of Art-Net streaming state.

---

## 9. Open items for Claude Code during build (not yet nailed down)

- Exact MA3 Lua property names for reading current command-line fixture selection (to auto-fill the fixture field from floor selection).
- Exact MA3 Lua syntax/library confirmation for HTTP POST bodies (JSON encode via bundled `json` lib) — confirm during implementation against console's actual Lua sandbox.
- Whether raw UDP is available to MA3 Lua plugins — not needed for v1 (HTTP-only discovery/control), but worth a quick check in case it simplifies subnet scanning later.
- Docking behavior specifics (how MA3 plugin windows support dock vs popup — confirm via MA3 plugin UI API/XML layout options).

---

## 10. Design language

Build all plugin UI using native grandMA3 look and feel (dark theme, standard MA3 buttons/tables/encoders-style fields) — not a custom skin. Should feel like a built-in MA3 tool, not a separate app embedded in a console.
