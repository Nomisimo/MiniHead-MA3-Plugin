# Verification checklist

This plugin was built without access to a real grandMA3 console or onPC to test against. Everything that is pure Lua — JSON encode/decode, command parsing, persistence, the fixture-range/IP-sort logic, the whole HTTP request/response builder, and every error-handling path — has been unit-tested against a real Lua 5.5 interpreter with the grandMA3 host functions mocked out (including a mock returning real firmware-shaped JSON), and all of that passes cleanly.

What's **not** verified is the handful of places this code calls into the actual MA3 Lua host API. Each one is marked `VERIFY ON CONSOLE` in `src/MiniHead_Control.lua` and fails soft — the plugin keeps working via a typed-input fallback — rather than crashing if a call turns out to be wrong. This doc is the prioritized list of what to check first and how, in the order they'll actually block you.

## 1. Networking (`socketSend`, ~line 330) — blocks everything

**What it does:** opens a TCP connection to a head and sends a raw HTTP/1.1 request, using `gma.socket.new("tcp")`, `:connect()`, `:send()`, `:receive()`, `:close()`.

**Confidence:** moderate. grandMA3 plugins are known to do real network I/O (OSC, external device control is a common plugin use case), but the exact method names on the socket object are a best guess, not a confirmed API.

**How to verify:** run `Cmd('Plugin "MiniHead Control" "Discover" "<a-real-head-ip>"')` with a MiniHead on the network. If it reports "No response from ... on port 80" even though the head is definitely up and reachable by browser, open the plugin in the console's Lua editor and check the error: a `gma.socket` reference error means the API name is wrong.

**If it's wrong:** this is the *only* function that needs to change. Nothing else in the file assumes anything about how the socket works — `httpRequest()` just calls `socketSend()` and gets back a raw string or an error. Swap in whatever the console's actual Lua console reveals (its error messages will name the real object/method) and everything above and below keeps working unmodified.

## 2. Reading the current MA3 fixture selection (`ma3ReadSelectedFixtures`, ~line 660)

**What it does:** tries `gma.show.getvar("SelFixtures")` to read which fixture(s) are currently selected on the command line/floor, so `UseSelection` and `Batch` can auto-fill from a floor selection instead of typing.

**Confidence:** low — this was flagged as an open item in the spec itself. `"SelFixtures"` is a guess at the variable/property name.

**Impact if wrong:** low. Both `UseSelection <ip>` and `Batch` (with no argument) fall back to a clear error telling you to type the value instead (`SetFixture <ip> <n>` / `Batch 1 Thru 8`), which always works since it's just string parsing, not an MA3 read. This is a convenience feature, not a blocker.

**How to fix:** select a fixture in MA3, run `Cmd('Plugin "MiniHead Control" "UseSelection" "<some-ip>"')`, see if it picks up the selection. If not, the right call is likely something reachable via `gma.show.getobj` on the command line's current content — check MA3's Lua API docs in-console (`Help` on the Lua object browser, if your build has one) for how other selection-aware plugins read this.

## 3. Reading a fixture's DMX patch (`ma3ReadPatch`, ~line 620)

**What it does:** given an MA3 fixture number, tries `gma.show.property.get(handle, "Patch")` (expecting a `"universe.address"` string), then falls back to separate `"Universe"`/`"Address"` properties.

**Confidence:** moderate — reading object properties via a handle is a well-established MA3 Lua pattern; the exact property name(s) for patch info are the uncertain part.

**Impact if wrong:** the plugin treats "can't read a patch" and "genuinely unpatched" identically — it asks (via confirm dialog) whether to apply the fixture ID only and skip the patch push. So a wrong property name degrades to "always asks to skip the patch," not a crash or wrong data sent.

**How to fix:** patch a fixture in MA3, run `Apply <ip>` against a head linked to it, see if it reads the patch correctly (feedback line will show `patch=U.AAA`) instead of prompting the "not patched" dialog.

## 4. Renaming a fixture (`ma3RenameFixture`, ~line 670)

**What it does:** `gma.show.property.set(handle, "Name", newName)`.

**Confidence:** higher than #2/#3 — property get/set on an object handle is one of the most fundamental, stable patterns in MA3 Lua plugins, and `"Name"` is very likely the literal property name MA3 itself uses.

**Impact if wrong:** `Rename <ip>` reports a failure; nothing else is affected (this is an isolated, opt-in, confirm-gated feature per the spec — "only with an explicit checkbox confirmation each time, never automatic").

## 5. Plugin invocation argument passing (`main(display, arg)`)

**What it does:** assumes `Cmd('Plugin "MiniHead Control" "List"')` calls `main(display, "List")` — i.e. that grandMA3 passes a quoted argument after the plugin name through to the Lua entry point's second parameter, the standard MA2/MA3 plugin convention.

**Confidence:** moderate-high, but exact quoting rules for multi-word arguments (e.g. `"Apply 192.168.1.42"` vs `"Apply" "192.168.1.42"`) may need adjusting to match your console's actual command-line grammar.

**How to verify:** `Cmd('Plugin "MiniHead Control" "Help"')` should print the command list. If `arg` comes through empty or malformed, check the exact invocation syntax your MA3 version expects (this is easy to spot — `Help`'s output is unmistakable when it works).

## 6. What was *not* attempted: a native popup/table window

The spec's §2 layout describes a real docked/popup window with an editable table, status dots, and per-row buttons. This plugin ships v1 as command-driven (feedback-table output + `gma.gui.confirm`/`msgbox`/`textinput` dialogs) instead, deliberately — building custom MA3 windows is done by authoring an XML Layout resource using MA3's own UI object classes (the same system that defines MA3's native skin), which is a distinct, console-side, trial-and-error-driven skill rather than something guessable from Lua API knowledge alone. Every actual control action (discover, link, apply, batch, identify, blackout, rainbow, rename) is fully implemented and independent of whatever UI shell wraps it — turning this into a docked table view is a matter of building that layout in-console and wiring its buttons to the existing commands in `src/MiniHead_Control.lua`, not rewriting any control logic.

## What's solid, cross-checked against firmware source

The HTTP endpoints, request/response shapes, and behavior notes in [`api-reference.md`](api-reference.md) were confirmed by reading `Nomisimo/MiniHead`'s actual firmware source (not just the spec or the companion app's docs, which turned out to disagree with the running code in a few field names) — see that doc for specifics. This is the part of the plugin most likely to already be exactly right.
