-- ProximityAlert.lua
-- ProximityAlert addon: searches pfDB/pfQuest for rare mobs, uses stored coords to only actively search when player is near.
-- Provides /proxalert slash commands to control settings (no options UI, no minimap button).

local addonName = "ProximityAlert"
local frame = CreateFrame("Frame", "ProximityAlertMainFrame")
local alertShown = false
local lastScan = 0
local scanInterval = 3     -- scan every 3 seconds
local cooldown = 180       -- 3-minute cooldown per rare to avoid spam

-- Saved settings (persisted as ProximityAlertConfig between sessions)
ProximityAlertConfig = ProximityAlertConfig or {
    enabled = true,
    debug = false,
    sounds = true,
    approachDistance = 0.06, -- normalized (0..1)
}

-- Track when each mob was last alerted
local lastAlert = {}

-- Cache and zone tracking
local lastZone = nil
-- cachedRares[name] = { coords = { {x=..., y=...}, ... } or {} when no coords available
local cachedRares = {}

-- Alert hide time
local hideTime = nil

-- Create visual alert frame
local ProximityAlertFrame = CreateFrame("Frame", "ProximityAlertFrame", UIParent)
ProximityAlertFrame:SetWidth(260)
ProximityAlertFrame:SetHeight(60)
ProximityAlertFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 200)
ProximityAlertFrame:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 }
})
ProximityAlertFrame:SetBackdropColor(0, 0, 0, 0.8)
ProximityAlertFrame:Hide()

local ProximityAlertText = ProximityAlertFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
ProximityAlertText:SetPoint("CENTER", ProximityAlertFrame, "CENTER", 0, 0)

-- Utility Helpers

-- Safe sound playback (respect config.sounds)
local function SafePlaySoundIfEnabled(path)
    if not ProximityAlertConfig.sounds then return end
    if PlaySoundFile then
        PlaySoundFile(path)
    else
        PlaySound("igQuestLogOpen")
    end
end

-- Safe target
local function SafeTargetByName(name)
    pcall(function()
        UIErrorsFrame:UnregisterEvent("UI_ERROR_MESSAGE")
        TargetByName(name, true)
        UIErrorsFrame:RegisterEvent("UI_ERROR_MESSAGE")
    end)
end

-- Show alert
local function ShowAlert(message, soundFile)
    if alertShown then return end
    alertShown = true

    ProximityAlertText:SetText(message)
    ProximityAlertFrame:Show()

    SafePlaySoundIfEnabled("Interface\\AddOns\\ProximityAlert\\Sounds\\" .. (soundFile or "foundrare.wav"))

    hideTime = GetTime() + 3
end

-- Debug output controlled by config
local function DebugPrint(msg)
    if ProximityAlertConfig.debug then
        DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa[ProximityAlert DEBUG]: " .. tostring(msg) .. "|r")
    end
end

-- Return player's current map position as normalized coords (0..1), or nil if unavailable
local function GetPlayerNormalizedPos()
    if type(GetPlayerMapPosition) ~= "function" then return nil end
    local px, py = GetPlayerMapPosition("player")
    if not px or not py then return nil end
    if px == 0 and py == 0 then
        return nil
    end
    return px, py
end

-- Euclidean distance between two normalized points (0..1)
local function Dist(aX, aY, bX, bY)
    local dx = aX - bX
    local dy = aY - bY
    return math.sqrt(dx * dx + dy * dy)
end

-- Safe table length function (avoids '#' operator)
local function TableLen(t)
    if not t then return 0 end
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- pfQuest Integration

-- Load rare list for the current zone and extract coordinates if available
local function GetZoneRares()
    if not pfDB or not pfDB.units or not pfDB.units.data or not pfDB.zones or not pfDB.zones.loc then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff5555[ProximityAlert]: pfQuest database not loaded.|r")
        return {}
    end

    local zoneName = GetRealZoneText()
    if not zoneName then return {} end

    zoneName = string.gsub(zoneName, "^%s*(.-)%s*$", "%1")

    -- only refresh when zone changes
    if zoneName ~= lastZone then
        lastZone = zoneName
        cachedRares = {}

        local zoneLoc = pfDB.zones.loc or {}
        local zoneId = nil
        for id, locName in pairs(zoneLoc) do
            if locName == zoneName then
                zoneId = tostring(id)  -- Ensure string for consistency
                break
            end
        end

        if not zoneId then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff5555[ProximityAlert]: No zone ID found for '" .. zoneName .. "'.|r")
            return {}
        end

        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[ProximityAlert]:|r Zone '" .. zoneName .. "' ID: " .. zoneId)

        local unitData = (pfDB.units and pfDB.units.data) or {}
        local unitLoc = (pfDB.units and pfDB.units.loc) or {}

        local numUnits = 0
        for _ in pairs(unitData) do numUnits = numUnits + 1 end
        DebugPrint("Total units in pfDB: " .. tostring(numUnits))

        local count = 0
        local anyCount = 0

        local zoneNum = tonumber(zoneId)

        for unitId, data in pairs(unitData) do
            -- only process if the unit entry is a table (defensive)
            if type(data) == "table" then
                -- robust zone spawn check: handle both data.spawns[zone] and data.coords entries
                local spawns = nil

                if type(data.spawns) == "table" then
                    spawns = data.spawns[zoneId] or data.spawns[zoneNum]
                end

                -- coords table uses entries like { x, y, zone, respawn }
                local coordsFound = {}
                if type(data.coords) == "table" then
                    for _, coordEntry in pairs(data.coords) do
                        if type(coordEntry) == "table" then
                            local cz = coordEntry[3]
                            if cz and (tonumber(cz) == zoneNum or tostring(cz) == zoneId) then
                                local cx = tonumber(coordEntry[1])
                                local cy = tonumber(coordEntry[2])
                                if cx and cy then
                                    -- convert from percent (0..100) to normalized (0..1)
                                    table.insert(coordsFound, { x = cx / 100.0, y = cy / 100.0 })
                                    spawns = true
                                end
                            end
                        end
                    end
                end

                if spawns then
                    anyCount = anyCount + 1

                    -- get unit rank robustly, some DBs use 'rnk', some 'rank'
                    local rank = nil
                    if type(data.rnk) ~= "nil" then
                        rank = tonumber(data.rnk)
                    elseif type(data.rank) ~= "nil" then
                        rank = tonumber(data.rank)
                    end

                    -- treat rank >= 3 as rare (per Turtle WoW / pfQuest-turtle)
                    if rank and rank >= 3 then
                        local unitNum = tonumber(unitId)
                        local name = (unitLoc and (unitLoc[unitId] or unitLoc[unitNum])) or data.name or tostring(unitId)
                        if name then
                            cachedRares[name] = cachedRares[name] or {}
                            -- attach coords if any found (may be empty)
                            if TableLen(coordsFound) > 0 then
                                cachedRares[name].coords = coordsFound
                            else
                                cachedRares[name].coords = cachedRares[name].coords or {}
                            end
                            count = count + 1
                        end
                    end
                end
            end
        end

        if count > 0 then
            DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[ProximityAlert]:|r Found " .. tostring(count) .. " rares in '" .. zoneName .. "':")
            for name, info in pairs(cachedRares) do
                local coordsText = ""
                if info and info.coords and TableLen(info.coords) > 0 then
                    coordsText = " (coords: " .. tostring(TableLen(info.coords)) .. ")"
                end
                DEFAULT_CHAT_FRAME:AddMessage("  - " .. name .. coordsText)
            end
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9933[ProximityAlert]:|r No rares found in '" .. zoneName .. "' (ID " .. zoneId .. ").")
            DebugPrint("Total units (any rank) in zone: " .. tostring(anyCount))
        end
    end

    return cachedRares
end

-- Core Scanning Logic
local function SilentScan()
    local now = GetTime()
    local zoneRares = GetZoneRares() or {}
    local prevTarget = UnitName("target")

    local px, py = GetPlayerNormalizedPos()

    for mobName, mobInfo in pairs(zoneRares) do
        if not mobName then break end

        -- if mobInfo has coords, only attempt search when player is close to at least one of them
        local allowedToSearch = true
        if mobInfo and mobInfo.coords and TableLen(mobInfo.coords) > 0 then
            if not px or not py then
                -- cannot determine player position; skip searching for mobs with coords to avoid false positives
                allowedToSearch = false
                DebugPrint("Cannot get player position, skipping active search for " .. tostring(mobName) .. ".")
            else
                -- compute nearest distance to the rare's coords
                local nearest = nil
                for _, c in pairs(mobInfo.coords) do
                    if c and c.x and c.y then
                        local d = Dist(px, py, c.x, c.y)
                        if not nearest or d < nearest then nearest = d end
                    end
                end
                if nearest then
                    if nearest <= ProximityAlertConfig.approachDistance then
                        allowedToSearch = true
                    else
                        allowedToSearch = false
                        DebugPrint(tostring(mobName) .. " is too far (" .. string.format("%.3f", nearest) .. "), need <= " .. tostring(ProximityAlertConfig.approachDistance) .. ".")
                    end
                else
                    allowedToSearch = false
                end
            end
        else
            -- No coords known for this rare in this zone: keep original behavior and search regardless
            allowedToSearch = true
        end

        if allowedToSearch then
            -- skip if recently alerted
            if not lastAlert[mobName] or (now - lastAlert[mobName]) > cooldown then
                DebugPrint("Checking for " .. tostring(mobName) .. "...")
                ClearTarget()
                SafeTargetByName(mobName)
                local name = UnitName("target")

                if name == mobName then
                    local isDead = UnitIsDead("target")
                    lastAlert[mobName] = now

                    if isDead then
                        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[ProximityAlert]:|r Found " .. tostring(name) .. " (dead)")
                        ShowAlert(tostring(name) .. " detected (dead)", "foundrare.wav")
                        ClearTarget()
                    else
                        -- get level info (wrap in pcall in case UnitLevel isn't available)
                        local lvl = "?"
                        if type(UnitLevel) == "function" then
                            local ok, v = pcall(UnitLevel, "target")
                            if ok and v then lvl = v end
                        end

                        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[ProximityAlert]:|r Found " .. tostring(name) .. " (alive, level " .. tostring(lvl) .. ")")
                        ShowAlert(tostring(name) .. " is nearby!", "foundrare.wav")

                        -- announce to party (if in a party)
                        local msg = string.format("Rare %s (level %s) spotted nearby!", tostring(mobName), tostring(lvl))
                        local inParty = false
                        if type(GetNumPartyMembers) == "function" then
                            local ok, n = pcall(GetNumPartyMembers)
                            if ok and n and n > 0 then inParty = true end
                        end
                        if inParty and type(SendChatMessage) == "function" then
                            pcall(SendChatMessage, msg, "PARTY")
                        else
                            -- Not in party: echo to default chat so user still sees it
                            DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[ProximityAlert]:|r " .. msg)
                        end

                        -- keep alive rare targeted
                    end
                    break
                end
            end
        end
    end

    -- restore previous target if none found
    if type(UnitName) == "function" then
        local cur = UnitName("target")
        if not cur and prevTarget then
            pcall(TargetByName, prevTarget, true)
        elseif not cur then
            pcall(ClearTarget)
        end
    end
end

-- OnUpdate Loop - wrapped in pcall to avoid crash loops and report errors once
frame:SetScript("OnUpdate", function()
    local now = GetTime()
    if now - lastScan >= scanInterval then
        if ProximityAlertConfig.enabled then
            local ok, err = pcall(SilentScan)
            if not ok and err then
                DEFAULT_CHAT_FRAME:AddMessage("|cffff5555[ProximityAlert Error]: " .. tostring(err) .. "|r")
            end
        else
            DebugPrint("ProximityAlert scanning paused (disabled).")
        end
        lastScan = now
    end

    if hideTime and now > hideTime then
        ProximityAlertFrame:Hide()
        hideTime = nil
        alertShown = false
    end
end)

-- Register for zone change to force cache refresh
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
frame:SetScript("OnEvent", function()
    lastZone = nil  -- force refresh on zone change
end)

DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99ProximityAlert|r initialized. Scanning every " .. tostring(scanInterval) .. "s for rares in this zone.")

-- ========== Slash command /proxalert ==========
SLASH_PROXIMITYALERT1 = "/proxalert"

local function PrintUsage()
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99ProximityAlert commands:|r")
    DEFAULT_CHAT_FRAME:AddMessage("/proxalert help - show this help")
    DEFAULT_CHAT_FRAME:AddMessage("/proxalert debug on|off - toggle debug messages")
    DEFAULT_CHAT_FRAME:AddMessage("/proxalert enabled on|off - enable/disable scanning")
    DEFAULT_CHAT_FRAME:AddMessage("/proxalert sounds on|off - toggle sounds")
    DEFAULT_CHAT_FRAME:AddMessage("/proxalert distance <0.01..0.5> - set approach distance (normalized)")
    DEFAULT_CHAT_FRAME:AddMessage("/proxalert status - print current settings")
    DEFAULT_CHAT_FRAME:AddMessage("/proxalert reset - reset settings to defaults")
end

local function ShowStatus()
    DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff33ff99ProximityAlert status:|r enabled=%s, debug=%s, sounds=%s, distance=%.3f",
        tostring(ProximityAlertConfig.enabled),
        tostring(ProximityAlertConfig.debug),
        tostring(ProximityAlertConfig.sounds),
        tonumber(ProximityAlertConfig.approachDistance) or 0))
end

SlashCmdList["PROXIMITYALERT"] = function(msg)
    if not msg or msg == "" then
        PrintUsage()
        return
    end

    local args = {}
    for word in string.gmatch(msg, "%S+") do table.insert(args, word) end
    local cmd = args[1] and string.lower(args[1]) or ""

    if cmd == "help" then
        PrintUsage()
        return
    elseif cmd == "debug" then
        local v = args[2] and string.lower(args[2])
        if v == "on" then
            ProximityAlertConfig.debug = true
            DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99ProximityAlert: Debug ON|r")
        elseif v == "off" then
            ProximityAlertConfig.debug = false
            DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99ProximityAlert: Debug OFF|r")
        else
            DEFAULT_CHAT_FRAME:AddMessage("Usage: /proxalert debug on|off")
        end
        return
    elseif cmd == "enabled" then
        local v = args[2] and string.lower(args[2])
        if v == "on" then
            ProximityAlertConfig.enabled = true
            DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99ProximityAlert: Scanning ENABLED|r")
        elseif v == "off" then
            ProximityAlertConfig.enabled = false
            DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99ProximityAlert: Scanning DISABLED|r")
        else
            DEFAULT_CHAT_FRAME:AddMessage("Usage: /proxalert enabled on|off")
        end
        return
    elseif cmd == "sounds" then
        local v = args[2] and string.lower(args[2])
        if v == "on" then
            ProximityAlertConfig.sounds = true
            DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99ProximityAlert: Sounds ON|r")
        elseif v == "off" then
            ProximityAlertConfig.sounds = false
            DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99ProximityAlert: Sounds OFF|r")
        else
            DEFAULT_CHAT_FRAME:AddMessage("Usage: /proxalert sounds on|off")
        end
        return
    elseif cmd == "distance" then
        local v = tonumber(args[2])
        if v and v >= 0.01 and v <= 0.5 then
            ProximityAlertConfig.approachDistance = v
            DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff33ff99ProximityAlert: approachDistance set to %.3f|r", v))
        else
            DEFAULT_CHAT_FRAME:AddMessage("Usage: /proxalert distance <0.01..0.5>")
        end
        return
    elseif cmd == "status" then
        ShowStatus()
        return
    elseif cmd == "reset" then
        ProximityAlertConfig = {
            enabled = true,
            debug = false,
            sounds = true,
            approachDistance = 0.06,
        }
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99ProximityAlert: settings reset to defaults|r")
        return
    else
        PrintUsage()
        return
    end
end