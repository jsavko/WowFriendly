-- WowFriendly: slash commands and keybinding entry points.
local _, ns = ...

local USAGE = {
  "/wf veryhappy [name[: note]]  two smiles: very friendly (default: target, then mouseover)",
  "/wf happy [name[: note]]      one smile: friendly",
  "/wf sad [name[: note]]        one frown: jerk",
  "/wf verysad [name[: note]]    two frowns: big jerk",
  "/wf ++ | + | - | --           short forms of the four ratings above",
  "/wf clear [name]              remove your rating",
  "/wf note [name:] <text>       set or replace the note on your rating",
  "/wf who [name]                show everything your circle has said about a player",
  "/wf list                      open the rated players window",
  "/wf trust <Name Surname>      trust a character's ratings (also: untrust, trusted)",
  "/wf sync                      say hello to friends and sync now",
  "/wf export | import           share ratings as a text string",
  "/wf status                    show counts, peers and queue",
  "/wf config                    open settings",
  "/wf debug                     toggle debug output",
  "Names with a surname take a colon before the note: /wf sad Arthas Menethil: ninja looted",
}

local function printUsage()
  ns.Print("commands:")
  for _, line in ipairs(USAGE) do
    ns.Print("  " .. line)
  end
end

-- Splits "rest" into a name part and a text part.
--   "Arthas Menethil: text"  -> "Arthas Menethil", "text"
--   "\"Arthas Menethil\" text" -> "Arthas Menethil", "text"
--   ": text" or "text"       -> nil, "text"   (caller decides whether text is a name)
local function splitNameAndText(rest)
  if not rest or rest == "" then return nil, "" end
  local quoted, after = rest:match('^"([^"]+)"%s*(.*)$')
  if quoted then return quoted, after end
  local name, text = rest:match("^([^:]*):%s*(.*)$")
  if name then
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then name = nil end
    return name, text
  end
  return nil, rest
end

-- Resolves a typed name, falling back to target then mouseover when none was given.
local function resolveKey(typed, verb)
  if typed and typed ~= "" then
    local key = ns.Identity.KeyFromInput(typed)
    if not key then ns.Print("'%s' is not a valid player name.", typed) end
    return key
  end
  local key = ns.Identity.KeyForUnit("target") or ns.Identity.KeyForUnit("mouseover")
  if not key then
    ns.Print("No player targeted or under the mouse. Usage: /wf %s <name>", verb or "happy")
  end
  return key
end

local function rateCommand(value, rest, verb)
  local name, text = splitNameAndText(rest)
  local hadColon = rest and rest:find(":") ~= nil
  local hadQuote = rest and rest:find('^"') ~= nil
  if not name and not hadColon and not hadQuote then
    -- No separator: the whole remainder is the name (if any), and there is no note.
    name, text = text, nil
  end
  local key = resolveKey(name, verb)
  if not key then return end
  if text == "" then text = nil end
  ns.Rate(key, value, text)
end

local function noteCommand(rest)
  local name, text = splitNameAndText(rest)
  local key = resolveKey(name, "note")
  if not key then return end
  ns.SetNote(key, text or "")
end

local function trustCommand(rest, enable)
  local key = ns.Identity.KeyFromInput(rest or "")
  if not key then
    ns.Print("Usage: /wf %s <Name Surname>", enable and "trust" or "untrust")
    return
  end
  local me = ns.Identity.SelfKey()
  if me and ns.Identity.Matches(key, me) then
    ns.Print("You are always trusted by yourself.")
    return
  end
  if enable then
    ns.db.friends[key] = true
    ns.Print("Now trusting ratings from %s.", key)
    if ns.Comms and ns.Comms.SyncNow then ns.Comms.SyncNow(true) end
  else
    local match = ns.Identity.FindMatch(ns.db.friends, key)
    if match then
      ns.db.friends[match] = nil
      ns.Print("No longer trusting %s.", match)
    else
      ns.Print("%s was not in your trusted list.", key)
    end
  end
  ns.Fire("TRUST_CHANGED")
end

local function listTrusted()
  local names = {}
  for name, enabled in pairs(ns.db.friends) do
    if enabled then names[#names + 1] = name end
  end
  table.sort(names)
  if #names == 0 then
    ns.Print("No trusted characters yet. Battle.net friends running WowFriendly are trusted automatically.")
  else
    ns.Print("Trusted characters (%d): %s", #names, table.concat(names, ", "))
  end
  if ns.db.settings.shareGuild then
    ns.Print("Guild sharing is ON: guild members running WowFriendly are also trusted.")
  end
end

local handlers = {}

handlers.veryhappy = function(rest) rateCommand(2, rest, "veryhappy") end
handlers.happy2 = handlers.veryhappy
handlers["++"] = handlers.veryhappy
handlers.happy = function(rest) rateCommand(1, rest, "happy") end
handlers.smile = handlers.happy
handlers.good = handlers.happy
handlers["+"] = handlers.happy
handlers.sad = function(rest) rateCommand(-1, rest, "sad") end
handlers.frown = handlers.sad
handlers.bad = handlers.sad
handlers["-"] = handlers.sad
handlers.verysad = function(rest) rateCommand(-2, rest, "verysad") end
handlers.sad2 = handlers.verysad
handlers["--"] = handlers.verysad
handlers.clear = function(rest)
  local key = resolveKey(rest, "clear")
  if key then ns.Rate(key, 0) end
end
handlers.note = noteCommand
handlers.who = function(rest)
  local key = resolveKey(rest, "who")
  if key then ns.Who(key) end
end
handlers.list = function() if ns.UI and ns.UI.List then ns.UI.List.Toggle() end end
handlers.trust = function(rest) trustCommand(rest, true) end
handlers.untrust = function(rest) trustCommand(rest, false) end
handlers.trusted = listTrusted
handlers.sync = function()
  if ns.Comms and ns.Comms.SyncNow then
    ns.Comms.SyncNow(true)
    ns.Print("Sync requested.")
  end
end
handlers.export = function() if ns.UI and ns.UI.Export then ns.UI.Export.Show("export") end end
handlers.import = function() if ns.UI and ns.UI.Export then ns.UI.Export.Show("import") end end
handlers.config = function() if ns.UI and ns.UI.Options then ns.UI.Options.Open() end end
handlers.options = handlers.config
handlers.debug = function()
  ns.db.settings.debug = not ns.db.settings.debug
  ns.Print("Debug output %s.", ns.db.settings.debug and "on" or "off")
  if ns.db.settings.debug then
    local me = ns.Identity.SelfKey()
    ns.Print("Your key: %s", tostring(me))
    if UnitFullName then
      local ok, a, b = pcall(UnitFullName, "player")
      if ok then ns.Print("UnitFullName(player) = %s, %s", tostring(a), tostring(b)) end
    end
    if UnitName then
      local ok, a, b = pcall(UnitName, "player")
      if ok then ns.Print("UnitName(player) = %s, %s", tostring(a), tostring(b)) end
    end
    if GetNormalizedRealmName then
      ns.Print("GetNormalizedRealmName() = %s", tostring(ns.SafeCall("string", GetNormalizedRealmName)))
    end
  end
end
handlers.status = function()
  local entries, players = ns.Ratings.Count(ns.db)
  ns.Print("%d ratings on %d players. Version %s, protocol %d.", entries, players, tostring(ns.version), ns.PROTOCOL_VERSION)
  if ns.Comms and ns.Comms.Status then ns.Comms.Status() end
end
handlers.help = printUsage

local function dispatch(input)
  if not ns.db then
    ns.Print("Still loading, try again in a moment.")
    return
  end
  input = (input or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local sub, rest = input:match("^(%S+)%s*(.*)$")
  sub = sub and sub:lower() or ""
  local handler = handlers[sub]
  if not handler then
    if sub ~= "" then ns.Print("Unknown command '%s'.", sub) end
    printUsage()
    return
  end
  handler(rest)
end

SLASH_WOWFRIENDLY1 = "/wf"
SLASH_WOWFRIENDLY2 = "/wowfriendly"
SlashCmdList.WOWFRIENDLY = dispatch

-- Keybindings (Bindings.xml) call this global.
BINDING_HEADER_WOWFRIENDLY = "WowFriendly"
BINDING_NAME_WOWFRIENDLY_SMILE2 = "Two smiles at mouseover / target"
BINDING_NAME_WOWFRIENDLY_SMILE = "Smile at mouseover / target"
BINDING_NAME_WOWFRIENDLY_FROWN = "Frown at mouseover / target"
BINDING_NAME_WOWFRIENDLY_FROWN2 = "Two frowns at mouseover / target"

local BIND_VALUES = { smile2 = 2, smile = 1, frown = -1, frown2 = -2, clear = 0 }

function WowFriendly_Bind(action)
  if not ns.db then return end
  local key = ns.Identity.KeyForUnit("mouseover") or ns.Identity.KeyForUnit("target")
  if not key then
    ns.Print("No player under the mouse or targeted.")
    return
  end
  local value = BIND_VALUES[action]
  if value then ns.Rate(key, value) end
end

ns.Commands = { dispatch = dispatch, splitNameAndText = splitNameAndText }
