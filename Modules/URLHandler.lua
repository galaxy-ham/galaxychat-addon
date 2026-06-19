-- GalaxyChat/Modules/URLHandler.lua
-- Detects URLs in chat messages, wraps them as clickable hyperlinks,
-- and shows a minimal popup with auto-select text for easy copying.

GalaxyChat = GalaxyChat or {}
GalaxyChat.URLHandler = {}
local URLHandler = GalaxyChat.URLHandler

local filterRegistered   = false
local hookRegistered     = false

-- ---------------------------------------------------------------------------
-- URL detection
-- Returns a message with all found URLs replaced by |Hurl:…|h[…]|h links.
-- Also returns a boolean indicating whether any URL was found.
-- ---------------------------------------------------------------------------

-- Escape a URL for safe embedding in the |H link data field.
-- We replace spaces (none expected) and pipe chars which would break the format.
local function SafeEncodeURL(url)
    return url:gsub("|", "%%7C")
end

local function SafeDecodeURL(url)
    return url:gsub("%%7C", "|")
end

local function WrapURL(url)
    local encoded = SafeEncodeURL(url)
    -- Truncate display text if very long
    local display = #url > 60 and (url:sub(1, 57) .. "...") or url
    return "|Hurl:" .. encoded .. "|h|cff88ddff[" .. display .. "]|r|h"
end

function URLHandler.FindAndWrapURLs(message)
    if not message then return message, false end

    local found = false

    -- We process the message token by token (split on spaces) to avoid
    -- pattern interactions and to keep non-URL text intact.
    local parts = {}
    for token in (message .. " "):gmatch("([^ ]*) ") do
        local matched = false
        for _, pattern in ipairs(GalaxyChat.URLPatterns) do
            local s, e = token:find("^" .. pattern .. "$")
            if s then
                table.insert(parts, WrapURL(token))
                matched = true
                found   = true
                break
            end
        end
        if not matched then
            table.insert(parts, token)
        end
    end

    return table.concat(parts, " "), found
end

-- ---------------------------------------------------------------------------
-- Chat filter
-- ---------------------------------------------------------------------------
local function ChatFilter(chatFrame, event, message, author, language, channelString,
                           target, flags, unknown, channelNumber, channelName,
                           unknown2, guid, bnSenderID, isMobile, isSubMerged)

    if not GalaxyChat.GetSetting("urlHandler", "enabled") then
        return false
    end

    local newMessage, changed = URLHandler.FindAndWrapURLs(message)
    if changed then
        return false, newMessage, author, language, channelString,
               target, flags, unknown, channelNumber, channelName,
               unknown2, guid, bnSenderID, isMobile, isSubMerged
    end

    return false
end

-- ---------------------------------------------------------------------------
-- Popup frame
-- ---------------------------------------------------------------------------
local popup  -- created lazily

local function CreatePopup()
    local f = CreateFrame("Frame", "GalaxyChatURLPopup", UIParent, "BackdropTemplate")
    f:SetSize(460, 90)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop",  f.StopMovingOrSizing)
    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile     = true, tileSize = 32, edgeSize = 32,
        insets   = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    f:SetBackdropColor(0, 0, 0, 0.9)

    -- Title
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -14)
    title:SetText("|cff88aaff[GalaxyChat]|r  Copy URL")

    -- EditBox
    local eb = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    eb:SetSize(400, 28)
    eb:SetPoint("CENTER", 0, -6)
    eb:SetAutoFocus(false)
    eb:SetMaxLetters(0)
    eb:SetScript("OnEscapePressed", function() f:Hide() end)

    -- Auto-close on any keypress once the box has been focused and user acts
    local hasBeenFocused = false
    eb:SetScript("OnEditFocusGained", function()
        eb:HighlightText()
        hasBeenFocused = true
    end)
    eb:SetScript("OnKeyUp", function(self, key)
        if hasBeenFocused then
            -- Give the copy a moment to register before closing
            C_Timer.After(0.05, function() f:Hide() end)
        end
    end)

    -- Close button
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -6, -6)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    -- Hint text
    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("BOTTOM", 0, 12)
    hint:SetText("Press Ctrl+C to copy, then any key to close.")

    f.editBox       = eb
    f.hasBeenFocused = hasBeenFocused

    f:Hide()
    return f
end

function URLHandler.ShowPopup(url)
    if not popup then
        popup = CreatePopup()
    end

    local decoded = SafeDecodeURL(url)
    popup.editBox:SetText(decoded)
    popup:Show()

    -- Defer focus so the frame is visible first
    C_Timer.After(0.05, function()
        popup.editBox:SetFocus()
        popup.editBox:HighlightText()
    end)
end

-- ---------------------------------------------------------------------------
-- Hyperlink click intercept
-- SetItemRef(link, text, button, chatFrame) is called for all chat link clicks.
-- We intercept links whose type is "url".
-- ---------------------------------------------------------------------------
local function OnSetItemRef(link, text, button, chatFrame)
    if not GalaxyChat.GetSetting("urlHandler", "enabled") then return end

    local linkType, data = link:match("^(%w+):(.+)$")
    if linkType == "url" then
        URLHandler.ShowPopup(data)
    end
end

-- ---------------------------------------------------------------------------
-- Enable / Disable
-- ---------------------------------------------------------------------------
function URLHandler.Enable()
    if not filterRegistered then
        for _, event in ipairs(GalaxyChat.ChatEvents) do
            ChatFrame_AddMessageEventFilter(event, ChatFilter)
        end
        filterRegistered = true
    end

    if not hookRegistered then
        hooksecurefunc("SetItemRef", OnSetItemRef)
        hookRegistered = true   -- hooksecurefunc cannot be un-hooked; guard the call
    end
end

function URLHandler.Disable()
    if filterRegistered then
        for _, event in ipairs(GalaxyChat.ChatEvents) do
            ChatFrame_RemoveMessageEventFilter(event, ChatFilter)
        end
        filterRegistered = false
    end
    -- Note: hooksecurefunc cannot be removed. The handler checks the enabled
    -- setting before acting, so disabling via setting is sufficient.
end

-- ---------------------------------------------------------------------------
-- Init
-- ---------------------------------------------------------------------------
function URLHandler.Init()
    if GalaxyChat.GetSetting("urlHandler", "enabled") then
        URLHandler.Enable()
    end
end
