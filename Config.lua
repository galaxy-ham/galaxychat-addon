-- GalaxyChat/Config.lua
-- Default settings and constants. Loaded first so all modules can reference them.

GalaxyChat = GalaxyChat or {}

-- ---------------------------------------------------------------------------
-- Defaults
-- Deep-copied into GalaxyChatDB on first load (or for any missing keys).
-- ---------------------------------------------------------------------------
GalaxyChat.Defaults = {
    classColors = {
        enabled         = false,
        colorAuthorName = true,
        colorMidMessage = true,
    },
    nameAlert = {
        enabled              = false,
        keywords             = "",       -- comma-separated string
        includeCharacterName = true,
        soundId              = 3081,     -- default: Whisper
        soundChannel         = "Master", -- Master, SFX, Music, Ambience, Dialog
        alertOnWhisper       = false,
    },
    urlHandler = {
        enabled = false,
    },
    cache = {
        maxEntries  = 5000,
        maxAgeDays  = 60,
    },
}

-- ---------------------------------------------------------------------------
-- Sound presets shown in the settings dropdown.
-- { label, id } — id is a SoundKitID.
-- Mixed set: a few subtle UI tones, a few punchy/dramatic ones.
-- ---------------------------------------------------------------------------
GalaxyChat.SoundPresets = {
    { label = "Whisper",      id = 3081   },
    { label = "Chat Warning", id = 15273  },
    { label = "Toast",        id = 18019  },
    { label = "Loot",         id = 31578  },
    { label = "Tabs",         id = 43938  },
    { label = "Rain Drop",    id = 111366 },
}

-- ---------------------------------------------------------------------------
-- Sound output channels available to PlaySound().
-- ---------------------------------------------------------------------------
GalaxyChat.SoundChannels = {
    "Master",
    "SFX",
    "Music",
    "Ambience",
    "Dialog",
}

-- ---------------------------------------------------------------------------
-- Chat events we want to scan.
-- Used by both ClassColors and NameAlert modules.
-- ---------------------------------------------------------------------------
GalaxyChat.ChatEvents = {
    "CHAT_MSG_SAY",
    "CHAT_MSG_YELL",
    "CHAT_MSG_EMOTE",
    "CHAT_MSG_TEXT_EMOTE",
    "CHAT_MSG_PARTY",
    "CHAT_MSG_PARTY_LEADER",
    "CHAT_MSG_RAID",
    "CHAT_MSG_RAID_LEADER",
    "CHAT_MSG_RAID_WARNING",
    "CHAT_MSG_INSTANCE_CHAT",
    "CHAT_MSG_INSTANCE_CHAT_LEADER",
    "CHAT_MSG_GUILD",
    "CHAT_MSG_OFFICER",
    "CHAT_MSG_WHISPER",
    "CHAT_MSG_WHISPER_INFORM",
    "CHAT_MSG_CHANNEL",
    "CHAT_MSG_SYSTEM",
}

-- ---------------------------------------------------------------------------
-- URL detection patterns (Lua pattern syntax).
-- Checked in order; first match per token wins.
-- ---------------------------------------------------------------------------
GalaxyChat.URLPatterns = {
    "https?://[%w%-%.%_%~%:%/%?%#%[%]%@%!%$%&%'%(%)%*%+%,%;%=]+",
    "www%.[%w%-]+%.[%w%-%.]+[%S]*",
    "[%w%-]+%.gg/[%S]*",
    "[%w%-]+%.tv/[%S]*",
    "[%w%-]+%.io/[%S]*",
    "[%w%-]+%.com/[%S]*",
    "[%w%-]+%.net/[%S]*",
    "[%w%-]+%.org/[%S]*",
}

-- ---------------------------------------------------------------------------
-- Misc constants
-- ---------------------------------------------------------------------------
GalaxyChat.CACHE_FLUSH_INTERVAL = 2      -- seconds between queue flush ticks
GalaxyChat.CACHE_FLUSH_BATCH    = 5      -- max lookups attempted per tick
GalaxyChat.ALERT_DEBOUNCE_MS    = 500    -- ms between sound triggers
GalaxyChat.MIN_NAME_LENGTH      = 2      -- skip mid-msg scan for very short names
