-- WowFriendly: peer-to-peer sync over addon channels and Battle.net game data.
--
-- Protocol (all tables, LibSerialize -> Deflate -> addon-channel encoding):
--   H  hello   { m="H", v=protocol, c=ratingCount, k=myKey }
--   S  since   { m="S", t=lastSyncTime, k=myKey }      "send me what you stored since t"
--   D  delta   { m="D", e={ {g,a,r,t,n}, ... }, k=myKey }
--   R  rate    { m="R", e={g,a,r,t,n}, k=myKey }        a single live rating
-- Entries are merged last-writer-wins per (target g, author a); r runs from -2 (two
-- frowns) to 2 (two smiles) and clears travel as tombstones (r = 0). Only trusted
-- senders are accepted: Battle.net friends, the explicit trusted list, and guild
-- members when guild sharing is on.
local _, ns = ...

local Comms, Trust = {}, {}
ns.Comms, ns.Trust = Comms, Trust

local AceComm = LibStub and LibStub("AceComm-3.0", true)
local LibSerialize = LibStub and LibStub("LibSerialize", true)
local LibDeflate = LibStub and LibStub("LibDeflate", true)
local CTL = ChatThrottleLib

local PREFIX = ns.PREFIX
local PROTOCOL = ns.PROTOCOL_VERSION
local MAX_BN_BYTES = 255          -- ChatThrottleLib:BNSendGameData limit
local DELTA_CHUNK = 40            -- entries per DELTA message on addon channels
local MAX_DELTA_ENTRIES = 500     -- entries accepted per DELTA from a trusted friend
local GUILD_DELTA_CAP = 50        -- entries accepted per DELTA from a guild-only sender
local HELLO_REPLY_INTERVAL = 60   -- seconds between replies to the same peer's HELLO
local HELLO_TARGET_INTERVAL = 120 -- seconds between HELLOs to the same channel/target
local SINCE_OVERLAP = 60          -- re-request this much history to cover clock skew
local QUEUE_MAX = 200
local HELLO_TTL = 120             -- queued HELLOs older than this are dropped
local PEER_TTL = 3600             -- seconds after which a silent peer is forgotten
local EXPORT_PREFIX = "WF1:"

local available = (AceComm and LibSerialize and LibDeflate and CTL) and true or false

local comm = {}
if AceComm then
  if AceComm.Embed then
    AceComm:Embed(comm)
  else
    comm.RegisterComm = function(_, ...) return AceComm:RegisterComm(...) end
    comm.SendCommMessage = function(_, ...) return AceComm:SendCommMessage(...) end
  end
end

local function now() return ns.Now() end
local function mono()
  if GetTime then return GetTime() end
  return now()
end
local function myKey() return ns.Identity.SelfKey() end
local function settings() return ns.db and ns.db.settings or ns.defaults end

function Comms.Available() return available end

---------------------------------------------------------------------------
-- Encoding
---------------------------------------------------------------------------

function Comms.Serialize(tbl)
  local ok, serialized = pcall(LibSerialize.Serialize, LibSerialize, tbl)
  if not ok or type(serialized) ~= "string" then return nil end
  local compressed = LibDeflate:CompressDeflate(serialized, { level = 6 })
  return compressed
end

function Comms.Deserialize(compressed)
  local decompressed = LibDeflate:DecompressDeflate(compressed)
  if type(decompressed) ~= "string" then return nil, "inflate" end
  -- LibSerialize:Deserialize returns success, value
  local ok, success, value = pcall(LibSerialize.Deserialize, LibSerialize, decompressed)
  if not ok or success ~= true then return nil, "deserialize" end
  if type(value) ~= "table" then return nil, "not a table" end
  return value
end

function Comms.Encode(tbl)
  if not available then return nil end
  local compressed = Comms.Serialize(tbl)
  if not compressed then return nil end
  return LibDeflate:EncodeForWoWAddonChannel(compressed)
end

function Comms.Decode(text)
  if not available or type(text) ~= "string" then return nil, "unavailable" end
  local compressed = LibDeflate:DecodeForWoWAddonChannel(text)
  if not compressed then return nil, "decode" end
  return Comms.Deserialize(compressed)
end

function Comms.EncodeForPrint(tbl)
  if not available then return nil end
  local compressed = Comms.Serialize(tbl)
  if not compressed then return nil end
  return EXPORT_PREFIX .. LibDeflate:EncodeForPrint(compressed)
end

function Comms.DecodeFromPrint(text)
  if not available or type(text) ~= "string" then return nil, "unavailable" end
  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  if text:sub(1, #EXPORT_PREFIX) == EXPORT_PREFIX then text = text:sub(#EXPORT_PREFIX + 1) end
  text = text:gsub("%s", "")
  local compressed = LibDeflate:DecodeForPrint(text)
  if not compressed then return nil, "not a WowFriendly string" end
  return Comms.Deserialize(compressed)
end

---------------------------------------------------------------------------
-- Lockdown-aware send queue
---------------------------------------------------------------------------

local queue = {}

function Comms.CanSend()
  if C_ChatInfo and C_ChatInfo.InChatMessagingLockdown then
    local ok, locked = pcall(C_ChatInfo.InChatMessagingLockdown)
    if ok and locked == true then return false end
  end
  if C_RestrictedActions and C_RestrictedActions.IsChatMessagingRestricted then
    local ok, restricted = pcall(C_RestrictedActions.IsChatMessagingRestricted)
    if ok and restricted == true then return false end
  end
  return true
end

local function SendNow(item)
  if item.kind == "BN" then
    CTL:BNSendGameData(item.prio, PREFIX, item.text, "WHISPER", item.target)
  else
    comm:SendCommMessage(PREFIX, item.text, item.dist, item.target, item.prio)
  end
end

function Comms.Drain()
  if #queue == 0 then return end
  if not Comms.CanSend() then
    ns.Debug("comms: messaging locked down, %d queued", #queue)
    return
  end
  local pending = queue
  queue = {}
  local t = mono()
  for _, item in ipairs(pending) do
    if item.ttl and t - item.created > item.ttl then
      ns.Debug("comms: dropped stale %s message", item.kind)
    else
      local ok, err = pcall(SendNow, item)
      if not ok then ns.Debug("comms: send failed: %s", tostring(err)) end
    end
  end
end

local function Enqueue(item)
  item.created = mono()
  if #queue >= QUEUE_MAX then table.remove(queue, 1) end
  queue[#queue + 1] = item
  Comms.Drain()
end

function Comms.QueueLength() return #queue end

local function SendAddon(text, dist, target, prio, ttl)
  Enqueue({ kind = "ADDON", text = text, dist = dist, target = target, prio = prio or "NORMAL", ttl = ttl })
  return true
end

-- Battle.net game data: single part, at most 255 bytes, unordered. Escape a leading
-- control character the same way AceComm does so receivers can tell parts apart.
local function SendBN(text, gameAccountID, prio, ttl)
  if text:match("^[\001-\009]") then text = "\004" .. text end
  if #text > MAX_BN_BYTES then return false end
  Enqueue({ kind = "BN", text = text, target = gameAccountID, prio = prio or "NORMAL", ttl = ttl })
  return true
end

-- route = { via = "ADDON", dist = "WHISPER"|"PARTY"|..., target = name|nil } or { via = "BN", target = gameAccountID }
local function SendTable(route, tbl, prio, ttl)
  local text = Comms.Encode(tbl)
  if not text then return false end
  if route.via == "BN" then return SendBN(text, route.target, prio, ttl) end
  return SendAddon(text, route.dist, route.target, prio, ttl)
end

local function copyEntry(e)
  return { g = e.g, a = e.a, r = e.r, t = e.t, n = e.n }
end

-- Sends a single entry over Battle.net, shortening the note until it fits.
local function SendEntryBN(route, entry, prio)
  local e = copyEntry(entry)
  for _ = 1, 8 do
    local text = Comms.Encode({ m = "R", e = e, k = myKey() })
    if text and #text + 1 <= MAX_BN_BYTES then return SendBN(text, route.target, prio) end
    if not e.n or e.n == "" then return false end
    local half = math.floor(#e.n / 2)
    e.n = ns.Ratings.SanitizeNote(e.n:sub(1, half))
  end
  return false
end

local function SendDelta(route, entries, prio)
  if #entries == 0 then
    return SendTable(route, { m = "D", e = {}, k = myKey() }, prio)
  end
  if route.via == "BN" then
    local i = 1
    while i <= #entries do
      local chunk, text, j = {}, nil, i
      while j <= #entries do
        chunk[#chunk + 1] = entries[j]
        local attempt = Comms.Encode({ m = "D", e = chunk, k = myKey() })
        if attempt and #attempt + 1 <= MAX_BN_BYTES then
          text = attempt
          j = j + 1
        else
          chunk[#chunk] = nil
          break
        end
      end
      if #chunk == 0 then
        SendEntryBN(route, entries[i], prio)
        i = i + 1
      else
        SendBN(text, route.target, prio)
        i = j
      end
    end
    return true
  end
  for i = 1, #entries, DELTA_CHUNK do
    local chunk = {}
    for j = i, math.min(i + DELTA_CHUNK - 1, #entries) do chunk[#chunk + 1] = copyEntry(entries[j]) end
    SendTable(route, { m = "D", e = chunk, k = myKey() }, prio)
  end
  return true
end

---------------------------------------------------------------------------
-- Peers and trust
---------------------------------------------------------------------------

local peers = {}        -- peerKey -> { key, route, trust, lastSeen (mono) }
local helloReplyAt = {} -- peerKey -> mono time we last answered their HELLO
local helloSentAt = {}  -- target id -> mono time we last sent a HELLO there
local sinceSentAt = {}  -- peerKey -> server time we last asked them for a delta
local guildPeers = {}   -- senderKey -> true when they HELLO'd us on the guild channel this session
local guildRoster = {}  -- key -> true, refreshed on GUILD_ROSTER_UPDATE

local function RefreshGuildRoster()
  guildRoster = {}
  if not (IsInGuild and GetNumGuildMembers and GetGuildRosterInfo) then return end
  if not ns.SafeCall("boolean", IsInGuild) then return end
  local total = ns.SafeCall("number", GetNumGuildMembers)
  if not total then return end
  for i = 1, total do
    local ok, name = pcall(GetGuildRosterInfo, i)
    if ok then
      local key = ns.Identity.KeyFromSender(ns.Readable(name, "string"))
      if key then guildRoster[key] = true end
    end
  end
end

local function IsGuildMember(senderKey)
  return ns.Identity.FindMatch(guildRoster, senderKey) ~= nil
end

-- Returns "bnet", "friend" or "guild" when the sender may feed our pool, else nil.
function Trust.Classify(ctx)
  local s = settings()
  if ctx.via == "BN" then
    -- Battle.net game data can only arrive from one of our Battle.net friends' game accounts.
    if s.syncBattleNet then return "bnet" end
    return nil
  end
  if not ctx.senderKey then return nil end
  if s.syncTrusted and ns.db and ns.Identity.FindMatch(ns.db.friends, ctx.senderKey) then return "friend" end
  if s.shareGuild then
    if ctx.distribution == "GUILD" then return "guild" end
    if guildPeers[ctx.senderKey] then return "guild" end
    if IsGuildMember(ctx.senderKey) then return "guild" end
  end
  return nil
end

function Trust.IsTrustedSender(senderKey, distribution, gameAccountID)
  return Trust.Classify({
    via = gameAccountID and "BN" or "ADDON",
    senderKey = senderKey,
    distribution = distribution,
    sender = gameAccountID or senderKey,
  }) ~= nil
end

local function RouteFor(ctx)
  if ctx.via == "BN" then return { via = "BN", target = ctx.sender } end
  return { via = "ADDON", dist = "WHISPER", target = ctx.sender }
end

local function RememberPeer(ctx)
  local p = peers[ctx.peerKey] or {}
  p.key = ctx.peerKey
  p.route = ctx.route
  p.trust = ctx.trust
  p.lastSeen = mono()
  peers[ctx.peerKey] = p
  if ns.db then
    local saved = ns.db.peers[ctx.peerKey] or {}
    saved.lastSeen = now()
    saved.trust = ctx.trust
    ns.db.peers[ctx.peerKey] = saved
  end
end

local function PrunePeers()
  local t = mono()
  for key, p in pairs(peers) do
    if t - p.lastSeen > PEER_TTL then peers[key] = nil end
  end
end

---------------------------------------------------------------------------
-- Message handling
---------------------------------------------------------------------------

local function HelloPayload()
  local count = ns.Ratings.Count(ns.db)
  return { m = "H", v = PROTOCOL, c = count, k = myKey() }
end

local function SendSince(peerKey, route)
  local saved = ns.db.peers[peerKey]
  local since = ((saved and saved.lastSync) or 0) - SINCE_OVERLAP
  if since < 0 then since = 0 end
  sinceSentAt[peerKey] = now()
  SendTable(route, { m = "S", t = since, k = myKey() }, "NORMAL", HELLO_TTL)
end

-- Merges a list of wire entries; drops anything about us or claiming to be from us.
local function MergeEntries(list, ctx, cap)
  local me = myKey()
  local added, updated, skipped = 0, 0, 0
  for i, e in ipairs(list) do
    if i > cap then
      skipped = skipped + (#list - cap)
      ns.Debug("comms: capped delta from %s at %d entries", tostring(ctx.peerKey), cap)
      break
    end
    local target = type(e) == "table" and ns.Identity.KeyFromSender(e.g) or nil
    local author = type(e) == "table" and ns.Identity.KeyFromSender(e.a) or nil
    if not target or not author
      or (me and (ns.Identity.Matches(target, me) or ns.Identity.Matches(author, me))) then
      skipped = skipped + 1
    else
      local result = ns.Ratings.Merge(ns.db, target, author, e)
      if result == "added" then added = added + 1
      elseif result == "updated" then updated = updated + 1
      else skipped = skipped + 1 end
    end
  end
  return added, updated, skipped
end

local function OnHello(msg, ctx)
  if msg.v ~= PROTOCOL then
    ns.Debug("comms: %s speaks protocol %s, we speak %d", tostring(ctx.peerKey), tostring(msg.v), PROTOCOL)
    return
  end
  local t = mono()
  local last = helloReplyAt[ctx.peerKey]
  if last and t - last < HELLO_REPLY_INTERVAL then return end
  helloReplyAt[ctx.peerKey] = t
  if ctx.via == "ADDON" and ctx.distribution == "GUILD" then guildPeers[ctx.senderKey] = true end
  ns.Debug("comms: hello from %s (%s, %s ratings)", tostring(ctx.peerKey), ctx.trust, tostring(msg.c))
  SendSince(ctx.peerKey, ctx.route)
end

local function OnSince(msg, ctx)
  local t = tonumber(msg.t) or 0
  if t < 0 then t = 0 end
  local entries = ns.Ratings.EntriesSince(ns.db, t)
  local filtered = {}
  for _, e in ipairs(entries) do
    -- Do not tell people what others said about them.
    if not ns.Identity.Matches(e.g, ctx.peerKey) and not (ctx.senderKey and ns.Identity.Matches(e.g, ctx.senderKey)) then
      filtered[#filtered + 1] = e
    end
  end
  ns.Debug("comms: %s asked for changes since %d; sending %d", tostring(ctx.peerKey), t, #filtered)
  SendDelta(ctx.route, filtered, "BULK")
  -- Make the exchange symmetric: ask them too, unless we did so a moment ago.
  local lastAsk = sinceSentAt[ctx.peerKey]
  if not lastAsk or now() - lastAsk > HELLO_REPLY_INTERVAL then
    SendSince(ctx.peerKey, ctx.route)
  end
end

local function OnDelta(msg, ctx)
  if type(msg.e) ~= "table" then return end
  local cap = ctx.trust == "guild" and GUILD_DELTA_CAP or MAX_DELTA_ENTRIES
  local added, updated, skipped = MergeEntries(msg.e, ctx, cap)
  local saved = ns.db.peers[ctx.peerKey] or {}
  saved.lastSync = sinceSentAt[ctx.peerKey] or now()
  ns.db.peers[ctx.peerKey] = saved
  ns.Debug("comms: delta from %s: %d added, %d updated, %d skipped", tostring(ctx.peerKey), added, updated, skipped)
  if added + updated > 0 then
    ns.Print("Received %d new and %d updated ratings from %s.", added, updated, ctx.peerKey)
    ns.Fire("RATING_CHANGED")
  end
end

local function OnRate(msg, ctx)
  if type(msg.e) ~= "table" then return end
  local added, updated = MergeEntries({ msg.e }, ctx, 1)
  if added + updated > 0 then
    local e = msg.e
    local target = ns.Identity.KeyFromSender(e.g)
    local author = ns.Identity.KeyFromSender(e.a)
    if e.r == 0 then
      ns.Print("%s cleared their rating of %s.", author, target)
    else
      local what = ns.LevelText(e.r)
      local note = type(e.n) == "string" and ns.Ratings.SanitizeNote(e.n)
      ns.Print("%s rated %s as %s%s", author, target, what, note and (": \"" .. note .. "\"") or ".")
    end
    ns.Fire("RATING_CHANGED", target)
  end
end

local handlers = { H = OnHello, S = OnSince, D = OnDelta, R = OnRate }

local function HandleMessage(msg, ctx)
  if type(msg.m) ~= "string" or not handlers[msg.m] then return end
  local trust = Trust.Classify(ctx)
  if not trust then
    ns.Debug("comms: dropped %s from untrusted %s", msg.m, tostring(ctx.senderKey or ctx.sender))
    return
  end
  ctx.trust = trust
  -- Peer identity: the transport sender decides trust; the claimed key only refines the label.
  local claimed = type(msg.k) == "string" and ns.Identity.KeyFromSender(msg.k) or nil
  local peerKey = ctx.senderKey
  if ctx.via == "BN" then
    peerKey = claimed or ("BattleNet#" .. tostring(ctx.sender))
  elseif claimed and ns.Identity.Matches(claimed, ctx.senderKey) and ns.Identity.HasSurname(claimed) then
    peerKey = claimed
  end
  ctx.peerKey = peerKey
  ctx.route = RouteFor(ctx)
  RememberPeer(ctx)
  handlers[msg.m](msg, ctx)
end

local function OnAddonMessage(prefix, text, distribution, sender)
  if prefix ~= PREFIX or not ns.db then return end
  text = ns.Readable(text, "string")
  sender = ns.Readable(sender, "string")
  distribution = ns.Readable(distribution, "string")
  if not text or not sender then return end
  local senderKey = ns.Identity.KeyFromSender(sender)
  if not senderKey then return end
  local me = myKey()
  if me and ns.Identity.Matches(senderKey, me) then return end -- our own group/guild echo
  local msg, err = Comms.Decode(text)
  if not msg then
    ns.Debug("comms: undecodable message from %s (%s)", sender, tostring(err))
    return
  end
  HandleMessage(msg, { via = "ADDON", distribution = distribution, sender = sender, senderKey = senderKey })
end

local function OnBNMessage(prefix, text, _, gameAccountID)
  if prefix ~= PREFIX or not ns.db then return end
  text = ns.Readable(text, "string")
  gameAccountID = ns.Readable(gameAccountID, "number")
  if not text or not gameAccountID then return end
  if text:sub(1, 1) == "\004" then
    text = text:sub(2)
  elseif text:match("^[\001-\003]") then
    return -- multipart markers are never valid over Battle.net
  end
  local msg, err = Comms.Decode(text)
  if not msg then
    ns.Debug("comms: undecodable Battle.net message from #%d (%s)", gameAccountID, tostring(err))
    return
  end
  HandleMessage(msg, { via = "BN", sender = gameAccountID })
end

---------------------------------------------------------------------------
-- Outbound: hellos and live ratings
---------------------------------------------------------------------------

local function ShouldHello(targetId, force)
  local t = mono()
  local last = helloSentAt[targetId]
  if not force and last and t - last < HELLO_TARGET_INTERVAL then return false end
  helloSentAt[targetId] = t
  return true
end

function Comms.HelloGroup(force)
  if not available or not ns.db then return end
  if not IsInGroup then return end
  local inGroup = ns.SafeCall("boolean", IsInGroup, LE_PARTY_CATEGORY_HOME)
  if not inGroup then return end
  local inRaid = IsInRaid and ns.SafeCall("boolean", IsInRaid, LE_PARTY_CATEGORY_HOME)
  local dist = inRaid and "RAID" or "PARTY"
  if not ShouldHello("group:" .. dist, force) then return end
  local text = Comms.Encode(HelloPayload())
  if text then SendAddon(text, dist, nil, "NORMAL", HELLO_TTL) end
end

function Comms.HelloGuild(force)
  if not available or not ns.db or not settings().shareGuild then return end
  if not (IsInGuild and ns.SafeCall("boolean", IsInGuild)) then return end
  if not ShouldHello("guild", force) then return end
  local text = Comms.Encode(HelloPayload())
  if text then SendAddon(text, "GUILD", nil, "NORMAL", HELLO_TTL) end
end

-- Whispers trusted characters. Addon whispers to offline players fail silently. A key
-- with a surname is also tried as first name only, since the server form is unverified.
function Comms.HelloFriends(force)
  if not available or not ns.db or not settings().syncTrusted then return end
  local text = Comms.Encode(HelloPayload())
  if not text then return end
  for name, enabled in pairs(ns.db.friends) do
    if enabled then
      if ShouldHello("w:" .. name, force) then SendAddon(text, "WHISPER", name, "NORMAL", HELLO_TTL) end
      local first = ns.Identity.FirstName(name)
      if first and first ~= name and ShouldHello("w:" .. first, force) then
        SendAddon(text, "WHISPER", first, "NORMAL", HELLO_TTL)
      end
    end
  end
end

-- Calls fn(gameAccountID, info) for every Battle.net friend online in a WoW client of our project.
local function ForEachOnlineWoWFriend(fn)
  if not (BNGetNumFriends and C_BattleNet) then return end
  local total = ns.SafeCall("number", BNGetNumFriends)
  if not total then return end
  local wowClient = BNET_CLIENT_WOW or "WoW"
  for i = 1, total do
    local numAccounts = 1
    if C_BattleNet.GetFriendNumGameAccounts then
      numAccounts = ns.SafeCall("number", C_BattleNet.GetFriendNumGameAccounts, i) or 1
    end
    for j = 1, numAccounts do
      local info
      if C_BattleNet.GetFriendGameAccountInfo then
        info = ns.SafeCall("table", C_BattleNet.GetFriendGameAccountInfo, i, j)
      elseif j == 1 and C_BattleNet.GetFriendAccountInfo then
        local account = ns.SafeCall("table", C_BattleNet.GetFriendAccountInfo, i)
        info = account and ns.Readable(account.gameAccountInfo, "table") or nil
      end
      if info then
        local client = ns.Readable(info.clientProgram, "string")
        local online = ns.Readable(info.isOnline, "boolean")
        local id = ns.Readable(info.gameAccountID, "number")
        local project = ns.Readable(info.wowProjectID, "number")
        if id and online and client == wowClient and (project == nil or WOW_PROJECT_ID == nil or project == WOW_PROJECT_ID) then
          fn(id, info)
        end
      end
    end
  end
end

function Comms.HelloBattleNet(force)
  if not available or not ns.db or not settings().syncBattleNet then return end
  local text = Comms.Encode(HelloPayload())
  if not text then return end
  ForEachOnlineWoWFriend(function(id)
    if ShouldHello("bn:" .. id, force) then SendBN(text, id, "NORMAL", HELLO_TTL) end
  end)
end

function Comms.SyncNow(force)
  if not available or not ns.db then return end
  Comms.HelloGroup(force)
  Comms.HelloGuild(force)
  Comms.HelloFriends(force)
  Comms.HelloBattleNet(force)
end

-- Pushes a rating we just made to every reachable trusted peer.
function Comms.Broadcast(target, author, entry)
  if not available or not ns.db or not entry then return end
  local payload = { g = target, a = author, r = entry.r, t = entry.t, n = entry.n }
  local sentGuild = false
  if settings().shareGuild and IsInGuild and ns.SafeCall("boolean", IsInGuild) then
    local text = Comms.Encode({ m = "R", e = payload, k = myKey() })
    if text then
      SendAddon(text, "GUILD", nil, "NORMAL")
      sentGuild = true
    end
  end
  local t = mono()
  for peerKey, p in pairs(peers) do
    if t - p.lastSeen <= PEER_TTL and not ns.Identity.Matches(peerKey, target) then
      if p.trust == "guild" and sentGuild then
        -- already covered by the guild broadcast
      elseif p.route.via == "BN" then
        SendEntryBN(p.route, payload, "NORMAL")
      else
        SendTable(p.route, { m = "R", e = payload, k = myKey() }, "NORMAL")
      end
    end
  end
end

function Comms.Status()
  if not available then
    ns.Print("Sharing is unavailable (missing library).")
    return
  end
  ns.Print("Messaging %s, %d queued.", Comms.CanSend() and "allowed" or "locked down", #queue)
  local count = 0
  local t = mono()
  for key, p in pairs(peers) do
    count = count + 1
    local saved = ns.db.peers[key]
    local lastSync = saved and saved.lastSync and date and date("%Y-%m-%d %H:%M", saved.lastSync) or "never"
    ns.Print("  %s via %s (%s), seen %ds ago, synced %s", key, p.route.via == "BN" and "Battle.net" or p.route.dist, p.trust, math.floor(t - p.lastSeen), lastSync)
  end
  if count == 0 then ns.Print("  No peers seen this session. /wf sync to say hello.") end
end

---------------------------------------------------------------------------
-- Scheduling and events
---------------------------------------------------------------------------

local pending = {}
local function Schedule(what, delay)
  if pending[what] then return end
  pending[what] = true
  local function run()
    pending[what] = nil
    if what == "all" then Comms.SyncNow(false)
    elseif what == "group" then Comms.HelloGroup(false)
    elseif what == "guild" then Comms.HelloGuild(false)
    elseif what == "bnet" then Comms.HelloBattleNet(false)
    elseif what == "drain" then Comms.Drain() end
  end
  if C_Timer and C_Timer.After then C_Timer.After(delay, run) else run() end
end

function Comms.OnGuildSharingChanged(enabled)
  if enabled then
    RefreshGuildRoster()
    Comms.HelloGuild(true)
  end
end

ns.OnInit(function()
  if not available then
    ns.Print("Sharing disabled: a required library failed to load.")
    return
  end
  comm:RegisterComm(PREFIX, OnAddonMessage)
  if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
  end
  ns.RegisterEvent("BN_CHAT_MSG_ADDON", OnBNMessage)
  ns.RegisterEvent("PLAYER_ENTERING_WORLD", function(isLogin, isReload)
    if isLogin or isReload then
      RefreshGuildRoster()
      Schedule("all", 5)
    end
  end)
  ns.RegisterEvent("GROUP_ROSTER_UPDATE", function() Schedule("group", 3) end)
  ns.RegisterEvent("GUILD_ROSTER_UPDATE", function()
    if settings().shareGuild then
      RefreshGuildRoster()
      Schedule("guild", 10)
    end
  end)
  ns.RegisterEvent("BN_FRIEND_INFO_CHANGED", function() Schedule("bnet", 5) end)
  ns.RegisterEvent("ADDON_RESTRICTION_STATE_CHANGED", function() Schedule("drain", 1) end)
  ns.RegisterEvent("PLAYER_REGEN_ENABLED", function() Schedule("drain", 1) end)
  if C_Timer and C_Timer.NewTicker then
    C_Timer.NewTicker(30, function()
      Comms.Drain()
      PrunePeers()
    end)
  end
end)

-- Exposed for tests.
Comms._internal = {
  MergeEntries = MergeEntries,
  HandleMessage = HandleMessage,
  OnAddonMessage = OnAddonMessage,
  OnBNMessage = OnBNMessage,
  peers = function() return peers end,
  queue = function() return queue end,
  SendDelta = SendDelta,
  SendEntryBN = SendEntryBN,
  MAX_BN_BYTES = MAX_BN_BYTES,
}
