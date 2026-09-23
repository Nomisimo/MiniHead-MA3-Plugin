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

-- ============================================================================
-- SECTION 1: Small utilities
-- ============================================================================

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
    scanRadius = 20,      -- +/- host addresses probed around the seed IP on Discover
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
      status, h.ip or "-", h.name or "-",
      tostring(h.fixtureNo or "-"), ua, h.role or "-"))
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

function api.getStatus(ip)
  local ok, code, body, err = httpRequest(ip, "GET", "/api/status", nil, 800)
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
        local ok = api.getStatus(ip)
        if ok then found[#found + 1] = ip end
      end
    end
  end
  return found
end

local function doDiscover(seedIp)
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

local function doUseSelection(ip)
  local sel = ma3ReadSelectedFixtures()
  if not sel or #sel == 0 then
    notifyError("Could not read a fixture selection from MA3 (or nothing is selected). Type it instead: SetFixture " .. tostring(ip) .. " <n>")
    return
  end
  doSetFixture(ip, tostring(sel[1]))
end

local function doApply(ip)
  local head, _, heads = findHeadByIp(ip)
  if not head then
    notifyError("No known head at " .. tostring(ip) .. ". Run Discover or List first.")
    return
  end

  local universe, addr = nil, nil
  if head.fixtureNo then
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
    notifyError("Failed to set fixture ID on " .. head.ip .. " [" .. tostring(idErr) .. "].")
    return
  end

  if universe and addr then
    local okPatch, code, patchErr = api.setPatch(head.ip, universe, addr)
    if not okPatch then
      notifyError("Fixture ID set, but patch push failed on " .. head.ip ..
        " [" .. tostring(patchErr or code) .. "]. If this is HTTP 404, confirm the head's firmware has Art-Net (PLUGIN_ARTNET) enabled.")
      head.universe, head.addr = nil, nil
      saveHeads(heads)
      return
    end
    head.universe, head.addr = universe, addr
    notifyInfo("Applied to " .. head.ip .. ": Fix#=" .. tostring(head.fixtureNo) ..
      ", patch=" .. universe .. "." .. string.format("%03d", addr))
  else
    notifyInfo("Applied to " .. head.ip .. ": Fix#=" .. tostring(head.fixtureNo) .. " (no patch pushed).")
  end

  saveHeads(heads)
end

local function doIdentify(ip)
  local head = findHeadByIp(ip)
  if not head then notifyError("No known head at " .. tostring(ip) .. "."); return end
  local ok, err = api.identify(head.ip, true)
  if ok then
    notifyInfo("Identify flashed on " .. head.ip .. ".")
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
    Printf("  Fixture " .. fixtureNumbers[i] .. "  <->  " .. heads[i].ip .. " (" .. (heads[i].name or "?") .. ")")
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
    "  Discover [ip]               - set/seed a head IP, pull /api/heads, scan nearby",
    "  List                        - show the head table (plain text)",
    "  Refresh                     - re-check online status + re-pull head list",
    "  SetFixture <ip> <n>         - link a head to MA3 fixture number n (also its fixture ID - same number)",
    "  UseSelection <ip>           - fill SetFixture from the current MA3 selection",
    "  Apply <ip>                  - push fixture number + patch to that head",
    "  Identify <ip>               - flash one head",
    "  IdentifyAll                 - flash all heads",
    "  BlackoutAll                 - blackout all heads",
    "  RainbowAll / RainbowOff     - start/stop rainbow demo on all heads",
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
    "MAC: " .. ((head.mac and head.mac ~= "") and head.mac or "-") .. "\n" ..
    "Role: " .. (head.role or "-") .. "   Status: " .. (head.online and "Online" or "Offline") .. "\n" ..
    "Last applied patch: " .. ua

  local result = MessageBox({
    title = "MiniHead - " .. (head.name or head.ip),
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
        h.online and "On " or "Off", h.ip, tostring(h.fixtureNo or "-"), h.name or "-")
    end
    msg = table.concat(lines, "\n")
  end

  local commands = {
    { value = 1, name = "Discover" },
    { value = 2, name = "Refresh" },
    { value = 3, name = "Identify All" },
    { value = 4, name = "Blackout All" },
    { value = 5, name = "Rainbow All" },
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
  elseif r == 6 then doSettings(); return doMenu()
  elseif ipByValue[r] then return doEditHead(ipByValue[r])
  end
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
  elseif cmd == "list" then renderHeadsTable()
  elseif cmd == "discover" then doDiscover(tokens[1])
  elseif cmd == "refresh" then doRefresh()
  elseif cmd == "setfixture" then doSetFixture(tokens[1], tokens[2])
  elseif cmd == "useselection" then doUseSelection(tokens[1])
  elseif cmd == "apply" then doApply(tokens[1])
  elseif cmd == "identify" then doIdentify(tokens[1])
  elseif cmd == "identifyall" then doIdentifyAll()
  elseif cmd == "blackoutall" then doBlackoutAll()
  elseif cmd == "rainbowall" then doRainbowAll(true)
  elseif cmd == "rainbowoff" then doRainbowAll(false)
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
