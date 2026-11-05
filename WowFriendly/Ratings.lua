-- WowFriendly: rating store. Pure Lua with no WoW API so it can run under plain Lua 5.1.
--
-- db.ratings[target][author] = { r = 1|-1|0, t = authorTime, n = note|nil, rt = receivedTime }
--   r  : 1 smile, -1 frown, 0 tombstone (cleared)
--   t  : the author's server timestamp for this entry; last-writer-wins per (target, author)
--   n  : optional note, at most MAX_NOTE characters
--   rt : when this client first stored this version (local only, never shipped)
local _, ns = ...

local Ratings = {}
ns.Ratings = Ratings

Ratings.MAX_NOTE = 100
Ratings.MAX_FUTURE = 86400 -- entries stamped more than a day in the future are rejected

-- Time source; tests override this.
Ratings.now = function()
  if GetServerTime then return GetServerTime() end
  return os.time()
end

local function isInteger(v)
  return type(v) == "number" and v == math.floor(v) and v > 0 and v ~= math.huge
end

-- Cuts a UTF-8 string to at most maxBytes without splitting a multibyte character.
local function utf8Truncate(s, maxBytes)
  if #s <= maxBytes then return s end
  local cut = maxBytes
  while cut > 0 do
    local b = s:byte(cut + 1)
    if not b or b < 0x80 or b >= 0xC0 then break end
    cut = cut - 1
  end
  return s:sub(1, cut)
end

-- Removes UI escape characters and control characters; nil when nothing is left.
function Ratings.SanitizeNote(note)
  if type(note) ~= "string" then return nil end
  note = note:gsub("|", ""):gsub("%c", " ")
  note = note:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if note == "" then return nil end
  note = utf8Truncate(note, Ratings.MAX_NOTE)
  note = note:gsub("%s+$", "")
  if note == "" then return nil end
  return note
end

-- Validates an entry from any source; returns ok, cleanEntryOrReason.
function Ratings.ValidateEntry(entry)
  if type(entry) ~= "table" then return false, "not a table" end
  local r, t = entry.r, entry.t
  if r ~= 1 and r ~= -1 and r ~= 0 then return false, "bad rating" end
  if not isInteger(t) then return false, "bad time" end
  if t > Ratings.now() + Ratings.MAX_FUTURE then return false, "time in future" end
  local n = nil
  if r ~= 0 then
    if entry.n ~= nil and type(entry.n) ~= "string" then return false, "bad note" end
    n = Ratings.SanitizeNote(entry.n)
  end
  return true, { r = r, t = t, n = n }
end

-- Deterministic ordering for equal timestamps so every peer picks the same winner.
-- Returns true when a should replace b.
function Ratings.Wins(a, b)
  if not b then return true end
  if a.t ~= b.t then return a.t > b.t end
  if a.r ~= b.r then return a.r > b.r end
  local an, bn = a.n or "", b.n or ""
  if an ~= bn then return an > bn end
  return false
end

local function bucket(db, target, create)
  local ratings = db.ratings
  local authors = ratings[target]
  if not authors and create then
    authors = {}
    ratings[target] = authors
  end
  return authors
end

function Ratings.GetByAuthor(db, target, author)
  local authors = bucket(db, target, false)
  return authors and authors[author] or nil
end

function Ratings.Get(db, target)
  return bucket(db, target, false)
end

-- Records the local player's rating. Guarantees a strictly newer timestamp than the
-- previous entry by the same author so peers never see a tie.
function Ratings.Set(db, target, author, value, note, t)
  assert(value == 1 or value == -1, "value must be 1 or -1")
  t = t or Ratings.now()
  local existing = Ratings.GetByAuthor(db, target, author)
  if existing and existing.t >= t then t = existing.t + 1 end
  local entry = { r = value, t = t, n = Ratings.SanitizeNote(note), rt = Ratings.now() }
  bucket(db, target, true)[author] = entry
  return entry
end

-- Writes a tombstone so the clear propagates to peers.
function Ratings.Clear(db, target, author, t)
  t = t or Ratings.now()
  local existing = Ratings.GetByAuthor(db, target, author)
  if existing and existing.t >= t then t = existing.t + 1 end
  local entry = { r = 0, t = t, rt = Ratings.now() }
  bucket(db, target, true)[author] = entry
  return entry
end

-- Merges a remote entry. Returns "added", "updated" or "skipped" (plus a reason when skipped).
function Ratings.Merge(db, target, author, entry)
  local ok, clean = Ratings.ValidateEntry(entry)
  if not ok then return "skipped", clean end
  local existing = Ratings.GetByAuthor(db, target, author)
  if existing and not Ratings.Wins(clean, existing) then return "skipped", "older" end
  clean.rt = Ratings.now()
  bucket(db, target, true)[author] = clean
  return existing and "updated" or "added"
end

-- Visible ratings for a target: counts plus entries sorted newest first. Nil when none.
function Ratings.Aggregate(db, target)
  local authors = bucket(db, target, false)
  if not authors then return nil end
  local result = { happy = 0, sad = 0, entries = {} }
  for author, e in pairs(authors) do
    if e.r == 1 then
      result.happy = result.happy + 1
    elseif e.r == -1 then
      result.sad = result.sad + 1
    end
    if e.r ~= 0 then
      result.entries[#result.entries + 1] = { author = author, r = e.r, t = e.t, n = e.n }
    end
  end
  if #result.entries == 0 then return nil end
  table.sort(result.entries, function(a, b)
    if a.t ~= b.t then return a.t > b.t end
    return a.author < b.author
  end)
  result.newest = result.entries[1]
  return result
end

-- Entries first stored locally at or after time t (uses rt so relayed data propagates
-- even when its author timestamp is old). Sorted oldest first.
function Ratings.EntriesSince(db, t)
  t = t or 0
  local list = {}
  for target, authors in pairs(db.ratings) do
    for author, e in pairs(authors) do
      local stamp = e.rt or e.t
      if stamp >= t then
        list[#list + 1] = { g = target, a = author, r = e.r, t = e.t, n = e.n, _rt = stamp }
      end
    end
  end
  table.sort(list, function(a, b)
    if a._rt ~= b._rt then return a._rt < b._rt end
    if a.g ~= b.g then return a.g < b.g end
    return a.a < b.a
  end)
  for _, e in ipairs(list) do e._rt = nil end
  return list
end

-- Everything, in a shippable form (no local receive times).
function Ratings.ToTable(db)
  local out = { v = ns.PROTOCOL_VERSION or 1, e = {} }
  for target, authors in pairs(db.ratings) do
    for author, e in pairs(authors) do
      out.e[#out.e + 1] = { g = target, a = author, r = e.r, t = e.t, n = e.n }
    end
  end
  table.sort(out.e, function(a, b)
    if a.g ~= b.g then return a.g < b.g end
    return a.a < b.a
  end)
  return out
end

-- Merges a table produced by ToTable (or received over the wire). isValidKey filters
-- names; skipTarget drops entries about a given player (yourself). Returns counts.
function Ratings.FromTable(db, tbl, isValidKey, skipTarget)
  local added, updated, skipped = 0, 0, 0
  if type(tbl) ~= "table" or type(tbl.e) ~= "table" then return 0, 0, 0 end
  for _, e in ipairs(tbl.e) do
    local target, author = e.g, e.a
    if type(target) ~= "string" or type(author) ~= "string"
      or (isValidKey and not (isValidKey(target) and isValidKey(author)))
      or (skipTarget and target == skipTarget) then
      skipped = skipped + 1
    else
      local result = Ratings.Merge(db, target, author, e)
      if result == "added" then added = added + 1
      elseif result == "updated" then updated = updated + 1
      else skipped = skipped + 1 end
    end
  end
  return added, updated, skipped
end

-- Number of (target, author) pairs that are live ratings, and number of rated players.
function Ratings.Count(db)
  local entries, players = 0, 0
  for _, authors in pairs(db.ratings) do
    local live = 0
    for _, e in pairs(authors) do
      if e.r ~= 0 then live = live + 1 end
    end
    if live > 0 then players = players + 1 end
    entries = entries + live
  end
  return entries, players
end

-- Sorted list of targets that have at least one live rating.
function Ratings.AllTargets(db)
  local list = {}
  for target, authors in pairs(db.ratings) do
    for _, e in pairs(authors) do
      if e.r ~= 0 then
        list[#list + 1] = target
        break
      end
    end
  end
  table.sort(list)
  return list
end

-- Drops tombstones older than maxAge seconds (default 90 days) and empty buckets.
function Ratings.Prune(db, maxAge)
  maxAge = maxAge or 90 * 86400
  local cutoff = Ratings.now() - maxAge
  local removed = 0
  for target, authors in pairs(db.ratings) do
    for author, e in pairs(authors) do
      if e.r == 0 and (e.rt or e.t) < cutoff then
        authors[author] = nil
        removed = removed + 1
      end
    end
    if next(authors) == nil then db.ratings[target] = nil end
  end
  return removed
end
