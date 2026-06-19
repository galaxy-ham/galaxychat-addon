-- GalaxyChat/Core.lua
-- Bootstrap, SavedVariables init, player cache, event dispatcher, slash commands.

GalaxyChat = GalaxyChat or {}

-- ---------------------------------------------------------------------------
-- Internal frame used for event registration
-- ---------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame", "GalaxyChatEventFrame")

-- ---------------------------------------------------------------------------
-- Utility: deep-merge src into dst (dst wins on conflicts, src fills gaps)
-- ---------------------------------------------------------------------------
local function DeepMergeDefaults(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then
                dst[k] = {}
            end
            DeepMergeDefaults(dst[k], v)
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
end

-- ---------------------------------------------------------------------------
-- Cache Module
-- GalaxyChatDB.playerCache[nameRealm] = { classToken, timestamp }
-- ---------------------------------------------------------------------------
GalaxyChat.Cache = {}
local Cache = GalaxyChat.Cache

local lookupQueue   = {}   -- { nameRealm = true }
local lookupPending = {}   -- names we've already sent a lookup request for

function Cache.Key(name, realm)
    realm = realm or GetRealmName() or ""
    if realm == "" then
        return name
    end
    return name .. "-" .. realm
end

function Cache.Get(nameRealm)
    local db = GalaxyChatDB and GalaxyChatDB.playerCache
    if not db then return nil end
    return db[nameRealm]
end

function Cache.Set(nameRealm, classToken)
    if not GalaxyChatDB then return end
    GalaxyChatDB.playerCache = GalaxyChatDB.playerCache or {}
    GalaxyChatDB.playerCache[nameRealm] = {
        classToken = classToken,
        timestamp  = time(),
    }
end

function Cache.QueueLookup(name, realm)
    if not name or name == "" then return end
    local key = Cache.Key(name, realm)
    if Cache.Get(key) then return end      -- already cached
    if lookupQueue[key] then return end    -- already queued
    lookupQueue[key] = true
end

function Cache.FlushQueue()
    local db = GalaxyChatDB
    if not db then return end

    local processed = 0
    for key in pairs(lookupQueue) do
        if processed >= GalaxyChat.CACHE_FLUSH_BATCH then break end

        -- Try GetPlayerInfoByGUID — we don't always have the GUID, so
        -- we attempt via the tooltip/unit trick where possible.
        -- Best-effort: if the name is visible in the group/guild, pull info.
        local name, realm = strsplit("-", key, 2)

        -- Check group members
        local found = false
        local numGroup = GetNumGroupMembers and GetNumGroupMembers() or 0
        for i = 1, numGroup do
            local unit = (IsInRaid() and "raid" or "party") .. i
            local uName, uRealm = UnitName(unit)
            if uName == name then
                local _, classToken = UnitClass(unit)
                if classToken then
                    Cache.Set(key, classToken)
                    found = true
                    break
                end
            end
        end

        -- Check guild roster if not found in group
        if not found then
            local numGuild = GetNumGuildMembers and GetNumGuildMembers() or 0
            for i = 1, numGuild do
                local gName, _, _, _, _, _, _, _, _, _, gClass = GetGuildRosterInfo(i)
                if gName then
                    local gBase = strsplit("-", gName, 2)
                    if gBase == name then
                        if gClass then
                            Cache.Set(key, gClass:upper():gsub(" ", ""))
                            found = true
                            break
                        end
                    end
                end
            end
        end

        -- Remove from queue regardless of success (avoid hammering)
        lookupQueue[key] = nil
        processed = processed + 1
    end
end

function Cache.Prune()
    local db = GalaxyChatDB
    if not db or not db.playerCache then return end
    if not db.settings or not db.settings.cache then return end

    local maxAge = (db.settings.cache.maxAgeDays or 60) * 86400
    local now    = time()
    local pruned = 0

    for key, entry in pairs(db.playerCache) do
        if (now - (entry.timestamp or 0)) > maxAge then
            db.playerCache[key] = nil
            pruned = pruned + 1
        end
    end

    if pruned > 0 then
        print("|cff88aaff[GalaxyChat]|r Pruned " .. pruned .. " stale cache entries.")
    end
end

function Cache.Enforce()
    local db = GalaxyChatDB
    if not db or not db.playerCache then return end
    if not db.settings or not db.settings.cache then return end

    local maxEntries = db.settings.cache.maxEntries or 5000

    -- Count entries
    local entries = {}
    for key, entry in pairs(db.playerCache) do
        table.insert(entries, { key = key, timestamp = entry.timestamp or 0 })
    end

    if #entries <= maxEntries then return end

    -- Sort oldest first
    table.sort(entries, function(a, b) return a.timestamp < b.timestamp end)

    -- Remove oldest until within limit
    local toRemove = #entries - maxEntries
    for i = 1, toRemove do
        db.playerCache[entries[i].key] = nil
    end

    print("|cff88aaff[GalaxyChat]|r Cache trimmed to " .. maxEntries .. " entries.")
end

function Cache.Clear()
    if GalaxyChatDB then
        GalaxyChatDB.playerCache = {}
        print("|cff88aaff[GalaxyChat]|r Player cache cleared.")
    end
end

-- ---------------------------------------------------------------------------
-- Warm cache from currently available unit information
-- ---------------------------------------------------------------------------
local function WarmCacheFromUnits()
    -- Current player
    local pName, pRealm = UnitName("player")
    pRealm = pRealm or GetRealmName() or ""
    local _, pClass = UnitClass("player")
    if pName and pClass then
        Cache.Set(Cache.Key(pName, pRealm), pClass)
    end

    -- Group members
    local numGroup = GetNumGroupMembers and GetNumGroupMembers() or 0
    for i = 1, numGroup do
        local unit = (IsInRaid() and "raid" or "party") .. i
        local uName, uRealm = UnitName(unit)
        local _, uClass = UnitClass(unit)
        if uName and uClass then
            uRealm = uRealm or GetRealmName() or ""
            Cache.Set(Cache.Key(uName, uRealm), uClass)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Event handling
-- ---------------------------------------------------------------------------
local registeredModuleEvents = {}   -- event -> list of handler functions

function GalaxyChat.RegisterEvent(event, handler)
    if not registeredModuleEvents[event] then
        registeredModuleEvents[event] = {}
        eventFrame:RegisterEvent(event)
    end
    table.insert(registeredModuleEvents[event], handler)
end

eventFrame:SetScript("OnEvent", function(self, event, ...)
    -- Dispatch to module handlers
    local handlers = registeredModuleEvents[event]
    if handlers then
        for _, fn in ipairs(handlers) do
            fn(event, ...)
        end
    end

    -- Core handlers
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName ~= "GalaxyChat" then return end

        -- Init SavedVariables
        GalaxyChatDB = GalaxyChatDB or {}
        GalaxyChatDB.settings    = GalaxyChatDB.settings    or {}
        GalaxyChatDB.playerCache = GalaxyChatDB.playerCache or {}

        DeepMergeDefaults(GalaxyChatDB.settings, GalaxyChat.Defaults)

        -- Prune and enforce cache limits on login
        Cache.Prune()
        Cache.Enforce()

        -- Start the queue flush ticker
        C_Timer.NewTicker(GalaxyChat.CACHE_FLUSH_INTERVAL, Cache.FlushQueue)

        -- Init modules (each checks its own enabled flag)
        if GalaxyChat.ClassColors then GalaxyChat.ClassColors.Init() end
        if GalaxyChat.NameAlert   then GalaxyChat.NameAlert.Init()   end
        if GalaxyChat.URLHandler  then GalaxyChat.URLHandler.Init()  end
        if GalaxyChat.Settings    then GalaxyChat.Settings.Init()    end

    elseif event == "PLAYER_LOGIN" then
        WarmCacheFromUnits()

        -- Store current character name for NameAlert
        local name, realm = UnitName("player")
        GalaxyChat.playerName  = name
        GalaxyChat.playerRealm = realm or GetRealmName() or ""

    elseif event == "GROUP_ROSTER_UPDATE"
        or event == "FRIENDLIST_UPDATE"
        or event == "GUILD_ROSTER_UPDATE"
        or event == "WHO_LIST_UPDATE" then
        WarmCacheFromUnits()
    end
end)

eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
eventFrame:RegisterEvent("FRIENDLIST_UPDATE")
eventFrame:RegisterEvent("GUILD_ROSTER_UPDATE")
eventFrame:RegisterEvent("WHO_LIST_UPDATE")

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------
local function OpenSettings()
    -- Opens the GalaxyChat settings category in the retail Settings panel.
    if GalaxyChat.Settings and GalaxyChat.Settings.OpenPanel then
        GalaxyChat.Settings.OpenPanel()
    else
        print("|cff88aaff[GalaxyChat]|r Settings panel not loaded yet.")
    end
end

SLASH_GALAXYCHAT1 = "/galaxychat"
SLASH_GALAXYCHAT2 = "/gc"

-- Debug: capture the next incoming chat message and dump its raw args
local debugNextMessage = false

SlashCmdList["GALAXYCHAT"] = function(msg)
    msg = msg and msg:lower():trim() or ""
    if msg == "" or msg == "config" or msg == "settings" then
        OpenSettings()
    elseif msg == "clearcache" then
        Cache.Clear()
    elseif msg == "version" then
        print("|cff88aaff[GalaxyChat]|r v1.0.0")
    elseif msg == "debug" then
        debugNextMessage = true
        print("|cff88aaff[GalaxyChat]|r Debug: will dump raw args for the next chat message.")
    else
        print("|cff88aaff[GalaxyChat]|r Commands:")
        print("  /gc             — Open settings")
        print("  /gc clearcache  — Clear player name cache")
        print("  /gc debug       — Dump raw args of next chat message")
        print("  /gc version     — Show version")
    end
end

-- Register a chat filter purely for debug dumping
ChatFrame_AddMessageEventFilter("CHAT_MSG_SAY",   function(_, event, msg, author) if debugNextMessage then debugNextMessage = false; print("[GC DEBUG] event=" .. tostring(event)); print("[GC DEBUG] author=" .. tostring(author)); print("[GC DEBUG] msg=" .. tostring(msg)) end return false end)
ChatFrame_AddMessageEventFilter("CHAT_MSG_RAID",  function(_, event, msg, author) if debugNextMessage then debugNextMessage = false; print("[GC DEBUG] event=" .. tostring(event)); print("[GC DEBUG] author=" .. tostring(author)); print("[GC DEBUG] msg=" .. tostring(msg)) end return false end)
ChatFrame_AddMessageEventFilter("CHAT_MSG_PARTY", function(_, event, msg, author) if debugNextMessage then debugNextMessage = false; print("[GC DEBUG] event=" .. tostring(event)); print("[GC DEBUG] author=" .. tostring(author)); print("[GC DEBUG] msg=" .. tostring(msg)) end return false end)

-- ---------------------------------------------------------------------------
-- Convenience accessor used by modules
-- ---------------------------------------------------------------------------
function GalaxyChat.GetSetting(...)
    local node = GalaxyChatDB and GalaxyChatDB.settings
    if not node then return nil end
    for _, key in ipairs({...}) do
        node = node[key]
        if node == nil then return nil end
    end
    return node
end

function GalaxyChat.SetSetting(value, ...)
    if not GalaxyChatDB or not GalaxyChatDB.settings then return end
    local keys  = {...}
    local node  = GalaxyChatDB.settings
    for i = 1, #keys - 1 do
        node = node[keys[i]]
        if type(node) ~= "table" then return end
    end
    node[keys[#keys]] = value
end
