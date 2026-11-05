-- luacheck configuration for anyone who has luacheck installed (it is not required).
std = "lua51"
max_line_length = false
self = false

exclude_files = { "WowFriendly/Libs/**", ".tools/**" }

-- Addon namespace injected via `local ADDON_NAME, ns = ...`
ignore = {
  "212/self", -- unused self
  "212/_.*", -- unused args starting with _
  "211/_.*", -- unused locals starting with _
}

globals = {
  -- our own globals
  "WowFriendlyDB", "WowFriendly_Bind",
  "BINDING_HEADER_WOWFRIENDLY", "BINDING_NAME_WOWFRIENDLY_SMILE", "BINDING_NAME_WOWFRIENDLY_FROWN",
  "SLASH_WOWFRIENDLY1", "SLASH_WOWFRIENDLY2", "SlashCmdList", "StaticPopupDialogs",
}

read_globals = {
  -- Lua / WoW additions
  "strsplit", "strtrim", "strlower", "strupper", "tinsert", "tremove", "wipe", "format", "date", "time",
  "bit", "issecretvalue", "hooksecurefunc", "securecallfunction",
  -- Libraries
  "LibStub", "ChatThrottleLib",
  -- Frames and UI
  "CreateFrame", "UIParent", "GameTooltip", "GameFontNormal", "GameFontHighlight", "GameFontNormalSmall",
  "GameFontHighlightSmall", "GameFontDisableSmall", "StaticPopup_Show", "StaticPopup_Hide", "PlaySound",
  "SOUNDKIT", "UISpecialFrames", "ChatFrame_OpenChat", "DEFAULT_CHAT_FRAME", "SELECTED_CHAT_FRAME",
  "Menu", "MenuUtil", "TooltipDataProcessor", "Enum", "Settings", "SettingsPanel", "EventRegistry",
  "InterfaceOptionsFrame_OpenToCategory", "C_Timer", "C_AddOns", "C_ChatInfo", "C_BattleNet", "C_GuildInfo",
  "C_EventUtils", "C_RestrictedActions", "GetRestrictedActionStatus", "GetAddOnMetadata",
  -- Units and identity
  "UnitIsPlayer", "UnitExists", "UnitName", "UnitFullName", "UnitGUID", "UnitIsUnit", "UnitTokenFromGUID",
  "UnitRealmRelationship", "UnitIsSameServer", "GetNormalizedRealmName", "GetRealmName", "GetUnitName",
  "Ambiguate", "LE_REALM_RELATION_SAME", "GetServerTime", "GetTime", "GetBuildInfo", "GetCVar",
  "IsInGroup", "IsInRaid", "IsInGuild", "GetNumGroupMembers", "GetNumGuildMembers", "GetGuildRosterInfo",
  "LE_PARTY_CATEGORY_HOME", "LE_PARTY_CATEGORY_INSTANCE", "IsInInstance", "InCombatLockdown",
  "BNGetNumFriends", "BNGetInfo", "BNET_CLIENT_WOW", "WOW_PROJECT_ID", "WOW_PROJECT_CAMELOT",
  "BNSendGameData", "SendAddonMessage", "RegisterAddonMessagePrefix",
  -- Strings
  "OKAY", "CANCEL", "SAVE", "CLOSE", "ACCEPT", "NORMAL_FONT_COLOR", "HIGHLIGHT_FONT_COLOR", "RED_FONT_COLOR",
  "GREEN_FONT_COLOR", "GRAY_FONT_COLOR", "YELLOW_FONT_COLOR",
}
