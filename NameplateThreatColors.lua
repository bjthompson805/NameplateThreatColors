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

local SECURE_COLOR = { 0, 1, 0 }

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

ApplyColors()

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("GROUP_ROSTER_UPDATE")
events:RegisterEvent("PLAYER_ROLES_ASSIGNED")
events:RegisterEvent("NAME_PLATE_UNIT_ADDED")
events:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
events:RegisterEvent("UNIT_THREAT_SITUATION_UPDATE")
events:RegisterEvent("UNIT_THREAT_LIST_UPDATE")
events:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        ApplyColors()
    end
    local ok, err = pcall(Recompute)
    if not ok then ReportError(err) end
end)
