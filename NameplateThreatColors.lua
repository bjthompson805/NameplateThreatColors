-- Nameplate "Aggro Display -> Health Bar Color" tweaks (Blizzard_NamePlates / CompactUnitFrame_UpdateHealthColor).
--
-- Blizzard's behavior depends on your assigned group role:
--   Tank:   uses UnitThreatLeadSituation. Holding aggro with a safe lead (status 0) gets NO threat color,
--           so the plate stays plain hostile red. Slipping = GAINING_THREAT_COLOR, not top threat = HIGH_THREAT_COLOR.
--   Others: uses UnitThreatSituation. Mob on you = HIGH_THREAT_COLOR, close to pulling = GAINING_THREAT_COLOR.
--
-- This addon paints the plate SECURE_COLOR when you are a Tank and the mob is on you with a safe lead.
-- Every other state keeps Blizzard's colors.
--
-- Design note: calling UnitThreatLeadSituation / UnitThreatSituation from inside a hook on Blizzard's
-- CompactUnitFrame_UpdateHealthColor caused "Can't measure restricted regions" errors in the nameplate aura
-- layout (taint). So the threat calls are made ONLY from this addon's own event handler, and the hook just
-- reads the cached result (secureUnits) and paints. Keep it that way.

local ADDON_NAME = ...

local SECURE_COLOR = { 0, 1, 0 }

-- Toggled from Options -> AddOns -> Nameplate Threat Colors, and saved per account in NameplateThreatColorsDB.
--   secureColor: paint the plate SECURE_COLOR while you tank the mob with a safe lead.
--   showLevel:   prefix enemy nameplate names with the mob's level ("5 Boar", elite "5+ Boar", skull "?? Boar"),
--                colored by Blizzard's creature difficulty colors (grey, green, yellow, orange, or red).
local DEFAULTS = {
    secureColor = true,
    showLevel   = true,
}
local settings = DEFAULTS -- replaced by the saved table on ADDON_LOADED

-- Optional in-place overrides of Blizzard's colors (they must be modified, not replaced). nil = keep default.
-- Defaults: HIGH_THREAT_COLOR 1, 0.27, 0.04 / GAINING_THREAT_COLOR 0.97, 0.71, 0
local COLORS = {
    HIGH_THREAT_COLOR    = nil,
    GAINING_THREAT_COLOR = nil,
}

local function ApplyColors()
    for name, rgb in pairs(COLORS) do
        local color = _G[name]
        if color and color.SetRGB then
            color:SetRGB(rgb[1], rgb[2], rgb[3])
        end
    end
end

local secureUnits = {} -- ["nameplateN"] = true while you're a Tank holding that mob with a safe lead
local reportedError = false

local function ReportError(err)
    if not reportedError then
        reportedError = true
        print("|cffff8800NameplateThreatColors:|r " .. tostring(err))
    end
end

-- Runs from this addon's own event handler, never from inside Blizzard's call stack.
local function Recompute()
    for unit in pairs(secureUnits) do
        secureUnits[unit] = nil
    end
    if not settings.secureColor then return end
    if not UnitInParty("player") then return end -- Blizzard ignores threat outside a group
    if not (PlayerUtil and PlayerUtil.IsPlayerEffectivelyTank()) then return end

    for i = 1, 40 do
        local unit = "nameplate" .. i
        if UnitExists(unit) and UnitCanAttack("player", unit) then
            -- Lead 1/2 = slipping and 3 = not top threat: Blizzard colors those. Only a safe lead (0) gets green.
            if UnitThreatLeadSituation("player", unit) == 0 and UnitThreatSituation("player", unit) == 3 then
                secureUnits[unit] = true
            end
        end
    end
end

local function PaintSecureThreat(frame)
    if not settings.secureColor then return end
    if not frame.displayThreatHealthBarColor then return end -- "Health Bar Color" option off, or friendly plate
    local optionTable = frame.optionTable
    if not (optionTable and optionTable.usePlayerForAggroHighlightThreat) then return end -- enemy nameplates only
    if not secureUnits[frame.displayedUnit] then return end

    frame.healthBar:SetStatusBarColor(SECURE_COLOR[1], SECURE_COLOR[2], SECURE_COLOR[3])
end

hooksecurefunc("CompactUnitFrame_UpdateHealthColor", function(frame)
    local ok, err = pcall(PaintSecureThreat, frame)
    if not ok then ReportError(err) end
end)

-- Level text follows the same taint rule as threat: unit API calls happen only in the event handler,
-- which caches the finished string per unit. The name hook just reads the cache and sets text.
local levelTexts = {}                           -- ["nameplateN"] = "|cffRRGGBB5+|r"
local namesWritten = setmetatable({}, { __mode = "k" }) -- [frame] = { base = "Boar", full = "5 Boar" }

local ELITE = { elite = true, rareelite = true, worldboss = true }
local FALLBACK_COLOR = { r = 1, g = 0.1, b = 0.1 }

local function BuildLevelText(unit)
    local level = UnitLevel(unit)
    local text, color
    if not level or level <= 0 then -- -1 = skull / too high to know
        text = "??"
        color = QuestDifficultyColors and QuestDifficultyColors.impossible
    else
        text = ELITE[UnitClassification(unit)] and (level .. "+") or tostring(level)
        if GetCreatureDifficultyColor then
            color = GetCreatureDifficultyColor(level)
        elseif GetQuestDifficultyColor then
            color = GetQuestDifficultyColor(level)
        end
    end
    color = color or FALLBACK_COLOR
    return string.format("|cff%02x%02x%02x%s|r",
        math.floor(color.r * 255 + 0.5), math.floor(color.g * 255 + 0.5), math.floor(color.b * 255 + 0.5), text)
end

local function PaintLevel(frame)
    if not settings.showLevel then return end
    if frame.IsForbidden and frame:IsForbidden() then return end
    local levelText = levelTexts[frame.displayedUnit or frame.unit]
    local nameText = frame.name
    if not (levelText and nameText and nameText:IsShown()) then return end

    local current = nameText:GetText()
    if not current or current == "" then return end
    -- If the text is still what we last wrote, rebuild from the stored base name so the prefix never stacks.
    local written = namesWritten[frame]
    local base = (written and current == written.full) and written.base or current
    local full = levelText .. " " .. base
    if full ~= current then
        nameText:SetText(full)
    end
    namesWritten[frame] = { base = base, full = full }
end

local function UpdateLevel(unit)
    if not settings.showLevel then return end
    if not (unit and unit:find("^nameplate")) then return end
    if UnitExists(unit) and UnitCanAttack("player", unit) then
        levelTexts[unit] = BuildLevelText(unit)
    else
        levelTexts[unit] = nil
    end
    -- Blizzard may have already drawn the name before this handler ran, so paint the plate directly too.
    local plate = C_NamePlate.GetNamePlateForUnit(unit)
    if plate and plate.UnitFrame then
        PaintLevel(plate.UnitFrame)
    end
end

local function UpdateAllLevels()
    for i = 1, 40 do
        UpdateLevel("nameplate" .. i)
    end
end

if CompactUnitFrame_UpdateName then
    hooksecurefunc("CompactUnitFrame_UpdateName", function(frame)
        local ok, err = pcall(PaintLevel, frame)
        if not ok then ReportError(err) end
    end)
end

local function PlateFrame(unit)
    local plate = C_NamePlate.GetNamePlateForUnit(unit)
    return plate and plate.UnitFrame
end

-- Toggles from the options panel. Turning a feature off also undoes what is already on screen,
-- instead of leaving it until Blizzard's next redraw of that plate.
local function SetSecureColor(on)
    settings.secureColor = on
    if on then
        Recompute()
        for unit in pairs(secureUnits) do
            local frame = PlateFrame(unit)
            if frame then PaintSecureThreat(frame) end
        end
    else
        -- Blizzard caches the color it last set in healthBar.r/g/b, and our green bypasses that cache,
        -- so it still holds Blizzard's color. Without it, the plate fixes itself on Blizzard's next recolor.
        for unit in pairs(secureUnits) do
            local frame = PlateFrame(unit)
            local bar = frame and frame.healthBar
            if bar and bar.r then
                bar:SetStatusBarColor(bar.r, bar.g, bar.b)
            end
        end
        Recompute() -- clears secureUnits
    end
end

local function SetShowLevel(on)
    settings.showLevel = on
    if on then
        UpdateAllLevels()
    else
        for frame, written in pairs(namesWritten) do
            if frame.name and frame.name:GetText() == written.full then
                frame.name:SetText(written.base)
            end
            namesWritten[frame] = nil
        end
        for unit in pairs(levelTexts) do
            levelTexts[unit] = nil
        end
    end
end

local function LoadSettings()
    if type(NameplateThreatColorsDB) ~= "table" then
        NameplateThreatColorsDB = {}
    end
    for key, value in pairs(DEFAULTS) do
        if NameplateThreatColorsDB[key] == nil then
            NameplateThreatColorsDB[key] = value
        end
    end
    settings = NameplateThreatColorsDB
end

ApplyColors()

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("GROUP_ROSTER_UPDATE")
events:RegisterEvent("PLAYER_ROLES_ASSIGNED")
events:RegisterEvent("NAME_PLATE_UNIT_ADDED")
events:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
events:RegisterEvent("UNIT_THREAT_SITUATION_UPDATE")
events:RegisterEvent("UNIT_THREAT_LIST_UPDATE")
events:RegisterEvent("UNIT_LEVEL") -- also fires for "player" on level up, which changes every color
pcall(events.RegisterEvent, events, "UNIT_CLASSIFICATION_CHANGED") -- may not exist on this client

local LEVEL_ONLY_EVENTS = { UNIT_LEVEL = true, UNIT_CLASSIFICATION_CHANGED = true }

local function HandleLevels(event, unit)
    if not settings.showLevel then return end
    if event == "NAME_PLATE_UNIT_REMOVED" then
        levelTexts[unit] = nil
    elseif event == "NAME_PLATE_UNIT_ADDED" or LEVEL_ONLY_EVENTS[event] then
        if unit == "player" then
            UpdateAllLevels()
        else
            UpdateLevel(unit)
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        UpdateAllLevels()
    end
end

events:SetScript("OnEvent", function(_, event, unit)
    if event == "ADDON_LOADED" then
        if unit == ADDON_NAME then -- first arg is the addon name for this event
            LoadSettings()
            events:UnregisterEvent("ADDON_LOADED")
        end
        return
    end
    if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        ApplyColors()
    end
    local ok, err = pcall(HandleLevels, event, unit)
    if not ok then ReportError(err) end
    if LEVEL_ONLY_EVENTS[event] then return end

    ok, err = pcall(Recompute)
    if not ok then ReportError(err) end
end)

-- Options -> AddOns panel, same canvas-layout pattern as the other addons installed on this client.
local function BuildOptionsPanel()
    local panel = CreateFrame("Frame")
    panel.name = "Nameplate Threat Colors"

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText(panel.name)

    local checkboxes = {}
    local anchor, offsetX, offsetY = title, 0, -16

    local function AddCheckbox(key, label, description, setter)
        local checkbox = CreateFrame("CheckButton", "NameplateThreatColors_" .. key, panel, "UICheckButtonTemplate")
        checkbox:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", offsetX, offsetY)
        checkbox.settingKey = key
        local text = checkbox.Text or checkbox.text or _G[checkbox:GetName() .. "Text"]
        if text then
            text:SetFontObject("GameFontNormal")
            text:SetText(label)
        end

        local desc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        desc:SetPoint("TOPLEFT", checkbox, "BOTTOMLEFT", 30, 2)
        desc:SetWidth(540)
        desc:SetJustifyH("LEFT")
        desc:SetText(description)

        checkbox:SetScript("OnClick", function(self)
            local ok, err = pcall(setter, self:GetChecked() and true or false)
            if not ok then ReportError(err) end
        end)
        checkboxes[#checkboxes + 1] = checkbox
        anchor, offsetX, offsetY = desc, -30, -16
    end

    AddCheckbox("secureColor", "Green health bar while you hold aggro as a tank",
        "Paints an enemy nameplate green while you are in a group, assigned the Tank role, and the mob is on you "
        .. "with a safe threat lead. Needs Interface > Nameplates > Aggro Display > Health Bar Color turned on.",
        SetSecureColor)
    AddCheckbox("showLevel", "Show level before enemy names",
        "Adds the mob's level in front of its name, like \"5 Boar\", with \"+\" for elites and \"??\" when the level "
        .. "is unknown. The level is colored grey, green, yellow, orange, or red by difficulty.",
        SetShowLevel)

    panel:SetScript("OnShow", function()
        for _, checkbox in ipairs(checkboxes) do
            checkbox:SetChecked(settings[checkbox.settingKey])
        end
    end)

    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        Settings.RegisterAddOnCategory(Settings.RegisterCanvasLayoutCategory(panel, panel.name))
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
end

local ok, err = pcall(BuildOptionsPanel)
if not ok then ReportError(err) end
