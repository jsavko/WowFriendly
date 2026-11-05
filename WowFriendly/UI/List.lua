-- WowFriendly: window listing every rated player.
local _, ns = ...
ns.UI = ns.UI or {}

local List = {}
ns.UI.List = List

local ROW_HEIGHT = 22
local MAX_AUTHORS = 3

local frame, scroll, content, filterBox, countText
local rows = {}

local function GetRow(i)
  if rows[i] then return rows[i] end
  local row = CreateFrame("Frame", nil, content)
  row:SetHeight(ROW_HEIGHT)
  row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
  row:SetPoint("TOPRIGHT", 0, -(i - 1) * ROW_HEIGHT)

  row.bg = row:CreateTexture(nil, "BACKGROUND")
  row.bg:SetAllPoints()
  row.bg:SetColorTexture(1, 1, 1, i % 2 == 0 and 0.05 or 0)

  row.icons = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  row.icons:SetPoint("LEFT", 4, 0)
  row.icons:SetWidth(62)
  row.icons:SetJustifyH("LEFT")

  row.name = CreateFrame("Button", nil, row)
  row.name:SetPoint("LEFT", 70, 0)
  row.name:SetSize(160, ROW_HEIGHT)
  row.name.text = row.name:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  row.name.text:SetAllPoints()
  row.name.text:SetJustifyH("LEFT")
  row.name:SetScript("OnClick", function() if row.key then ns.Who(row.key) end end)

  row.info = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.info:SetPoint("LEFT", 236, 0)
  row.info:SetPoint("RIGHT", -140, 0)
  row.info:SetJustifyH("LEFT")
  row.info:SetWordWrap(false)

  row.date = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  row.date:SetPoint("RIGHT", -60, 0)
  row.date:SetWidth(76)
  row.date:SetJustifyH("RIGHT")

  row.clear = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
  row.clear:SetSize(52, 18)
  row.clear:SetPoint("RIGHT", -4, 0)
  row.clear:SetText("Clear")
  row.clear:SetScript("OnClick", function() if row.key then ns.Rate(row.key, 0) end end)

  row:SetScript("OnEnter", function(self)
    if not self.key or not GameTooltip then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(self.key)
    ns.Tooltip.AddLines(GameTooltip, self.key)
    GameTooltip:Show()
  end)
  row:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

  rows[i] = row
  return row
end

local function Build()
  frame = CreateFrame("Frame", "WowFriendlyListFrame", UIParent, "BasicFrameTemplateWithInset")
  frame:SetSize(600, 440)
  frame:SetPoint("CENTER")
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:SetClampedToScreen(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  frame:SetFrameStrata("DIALOG")
  frame:Hide()
  if frame.TitleText then frame.TitleText:SetText("WowFriendly - rated players") end
  if UISpecialFrames then table.insert(UISpecialFrames, frame:GetName()) end

  local filterLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  filterLabel:SetPoint("TOPLEFT", 16, -36)
  filterLabel:SetText("Filter")

  filterBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
  filterBox:SetSize(200, 20)
  filterBox:SetPoint("LEFT", filterLabel, "RIGHT", 12, 0)
  filterBox:SetAutoFocus(false)
  filterBox:SetScript("OnTextChanged", function() List.Refresh() end)
  filterBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

  countText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  countText:SetPoint("TOPRIGHT", -16, -40)

  local header = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  header:SetPoint("TOPLEFT", 20, -66)
  header:SetText("Ratings        Player                          Who said what (newest first)                             Last rated")

  scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 12, -82)
  scroll:SetPoint("BOTTOMRIGHT", -32, 44)
  scroll:SetScript("OnSizeChanged", function() List.Refresh() end)

  content = CreateFrame("Frame", nil, scroll)
  content:SetSize(1, 1)
  scroll:SetScrollChild(content)

  local function button(text, anchor, x, onClick)
    local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    b:SetSize(96, 24)
    b:SetPoint(anchor, x, 12)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
  end
  button("Export", "BOTTOMLEFT", 14, function() ns.UI.Export.Show("export") end)
  button("Import", "BOTTOMLEFT", 116, function() ns.UI.Export.Show("import") end)
  button("Sync now", "BOTTOMLEFT", 218, function() if ns.Comms then ns.Comms.SyncNow(true) end ns.Print("Sync requested.") end)
  button("Settings", "BOTTOMRIGHT", -14, function() ns.UI.Options.Open() end)
end

local function matches(key, agg, filter)
  if filter == "" then return true end
  if key:lower():find(filter, 1, true) then return true end
  for _, e in ipairs(agg.entries) do
    if e.author:lower():find(filter, 1, true) then return true end
    if e.n and e.n:lower():find(filter, 1, true) then return true end
  end
  return false
end

function List.Refresh()
  if not frame or not frame:IsShown() or not ns.db then return end
  local filter = (filterBox:GetText() or ""):lower()
  local me = ns.Identity.SelfKey()
  local shown, total = 0, 0
  for _, key in ipairs(ns.Ratings.AllTargets(ns.db)) do
    local agg = ns.Ratings.Aggregate(ns.db, key)
    if agg then
      total = total + 1
      if matches(key, agg, filter) then
        shown = shown + 1
        local row = GetRow(shown)
        row.key = key
        local icons = {}
        if agg.happy > 0 then icons[#icons + 1] = ns.SMILE_ICON .. agg.happy end
        if agg.sad > 0 then icons[#icons + 1] = ns.FROWN_ICON .. agg.sad end
        row.icons:SetText(table.concat(icons, " "))
        row.name.text:SetText(key)
        local authors = {}
        for i, e in ipairs(agg.entries) do
          if i > MAX_AUTHORS then break end
          authors[#authors + 1] = ns.IconFor(e.r) .. e.author
        end
        local info = table.concat(authors, ", ")
        if #agg.entries > MAX_AUTHORS then info = info .. string.format(" +%d", #agg.entries - MAX_AUTHORS) end
        if agg.newest.n then info = info .. "  |cffbbbbbb\"" .. agg.newest.n .. "\"|r" end
        row.info:SetText(info)
        row.date:SetText(date and date("%Y-%m-%d", agg.newest.t) or "")
        local mine = me and ns.Ratings.GetByAuthor(ns.db, key, me)
        if mine and mine.r ~= 0 then row.clear:Show() else row.clear:Hide() end
        row:Show()
      end
    end
  end
  for i = shown + 1, #rows do rows[i]:Hide() end
  local width = scroll:GetWidth()
  content:SetWidth(width and width > 0 and width or 540)
  content:SetHeight(math.max(1, shown * ROW_HEIGHT))
  if shown == total then
    countText:SetText(string.format("%d rated players", total))
  else
    countText:SetText(string.format("%d of %d rated players", shown, total))
  end
end

function List.Show()
  if not ns.db then return end
  if not frame then Build() end
  frame:Show()
  List.Refresh()
end

function List.Hide()
  if frame then frame:Hide() end
end

function List.Toggle()
  if frame and frame:IsShown() then List.Hide() else List.Show() end
end

ns.OnInit(function()
  ns.On("RATING_CHANGED", function() List.Refresh() end)
end)
