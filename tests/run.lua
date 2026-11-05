-- WowFriendly offline tests. Runs under plain Lua 5.1 with a small WoW stub and a
-- simulated network so several "clients" can sync in-process.
--   .tools/lua tests/run.lua        (from the repository root)
package.path = "./?.lua;" .. package.path

local passed, failed = 0, 0
local function ok(cond, msg)
  if cond then passed = passed + 1 else
    failed = failed + 1
    print("FAIL: " .. msg)
    print(debug.traceback("", 2))
  end
end
local function eq(actual, expected, msg)
  if actual == expected then passed = passed + 1 else
    failed = failed + 1
    print(string.format("FAIL: %s (expected %s, got %s)", msg, tostring(expected), tostring(actual)))
    print(debug.traceback("", 2))
  end
end
local function section(name) print("== " .. name) end

---------------------------------------------------------------------------
-- WoW stub
---------------------------------------------------------------------------
local serverTime = 1700000000
local monoTime = 1000
local function advance(seconds)
  serverTime = serverTime + seconds
  monoTime = monoTime + seconds
end
function GetServerTime() return serverTime end
function GetTime() return monoTime end
function issecretvalue() return false end
function GetNormalizedRealmName() return "Forever" end
function GetRealmName() return "Forever" end
function GetBuildInfo() return "12.1.0", "0", "2026-11-04", 16001 end
date = os.date
time = function() return serverTime end
LE_PARTY_CATEGORY_HOME = 1
BNET_CLIENT_WOW = "WoW"
WOW_PROJECT_ID = 20
SlashCmdList = {}
StaticPopupDialogs = {}
UISpecialFrames = {}
C_EventUtils = { IsEventValid = function() return true end }
C_Timer = { After = function(_, fn) fn() end, NewTicker = function() end }

local lockdown = false
C_ChatInfo = {
  InChatMessagingLockdown = function() return lockdown end,
  RegisterAddonMessagePrefix = function() end,
}

local LAST_PRINT, PRINTS = nil, {}
DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg)
  LAST_PRINT = msg
  PRINTS[#PRINTS + 1] = msg
  if os.getenv("WF_VERBOSE") then print("   " .. msg) end
end }

-- Simulated world: which client is "running" right now decides what the unit APIs return.
local network = { clients = {}, current = nil, pending = {} }
local units = {} -- unit token -> { name, surname } for the current client

function UnitExists(unit) return unit == "player" or units[unit] ~= nil end
function UnitIsPlayer(unit) return unit == "player" or (units[unit] and units[unit].player ~= false) or false end
function UnitFullName(unit)
  if unit == "player" then return network.current.name, network.current.surname end
  local u = units[unit]
  if u then return u.name, u.surname end
end
function IsInGroup() return network.current.party ~= nil end
function IsInRaid() return false end
function IsInGuild() return network.current.guild ~= nil end
function GetNumGuildMembers()
  local n = 0
  for _, c in pairs(network.clients) do if c.guild and c.guild == network.current.guild then n = n + 1 end end
  return n
end
function GetGuildRosterInfo(i)
  local list = {}
  for _, c in pairs(network.clients) do if c.guild and c.guild == network.current.guild then list[#list + 1] = c end end
  table.sort(list, function(a, b) return a.name < b.name end)
  local c = list[i]
  return c and (c.name .. "-Forever") or nil
end
function BNGetNumFriends() return #network.current.bnFriends end
C_BattleNet = {
  GetFriendNumGameAccounts = function() return 1 end,
  GetFriendGameAccountInfo = function(i)
    local friend = network.current.bnFriends[i]
    return { clientProgram = "WoW", isOnline = friend.online ~= false, gameAccountID = friend.bnID, wowProjectID = 20 }
  end,
}

function CreateFrame(_, name)
  local f = { events = {}, scripts = {}, name = name }
  function f:RegisterEvent(e) self.events[e] = true end
  function f:UnregisterEvent(e) self.events[e] = nil end
  function f:SetScript(k, fn) self.scripts[k] = fn end
  function f:Fire(e, ...) if self.events[e] and self.scripts.OnEvent then self.scripts.OnEvent(self, e, ...) end end
  return f
end

-- Real libraries (pure Lua): LibStub, LibDeflate, LibSerialize.
assert(loadfile("WowFriendly/Libs/LibStub/LibStub.lua"))()
assert(loadfile("WowFriendly/Libs/LibDeflate/LibDeflate.lua"))()
assert(loadfile("WowFriendly/Libs/LibSerialize/LibSerialize.lua"))()

-- Fake AceComm and ChatThrottleLib routing through the simulated network.
local LOADING_CLIENT
local FakeAceComm = LibStub:NewLibrary("AceComm-3.0", 14)
function FakeAceComm:Embed(target)
  target.owner = LOADING_CLIENT
  target.RegisterComm = FakeAceComm.RegisterComm
  target.SendCommMessage = FakeAceComm.SendCommMessage
end
function FakeAceComm:RegisterComm(_, fn) self.owner.commHandler = fn end
function FakeAceComm:SendCommMessage(prefix, text, dist, target)
  assert(#text <= 255 * 40, "unreasonably large addon message")
  network.pending[#network.pending + 1] = { from = self.owner, kind = "ADDON", prefix = prefix, text = text, dist = dist, target = target }
end
ChatThrottleLib = {
  BNSendGameData = function(_, _, prefix, text, chattype, id)
    assert(chattype == "WHISPER")
    assert(#text <= 255, "BN message over 255 bytes: " .. #text)
    network.pending[#network.pending + 1] = { from = LOADING_CLIENT, kind = "BN", prefix = prefix, text = text, target = id }
  end,
}

local function as(client, fn, ...)
  local prev = network.current
  network.current = client
  LOADING_CLIENT = client
  local results = { pcall(fn, ...) }
  network.current = prev
  LOADING_CLIENT = prev
  if not results[1] then error(results[2], 2) end
  return unpack(results, 2)
end

local function findClient(nameOrKey)
  nameOrKey = nameOrKey:gsub("%-Forever$", "")
  for _, c in pairs(network.clients) do
    if c.key == nameOrKey or c.name == nameOrKey then return c end
  end
end

local function deliver(msg)
  local sender = msg.from.name .. "-Forever" -- the server form: first name plus realm
  if msg.kind == "BN" then
    for _, c in pairs(network.clients) do
      if c.bnID == msg.target then
        as(c, function() c.ns.frame:Fire("BN_CHAT_MSG_ADDON", msg.prefix, msg.text, "WHISPER", msg.from.bnID) end)
      end
    end
  elseif msg.dist == "WHISPER" then
    local c = findClient(msg.target)
    if c and c ~= msg.from then as(c, function() c.commHandler(msg.prefix, msg.text, "WHISPER", sender) end) end
  elseif msg.dist == "PARTY" or msg.dist == "RAID" then
    for _, c in pairs(network.clients) do
      if c.party and c.party == msg.from.party then
        as(c, function() c.commHandler(msg.prefix, msg.text, msg.dist, sender) end)
      end
    end
  elseif msg.dist == "GUILD" then
    for _, c in pairs(network.clients) do
      if c.guild and c.guild == msg.from.guild then
        as(c, function() c.commHandler(msg.prefix, msg.text, "GUILD", sender) end)
      end
    end
  end
end

local function flush(limit)
  local n = 0
  while #network.pending > 0 do
    local msg = table.remove(network.pending, 1)
    n = n + 1
    assert(n < (limit or 500), "network did not settle")
    deliver(msg)
  end
  return n
end

local MODULES = { "Core", "Identity", "Ratings", "Comms", "Commands" }
local function NewClient(name, surname, opts)
  opts = opts or {}
  local client = { name = name, surname = surname, key = name .. " " .. surname, bnID = opts.bnID, bnFriends = opts.bnFriends or {}, party = opts.party, guild = opts.guild }
  network.clients[client.key] = client
  LOADING_CLIENT = client
  network.current = client
  local ns = {}
  for _, file in ipairs(MODULES) do
    local chunk = assert(loadfile("WowFriendly/" .. file .. ".lua"))
    chunk("WowFriendly", ns)
  end
  client.ns = ns
  WowFriendlyDB = nil
  ns.frame:Fire("ADDON_LOADED", "WowFriendly")
  client.db = ns.db
  eq(ns.Identity.SelfKey(), client.key, "self key for " .. client.key)
  ns.frame:Fire("PLAYER_LOGIN")
  network.current = nil
  LOADING_CLIENT = nil
  return client
end

local function rating(client, target, author)
  return client.ns.Ratings.GetByAuthor(client.db, target, author)
end

---------------------------------------------------------------------------
-- Ratings (pure)
---------------------------------------------------------------------------
section("Ratings")
do
  local ns = {}
  ns.PROTOCOL_VERSION = 1
  assert(loadfile("WowFriendly/Ratings.lua"))("WowFriendly", ns)
  local R = ns.Ratings
  local db = { ratings = {} }
  local tnow = 1000
  R.now = function() return tnow end

  local e = R.Set(db, "Arthas Menethil", "Jaina Proudmoore", -1, "ninja looted |cffff0000x|r", 1000)
  eq(e.r, -1, "set stores value")
  eq(e.n, "ninja looted cffff0000xr", "note strips pipes")
  eq(e.t, 1000, "set keeps given time")
  local e2 = R.Set(db, "Arthas Menethil", "Jaina Proudmoore", 1, nil, 1000)
  eq(e2.t, 1001, "re-rating in the same second bumps the timestamp")
  eq(R.Merge(db, "Arthas Menethil", "Jaina Proudmoore", { r = -1, t = 1000 }), "skipped", "older entry does not overwrite")
  eq(R.Merge(db, "Arthas Menethil", "Jaina Proudmoore", { r = -1, t = 1001 }), "skipped", "equal time: smile beats frown deterministically")
  eq(R.Merge(db, "Arthas Menethil", "Jaina Proudmoore", { r = -1, t = 1002, n = "changed mind" }), "updated", "newer entry wins")
  eq(rating and R.GetByAuthor(db, "Arthas Menethil", "Jaina Proudmoore").n, "changed mind", "merge stored note")
  eq(R.Merge(db, "Arthas Menethil", "Uther Lightbringer", { r = 1, t = 900 }), "added", "second author added")

  local agg = R.Aggregate(db, "Arthas Menethil")
  eq(agg.happy, 1, "aggregate happy count")
  eq(agg.sad, 1, "aggregate sad count")
  eq(agg.entries[1].author, "Jaina Proudmoore", "aggregate newest first")
  eq(agg.newest.n, "changed mind", "aggregate newest note")

  -- tombstone
  local tomb = R.Clear(db, "Arthas Menethil", "Uther Lightbringer", 950)
  eq(tomb.r, 0, "clear writes tombstone")
  eq(tomb.t, 950, "clear keeps the given time when it is already newer")
  agg = R.Aggregate(db, "Arthas Menethil")
  eq(agg.happy, 0, "tombstone removes rating from counts")
  eq(#agg.entries, 1, "tombstone hidden from entries")
  eq(R.Merge(db, "Arthas Menethil", "Uther Lightbringer", { r = 1, t = 900 }), "skipped", "tombstone beats older rating")
  eq(R.Merge(db, "Arthas Menethil", "Uther Lightbringer", { r = 1, t = 2000 }), "updated", "newer rating beats tombstone")
  R.Clear(db, "Arthas Menethil", "Uther Lightbringer", 3000)
  R.Clear(db, "Nobody Special", "Uther Lightbringer", 3000)
  ok(R.Aggregate(db, "Nobody Special") == nil, "aggregate nil when only tombstones")
  local entries, players = R.Count(db)
  eq(entries, 1, "count live entries")
  eq(players, 1, "count rated players")
  eq(#R.AllTargets(db), 1, "AllTargets excludes tombstone-only players")

  -- validation
  ok(not R.ValidateEntry({ r = 3, t = 1 }), "reject bad rating value")
  ok(not R.ValidateEntry({ r = 1, t = "x" }), "reject non-numeric time")
  ok(not R.ValidateEntry({ r = 1, t = 1.5 }), "reject fractional time")
  ok(not R.ValidateEntry({ r = 1, t = tnow + 90000 }), "reject far-future time")
  ok(R.ValidateEntry({ r = 1, t = tnow + 1000 }), "accept slightly-future time")
  ok(not R.ValidateEntry({ r = 1, t = 5, n = 42 }), "reject non-string note")
  ok(not R.ValidateEntry("junk"), "reject non-table")
  local _, clean = R.ValidateEntry({ r = 0, t = 5, n = "x" })
  eq(clean.n, nil, "tombstone drops note")
  _, clean = R.ValidateEntry({ r = 1, t = 5, n = string.rep("a", 150) })
  eq(#clean.n, 100, "note truncated to 100")
  _, clean = R.ValidateEntry({ r = 1, t = 5, n = string.rep("é", 60) })
  eq(#clean.n, 100, "utf8 note truncated on a character boundary")
  ok(clean.n:sub(-2) == "é", "truncation keeps whole multibyte char")
  eq(R.SanitizeNote("  a\tb\n|c  "), "a b c", "sanitize collapses whitespace and strips pipes")
  eq(R.SanitizeNote("   "), nil, "blank note becomes nil")

  -- since / export / import
  tnow = 5000
  R.Set(db, "Fresh Face", "Jaina Proudmoore", 1, "new", 4000)
  local since = R.EntriesSince(db, 5000)
  eq(#since, 1, "EntriesSince uses local receive time")
  eq(since[1].g, "Fresh Face", "EntriesSince picks the new entry")
  eq(since[1].rt, nil, "EntriesSince does not leak receive time")
  eq(#R.EntriesSince(db, 0), 4, "EntriesSince(0) returns everything including tombstones")
  local tbl = R.ToTable(db)
  eq(tbl.v, 1, "ToTable carries version")
  eq(#tbl.e, 4, "ToTable includes tombstones")
  ok(tbl.e[1].rt == nil, "ToTable drops receive times")
  local db2 = { ratings = {} }
  local added, updated, skipped = R.FromTable(db2, tbl, nil, "Arthas Menethil")
  eq(added, 2, "FromTable adds entries not about the skip target")
  eq(skipped, 2, "FromTable skips entries about the skip target")
  added, updated, skipped = R.FromTable(db2, tbl, function(k) return k ~= "Fresh Face" end)
  eq(added, 2, "FromTable honours the key filter")
  eq(updated, 0, "FromTable does not update identical entries")
  eq(skipped, 2, "FromTable counts filtered entries as skipped")
  eq(R.FromTable(db2, "garbage"), 0, "FromTable tolerates garbage")

  -- prune
  tnow = 3000 + 100 * 86400
  eq(R.Prune(db), 2, "prune removes old tombstones")
  ok(db.ratings["Nobody Special"] == nil, "prune removes empty buckets")

  -- Wins determinism
  ok(R.Wins({ r = 1, t = 1 }, { r = -1, t = 1 }) and not R.Wins({ r = -1, t = 1 }, { r = 1, t = 1 }), "Wins is antisymmetric on value")
  ok(not R.Wins({ r = 1, t = 1 }, { r = 1, t = 1 }), "identical entries do not win")

  -- four levels: two smiles, one smile, one frown, two frowns
  ok(R.IsLevel(2) and R.IsLevel(1) and R.IsLevel(-1) and R.IsLevel(-2), "IsLevel accepts the four levels")
  ok(not R.IsLevel(0) and not R.IsLevel(3) and not R.IsLevel(-3) and not R.IsLevel(1.5) and not R.IsLevel("1"), "IsLevel rejects everything else")
  local db3 = { ratings = {} }
  eq(R.Set(db3, "Four Levels", "Author Twoup", 2, nil, 10).r, 2, "set stores two smiles")
  eq(R.Set(db3, "Four Levels", "Author Oneup", 1, nil, 10).r, 1, "set stores one smile")
  eq(R.Set(db3, "Four Levels", "Author Onedown", -1, nil, 10).r, -1, "set stores one frown")
  eq(R.Set(db3, "Four Levels", "Author Twodown", -2, nil, 10).r, -2, "set stores two frowns")
  ok(not pcall(R.Set, db3, "Four Levels", "Author Bad", 3, nil, 10), "set rejects level 3")
  ok(not pcall(R.Set, db3, "Four Levels", "Author Bad", 0, nil, 10), "set rejects 0 (clears use Clear)")
  agg = R.Aggregate(db3, "Four Levels")
  eq(agg.counts[2], 1, "aggregate counts two smiles")
  eq(agg.counts[1], 1, "aggregate counts one smile")
  eq(agg.counts[-1], 1, "aggregate counts one frown")
  eq(agg.counts[-2], 1, "aggregate counts two frowns")
  eq(agg.happy, 2, "happy totals both smile levels")
  eq(agg.sad, 2, "sad totals both frown levels")
  eq(#agg.entries, 4, "aggregate lists every level")
  ok(R.ValidateEntry({ r = 2, t = 1 }) and R.ValidateEntry({ r = -2, t = 1 }), "validate accepts two-face levels")
  ok(not R.ValidateEntry({ r = 3, t = 1 }) and not R.ValidateEntry({ r = -3, t = 1 }), "validate rejects beyond two faces")
  ok(not R.ValidateEntry({ r = 1.5, t = 1 }), "validate rejects fractional rating")
  eq(R.Merge(db3, "Four Levels", "Author Oneup", { r = 2, t = 10 }), "updated", "equal time: two smiles beat one smile")
  ok(R.Wins({ r = 2, t = 1 }, { r = 1, t = 1 }) and not R.Wins({ r = 1, t = 1 }, { r = 2, t = 1 }), "Wins prefers the higher level at equal time")
  ok(R.Wins({ r = -1, t = 1 }, { r = -2, t = 1 }) and R.Wins({ r = 0, t = 1 }, { r = -1, t = 1 }), "Wins orders 0 > -1 > -2 at equal time")
end

---------------------------------------------------------------------------
-- Identity
---------------------------------------------------------------------------
section("Identity")
do
  local ns = {}
  assert(loadfile("WowFriendly/Core.lua"))("WowFriendly", ns)
  assert(loadfile("WowFriendly/Identity.lua"))("WowFriendly", ns)
  local I = ns.Identity
  eq(I.KeyFromInput("arthas menethil"), "Arthas Menethil", "capitalizes typed names")
  eq(I.KeyFromInput("ARTHAS"), "Arthas", "lowercases the rest of a first name")
  eq(I.KeyFromInput("arthas mcDonald"), "Arthas McDonald", "keeps surname inner case")
  eq(I.KeyFromInput("Arthas-Forever"), "Arthas", "strips realm suffix")
  eq(I.KeyFromInput("  Arthas   Menethil  "), "Arthas Menethil", "collapses whitespace")
  eq(I.KeyFromInput("x"), nil, "rejects one-character names")
  eq(I.KeyFromInput("Arthas1"), nil, "rejects digits")
  eq(I.KeyFromInput(""), nil, "rejects empty")
  eq(I.KeyFromInput(nil), nil, "rejects nil")
  eq(I.KeyFromInput("Gnorm O'Brien"), "Gnorm O'Brien", "allows apostrophes")
  eq(I.KeyFromInput(string.rep("a", 70)), nil, "rejects overlong keys")
  eq(I.KeyFromInput("Ärthas"), "Ärthas", "allows non-ASCII")
  eq(I.KeyFromParts("Arthas", "Menethil"), "Arthas Menethil", "name plus surname")
  eq(I.KeyFromParts("Arthas", "Forever"), "Arthas", "drops the realm when it comes back as second value")
  eq(I.KeyFromParts("Arthas", nil), "Arthas", "name without surname")
  eq(I.KeyFromParts("Ar|thas", "Me|nethil"), "Arthas Menethil", "sanitizes pipes")
  eq(I.KeyFromParts(nil, "x"), nil, "no name, no key")
  eq(I.KeyFromSender("Jaina-Forever"), "Jaina", "sender realm stripped")
  eq(I.KeyFromSender("Jaina Proudmoore-Forever"), "Jaina Proudmoore", "sender with surname and realm")
  eq(I.KeyFromSender("|cffbad"), "cffbad", "sender pipes stripped")
  eq(I.KeyFromSender("1234"), nil, "sender with digits rejected")
  ok(I.Matches("Arthas", "Arthas Menethil"), "first name matches full key")
  ok(I.Matches("arthas menethil", "Arthas Menethil"), "case-insensitive match")
  ok(not I.Matches("Arthas Menethil", "Arthas Faol"), "different surnames do not match")
  ok(not I.Matches("Arthas", "Jaina Proudmoore"), "different names do not match")
  eq(I.FindMatch({ ["Arthas Menethil"] = true }, "Arthas"), "Arthas Menethil", "FindMatch by first name")
  eq(I.FindMatch({ ["Arthas Menethil"] = true }, "Jaina"), nil, "FindMatch miss")
  eq(I.FindMatch({ ["Arthas Menethil"] = false }, "Arthas"), nil, "FindMatch ignores disabled")
  ok(I.IsValidKey("Arthas Menethil") and not I.IsValidKey("Arthas  Menethil") and not I.IsValidKey(" Arthas"), "IsValidKey whitespace rules")
  eq(I.FirstName("Arthas Menethil"), "Arthas", "FirstName")
  ok(I.HasSurname("Arthas Menethil") and not I.HasSurname("Arthas"), "HasSurname")
  units.target = { name = "Thrall", surname = "Doomhammer" }
  units.npc = { name = "Hogger", player = false }
  network.current = { name = "Me", surname = "Myself" }
  eq(I.KeyForUnit("target"), "Thrall Doomhammer", "KeyForUnit for a player")
  eq(I.KeyForUnit("npc"), nil, "KeyForUnit nil for NPC")
  eq(I.KeyForUnit("nobody"), nil, "KeyForUnit nil for missing unit")
  eq(I.SelfKey(), "Me Myself", "SelfKey")
  network.current = nil
  units = {}
end

---------------------------------------------------------------------------
-- Commands parsing
---------------------------------------------------------------------------
section("Commands")
do
  local A = NewClient("Jaina", "Proudmoore", { bnID = 1 })
  local split = A.ns.Commands.splitNameAndText
  local n, t = split("Arthas Menethil: ninja looted")
  eq(n, "Arthas Menethil", "colon splits name"); eq(t, "ninja looted", "colon splits text")
  n, t = split('"Arthas Menethil" great healer')
  eq(n, "Arthas Menethil", "quotes split name"); eq(t, "great healer", "quotes split text")
  n, t = split(": just a note")
  eq(n, nil, "leading colon means no name"); eq(t, "just a note", "leading colon keeps text")
  n, t = split("plain words")
  eq(n, nil, "no separator gives no name"); eq(t, "plain words", "no separator keeps text")

  local dispatch = A.ns.Commands.dispatch
  as(A, dispatch, "sad Arthas Menethil: ninja looted")
  local e = rating(A, "Arthas Menethil", A.key)
  ok(e and e.r == -1 and e.n == "ninja looted", "/wf sad with note")
  as(A, dispatch, "happy arthas menethil")
  e = rating(A, "Arthas Menethil", A.key)
  ok(e and e.r == 1 and e.n == "ninja looted", "/wf happy keeps note when none given")
  as(A, dispatch, "note Arthas Menethil: changed my mind")
  eq(rating(A, "Arthas Menethil", A.key).n, "changed my mind", "/wf note replaces note")
  as(A, dispatch, "note Arthas Menethil:")
  eq(rating(A, "Arthas Menethil", A.key).n, nil, "/wf note with empty text clears note")
  units.target = { name = "Thrall", surname = "Doomhammer" }
  as(A, dispatch, "sad")
  ok(rating(A, "Thrall Doomhammer", A.key) and rating(A, "Thrall Doomhammer", A.key).r == -1, "/wf sad uses target")
  as(A, dispatch, "clear")
  eq(rating(A, "Thrall Doomhammer", A.key).r, 0, "/wf clear writes tombstone")
  units = {}
  as(A, dispatch, "sad")
  ok(LAST_PRINT:find("No player targeted"), "/wf sad without target explains")
  as(A, dispatch, "sad Jaina Proudmoore")
  ok(LAST_PRINT:find("cannot rate yourself"), "cannot rate self")
  as(A, dispatch, "note Nobody Here: x")
  ok(LAST_PRINT:find("Rate Nobody Here first"), "note requires a rating")
  as(A, dispatch, "trust thrall doomhammer")
  ok(A.db.friends["Thrall Doomhammer"], "/wf trust adds")
  as(A, dispatch, "untrust Thrall")
  ok(not A.db.friends["Thrall Doomhammer"], "/wf untrust removes by first name")
  as(A, dispatch, "who Arthas Menethil")
  ok(LAST_PRINT:find("Jaina Proudmoore"), "/wf who lists authors")
  as(A, dispatch, "bogus")
  ok(LAST_PRINT:find("/wf"), "unknown command prints usage")
  as(A, function() WowFriendly_Bind("frown") end)
  ok(LAST_PRINT:find("No player under the mouse"), "binding without unit explains")
  units.mouseover = { name = "Hogger", surname = "Gnoll" }
  as(A, function() WowFriendly_Bind("frown") end)
  eq(rating(A, "Hogger Gnoll", A.key).r, -1, "binding rates mouseover")
  as(A, function() WowFriendly_Bind("smile2") end)
  eq(rating(A, "Hogger Gnoll", A.key).r, 2, "binding smile2 rates two smiles")
  as(A, function() WowFriendly_Bind("frown2") end)
  eq(rating(A, "Hogger Gnoll", A.key).r, -2, "binding frown2 rates two frowns")
  units = {}

  -- four-level commands
  local S, F = A.ns.SMILE_ICON, A.ns.FROWN_ICON
  as(A, dispatch, "veryhappy Arthas Menethil: carried us")
  e = rating(A, "Arthas Menethil", A.key)
  ok(e and e.r == 2 and e.n == "carried us", "/wf veryhappy stores two smiles with note")
  ok(LAST_PRINT:find(S .. S .. " very friendly", 1, true), "confirmation shows two smiles and label")
  as(A, dispatch, "-- Arthas Menethil")
  e = rating(A, "Arthas Menethil", A.key)
  ok(e and e.r == -2 and e.n == "carried us", "/wf -- stores two frowns and keeps the note")
  ok(LAST_PRINT:find(F .. F .. " big jerk", 1, true), "confirmation shows two frowns and label")
  units.target = { name = "Thrall", surname = "Doomhammer" }
  as(A, dispatch, "+")
  eq(rating(A, "Thrall Doomhammer", A.key).r, 1, "/wf + rates target one smile")
  as(A, dispatch, "-")
  eq(rating(A, "Thrall Doomhammer", A.key).r, -1, "/wf - rates target one frown")
  as(A, dispatch, "++")
  eq(rating(A, "Thrall Doomhammer", A.key).r, 2, "/wf ++ rates target two smiles")
  as(A, dispatch, "sad2")
  eq(rating(A, "Thrall Doomhammer", A.key).r, -2, "/wf sad2 rates target two frowns")
  as(A, dispatch, "happy2 : short note")
  e = rating(A, "Thrall Doomhammer", A.key)
  ok(e and e.r == 2 and e.n == "short note", "/wf happy2 with a leading-colon note uses the target")
  units = {}
  ok(as(A, A.ns.Rate, "Thrall Doomhammer", 3) == false and LAST_PRINT:find("two smiles"), "Rate rejects level 3 with a hint")
  eq(rating(A, "Thrall Doomhammer", A.key).r, 2, "rejected level leaves the rating alone")

  -- /wf who reports buckets in level order, then who said what
  local before = #PRINTS
  as(A, dispatch, "who Arthas Menethil")
  ok(PRINTS[before + 1]:find("Arthas Menethil: " .. F .. F .. " 1", 1, true), "/wf who summary shows the two-frown bucket")
  ok(LAST_PRINT:find(F .. F .. " Jaina Proudmoore", 1, true), "/wf who author line shows two frowns")

  -- core formatting helpers
  eq(A.ns.IconFor(2), S .. S, "IconFor(2) is two smiles")
  eq(A.ns.IconFor(1), S, "IconFor(1) is one smile")
  eq(A.ns.IconFor(-1), F, "IconFor(-1) is one frown")
  eq(A.ns.IconFor(-2), F .. F, "IconFor(-2) is two frowns")
  eq(A.ns.IconFor(0), "", "IconFor(0) is empty")
  eq(A.ns.IconFor(nil), "", "IconFor(nil) is empty")
  eq(A.ns.IconFor(7), S .. S, "IconFor caps at two icons")
  eq(A.ns.LevelText(1), S .. " friendly", "LevelText one smile")
  eq(A.ns.LevelText(-1), F .. " jerk", "LevelText one frown")
  eq(A.ns.SummaryText({ counts = { [2] = 2, [1] = 0, [-1] = 1, [-2] = 3 } }, "/"),
    S .. S .. " 2/" .. F .. " 1/" .. F .. F .. " 3", "SummaryText skips empty buckets and keeps level order")
  eq(A.ns.SummaryText(nil), "", "SummaryText tolerates nil")
  eq(A.ns.SummaryText({ counts = {} }), "", "SummaryText empty when nothing is rated")

  network.clients[A.key] = nil
  flush()
end

---------------------------------------------------------------------------
-- Encoding
---------------------------------------------------------------------------
section("Encoding")
do
  local A = NewClient("Jaina", "Proudmoore", { bnID = 1 })
  local C = A.ns.Comms
  ok(C.Available(), "comms available with libs")
  local tbl = { m = "R", e = { g = "Arthas Menethil", a = "Jaina Proudmoore", r = -1, t = 1700000000, n = "ninja looted" }, k = "Jaina Proudmoore" }
  local wire = C.Encode(tbl)
  ok(type(wire) == "string" and #wire < 255, "single rating fits a Battle.net message: " .. tostring(wire and #wire))
  local back = C.Decode(wire)
  ok(back and back.e.g == "Arthas Menethil" and back.e.r == -1 and back.e.n == "ninja looted", "wire round trip")
  ok(C.Decode("garbage\1\2") == nil, "garbage rejected")
  ok(C.Decode("") == nil, "empty rejected")
  local printable = C.EncodeForPrint(tbl)
  ok(printable:sub(1, 4) == "WF1:", "print encoding has prefix")
  ok(not printable:find("[^%w%(%):]"), "print encoding is safe to paste")
  back = C.DecodeFromPrint("  " .. printable .. "\n")
  ok(back and back.e.n == "ninja looted", "print round trip tolerates whitespace")
  back = C.DecodeFromPrint(printable:sub(1, 4) .. printable:sub(6))
  ok(back == nil or back.e == nil or back.e.n ~= "ninja looted", "corrupted print string does not round trip")
  ok(C.DecodeFromPrint("not a string") == nil, "random text rejected")
  network.clients[A.key] = nil
  flush()
end

---------------------------------------------------------------------------
-- Sync between Battle.net friends
---------------------------------------------------------------------------
section("Sync over Battle.net")
do
  PRINTS = {}
  local A = NewClient("Jaina", "Proudmoore", { bnID = 1, bnFriends = { { bnID = 2 } } })
  local B = NewClient("Thrall", "Doomhammer", { bnID = 2, bnFriends = { { bnID = 1 } } })
  as(A, A.ns.Rate, "Arthas Menethil", -1, "ninja looted the sword")
  as(B, B.ns.Rate, "Uther Lightbringer", 1, "carried us")
  flush()
  ok(rating(B, "Arthas Menethil", A.key) == nil, "nothing shared before hello")

  as(A, A.ns.Comms.SyncNow, true)
  local count = flush()
  ok(count >= 4 and count <= 8, "handshake uses a handful of messages: " .. count)
  local e = rating(B, "Arthas Menethil", A.key)
  ok(e and e.r == -1 and e.n == "ninja looted the sword", "B received A's rating with author A")
  e = rating(A, "Uther Lightbringer", B.key)
  ok(e and e.r == 1 and e.n == "carried us", "A received B's rating (symmetric exchange)")
  ok(A.db.peers[B.key] and A.db.peers[B.key].lastSync, "A recorded lastSync for B")
  ok(B.db.peers[A.key] and B.db.peers[A.key].lastSync, "B recorded lastSync for A")

  -- live propagation of a new rating and a clear
  advance(200)
  as(A, A.ns.Rate, "Kelthuzad Necro", -1)
  flush()
  e = rating(B, "Kelthuzad Necro", A.key)
  ok(e and e.r == -1, "live RATE reached B")
  as(A, A.ns.Rate, "Kelthuzad Necro", 0)
  flush()
  e = rating(B, "Kelthuzad Necro", A.key)
  ok(e and e.r == 0, "clear propagates as tombstone")
  ok(B.ns.Ratings.Aggregate(B.db, "Kelthuzad Necro") == nil, "cleared rating no longer shown at B")

  -- B's own rating of Arthas does not clobber A's
  as(B, B.ns.Rate, "Arthas Menethil", 1, "was fine with me")
  flush()
  local agg = A.ns.Ratings.Aggregate(A.db, "Arthas Menethil")
  eq(agg.happy, 1, "A sees B's smile")
  eq(agg.sad, 1, "A keeps own frown")

  -- Entries about the receiver and entries claiming to be from the receiver are dropped
  as(A, A.ns.Rate, "Thrall Doomhammer", -1, "about B")
  flush()
  ok(rating(B, "Thrall Doomhammer", A.key) == nil, "ratings about the receiver are not delivered")
  local before = #PRINTS
  local forged = A.ns.Comms.Encode({ m = "R", e = { g = "Victim Person", a = B.key, r = -1, t = serverTime }, k = A.key })
  as(B, function() B.ns.frame:Fire("BN_CHAT_MSG_ADDON", "WOWFRIENDLY", forged, "WHISPER", 1) end)
  ok(rating(B, "Victim Person", B.key) == nil, "entries impersonating the receiver are dropped")

  -- Big note still fits over Battle.net (possibly shortened)
  advance(200)
  as(A, A.ns.Rate, "Longnote Person", 1, string.rep("word ", 20))
  flush()
  e = rating(B, "Longnote Person", A.key)
  ok(e and e.r == 1 and e.n and #e.n > 0 and #e.n <= 100, "long note arrives over Battle.net")

  -- Incremental sync only ships new entries
  advance(200)
  as(A, A.ns.Rate, "Later Person", 1)
  as(B, A.ns.Rate, "Not Delivered", 1) -- rated by B while messages flow
  flush()
  advance(200)
  as(A, A.ns.Comms.SyncNow, true)
  count = flush()
  ok(count <= 8, "second sync stays small: " .. count)
  ok(rating(B, "Later Person", A.key), "second sync delivered the new entry")

  -- Two-face levels travel like one-face levels: same wire size, same path, same chat
  local long = string.rep("word ", 20)
  local function wireSize(r)
    return #A.ns.Comms.Encode({ m = "R", e = { g = "Strong Person", a = A.key, r = r, t = serverTime, n = long }, k = A.key })
  end
  ok(math.abs(wireSize(2) - wireSize(1)) <= 2 and math.abs(wireSize(-2) - wireSize(-1)) <= 2, "two-face levels do not grow the Battle.net payload")
  advance(200)
  as(A, A.ns.Rate, "Strong Person", 2, long)
  flush()
  e = rating(B, "Strong Person", A.key)
  ok(e and e.r == 2 and e.n and #e.n > 0 and #e.n <= 100, "two smiles with a long note arrive over Battle.net")
  PRINTS = {}
  as(A, A.ns.Rate, "Worst Person", -2, "ninja")
  flush()
  e = rating(B, "Worst Person", A.key)
  ok(e and e.r == -2 and e.n == "ninja", "live RATE with two frowns reached B")
  local seen = false
  for _, p in ipairs(PRINTS) do
    if p:find("Worst Person", 1, true) and p:find(B.ns.FROWN_ICON .. B.ns.FROWN_ICON .. " big jerk", 1, true) then seen = true end
  end
  ok(seen, "B's chat message shows two frowns")
  as(B, B.ns.Rate, "Strong Person", -1, "meh")
  flush()
  agg = A.ns.Ratings.Aggregate(A.db, "Strong Person")
  eq(agg.counts[2], 1, "A keeps own two smiles")
  eq(agg.counts[-1], 1, "A sees B's one frown")
  eq(agg.counts[1] + agg.counts[-2], 0, "other buckets stay empty")

  -- Untrusted: C is in A's party but not a friend
  local C = NewClient("Sneaky", "Stranger", { bnID = 3, party = "p1" })
  A.party = "p1"
  as(C, C.ns.Rate, "Innocent Bystander", -1, "poison")
  as(C, C.ns.Comms.SyncNow, true)
  flush()
  ok(rating(A, "Innocent Bystander", "Sneaky Stranger") == nil, "untrusted party member's data is ignored")
  ok(A.ns.Comms._internal.peers()["Sneaky Stranger"] == nil, "untrusted sender is not remembered as a peer")

  -- Now trust each other; A trusts C by first name only (the sender string is "Sneaky-Forever")
  advance(200)
  A.db.friends["Sneaky"] = true
  C.db.friends["Jaina"] = true
  as(C, C.ns.Comms.SyncNow, true)
  flush()
  e = rating(A, "Innocent Bystander", "Sneaky Stranger")
  ok(e and e.r == -1, "trusted-by-first-name sender accepted over party/whisper")

  -- Relay: B is not C's friend, but learns C's rating through A
  advance(200)
  as(A, A.ns.Comms.SyncNow, true)
  flush()
  e = rating(B, "Innocent Bystander", "Sneaky Stranger")
  ok(e and e.r == -1 and e.n == "poison", "relayed rating keeps the original author")

  -- Lockdown queues sends, then drains on restriction change
  advance(200)
  lockdown = true
  as(A, A.ns.Rate, "Locked Person", -1)
  ok(A.ns.Comms.QueueLength() > 0, "rating during lockdown is queued")
  flush()
  ok(rating(B, "Locked Person", A.key) == nil, "nothing sent during lockdown")
  lockdown = false
  as(A, function() A.ns.frame:Fire("ADDON_RESTRICTION_STATE_CHANGED", 1, 0) end)
  flush()
  eq(A.ns.Comms.QueueLength(), 0, "queue drained after lockdown")
  ok(rating(B, "Locked Person", A.key), "queued rating delivered after lockdown")

  -- Export from A, import into a fresh client D
  local D = NewClient("Fresh", "Person", {})
  local exported = as(A, function() return A.ns.Comms.EncodeForPrint(A.ns.Ratings.ToTable(A.db)) end)
  local added = select(1, D.ns.Ratings.FromTable(D.db, D.ns.Comms.DecodeFromPrint(exported), D.ns.Identity.IsValidKey, D.key))
  ok(added >= 5, "import of export adds entries: " .. added)
  ok(rating(D, "Arthas Menethil", A.key) and rating(D, "Arthas Menethil", B.key), "import carries every author")

  -- Guild sharing off: guild hello ignored; on: accepted
  local G1 = NewClient("Alpha", "Guildone", { guild = "g" })
  local G2 = NewClient("Beta", "Guildtwo", { guild = "g" })
  as(G1, G1.ns.Rate, "Guild Target", 1, "nice")
  as(G1, function() G1.db.settings.shareGuild = true; G1.ns.Comms.OnGuildSharingChanged(true) end)
  flush()
  ok(rating(G2, "Guild Target", G1.key) == nil, "guild data ignored while sharing is off at the receiver")
  advance(200)
  as(G2, function() G2.db.settings.shareGuild = true; G2.ns.Comms.OnGuildSharingChanged(true) end)
  as(G1, G1.ns.Comms.HelloGuild, true)
  flush()
  e = rating(G2, "Guild Target", G1.key)
  ok(e and e.r == 1, "guild sharing exchanges ratings when both opt in")
end

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
