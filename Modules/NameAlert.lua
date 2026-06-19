-- GalaxyChat/Modules/NameAlert.lua
-- Plays a sound when the player's name or a keyword appears in chat.

GalaxyChat = GalaxyChat or {}
GalaxyChat.NameAlert = {}
local NameAlert = GalaxyChat.NameAlert

-- Parsed keyword list (rebuilt on settings change)
local keywords       = {}
local lastAlertTime  = 0    -- GetTime() value, used for debounce

-- ---------------------------------------------------------------------------
-- Keyword list builder
-- Reads from settings, lowercases and trims all entries.
-- Optionally prepends the current character name.
-- ---------------------------------------------------------------------------
function NameAlert.BuildKeywordList()
    keywords = {}

    local settings = GalaxyChat.GetSetting("nameAlert")
    if not settings then return end

    -- Character name
    if settings.includeCharacterName and GalaxyChat.playerName then
        table.insert(keywords, GalaxyChat.playerName:lower())
    end

    -- User-defined keywords
    local raw = settings.keywords or ""
    for token in raw:gmatch("[^,]+") do
        local trimmed = token:match("^%s*(.-)%s*$")
        if trimmed ~= "" then
            table.insert(keywords, trimmed:lower())
        end
    end
end

-- ---------------------------------------------------------------------------
-- Sound playback with debounce
-- ---------------------------------------------------------------------------
function NameAlert.PlayAlert()
    local now = GetTime()
    local debounce = GalaxyChat.ALERT_DEBOUNCE_MS / 1000

    if (now - lastAlertTime) < debounce then return end
    lastAlertTime = now

    local soundId      = GalaxyChat.GetSetting("nameAlert", "soundId")      or 3081
    local soundChannel = GalaxyChat.GetSetting("nameAlert", "soundChannel") or "Master"
    PlaySound(soundId, soundChannel)
end

-- ---------------------------------------------------------------------------
-- Message checker
-- ---------------------------------------------------------------------------
function NameAlert.CheckMessage(message, event)
    if not message or #keywords == 0 then return end

    local lower = message:lower()
    for _, kw in ipairs(keywords) do
        if lower:find(kw, 1, true) then
            NameAlert.PlayAlert()
            return   -- one sound per message, no double-fire
        end
    end
end

-- ---------------------------------------------------------------------------
-- Event handler
-- ---------------------------------------------------------------------------
local whisperEvents = {
    CHAT_MSG_WHISPER        = true,
    CHAT_MSG_WHISPER_INFORM = true,
}

local function OnChatEvent(event, message, author, ...)
    local settings = GalaxyChat.GetSetting("nameAlert")
    if not settings or not settings.enabled then return end

    -- Gate whispers behind the setting
    if whisperEvents[event] and not settings.alertOnWhisper then return end

    NameAlert.CheckMessage(message, event)
end

-- ---------------------------------------------------------------------------
-- Enable / Disable
-- ---------------------------------------------------------------------------
local eventsRegistered = false

function NameAlert.Enable()
    if eventsRegistered then return end
    for _, event in ipairs(GalaxyChat.ChatEvents) do
        GalaxyChat.RegisterEvent(event, OnChatEvent)
    end
    eventsRegistered = true
end

function NameAlert.Disable()
    -- GalaxyChat.RegisterEvent does not support removal (simple design).
    -- The handler itself checks the enabled flag, so disabling via setting
    -- is sufficient — events are cheap to dispatch to a no-op guard.
    eventsRegistered = false
end

-- Rebuild keyword list whenever player name becomes available
local function OnPlayerLogin(event, ...)
    NameAlert.BuildKeywordList()
end

-- ---------------------------------------------------------------------------
-- Init
-- ---------------------------------------------------------------------------
function NameAlert.Init()
    -- Listen for login to capture character name before building keyword list
    GalaxyChat.RegisterEvent("PLAYER_LOGIN", OnPlayerLogin)

    if GalaxyChat.GetSetting("nameAlert", "enabled") then
        NameAlert.Enable()
    end

    -- Build now in case PLAYER_LOGIN already fired (shouldn't happen, but safe)
    NameAlert.BuildKeywordList()
end

-- ---------------------------------------------------------------------------
-- Public API for settings panel
-- ---------------------------------------------------------------------------

-- Call after any keyword/sound setting changes
function NameAlert.Refresh()
    NameAlert.BuildKeywordList()
end

-- Test the currently configured sound immediately
function NameAlert.TestSound()
    local soundId      = GalaxyChat.GetSetting("nameAlert", "soundId")      or 3081
    local soundChannel = GalaxyChat.GetSetting("nameAlert", "soundChannel") or "Master"
    PlaySound(soundId, soundChannel)
end
