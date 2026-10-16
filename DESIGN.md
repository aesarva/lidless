---
name: Lidless
description: A broadcast-studio door for a keep-awake utility; the ON AIR sign is lit exactly while the Mac is held awake.
colors:
  signal-red: "#E0342A"
  signal-red-lit: "#EC4A3E"
  signal-red-rim: "#A8221A"
  off-air-glass: "#2A1311"
  off-air-lettering: "#6B2E28"
  studio-black: "#121212"
  studio-raised: "#1C1C1C"
  studio-cream: "#E8E2D6"
  plate-ink: "#1A1A1A"
  caution-amber: "#F2A65A"
typography:
  sign:
    fontFamily: "Unbounded, sans-serif"
    fontSize: "21px"
    fontWeight: 700
    letterSpacing: "3.2px"
  headline-time:
    fontFamily: "SF Pro, system-ui, sans-serif"
    fontSize: "46px"
    fontWeight: 600
    letterSpacing: "-0.8px"
    fontFeature: "tnum"
  row-title:
    fontFamily: "SF Pro, system-ui, sans-serif"
    fontSize: "13px"
    fontWeight: 500
  label:
    fontFamily: "SF Pro, system-ui, sans-serif"
    fontSize: "12px"
    fontWeight: 400
    fontFeature: "tnum"
  caption:
    fontFamily: "SF Pro, system-ui, sans-serif"
    fontSize: "11px"
    fontWeight: 400
rounded:
  panel: "14px"
  plate: "9px"
  sign: "8px"
  segment-track: "8px"
  segment: "6px"
  meter-cell: "1px"
spacing:
  hairline: "1px"
  cell-gap: "2px"
  xs: "5px"
  row: "9px"
  gap: "14px"
  panel-padding: "16px"
  panel-width: "320px"
components:
  on-air-sign:
    backgroundColor: "{colors.signal-red}"
    textColor: "#FFFFFF"
    typography: "{typography.sign}"
    rounded: "{rounded.sign}"
    height: "56px"
  on-air-sign-off:
    backgroundColor: "{colors.off-air-glass}"
    textColor: "{colors.off-air-lettering}"
    rounded: "{rounded.sign}"
    height: "56px"
  duration-track:
    backgroundColor: "{colors.studio-raised}"
    rounded: "{rounded.segment-track}"
    padding: "2px"
  duration-segment-selected:
    backgroundColor: "{colors.studio-cream}"
    textColor: "{colors.plate-ink}"
    rounded: "{rounded.segment}"
    height: "26px"
  meter-plate:
    backgroundColor: "{colors.studio-cream}"
    textColor: "{colors.plate-ink}"
    rounded: "{rounded.plate}"
    padding: "11px 12px"
  panel:
    backgroundColor: "{colors.studio-black}"
    textColor: "{colors.studio-cream}"
    rounded: "{rounded.panel}"
    padding: "16px"
    width: "320px"
---

# Design System: Lidless

## Overview

**Creative North Star: "The Studio Door"**

The menu-bar panel is the door of a broadcast studio. While Lidless holds the Mac awake the ON AIR sign is lit and nobody should interrupt; when it is not, the sign is dark glass with its lettering still readable. The panel is always dark studio black, whatever the system appearance, and everything else is one cream plate and a few quiet greys. It deliberately avoids the Control Center tile grid.

Density is compact and vertical: one 320pt column, a sign, a number, a segment row, a meter plate, two switch rows, a footer. Light is flat: no coloured glows, no gradients except the lamp itself. Expression comes from a single wide display face on the sign and from restraint with red.

The settings window is the exception that proves the rule: it stays native (system appearance, grouped Form) and carries none of the studio styling.

**Key Characteristics:**
- Always-dark panel (forced dark appearance), 320pt wide, 14pt continuous corners.
- Signal red means "on air" and nothing else.
- Cream plate (#E8E2D6) is the only light surface; it holds measurements.
- State is never calmer than reality: off air shows an em dash, not a fake timer.

## Colors

A black studio, one cream plate, and a single spent-on-purpose signal red.

### Primary
- **Signal Red** (#E0342A): the lit sign body, switches while a session runs, the battery stop line while on air, the heat meter's red zone.
- **Lamp Lit Red** (#EC4A3E): top of the sign's lit gradient only.
- **Lamp Rim Red** (#A8221A): the 1px border of the lit sign.

### Secondary
- **Off-Air Glass** (#2A1311): the unlit sign body. **Off-Air Lettering** (#6B2E28): its dim "ON AIR" text.
- **Caution Amber** (#F2A65A): warning text on the black panel only (paused lid mode, blocked start, helper error). Never a fill.

### Neutral
- **Studio Black** (#121212): panel ground.
- **Studio Raised** (#1C1C1C): the duration track, one layer above the ground.
- **Studio Cream** (#E8E2D6): primary text on black, the selected duration segment, and the meter plate. Dim text is cream at 66%, faint at 42%, hairline at 12%.
- **Plate Ink** (#1A1A1A): text and lit meter cells on the cream plate; dim text at 62%, unlit cells at 13%.

### Named Rules
**The Spent Red Rule.** Red appears only while on air (or as the standing heat red zone, shown faint when off). Off air an enabled switch is cream-grey and the battery stop line is plate ink. If red shows with the sign dark, something is lying.

**The Cream Plate Rule.** Measurements live on the cream plate; the plate is the only light surface in the panel.

## Typography

**Sign Font:** Unbounded Bold (bundled, SIL OFL; sign lettering only)
**UI Font:** SF Pro (system) for everything else, tabular digits wherever numbers change.

**Character:** One loud wide face on one element, then a quiet system voice.

### Hierarchy
- **Sign** (700, 21pt, tracking 3.2): "ON AIR" / localized, shrinks to 70% before truncating.
- **Headline time** (600, 46pt, tracking -0.8, tabular): remaining or elapsed time; cream when running, 42% cream em dash when off.
- **Row title** (500, 13pt): switch row titles.
- **Label** (12pt, 400 or 600 selected/meter titles, tabular): duration segments, meter titles and values, session caption.
- **Caption** (11pt): row details, meter notes.

### Named Rules
**The One Loud Face Rule.** Unbounded belongs to the sign. Everything else is SF Pro.

## Layout

Single column, 16pt panel padding, 14pt between blocks, fixed 320pt width with natural height; the top edge stays under the menu bar when content wraps. Switch rows sit 9pt vertical padding apart with a 1px hairline between. Duration segments share width equally with a 2pt gap; meters are 20 cells with 2pt gaps, 7pt tall. Footer icon buttons (28x24 hit area) sit at the bottom corners, pulled 4pt up. English and Russian copy must wrap inside the column, never widen it.

## Elevation & Depth

Flat tonal layering: black ground, a slightly lighter raised track, one cream plate. The only depth cues are the window's system shadow, a 1px white-10% panel border, and the sign's lit gradient. No glows around red.

## Shapes

Continuous (squircle) corners nested by size: 14pt panel, 9pt plate, 8pt sign and duration track, 6pt segment, 1pt meter cell. Meter cells are small rectangles; the battery stop line is a 1.5pt vertical rule that overshoots the cells by 3pt.

## Components

### On Air Sign
Full-width, 56pt tall. Lit: red gradient (#EC4A3E to #E0342A), rim #A8221A, white lettering. Off: dark glass, dim lettering, near-black border. Turning on strikes in steps (about 0.55, 0.25, then 1 over roughly 250ms); off fades over 350ms; Reduce Motion uses a 200ms crossfade.

### Duration Control
A custom segment row (the native segmented control ignored its frame). Presets, "Until…" (opens a time popover), and infinity. Selected segment is cream with plate-ink semibold text; hover is cream at 8%. Picking starts a session or restarts the running one. 150ms ease-out.

### Meter Plate
Cream plate with battery and heat rows: title, note, value, then 20 cells. Battery lit cells = level/5 with a stop line at threshold/5; heat cells 4/8/15/20 for normal/normal/elevated/high with cells from 14 up as the red zone (faint red at 18% when unlit). Whole plate is a button to Safety settings. Fills ease over 250ms.

### Switch Rows
Title (13pt medium), 11pt detail, small native switch right. Tint is signal red only while on air, otherwise dim cream. Detail turns amber for paused or blocked states.

### Session Switch
Large native switch beside the time, tinted signal red.

### Menu-bar Glyphs and App Icon
Template "pulse" glyphs at 18pt (flat line, ECG pulse, pulse in progress ring, pulse over horizon, pulse with orange attention dot, the only coloured glyph). App icon: studio-black ground with a lit red light box carrying a warm-white pulse line and a thin cream rule (generated raster, provenance in docs/asset-provenance.md).

## Do's and Don'ts

### Do:
- **Do** keep the panel dark and 320pt wide in every system appearance.
- **Do** spend signal red only on on-air state.
- **Do** use tabular digits for every changing number.
- **Do** pair every state with words; off air says so in text.
- **Do** keep the Settings window native and system-appearance.

### Don't:
- **Don't** set red on a control while off air.
- **Don't** use Unbounded outside the sign.
- **Don't** put coloured glows or extra light surfaces in the panel.
- **Don't** replace the duration row with a native segmented control (it breaks the panel width).
- **Don't** show a calm value (a timer, a full meter) when the data is absent; use an em dash and empty cells.
