-- WowFriendly: unit right-click menu entries and the note popup.
local _, ns = ...

-- Unit popup menus that show a player. Group Finder menus (MENU_LFG_FRAME_*) carry
-- result IDs instead of names and are left for a later version.
local UNIT_MENU_TAGS = {
  "TARGET", "PLAYER", "ENEMY_PLAYER", "PARTY", "RAID_PLAYER", "RAID", "FOCUS",
  "FRIEND", "CHAT_ROSTER", "COMMUNITIES_GUILD_MEMBER", "GUILD",
}

local function IsGamepadUI()
  if not GetCVar then return false end
  local ok, value = pcall(GetCVar, "InputDeviceInterfaceStyle")
  return ok and value == "1"
end

-- Resolves the player the menu is about from its context data.
local function ResolveKey(contextData)
  if ns.IsSecret(contextData) or type(contextData) ~= "table" then return nil end
  local unit = ns.Readable(contextData.unit, "string")
  if unit then
    local key = ns.Identity.KeyForUnit(unit)
    if key then return key end
  end
  local name = ns.Readable(contextData.name, "string")
  if name then
    local server = ns.Readable(contextData.server, "string")
    return ns.Identity.KeyFromParts(name, server)
  end
  return nil
end

local function BuildMenu(rootDescription, key)
  local me = ns.Identity.SelfKey()
  local mine = me and ns.Ratings.GetByAuthor(ns.db, key, me)
  local hasMine = mine and mine.r ~= 0

  rootDescription:CreateDivider()
  local sub = rootDescription:CreateButton("WowFriendly")
  if sub.CreateTitle then sub:CreateTitle(key) end
  sub:CreateButton(ns.SMILE_ICON .. " Smile", function() ns.Rate(key, 1) end)
  sub:CreateButton(ns.FROWN_ICON .. " Frown", function() ns.Rate(key, -1) end)
  if hasMine then
    sub:CreateButton("Set note...", function() ns.PromptNote(key) end)
    sub:CreateButton("Clear my rating", function() ns.Rate(key, 0) end)
  end
  if ns.Ratings.Aggregate(ns.db, key) then
    sub:CreateButton("Show ratings in chat", function() ns.Who(key) end)
  end
end

local function OnUnitMenu(_, rootDescription, contextData)
  if IsGamepadUI() then return end
  if not ns.db then return end
  if ns.IsSecret(rootDescription) or type(rootDescription) ~= "table" or not rootDescription.CreateButton then return end
  local key = ResolveKey(contextData)
  if not key then return end
  local me = ns.Identity.SelfKey()
  if me and ns.Identity.Matches(key, me) then return end
  BuildMenu(rootDescription, key)
end

ns.OnInit(function()
  -- Forever's Gamepad UI menus are protected; leave them untouched (checked again per open).
  if not (Menu and Menu.ModifyMenu) then
    ns.Debug("menu: Menu.ModifyMenu not available; right-click entries disabled")
    return
  end
  if IsGamepadUI() then
    ns.Debug("menu: Gamepad UI active; right-click entries disabled")
    return
  end
  for _, tag in ipairs(UNIT_MENU_TAGS) do
    local ok, err = pcall(Menu.ModifyMenu, "MENU_UNIT_" .. tag, OnUnitMenu)
    if not ok then ns.Debug("menu: could not modify MENU_UNIT_%s: %s", tag, tostring(err)) end
  end
end)

---------------------------------------------------------------------------
-- Note popup
---------------------------------------------------------------------------

local function GetEditBox(dialog)
  if not dialog then return nil end
  local eb = dialog.editBox or dialog.EditBox
  if not eb and dialog.GetName then
    local name = dialog:GetName()
    if name then eb = _G[name .. "EditBox"] end
  end
  return eb
end

local function SaveFromDialog(dialog)
  local eb = GetEditBox(dialog)
  local data = dialog and dialog.data
  if eb and type(data) == "table" and data.key then
    ns.SetNote(data.key, eb:GetText())
  end
end

StaticPopupDialogs["WOWFRIENDLY_NOTE"] = {
  text = "WowFriendly note for %s",
  button1 = SAVE or "Save",
  button2 = CANCEL or "Cancel",
  hasEditBox = true,
  maxLetters = 100,
  editBoxWidth = 320,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
  OnShow = function(self, data)
    local eb = GetEditBox(self)
    if eb then
      eb:SetText(type(data) == "table" and data.note or "")
      eb:HighlightText()
      eb:SetFocus()
    end
  end,
  OnAccept = function(self)
    SaveFromDialog(self)
  end,
  EditBoxOnEnterPressed = function(self)
    local dialog = self:GetParent()
    SaveFromDialog(dialog)
    dialog:Hide()
  end,
  EditBoxOnEscapePressed = function(self)
    self:GetParent():Hide()
  end,
}

function ns.PromptNote(key)
  if not ns.db or not StaticPopup_Show then return end
  local me = ns.Identity.SelfKey()
  local mine = me and ns.Ratings.GetByAuthor(ns.db, key, me)
  if not mine or mine.r == 0 then
    ns.Print("Rate %s first (Smile or Frown), then add a note.", key)
    return
  end
  StaticPopup_Show("WOWFRIENDLY_NOTE", key, nil, { key = key, note = mine.n or "" })
end

ns.Menu = { ResolveKey = ResolveKey, IsGamepadUI = IsGamepadUI }
