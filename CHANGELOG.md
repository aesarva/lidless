# Changelog

## Unreleased

Fixes from a code review.

- A timed session in closed-lid mode could end with a false "reinstall the helper" warning: helper commands no longer run the main run loop while they wait, and a hung command is killed after 15 s.
- Closed-lid mode can no longer outlive the app: Lidless turns off what it turned on even if the marker was removed, and uninstalling the helper turns closed-lid mode off first.
- The watchdog only counts the marker owner's own Lidless, so another user's copy cannot block the reset. Reinstall the helper (Settings → Helper) to get the new watchdog.
- The session ends on time and the safety checks keep running while the quick menu or an alert is open.
- A stale "ends in 5 minutes" notification no longer appears after the session was stopped or extended.
- Fewer redraws: the panel updates only when readings change, the menu-bar lamp only when it visibly burns down.

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
