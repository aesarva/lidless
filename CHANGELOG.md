# Changelog

## 0.2.0 — 2026-10-17

First public release.

- Keep the Mac awake for 15 min, 1 h, 3 h, until a time of day, or indefinitely; editable presets.
- Closed-lid mode: the Mac keeps running with the lid shut and the screen turns off; screens are left alone with an external display. A one-time helper install allows exactly `pmset -a disablesleep 0|1`; a root watchdog restores normal sleep if Lidless is gone.
- Safety: stop on low battery, pause closed-lid mode when hot, stop when critically hot with the lid closed, pause closed-lid mode after a time limit on battery.
- "On Air" menu-bar panel: press the ON AIR sign to go on and off air; countdown or time-on-air clock on the sign; battery and heat meters.
- Menu-bar icon: a lit red lamp while on air that burns down with a timer; an attention dot.
- Notifications 5 minutes before the end with +30 min / +1 h.
- English and Russian, switchable in Settings.
- Universal (Apple Silicon + Intel), macOS 14+.
