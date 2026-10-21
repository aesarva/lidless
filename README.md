<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="Lidless app icon: a lit red ON AIR lamp with a pulse line">
</p>

<h1 align="center">Lidless</h1>

<p align="center">
  <b>Keep your Mac awake — even with the lid closed — and never leave it unable to sleep.</b><br>
  A native macOS menu-bar app with an ON AIR sign you press to go on air.
</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111111?logo=apple">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-E0342A?logo=swift&logoColor=white">
  <img alt="Universal" src="https://img.shields.io/badge/Apple%20Silicon%20%2B%20Intel-universal-555555">
  <a href="LICENSE"><img alt="License: GPL-3.0" src="https://img.shields.io/badge/license-GPL--3.0-blue"></a>
</p>

<p align="center">
  English · <a href="README.ru.md">Русский</a>
</p>

<p align="center">
  <img src="docs/images/panel-timer.png" width="300" alt="Lidless panel on air with a one-hour countdown on the sign">
  &nbsp;
  <img src="docs/images/panel-indefinite.png" width="300" alt="Lidless panel on air indefinitely, the sign counts time on air">
  &nbsp;
  <img src="docs/images/panel-off.png" width="300" alt="Lidless panel off air, the sign is dark">
</p>

---

## Why Lidless

Most keep-awake utilities stop at "don't sleep while the lid is open". Lidless is built for the moments when you actually walk away:

- **Works with the lid closed.** Close the lid and the screen goes dark, but the Mac keeps running your build, download, render, AI agent, SSH session or AirPlay stream. With an external display connected, Lidless leaves your screens alone.
- **Guards itself.** A session stops on low battery, closed-lid mode pauses when the Mac gets hot, and a time limit stops a forgotten laptop from cooking in a bag. If the Mac is critically hot with the lid closed, the session ends.
- **Never leaves your Mac broken.** Quitting Lidless restores normal sleep. If it crashes, is force-quit, or the Mac reboots mid-session, a small root watchdog restores normal sleep within a minute. The only privileged command Lidless can run is `pmset -a disablesleep 0|1`.
- **One press.** The ON AIR sign *is* the button. Press it to go on air, press it again to go off air. The sign counts down a timed session or counts time on air for an indefinite one.
- **Honest at a glance.** While on air the menu-bar icon is a small lit red lamp; with a timer its light burns down as time runs out. An orange dot means something needs your attention.
- **Native and private.** SwiftUI + AppKit, a universal binary, no network access, no analytics, no accounts.

## Features

| | |
|---|---|
| **Sessions** | 15 min, 1 h, 3 h (presets are editable), *Until…* a time of day, or indefinitely (∞). Pick a length to start right away or to restart a running session with a new length. |
| **The sign** | Press it (or hit Return) to go on air / off air. Lit red while on air, with a countdown or time-on-air clock; dark glass when off. |
| **Display** | *Keep display on* keeps the screen lit; otherwise the screen may sleep while the Mac stays awake. |
| **Closed-lid mode** | The Mac keeps running with the lid shut; the screen turns off at once. Needs a one-time helper install ([details](#closed-lid-mode-and-the-helper)). |
| **Safety meters** | Battery and heat as studio meters on the panel, with the battery stop line drawn in. |
| **Notifications** | A heads-up 5 minutes before a timed session ends, with **+30 min** and **+1 h** buttons; a note when a safety rule stops or pauses something. |
| **Menu-bar icon** | A quiet line when off; a lit lamp on air; optional remaining-time text next to it. |
| **Settings** | Launch at login, default length, presets, menu-bar timer text, start a session at launch, safety thresholds, helper install/uninstall, and the interface language. |
| **Languages** | English and Russian, switchable in Settings → General → Language (independent of the system language). |

### Menu-bar icon

<p>
  <img src="docs/images/menubar-light.png" width="536" alt="Menu-bar icon states in a light menu bar">
  <br>
  <img src="docs/images/menubar-dark.png" width="536" alt="Menu-bar icon states in a dark menu bar">
</p>

Left to right: **off** · **on air** · **on air with a timer** (the lamp's light burns down; remaining time shown) · **on air in closed-lid mode** (a horizon line under the lamp) · **needs attention** (a safety rule fired, or the helper is unavailable).

### Safety rules

<img src="docs/images/panel-safety.png" width="320" align="right" alt="Closed-lid mode paused because the Mac is hot">

| Rule | Default | What happens |
|---|---|---|
| Low battery | on, 20% (5–50%) | On battery below the threshold the session stops; a session will not start below it. |
| Heat | on | At *serious* thermal pressure closed-lid mode pauses (the session goes on); at *critical* pressure with the lid closed the session stops. |
| Closed-lid time on battery | on, 4 h (30 min–12 h) | After that long closed on battery, closed-lid mode pauses. |

Every rule can be turned off or tuned in **Settings → Safety**.

<br clear="right">

## Install

1. Download `Lidless.dmg` from [Releases](https://github.com/aesarva/lidless/releases) and open it.
2. Drag **Lidless** onto the **Applications** shortcut, then launch it. It lives only in the menu bar (no Dock icon).

Releases are signed with a Developer ID and notarized by Apple, so Lidless opens like any other app. Requires macOS 14 Sonoma or later, on Apple Silicon or Intel.

## Quick start

1. Click the menu-bar icon.
2. Press the **ON AIR** sign — or pick a length (15 min, 1 h, 3 h, *Until…*, ∞) to start with it.
3. Want to close the lid? Turn on **Closed-lid mode** (the first time, Lidless asks for your administrator password to install its helper).
4. Press the sign again to go off air. Quitting Lidless also ends the session and restores normal sleep.

Click the icon again or press Esc to close the panel. Right-click the icon for a quick menu.

## Closed-lid mode and the helper

Ordinary sessions use a standard macOS power assertion and need nothing extra. Keeping a Mac awake with the lid closed (without an external display) needs `pmset -a disablesleep 1`, which requires root. The first time you turn closed-lid mode on, Lidless asks for your administrator password **once** and installs:

| Path | Purpose |
|---|---|
| `/etc/sudoers.d/lidless` | lets your user run `/usr/bin/pmset -a disablesleep 0` and `… 1` without a password — and nothing else |
| `/Library/PrivilegedHelperTools/app.lidless.watchdog.sh` | watchdog script that restores normal sleep if Lidless is gone |
| `/Library/LaunchDaemons/app.lidless.watchdog.plist` | launchd job `app.lidless.watchdog` that runs the watchdog every 60 seconds and at boot |

A marker file, `/Users/Shared/Lidless/lid-mode.marker`, records that Lidless turned closed-lid mode on. If Lidless quits, crashes, or the Mac reboots mid-session, the watchdog sees the marker without a running app and runs `pmset -a disablesleep 0`. Lidless never touches a `disablesleep` you set yourself.

When the lid closes in closed-lid mode, Lidless turns the screen off (`pmset displaysleepnow`, no privileges needed) and keeps the Mac awake; when the lid opens, your display choice applies again.

### Security model

- **The rule is narrow.** The sudoers rule allows exactly `pmset -a disablesleep 0|1`, for your user only, and nothing else. It is validated with `visudo` before it is installed.
- **Until Lidless registers its helper through `SMAppService`,** the helper scripts are copied from inside the app bundle at install time. Releases are signed and notarized, but an installed bundle is user-writable, so the install is only as trustworthy as the copy of Lidless on your disk. Install the helper only from a copy you trust.
- **After installation** the sudoers rule and the watchdog live in root-owned locations. Uninstall runs `uninstall.sh` from the app bundle as root through the password prompt, so it shares the trust level of the bundle.
- **If the helper breaks** while closed-lid mode is on (for example, the sudoers file was removed), Lidless keeps retrying every 15 seconds and shows the orange dot until normal sleep is restored; the watchdog restores it once Lidless quits.

### Uninstall

Open **Settings → Helper → Uninstall**, enter your password, then delete `Lidless.app`. This removes the sudoers file, watchdog script, launchd job and marker, and restores normal sleep.

## Privacy

Lidless makes no network requests, collects no analytics and needs no account. It reads battery level, power source, thermal state and the lid sensor locally to apply its safety rules.

## Build from source

Requirements: Xcode 16 or later and

```sh
brew install xcodegen shellcheck
```

```sh
make test      # Swift package tests, shellcheck, watchdog script tests
make build     # generate the Xcode project and build (Debug)
make run       # build and launch the Debug app
make app       # Release universal build (arm64 + x86_64), hardened runtime → build/Lidless.app
make dmg       # make app + dist/Lidless-<VERSION>.dmg without a Developer ID (VERSION=0.2.0 by default)
```

`scripts/build-app.sh` honours `ARCHS` (e.g. `ARCHS=arm64`), `VERSION` and `SIGN_IDENTITY` (default `-`, ad-hoc). The build number is the commit count.

### Signed release

Lidless is distributed outside the App Store (its privileged helper is not allowed there). With a **Developer ID Application** certificate in your keychain and notarization credentials stored once:

```sh
xcrun notarytool store-credentials Lidless --apple-id <you@example.com> --team-id <TEAMID>
scripts/release.sh 0.2.0     # build, sign, notarize app and DMG, staple, check Gatekeeper
```

Without a certificate, `scripts/release.sh 0.2.0 --unsigned` (or `make dmg`) checks everything except signing and notarization.

### Project layout

```
App/                     SwiftUI/AppKit app: menu-bar panel, settings, icon, notifications
Packages/LidlessCore/    sessions, safety policy, helper backend, IOKit adapters (+ tests)
Helper/                  install/uninstall scripts, the root watchdog and its launchd job
scripts/                 build-app.sh and release.sh
docs/                    images, asset provenance, design spec and implementation plan
DESIGN.md                the "On Air" visual system
```

### Debug aids

Debug builds accept `-SnapshotDir <dir>` (render every panel state and settings tab to PNGs, then quit) and `-OpenPanelOnLaunch YES -CapturePanelTo <png>` (capture the live panel). These runs use in-memory settings and a fake helper, so they never touch your real settings or `disablesleep`.

## Manual verification

These checks need a real MacBook and are not automated yet:

1. A 15-minute session with the lid open and *display may sleep*: the display turns off, the system stays awake (`pmset -g assertions`).
2. Closed-lid mode, no external display and no charger, lid closed for 5 minutes: `pmset -g log` shows no sleep; an SSH session stays alive.
3. Force-quit Lidless while closed-lid mode is active: within 60 seconds `pmset -g` shows `SleepDisabled 0`.
4. Reboot mid-session without Lidless launching at login: after boot `SleepDisabled 0`.
5. A battery threshold above the current charge: the session stops and a notification appears.
6. Uninstall the helper: the sudoers file, plist and script are removed and `SleepDisabled 0`.

## Roadmap

- Automatic triggers: stay awake while an app runs, on power, with a display or a Wi-Fi network, during downloads, on a schedule.
- Integrations: a global hotkey, a URL scheme, a CLI, Shortcuts actions.
- Statistics and widgets: session history, a desktop widget, a Control Center control.
- An `SMAppService` helper: no sudoers rule, approved in System Settings → Login Items.

Contributions: see [CONTRIBUTING.md](CONTRIBUTING.md) for the branch workflow (`main`, `develop`, one branch per change).

## License

Lidless is free software under the [GNU General Public License v3.0](LICENSE).

The ON AIR lettering uses [Unbounded](https://github.com/googlefonts/unbounded) (SIL Open Font License 1.1, bundled with its license). The app icon was generated with OpenAI gpt-image; see [docs/asset-provenance.md](docs/asset-provenance.md).
