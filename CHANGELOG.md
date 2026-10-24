# Changelog

## 0.4.0 — Unreleased

- Lidless now updates itself: it reads a small feed on GitHub once a day, and when a new version is out the panel shows "Version X available" with a blue dot on the menu-bar icon. One press on Install and Relaunch downloads it, checks its signature and relaunches Lidless. Switch the daily check off in Settings → General → Check for updates automatically.
- A session on air carries over an update: after the restart it continues with the same end time, display choice and closed-lid mode.
- Settings → Helper → Remove now waits until the helper confirms that normal sleep is back; if it can't, the helper stays registered and says so.
- Helper calls no longer block the menu: turning closed-lid mode off while the helper is slow or in trouble leaves the panel responsive.
- A new build registers its helper again when it finds the old one still running or answering with another build number, so a changed helper is picked up even when the version number stays the same.
- Settings → Helper shows the running daemon's version and build.
- Settings is a native macOS window with toolbar tabs.
- Unsigned builds no longer show a warning at every session about closed-lid mode needing a signed build.

## 0.3.0 — 2026-10-24

- The privileged helper is now a daemon registered through `SMAppService`: approve it once in System Settings → General → Login Items & Extensions, with no administrator password and no sudoers rule.
- Normal sleep returns at once when Lidless quits, crashes or is force-quit; a reboot mid-session is reset at boot; if the helper crashes, macOS starts it again and closed-lid mode is re-applied; switching Lidless off in Login Items makes macOS quit it, which restores normal sleep.
- A `disablesleep` set by someone else is never touched.
- The 0.2.0 helper (sudoers rule, watchdog script and launchd job) is removed automatically once the new helper is approved. A `disablesleep` left on by a cut-short 0.2.0 closed-lid session is reset at launch even before that.
- Closed-lid mode works only in builds signed with a Developer ID; unsigned builds show "needs a signed build".
- Settings → Helper: Set Up… and Remove (no password).

## 0.2.0 — 2026-10-21

First public release, signed with a Developer ID and notarized.

- Keep the Mac awake for 15 min, 1 h, 3 h, until a time of day, or indefinitely; editable presets.
- Closed-lid mode: the Mac keeps running with the lid shut and the screen turns off; screens are left alone with an external display. A one-time helper install allows exactly `pmset -a disablesleep 0|1`; a root watchdog restores normal sleep if Lidless is gone.
- Safety: stop on low battery, pause closed-lid mode when hot, stop when critically hot with the lid closed, pause closed-lid mode after a time limit on battery.
- "On Air" menu-bar panel: press the ON AIR sign to go on and off air; countdown or time-on-air clock on the sign; battery and heat meters.
- Menu-bar icon: a lit red lamp while on air that burns down with a timer; an attention dot.
- Notifications 5 minutes before the end with +30 min / +1 h.
- English and Russian, switchable in Settings.
- Universal (Apple Silicon + Intel), macOS 14+.
