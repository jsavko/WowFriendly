-- WowFriendly: unit tooltip lines.
local _, ns = ...

local MAX_AUTHOR_LINES = 5

local function AddLines(tooltip, key)
  local settings = ns.db.settings
  local agg = ns.Ratings.Aggregate(ns.db, key)
  if not agg then return end

  local summary = {}
  if agg.happy > 0 then summary[#summary + 1] = ns.SMILE_ICON .. " " .. agg.happy end
  if agg.sad > 0 then summary[#summary + 1] = ns.FROWN_ICON .. " " .. agg.sad end
  tooltip:AddLine("WowFriendly  " .. table.concat(summary, "   "), 0.37, 0.83, 1)

  if settings.showAuthors then
    for i, e in ipairs(agg.entries) do
      if i > MAX_AUTHOR_LINES then
        tooltip:AddLine(string.format("   ... and %d more", #agg.entries - MAX_AUTHOR_LINES), 0.6, 0.6, 0.6)
        break
      end
      local text = ns.IconFor(e.r) .. " " .. e.author
      if settings.showNotes and e.n then
        text = text .. ": \"" .. e.n .. "\""
      end
      tooltip:AddLine(text, 0.9, 0.9, 0.9, true)
    end
  elseif settings.showNotes and agg.newest and agg.newest.n then
    tooltip:AddLine("\"" .. agg.newest.n .. "\"", 0.9, 0.9, 0.9, true)
  end

  if tooltip.Show then tooltip:Show() end
end

-- Finds the unit token the tooltip is showing, guarding every value against secrets.
local function ResolveUnit(tooltip, data)
  local unit
  if tooltip and tooltip.GetUnit then
    local ok, _, token = pcall(tooltip.GetUnit, tooltip)
    if ok then unit = ns.Readable(token, "string") end
  end
  if not unit and data and not ns.IsSecret(data) and type(data) == "table" then
    local guid = ns.Readable(data.guid, "string")
    if guid and UnitTokenFromGUID then
      unit = ns.SafeCall("string", UnitTokenFromGUID, guid)
    end
  end
  return unit
end

local function OnUnitTooltip(tooltip, data)
  if not ns.db or not ns.db.settings.showOnTooltip then return end
  if ns.IsSecret(tooltip) or type(tooltip) ~= "table" or not tooltip.AddLine then return end
  local unit = ResolveUnit(tooltip, data)
  if not unit then return end
  local key = ns.Identity.KeyForUnit(unit)
  if not key then return end
  local me = ns.Identity.SelfKey()
  if me and ns.Identity.Matches(key, me) then return end
  AddLines(tooltip, key)
end

ns.OnInit(function()
  if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall
    and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Unit then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, OnUnitTooltip)
    ns.Debug("tooltip: using TooltipDataProcessor")
  elseif GameTooltip and GameTooltip.HookScript then
    GameTooltip:HookScript("OnTooltipSetUnit", function(tt) OnUnitTooltip(tt, nil) end)
    ns.Debug("tooltip: using OnTooltipSetUnit hook")
  end
end)

ns.Tooltip = { AddLines = AddLines, OnUnitTooltip = OnUnitTooltip }
