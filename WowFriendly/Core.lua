-- WowFriendly: core namespace, saved variables, events and shared helpers.
local ADDON_NAME, ns = ...

ns.name = ADDON_NAME
ns.DB_VERSION = 1
ns.PROTOCOL_VERSION = 1
ns.PREFIX = "WOWFRIENDLY"
ns.MEDIA = "Interface\\AddOns\\" .. ADDON_NAME .. "\\Media\\"
ns.COLOR = "|cff5fd3ff"
ns.SMILE_ICON = "|T" .. ns.MEDIA .. "smile:14:14|t"
ns.FROWN_ICON = "|T" .. ns.MEDIA .. "frown:14:14|t"

-- Rating levels in display order (best first), and the wording used for each.
-- A level renders as the smile or frown icon repeated once per point.
ns.LEVELS = { 2, 1, -1, -2 }
ns.LEVEL_INFO = {
  [2] = { label = "very friendly" },
  [1] = { label = "friendly" },
  [-1] = { label = "jerk" },
  [-2] = { label = "big jerk" },
}

do
  local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
  local ok, version = pcall(function() return getMeta and getMeta(ADDON_NAME, "Version") end)
  ns.version = (ok and version) or "dev"
end

ns.defaults = {
  showOnTooltip = true,
  showAuthors = true,
  showNotes = true,
  syncBattleNet = true,
  syncTrusted = true,
  shareGuild = false,
  debug = false,
}

---------------------------------------------------------------------------
-- Secret-value guards (Midnight / Forever hide many values in instances)
---------------------------------------------------------------------------

function ns.IsSecret(value)
  if issecretvalue and issecretvalue(value) then return true end
  return false
end

-- Returns value only when it is a non-secret value of the expected type.
function ns.Readable(value, expectedType)
  if ns.IsSecret(value) then return nil end
  if expectedType and type(value) ~= expectedType then return nil end
  return value
end

-- Calls fn(...) in a pcall and returns its first result if it is readable and of the expected type.
function ns.SafeCall(expectedType, fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, value = pcall(fn, ...)
  if not ok then return nil end
  return ns.Readable(value, expectedType)
end

---------------------------------------------------------------------------
-- Output
---------------------------------------------------------------------------

local function chatFrame()
  return SELECTED_CHAT_FRAME or DEFAULT_CHAT_FRAME
end

function ns.Print(fmt, ...)
  local msg = fmt
  if select("#", ...) > 0 then
    local ok, formatted = pcall(string.format, tostring(fmt), ...)
    msg = ok and formatted or tostring(fmt)
  end
  local frame = chatFrame()
  if frame and frame.AddMessage then
    frame:AddMessage(ns.COLOR .. "WowFriendly:|r " .. tostring(msg))
  elseif print then
    print("WowFriendly: " .. tostring(msg))
  end
end

function ns.Debug(fmt, ...)
  if not (ns.db and ns.db.settings and ns.db.settings.debug) then return end
  local msg = fmt
  if select("#", ...) > 0 then
    local ok, formatted = pcall(string.format, tostring(fmt), ...)
    msg = ok and formatted or tostring(fmt)
  end
  local frame = chatFrame()
  if frame and frame.AddMessage then
    frame:AddMessage("|cff888888WF debug:|r " .. tostring(msg))
  end
end

---------------------------------------------------------------------------
-- Event dispatch and module lifecycle
---------------------------------------------------------------------------

ns.events = {}
local initCallbacks, loginCallbacks = {}, {}
local listeners = {}

-- Internal message bus (not WoW events): ns.On("RATING_CHANGED", fn); ns.Fire("RATING_CHANGED", key)
function ns.On(message, fn)
  listeners[message] = listeners[message] or {}
  table.insert(listeners[message], fn)
end

function ns.Fire(message, ...)
  local list = listeners[message]
  if not list then return end
  for _, fn in ipairs(list) do
    local ok, err = pcall(fn, ...)
    if not ok then ns.Debug("listener error for %s: %s", message, tostring(err)) end
  end
end

-- Runs once the saved variables are ready (inside ADDON_LOADED for this addon).
function ns.OnInit(fn)
  if ns.db then fn() else table.insert(initCallbacks, fn) end
end

-- Runs on PLAYER_LOGIN (player identity and most APIs are available).
function ns.OnLogin(fn)
  if ns.loggedIn then fn() else table.insert(loginCallbacks, fn) end
end

local frame = CreateFrame("Frame", ADDON_NAME .. "EventFrame")
ns.frame = frame

local function eventIsValid(event)
  if C_EventUtils and C_EventUtils.IsEventValid then
    local ok, valid = pcall(C_EventUtils.IsEventValid, event)
    if ok then return valid end
  end
  return true
end

-- Registers a WoW event; silently skips events the client does not have.
function ns.RegisterEvent(event, fn)
  if fn then ns.events[event] = fn end
  if not eventIsValid(event) then
    ns.Debug("event %s not available on this client", event)
    return false
  end
  local ok = pcall(frame.RegisterEvent, frame, event)
  if not ok then ns.Debug("could not register %s", event) end
  return ok
end

function ns.UnregisterEvent(event)
  pcall(frame.UnregisterEvent, frame, event)
end

frame:SetScript("OnEvent", function(_, event, ...)
  local handler = ns.events[event]
  if handler then
    local ok, err = pcall(handler, ...)
    if not ok then
      ns.Debug("error in %s handler: %s", event, tostring(err))
    end
  end
end)

local function initDB()
  WowFriendlyDB = WowFriendlyDB or {}
  local db = WowFriendlyDB
  db.version = db.version or ns.DB_VERSION
  db.ratings = db.ratings or {}
  db.friends = db.friends or {}
  db.peers = db.peers or {}
  db.settings = db.settings or {}
  for k, v in pairs(ns.defaults) do
    if db.settings[k] == nil then db.settings[k] = v end
  end
  -- Future schema upgrades go here, keyed on db.version.
  db.version = ns.DB_VERSION
  ns.db = db
end

ns.RegisterEvent("ADDON_LOADED", function(name)
  if name ~= ADDON_NAME then return end
  ns.UnregisterEvent("ADDON_LOADED")
  initDB()
  for _, fn in ipairs(initCallbacks) do
    local ok, err = pcall(fn)
    if not ok then ns.Print("init error: %s", tostring(err)) end
  end
  initCallbacks = {}
end)

ns.RegisterEvent("PLAYER_LOGIN", function()
  ns.loggedIn = true
  for _, fn in ipairs(loginCallbacks) do
    local ok, err = pcall(fn)
    if not ok then ns.Print("login error: %s", tostring(err)) end
  end
  loginCallbacks = {}
end)

---------------------------------------------------------------------------
-- Rating actions (glue between commands/menu/bindings, the store and comms)
---------------------------------------------------------------------------

local function now()
  if GetServerTime then return GetServerTime() end
  return time()
end
ns.Now = now

-- One smile per positive point, one frown per negative point; empty for 0 or nil.
function ns.IconFor(value)
  if type(value) ~= "number" or value == 0 then return "" end
  local icon = value > 0 and ns.SMILE_ICON or ns.FROWN_ICON
  local max = (ns.Ratings and ns.Ratings.MAX_LEVEL) or 2
  return string.rep(icon, math.min(math.abs(value), max))
end

-- "<icons> <label>" for a level, e.g. two smiles followed by "very friendly".
function ns.LevelText(value)
  local info = ns.LEVEL_INFO[value]
  if not info then return ns.IconFor(value) end
  return ns.IconFor(value) .. " " .. info.label
end

-- Summary of an aggregate in level order, skipping empty buckets:
-- "<smile><smile> 2<sep><smile> 1<sep><frown> 1<sep><frown><frown> 2"
function ns.SummaryText(agg, sep)
  local parts = {}
  local counts = agg and agg.counts or {}
  for _, level in ipairs(ns.LEVELS) do
    local n = counts[level] or 0
    if n > 0 then parts[#parts + 1] = ns.IconFor(level) .. " " .. n end
  end
  return table.concat(parts, sep or "  ")
end

-- value: 2, 1, -1, -2 (a rating) or 0 (clear). note: optional string; nil keeps the existing note.
function ns.Rate(key, value, note)
  if not ns.db then return false end
  if value ~= 0 and not ns.Ratings.IsLevel(value) then
    ns.Print("Ratings go from two frowns (-2) to two smiles (2).")
    return false
  end
  local me = ns.Identity.SelfKey()
  if not me then
    ns.Print("Your character name is not available yet; try again in a moment.")
    return false
  end
  if not ns.Identity.IsValidKey(key) then
    ns.Print("That is not a valid player name.")
    return false
  end
  if ns.Identity.Matches(key, me) then
    ns.Print("You cannot rate yourself.")
    return false
  end

  local entry
  if value == 0 then
    local existing = ns.Ratings.GetByAuthor(ns.db, key, me)
    if not existing or existing.r == 0 then
      ns.Print("You have no rating for %s.", key)
      return false
    end
    entry = ns.Ratings.Clear(ns.db, key, me, now())
    ns.Print("Cleared your rating for %s.", key)
  else
    if note == nil then
      local existing = ns.Ratings.GetByAuthor(ns.db, key, me)
      if existing and existing.r ~= 0 then note = existing.n end
    end
    entry = ns.Ratings.Set(ns.db, key, me, value, note, now())
    local what = ns.LevelText(value)
    if entry.n then
      ns.Print("Rated %s as %s: \"%s\"", key, what, entry.n)
    else
      ns.Print("Rated %s as %s.", key, what)
    end
  end

  if ns.Comms and ns.Comms.Broadcast then ns.Comms.Broadcast(key, me, entry) end
  ns.Fire("RATING_CHANGED", key)
  return true
end

function ns.SetNote(key, note)
  if not ns.db then return false end
  local me = ns.Identity.SelfKey()
  if not me then return false end
  if not ns.Identity.IsValidKey(key) then
    ns.Print("That is not a valid player name.")
    return false
  end
  local existing = ns.Ratings.GetByAuthor(ns.db, key, me)
  if not existing or existing.r == 0 then
    ns.Print("Rate %s first (/wf happy, /wf veryhappy, /wf sad or /wf verysad), then add a note.", key)
    return false
  end
  return ns.Rate(key, existing.r, note or "")
end

-- Describes a player's ratings in chat.
function ns.Who(key)
  if not ns.db then return end
  local agg = ns.Ratings.Aggregate(ns.db, key)
  if not agg then
    ns.Print("No ratings for %s.", key)
    return
  end
  ns.Print("%s: %s", key, ns.SummaryText(agg, "  "))
  for _, e in ipairs(agg.entries) do
    local line = string.format("  %s %s", ns.IconFor(e.r), e.author)
    if e.n then line = line .. string.format(": \"%s\"", e.n) end
    line = line .. "  |cff888888" .. (date and date("%Y-%m-%d", e.t) or tostring(e.t)) .. "|r"
    ns.Print(line)
  end
end
