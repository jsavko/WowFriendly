-- WowFriendly: export / import window for sharing ratings as a text string.
local _, ns = ...
ns.UI = ns.UI or {}

local Export = {}
ns.UI.Export = Export

local frame, scroll, edit, hint, importButton, mode, exportedText, settingText

local function SetEditWidth()
  if edit and scroll then
    local w = scroll:GetWidth()
    if w and w > 0 then edit:SetWidth(w - 8) end
  end
end

local function Build()
  frame = CreateFrame("Frame", "WowFriendlyExportFrame", UIParent, "BasicFrameTemplateWithInset")
  frame:SetSize(520, 360)
  frame:SetPoint("CENTER")
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:SetClampedToScreen(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  frame:SetFrameStrata("DIALOG")
  frame:Hide()
  if UISpecialFrames then table.insert(UISpecialFrames, frame:GetName()) end

  hint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  hint:SetPoint("TOPLEFT", 14, -30)
  hint:SetPoint("TOPRIGHT", -14, -30)
  hint:SetJustifyH("LEFT")
  hint:SetHeight(28)

  scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 14, -62)
  scroll:SetPoint("BOTTOMRIGHT", -32, 44)
  scroll:SetScript("OnSizeChanged", SetEditWidth)

  edit = CreateFrame("EditBox", nil, scroll)
  edit:SetMultiLine(true)
  edit:SetAutoFocus(false)
  edit:SetMaxLetters(0)
  edit:SetFontObject(ChatFontNormal or GameFontHighlightSmall)
  edit:SetWidth(460)
  edit:SetHeight(240)
  edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  edit:SetScript("OnTextChanged", function(self, userInput)
    if mode == "export" and userInput and not settingText and self:GetText() ~= exportedText then
      -- Read-only: put the exported string back if the user edits it.
      settingText = true
      self:SetText(exportedText or "")
      self:HighlightText()
      settingText = nil
    end
  end)
  scroll:SetScrollChild(edit)

  importButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  importButton:SetSize(110, 24)
  importButton:SetPoint("BOTTOMRIGHT", -14, 12)
  importButton:SetText("Import")
  importButton:SetScript("OnClick", function() Export.DoImport(edit:GetText()) end)

  local closeButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  closeButton:SetSize(90, 24)
  closeButton:SetPoint("BOTTOMLEFT", 14, 12)
  closeButton:SetText(CLOSE or "Close")
  closeButton:SetScript("OnClick", function() frame:Hide() end)
end

local function SetTitle(text)
  if frame.TitleText then
    frame.TitleText:SetText(text)
  elseif frame.title then
    frame.title:SetText(text)
  end
end

function Export.Show(which)
  if not ns.db then return end
  if not frame then Build() end
  mode = which == "import" and "import" or "export"
  frame:Show()
  SetEditWidth()
  if mode == "export" then
    local entries, players = ns.Ratings.Count(ns.db)
    local text = ns.Comms.EncodeForPrint(ns.Ratings.ToTable(ns.db))
    exportedText = text or ""
    SetTitle("WowFriendly export")
    hint:SetText(string.format("%d ratings on %d players. Press Ctrl+C to copy, then paste the string to a friend. They import it with /wf import.", entries, players))
    importButton:Hide()
    settingText = true
    edit:SetText(exportedText)
    settingText = nil
    edit:SetFocus()
    edit:HighlightText()
  else
    exportedText = nil
    SetTitle("WowFriendly import")
    hint:SetText("Paste a WowFriendly export string below and click Import. Entries merge with your own; nothing of yours is overwritten.")
    importButton:Show()
    settingText = true
    edit:SetText("")
    settingText = nil
    edit:SetFocus()
  end
end

function Export.DoImport(text)
  if not ns.db then return end
  local tbl, err = ns.Comms.DecodeFromPrint(text or "")
  if not tbl then
    ns.Print("Could not read that string (%s).", tostring(err))
    return
  end
  if tbl.v and tbl.v ~= ns.PROTOCOL_VERSION then
    ns.Print("Export was made with protocol %s (ours is %d); importing what is compatible.", tostring(tbl.v), ns.PROTOCOL_VERSION)
  end
  -- Imports are a deliberate action, so entries you authored yourself are allowed back in
  -- (handy after a reinstall); entries about you are still ignored.
  local me = ns.Identity.SelfKey()
  local added, updated, skipped = ns.Ratings.FromTable(ns.db, tbl, ns.Identity.IsValidKey, me)
  ns.Print("Import finished: %d added, %d updated, %d skipped.", added, updated, skipped)
  if added + updated > 0 then ns.Fire("RATING_CHANGED") end
  if frame then frame:Hide() end
end
