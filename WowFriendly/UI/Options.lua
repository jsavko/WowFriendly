-- WowFriendly: settings panel (Settings API, 11.0 signature).
local _, ns = ...
ns.UI = ns.UI or {}

local Options = {}
ns.UI.Options = Options

local category

local SECTIONS = {
  {
    header = "Tooltip",
    items = {
      { key = "showOnTooltip", name = "Show ratings on player tooltips", tooltip = "Add WowFriendly lines to the tooltip of rated players." },
      { key = "showAuthors", name = "Show who gave each rating", tooltip = "List each friend's rating on the tooltip, newest first." },
      { key = "showNotes", name = "Show notes", tooltip = "Include notes on the tooltip." },
    },
  },
  {
    header = "Sharing",
    items = {
      { key = "syncBattleNet", name = "Share with Battle.net friends", tooltip = "Exchange ratings with Battle.net friends who run WowFriendly, including the other faction." },
      { key = "syncTrusted", name = "Share with trusted characters", tooltip = "Exchange ratings with characters added via /wf trust." },
      { key = "shareGuild", name = "Share with guild members", tooltip = "Also accept ratings from, and send yours to, anyone in your guild who runs WowFriendly. Off by default because it widens the circle beyond your friends.",
        onChange = function(value) if ns.Comms and ns.Comms.OnGuildSharingChanged then ns.Comms.OnGuildSharingChanged(value) end end },
    },
  },
  {
    header = "Advanced",
    items = {
      { key = "debug", name = "Debug output in chat", tooltip = "Print sync details to the chat frame." },
    },
  },
}

local function AddHeader(text)
  if not (SettingsPanel and SettingsPanel.GetLayout and CreateSettingsListSectionHeaderInitializer) then return end
  pcall(function()
    local layout = SettingsPanel:GetLayout(category)
    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(text))
  end)
end

local function Register()
  if not (Settings and Settings.RegisterVerticalLayoutCategory and Settings.RegisterAddOnSetting
    and Settings.CreateCheckbox and Settings.RegisterAddOnCategory and Settings.VarType) then
    ns.Debug("options: Settings API not available; use /wf commands")
    return
  end
  category = Settings.RegisterVerticalLayoutCategory("WowFriendly")
  for _, section in ipairs(SECTIONS) do
    AddHeader(section.header)
    for _, def in ipairs(section.items) do
      local variable = "WOWFRIENDLY_" .. def.key:upper()
      local setting = Settings.RegisterAddOnSetting(category, variable, def.key, ns.db.settings,
        Settings.VarType.Boolean, def.name, ns.defaults[def.key])
      if def.onChange and setting.SetValueChangedCallback then
        setting:SetValueChangedCallback(function(_, value) def.onChange(value) end)
      end
      Settings.CreateCheckbox(category, setting, def.tooltip)
    end
  end
  Settings.RegisterAddOnCategory(category)
end

function Options.Open()
  if category and Settings and Settings.OpenToCategory then
    local id = category.GetID and category:GetID() or category
    Settings.OpenToCategory(id)
  else
    ns.Print("Settings panel unavailable. Toggle options with /wf commands or edit WowFriendlyDB.settings.")
  end
end

ns.OnInit(function()
  local ok, err = pcall(Register)
  if not ok then ns.Debug("options: %s", tostring(err)) end
end)
