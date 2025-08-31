local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff96[GT]|r "..tostring(msg))
end

-- Helper function to clear tables
local function wipe(t)
    for k in pairs(t) do
        t[k] = nil
    end
end

local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("ADDON_LOADED")
initFrame:SetScript("OnEvent", function(self, event, addon)
    if addon == "Guild-Tools" then
        GuildTools_Config = GuildTools_Config or {}
        GuildTools_Config.rankRules = GuildTools_Config.rankRules or {}
        GuildTools_Config.rankRules["Established"] = GuildTools_Config.rankRules["Established"] or 0
        GuildTools_Config.rankRules["Member"]      = GuildTools_Config.rankRules["Member"] or 0
        GuildTools_Config.altLinks = GuildTools_Config.altLinks or {} -- alt -> main
        GuildTools_Config.uiCollapsed = GuildTools_Config.uiCollapsed or {} -- ui collapsed mains

        if IsInGuild() then GuildRoster() end
        Print(("Loaded v%s. Type /gt for help."):format("0.4.0"))
    end
end)

local GuildToolsThrottleFrame = CreateFrame("Frame")
GuildToolsThrottleFrame:Hide()

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
    return (GuildTools_Config.altLinks and GuildTools_Config.altLinks[name]) or name
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
    
    -- First pass: create groups for all members
    for i = 1, n do
        local fullname = GetGuildRosterInfo(i) or ("Unknown"..i)
        local short = string.match(fullname, "^[^-]+") or fullname
        groups[short] = groups[short] or { main = short, alts = {} }
        byName[string.lower(short)] = short
    end
    
    -- Second pass: organize alts based on altLinks
    for altName, mainName in pairs(GuildTools_Config.altLinks or {}) do
        local altShort = string.match(altName, "^[^-]+") or altName
        local mainShort = string.match(mainName, "^[^-]+") or mainName
        
        -- If main exists in groups, add alt to main's group
        if groups[mainShort] then
            if altShort ~= mainShort then
                table.insert(groups[mainShort].alts, altShort)
                -- Remove alt from its own group if it was created
                if groups[altShort] and altShort ~= mainShort then
                    groups[altShort] = nil
                end
                -- Update byName to point to main
                byName[string.lower(altShort)] = mainShort
            end
        end
    end
    
    return groups, byName
end

local function ComputeAltTargetForMain(mainRankIndex)
    local established = tonumber(GuildTools_Config.rankRules["Established"]) or 7
    if established == 0 then established = 7 end
    local member = tonumber(GuildTools_Config.rankRules["Member"]) or 8
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

local function UpdateMainAltLink(altName, mainName)
    if not EnsureGuildRoster() then return end
    if not (CanGuildPromote() or CanGuildDemote()) then
        Print("Officer permissions required to link mains/alts.")
        return
    end

    local altIndex, altFull = FindMemberIndexByName(altName)
    local mainIndex, mainFull = FindMemberIndexByName(mainName)
    if not altIndex then Print("Alt not found: "..tostring(altName)); return end
    if not mainIndex then Print("Main not found: "..tostring(mainName)); return end

    -- Only update altLinks, no more guild notes
    GuildTools_Config.altLinks[altFull] = mainFull

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
    if not (CanGuildPromote() or CanGuildDemote()) then
        Print("Officer permissions required to unlink.")
        return
    end
    local idx, fullname = FindMemberIndexByName(name)
    if not idx then Print("Name not found: "..tostring(name)); return end
    
    -- Only remove from altLinks, no more guild notes
    GuildTools_Config.altLinks[fullname] = nil
    Print(("Unlinked %s"):format(fullname))
end

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

            for alt, linkedMain in pairs(GuildTools_Config.altLinks or {}) do
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

local function ShowRankRules()
    local r = GuildTools_Config.rankRules or {}
    Print(("Rank rules: Established=%s, Member=%s"):format(tostring(r.Established or "nil"), tostring(r.Member or "nil")))
end

local updateQueue = {}
local updatingNotes = false
local updateInterval = 0.3 -- seconds between updates
local elapsed = 0

local function ProcessNextUpdate(self, delta)
    if not updatingNotes then
        GuildToolsThrottleFrame:SetScript("OnUpdate", nil)
        GuildToolsThrottleFrame:Hide()
        return
    end

    elapsed = elapsed + delta
    if elapsed < updateInterval then return end
    elapsed = 0

    -- Get next queued update
    local entry = table.remove(updateQueue, 1)
    if not entry then
        updatingNotes = false
        Print("Finished adding notes to all queued members!")
        GuildToolsThrottleFrame:SetScript("OnUpdate", nil)
        GuildToolsThrottleFrame:Hide()
        GuildRoster()
        return
    end

    -- Apply note update safely
    local idx, isOfficer, note = entry.idx, entry.isOfficer, entry.note
    if idx then
        local _, _, _, _, _, _, publicNote, officerNote = GetGuildRosterInfo(idx)
        if isOfficer then
            officerNote = note .. (officerNote ~= "" and (" " .. officerNote) or "")
            GuildRosterSetOfficerNote(idx, officerNote)
        else
            publicNote = note .. (publicNote ~= "" and (" " .. publicNote) or "")
            GuildRosterSetPublicNote(idx, publicNote)
        end
    end

    Print(("Updated %s (%d remaining)..."):format(entry.name, #updateQueue))
end

local function StartProcessingUpdates()
    if updatingNotes then return end
    updatingNotes = true
    elapsed = 0
    GuildToolsThrottleFrame:SetScript("OnUpdate", ProcessNextUpdate)
    GuildToolsThrottleFrame:Show()
end

local function AddNoteToGroupOrAll(noteType, name, note)
    if not EnsureGuildRoster() then return end

    local isOfficer = string.lower(noteType) == "officer"
    local isPublic = string.lower(noteType) == "public"
    if not (isOfficer or isPublic) then
        Print("Invalid note type. Use 'Officer' or 'Public'.")
        return
    end

    local groups, byName = BuildGroups()
    local nameLower = string.lower(name)
    local targets = {}

    -- Determine targets
    if nameLower == "all" then
        for i = 1, GetNumGuildMembers() do
            local fullName = GetGuildRosterInfo(i)
            if fullName then table.insert(targets, fullName) end
        end
    else
        local main = byName[nameLower] or name
        local g = groups[main]
        if not g then
            Print("No group found for "..tostring(name))
            return
        end
        table.insert(targets, g.main)
        for _, alt in ipairs(g.alts) do
            table.insert(targets, alt)
        end
    end

    -- Queue updates instead of applying immediately
    wipe(updateQueue)
    for _, memberName in ipairs(targets) do
        local idx = FindMemberIndexByName(memberName)
        if idx then
            table.insert(updateQueue, {
                idx = idx,
                isOfficer = isOfficer,
                note = note,
                name = memberName,
            })
        end
    end

    Print(("Queued %d note updates. Processing..."):format(#updateQueue))
    StartProcessingUpdates()
end


-- ==============================
-- Slash commands handler
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
        GuildTools_Config.rankRules = GuildTools_Config.rankRules or {}
        GuildTools_Config.rankRules[k] = v
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
        Print("/gt addnote <Officer|Public> <name|all> <note>")
        Print("/gt ui - open compact roster + prune")
    elseif cmd == "addnote" and args[2] and args[3] and args[4] then
        local noteType = args[2]
        local name = args[3]
        local note = table.concat(args, " ", 4) -- everything after 3rd arg
        AddNoteToGroupOrAll(noteType, name, note)
    else
        Print("Unknown /gt command. Type /gt help for commands.")
    end
end

local rosterFrame = CreateFrame("Frame")
rosterFrame:RegisterEvent("GUILD_ROSTER_UPDATE")
rosterFrame:SetScript("OnEvent", function()
    if UI and UI.frame and UI.frame:IsShown() and UI.Rebuild then UI:Rebuild() end
end)
