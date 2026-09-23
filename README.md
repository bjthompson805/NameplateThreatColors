# Nameplate Threat Colors

A small addon for the WoW Classic Anniversary client (2.5.6, TBC). It makes the nameplate
**Aggro Display → Health Bar Color** option useful for tanks: an enemy plate turns **green**
while you are a Tank and the mob is on you with a safe threat lead.

## Why it exists

Blizzard's health bar threat coloring gives a tank no signal while everything is going well.
For a player assigned the **Tank** role, the client uses `UnitThreatLeadSituation`, and a safe lead
(status `0`) gets no threat color at all, so the plate stays plain hostile red. Only a slipping lead
(`GAINING_THREAT_COLOR`, yellow-orange) or lost aggro (`HIGH_THREAT_COLOR`, reddish-orange) is colored.

Overriding the global `RED_THREAT_COLOR` does nothing here. The nameplate code deliberately does not
use `GetThreatStatusColor`, and it keeps its own status-to-color table.

## Behavior

| Situation (you are assigned Tank, in a group) | Plate color |
|---|---|
| Mob is on you with a safe lead | **Green** (this addon) |
| Your lead is slipping | Blizzard's yellow-orange |
| You are not the top threat | Blizzard's reddish-orange |
| Any other role, no group, or the option is off | Blizzard's default behavior |

Requirements: turn on **Interface → Nameplates → Aggro Display → Health Bar Color**, be in a group,
and be assigned the Tank role (`UnitGroupRolesAssigned("player") == "TANK"`).

### Level on enemy names

Nameplates of attackable units show the level before the name: `5 Boar`, `5+ Boar` for elites
(elite, rare elite, and world boss), and `?? Boar` when the level is unknown (skull). The level uses
Blizzard's creature difficulty colors (`GetCreatureDifficultyColor`):

| Level compared to you | Color |
|---|---|
| 5 or more above, or `??` | Red |
| 3 to 4 above | Orange |
| Within 2 | Yellow |
| Lower, but still gives XP | Green |
| Too low to give XP | Grey |

## Install

Clone or copy this folder into `World of Warcraft/_anniversary_/Interface/AddOns/NameplateThreatColors`,
then restart the game or `/reload`.

## Options

**Options → AddOns → Nameplate Threat Colors** has a checkbox for each feature:

- **Green health bar while you hold aggro as a tank**
- **Show level before enemy names**

Both are on by default. Changes apply immediately and are saved per account in `NameplateThreatColorsDB`.

## Configuration

Edit the top of `NameplateThreatColors.lua`:

- `SECURE_COLOR` is the green used while you hold a mob securely.
- `COLORS` optionally overrides Blizzard's `HIGH_THREAT_COLOR` and `GAINING_THREAT_COLOR` in place.
  Leave them `nil` to keep the defaults.

## Design note: avoid taint

Calling `UnitThreatLeadSituation` or `UnitThreatSituation` from inside a `hooksecurefunc` hook on
`CompactUnitFrame_UpdateHealthColor` taints Blizzard's execution and breaks the nameplate aura layout:

```
Frame:GetScaledRect(): Action[FrameMeasurement] failed because[Can't measure restricted regions]
Lua Taint: *** ForceTaint_Strong ***
[Blizzard_NamePlates/Blizzard_NamePlateAuras.lua]: in function 'RefreshAuras'
```

So the threat calls are made only from the addon's own event handler, which caches which plates are
"secure". The hook reads that cache and paints the health bar, and makes no threat API calls itself.
Reading frame fields, `UnitInParty`, and `PlayerUtil.IsPlayerEffectivelyTank()` inside the hook were all
tested and are safe. Keep the threat calls out of the hook.

The level prefix follows the same rule as a precaution: `UnitLevel` and `UnitClassification` are called only
from the event handler, which caches the finished string. The `CompactUnitFrame_UpdateName` hook only
reads that cache and sets the name text.

## License

[MIT](LICENSE)
