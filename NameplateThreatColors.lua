-- Nameplate "Aggro Display -> Health Bar Color" tweaks (Blizzard_NamePlates / CompactUnitFrame_UpdateHealthColor).
--
-- Blizzard's behavior depends on your assigned group role:
--   Tank:   uses UnitThreatLeadSituation. Holding aggro with a safe lead (status 0) gets NO threat color,
--           so the plate stays plain hostile red. Slipping = GAINING_THREAT_COLOR, not top threat = HIGH_THREAT_COLOR.
--   Others: uses UnitThreatSituation. Mob on you = HIGH_THREAT_COLOR, close to pulling = GAINING_THREAT_COLOR.
--
-- This addon replaces those colors with a Low / Medium / High threat color per role (like Threat Plates),
-- each chosen in the options panel. The defaults match Blizzard's, except that the two "all is well" states,
-- Tank High and DPS/Healing Low, are green instead of uncolored.
--
-- Design note: calling UnitThreatLeadSituation / UnitThreatSituation from inside a hook on Blizzard's
-- CompactUnitFrame_UpdateHealthColor caused "Can't measure restricted regions" errors in the nameplate aura
-- layout (taint). So the threat calls are made ONLY from this addon's own event handler, and the health bar's
-- hook just reads the cached result (threatColors) and paints. Keep it that way. The hooks are on each plate's
-- own widgets (see HookPlate), not on Blizzard's global functions, which also run for forbidden nameplates.

local ADDON_NAME = ...

local function BlizzardColor(name, r, g, b)
    local color = _G[name]
    if color and color.GetRGB then
        return { color:GetRGB() }
    end
    return { r, g, b }
end

local GREEN   = { 0, 1, 0 }
local GAINING = BlizzardColor("GAINING_THREAT_COLOR", 0.97, 0.71, 0)
local HIGH    = BlizzardColor("HIGH_THREAT_COLOR", 1, 0.27, 0.04)

-- Toggled from Options -> AddOns -> Nameplate Threat Colors, and saved per account in NameplateThreatColorsDB.
--   threatColor: color enemy health bars by your threat, using colors[role][level].
--   showLevel:   prefix enemy nameplate names with the mob's level ("5 Boar", elite "5+ Boar", skull "?? Boar"),
--                colored by Blizzard's creature difficulty colors (grey, green, yellow, orange, or red).
local DEFAULTS = {
    threatColor = true,
    showLevel   = true,
    colors = {
        tank = { low = HIGH,  medium = GAINING, high = GREEN }, -- low = someone else has the mob
        dps  = { low = GREEN, medium = GAINING, high = HIGH },  -- high = the mob is on you
    },
}
local settings = DEFAULTS -- replaced by the saved table on ADDON_LOADED

local threatColors = {} -- ["nameplateN"] = { r, g, b } while this addon colors that plate
local reportedError = false

local function ReportError(err)
    if not reportedError then
        reportedError = true
        print("|cffff8800NameplateThreatColors:|r " .. tostring(err))
    end
end

local function PlateFrame(unit)
    local plate = C_NamePlate.GetNamePlateForUnit(unit)
    local frame = plate and plate.UnitFrame
    if frame and not (frame.IsForbidden and frame:IsForbidden()) then
        return frame
    end
end

-- Same threat states Blizzard colors, named the way Threat Plates names them. nil = leave Blizzard's color.
local function ThreatLevel(unit, isTank)
    local status = UnitThreatSituation("player", unit)
    if status == nil then return nil end -- not on this mob's threat list
    if isTank then
        local lead = UnitThreatLeadSituation("player", unit)
        if lead == 3 then return "low" end                     -- not top threat
        if lead == 1 or lead == 2 then return "medium" end     -- lead is slipping
        if lead == 0 and status == 3 then return "high" end    -- on you with a safe lead
        return nil
    end
    if status >= 2 then return "high" end   -- the mob is on you
    if status == 1 then return "medium" end -- close to pulling it
    return "low"
end

local blizzardColors = setmetatable({}, { __mode = "k" }) -- [healthBar] = { r, g, b } Blizzard last set
local painting = false -- true while this addon sets a bar color, so the bar's hook ignores it

local function SetBarColor(bar, r, g, b)
    painting = true
    local ok, err = pcall(bar.SetStatusBarColor, bar, r, g, b)
    painting = false
    if not ok then error(err, 0) end
end

local function PaintThreat(frame)
    if not frame.displayThreatHealthBarColor then return end -- "Health Bar Color" option off, or friendly plate
    local optionTable = frame.optionTable
    if not (optionTable and optionTable.usePlayerForAggroHighlightThreat) then return end -- enemy nameplates only
    local color = threatColors[frame.displayedUnit]
    if not color then return end

    SetBarColor(frame.healthBar, color[1], color[2], color[3])
end

-- Puts back the last color Blizzard set, which the bar's hook recorded. Blizzard compares against the bar's
-- actual color before recoloring, so a plate without a recorded color fixes itself on Blizzard's next recolor.
local function RestoreBlizzardColor(frame)
    local bar = frame.healthBar
    local color = bar and blizzardColors[bar]
    if color then
        SetBarColor(bar, color[1], color[2], color[3])
    end
end

-- Runs from this addon's own event handler, never from inside Blizzard's call stack.
local function Recompute()
    local previous = threatColors
    threatColors = {}

    if settings.threatColor and UnitInParty("player") then -- Blizzard ignores threat outside a group
        local isTank = PlayerUtil and PlayerUtil.IsPlayerEffectivelyTank() or false
        local colors = isTank and settings.colors.tank or settings.colors.dps
        for i = 1, 40 do
            local unit = "nameplate" .. i
            if UnitExists(unit) and UnitCanAttack("player", unit) then
                local level = ThreatLevel(unit, isTank)
                if level then
                    threatColors[unit] = colors[level]
                end
            end
        end
    end

    -- Paint changes now instead of waiting for Blizzard's next redraw, and hand back plates we stopped coloring.
    for unit, color in pairs(threatColors) do
        if previous[unit] ~= color then
            local frame = PlateFrame(unit)
            if frame then PaintThreat(frame) end
        end
    end
    for unit in pairs(previous) do
        if not threatColors[unit] then
            local frame = PlateFrame(unit)
            if frame then RestoreBlizzardColor(frame) end
        end
    end
end

local function RepaintThreat()
    for unit in pairs(threatColors) do
        local frame = PlateFrame(unit)
        if frame then PaintThreat(frame) end
    end
end

-- Level text follows the same taint rule as threat: unit API calls happen only in the event handler,
-- which caches the finished string per unit.
--
-- The level goes into Blizzard's name text ("5 Boar"), but never while Blizzard's own code is running.
-- A layout change made by addon code inside the nameplate (new name text, or a label anchored to it that
-- changed width) broke Blizzard's next aura layout on that plate, with "Can't measure restricted regions"
-- (taint), whenever that layout ran before the game had recalculated the plate. Aura layouts run during
-- event handling, often right after Blizzard sets the name. So name changes are queued and applied from an
-- OnUpdate script, which runs after event handling and before the frame is drawn, and only when the text
-- actually differs.
local levelTexts = {}                                   -- ["nameplateN"] = "|cffRRGGBB5+|r"
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

local writingName = false -- true while this addon sets a name, so the name's hook ignores it

-- Puts the level in front of the name, or takes it back out when there is no level to show.
-- Called from FlushNames (the OnUpdate below), or from the name hook only after this frame's OnUpdate pass.
-- It does not require the name to be shown: the hook runs inside Blizzard's update, before Blizzard shows it.
local function ApplyName(frame)
    if frame.IsForbidden and frame:IsForbidden() then return end
    local nameText = frame.name
    if not nameText then return end

    local current = nameText:GetText()
    if current == nil or current == "" or (issecretvalue and issecretvalue(current)) then return end
    -- If the text is still what we last wrote, rebuild from the stored base name so the prefix never stacks.
    local written = namesWritten[frame]
    local base = (written and current == written.full) and written.base or current
    local levelText = settings.showLevel and levelTexts[frame.displayedUnit or frame.unit]
    local wanted = levelText and (levelText .. " " .. base) or base

    if wanted ~= current then -- an unchanged text must not be set again: every change is a layout change
        writingName = true
        local ok, err = pcall(nameText.SetText, nameText, wanted)
        writingName = false
        if not ok then error(err, 0) end
    end
    namesWritten[frame] = levelText and { base = base, full = wanted } or nil
end

local pendingNames = {} -- [frame] = true, applied on the next FlushNames

local function FlushNames()
    for frame in pairs(pendingNames) do
        pendingNames[frame] = nil
        local ok, err = pcall(ApplyName, frame)
        if not ok then ReportError(err) end
    end
end

-- OnUpdate runs later in the same frame, after event handling and before the frame is drawn. A zero-delay
-- C_Timer runs a frame later instead, which showed the plain name for one frame each time Blizzard reset it
-- (UNIT_THREAT_LIST_UPDATE resets it on every hit), so the level flickered.
local lastUpdateTime -- GetTime() of this frame once the OnUpdate pass has run; GetTime() is fixed within a frame
local flusher = CreateFrame("Frame")
flusher:SetScript("OnUpdate", function()
    lastUpdateTime = GetTime()
    FlushNames()
end)

local function QueueName(frame)
    pendingNames[frame] = true
end

-- A reset that comes after this frame's OnUpdate pass (mouseover: UPDATE_MOUSEOVER_UNIT is raised from the
-- game's own update, not during event handling) would otherwise be drawn once before the next pass. Event
-- handling is over by then, and the frame is drawn next, so the level can go back right away.
local function QueueOrApplyName(frame)
    if lastUpdateTime == GetTime() then
        pendingNames[frame] = nil
        ApplyName(frame)
    else
        QueueName(frame)
    end
end

local function UpdateLevel(unit)
    if not settings.showLevel then return end
    if not (unit and unit:find("^nameplate")) then return end
    if UnitExists(unit) and UnitCanAttack("player", unit) then
        levelTexts[unit] = BuildLevelText(unit)
    else
        levelTexts[unit] = nil
    end

    local frame = PlateFrame(unit)
    if frame then
        QueueName(frame)
    end
end

local function UpdateAllLevels()
    for i = 1, 40 do
        UpdateLevel("nameplate" .. i)
    end
end

-- Hooks on the individual widgets of each nameplate this addon may touch, never on Blizzard's global
-- functions. Blizzard's code also runs for forbidden nameplates (friendly plates inside instances), and a
-- hooksecurefunc on CompactUnitFrame_UpdateHealthColor broke it there: every call on the forbidden health
-- bar failed with "bad self", thousands of times. Widget hooks only exist on plates hooked here.
local hookedPlates = setmetatable({}, { __mode = "k" }) -- [UnitFrame] = true

-- Blizzard set a bar color: remember it for RestoreBlizzardColor, then paint over it if the plate is ours.
local function OnBlizzardBarColor(frame, bar, r, g, b)
    if painting then return end
    local color = blizzardColors[bar]
    if color then
        color[1], color[2], color[3] = r, g, b
    else
        blizzardColors[bar] = { r, g, b }
    end
    PaintThreat(frame)
end

-- Blizzard reset the name text. During event handling, only queue the level to be put back: changing the
-- name then, before Blizzard's aura layouts run, is exactly what broke them.
local function OnBlizzardName(frame)
    if writingName then return end
    if namesWritten[frame] or levelTexts[frame.displayedUnit or frame.unit] then
        QueueOrApplyName(frame)
    end
end

-- Called from the event handler for plates PlateFrame returned, so never for a forbidden plate. Blizzard
-- reuses plates, so each is hooked once.
local function HookPlate(frame)
    if not frame or hookedPlates[frame] then return end
    hookedPlates[frame] = true

    local bar = frame.healthBar
    if bar then
        hooksecurefunc(bar, "SetStatusBarColor", function(_, r, g, b)
            local ok, err = pcall(OnBlizzardBarColor, frame, bar, r, g, b)
            if not ok then ReportError(err) end
        end)
    end
    if frame.name then
        hooksecurefunc(frame.name, "SetText", function()
            local ok, err = pcall(OnBlizzardName, frame)
            if not ok then ReportError(err) end
        end)
    end
end

-- Setters for the options panel. Each applies to plates already on screen right away.
local function SetThreatColor(on)
    settings.threatColor = on
    Recompute() -- paints or restores every plate whose color changes
end

local function SetColor(role, level, r, g, b)
    local color = settings.colors[role][level]
    color[1], color[2], color[3] = r, g, b
    RepaintThreat()
end

local function SetShowLevel(on)
    settings.showLevel = on
    if on then
        UpdateAllLevels()
    else
        for unit in pairs(levelTexts) do
            levelTexts[unit] = nil
        end
        for frame in pairs(namesWritten) do
            QueueName(frame) -- puts the plain name back
        end
    end
end

local function IsColor(value)
    return type(value) == "table"
        and type(value[1]) == "number" and type(value[2]) == "number" and type(value[3]) == "number"
end

local function LoadSettings()
    local db = type(NameplateThreatColorsDB) == "table" and NameplateThreatColorsDB or {}

    -- 1.4 called the threat toggle "secureColor".
    if db.threatColor == nil then
        db.threatColor = db.secureColor
    end
    db.secureColor = nil

    for _, key in ipairs({ "threatColor", "showLevel" }) do
        if db[key] == nil then
            db[key] = DEFAULTS[key]
        end
    end

    if type(db.colors) ~= "table" then
        db.colors = {}
    end
    -- A short-lived test build swapped the saved tank Low and High colors and set colorsVersion = 2.
    -- Swap them back so each color stays with its situation.
    if db.colorsVersion == 2 and type(db.colors.tank) == "table" then
        local tank = db.colors.tank
        tank.low, tank.high = tank.high, tank.low
    end
    db.colorsVersion = nil
    for role, levels in pairs(DEFAULTS.colors) do
        if type(db.colors[role]) ~= "table" then
            db.colors[role] = {}
        end
        for level, color in pairs(levels) do
            if not IsColor(db.colors[role][level]) then
                db.colors[role][level] = { color[1], color[2], color[3] }
            end
        end
    end

    NameplateThreatColorsDB = db
    settings = db
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_REGEN_ENABLED") -- combat over: threat lists clear, so hand plates back to Blizzard
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
        local frame = PlateFrame(unit)
        if frame and namesWritten[frame] then QueueName(frame) end
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

-- New plates get their widget hooks before anything paints them; PLAYER_ENTERING_WORLD covers plates that
-- were already up when the addon loaded (/reload).
local function HookPlates(event, unit)
    if event == "NAME_PLATE_UNIT_ADDED" then
        HookPlate(PlateFrame(unit))
    elseif event == "PLAYER_ENTERING_WORLD" then
        for i = 1, 40 do
            HookPlate(PlateFrame("nameplate" .. i))
        end
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
    local ok, err = pcall(HookPlates, event, unit)
    if not ok then ReportError(err) end
    ok, err = pcall(HandleLevels, event, unit)
    if not ok then ReportError(err) end
    if LEVEL_ONLY_EVENTS[event] then return end

    ok, err = pcall(Recompute)
    if not ok then ReportError(err) end
end)

-- Opens Blizzard's color picker on a color, calling onChange(r, g, b) live and with the old color on Cancel.
local function OpenColorPicker(color, onChange)
    local r0, g0, b0 = color[1], color[2], color[3]
    local function Changed()
        onChange(ColorPickerFrame:GetColorRGB())
    end
    local function Cancelled()
        onChange(r0, g0, b0)
    end

    ColorPickerFrame:Hide()
    ColorPickerFrame:SetFrameStrata("FULLSCREEN_DIALOG") -- above the Settings panel
    if ColorPickerFrame.SetupColorPickerAndShow then
        ColorPickerFrame:SetupColorPickerAndShow({
            swatchFunc = Changed,
            cancelFunc = Cancelled,
            hasOpacity = false,
            r = r0, g = g0, b = b0,
        })
    else
        ColorPickerFrame.func = Changed
        ColorPickerFrame.cancelFunc = Cancelled
        ColorPickerFrame.hasOpacity = false
        ColorPickerFrame.previousValues = { r0, g0, b0 }
        ColorPickerFrame:SetColorRGB(r0, g0, b0)
        ColorPickerFrame:Show()
    end
end

-- Options -> AddOns panel, same canvas-layout pattern as the other addons installed on this client.
local function BuildOptionsPanel()
    local panel = CreateFrame("Frame")
    panel.name = "Nameplate Threat Colors"

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText(panel.name)

    -- Each new region goes below the previous one, at an indent measured from the title's left edge.
    local anchor, anchorIndent = title, 0
    local function Place(region, indent, gap)
        region:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", indent - anchorIndent, -gap)
        anchor, anchorIndent = region, indent
    end

    local refreshers = {}

    local function AddCheckbox(key, label, description, setter)
        local checkbox = CreateFrame("CheckButton", "NameplateThreatColors_" .. key, panel, "UICheckButtonTemplate")
        Place(checkbox, 0, 16)
        local text = checkbox.Text or checkbox.text or _G[checkbox:GetName() .. "Text"]
        if text then
            text:SetFontObject("GameFontNormal")
            text:SetText(label)
        end

        local desc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        desc:SetWidth(540)
        desc:SetJustifyH("LEFT")
        desc:SetText(description)
        Place(desc, 30, -2)

        checkbox:SetScript("OnClick", function(self)
            local ok, err = pcall(setter, self:GetChecked() and true or false)
            if not ok then ReportError(err) end
        end)
        refreshers[#refreshers + 1] = function()
            checkbox:SetChecked(settings[key])
        end
    end

    local function AddHeader(text)
        local header = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        header:SetText(text)
        Place(header, 30, 14)
    end

    local function AddColorRow(role, level, label, hint)
        local swatch = CreateFrame("Button", nil, panel)
        swatch:SetSize(18, 18)
        Place(swatch, 40, 8)

        local border = swatch:CreateTexture(nil, "BACKGROUND")
        border:SetAllPoints()
        border:SetColorTexture(0.6, 0.6, 0.6)
        local fill = swatch:CreateTexture(nil, "ARTWORK")
        fill:SetPoint("TOPLEFT", 1, -1)
        fill:SetPoint("BOTTOMRIGHT", -1, 1)

        local labelText = swatch:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        labelText:SetPoint("LEFT", swatch, "RIGHT", 8, 0)
        labelText:SetText(label)
        local hintText = swatch:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
        hintText:SetPoint("LEFT", swatch, "LEFT", 140, 0)
        hintText:SetText(hint)

        local function Refresh()
            local color = settings.colors[role][level]
            fill:SetColorTexture(color[1], color[2], color[3])
        end
        local function Changed(r, g, b)
            local ok, err = pcall(SetColor, role, level, r, g, b)
            if not ok then ReportError(err) end
            Refresh()
        end

        swatch:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        swatch:SetScript("OnClick", function(_, button)
            if button == "RightButton" then
                local default = DEFAULTS.colors[role][level]
                Changed(default[1], default[2], default[3])
            else
                OpenColorPicker(settings.colors[role][level], Changed)
            end
        end)
        swatch:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(label)
            GameTooltip:AddLine("Left-click to choose a color.", 1, 1, 1)
            GameTooltip:AddLine("Right-click to reset it to the default.", 1, 1, 1)
            GameTooltip:Show()
        end)
        swatch:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
        refreshers[#refreshers + 1] = Refresh
    end

    AddCheckbox("threatColor", "Color health bar by threat",
        "Colors enemy health bars by your threat while you are in a group, with separate colors for the Tank role "
        .. "and for DPS/Healing. Needs Interface > Nameplates > Aggro Display > Health Bar Color turned on.",
        SetThreatColor)
    AddHeader("Tank")
    AddColorRow("tank", "low", "Low threat", "Someone else has the mob")
    AddColorRow("tank", "medium", "Medium threat", "Your threat lead is slipping")
    AddColorRow("tank", "high", "High threat", "The mob is on you with a safe lead")
    AddHeader("DPS/Healing")
    AddColorRow("dps", "low", "Low threat", "The mob is on someone else")
    AddColorRow("dps", "medium", "Medium threat", "You are close to pulling the mob")
    AddColorRow("dps", "high", "High threat", "The mob is on you")

    AddCheckbox("showLevel", "Show level before enemy names",
        "Adds the mob's level in front of its name, like \"5 Boar\", with \"+\" for elites and \"??\" when the level "
        .. "is unknown. The level is colored grey, green, yellow, orange, or red by difficulty.",
        SetShowLevel)

    panel:SetScript("OnShow", function()
        for _, refresh in ipairs(refreshers) do
            refresh()
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
