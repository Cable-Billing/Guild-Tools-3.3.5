-- GuildTools 3.3.5 - Core (clean rebuild: no revert, no offline queue, UI + prune)
local ADDON_NAME = ...

GuildTools335 = GuildTools335 or {}
GuildTools335.version = "0.3.0"

-- SavedVariables used: GuildTools335DB

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff96[GT]|r "..tostring(msg))
end

-- ==============================
-- Initialize SavedVariables
-- ==============================
local fInit = CreateFrame("Frame")
fInit:RegisterEvent("ADDON_LOADED")
fInit:SetScript("OnEvent", function(self, event, addon)
    if addon ~= "GuildTools335" then return end

    GuildTools335DB = GuildTools335DB or {}
    GuildTools335DB.rankRules = GuildTools335DB.rankRules or {}
    GuildTools335DB.rankRules["Established"] = GuildTools335DB.rankRules["Established"] or 0
    GuildTools335DB.rankRules["Member"]      = GuildTools335DB.rankRules["Member"] or 0

    GuildTools335DB.altLinks = GuildTools335DB.altLinks or {}    -- alt -> main
    GuildTools335DB.uiCollapsed = GuildTools335DB.uiCollapsed or {} -- ui collapsed mains

    Print("GuildTools335 loaded. Type /gt for help.")
end)

-- ==============================
-- Guild utility helpers
-- ==============================
local function CanEditOfficerNote()
    if not IsInGuild() then return false end
    return CanGuildPromote() or CanGuildDemote()
end

local function EnsureGuildRoster()
    if not IsInGuild() then
        Print("You are not in a guild.")
        return false
    end
    GuildRoster()
    return true
end

local function TrySetRank(name, targetRank)
    if not name or not targetRank then return false end
    targetRank = tonumber(targetRank)
    if not targetRank then return false end

    for i = 1, GetNumGuildMembers() do
        local n, _, r = GetGuildRosterInfo(i)
        if n == name then
            -- 3.3.5 uses flipped numbering: lower number => higher rank
            while r > targetRank do
                GuildPromote(name)
                r = r - 1
            end
            while r < targetRank do
                GuildDemote(name)
                r = r + 1
            end
            return true
        end
    end

    return false -- offline or not found
end

local function GetMainName(name)
    if not name then return nil end
    return (GuildTools335DB.altLinks and GuildTools335DB.altLinks[name]) or name
end

local function ParseTokens(note)
    local t = {}
    if not note or note == "" then return t end
    for key, val in string.gmatch(note, "%[(%u+):([%w,%-_]+)%]") do
        t[key] = val
    end
    return t
end

local function GetNotes(index)
    if not index then return "", "" end
    local _, _, _, _, _, _, note, officernote = GetGuildRosterInfo(index)
    return note or "", officernote or ""
end

local function SetOfficerNote(index, text)
    if index and text then
        GuildRosterSetOfficerNote(index, text)
    end
end

local function FindMemberIndexByName(searchName)
    if not searchName then return nil end
    local n = GetNumGuildMembers()
    searchName = string.lower(searchName)
    for i = 1, n do
        local name = GetGuildRosterInfo(i)
        if name then
            local short = string.match(name, "^[^-]+") or name
            if string.lower(short) == searchName then
                return i, name
            end
        end
    end
    return nil
end

local function BuildGroups()
    local n = GetNumGuildMembers()
    local groups = {}
    local byName = {}
    for i = 1, n do
        local fullname = GetGuildRosterInfo(i) or ("Unknown"..i)
        local short = string.match(fullname, "^[^-]+") or fullname
        local note, onote = GetNotes(i)
        local tokens = ParseTokens(onote)
        if next(tokens) == nil then
            tokens = ParseTokens(note)
        end
        local main = tokens["MAIN"] or short
        main = string.match(main, "^[^-]+") or main
        groups[main] = groups[main] or { main = main, alts = {} }
        if short ~= main then
            table.insert(groups[main].alts, short)
        end
        byName[string.lower(short)] = main
    end
    return groups, byName
end

local function SetOfficerMainToken(index, onote, mainName)
    if not index or not mainName then return end
    onote = onote or ""
    onote = onote:gsub("%[MAIN:[^%]]+%]", "")
    if onote ~= "" then onote = onote .. " " end
    onote = onote .. "[MAIN:"..(string.match(mainName, "^[^-]+") or mainName).."]"
    SetOfficerNote(index, onote)
end

-- ==============================
-- Alt rank calculation helper (NEW)
-- ==============================
local function ComputeAltTargetForMain(mainRankIndex)
    local rules = GuildTools335DB and GuildTools335DB.rankRules or {}
    local established = tonumber(rules["Established"]) or 7
    if established == 0 then established = 7 end
    local member = tonumber(rules["Member"]) or 8
    if member == 0 then member = 8 end

    mainRankIndex = tonumber(mainRankIndex) or member

    -- If main is worse than Member (index > member), alt matches main (keeps initiates at initiates).
    if mainRankIndex > member then
        return mainRankIndex
    end

    -- If main is exactly Member or Established, alt goes to Member.
    if mainRankIndex == established or mainRankIndex == member then
        return member
    end

    -- If main is better than Established, cap alt at Established.
    if mainRankIndex < established then
        return established
    end

    return member
end

-- ==============================
-- Link / unlink
-- ==============================
local function UpdateMainAltLink(altName, mainName)
    if not EnsureGuildRoster() then return end
    if not CanEditOfficerNote() then
        Print("Officer permissions required to link mains/alts.")
        return
    end

    local altIndex, altFull = FindMemberIndexByName(altName)
    local mainIndex, mainFull = FindMemberIndexByName(mainName)
    if not altIndex then Print("Alt not found: "..tostring(altName)); return end
    if not mainIndex then Print("Main not found: "..tostring(mainName)); return end

    local _, onote = GetNotes(altIndex)
    SetOfficerMainToken(altIndex, onote, mainFull)
    GuildTools335DB.altLinks[altFull] = mainFull

    local _, _, mainRankIndex = GetGuildRosterInfo(mainIndex)
    local desiredAltRank = ComputeAltTargetForMain(mainRankIndex)

    local success = TrySetRank(altFull, desiredAltRank)
    if success then
        Print(("Linked %s -> %s and adjusted %s to rank %d"):format(altFull, mainFull, altFull, desiredAltRank))
    else
        Print(("Linked %s -> %s. %s appears offline; rank left unchanged."):format(altFull, mainFull, altFull))
    end
end

local function Unlink(name)
    if not EnsureGuildRoster() then return end
    if not CanEditOfficerNote() then
        Print("Officer permissions required to unlink.")
        return
    end
    local idx, fullname = FindMemberIndexByName(name)
    if not idx then Print("Name not found: "..tostring(name)); return end
    local _, onote = GetNotes(idx)
    onote = (onote or ""):gsub("%[MAIN:[^%]]+%]", "")
    SetOfficerNote(idx, onote)
    GuildTools335DB.altLinks[fullname] = nil
    Print(("Unlinked %s"):format(fullname))
end

-- ==============================
-- Kick group
-- ==============================
local function KickGroup(name)
    if not EnsureGuildRoster() then return end
    local groups, byName = BuildGroups()
    local main = byName[string.lower(name)] or name
    local g = groups[main]
    if not g then Print("Group not found for "..tostring(name)); return end
    GuildUninvite(g.main)
    for _, alt in ipairs(g.alts) do
        GuildUninvite(alt)
    end
    Print(("Kicked group: %s (includes %d alts)"):format(g.main, #g.alts))
end

-- ==============================
-- Promote group with alt rules (uses helper)
-- ==============================
local function PromoteGroupWithAltRules(groupTable, targetRank)
    if not EnsureGuildRoster() then return end
    if not groupTable or #groupTable == 0 then return end
    targetRank = tonumber(targetRank)
    if not targetRank then Print("Invalid target rank."); return end
    if not (CanGuildPromote() or CanGuildDemote()) then Print("You need promote/demote permissions."); return end

    local processedMains = {}

    for _, name in ipairs(groupTable) do
        local main = GetMainName(name)
        if not processedMains[main] then
            processedMains[main] = true

            local mainSuccess = TrySetRank(main, targetRank)
            if mainSuccess then
                Print(("%s promoted to rank %d"):format(main, targetRank))
            else
                Print(("%s is offline or not found; main rank left unchanged."):format(tostring(main)))
            end

            for alt, linkedMain in pairs(GuildTools335DB.altLinks or {}) do
                if linkedMain == main and alt ~= main then
                    local desiredAltRank = ComputeAltTargetForMain(targetRank)

                    local altIndex = FindMemberIndexByName(alt)
                    local altTarget = desiredAltRank
                    if altIndex then
                        local _, _, altOldRank = GetGuildRosterInfo(altIndex)
                        if altOldRank and altOldRank < altTarget then
                            altTarget = altOldRank
                        end
                    end

                    local altSuccess = TrySetRank(alt, altTarget)
                    if altSuccess then
                        Print(("%s (alt of %s) set to rank %d"):format(alt, main, altTarget))
                    else
                        Print(("%s (alt of %s) is offline; rank left unchanged. Desired rank would be %d."):format(alt, main, altTarget))
                    end
                end
            end
        end
    end
end

-- ==============================
-- Show queued (removed)
-- ==============================
local function ShowQueuedPromotions()
    Print("Offline queue removed in this build. No queued promotions are stored.")
end

-- ==============================
-- Show ranks
-- ==============================
local function ShowRankRules()
    local r = GuildTools335DB.rankRules or {}
    Print(("Rank rules: Established=%s, Member=%s"):format(tostring(r.Established or "nil"), tostring(r.Member or "nil")))
end

-- ==============================
-- UI, prune, etc (unchanged)
-- ==============================
-- [UI code remains unchanged from your version]

-- ==============================
-- Slash commands handler (unchanged except using new funcs)
-- ==============================
SLASH_GUILDTOOLS1 = "/gt"
SlashCmdList["GUILDTOOLS"] = function(msg)
    local args = {}
    for w in string.gmatch(msg or "", "%S+") do table.insert(args, w) end
    local cmd = string.lower(args[1] or "")

    if cmd == "link" and args[2] and args[3] then
        UpdateMainAltLink(args[2], args[3])
    elseif cmd == "unlink" and args[2] then
        Unlink(args[2])
    elseif cmd == "show" and args[2] then
        if not EnsureGuildRoster() then return end
        local groups = BuildGroups()
        local name = args[2]
        local found = nil
        for m,g in pairs(groups) do
            if string.lower(m) == string.lower(name) then found = g; break end
            for _,a in ipairs(g.alts) do
                if string.lower(a) == string.lower(name) then found = g; break end
            end
            if found then break end
        end
        if not found then Print("No group found for "..tostring(name)); return end
        local list = table.concat(found.alts, ", ")
        Print(("Group [%s]: %s"):format(found.main, list ~= "" and list or "(no alts)"))
    elseif cmd == "kickgroup" and args[2] then
        KickGroup(args[2])
    elseif cmd == "promotegroup" and args[2] and args[3] then
        local groups, byName = BuildGroups()
        local main = byName[string.lower(args[2])] or args[2]
        local g = groups[main]
        if not g then Print("Group not found for: "..tostring(args[2])); return end
        local members = { g.main }
        for _, a in ipairs(g.alts) do if string.lower(a) ~= string.lower(g.main) then table.insert(members, a) end end
        PromoteGroupWithAltRules(members, tonumber(args[3]))
    elseif cmd == "setrank" and args[2] and args[3] then
        local k = args[2]
        local v = tonumber(args[3])
        if not v then Print("Invalid rank index."); return end
        GuildTools335DB.rankRules = GuildTools335DB.rankRules or {}
        GuildTools335DB.rankRules[k] = v
        Print(("Set rank rule %s = %d"):format(k, v))
    elseif cmd == "showranks" then
        ShowRankRules()
elseif cmd == "ui" then
    if CreateUI and type(CreateUI) == "function" then
        CreateUI()
    else
        Print("UI module not loaded correctly. Check UI.lua.")
    end

elseif cmd == "help" or cmd == "" then
    Print("GuildTools 3.3.5 commands:")
    Print("/gt link <alt> <main>")
    Print("/gt unlink <name>")
    Print("/gt show <name>")
    Print("/gt kickgroup <name>")
    Print("/gt promotegroup <name> <rankIndex>")
    Print("/gt setrank <Established|Member> <index>")
    Print("/gt showranks")
    Print("/gt ui - open compact roster + prune")
    else
        Print("Unknown /gt command. Type /gt help for commands.")
    end
end

-- ==============================
-- Hook roster update
-- ==============================
local fRoster = CreateFrame("Frame")
fRoster:RegisterEvent("GUILD_ROSTER_UPDATE")
fRoster:SetScript("OnEvent", function()
    if UI and UI.frame and UI.frame:IsShown() and UI.Rebuild then UI:Rebuild() end
end)

-- ==============================
-- Player login
-- ==============================
local fLogin = CreateFrame("Frame")
fLogin:RegisterEvent("PLAYER_LOGIN")
fLogin:SetScript("OnEvent", function()
    if IsInGuild() then GuildRoster() end
    Print(("Loaded v%s. Type /gt for help."):format(GuildTools335.version))
end)