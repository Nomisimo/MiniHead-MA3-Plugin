# ESP HTTP API — as actually used by this plugin

This plugin talks to each MiniHead node's own HTTP API on port 80. This table only covers the endpoints the plugin calls, and documents exactly what they do, confirmed by reading the firmware source directly (`Nomisimo/MiniHead`, `Firmware/MiniHead/main/core/wifi/*.h`) rather than assumed from the plugin spec alone.

**Why this doc exists separately from the spec:** three sources describe this API — the plugin spec, `Nomisimo/MiniHead-App`'s `docs/esp-api.md`, and the firmware's own `Firmware/MiniHead/README.md` §8 — and they don't all agree on field names or which endpoint is canonical for setting a patch. Where they disagreed, this plugin was built against the firmware source and the firmware's own README (the two most authoritative sources), not the spec's simplified table. Differences are called out below.

## Endpoints used

| Action | Request | Response | Called against |
|---|---|---|---|
| Liveness / info probe | `GET /api/status` | `{"connected","port","ip","apMode","apPasswordSet","rainbowActive","demoActive","animSpeed"}` | Each head's own IP |
| List all heads | `GET /api/heads` | Array of `{"mac","ip","fixID","name","mode","role","self"}` | A known head (prefers whichever reports `role:"LEADER"`) |
| Set fixture ID | `POST /api/config/fixid` `{"fixID": n}` | `{"status":"ok"}` | The target head's own IP |
| Set DMX patch | `POST /api/artnet/patch` `{"universe": n, "startAddr": n}` | `{"status":"ok"}` | The target head's own IP |
| Identify | `POST /api/heads/SELF/identify` `{"on": true}` | `{"status":"ok"}` | The target head's own IP |
| Blackout (all heads) | `POST /api/blackout` (no body) | `{"status":"ok"}` | Any known head — broadcasts via UDP regardless of which one you call |
| Rainbow demo (all heads) | `POST /api/rainbow` `{"on": bool}` | `{"status":"ok"}` | Any known head — same broadcast behavior |

## Notes and deviations from other docs

- **Patch endpoint:** the plugin spec's §8 table lists `POST /api/config/patch`. That route does exist in the firmware source (`wifi_control.h`, gated by `#ifdef PLUGIN_ARTNET`) but isn't documented in the firmware's own README and appears to be a legacy/internal alias. The firmware README §8.4 and the App's own client both use `POST /api/artnet/patch`, which is what this plugin uses. Functionally near-identical for a full replace (which is all v1 needs); the firmware README additionally states **universe must be 1–32767, universe 0 is rejected** — the plugin does not currently pre-validate this client-side, so a rejected universe surfaces as an HTTP error on Apply.
- **`/api/heads` fields:** the firmware's `handleGetHeads()` (`wifi_heads.h`) emits `mac, ip, fixID, name, mode, role, self`. Neither the App's docs (which add `priority`, `active`) nor the firmware README (which shows `online` instead) exactly match the running code. The plugin only reads the fields confirmed in source and does **not** trust any liveness/online field from this endpoint — online/offline is determined by the plugin itself, by probing `GET /api/status` directly per head (matching spec §3's "poll each known head" model).
- **Config routes have no leader redirect.** `POST /api/config/fixid` and `POST /api/artnet/patch` work when called directly on a head's own IP, whether it's currently the elected leader or a follower (`Firmware/MiniHead/README.md` §8.5: "these routes always operate on the local device"). The plugin always calls them this way — it never relies on MAC-based relay through a leader.
- **Identify accepts a literal `"SELF"` in place of a MAC** (`wifi_heads.h handleIdentify`) when called on that head's own IP, so the plugin never needs to know/format a head's MAC address for this action.
- **Requires the Art-Net firmware build** (`PLUGIN_ARTNET` defined) for the patch endpoint to exist at all — this is the companion firmware's default build per the plugin spec's own header. A 404 on `Apply`'s patch step most likely means a non-Art-Net firmware build.

## Endpoints intentionally not used

`/api/fixtures`, `/api/send`, cues, sequencer, Art-Net status/bulk-patch, WiFi/AP management — all real, documented endpoints, out of scope for this plugin's v1 feature set per the spec.
