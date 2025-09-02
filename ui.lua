-- UI.lua for GuildTools335 (WoW 3.3.5 compatible)
-- Full-featured UI: mains+alts grouping (officer notes), search, filter/prune, refresh.
-- Defines global CreateUI() used by Core.lua.

local ADDON_NAME = "GuildTools335"

-- -------------------------
-- Configuration: class colours
-- -------------------------
local CLASS_COLORS = {
    PRIEST   = { r = 1.00, g = 1.00, b = 1.00 }, -- White
    WARRIOR  = { r = 0.78, g = 0.61, b = 0.43 }, -- Brown
    MAGE     = { r = 0.25, g = 0.78, b = 0.92 }, -- Light Blue
    SHAMAN   = { r = 0.00, g = 0.44, b = 0.87 }, -- Dark Blue
    DRUID    = { r = 1.00, g = 0.49, b = 0.04 }, -- Orange
    ROGUE    = { r = 1.00, g = 0.96, b = 0.41 }, -- Yellow
    HUNTER   = { r = 0.67, g = 0.83, b = 0.45 }, -- Green
    PALADIN  = { r = 0.96, g = 0.55, b = 0.73 }, -- Pink
    WARLOCK  = { r = 0.58, g = 0.51, b = 0.79 }, -- Purple
}

-- -------------------------
-- Local UI state
-- -------------------------
local uiFrame, scrollFrame, contentFrame
local rows = {}            -- created UI objects (for cleanup)
local members = {}         -- temp map: shortName -> member info
local roster = {}          -- mainName -> { class, days, online, alts = {...} }
local sortedMains = {}     -- array of { main = name, data = roster[name] } sorted by days
local filterDays = 0       -- display filter (>= days). persisted in GuildTools335DB.uiPruneDays
local highlightTarget = nil -- name of main to highlight (string), cleared on refresh

-- -------------------------
-- Helpers
-- -------------------------
local function hex(n) return string.format("%02x", math.floor(n)) end
local function colorPrefixForClass(class)
    local c = CLASS_COLORS[class]
    if not c then return "|cffffffff" end
    return "|cff"..hex(c.r*255)..hex(c.g*255)..hex(c.b*255)
end

local function striprealm(name)
    if not name then return nil end
    local short = string.match(name, "^[^-]+")
    return short or name
end

local function ensureDB()
    _G.GuildTools335DB = _G.GuildTools335DB or {}
    GuildTools335DB.uiCollapsed = GuildTools335DB.uiCollapsed or {} -- [main]=true/false (true = collapsed)
    if GuildTools335DB.uiPruneDays == nil then GuildTools335DB.uiPruneDays = 0 end
    filterDays = GuildTools335DB.uiPruneDays or 0
    -- Use the same altLinks from main config
    if not GuildTools_Config then GuildTools_Config = {} end
    if not GuildTools_Config.altLinks then GuildTools_Config.altLinks = {} end
end

-- compute offline days from GetGuildRosterLastOnline (years, months, days, hours)
local function offlineDaysFromIndex(i, onlineFlag)
    if onlineFlag then return 0 end
    local y, m, d, h = GetGuildRosterLastOnline(i)
    if not y and not m and not d then
        return 9999
    end
    local days = 0
    if y then days = days + (y * 365) end
    if m then days = days + (m * 30) end
    if d then days = days + d end
    return days
end



-- clear created UI rows
local function clearRows()
    for _, o in ipairs(rows) do
        if o and o.Hide then o:Hide() end
    end
    wipe(rows)
end
local function addRow(o) table.insert(rows, o) end

-- -------------------------
-- Build the members map (single pass)
-- -------------------------
local function buildMembers()
    wipe(members)
    if not IsInGuild() then return end
    GuildRoster() -- request fresh data; returns cached immediately usually

    local n = GetNumGuildMembers()
    for i = 1, n do
        local fullName, rankName, rankIndex, level, classLocalized, zone, publicNote, officerNote, online, _, classFile = GetGuildRosterInfo(i)
        if fullName then
            local short = striprealm(fullName)
            local classTag = (classFile and string.upper(classFile)) or (classLocalized and string.upper(classLocalized)) or "PRIEST"
            local days = offlineDaysFromIndex(i, online)

            local mainName = short -- default
            -- check stored altLinks mapping (fullName or short)
            if GuildTools_Config and GuildTools_Config.altLinks then
                local link = GuildTools_Config.altLinks[fullName] or GuildTools_Config.altLinks[short]
                if link and link ~= "" then mainName = striprealm(link) end
            end

            members[short] = {
                short = short,
                fullName = fullName,
                class = classTag,
                days = days,
                online = (online and true) or false,
                main = mainName,
                rosterIndex = i,
            }
        end
    end
end

-- -------------------------
-- Build roster buckets (mains with alts). Alts won't appear as mains.
-- -------------------------
local function buildRoster()
    ensureDB()
    wipe(roster); wipe(sortedMains)

    buildMembers()

    -- create buckets for mains
    for name, info in pairs(members) do
        local main = info.main or name
        if not roster[main] then
            roster[main] = { class = nil, days = 9999, online = false, alts = {} }
        end
        if main == name then
            roster[main].class = info.class
            roster[main].days = info.days
            roster[main].online = info.online
        else
            table.insert(roster[main].alts, { name = name, class = info.class, days = info.days, online = info.online })
        end
    end

    -- If a main didn't exist as a member (linked to missing main), try to infer from alts
    for mainName, bucket in pairs(roster) do
        if not bucket.class then
            if bucket.alts and #bucket.alts > 0 then
                bucket.class = bucket.alts[1].class
                bucket.days = bucket.alts[1].days
            else
                bucket.class = "PRIEST"; bucket.days = 9999
            end
        end
        table.insert(sortedMains, { main = mainName, data = bucket })
    end

    -- sort by most recent activity (fewest days first), then alphabetically by main name
    table.sort(sortedMains, function(a, b)
        local ad = a.data.days or 9999
        local bd = b.data.days or 9999
        if ad ~= bd then
            return ad < bd
        end
        return string.lower(a.main) < string.lower(b.main)
    end)
end

-- -------------------------
-- Draw roster into contentFrame
-- -------------------------
-- We'll record yOffsets of each main entry so search+scroll can jump to them.
local mainYOffsets = {} -- mainName -> y offset (negative)
local contentHeight = 0

local function drawRoster()
    if not contentFrame then return end
    clearRows()
    wipe(mainYOffsets)

    local y = -6
    local lineH = 18
    local collapsedDB = GuildTools335DB.uiCollapsed or {}

    for _, entry in ipairs(sortedMains) do
        local mainName = entry.main
        local data = entry.data

        -- filter: only show groups if any member meets filterDays (when filterDays>0)
        local showGroup = true
        if filterDays and filterDays > 0 then
            showGroup = false
            if (data.days or 0) >= filterDays then showGroup = true end
            if not showGroup and data.alts then
                for _, a in ipairs(data.alts) do
                    if (a.days or 0) >= filterDays then showGroup = true; break end
                end
            end
        end

        if showGroup then
            local collapsed = true
            if collapsedDB[mainName] ~= nil then collapsed = collapsedDB[mainName] end

            -- local copy so closure picks correct main
            local mainLocal = mainName

            -- toggle button
            local toggle = CreateFrame("Button", nil, contentFrame, "UIPanelButtonTemplate")
            toggle:SetSize(18, 18)
            toggle:SetPoint("TOPLEFT", 8, y)
            toggle:SetText(collapsed and "+" or "-")
            toggle:SetScript("OnClick", function()
                GuildTools335DB.uiCollapsed = GuildTools335DB.uiCollapsed or {}
                GuildTools335DB.uiCollapsed[mainLocal] = not collapsed
                buildRoster()
                drawRoster()
            end)
            addRow(toggle)

            -- main fontstring (class colored)
            local fs = contentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            fs:SetPoint("TOPLEFT", toggle, "TOPRIGHT", 6, -2)
            local cp = colorPrefixForClass(data.class)
            local label = string.format("%s%s|r (%dd)", cp, mainName, data.days or 0)
            if highlightTarget and string.lower(highlightTarget) == string.lower(mainName) then
                label = "|cffFFFF00> "..label.."|r"
            end
            fs:SetText(label)
            addRow(fs)

            mainYOffsets[mainName] = math.abs(y)

            y = y - lineH

            -- alts if expanded
            if not collapsed and data.alts and #data.alts > 0 then
                table.sort(data.alts, function(a,b)
                    local ad = a.days or 9999
                    local bd = b.days or 9999
                    if ad ~= bd then
                        return ad < bd
                    end
                    return string.lower(a.name) < string.lower(b.name)
                end)
                for _, alt in ipairs(data.alts) do
                    local afs = contentFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                    afs:SetPoint("TOPLEFT", 34, y - 2)
                    local ap = colorPrefixForClass(alt.class)
                    local text = string.format("%s↳ %s|r (%dd)", ap, alt.name, alt.days or 0)
                    if highlightTarget and string.lower(highlightTarget) == string.lower(alt.name) then
                        text = "|cffFFFF00> "..text.."|r"
                    end
                    afs:SetText(text)
                    addRow(afs)
                    y = y - (lineH - 4)
                end
            end
        end
    end

    contentHeight = math.max(1, math.abs(y) + 12)
    contentFrame:SetHeight(contentHeight)
    -- clear single-use highlight after draw (persist until next refresh)
    highlightTarget = nil
end

-- -------------------------
-- Scroll helper: scroll to a main
-- -------------------------
local function scrollToMain(mainName)
    if not mainYOffsets or not mainYOffsets[mainName] then return end
    local y = mainYOffsets[mainName] or 0
    if scrollFrame and scrollFrame.SetVerticalScroll then
        -- some frames use top 0; we want to move so item appears near top
        local scroll = math.max(0, y - 20)
        scrollFrame:SetVerticalScroll(scroll)
    end
end

-- -------------------------
-- Search logic (case-insensitive)
-- If query matches an alt, we expand that main and highlight it.
-- -------------------------
local function findMainForQuery(q)
    if not q or q == "" then return nil end
    local ql = string.lower(q)

    -- first look for exact main match
    for _, entry in ipairs(sortedMains) do
        if string.lower(entry.main) == ql then
            return entry.main
        end
    end

    -- then look through alts
    for _, entry in ipairs(sortedMains) do
        for _, alt in ipairs(entry.data.alts) do
            if string.lower(alt.name) == ql then
                return entry.main, alt.name
            end
        end
    end

    return nil
end

-- -------------------------
-- Prune (kick) workflow: display-only filter, then optional kick
-- -------------------------
local function kickFiltered(daysThreshold)
    if not IsInGuild() then return end
    GuildRoster()
    local n = GetNumGuildMembers()
    local toKick = {}
    for i = 1, n do
        local fullName, _, _, _, _, _, _, _, online, _, _, _, _, _, _, _, _, lastOnline = GetGuildRosterInfo(i)
        if fullName then
            local short = striprealm(fullName)
            local days = lastOnline or 0
            local isOnline = online and true or false
            if not isOnline and days >= daysThreshold then
                table.insert(toKick, short)
            end
        end
    end

    if #toKick == 0 then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff96[GT]|r No members found matching prune criteria.")
        return
    end

    -- Confirm kick list (double-confirm)
    StaticPopupDialogs["GT_PRUNE_CONFIRM"] = {
        text = "Kick the following members?\n\n%s\n\nThis action is irreversible. Confirm to proceed.",
        button1 = "Kick",
        button2 = "Cancel",
        OnAccept = function(self)
            for _, name in ipairs(toKick) do
                GuildUninvite(name)
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ff96[GT]|r Kicked "..name)
            end
        end,
        timeout = 0, whileDead = true, hideOnEscape = true,
        preferredIndex = 3,
    }
    -- inject member list into text (truncate if long)
    local list = table.concat(toKick, ", ")
    if #list > 400 then list = string.sub(list, 1, 400) .. "..." end
    StaticPopup_Show("GT_PRUNE_CONFIRM", list)
end

-- -------------------------
-- UI creation
-- -------------------------
function CreateUI()
    ensureDB()

    if uiFrame and uiFrame:IsShown() then
        -- refresh only
        buildRoster()
        drawRoster()
        return
    end

    if not uiFrame then
        -- main frame
        uiFrame = CreateFrame("Frame", "GuildTools335_UIFrame", UIParent)
        uiFrame:SetSize(560, 560)
        uiFrame:SetPoint("CENTER")
        uiFrame:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 10, right = 10, top = 10, bottom = 10 },
        })
        uiFrame:SetBackdropColor(0,0,0,1)
        uiFrame:SetMovable(true)
        uiFrame:EnableMouse(true)
        uiFrame:RegisterForDrag("LeftButton")
        uiFrame:SetScript("OnDragStart", uiFrame.StartMoving)
        uiFrame:SetScript("OnDragStop", uiFrame.StopMovingOrSizing)

        -- title
        local title = uiFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
        title:SetPoint("TOP", 0, -8)
        title:SetText(ADDON_NAME)

        -- close
        local close = CreateFrame("Button", nil, uiFrame, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", -6, -6)

        -- Search box label
        local searchLabel = uiFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        searchLabel:SetPoint("TOPLEFT", 14, -36)
        searchLabel:SetText("Search (main or alt):")

        -- Search EditBox
        local searchBox = CreateFrame("EditBox", "GuildTools335SearchBox", uiFrame, "InputBoxTemplate")
        searchBox:SetSize(220, 20)
        searchBox:SetPoint("TOPLEFT", 14, -52)
        searchBox:SetAutoFocus(false)

        -- Search button
        local searchBtn = CreateFrame("Button", nil, uiFrame, "UIPanelButtonTemplate")
        searchBtn:SetSize(80, 20)
        searchBtn:SetPoint("LEFT", searchBox, "RIGHT", 8, 0)
        searchBtn:SetText("Search")

        -- Refresh button beside search
        local refreshBtn = CreateFrame("Button", nil, uiFrame, "UIPanelButtonTemplate")
        refreshBtn:SetSize(100, 20)
        refreshBtn:SetPoint("LEFT", searchBtn, "RIGHT", 8, 0)
        refreshBtn:SetText("Update Roster")

        -- ScrollFrame and content child
        scrollFrame = CreateFrame("ScrollFrame", "GuildTools335ScrollFrame", uiFrame, "UIPanelScrollFrameTemplate")
        scrollFrame:SetPoint("TOPLEFT", 14, -82)
        scrollFrame:SetPoint("BOTTOMRIGHT", -14, 64)

        contentFrame = CreateFrame("Frame", "GuildTools335Content", scrollFrame)
        contentFrame:SetSize(1, 1)
        scrollFrame:SetScrollChild(contentFrame)

        -- Filter/Prune button
        local pruneBtn = CreateFrame("Button", nil, uiFrame, "UIPanelButtonTemplate")
        pruneBtn:SetSize(140, 24)
        pruneBtn:SetPoint("BOTTOMRIGHT", -16, 16)
        local function updatePruneText()
            if filterDays and filterDays > 0 then
                pruneBtn:SetText("Filter: ≥ "..filterDays.."d")
            else
                pruneBtn:SetText("Prune / Filter")
            end
        end
        updatePruneText()

        -- Kick filtered button (dangerous) - separate confirm
        local kickBtn = CreateFrame("Button", nil, uiFrame, "UIPanelButtonTemplate")
        kickBtn:SetSize(140, 24)
        kickBtn:SetPoint("BOTTOMLEFT", 16, 16)
        kickBtn:SetText("Kick Filtered")

        -- Button behaviors
        refreshBtn:SetScript("OnClick", function()
            GuildRoster()
            buildRoster()
            drawRoster()
        end)

        searchBtn:SetScript("OnClick", function()
            local q = searchBox:GetText() or ""
            q = strtrim(q)
            if q == "" then
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ff96[GT]|r Enter a name to search.")
                return
            end
            local main, alt = findMainForQuery(q)
            if main then
                -- ensure main expanded
                GuildTools335DB.uiCollapsed = GuildTools335DB.uiCollapsed or {}
                GuildTools335DB.uiCollapsed[main] = false
                highlightTarget = alt or main
                buildRoster()
                drawRoster()
                scrollToMain(main)
            else
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ff96[GT]|r No match for '"..q.."'")
            end
        end)

        searchBox:SetScript("OnEnterPressed", function(self)
            searchBtn:Click()
            self:ClearFocus()
        end)

        pruneBtn:SetScript("OnClick", function()
            StaticPopupDialogs["GT_PRUNE_FILTER"] = {
                text = "Show only members inactive for ≥ how many days? (0 to show all).",
                button1 = "Apply",
                button2 = "Cancel",
                hasEditBox = true,
                maxLetters = 4,
                OnShow = function(self) self.editBox:SetText(tostring(filterDays or 0)); self.editBox:SetFocus(); self.editBox:HighlightText() end,
                OnAccept = function(self)
                    local v = tonumber(self.editBox:GetText()) or 0
                    if v < 0 then v = 0 end
                    filterDays = math.floor(v)
                    GuildTools335DB.uiPruneDays = filterDays
                    updatePruneText()
                    buildRoster()
                    drawRoster()
                end,
                EditBoxOnEnterPressed = function(self) local p=self:GetParent(); p.button1:Click() end,
                timeout = 0, whileDead = true, hideOnEscape = true,
            }
            StaticPopup_Show("GT_PRUNE_FILTER")
        end)

        kickBtn:SetScript("OnClick", function()
            if not filterDays or filterDays <= 0 then
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ff96[GT]|r Set a filter (Prune/Filter) first to restrict who will be kicked.")
                return
            end
            -- Build list of filtered members (offline >= filterDays)
            GuildRoster()
            local n = GetNumGuildMembers()
            local toKick = {}
            for i = 1, n do
                local fullName, _, _, _, _, _, _, _, online, _, _, _, _, _, _, _, _, lastOnline = GetGuildRosterInfo(i)
                if fullName then
                    local short = striprealm(fullName)
                    local days = lastOnline or 0
                    if (not online) and days >= filterDays then
                        table.insert(toKick, short)
                    end
                end
            end
            if #toKick == 0 then
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ff96[GT]|r No members match the current filter.")
                return
            end
            -- confirmation with list preview
            local preview = table.concat(toKick, ", ")
            if #preview > 400 then preview = string.sub(preview, 1, 400) .. "..." end
            StaticPopupDialogs["GT_PRUNE_KICK_CONFIRM"] = {
                text = "Kick the following members?\n\n%s\n\nThis action is irreversible. Confirm to proceed.",
                button1 = "Kick",
                button2 = "Cancel",
                OnAccept = function(self)
                    for _,n in ipairs(toKick) do
                        GuildUninvite(n)
                        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff96[GT]|r Kicked "..n)
                    end
                end,
                timeout = 0, whileDead = true, hideOnEscape = true,
                preferredIndex = 3,
            }
            StaticPopup_Show("GT_PRUNE_KICK_CONFIRM", preview)
        end)
    end

    -- initial populate + show
    buildRoster()
    drawRoster()
    uiFrame:Show()
end

-- End of UI.lua
