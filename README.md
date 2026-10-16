# Nameplate Threat Colors

A small addon for the WoW Classic Anniversary client (2.5.6, TBC). It makes the nameplate
**Aggro Display → Health Bar Color** option color enemy health bars by your threat, with your own
Low, Medium, and High threat colors for the Tank role and for DPS/Healing, like Threat Plates. It also
shows a colored level before enemy names.

## Why it exists

Blizzard's health bar threat coloring gives a tank no signal while everything is going well.
For a player assigned the **Tank** role, the client uses `UnitThreatLeadSituation`, and a safe lead
(status `0`) gets no threat color at all, so the plate stays plain hostile red. Only a slipping lead
(`GAINING_THREAT_COLOR`, yellow-orange) or lost aggro (`HIGH_THREAT_COLOR`, reddish-orange) is colored.

Overriding the global `RED_THREAT_COLOR` does nothing here. The nameplate code deliberately does not
use `GetThreatStatusColor`, and it keeps its own status-to-color table.

## Behavior

### Health bar color by threat

The addon picks a threat level for each enemy on your threat list, using the same threat states Blizzard
colors, and paints that level's color. Each color can be changed in the options panel.

| Role | Level | Situation | Default color |
|---|---|---|---|
| Tank | Low | You are not the top threat | Blizzard's reddish-orange (`HIGH_THREAT_COLOR`) |
| Tank | Medium | Your threat lead is slipping | Blizzard's yellow-orange (`GAINING_THREAT_COLOR`) |
| Tank | High | The mob is on you with a safe lead | **Green** |
| DPS/Healing | Low | The mob is on someone else | **Green** |
| DPS/Healing | Medium | You are close to pulling the mob | Blizzard's yellow-orange (`GAINING_THREAT_COLOR`) |
| DPS/Healing | High | The mob is on you | Blizzard's reddish-orange (`HIGH_THREAT_COLOR`) |

The Tank colors are used while you are assigned the Tank role (`PlayerUtil.IsPlayerEffectivelyTank()`),
and the DPS/Healing colors otherwise. Enemies that aren't on your threat list, and any enemy while you're
not in a group, keep Blizzard's color. Blizzard ignores threat outside a group, too.

Requirement: turn on **Interface → Nameplates → Aggro Display → Health Bar Color**.

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

**Options → AddOns → Nameplate Threat Colors** has:

- **Color health bar by threat**, with a **Tank** section and a **DPS/Healing** section. Each section has a
  Low, Medium, and High threat color swatch. Left-click a swatch to choose a color, or right-click it to
  reset it to the default.
- **Show level before enemy names**

Both checkboxes are on by default. Changes apply immediately and are saved per account in
`NameplateThreatColorsDB`. Settings saved by 1.4 carry over.

## Design note: avoid taint

Calling `UnitThreatLeadSituation` or `UnitThreatSituation` from inside a `hooksecurefunc` hook on
`CompactUnitFrame_UpdateHealthColor` taints Blizzard's execution and breaks the nameplate aura layout:

```
Frame:GetScaledRect(): Action[FrameMeasurement] failed because[Can't measure restricted regions]
Lua Taint: *** ForceTaint_Strong ***
[Blizzard_NamePlates/Blizzard_NamePlateAuras.lua]: in function 'RefreshAuras'
```

So the threat calls are made only from the addon's own event handler, which caches each plate's threat
color. The hook reads that cache and paints the health bar, and makes no threat API calls itself.
Reading frame fields, `UnitInParty`, and `PlayerUtil.IsPlayerEffectivelyTank()` inside the hook were all
tested and are safe. Keep the threat calls out of the hook.

The hooks are on each enemy plate's own widgets (`SetStatusBarColor` on its health bar and `SetText` on its
name), never on Blizzard's global functions. Blizzard's code also runs for forbidden nameplates (friendly
plates inside instances), and a `hooksecurefunc` on `CompactUnitFrame_UpdateHealthColor` broke it there:
every call on the forbidden health bar failed with `calling 'GetStatusBarColor' on bad self`, thousands of
times. Plates are hooked only when the addon may touch them, so forbidden plates never run addon code.

The level prefix follows the same rule as a precaution: `UnitLevel` and `UnitClassification` are called only
from the event handler, which caches the finished string.

The level is written into Blizzard's name text, but never while Blizzard's own code is running. A layout
change that addon code makes inside the nameplate breaks Blizzard's next aura layout on that plate with the
same error above, if that layout runs before the game has recalculated the plate. That happened both when
the addon set the name text right away, and when it used its own label anchored to the name that changed
width. So the name's `SetText` hook and the event handler only queue the change, and an
`OnUpdate` script applies it later in the same frame, after event handling and before the frame is drawn,
and only when the text actually differs. (A zero-delay `C_Timer` runs a frame later, which made the level
flicker, since Blizzard resets the name on every `UNIT_THREAT_LIST_UPDATE`, which fires on every hit.)
Mouseover resets the name after that `OnUpdate` pass (`UPDATE_MOUSEOVER_UNIT` comes from the game's own update),
so a reset that arrives after the pass in the same frame (same `GetTime()`) is fixed right away instead.

## License

[MIT](LICENSE)
