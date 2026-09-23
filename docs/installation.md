# Installation

## Method A — Import the XML (try this first)

1. Copy [`src/MiniHead_Control.xml`](../src/MiniHead_Control.xml) to a USB stick, or a location the console can reach.
2. On the console (or onPC): open the **Plugin Pool**.
3. Right-click an empty slot → **Import** → select `MiniHead_Control.xml`.
4. If it imports without error, skip to [Wiring it to a button](#wiring-it-to-a-button).

If the import fails or the plugin doesn't appear correctly, the XML wrapper's tag structure hasn't been confirmed against a real console — use Method B, which is guaranteed to work regardless.

## Method B — Manual paste (guaranteed to work)

1. On the console (or onPC): open the **Plugin Pool**.
2. Right-click an empty slot → **New**.
3. Open the new plugin's Lua editor.
4. Open [`src/MiniHead_Control.lua`](../src/MiniHead_Control.lua) in a text editor, select all, copy.
5. Paste the full contents into the console's Lua editor, replacing whatever's there.
6. Name the plugin **MiniHead Control** (the code assumes this name in its own usage messages — cosmetic only, doesn't affect function).
7. Close the editor. The console's Lua parser will flag any syntax error immediately at this point — there shouldn't be any (see [Verification checklist](verification-checklist.md) for how to isolate a runtime error instead, which behaves differently).

## Wiring it to a button

The plugin is entirely command-driven — there's no popup window in v1 (see [verification-checklist.md](verification-checklist.md) for why). Everything happens through `Cmd()` calls, so put the ones you use often on executor buttons or a macro page:

```
Cmd('Plugin "MiniHead Control" "List"')
Cmd('Plugin "MiniHead Control" "Discover"')
Cmd('Plugin "MiniHead Control" "Refresh"')
Cmd('Plugin "MiniHead Control" "IdentifyAll"')
Cmd('Plugin "MiniHead Control" "BlackoutAll"')
Cmd('Plugin "MiniHead Control" "RainbowAll"')
```

For per-head actions, either type the full command on the command line with the head's IP, or make one button per head once your rig is patched:

```
Cmd('Plugin "MiniHead Control" "Apply 192.168.1.42"')
Cmd('Plugin "MiniHead Control" "Identify 192.168.1.42"')
```

Run `Cmd('Plugin "MiniHead Control" "Help"')` any time for the full command list, or see the table in the [README](../README.md#commands).

## First run

Invoking the plugin with no argument (or `List` before anything is known) walks you through first-run setup automatically: it prompts for one head's IP, connects, pulls the rest of the fleet from that head's `/api/heads`, and does a bounded scan of nearby addresses for anything not in that list. After that, the head list is saved into the showfile — no rediscovery needed next time you open it, per the spec.

## Auto-refresh (optional)

The plugin's `Refresh` command re-checks online status and re-pulls the head list — it's a plain command, not a background timer (see checklist item — MA3 plugins invoked once don't keep running). To get periodic polling, put `Cmd('Plugin "MiniHead Control" "Refresh"')` on a macro or executor with MA3's own timer/loop functionality, at whatever interval you set via `Settings poll <seconds>` (default 20s, matching the spec's 15–30s target).

## Uninstall

Delete the plugin object from the Plugin Pool. The two show variables it stores data in (`MiniHead_Settings`, `MiniHead_Heads`) are harmless leftover strings in the showfile if you don't clean them up — delete them from Global Variables if you want a clean slate.
