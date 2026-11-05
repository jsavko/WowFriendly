-- WowFriendly: player identity keys.
--
-- WoW Forever has a single realm and gives characters a surname, so UnitFullName()
-- returns (firstName, surname) rather than (name, realm). Players are keyed by the
-- full display name, e.g. "Arthas Menethil", with no realm suffix. GUIDs are
-- obfuscated on Forever so they cannot be used. If this ever runs on a client where
-- the second return is a realm, that value is dropped instead of being treated as
-- a surname.
local _, ns = ...

local Identity = {}
ns.Identity = Identity

Identity.MAX_KEY_LENGTH = 64

local function IsSecret(v) return ns.IsSecret(v) end

local function ReadString(v)
  if IsSecret(v) or type(v) ~= "string" or v == "" then return nil end
  return v
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function collapseSpaces(s)
  return (s:gsub("%s+", " "))
end

-- Realm names as they might appear as a second return value, so we can drop them.
local function ownRealmNames()
  local names = {}
  if GetNormalizedRealmName then
    local n = ReadString(ns.SafeCall("string", GetNormalizedRealmName))
    if n then names[n:lower()] = true end
  end
  if GetRealmName then
    local n = ReadString(ns.SafeCall("string", GetRealmName))
    if n then
      names[n:lower()] = true
      names[(n:gsub("%s", "")):lower()] = true
    end
  end
  return names
end

function Identity.IsRealmName(s)
  if type(s) ~= "string" then return false end
  local lowered = s:gsub("%s", ""):lower()
  return ownRealmNames()[lowered] == true
end

-- Removes characters that can break chat/tooltip rendering or the key format.
function Identity.Sanitize(s)
  if type(s) ~= "string" then return nil end
  s = s:gsub("|", ""):gsub("%c", "")
  s = collapseSpaces(trim(s))
  if s == "" then return nil end
  return s
end

-- Strips a trailing "-Realm" suffix (addon-message senders arrive as Name-Realm).
function Identity.StripRealm(s)
  if type(s) ~= "string" then return nil end
  local base, suffix = s:match("^(.-)%-([^%-]+)$")
  if base and base ~= "" then
    -- Only treat it as a realm if it has no spaces (realm names are normalized) and is not part of the name.
    if not suffix:find("%s") then return base end
  end
  return s
end

function Identity.Normalize(s)
  s = Identity.Sanitize(s)
  if not s then return nil end
  s = Identity.StripRealm(s)
  s = Identity.Sanitize(s)
  return s
end

-- First UTF-8 character and the rest of the string.
local function splitFirstChar(s)
  local first = s:match("^[%z\1-\127\194-\244][\128-\191]*")
  if not first then return s, "" end
  return first, s:sub(#first + 1)
end

-- WoW capitalization: first name is Capitalized with the rest lowercased; later words
-- (surnames) get an uppercase first letter and keep the rest as typed.
function Identity.Capitalize(s)
  local words = {}
  for word in s:gmatch("%S+") do
    local first, rest = splitFirstChar(word)
    if #words == 0 then
      words[#words + 1] = first:upper() .. rest:lower()
    else
      words[#words + 1] = first:upper() .. rest
    end
  end
  return table.concat(words, " ")
end

-- A key is 2-64 characters of letters (including non-ASCII), apostrophes and hyphens,
-- in one or more space-separated words.
function Identity.IsValidKey(key)
  if type(key) ~= "string" then return false end
  if #key < 2 or #key > Identity.MAX_KEY_LENGTH then return false end
  if key:find("[%c|%%]") then return false end
  if key:find("^%s") or key:find("%s$") or key:find("%s%s") then return false end
  for word in key:gmatch("%S+") do
    if not word:match("^[%a\128-\255][%a\128-\255'%-]*$") then return false end
  end
  return true
end

-- Builds a key from a user-typed name ("arthas", "Arthas Menethil", "Arthas-Realm").
function Identity.KeyFromInput(text)
  local s = Identity.Normalize(text)
  if not s then return nil end
  s = Identity.Capitalize(s)
  if not Identity.IsValidKey(s) then return nil end
  return s
end

-- Builds a key from API returns: name plus either a surname (Forever) or a realm (other clients).
function Identity.KeyFromParts(name, second)
  name = ReadString(name)
  if not name then return nil end
  name = Identity.Sanitize(name)
  if not name then return nil end
  second = ReadString(second)
  if second then
    second = Identity.Sanitize(second)
    if second and Identity.IsRealmName(second) then second = nil end
  end
  local key = second and (name .. " " .. second) or name
  key = Identity.StripRealm(key)
  if not Identity.IsValidKey(key) then return nil end
  return key
end

-- Key for a unit token ("target", "mouseover", "party1"...). Nil for NPCs, secrets or missing units.
function Identity.KeyForUnit(unit)
  unit = ReadString(unit)
  if not unit then return nil end
  if not UnitExists or not UnitIsPlayer or not UnitFullName then return nil end
  local exists = ns.SafeCall("boolean", UnitExists, unit)
  if not exists then return nil end
  local isPlayer = ns.SafeCall("boolean", UnitIsPlayer, unit)
  if not isPlayer then return nil end
  local ok, name, second = pcall(UnitFullName, unit)
  if not ok then return nil end
  return Identity.KeyFromParts(name, second)
end

-- Key for a sender string from CHAT_MSG_ADDON ("Name-Realm" or "Name Surname-Realm").
function Identity.KeyFromSender(sender)
  local s = Identity.Normalize(sender)
  if not s or not Identity.IsValidKey(s) then return nil end
  return s
end

local selfKey
function Identity.SelfKey()
  if selfKey then return selfKey end
  local key = Identity.KeyForUnit("player")
  if key then selfKey = key end
  return key
end

-- For tests and /reload safety.
function Identity.ResetSelf()
  selfKey = nil
end

function Identity.FirstName(key)
  if type(key) ~= "string" then return nil end
  return key:match("^(%S+)")
end

function Identity.HasSurname(key)
  return type(key) == "string" and key:find("%s") ~= nil
end

-- Two keys refer to the same player when they are equal, or when one of them lacks a
-- surname and the first names agree (addon senders may arrive as first name only).
function Identity.Matches(a, b)
  if type(a) ~= "string" or type(b) ~= "string" then return false end
  if a == b then return true end
  if a:lower() == b:lower() then return true end
  if Identity.HasSurname(a) and Identity.HasSurname(b) then return false end
  local fa, fb = Identity.FirstName(a), Identity.FirstName(b)
  return fa ~= nil and fb ~= nil and fa:lower() == fb:lower()
end

-- Finds the entry in a set-like table (key -> truthy) that matches the given key.
function Identity.FindMatch(set, key)
  if type(set) ~= "table" or type(key) ~= "string" then return nil end
  if set[key] then return key end
  for candidate, enabled in pairs(set) do
    if enabled and Identity.Matches(candidate, key) then return candidate end
  end
  return nil
end

-- Display form of a key (currently identical; kept for when realms matter).
function Identity.Pretty(key)
  return key
end
