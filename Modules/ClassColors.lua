-- GalaxyChat/Modules/ClassColors.lua
-- Highlights player names in chat using their class color.
--
-- APPROACH:
--   We use a single ChatFrame_AddMessageEventFilter for all coloring.
--   The filter receives the pre-format args (message, author, ...).
--   Author arg is always a plain "Name" or "Name-Realm" string — clean.
--   We do NOT return a modified author (that corrupts WoW's hyperlink assembly).
--
--   Instead, for author coloring we inject a color code into the message body
--   by hooking ChatFrame_MessageEventHandler, which receives the FULLY assembled
--   chat line string just before AddMessage is called, letting us recolor the
--   [DisplayName] portion inside the |Hplayer:...|h[Name]|h link safely.
--
--   Mid-message name coloring is done in a normal AddMessageEventFilter on the
--   message arg only.

GalaxyChat = GalaxyChat or {}
GalaxyChat.ClassColors = {}
local ClassColors = GalaxyChat.ClassColors

local midFilterRegistered  = false
local lineHookRegistered   = false

-- ---------------------------------------------------------------------------
-- Color helpers
-- ---------------------------------------------------------------------------

function ClassColors.GetColorCode(classToken)
    if not classToken then return nil end
    local color = RAID_CLASS_COLORS[classToken]
    if not color then return nil end
    return string.format("|cff%02x%02x%02x",
        math.floor(color.r * 255),
        math.floor(color.g * 255),
        math.floor(color.b * 255))
end

function ClassColors.ColorName(name, classToken)
    local code = ClassColors.GetColorCode(classToken)
    if code then return code .. name .. "|r" end
    return name
end

-- ---------------------------------------------------------------------------
-- Resolve name → classToken via cache; queue async lookup on miss.
-- ---------------------------------------------------------------------------
local function ResolveClass(name, realm)
    local key   = GalaxyChat.Cache.Key(name, realm)
    local entry = GalaxyChat.Cache.Get(key)
    if entry then return entry.classToken end
    GalaxyChat.Cache.QueueLookup(name, realm)
    return nil
end

-- ---------------------------------------------------------------------------
-- Recolor |Hplayer:...|h[DisplayName]|h links in a fully assembled chat line.
-- Called from the ChatFrame_MessageEventHandler hook.
-- Only rewrites the [DisplayName] bracket; leaves link data intact.
-- ---------------------------------------------------------------------------
local function RecolorPlayerLinks(line)
    if not line or not line:find("|Hplayer:", 1, true) then return line end

    return (line:gsub("(|Hplayer:([^|]+)|h%[([^%]]+)%]|h)", function(full, linkdata, display)
        -- Skip links whose display text already contains color codes —
        -- they have been processed in a previous pass (e.g. guild login notices).
        if display:find("|c", 1, true) then return full end

        -- linkdata = "Name-Realm:instanceID:SUBGROUP:..." — Name-Realm is before first ":"
        local nameRealm = linkdata:match("^([^:]+)")
        if not nameRealm then return full end

        local name, realm = strsplit("-", nameRealm, 2)
        if realm and realm:match("^%d+$") then realm = nil end
        if not name or name == "" then return full end

        local classToken = ResolveClass(name, realm)
        if not classToken then return full end  -- cache miss, leave as-is

        local colored = ClassColors.ColorName(display, classToken)
        return "|Hplayer:" .. linkdata .. "|h[" .. colored .. "]|h"
    end))
end

-- ---------------------------------------------------------------------------
-- Hook ChatFrame_MessageEventHandler.
-- This function is called by WoW's chat system with the fully assembled line
-- string just before it is handed to ChatFrame:AddMessage. Modifying it here
-- means AddMessage is only ever called once, with the already-recolored text.
-- Signature: ChatFrame_MessageEventHandler(frame, event, ...)
-- We hook it; our hook fires after the original, so the line has been built.
-- BUT: this hook fires after AddMessage has already been called internally.
--
-- Better surface: use the "lineID" event filter pattern via
-- hooksecurefunc("FCF_MessageEventHandler", fn) if available, otherwise fall
-- back to hooking each frame's AddMessage with a pre-call text swap via
-- a metatable __newindex trick — but the cleanest retail solution is:
--
-- Use ChatFrame_AddMessageEventFilter and reconstruct the author display
-- by finding the author name in the message text directly.
--
-- FINAL APPROACH: filter only. We receive (message, author) where author is
-- "Name-Realm". We color the author name wherever it appears in the already
-- chat-formatted message arg that WoW passes us. WoW includes the author
-- display name in the message string it passes to filters in some events.
-- For events where it does not, we prepend nothing and rely on mid-msg scan.
--
-- Actually the cleanest, most reliable, non-doubling approach in retail is:
-- Override the chatframe's AddMessage via its Lua object before WoW hooks it,
-- using a pre-hook (not hooksecurefunc). We do this via rawset on the frame.
-- ---------------------------------------------------------------------------

local hookedFrames = {}

local function PreHookAddMessage(frame)
    if hookedFrames[frame] then return end
    hookedFrames[frame] = true

    local orig = frame.AddMessage
    -- Replace with a wrapper that rewrites the text before passing to original.
    -- This is NOT hooksecurefunc — it's a direct Lua function replacement,
    -- which means we control what gets called and there is no double-fire.
    frame.AddMessage = function(self, text, r, g, b, id)
        if GalaxyChat.GetSetting("classColors", "enabled")
        and GalaxyChat.GetSetting("classColors", "colorAuthorName")
        and text and text:find("|Hplayer:", 1, true) then
            text = RecolorPlayerLinks(text)
        end
        return orig(self, text, r, g, b, id)
    end
end

local function HookAllChatFrames()
    if lineHookRegistered then return end
    for i = 1, NUM_CHAT_WINDOWS or 10 do
        local frame = _G["ChatFrame" .. i]
        if frame and frame.AddMessage then
            PreHookAddMessage(frame)
        end
    end
    lineHookRegistered = true
end

-- ---------------------------------------------------------------------------
-- Mid-message filter — colors cached player names found in the message body.
-- Never modifies the author arg.
-- ---------------------------------------------------------------------------
local function ColorNamesInMessage(message)
    local db = GalaxyChatDB
    if not db or not db.playerCache then return message end

    local minLen = GalaxyChat.MIN_NAME_LENGTH or 2

    for keyNameRealm, entry in pairs(db.playerCache) do
        local name = strsplit("-", keyNameRealm, 2)
        if #name >= minLen and entry.classToken then
            local colored = ClassColors.ColorName(name, entry.classToken)
            local escaped = name:gsub("([%(%)%.%%%+%-%*%?%[%^%$])", "%%%1")
            message = message:gsub(
                "()(" .. escaped .. ")()",
                function(pre_pos, match, post_pos)
                    local pre_char  = message:sub(pre_pos - 1, pre_pos - 1)
                    local post_char = message:sub(post_pos, post_pos)
                    if (pre_char  == "" or not pre_char:match("%a"))
                    and (post_char == "" or not post_char:match("%a")) then
                        return colored
                    end
                    return match
                end
            )
        end
    end

    return message
end

local function MidMessageFilter(chatFrame, event, message, author, language, channelString,
                                 target, flags, unknown, channelNumber, channelName,
                                 unknown2, guid, bnSenderID, isMobile, isSubMerged)

    if not GalaxyChat.GetSetting("classColors", "enabled") then return false end
    if not GalaxyChat.GetSetting("classColors", "colorMidMessage") then return false end
    if not message or message == "" then return false end

    local colored = ColorNamesInMessage(message)
    if colored == message then return false end

    return false, colored, author, language, channelString,
           target, flags, unknown, channelNumber, channelName,
           unknown2, guid, bnSenderID, isMobile, isSubMerged
end

-- ---------------------------------------------------------------------------
-- Enable / Disable
-- ---------------------------------------------------------------------------
function ClassColors.Enable()
    HookAllChatFrames()  -- pre-hook AddMessage on all frames (idempotent)

    if not midFilterRegistered then
        for _, event in ipairs(GalaxyChat.ChatEvents) do
            ChatFrame_AddMessageEventFilter(event, MidMessageFilter)
        end
        midFilterRegistered = true
    end
end

function ClassColors.Disable()
    -- Frame pre-hooks cannot be removed without storing originals, but the
    -- enabled-flag check at the top of the wrapper makes them no-ops when off.
    if midFilterRegistered then
        for _, event in ipairs(GalaxyChat.ChatEvents) do
            ChatFrame_RemoveMessageEventFilter(event, MidMessageFilter)
        end
        midFilterRegistered = false
    end
end

-- ---------------------------------------------------------------------------
-- Init
-- ---------------------------------------------------------------------------
function ClassColors.Init()
    if GalaxyChat.GetSetting("classColors", "enabled") then
        ClassColors.Enable()
    end
end
