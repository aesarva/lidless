---
version: 1
slug: "app-popover-popoverview-swift"
primary_target: "App/Popover/PopoverView.swift"
related_targets: ["App/Settings/SettingsView.swift","App/StatusItem/IconRenderer.swift"]
---

# Popover (menu-bar panel) and its family: settings window, menu-bar glyphs, app icon

Mode: Operate. Platform: native macOS 14+ (SwiftUI/AppKit). Build path: code-led (operate surface).

Audience and job: glance from the menu bar, start/stop a keep-awake session in one click, pick a duration, toggle display and closed-lid mode, read battery/thermal guard state, then leave it alone for hours.

Constraints: native controls only (Toggle .switch, segmented Picker, Button); state must never look calmer than reality; en + ru copy; works in light and dark menu bars; popover must be key-window active on open (no grey inactive material), closes on outside click.

## Direction contract

THESIS: The popover is the door of a broadcast studio: while Lidless keeps the Mac awake the ON AIR sign is lit and everyone knows not to interrupt. It refuses the Control Center tile grid every keep-awake utility ships.

OWN-WORLD: Studio black panel #121212 with a #1B1B1B second layer and cream #E8E2D6 meter plate; signal red #E0342A reserved for "on air" only (the lit sign, the session switch, live meter zones); warm off-air glass #3A1512 for the unlit sign. One sans family (SF Pro) for UI and tabular numerals; the sign lettering is a self-hosted wide display face (Unbounded). Flat light, no coloured glows; neutral offset shadows only.

STORY: The visitor sees at once whether the Mac is on air and for how long, changes duration or lid mode in one click, sees battery and heat as studio meters with their stop lines, and closes the panel trusting the session.

FIRST VIEWPORT: 320pt panel. Top: full-width sign "В ЭФИРЕ / ON AIR", 56pt tall, lit red when a session runs, dark glass with visible lettering when off. Below: remaining time 48pt tabular left, "до 23:39 · крышка закрыта" under it, session switch right. Then a segmented duration control. Then a cream meter plate with two 20-segment meters (battery with threshold tick, thermal with red top zone). Then two switch rows (Экран, Закрытая крышка). Footer: Settings and Quit as icon buttons.

FORM: chosen form "В эфире" (studio ON AIR sign), my top-ranked grounded candidate, picked by the user over the roll. seed: 0cbe9c1415b0d005

SIGNATURE: the sign strikes on: when a session starts the lamp lights with a short two-step strike (off → dim → full, ~220ms) like a studio lamp; off fades it back to dark glass; Reduce Motion crossfades. Meters fill segment by segment on change.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
