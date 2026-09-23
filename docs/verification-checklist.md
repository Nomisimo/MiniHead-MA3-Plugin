# Verification status

Updated after a live test session against a real grandMA3 onPC 2.4.2.2 installation. Everything below is now either **confirmed working against real hardware**, or **confirmed via grandMA3's own `HelpLua` function export** (not guessed).

## Confirmed working end-to-end, against real hardware

- Plugin loads and runs via the **file-based Import method** (XML + separate `.lua` referenced by `FileName`, placed in `gma3_library/datapools/plugins/<name>/`) — see [installation.md](installation.md).
- Entry point: `function Main(display_handle, arg) ... end` followed by **`return Main`** at the very end of the file. This is the actual, non-obvious requirement — a script that defines `Main` (or even lowercase `main`) but never returns it is loaded without any error and simply never invoked. This was the root cause of a long "nothing happens, no error" debugging session; see the commit history for the full trail.
- `Printf(...)` — writes to the Command Line History. Used for all plugin output.
- `Cmd(...)` — executes a command-line command (used for `NetworkSettings` → `Cmd('Menu "ConnectorConfig"')`).
- Plugin invocation from the command line: **`Plugin <pool-number> "<args>"`** (e.g. `Plugin 4 "Discover 192.168.1.50"`). Note: `Plugin "<Plugin Name>" ...` (name in quotes instead of a number) returned `Illegal object` in testing on this build, even though MA Lighting's own keyword documentation describes it as valid syntax — use the pool number.
- **Full HTTP round-trip to a real MiniHead ESP32**: `require("socket")` (LuaSocket) → `socket.tcp()` → `:connect()/:send()/:receive()/:close()` → real JSON response parsed by this plugin's own JSON decoder → rendered correctly. Confirmed via `Discover <real-ip>` against actual hardware.
- `Confirm(title, message, nil, showCancelBoolean)` — used for all confirm dialogs.
- `TextInput(title, defaultValue)` — used for the first-run seed-IP prompt.
- `GetVar(GlobalVars(), name)` / `SetVar(GlobalVars(), name, value)` — used for persisting settings and the head list into the showfile.
- `FromAddr("Fixture " .. n)` — used to get a handle to an MA3 fixture by number.
- `Set(handle, "Name", newName)` — used for the opt-in fixture-rename feature.
- `SelectionTable()` / `GetSubfixture(index)` / `Get(handle, "FID")` — used to read the current MA3 floor/command-line selection.

All of the above were verified with a throwaway diagnostic plugin (`Echo`/`Printf`/environment probes) before being wired into the real plugin, and the full command set (`Help`, `Discover`, `List`, `SetFixture`, `Apply`, `Rename`, `IdentifyAll`, `BlackoutAll`, `RainbowAll`, `Settings`) was exercised via a local Lua-interpreter test harness with the confirmed API stubbed out, before being tested live. See the repo's commit history for both.

## Not yet live-tested: the `Menu` command

`Menu` (and the bare `Plugin <n>` invocation, which now opens it) builds a `MessageBox` dialog with a dynamically generated button per known head, and a second dialog per head with an editable `Fix#` input plus Apply/Identify/Rename buttons. The `MessageBox` mechanism itself (multi-button dialogs, named input fields, reading `result.result` / `result.inputs[name]` back) is confirmed by MA Lighting's own documented example. The *specific* dialog shapes this plugin builds (variable-length button lists, the input-field round trip) were verified against a local Lua interpreter with `MessageBox` mocked (see the repo's test harnesses), but not yet seen rendered on the actual console. If a button list with 6+ entries renders oddly, or the input field doesn't prefill/round-trip as expected, that's the first thing to check live — `List`/`Discover`/`Apply`/etc. (the typed command path) are unaffected either way, since `Menu` is purely an additional UI layer on top of the same, already-hardware-confirmed logic.

## One soft spot left: reading a fixture's DMX patch

`ma3ReadPatch()` in `src/MiniHead_Control.lua` reads a fixture's universe/address via `Get(handle, "Patch")` (expecting a `"universe.address"` string), falling back to separate `Get(handle, "Universe")` / `Get(handle, "Address")` properties. The **mechanism** (`FromAddr` + `Get`) is confirmed real and correct — the exact **property name** MA3 uses for a fixture's patch is the one piece not yet confirmed against a real patched fixture.

**Impact if the property name is wrong:** `Apply` treats "can't read a patch" and "genuinely unpatched" identically — it asks (via confirm dialog) whether to apply the fixture ID only and skip the patch push. So a wrong property name degrades to "always asks to skip the patch," never a crash or wrong data sent.

**How to verify:** patch a fixture in MA3, link a head to it (`SetFixture <ip> <n>`), then `Apply <ip>`. If it reads correctly you'll see `patch=U.AAA` in the output instead of the "not patched" prompt.

**If it's wrong:** open the plugin's Lua editor, use the built-in **API Description** panel (search for "Patch" or fixture-related property names) or try `Get(handle):Dump()`-style introspection (`Dump()` on a fixture handle prints all its properties to the Command Line History) to find the exact property name, then adjust the two `Get(handle, "...")` calls in `ma3ReadPatch()`.

## How this was actually debugged (for context)

This plugin's Lua API was initially written against a guessed `gma.*` namespace (`gma.feedback`, `gma.gui.msgbox`, `gma.show.getvar`, `gma.socket`, etc.) based on general MA-family plugin conventions. None of it existed. The real API turned out to be flat globals (`Printf`, `Confirm`, `GetVar`, `FromAddr`, ...), confirmed by:

1. Running `HelpLua` on the console, which exports the complete, version-exact function list to `grandMA3_lua_functions.txt` in the grandMA3 library folder — the single most useful thing found during this process.
2. Cross-referencing two independent, real community plugin projects ([LightYourWay/grandMA3-plugin-starter](https://github.com/LightYourWay/grandMA3-plugin-starter), version-pinned to 2.4.2.2, and [patopesto/GrandMA3-Plugins](https://github.com/patopesto/GrandMA3-Plugins)) for the entry-point convention and XML schema.
3. A throwaway diagnostic plugin, iterated live against the console, to isolate exactly which assumption was wrong (entry point vs. function names vs. XML format vs. networking availability) before rewriting the real plugin.

If you ever need to verify something else about the API yourself: **run `HelpLua`** first — it's the fastest path to ground truth, faster than guessing or searching third-party docs.
