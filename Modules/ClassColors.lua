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
        and text then
            -- Strings from secure/combat contexts are marked "secret" and cannot
            -- be indexed by addon code. Use pcall to bail out silently on taint.
            local ok, hasLink = pcall(string.find, text, "|Hplayer:", 1, true)
            if ok and hasLink then
                local ok2, recolored = pcall(RecolorPlayerLinks, text)
                if ok2 and recolored then
                    text = recolored
                end
            end
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
-- Find |H...|h...|h hyperlink spans in a message so mid-message coloring
-- never rewrites text living inside a link's data/display fields.
--
-- WHY (bug fix): link data must never contain "|" characters. If a cached
-- name is a substring of a link's own linkdata/display — which it always is
-- for e.g. a guild "<Name> has come online." CHAT_MSG_SYSTEM line, since
-- that message IS a |Hplayer:Name|h[Name]|h link — a naive whole-message
-- rewrite can inject a "|cffXXXXXX...|r" color code INSIDE the link's data
-- field. That breaks WoW's pipe/escape parsing, so the client falls back to
-- printing the raw "|Hplayer:...|h" text instead of rendering the link.
-- Scanning for existing link spans up front and excluding them from the
-- mid-message color pass fixes this without affecting normal plain-text
-- name coloring.
-- ---------------------------------------------------------------------------
local function FindProtectedRanges(message)
    local ranges = {}
    local searchStart = 1
    while true do
        local s, e = message:find("|H[^|]*|h.-|h", searchStart)
        if not s then break end
        table.insert(ranges, { s, e })
        searchStart = e + 1
    end
    return ranges
end

local function InProtectedRange(pos, ranges)
    for _, r in ipairs(ranges) do
        if pos >= r[1] and pos <= r[2] then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Mid-message filter — colors cached player names found in the message body.
-- Never modifies the author arg. Skips any name occurrence that falls
-- inside an existing hyperlink span (see FindProtectedRanges above).
--
-- PERFORMANCE FIX: this used to loop over the ENTIRE player cache (every
-- name ever seen — potentially thousands of entries after a long session)
-- for EVERY chat message, across all 17 registered chat events. Each pass
-- escaped a name into a pattern and ran gsub against the whole message, so
-- cost scaled with cache size, not message size — continuous, unbounded
-- garbage generation on busy channels (raid/guild/world chat), which is
-- what produced the addon's memory sawtooth (climbing during play, only
-- dropping when the GC finally caught up, e.g. on a loading screen/reload).
-- Benchmarked: ~20s of CPU time per 1000 messages scanned with a 5000-entry
-- cache under the old approach.
--
-- Fix: GalaxyChat.Cache.nameIndex (built in Core.lua) maps bare name ->
-- classToken, so "is this word a known player?" is now a single O(1) table
-- lookup done once per word while tokenizing the message ONE time. Cost is
-- now proportional to the message being scanned, regardless of how large
-- the cache has grown. Hyperlink-protected-range detection also now runs
-- at most once per message (and only when a "|H" is actually present),
-- instead of once per cache entry.
-- ---------------------------------------------------------------------------
local function ColorNamesInMessage(message)
    local nameIndex = GalaxyChat.Cache.nameIndex
    if not nameIndex or not next(nameIndex) then return message end

    local minLen = GalaxyChat.MIN_NAME_LENGTH or 2

    -- Most chat lines contain no hyperlink at all; only pay for the scan
    -- when one is actually present.
    local protectedRanges
    if message:find("|H", 1, true) then
        protectedRanges = FindProtectedRanges(message)
    end

    local changed = false
    local result = message:gsub("()(%a[%w']*)()", function(pre_pos, word, post_pos)
        if #word < minLen then return word end
        if protectedRanges and InProtectedRange(pre_pos, protectedRanges) then
            return word  -- inside a |H...|h link; leave intact
        end

        local classToken = nameIndex[word]
        if not classToken then return word end

        changed = true
        return ClassColors.ColorName(word, classToken)
    end)

    -- Only hand back a modified string when something actually changed, so
    -- the caller (MidMessageFilter) can cheaply detect "no-op" and skip
    -- re-adding the message through the filter chain.
    if not changed then return message end
    return result
end

local function MidMessageFilter(chatFrame, event, message, author, language, channelString,
                                 target, flags, unknown, channelNumber, channelName,
                                 unknown2, guid, bnSenderID, isMobile, isSubMerged)

    if not GalaxyChat.GetSetting("classColors", "enabled") then return false end
    if not GalaxyChat.GetSetting("classColors", "colorMidMessage") then return false end
    if not message then return false end

    -- Secret strings from secure combat contexts cannot be indexed; bail silently.
    local ok, isEmpty = pcall(string.find, message, "^$")
    if not ok or isEmpty then return false end

    local ok2, colored = pcall(ColorNamesInMessage, message)
    if not ok2 or not colored or colored == message then return false end

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
