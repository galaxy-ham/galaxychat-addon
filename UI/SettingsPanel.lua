-- GalaxyChat/UI/SettingsPanel.lua
-- Registers GalaxyChat in the retail Game Menu → Settings screen.
-- Uses the Settings API (introduced in Dragonflight, stable in TWW 12.x).

GalaxyChat = GalaxyChat or {}
GalaxyChat.Settings = {}
local Settings = GalaxyChat.Settings

local category   -- Settings category handle
local layout     -- Settings layout handle

-- ---------------------------------------------------------------------------
-- Helpers: create setting variable wrappers the Settings API expects
-- ---------------------------------------------------------------------------

-- Creates a CBooleanSettingInitializer-compatible proxy for a boolean setting.
local function MakeBoolProxy(getPath, setPath)
    -- getPath / setPath are sequences of keys into GalaxyChatDB.settings
    local function getter()
        return GalaxyChat.GetSetting(unpack(getPath)) == true
    end
    local function setter(val)
        GalaxyChat.SetSetting(val, unpack(setPath))
    end
    return getter, setter
end

-- ---------------------------------------------------------------------------
-- Widget builders (all parented to the scrollable content frame the
-- Settings API provides via layout:AddInitializer)
-- ---------------------------------------------------------------------------

local PADDING   = 16
local ROW_H     = 26
local INDENT    = 20
local SECTION_H = 36

-- Utility: add a section header label
local function AddSectionHeader(parent, text, yOffset)
    local header = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    header:SetPoint("TOPLEFT", PADDING, yOffset)
    header:SetText("|cff88aaff" .. text)
    return header, yOffset - SECTION_H
end

-- Utility: add a checkbox row, return the checkbox and next yOffset.
-- InterfaceOptionsCheckButtonTemplate was removed in Dragonflight.
-- We build a plain CheckButton + label manually, which works in all retail versions.
local function AddCheckbox(parent, labelText, tooltip, getter, setter, yOffset)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb:SetPoint("TOPLEFT", PADDING + INDENT, yOffset)
    cb:SetChecked(getter() == true)

    local lbl = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    lbl:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    lbl:SetText(labelText)

    if tooltip then
        cb:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(tooltip, nil, nil, nil, nil, true)
            GameTooltip:Show()
        end)
        cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    cb:SetScript("OnClick", function(self)
        -- GetChecked() returns 1 or nil in WoW Lua; normalise to true/false
        setter(self:GetChecked() == 1 or self:GetChecked() == true)
    end)

    return cb, yOffset - ROW_H
end

-- Utility: add a label + single-line EditBox row
local function AddEditBox(parent, labelText, getter, setter, yOffset, width)
    width = width or 260

    local lbl = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    lbl:SetPoint("TOPLEFT", PADDING + INDENT, yOffset)
    lbl:SetText(labelText)

    local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    eb:SetSize(width, 24)
    eb:SetPoint("TOPLEFT", lbl, "BOTTOMLEFT", 0, -4)
    eb:SetText(getter() or "")
    eb:SetAutoFocus(false)
    -- Only save on explicit action; OnEditFocusLost can fire during init otherwise
    local dirty = false
    eb:SetScript("OnEditFocusGained", function(self) dirty = true end)
    eb:SetScript("OnEnterPressed",    function(self) self:ClearFocus(); setter(self:GetText()) end)
    eb:SetScript("OnEditFocusLost",   function(self) if dirty then setter(self:GetText()); dirty = false end end)

    return eb, yOffset - ROW_H - 32
end

-- Utility: add a label + dropdown + numeric override row for sounds
local function AddSoundSelector(parent, yOffset)
    local lbl = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    lbl:SetPoint("TOPLEFT", PADDING + INDENT, yOffset)
    lbl:SetText("Alert Sound:")

    -- --- Sound preset dropdown ---
    local dropdown = CreateFrame("Frame", "GalaxyChatSoundDropdown", parent, "UIDropDownMenuTemplate")
    dropdown:SetPoint("TOPLEFT", lbl, "BOTTOMLEFT", -14, -2)
    UIDropDownMenu_SetWidth(dropdown, 180)

    local function GetCurrentPresetLabel()
        local currentId = GalaxyChat.GetSetting("nameAlert", "soundId") or 3081
        for _, preset in ipairs(GalaxyChat.SoundPresets) do
            if preset.id == currentId then return preset.label end
        end
        return "Custom"
    end

    UIDropDownMenu_SetText(dropdown, GetCurrentPresetLabel())

    UIDropDownMenu_Initialize(dropdown, function(self, level, menuList)
        for _, preset in ipairs(GalaxyChat.SoundPresets) do
            local info = UIDropDownMenu_CreateInfo()
            info.text      = preset.label
            info.value     = preset.id
            info.checked   = (GalaxyChat.GetSetting("nameAlert", "soundId") == preset.id)
            info.func      = function(btn)
                GalaxyChat.SetSetting(preset.id, "nameAlert", "soundId")
                UIDropDownMenu_SetText(dropdown, preset.label)
                if GalaxyChatSoundIdBox then
                    GalaxyChatSoundIdBox:SetText(tostring(preset.id))
                    GalaxyChatSoundIdBox:SetEnabled(false)
                    GalaxyChatSoundIdBox:SetAlpha(0.4)
                end
                if GalaxyChat.NameAlert then GalaxyChat.NameAlert.Refresh() end
            end
            UIDropDownMenu_AddButton(info)
        end

        -- Explicit "Custom" entry — enables the ID box for manual entry
        local customInfo  = UIDropDownMenu_CreateInfo()
        customInfo.text   = "Custom"
        customInfo.value  = -1
        customInfo.checked = (GetCurrentPresetLabel() == "Custom")
        customInfo.func   = function(btn)
            UIDropDownMenu_SetText(dropdown, "Custom")
            if GalaxyChatSoundIdBox then
                GalaxyChatSoundIdBox:SetEnabled(true)
                GalaxyChatSoundIdBox:SetAlpha(1.0)
                GalaxyChatSoundIdBox:SetFocus()
            end
        end
        UIDropDownMenu_AddButton(customInfo)
    end)

    -- --- Manual ID box ---
    local idLbl = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    idLbl:SetPoint("LEFT", dropdown, "RIGHT", 8, 0)
    idLbl:SetText("or ID:")

    local idBox = CreateFrame("EditBox", "GalaxyChatSoundIdBox", parent, "InputBoxTemplate")
    idBox:SetSize(70, 24)
    idBox:SetPoint("LEFT", idLbl, "RIGHT", 4, 0)
    idBox:SetNumeric(true)
    idBox:SetText(tostring(GalaxyChat.GetSetting("nameAlert", "soundId") or 3081))
    idBox:SetAutoFocus(false)
    -- Grey out if a named preset is active; enable only when Custom is selected
    local isCustom = (GetCurrentPresetLabel() == "Custom")
    idBox:SetEnabled(isCustom)
    idBox:SetAlpha(isCustom and 1.0 or 0.4)

    local function ApplyCustomId()
        local val = tonumber(idBox:GetText())
        if val and val > 0 then
            GalaxyChat.SetSetting(val, "nameAlert", "soundId")
            UIDropDownMenu_SetText(dropdown, "Custom")
            if GalaxyChat.NameAlert then GalaxyChat.NameAlert.Refresh() end
        end
    end

    idBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); ApplyCustomId() end)
    idBox:SetScript("OnEditFocusLost", ApplyCustomId)

    -- --- Sound channel dropdown ---
    local chanLbl = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    chanLbl:SetPoint("TOPLEFT", lbl, "BOTTOMLEFT", 0, -36)
    chanLbl:SetText("Output Channel:")

    local chanDropdown = CreateFrame("Frame", "GalaxyChatChannelDropdown", parent, "UIDropDownMenuTemplate")
    chanDropdown:SetPoint("TOPLEFT", chanLbl, "BOTTOMLEFT", -14, -2)
    UIDropDownMenu_SetWidth(chanDropdown, 130)
    UIDropDownMenu_SetText(chanDropdown, GalaxyChat.GetSetting("nameAlert", "soundChannel") or "Master")

    UIDropDownMenu_Initialize(chanDropdown, function(self, level, menuList)
        for _, channel in ipairs(GalaxyChat.SoundChannels) do
            local info    = UIDropDownMenu_CreateInfo()
            info.text     = channel
            info.value    = channel
            info.checked  = (GalaxyChat.GetSetting("nameAlert", "soundChannel") == channel)
            info.func     = function(btn)
                GalaxyChat.SetSetting(channel, "nameAlert", "soundChannel")
                UIDropDownMenu_SetText(chanDropdown, channel)
                if GalaxyChat.NameAlert then GalaxyChat.NameAlert.Refresh() end
            end
            UIDropDownMenu_AddButton(info)
        end
    end)

    -- --- Test button — sits below both dropdowns ---
    local testBtn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    testBtn:SetSize(110, 24)
    testBtn:SetPoint("TOPLEFT", dropdown, "BOTTOMLEFT", 14, -40)
    testBtn:SetText("▶  Test Sound")
    testBtn:SetScript("OnClick", function()
        if GalaxyChat.NameAlert then GalaxyChat.NameAlert.TestSound() end
    end)

    return yOffset - SECTION_H - 120
end

-- Utility: add a numeric EditBox row (for cache settings)
local function AddNumericBox(parent, labelText, getter, setter, yOffset, width)
    width = width or 80

    local lbl = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    lbl:SetPoint("TOPLEFT", PADDING + INDENT, yOffset)
    lbl:SetText(labelText)

    local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    eb:SetSize(width, 24)
    eb:SetPoint("LEFT", lbl, "RIGHT", 8, 0)
    eb:SetNumeric(true)
    eb:SetText(tostring(getter() or ""))
    eb:SetAutoFocus(false)

    local function Apply()
        local val = tonumber(eb:GetText())
        if val then setter(val) end
    end

    eb:SetScript("OnEnterPressed", function(self) self:ClearFocus(); Apply() end)
    eb:SetScript("OnEditFocusLost", Apply)

    return eb, yOffset - ROW_H
end

-- ---------------------------------------------------------------------------
-- Build the settings content panel
-- Called by the Settings API initializer.
-- ---------------------------------------------------------------------------
local function BuildPanel(container)
    local y = -10   -- running Y offset (negative = downward)

    -- ========================================================
    -- Section 1: Class Colors
    -- ========================================================
    local _, ny = AddSectionHeader(container, "Class Colors", y)
    y = ny

    AddCheckbox(
        container,
        "Enable class color highlighting",
        "Colors player names using their class color in all chat channels.",
        function() return GalaxyChat.GetSetting("classColors", "enabled") end,
        function(v)
            GalaxyChat.SetSetting(v, "classColors", "enabled")
            if v then
                if GalaxyChat.ClassColors then GalaxyChat.ClassColors.Enable() end
            else
                if GalaxyChat.ClassColors then GalaxyChat.ClassColors.Disable() end
            end
        end,
        y
    )
    y = y - ROW_H

    AddCheckbox(
        container,
        "Color author name in chat",
        "Colors the name prefix that appears before each chat message.",
        function() return GalaxyChat.GetSetting("classColors", "colorAuthorName") end,
        function(v) GalaxyChat.SetSetting(v, "classColors", "colorAuthorName") end,
        y
    )
    y = y - ROW_H

    AddCheckbox(
        container,
        "Color names mentioned mid-message",
        "Scans each message body and colors any known player names found within it.",
        function() return GalaxyChat.GetSetting("classColors", "colorMidMessage") end,
        function(v) GalaxyChat.SetSetting(v, "classColors", "colorMidMessage") end,
        y
    )
    y = y - ROW_H - 10

    -- ========================================================
    -- Section 2: Name & Keyword Alerts
    -- ========================================================
    local _, ny2 = AddSectionHeader(container, "Name & Keyword Alerts", y)
    y = ny2

    AddCheckbox(
        container,
        "Enable keyword alerts",
        "Plays a sound when your name or a keyword appears in chat.",
        function() return GalaxyChat.GetSetting("nameAlert", "enabled") end,
        function(v)
            GalaxyChat.SetSetting(v, "nameAlert", "enabled")
            if v then
                if GalaxyChat.NameAlert then GalaxyChat.NameAlert.Enable() end
            else
                if GalaxyChat.NameAlert then GalaxyChat.NameAlert.Disable() end
            end
        end,
        y
    )
    y = y - ROW_H

    AddCheckbox(
        container,
        "Always include my character name",
        "Automatically adds your current character's name to the keyword list.",
        function() return GalaxyChat.GetSetting("nameAlert", "includeCharacterName") end,
        function(v)
            GalaxyChat.SetSetting(v, "nameAlert", "includeCharacterName")
            if GalaxyChat.NameAlert then GalaxyChat.NameAlert.Refresh() end
        end,
        y
    )
    y = y - ROW_H

    AddCheckbox(
        container,
        "Alert on whispers",
        "Also triggers the alert sound when a whisper arrives (even without a keyword match).",
        function() return GalaxyChat.GetSetting("nameAlert", "alertOnWhisper") end,
        function(v) GalaxyChat.SetSetting(v, "nameAlert", "alertOnWhisper") end,
        y
    )
    y = y - ROW_H

    -- Keywords input
    local _, ny3 = AddEditBox(
        container,
        "Keywords (comma-separated):",
        function() return GalaxyChat.GetSetting("nameAlert", "keywords") end,
        function(v)
            GalaxyChat.SetSetting(v, "nameAlert", "keywords")
            if GalaxyChat.NameAlert then GalaxyChat.NameAlert.Refresh() end
        end,
        y, 340
    )
    y = ny3

    -- Sound selector
    y = AddSoundSelector(container, y)

    y = y - 10

    -- ========================================================
    -- Section 3: URL Handler
    -- ========================================================
    local _, ny4 = AddSectionHeader(container, "URL Handler", y)
    y = ny4

    AddCheckbox(
        container,
        "Enable URL detection",
        "Makes URLs in chat clickable. A popup appears so you can copy the link.",
        function() return GalaxyChat.GetSetting("urlHandler", "enabled") end,
        function(v)
            GalaxyChat.SetSetting(v, "urlHandler", "enabled")
            if v then
                if GalaxyChat.URLHandler then GalaxyChat.URLHandler.Enable() end
            else
                if GalaxyChat.URLHandler then GalaxyChat.URLHandler.Disable() end
            end
        end,
        y
    )
    y = y - ROW_H - 10

    -- ========================================================
    -- Section 4: Cache Settings
    -- ========================================================
    local _, ny5 = AddSectionHeader(container, "Player Cache", y)
    y = ny5

    AddNumericBox(
        container,
        "Max cached entries:",
        function() return GalaxyChat.GetSetting("cache", "maxEntries") end,
        function(v) GalaxyChat.SetSetting(v, "cache", "maxEntries") end,
        y
    )
    y = y - ROW_H

    AddNumericBox(
        container,
        "Max entry age (days):",
        function() return GalaxyChat.GetSetting("cache", "maxAgeDays") end,
        function(v) GalaxyChat.SetSetting(v, "cache", "maxAgeDays") end,
        y
    )
    y = y - ROW_H + 4

    -- Clear cache button
    local clearBtn = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
    clearBtn:SetSize(140, 26)
    clearBtn:SetPoint("TOPLEFT", PADDING + INDENT, y)
    clearBtn:SetText("Clear Cache Now")
    clearBtn:SetScript("OnClick", function()
        StaticPopupDialogs["GALAXYCHAT_CLEAR_CACHE"] = {
            text      = "Clear the entire GalaxyChat player name cache?\nThis cannot be undone.",
            button1   = "Clear",
            button2   = "Cancel",
            OnAccept  = function() GalaxyChat.Cache.Clear() end,
            timeout   = 0,
            whileDead = true,
        }
        StaticPopup_Show("GALAXYCHAT_CLEAR_CACHE")
    end)

    y = y - ROW_H - 10

    -- Expand container to fit content
    container:SetHeight(math.abs(y) + 20)
end

-- ---------------------------------------------------------------------------
-- Register with the retail Settings API (TWW 12.x compatible)
-- Settings.CreateCustomLayout does not exist; we build a manual canvas frame
-- and hand it to Settings.RegisterCanvasLayoutCategory.
-- ---------------------------------------------------------------------------
function Settings.Init()
    -- Canvas frame: this is what the Settings panel will display.
    -- It must be parented to UIParent and hidden by default.
    local canvas = CreateFrame("Frame", "GalaxyChatSettingsCanvas", UIParent)
    canvas:SetSize(780, 600)
    canvas:Hide()

    -- Scrollable inner content frame
    local scrollFrame = CreateFrame("ScrollFrame", nil, canvas, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT",     canvas, "TOPLEFT",  0,   0)
    scrollFrame:SetPoint("BOTTOMRIGHT", canvas, "BOTTOMRIGHT", -30, 0)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(750, 800)   -- tall enough for all content; BuildPanel adjusts height
    scrollFrame:SetScrollChild(content)

    -- Build our widgets into the content frame
    BuildPanel(content)

    -- Register with the Settings API using the canvas layout path
    category = _G.Settings.RegisterCanvasLayoutCategory(canvas, "GalaxyChat")
    _G.Settings.RegisterAddOnCategory(category)
end

function Settings.OpenPanel()
    if category then
        _G.Settings.OpenToCategory(category:GetID())
    end
end
