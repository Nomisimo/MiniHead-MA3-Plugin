--[[
  MiniHead Control - grandMA3 plugin
  https://github.com/Nomisimo/MiniHead-MA3-Plugin

  Discovers Nomisimo/MiniHead ESP32 moving-head nodes on the local network,
  links each one to an MA3 fixture number, and pushes fixture ID + DMX patch
  (universe/address, read from MA3's own patch) to the head over HTTP.
  Also drives Identify / Blackout / Rainbow-Demo across the fleet.

  Companion firmware: https://github.com/Nomisimo/MiniHead (Art-Net build)
  Companion app:       https://github.com/Nomisimo/MiniHead-App

  License: GPL-3.0 (see LICENSE)

  --------------------------------------------------------------------------
  Entry point and all grandMA3 Lua API calls below (Printf, Cmd, Confirm,
  TextInput, GetVar/SetVar, FromAddr, Get/Set, SelectionTable, LuaSocket)
  are confirmed against grandMA3 2.4.2.2's own HelpLua function export and
  a live console test session - not guessed. The one remaining soft spot is
  the exact property name for reading a fixture's DMX patch (tries "Patch"
  then "Universe"/"Address"), which fails soft into the existing "not
  patched, apply anyway?" flow rather than crashing. Details:
  docs/verification-checklist.md in this repo.
  --------------------------------------------------------------------------
]]--

-- Top-level plugin varargs - needed for the custom window (Section 11.6):
-- myHandle identifies this component to the UI system (.PluginComponent),
-- signalTable is where click-handler functions are registered by name.
-- Confirmed pattern from two real community plugins (BakaCowpoke/GrandMA3-Lua).
local pluginName, componentName, signalTable, myHandle =
  select(1, ...), select(2, ...), select(3, ...), select(4, ...)

-- ============================================================================
-- SECTION 1: Small utilities
-- ============================================================================

-- `val or fallback` doesn't catch an empty string (only nil/false) - the
-- firmware often reports "" rather than omitting a field, so every display
-- fallback in this file goes through this instead.
local function nz(val, fallback)
  if val == nil or val == "" then return fallback end
  return val
end

local function tokenize(arg)
  local tokens = {}
  for tok in tostring(arg or ""):gmatch("%S+") do
    tokens[#tokens + 1] = tok
  end
  return tokens
end

local function ipParts(ip)
  local a, b, c, d = tostring(ip or ""):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then return nil end
  return tonumber(a), tonumber(b), tonumber(c), tonumber(d)
end

local function ipSortKey(ip)
  local a, b, c, d = ipParts(ip)
  if not a then return 0 end
  return a * 16777216 + b * 65536 + c * 256 + d
end

-- Accepts "1 Thru 8", "1 thru 8", "1-8", "1,3,5", "1 2 3"
local function parseFixtureRange(str)
  str = str or ""
  local a, b = str:match("(%d+)%s*[Tt][Hh][Rr][Uu]%s*(%d+)")
  if not a then a, b = str:match("(%d+)%s*%-%s*(%d+)") end
  if a and b then
    a, b = tonumber(a), tonumber(b)
    if a > b then a, b = b, a end
    local result = {}
    for i = a, b do result[#result + 1] = i end
    return result
  end
  local result = {}
  for tok in str:gmatch("%d+") do
    result[#result + 1] = tonumber(tok)
  end
  return result
end

-- ============================================================================
-- SECTION 2: JSON - minimal pure-Lua encode/decode
-- No dependency on any bundled MA3 json library, so this works regardless of
-- what (if anything) grandMA3's Lua sandbox exposes globally as `json`.
-- ============================================================================

local json = {}

local JSON_ESCAPES = {
  ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function jsonEncodeString(s)
  local out = { '"' }
  for i = 1, #s do
    local c = s:sub(i, i)
    out[#out + 1] = JSON_ESCAPES[c] or c
  end
  out[#out + 1] = '"'
  return table.concat(out)
end

local function jsonIsArray(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  for i = 1, n do
    if t[i] == nil then return false end
  end
  return true
end

function json.encode(v)
  local t = type(v)
  if t == "nil" then
    return "null"
  elseif t == "boolean" then
    return v and "true" or "false"
  elseif t == "number" then
    return tostring(v)
  elseif t == "string" then
    return jsonEncodeString(v)
  elseif t == "table" then
    if jsonIsArray(v) then
      local parts = {}
      for i = 1, #v do parts[#parts + 1] = json.encode(v[i]) end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      local parts = {}
      for k, val in pairs(v) do
        parts[#parts + 1] = jsonEncodeString(tostring(k)) .. ":" .. json.encode(val)
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  end
  return "null"
end

local function jsonSkipWs(s, i)
  while i <= #s do
    local c = s:sub(i, i)
    if c ~= " " and c ~= "\t" and c ~= "\n" and c ~= "\r" then break end
    i = i + 1
  end
  return i
end

local jsonParseValue -- forward declaration (mutually recursive with object/array)

local function jsonParseString(s, i)
  i = i + 1 -- opening quote
  local out = {}
  while i <= #s do
    local c = s:sub(i, i)
    if c == '"' then
      return table.concat(out), i + 1
    elseif c == "\\" then
      local nc = s:sub(i + 1, i + 1)
      if nc == "n" then out[#out + 1] = "\n"
      elseif nc == "t" then out[#out + 1] = "\t"
      elseif nc == "r" then out[#out + 1] = "\r"
      elseif nc == "u" then
        local hex = s:sub(i + 2, i + 5)
        local code = tonumber(hex, 16) or 63
        out[#out + 1] = (code < 128) and string.char(code) or "?"
        i = i + 4
      else
        out[#out + 1] = nc
      end
      i = i + 2
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return table.concat(out), i
end

local function jsonParseNumber(s, i)
  local start = i
  while i <= #s and s:sub(i, i):match("[%d%.%-%+eE]") do i = i + 1 end
  return tonumber(s:sub(start, i - 1)), i
end

local function jsonParseArray(s, i)
  i = i + 1 -- '['
  local arr = {}
  i = jsonSkipWs(s, i)
  if s:sub(i, i) == "]" then return arr, i + 1 end
  while true do
    local val
    val, i = jsonParseValue(s, i)
    arr[#arr + 1] = val
    i = jsonSkipWs(s, i)
    local c = s:sub(i, i)
    if c == "," then
      i = jsonSkipWs(s, i + 1)
    elseif c == "]" then
      return arr, i + 1
    else
      return arr, i + 1
    end
  end
end

local function jsonParseObject(s, i)
  i = i + 1 -- '{'
  local obj = {}
  i = jsonSkipWs(s, i)
  if s:sub(i, i) == "}" then return obj, i + 1 end
  while true do
    i = jsonSkipWs(s, i)
    local key
    key, i = jsonParseString(s, i)
    i = jsonSkipWs(s, i)
    i = i + 1 -- ':'
    i = jsonSkipWs(s, i)
    local val
    val, i = jsonParseValue(s, i)
    obj[key] = val
    i = jsonSkipWs(s, i)
    local c = s:sub(i, i)
    if c == "," then
      i = i + 1
    elseif c == "}" then
      return obj, i + 1
    else
      return obj, i + 1
    end
  end
end

jsonParseValue = function(s, i)
  i = jsonSkipWs(s, i)
  local c = s:sub(i, i)
  if c == '"' then return jsonParseString(s, i)
  elseif c == "{" then return jsonParseObject(s, i)
  elseif c == "[" then return jsonParseArray(s, i)
  elseif c == "t" and s:sub(i, i + 3) == "true" then return true, i + 4
  elseif c == "f" and s:sub(i, i + 4) == "false" then return false, i + 5
  elseif c == "n" and s:sub(i, i + 3) == "null" then return nil, i + 4
  else return jsonParseNumber(s, i)
  end
end

function json.decode(s)
  if not s or s == "" then return nil end
  local ok, val = pcall(function()
    local v = jsonParseValue(s, 1)
    return v
  end)
  if ok then return val end
  return nil
end

-- ============================================================================
-- SECTION 3: Persistence (grandMA3 Global Variables)
-- GetVar/SetVar/GlobalVars confirmed via HelpLua export against 2.4.2.2.
-- Whole head list / settings are stored as one JSON string per variable, so
-- this survives save/reload same as the rest of the showfile.
-- ============================================================================

local SETTINGS_VAR = "MiniHead_Settings"
local HEADS_VAR = "MiniHead_Heads"

local function defaultSettings()
  return {
    seedIP = "",
    pollInterval = 20,   -- seconds; informational, used by your Refresh macro timer
    toastEnabled = true,
    cmdlineLogEnabled = true,
    scanRadius = 8,       -- +/- host addresses probed around the seed IP on Discover
  }
end

local function loadSettings()
  local defaults = defaultSettings()
  local ok, raw = pcall(function() return GetVar(GlobalVars(), SETTINGS_VAR) end)
  if ok and raw and raw ~= "" then
    local data = json.decode(raw)
    if type(data) == "table" then
      for k, v in pairs(defaults) do
        if data[k] == nil then data[k] = v end
      end
      return data
    end
  end
  return defaults
end

local function saveSettings(s)
  pcall(function() SetVar(GlobalVars(), SETTINGS_VAR, json.encode(s)) end)
end

local function loadHeads()
  local ok, raw = pcall(function() return GetVar(GlobalVars(), HEADS_VAR) end)
  if ok and raw and raw ~= "" then
    local data = json.decode(raw)
    if type(data) == "table" then return data end
  end
  return {}
end

local function saveHeads(list)
  pcall(function() SetVar(GlobalVars(), HEADS_VAR, json.encode(list)) end)
end

-- ============================================================================
-- SECTION 4: Feedback / error surfacing (spec S6)
-- Printf writes to the Command Line History; Confirm(..., false) is used as
-- a blocking "toast" for errors (both confirmed via HelpLua export).
-- ============================================================================

local function notifyInfo(msg)
  Printf("[MiniHead] " .. msg)
end

local function notifyError(msg)
  local s = loadSettings()
  if s.cmdlineLogEnabled ~= false then
    Printf("[MiniHead] ERROR: " .. msg)
  end
  if s.toastEnabled ~= false then
    pcall(function() Confirm("MiniHead - Error", msg, nil, false) end)
  end
end

-- ============================================================================
-- SECTION 5: Head-list helpers
-- ============================================================================

local function findHeadByIp(ip)
  local heads = loadHeads()
  for idx, h in ipairs(heads) do
    if h.ip == ip then return h, idx, heads end
  end
  return nil, nil, heads
end

local function renderHeadsTable()
  local heads = loadHeads()
  table.sort(heads, function(a, b) return ipSortKey(a.ip) < ipSortKey(b.ip) end)
  Printf("[MiniHead] " .. #heads .. " head(s) known:")
  if #heads == 0 then
    Printf("  (none yet - run: Discover <ip>)")
    return
  end
  Printf(string.format("  %-3s %-15s %-16s %-5s %-9s %-8s",
    "St", "IP", "Name", "Fix#", "U.Addr", "Role"))
  for _, h in ipairs(heads) do
    local status = h.online and "On" or "Off"
    local ua = "--"
    if h.universe and h.addr then
      ua = h.universe .. "." .. string.format("%03d", h.addr)
    end
    Printf(string.format("  %-3s %-15s %-16s %-5s %-9s %-8s",
      status, nz(h.ip, "-"), nz(h.name, "-"),
      tostring(h.fixtureNo or "-"), ua, nz(h.role, "-")))
  end
end

-- ============================================================================
-- SECTION 6: HTTP transport (LuaSocket)
-- Confirmed available on this build via `require("socket")` (a live test on
-- 2.4.2.2 returned a real module table, and io/os are the standard Lua 5.4
-- libraries - not a custom/guessed API this time).
-- ============================================================================

local function buildHttpRequest(method, ip, path, bodyStr)
  local lines = {}
  lines[#lines + 1] = method .. " " .. path .. " HTTP/1.1"
  lines[#lines + 1] = "Host: " .. ip
  lines[#lines + 1] = "User-Agent: MiniHead-MA3-Plugin"
  lines[#lines + 1] = "Accept: application/json"
  lines[#lines + 1] = "Connection: close"
  if bodyStr and #bodyStr > 0 then
    lines[#lines + 1] = "Content-Type: application/json"
    lines[#lines + 1] = "Content-Length: " .. tostring(#bodyStr)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = bodyStr or ""
  return table.concat(lines, "\r\n")
end

local function parseHttpResponse(raw)
  if not raw or #raw == 0 then return nil, nil end
  local headerEnd = raw:find("\r\n\r\n", 1, true)
  if not headerEnd then return nil, nil end
  local head = raw:sub(1, headerEnd - 1)
  local body = raw:sub(headerEnd + 4)
  local code = head:match("HTTP/1%.[01]%s+(%d+)")
  return tonumber(code), body
end

local function socketSend(ip, port, requestStr, timeoutMs)
  local ok, resultOrErr = pcall(function()
    local socket = require("socket")
    local sock = socket.tcp()
    if not sock then error("socket.tcp() returned nil") end
    sock:settimeout((timeoutMs or 3000) / 1000)
    local connected, connErr = sock:connect(ip, port)
    if not connected then error(connErr or "connect failed") end
    sock:send(requestStr)
    local chunks = {}
    local guard = 0
    while guard < 64 do -- bounded read loop; response bodies here are tiny
      guard = guard + 1
      local chunk, err, partial = sock:receive(2048)
      if chunk and #chunk > 0 then
        chunks[#chunks + 1] = chunk
      elseif partial and #partial > 0 then
        chunks[#chunks + 1] = partial
        break
      else
        break
      end
      if err then break end
    end
    sock:close()
    return table.concat(chunks)
  end)
  if ok and resultOrErr and #resultOrErr > 0 then
    return resultOrErr, nil
  end
  return nil, (not ok and tostring(resultOrErr)) or "no response"
end

-- Returns: ok(bool), httpStatus(number|nil), bodyString(string|nil), err(string|nil)
local function httpRequest(ip, method, path, bodyTable, timeoutMs)
  local bodyStr = bodyTable and json.encode(bodyTable) or nil
  local reqStr = buildHttpRequest(method, ip, path, bodyStr)
  local raw, err = socketSend(ip, 80, reqStr, timeoutMs)
  if not raw then
    return false, nil, nil, err or "no response"
  end
  local code, respBody = parseHttpResponse(raw)
  if not code then
    return false, nil, nil, "unparseable response"
  end
  return true, code, respBody, nil
end

-- ============================================================================
-- SECTION 7: MiniHead API client
-- Endpoints confirmed against Nomisimo/MiniHead firmware source
-- (Firmware/MiniHead/main/core/wifi/*.h) and Firmware/MiniHead/README.md S8,
-- not just the plugin spec. See docs/api-reference.md for field-by-field
-- notes and where the spec/App-docs/firmware disagreed.
--
-- Every api.* function returns a trailing diagnostic string on failure -
-- either "HTTP <code>" (reached the head, it rejected the request) or the
-- raw transport error from socketSend (didn't reach it at all).
-- ============================================================================

local api = {}

-- timeoutMs defaults to 800 for a real probe; the subnet scan passes a much
-- shorter one since it's hitting mostly-empty addresses sequentially and
-- every extra millisecond there is felt directly as UI blocking.
function api.getStatus(ip, timeoutMs)
  local ok, code, body, err = httpRequest(ip, "GET", "/api/status", nil, timeoutMs or 800)
  if ok and code == 200 then
    return true, json.decode(body)
  end
  return false, nil, err or ("HTTP " .. tostring(code))
end

function api.getHeads(ip)
  local ok, code, body, err = httpRequest(ip, "GET", "/api/heads", nil, 2500)
  if ok and code == 200 then
    local data = json.decode(body)
    if type(data) == "table" then return true, data end
    return false, nil, "bad JSON in response"
  end
  return false, nil, err or ("HTTP " .. tostring(code))
end

-- Always called against the head's OWN ip - config routes have no leader
-- redirect (Firmware/MiniHead/README.md S8.5).
function api.setFixID(ip, fixID)
  local ok, code, _, err = httpRequest(ip, "POST", "/api/config/fixid", { fixID = fixID }, 2000)
  return ok and code == 200, err or ("HTTP " .. tostring(code))
end

function api.setName(ip, name)
  local ok, code, _, err = httpRequest(ip, "POST", "/api/config/name", { name = name }, 2000)
  return ok and code == 200, err or ("HTTP " .. tostring(code))
end

-- POST /api/artnet/patch (not /api/config/patch - see docs/api-reference.md).
-- Requires the head's firmware to be built with PLUGIN_ARTNET, which is the
-- companion firmware's default build per the plugin spec.
function api.setPatch(ip, universe, startAddr)
  local ok, code, _, err = httpRequest(ip, "POST", "/api/artnet/patch", { universe = universe, startAddr = startAddr }, 2000)
  return ok and code == 200, code, err
end

-- "SELF" is a literal accepted by the firmware so we never need to know a
-- head's own MAC to identify it - call this directly against its own IP.
function api.identify(ip, on)
  local ok, code, _, err = httpRequest(ip, "POST", "/api/heads/SELF/identify", { on = on }, 1500)
  return ok and code == 200, err or ("HTTP " .. tostring(code))
end

-- Global action: broadcasts to all heads via UDP regardless of which head's
-- IP receives the HTTP call.
function api.blackoutAll(ip)
  local ok, code, _, err = httpRequest(ip, "POST", "/api/blackout", nil, 1500)
  return ok and code == 200, err or ("HTTP " .. tostring(code))
end

function api.rainbowAll(ip, on)
  local ok, code, _, err = httpRequest(ip, "POST", "/api/rainbow", { on = on }, 1500)
  return ok and code == 200, err or ("HTTP " .. tostring(code))
end

-- Distinct from Rainbow: firmware's own sinusoid demo animation.
function api.demoAll(ip, on)
  local ok, code, _, err = httpRequest(ip, "POST", "/api/demo", { on = on }, 1500)
  return ok and code == 200, err or ("HTTP " .. tostring(code))
end

-- ============================================================================
-- SECTION 8: MA3-internal integration
-- FromAddr / Get / Set / SelectionTable / GetSubfixture all confirmed via
-- the HelpLua export against 2.4.2.2. The one soft spot left is the exact
-- property name for a fixture's DMX patch (tries "Patch" then separate
-- "Universe"/"Address") - fails soft into the existing "not patched, apply
-- anyway?" confirm flow rather than crashing. See verification-checklist.md.
-- ============================================================================

-- Reads the DMX universe/address MA3 has patched for a fixture number.
-- Returns universe, address (both nil if unpatched, or property name wrong).
local function ma3ReadPatch(fixtureNo)
  if not fixtureNo then return nil, nil end
  local ok, uni, addr = pcall(function()
    local handle = FromAddr("Fixture " .. tostring(fixtureNo))
    if not handle then return nil, nil end
    local patchStr = Get(handle, "Patch")
    if patchStr and tostring(patchStr) ~= "" then
      local u, a = tostring(patchStr):match("(%d+)%.(%d+)")
      if u and a then return tonumber(u), tonumber(a) end
    end
    local u2 = Get(handle, "Universe")
    local a2 = Get(handle, "Address")
    if u2 and a2 then return tonumber(u2), tonumber(a2) end
    return nil, nil
  end)
  if ok then return uni, addr end
  return nil, nil
end

-- Reads the current MA3 command-line/floor fixture selection as a list of
-- Fixture Numbers (FIDs) - via SelectionTable -> GetSubfixture -> Get(.,"FID").
local function ma3ReadSelectedFixtures()
  local ok, result = pcall(function()
    local indices = SelectionTable()
    local fixtureNumbers = {}
    for _, idx in ipairs(indices or {}) do
      local handle = GetSubfixture(idx)
      if handle then
        local fid = Get(handle, "FID")
        if fid then fixtureNumbers[#fixtureNumbers + 1] = tonumber(fid) end
      end
    end
    return fixtureNumbers
  end)
  if ok and result and #result > 0 then return result end
  return nil
end

local function ma3RenameFixture(fixtureNo, newName)
  local ok = pcall(function()
    local handle = FromAddr("Fixture " .. tostring(fixtureNo))
    if not handle then error("no handle for Fixture " .. tostring(fixtureNo)) end
    Set(handle, "Name", newName)
  end)
  return ok
end

local function promptText(title, default)
  local ok, result = pcall(function() return TextInput(title, default or "") end)
  if ok and result and result ~= "" then return result end
  return nil
end

local function confirmDialog(title, msg)
  local ok, result = pcall(function() return Confirm(title, msg, nil, true) end)
  return ok and result and true or false
end

-- ============================================================================
-- SECTION 9: Discovery
-- ============================================================================

-- Bounded probe: only +/-radius host addresses around the seed, never a
-- blind /24 sweep - keeps a plugin invocation from hanging the console on a
-- mostly-empty subnet. Widen via: Settings radius <n>.
local function subnetProbe(seedIp, radius, knownHeads)
  local a, b, c, d = ipParts(seedIp)
  if not a then return {} end
  local known = {}
  for _, h in ipairs(knownHeads or {}) do known[h.ip] = true end
  local lo = math.max(1, d - radius)
  local hi = math.min(254, d + radius)
  local found = {}
  for i = lo, hi do
    if i ~= d then
      local ip = a .. "." .. b .. "." .. c .. "." .. i
      if not known[ip] then
        -- Short timeout: this runs sequentially and blocks the UI for its
        -- duration - up to 2*radius probes, so every ms here counts.
        local ok = api.getStatus(ip, 150)
        if ok then found[#found + 1] = ip end
      end
    end
  end
  return found
end

local function doDiscover(seedIp)
  -- Reuse the last known seed IP before prompting - "Discover Heads" in the
  -- Window was re-prompting via TextInput every time, whose modal popup
  -- behind the still-open window looked like onPC hanging.
  if not seedIp or seedIp == "" then
    local existingSettings = loadSettings()
    seedIp = existingSettings.seedIP
  end
  if not seedIp or seedIp == "" then
    seedIp = promptText("MiniHead - Enter a head's IP address", "192.168.1.")
  end
  if not seedIp or seedIp == "" then
    notifyInfo("Discover cancelled - no IP given.")
    return
  end

  notifyInfo("Probing " .. seedIp .. " ...")
  local okStatus, _, statusErr = api.getStatus(seedIp)
  if not okStatus then
    notifyError("No response from " .. seedIp .. " on port 80 [" .. tostring(statusErr) .. "]. " ..
      "If the head is reachable by browser but this still fails, the error in [] is from the plugin's " ..
      "network call - otherwise check the IP and that the head is powered and on this network.")
    return
  end

  local settings = loadSettings()
  settings.seedIP = seedIp
  saveSettings(settings)

  -- fixtureNo defaults to the head's own stored fixID (spec S4) until the
  -- user links it to something else or a prior session already did.
  local heads = {}
  local okHeads, list = api.getHeads(seedIp)
  if okHeads and list then
    for _, h in ipairs(list) do
      heads[#heads + 1] = {
        mac = h.mac, ip = h.ip, name = h.name,
        fixtureNo = (h.fixID and h.fixID > 0) and h.fixID or nil,
        role = h.role, online = true,
      }
    end
    notifyInfo(#heads .. " head(s) found via " .. seedIp .. ".")
  else
    heads[1] = { mac = "", ip = seedIp, name = "Head", fixtureNo = nil, role = "LEADER", online = true }
    notifyInfo("Connected to " .. seedIp .. " but it returned no /api/heads list - added it alone.")
  end

  -- Preserve existing fixture links for heads we already knew about.
  local existing = loadHeads()
  local byIp = {}
  for _, h in ipairs(existing) do byIp[h.ip] = h end
  for _, h in ipairs(heads) do
    local prev = byIp[h.ip]
    if prev then h.fixtureNo = prev.fixtureNo end
  end
  saveHeads(heads)

  local radius = settings.scanRadius or 20
  notifyInfo("Scanning +/-" .. radius .. " addresses around " .. seedIp .. " for extra heads...")
  local extra = subnetProbe(seedIp, radius, heads)
  if #extra > 0 then
    notifyInfo(#extra .. " extra head(s) found by subnet scan (not in that list - re-run Discover on one of them to merge): " .. table.concat(extra, ", "))
  end

  renderHeadsTable()
end

local function doRefresh()
  local heads = loadHeads()
  if #heads == 0 then
    notifyInfo("No heads known yet - run: Discover <ip>")
    return
  end

  local leaderIp = nil
  for _, h in ipairs(heads) do
    if h.role == "LEADER" then leaderIp = h.ip break end
  end
  local sourceIp = leaderIp or heads[1].ip

  local okHeads, list, headsErr = api.getHeads(sourceIp)
  if okHeads and list then
    local prevByIp = {}
    for _, h in ipairs(heads) do prevByIp[h.ip] = h end
    local fresh = {}
    for _, h in ipairs(list) do
      local prev = prevByIp[h.ip]
      fresh[#fresh + 1] = {
        mac = h.mac, ip = h.ip, name = h.name, role = h.role,
        fixtureNo = prev and prev.fixtureNo or ((h.fixID and h.fixID > 0) and h.fixID or nil),
        online = true,
      }
    end
    heads = fresh
  else
    notifyError("Could not refresh the head list from " .. sourceIp .. " [" .. tostring(headsErr) .. "] - keeping the last known list.")
  end

  for _, h in ipairs(heads) do
    h.online = api.getStatus(h.ip) and true or false
  end

  saveHeads(heads)
  renderHeadsTable()
end

-- ============================================================================
-- SECTION 10: Apply logic (single + batch)
-- ============================================================================

-- FixID (pushed to the ESP) and MA3 Fixture Number are the same number -
-- one field, no separate "set the ESP's ID" step.
local function doSetFixture(ip, val)
  local head, _, heads = findHeadByIp(ip)
  if not head then notifyError("No known head at " .. tostring(ip) .. "."); return end
  local n = tonumber(val)
  head.fixtureNo = n
  saveHeads(heads)
  if n then
    notifyInfo(ip .. " linked to MA3 Fixture " .. n .. " (not yet pushed - run: Apply " .. ip .. ")")
  else
    notifyInfo(ip .. " fixture link cleared.")
  end
end

local function doSetName(ip, name)
  local head, _, heads = findHeadByIp(ip)
  if not head then notifyError("No known head at " .. tostring(ip) .. "."); return end
  head.name = name
  saveHeads(heads)
  notifyInfo(ip .. " name field set to \"" .. name .. "\" (not yet pushed - run: Apply " .. ip .. ")")
end

-- Diagnostic: dumps every property MA3 actually has on a fixture handle to
-- the Command Line History, to find the real patch property name (Get(h,
-- "Patch")/"Universe"/"Address" are a guess that's been confirmed wrong -
-- "Address finden geht nicht"). Run against a fixture that IS patched in
-- MA3 and look for whatever property holds "1.001"-style or separate
-- universe/address values.
local function doDumpFixture(fixtureNo)
  local n = tonumber(fixtureNo)
  if not n then notifyError("Usage: DumpFixture <n> (an MA3 fixture number)"); return end
  local ok, err = pcall(function()
    local handle = FromAddr("Fixture " .. tostring(n))
    if not handle then error("FromAddr('Fixture " .. n .. "') returned nil") end
    Printf("[MiniHead] Dumping Fixture " .. n .. " - look below for Patch/Universe/Address:")
    handle:Dump()
  end)
  if not ok then
    notifyError("DumpFixture failed: " .. tostring(err))
  end
end

local function doUseSelection(ip)
  local sel = ma3ReadSelectedFixtures()
  if not sel or #sel == 0 then
    notifyError("Could not read a fixture selection from MA3 (or nothing is selected). Type it instead: SetFixture " .. tostring(ip) .. " <n>")
    return
  end
  doSetFixture(ip, tostring(sel[1]))
end

-- overrideUniverse/overrideAddr let a caller (the Edit dialog) supply a
-- patch by hand when MA3's own ma3ReadPatch() can't find one - still never
-- invented by the plugin itself, just typed in by the user that one time.
local function doApply(ip, overrideUniverse, overrideAddr)
  local head, _, heads = findHeadByIp(ip)
  if not head then
    notifyError("No known head at " .. tostring(ip) .. ". Run Discover or List first.")
    return
  end

  -- Each of name / fixID / patch pushes independently and reports its own
  -- failure - one failing must not silently block the others (a name-push
  -- failure used to return early and skip fixID+patch entirely).
  if head.name and head.name ~= "" then
    local okName, nameErr = api.setName(head.ip, head.name)
    if okName then
      notifyInfo("Name pushed to " .. head.ip .. ": \"" .. head.name .. "\"")
    else
      notifyError("Name push failed on " .. head.ip .. " [" .. tostring(nameErr) .. "] - continuing with fixID/patch.")
    end
  end

  -- Only ever pushes an address that MA3 itself reports as patched under
  -- this Fix#, or one the user typed in by hand this time - never invented.
  local universe, addr = overrideUniverse, overrideAddr
  if (not universe or not addr) and head.fixtureNo then
    universe, addr = ma3ReadPatch(head.fixtureNo)
    if not universe then
      local proceed = confirmDialog("MiniHead - Fixture Not Patched",
        "Fixture " .. head.fixtureNo .. " has no readable DMX patch in MA3.\n" ..
        "Apply the fixture ID only and skip the patch push?")
      if not proceed then
        notifyInfo("Apply cancelled for " .. ip .. ".")
        return
      end
    end
  end

  local okId, idErr = api.setFixID(head.ip, head.fixtureNo or 0)
  if not okId then
    notifyError("Fixture ID push failed on " .. head.ip .. " [" .. tostring(idErr) .. "].")
  else
    notifyInfo("Fixture ID pushed to " .. head.ip .. ": " .. tostring(head.fixtureNo or 0))
  end

  if universe and addr then
    local okPatch, code, patchErr = api.setPatch(head.ip, universe, addr)
    if okPatch then
      head.universe, head.addr = universe, addr
      notifyInfo("Patch pushed to " .. head.ip .. ": " .. universe .. "." .. string.format("%03d", addr))
    else
      notifyError("Patch push failed on " .. head.ip ..
        " [" .. tostring(patchErr or code) .. "]. If this is HTTP 404, confirm the head's firmware has Art-Net (PLUGIN_ARTNET) enabled.")
      head.universe, head.addr = nil, nil
    end
  end

  saveHeads(heads)
end

local function doIdentify(ip)
  local head = findHeadByIp(ip)
  if not head then notifyError("No known head at " .. tostring(ip) .. "."); return end
  local ok, err = api.identify(head.ip, true)
  if ok then
    notifyInfo("Identify flashed on " .. head.ip .. ".")
    -- Timer()'s delay_time unit was never confirmed and the auto-off
    -- wasn't visibly happening - switched to a real, exact wait using
    -- os.clock() (confirmed available: full standard Lua os/io libraries,
    -- not a custom/sandboxed subset - see verification-checklist.md).
    -- Blocks this click handler for 1s, which is fine for a one-shot
    -- action the user is already standing there waiting on - unlike the
    -- Window's own open-ended wait loop, this is short and bounded.
    local clockStart = os.clock()
    while os.clock() - clockStart < 1.0 do end
    local offOk, offErr = api.identify(head.ip, false)
    if not offOk then
      Printf("[MiniHead] Identify auto-off failed for " .. head.ip .. " [" .. tostring(offErr) .. "].")
    end
  else
    notifyError("Identify failed on " .. head.ip .. " [" .. tostring(err) .. "].")
  end
end

local function doIdentifyAll()
  local heads = loadHeads()
  if #heads == 0 then notifyInfo("No heads known yet."); return end
  local okCount = 0
  for _, h in ipairs(heads) do
    if api.identify(h.ip, true) then okCount = okCount + 1 end
  end
  notifyInfo("Identify sent to " .. okCount .. "/" .. #heads .. " head(s).")
end

local function anyReachableIp()
  local heads = loadHeads()
  for _, h in ipairs(heads) do
    if h.role == "LEADER" then return h.ip end
  end
  if heads[1] then return heads[1].ip end
  return nil
end

local function doBlackoutAll()
  local ip = anyReachableIp()
  if not ip then notifyInfo("No heads known yet."); return end
  local ok, err = api.blackoutAll(ip)
  if ok then
    notifyInfo("Blackout sent (all heads).")
  else
    notifyError("Blackout failed via " .. ip .. " [" .. tostring(err) .. "]. Try Refresh.")
  end
end

local function doRainbowAll(on)
  local ip = anyReachableIp()
  if not ip then notifyInfo("No heads known yet."); return end
  local ok, err = api.rainbowAll(ip, on)
  if ok then
    notifyInfo("Rainbow demo " .. (on and "started" or "stopped") .. " (all heads).")
  else
    notifyError("Rainbow command failed via " .. ip .. " [" .. tostring(err) .. "]. Try Refresh.")
  end
end

local function doDemoAll(on)
  local ip = anyReachableIp()
  if not ip then notifyInfo("No heads known yet."); return end
  local ok, err = api.demoAll(ip, on)
  if ok then
    notifyInfo("Demo animation " .. (on and "started" or "stopped") .. " (all heads).")
  else
    notifyError("Demo command failed via " .. ip .. " [" .. tostring(err) .. "]. Try Refresh.")
  end
end

local function doBatch(rangeArg)
  local fixtureNumbers
  if rangeArg and rangeArg ~= "" then
    fixtureNumbers = parseFixtureRange(rangeArg)
  else
    fixtureNumbers = ma3ReadSelectedFixtures()
  end
  if not fixtureNumbers or #fixtureNumbers == 0 then
    notifyError("No fixture range given. Select a range in MA3 first, or type it: Batch 1 Thru 8")
    return
  end
  table.sort(fixtureNumbers)

  local heads = loadHeads()
  if #heads == 0 then notifyInfo("No heads known yet - run: Discover <ip>"); return end
  table.sort(heads, function(a, b) return ipSortKey(a.ip) < ipSortKey(b.ip) end)

  local n = math.min(#fixtureNumbers, #heads)
  if n == 0 then notifyInfo("Nothing to match."); return end

  notifyInfo("Batch preview (" .. n .. " pair(s), matched by IP order):")
  for i = 1, n do
    Printf("  Fixture " .. fixtureNumbers[i] .. "  <->  " .. heads[i].ip .. " (" .. nz(heads[i].name, "?") .. ")")
  end
  if #fixtureNumbers ~= #heads then
    notifyInfo("Note: " .. #fixtureNumbers .. " fixture(s) selected but " .. #heads .. " head(s) known - matching the first " .. n .. ".")
  end

  if not confirmDialog("MiniHead - Batch Apply", "Apply fixID + patch to " .. n .. " head(s) as previewed above?") then
    notifyInfo("Batch apply cancelled.")
    return
  end

  for i = 1, n do
    heads[i].fixtureNo = fixtureNumbers[i]
  end
  saveHeads(heads)
  for i = 1, n do
    doApply(heads[i].ip)
  end
  notifyInfo("Batch apply complete.")
end

local function doRename(ip)
  local head = findHeadByIp(ip)
  if not head then notifyError("No known head at " .. tostring(ip) .. "."); return end
  if not head.fixtureNo then
    notifyError(ip .. " isn't linked to an MA3 fixture yet - use SetFixture first.")
    return
  end
  local msg = "Rename MA3 Fixture " .. head.fixtureNo .. " to \"" .. (head.name or "") .. "\" (the head's own name)?\n" ..
    "This overwrites the fixture's current name in your show."
  if not confirmDialog("MiniHead - Rename Fixture", msg) then
    notifyInfo("Rename cancelled.")
    return
  end
  if ma3RenameFixture(head.fixtureNo, head.name or "") then
    notifyInfo("Fixture " .. head.fixtureNo .. " renamed to \"" .. (head.name or "") .. "\".")
  else
    notifyError("Rename failed - could not write the fixture name in MA3 (see docs/verification-checklist.md).")
  end
end

-- ============================================================================
-- SECTION 11: Settings & help
-- ============================================================================

local function doSettings()
  local s = loadSettings()
  Printf("[MiniHead] Settings:")
  Printf("  Poll interval: " .. s.pollInterval .. "s (wire Refresh to a timed macro at this interval)")
  Printf("  Toast on error: " .. tostring(s.toastEnabled))
  Printf("  Command-line log: " .. tostring(s.cmdlineLogEnabled))
  Printf("  Subnet scan radius: +/-" .. s.scanRadius)
  Printf("  Change with: Settings poll <sec> | Settings toast <on|off> | Settings log <on|off> | Settings radius <n>")
end

local function doSettingsSet(key, val)
  local s = loadSettings()
  key = (key or ""):lower()
  if key == "poll" then
    local n = tonumber(val)
    if n and n >= 5 then s.pollInterval = n else notifyError("Poll interval must be a number >= 5."); return end
  elseif key == "toast" then
    s.toastEnabled = (val == "on" or val == "true")
  elseif key == "log" then
    s.cmdlineLogEnabled = (val == "on" or val == "true")
  elseif key == "radius" then
    local n = tonumber(val)
    if n and n > 0 then s.scanRadius = n else notifyError("Radius must be a positive number."); return end
  else
    notifyError("Unknown setting: " .. tostring(key))
    return
  end
  saveSettings(s)
  doSettings()
end

local function doHelp()
  local lines = {
    "MiniHead Control - commands, e.g. Plugin \"MiniHead Control\" \"List\":",
    "  Menu                        - open the clickable menu (buttons + fields, no typing)",
    "  Window                      - open the full custom window (experimental, see docs)",
    "  Discover [ip]               - set/seed a head IP, pull /api/heads, scan nearby",
    "  List                        - show the head table (plain text)",
    "  Refresh                     - re-check online status + re-pull head list",
    "  SetFixture <ip> <n>         - link a head to MA3 fixture number n (also its fixture ID - same number)",
    "  UseSelection <ip>           - fill SetFixture from the current MA3 selection",
    "  DumpFixture <n>              - diagnostic: dump all of MA3 fixture n's properties",
    "  Apply <ip>                  - push fixture number + patch to that head",
    "  Identify <ip>               - flash one head",
    "  IdentifyAll                 - flash all heads",
    "  BlackoutAll                 - blackout all heads",
    "  RainbowAll / RainbowOff     - start/stop rainbow hue-cycle on all heads",
    "  DemoAll / DemoOff           - start/stop the sinusoid demo animation on all heads",
    "  Batch [range]               - batch-link+apply an MA3 selection (or typed range), matched by IP order",
    "  Rename <ip>                 - write the head's name onto its linked MA3 fixture (confirms every time)",
    "  NetworkSettings              - open MA3's Art-Net Connector Configuration menu",
    "  Settings / Settings <k> <v> - view or change poll interval, toasts, logging, scan radius",
    "  Help                        - this list",
  }
  for _, l in ipairs(lines) do Printf(l) end
end

-- ============================================================================
-- SECTION 11.5: Interactive menu (MessageBox-based clickable UI)
-- Not a persistent docked table (that needs XML Layout authoring, a
-- different, unverified undertaking - see verification-checklist.md) but a
-- real point-and-click UI built entirely on the confirmed MessageBox API:
-- a main menu listing heads as buttons, and a per-head dialog with an
-- editable Fix# field plus Apply/Identify/Rename buttons.
-- doMenu and doEditHead call each other, so both are forward-declared and
-- every call back into either one is a `return`ed tail call - the pair can
-- be clicked back and forth indefinitely without growing the Lua stack.
-- ============================================================================

local doMenu
local doEditHead

doEditHead = function(ip)
  local head, _, heads = findHeadByIp(ip)
  if not head then notifyError("No known head at " .. tostring(ip) .. "."); return doMenu() end

  local ua = "not read yet"
  if head.universe and head.addr then
    ua = head.universe .. "." .. string.format("%03d", head.addr)
  end
  local msg = "IP: " .. head.ip .. "\n" ..
    "MAC: " .. nz(head.mac, "-") .. "\n" ..
    "Role: " .. nz(head.role, "-") .. "   Status: " .. (head.online and "Online" or "Offline") .. "\n" ..
    "Last applied patch: " .. ua

  local result = MessageBox({
    title = "MiniHead - " .. nz(head.name, head.ip),
    message = msg,
    inputs = { { name = "Fix#", value = tostring(head.fixtureNo or "") } },
    commands = {
      { value = 1, name = "Apply" },
      { value = 2, name = "Identify" },
      { value = 3, name = "Rename" },
      { value = 4, name = "Back" },
    },
  })

  if not result or not result.success then return doMenu() end

  local newFixStr = result.inputs and result.inputs["Fix#"]
  if newFixStr ~= nil and newFixStr ~= tostring(head.fixtureNo or "") then
    doSetFixture(ip, newFixStr)
  end

  if result.result == 1 then
    doApply(ip)
    return doEditHead(ip)
  elseif result.result == 2 then
    doIdentify(ip)
    return doEditHead(ip)
  elseif result.result == 3 then
    doRename(ip)
    return doEditHead(ip)
  else
    return doMenu()
  end
end

doMenu = function()
  local heads = loadHeads()
  table.sort(heads, function(a, b) return ipSortKey(a.ip) < ipSortKey(b.ip) end)

  local msg
  if #heads == 0 then
    msg = "No heads known yet. Tap Discover to find one."
  else
    local lines = {}
    for _, h in ipairs(heads) do
      lines[#lines + 1] = string.format("%s  %-15s  Fix#%-4s  %s",
        h.online and "On " or "Off", h.ip, tostring(h.fixtureNo or "-"), nz(h.name, "-"))
    end
    msg = table.concat(lines, "\n")
  end

  local commands = {
    { value = 1, name = "Discover" },
    { value = 2, name = "Refresh" },
    { value = 3, name = "Identify All" },
    { value = 4, name = "Blackout All" },
    { value = 5, name = "Rainbow All" },
    { value = 7, name = "Demo All" },
    { value = 6, name = "Settings" },
  }
  local ipByValue = {}
  for i, h in ipairs(heads) do
    local v = 100 + i
    commands[#commands + 1] = { value = v, name = "Edit " .. h.ip }
    ipByValue[v] = h.ip
  end

  local result = MessageBox({
    title = "MiniHead Control",
    message = msg,
    commands = commands,
  })
  if not result or not result.success then return end

  local r = result.result
  if r == 1 then doDiscover(nil); return doMenu()
  elseif r == 2 then doRefresh(); return doMenu()
  elseif r == 3 then doIdentifyAll(); return doMenu()
  elseif r == 4 then doBlackoutAll(); return doMenu()
  elseif r == 5 then doRainbowAll(true); return doMenu()
  elseif r == 7 then doDemoAll(true); return doMenu()
  elseif r == 6 then doSettings(); return doMenu()
  elseif ipByValue[r] then return doEditHead(ipByValue[r])
  end
end

-- ============================================================================
-- SECTION 11.6: Custom persistent-feeling window (experimental)
--
-- *** NOT YET LIVE-TESTED - see docs/verification-checklist.md ***
-- Built on GetFocusDisplay().ScreenOverlay:Append('ClassName') + dot-notation
-- properties + .PluginComponent/.Clicked/signalTable for click handling -
-- confirmed real by two independent working community plugins and grandMA3's
-- own shipped message_box.uixml (same class names: TitleBar, TitleButton,
-- CloseButton, DialogFrame, ScrollBox, ScrollBarV, UILayoutGrid, Button,
-- LineEdit). This is NOT a docked/ScreenContent window - confirmed via
-- grandMA3's own add_window.lua that ScreenContent window types are a fixed,
-- engine-built list with no plugin registration hook. It's an overlay that
-- stays open (AutoClose='No') for as long as its Lua task keeps running.
--
-- v1 behavior: row/global actions call straight into the already
-- hardware-verified do* functions and leave the window open as-is; the
-- displayed data is a snapshot from when the window opened - close and
-- reopen (Window command) to see fresh state. Only Close rebuilds nothing
-- and just tears the window down.
-- ============================================================================

-- doWindow and doSettingsDialog close one another (Settings closes the main
-- window and opens itself; OK/Cancel/close on Settings reopens the main
-- window), so both are forward-declared and call each other by upvalue.
local doWindow
local doSettingsDialog

doWindow = function()
  local heads = loadHeads()
  table.sort(heads, function(a, b) return ipSortKey(a.ip) < ipSortKey(b.ip) end)

  local continue = false

  local ok, err = pcall(function()

    -- Small helper: some color references may not exist on every build:
    -- try each individually so a wrong guess just skips that one color
    -- rather than failing the whole window build (like the UILayoutGrid
    -- indexing bug did).
    local function tryColor(obj, prop, colorName)
      pcall(function() obj[prop] = colorName end)
    end

    -- Ground truth (from shared/resource/textures/graphics.textures.xml and
    -- shared/resource/lib_color_themes/default.xml in the grandMA3 install,
    -- not guessed): 'cornerN' Border="L,T,R,B" - nonzero L+T=top-left,
    -- T+R=top-right, L+B=bottom-left (corner4), R+B=bottom-right (corner8).
    -- Color refs use the ColorGroup layer, e.g. 'Global.SuccessText' /
    -- 'Global.AlertText' / 'Global.WarningText' - NOT the raw ColorDef
    -- names like 'Global.Success' or ad-hoc ones like 'Global.Green'.

    local baseLayer = GetFocusDisplay().ScreenOverlay:Append('BaseInput')
    baseLayer.H = 570
    baseLayer.W = 940
    baseLayer.Columns = 1
    baseLayer.Rows = 5
    baseLayer[1][1].SizePolicy = 'Fixed'; baseLayer[1][1].Size = 36  -- title bar
    baseLayer[1][2].SizePolicy = 'Fixed'; baseLayer[1][2].Size = 44  -- header actions
    baseLayer[1][3].SizePolicy = 'Stretch'                            -- head list
    baseLayer[1][4].SizePolicy = 'Fixed'; baseLayer[1][4].Size = 44  -- bottom actions
    baseLayer[1][5].SizePolicy = 'Fixed'; baseLayer[1][5].Size = 12  -- bottom margin - see below
    baseLayer.AutoClose = 'No'
    baseLayer.CloseOnEscape = 'Yes'
    -- DefaultMargin/DefaultMarginOnBorders confirmed in grandMA3's own
    -- shipped message_box.uixml (<DialogFrame DefaultMargin="5" .../>) -
    -- insets content from the window's own border instead of it touching
    -- the edge, which is what the bottom action row was doing.
    pcall(function() baseLayer.DefaultMargin = 8 end)
    pcall(function() baseLayer.DefaultMarginOnBorders = 'Yes' end)
    -- NOTE: tinting the whole window's BackColor ("Window.Plugins") turned
    -- the entire window a flat, overwhelming pink - reverted. Per the HTML
    -- mockup's actual palette, color belongs on small accents (button text,
    -- the status dot) against a neutral dark body, not as a full-surface
    -- wash. Left baseLayer at its default background.

    -- Title bar
    local titleBar = baseLayer:Append('TitleBar')
    titleBar.Columns = 2
    titleBar.Rows = 1
    titleBar.Anchors = '0,0'
    titleBar[2][2].SizePolicy = 'Fixed'
    titleBar[2][2].Size = 50
    titleBar.Texture = 'corner2'
    titleBar.Transparent = "No"

    local titleIcon = titleBar:Append('TitleButton')
    titleIcon.Font = 'Regular20'
    titleIcon.Text = 'MiniHead Control'
    titleIcon.Texture = 'corner1'
    titleIcon.Anchors = '0,0'

    local titleClose = titleBar:Append('CloseButton')
    titleClose.Anchors = '1,0'
    titleClose.Texture = 'corner2'
    titleClose.PluginComponent = myHandle
    titleClose.Clicked = 'MH_CloseClicked'

    -- Header actions: Discover / Refresh / Settings.
    -- NOTE: explicit per-cell [col][row].SizePolicy (like BaseInput uses)
    -- crashed here on a UILayoutGrid ("attempt to index a nil value") -
    -- that indexing pattern is BaseInput-specific, not general. Reverted to
    -- the plain Columns/Rows + per-child Anchors pattern confirmed working
    -- by the community examples' own button grids - equal-width columns,
    -- less tight than intended but reliable.
    local headerGrid = baseLayer:Append('UILayoutGrid')
    headerGrid.Anchors = '0,1'
    headerGrid.Columns = 3
    headerGrid.Rows = 1

    local discoverBtn = headerGrid:Append('Button')
    discoverBtn.Anchors = '0,0'
    discoverBtn.Text = 'Discover Heads'
    discoverBtn.HasHover = 'Yes'
    discoverBtn.PluginComponent = myHandle
    discoverBtn.Clicked = 'MH_DiscoverClicked'

    local refreshBtn = headerGrid:Append('Button')
    refreshBtn.Anchors = '1,0'
    refreshBtn.Text = 'Refresh'
    refreshBtn.HasHover = 'Yes'
    refreshBtn.PluginComponent = myHandle
    refreshBtn.Clicked = 'MH_RefreshClicked'

    local settingsBtn = headerGrid:Append('Button')
    settingsBtn.Anchors = '2,0'
    settingsBtn.Text = 'Settings'
    settingsBtn.HasHover = 'Yes'
    settingsBtn.PluginComponent = myHandle
    settingsBtn.Clicked = 'MH_SettingsClicked'

    -- Scrollable head list
    local dialog = baseLayer:Append('DialogFrame')
    dialog.Anchors = '0,2'
    dialog.H, dialog.W = '100%', '100%'

    local scrollbox = dialog:Append('ScrollBox')
    scrollbox.Name = 'mhbox'

    local scrollbar = dialog:Append('ScrollBarV')
    scrollbar.ScrollTarget = '../mhbox'
    scrollbar.Anchors = '1,0'

    local rowH = 40
    -- Only two color refs used, both confirmed real in community examples -
    -- avoids guessing at semantic green/red names that may not exist.
    local COLOR_ON = 'Global.Text'
    local COLOR_OFF = 'Global.Inactive'

    -- Column header labels (row 0), data rows start one rowH below.
    local headerCols = {
      { x = 5,   w = 35,  t = 'St' },
      { x = 45,  w = 135, t = 'IP' },
      { x = 185, w = 130, t = 'MAC' },
      { x = 320, w = 140, t = 'Name' },
      { x = 465, w = 55,  t = 'Fix#' },
      { x = 525, w = 65,  t = 'U.Addr' },
      { x = 595, w = 75,  t = 'Role' },
    }
    for _, c in ipairs(headerCols) do
      local hdr = scrollbox:Append('Button')
      hdr.Text = c.t
      hdr.HasHover = 'No'
      hdr.TextColor = 'Global.Inactive'
      hdr.Font = 'Regular12'
      hdr.TextalignmentH = 'Left'
      hdr.W, hdr.H = c.w, rowH - 8
      hdr.X, hdr.Y = c.x, 0
    end

    for i, h in ipairs(heads) do
      local y = i * rowH
      local rowColor = h.online and COLOR_ON or COLOR_OFF

      local statusLbl = scrollbox:Append('Button')
      statusLbl.Text = h.online and 'On' or 'Off'
      statusLbl.HasHover = 'No'
      statusLbl.TextColor = rowColor
      tryColor(statusLbl, 'TextColor', h.online and 'Global.SuccessText' or 'Global.AlertText')
      statusLbl.W, statusLbl.H = 35, rowH - 4
      statusLbl.X, statusLbl.Y = 5, y

      local ipLbl = scrollbox:Append('Button')
      ipLbl.Text = nz(h.ip, '-')
      ipLbl.HasHover = 'No'
      ipLbl.TextColor = rowColor
      ipLbl.TextalignmentH = 'Left'
      ipLbl.W, ipLbl.H = 135, rowH - 4
      ipLbl.X, ipLbl.Y = 45, y

      local macLbl = scrollbox:Append('Button')
      macLbl.Text = nz(h.mac, '-')
      macLbl.HasHover = 'No'
      macLbl.TextColor = rowColor
      macLbl.TextalignmentH = 'Left'
      macLbl.Font = 'Regular12'
      macLbl.W, macLbl.H = 130, rowH - 4
      macLbl.X, macLbl.Y = 185, y

      -- Display-only in the row (a raw Append'd LineEdit's .Text did not
      -- reliably read back what was actually typed, live-tested - see
      -- verification-checklist.md). Editing happens via a MessageBox
      -- prompt on Apply instead, using the proven inputs= mechanism.
      local nameLbl = scrollbox:Append('Button')
      nameLbl.Text = nz(h.name, '-')
      nameLbl.HasHover = 'No'
      nameLbl.TextColor = rowColor
      nameLbl.TextalignmentH = 'Left'
      nameLbl.W, nameLbl.H = 140, rowH - 4
      nameLbl.X, nameLbl.Y = 320, y

      local fixLbl = scrollbox:Append('Button')
      fixLbl.Text = tostring(h.fixtureNo or '-')
      fixLbl.HasHover = 'No'
      fixLbl.TextColor = rowColor
      fixLbl.TextalignmentH = 'Centre'
      fixLbl.W, fixLbl.H = 55, rowH - 4
      fixLbl.X, fixLbl.Y = 465, y

      local uaddrText = '--'
      if h.universe and h.addr then uaddrText = h.universe .. '.' .. string.format('%03d', h.addr) end
      local uaddrLbl = scrollbox:Append('Button')
      uaddrLbl.Text = uaddrText
      uaddrLbl.HasHover = 'No'
      uaddrLbl.TextColor = rowColor
      uaddrLbl.W, uaddrLbl.H = 65, rowH - 4
      uaddrLbl.X, uaddrLbl.Y = 525, y

      local roleLbl = scrollbox:Append('Button')
      roleLbl.Text = nz(h.role, '-')
      roleLbl.HasHover = 'No'
      roleLbl.TextColor = rowColor
      roleLbl.W, roleLbl.H = 75, rowH - 4
      roleLbl.X, roleLbl.Y = 595, y

      local idBtn = scrollbox:Append('Button')
      idBtn.Text = 'Identify'
      idBtn.HasHover = 'Yes'
      idBtn.W, idBtn.H = 85, rowH - 4
      idBtn.X, idBtn.Y = 675, y
      tryColor(idBtn, 'TextColor', 'Global.Blue')
      idBtn.PluginComponent = myHandle
      idBtn.Clicked = 'MH_Identify' .. i

      local editBtn = scrollbox:Append('Button')
      editBtn.Text = 'Edit'
      editBtn.HasHover = 'Yes'
      editBtn.W, editBtn.H = 85, rowH - 4
      editBtn.X, editBtn.Y = 765, y
      tryColor(editBtn, 'TextColor', 'Global.SuccessText')
      editBtn.PluginComponent = myHandle
      editBtn.Clicked = 'MH_Edit' .. i

      local ip = h.ip
      signalTable['MH_Identify' .. i] = function(caller)
        doIdentify(ip)
      end
      signalTable['MH_Edit' .. i] = function(caller)
        local head2 = findHeadByIp(ip)
        if not head2 then return end
        local uaddrStr = ''
        if head2.universe and head2.addr then
          uaddrStr = head2.universe .. "." .. string.format("%03d", head2.addr)
        end
        local result = MessageBox({
          title = "Edit - " .. nz(head2.name, ip),
          message = "Confirm or edit, then push to " .. ip .. ".\n" ..
            "U.Addr format: 1.001 (universe.address). Leave blank to use MA3's own patch for this Fix#.",
          inputs = {
            { name = "Name", value = head2.name or '' },
            { name = "Fix#", value = tostring(head2.fixtureNo or '') },
            { name = "U.Addr", value = uaddrStr },
          },
          commands = {
            { value = 1, name = "Save" },
            { value = 0, name = "Cancel" },
          },
        })
        if not (result and result.success and result.result == 1) then return end
        local overrideUni, overrideAddr = nil, nil
        if result.inputs then
          local newName = result.inputs["Name"]
          if newName ~= nil and newName ~= tostring(head2.name or '') then
            doSetName(ip, newName)
          end
          local newFix = result.inputs["Fix#"]
          if newFix ~= nil and newFix ~= tostring(head2.fixtureNo or '') then
            doSetFixture(ip, newFix)
          end
          local uaddrIn = result.inputs["U.Addr"]
          if uaddrIn and uaddrIn ~= '' then
            local u, a = tostring(uaddrIn):match("(%d+)%.(%d+)")
            if u and a then
              overrideUni, overrideAddr = tonumber(u), tonumber(a)
            else
              notifyError("U.Addr \"" .. tostring(uaddrIn) .. "\" isn't in 1.001 format - ignored, falling back to MA3's patch.")
            end
          end
        end
        doApply(ip, overrideUni, overrideAddr)
      end
    end

    -- Bottom actions: global fleet actions + MA3 shortcuts, one row (was
    -- two separate rows - merged to free vertical space for the table).
    local bottomGrid = baseLayer:Append('UILayoutGrid')
    bottomGrid.Anchors = '0,3'
    bottomGrid.Columns = 6
    bottomGrid.Rows = 1

    local idAllBtn = bottomGrid:Append('Button')
    idAllBtn.Anchors = '0,0'
    idAllBtn.Text = 'Identify All'
    idAllBtn.HasHover = 'Yes'
    -- Best-effort: round this button's bottom-left corner to match the
    -- window's own - only confirmed corner textures so far are corner1/
    -- corner2 on the TitleBar's top corners, so this is a guess at the
    -- bottom-corner equivalents, individually pcall-guarded via tryColor.
    tryColor(idAllBtn, 'Texture', 'corner4')
    idAllBtn.PluginComponent = myHandle
    idAllBtn.Clicked = 'MH_IdentifyAllClicked'

    local boAllBtn = bottomGrid:Append('Button')
    boAllBtn.Anchors = '1,0'
    boAllBtn.Text = 'Blackout All'
    boAllBtn.HasHover = 'Yes'
    tryColor(boAllBtn, 'TextColor', 'Global.AlertText')
    boAllBtn.PluginComponent = myHandle
    boAllBtn.Clicked = 'MH_BlackoutAllClicked'

    local rbAllBtn = bottomGrid:Append('Button')
    rbAllBtn.Anchors = '2,0'
    rbAllBtn.Text = 'Rainbow'
    rbAllBtn.HasHover = 'Yes'
    -- No real "magenta/accent" semantic color exists in grandMA3's Global
    -- ColorGroup (confirmed by reading the shipped color theme XML) - left
    -- as the plain default button color rather than another silent no-op guess.
    rbAllBtn.PluginComponent = myHandle
    rbAllBtn.Clicked = 'MH_RainbowAllClicked'

    local demoAllBtn = bottomGrid:Append('Button')
    demoAllBtn.Anchors = '3,0'
    demoAllBtn.Text = 'Demo'
    demoAllBtn.HasHover = 'Yes'
    tryColor(demoAllBtn, 'TextColor', 'Global.WarningText')
    demoAllBtn.PluginComponent = myHandle
    demoAllBtn.Clicked = 'MH_DemoAllClicked'

    local patchBtn = bottomGrid:Append('Button')
    patchBtn.Anchors = '4,0'
    patchBtn.Text = 'Open Patch'
    patchBtn.HasHover = 'Yes'
    patchBtn.PluginComponent = myHandle
    patchBtn.Clicked = 'MH_OpenPatchClicked'

    local netBtn = bottomGrid:Append('Button')
    netBtn.Anchors = '5,0'
    netBtn.Text = 'Network Settings'
    netBtn.HasHover = 'Yes'
    tryColor(netBtn, 'Texture', 'corner8')
    netBtn.PluginComponent = myHandle
    netBtn.Clicked = 'MH_NetworkSettingsClicked'

    -- Fixed-chrome click handlers
    signalTable.MH_CloseClicked = function(caller)
      GetFocusDisplay().ScreenOverlay:ClearUIChildren()
      continue = true
    end
    signalTable.MH_DiscoverClicked = function(caller) doDiscover(nil) end
    signalTable.MH_RefreshClicked = function(caller) doRefresh() end
    signalTable.MH_SettingsClicked = function(caller)
      GetFocusDisplay().ScreenOverlay:ClearUIChildren()
      continue = true
      doSettingsDialog()
    end
    signalTable.MH_IdentifyAllClicked = function(caller) doIdentifyAll() end
    signalTable.MH_BlackoutAllClicked = function(caller) doBlackoutAll() end
    signalTable.MH_RainbowAllClicked = function(caller) doRainbowAll(true) end
    signalTable.MH_DemoAllClicked = function(caller) doDemoAll(true) end
    -- "Menu 'Patch'.'Edit'" confirmed from grandMA3's own shipped
    -- menu_selector.uixml (the SignalValue behind its own "Patch" button).
    signalTable.MH_OpenPatchClicked = function(caller) Cmd('Menu "Patch"."Edit"') end
    signalTable.MH_NetworkSettingsClicked = function(caller) Cmd('Menu "ConnectorConfig"') end

  end)

  if not ok then
    notifyError("Window build failed: " .. tostring(err))
    return
  end

  local guard = 0
  repeat
    guard = guard + 1
  until continue or guard > 200000000
end

-- Settings editor: one MessageBox with both text inputs and boolean
-- states, confirmed supported together by MA Lighting's own documented
-- MessageBox example. Reopens the main window on OK, Cancel, or dismiss.
doSettingsDialog = function()
  local s = loadSettings()

  local result = MessageBox({
    title = "MiniHead Settings",
    message = "Poll interval and scan radius apply next time you Discover/Refresh.",
    inputs = {
      { name = "Poll Interval (s)", value = tostring(s.pollInterval) },
      { name = "Scan Radius", value = tostring(s.scanRadius) },
    },
    states = {
      { name = "Toast on Error", state = s.toastEnabled and true or false },
      { name = "Command-line Log", state = s.cmdlineLogEnabled and true or false },
    },
    commands = {
      { value = 1, name = "OK" },
      { value = 0, name = "Cancel" },
    },
  })

  if result and result.success and result.result == 1 then
    if result.inputs then
      local pollN = tonumber(result.inputs["Poll Interval (s)"])
      local radiusN = tonumber(result.inputs["Scan Radius"])
      if pollN and pollN >= 5 then s.pollInterval = pollN end
      if radiusN and radiusN > 0 then s.scanRadius = radiusN end
    end
    if result.states then
      if result.states["Toast on Error"] ~= nil then s.toastEnabled = result.states["Toast on Error"] end
      if result.states["Command-line Log"] ~= nil then s.cmdlineLogEnabled = result.states["Command-line Log"] end
    end
    saveSettings(s)
    notifyInfo("Settings saved.")
  end

  return doWindow()
end

-- ============================================================================
-- SECTION 12: Entry point
-- Confirmed convention for this build: the script's outermost chunk must
-- RETURN its entry function(s) - `function Main(...)` alone (without the
-- trailing `return Main`) is silently never called. Invoke e.g.:
--   Plugin "MiniHead Control" "List"
--   Plugin "MiniHead Control" "Apply 192.168.1.42"
-- ============================================================================

function Main(display_handle, arg)
  local tokens = tokenize(arg)
  local cmd = (tokens[1] or ""):lower()
  table.remove(tokens, 1)

  if cmd == "" then
    local settings = loadSettings()
    if settings.seedIP == "" and #loadHeads() == 0 then
      doDiscover(nil)
    end
    return doMenu()
  end

  if cmd == "menu" then return doMenu()
  elseif cmd == "window" then doWindow()
  elseif cmd == "list" then renderHeadsTable()
  elseif cmd == "discover" then doDiscover(tokens[1])
  elseif cmd == "refresh" then doRefresh()
  elseif cmd == "setfixture" then doSetFixture(tokens[1], tokens[2])
  elseif cmd == "useselection" then doUseSelection(tokens[1])
  elseif cmd == "dumpfixture" then doDumpFixture(tokens[1])
  elseif cmd == "apply" then doApply(tokens[1])
  elseif cmd == "identify" then doIdentify(tokens[1])
  elseif cmd == "identifyall" then doIdentifyAll()
  elseif cmd == "blackoutall" then doBlackoutAll()
  elseif cmd == "rainbowall" then doRainbowAll(true)
  elseif cmd == "rainbowoff" then doRainbowAll(false)
  elseif cmd == "demoall" then doDemoAll(true)
  elseif cmd == "demooff" then doDemoAll(false)
  elseif cmd == "batch" then doBatch(table.concat(tokens, " "))
  elseif cmd == "rename" then doRename(tokens[1])
  elseif cmd == "networksettings" then Cmd('Menu "ConnectorConfig"')
  elseif cmd == "settings" then
    if tokens[1] and tokens[2] then doSettingsSet(tokens[1], tokens[2]) else doSettings() end
  elseif cmd == "help" then doHelp()
  else
    notifyError("Unknown MiniHead command: \"" .. cmd .. "\". Try: Plugin \"MiniHead Control\" \"Help\"")
  end
end

return Main
