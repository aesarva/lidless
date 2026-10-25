<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="Lidless app icon: a lit red studio beacon with a pulse line">
</p>

<h1 align="center">Lidless</h1>

<p align="center">
  <b>Keep your Mac awake, even with the lid closed, and never leave it unable to sleep.</b><br>
  A native menu-bar app with an ON AIR sign you press to go on air.
</p>

<p align="center">
  <a href="https://github.com/aesarva/lidless/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/aesarva/lidless?color=E0342A&label=release"></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111111?logo=apple">
  <img alt="Universal" src="https://img.shields.io/badge/Apple%20Silicon%20%2B%20Intel-universal-555555">
  <img alt="Signed and notarized" src="https://img.shields.io/badge/Developer%20ID-notarized-555555">
  <a href="LICENSE"><img alt="License: GPL-3.0" src="https://img.shields.io/badge/license-GPL--3.0-blue"></a>
</p>

<p align="center">
  <a href="https://github.com/aesarva/lidless/releases/latest/download/Lidless.dmg"><b>Download Lidless.dmg</b></a>
  &nbsp;·&nbsp;
  <a href="CHANGELOG.md">What's new</a>
  &nbsp;·&nbsp;
  English · <a href="README.ru.md">Русский</a>
</p>

<p align="center">
  <img src="docs/images/panel-timer.png" width="300" alt="Lidless panel on air with a one-hour countdown on the sign">
  &nbsp;
  <img src="docs/images/panel-indefinite.png" width="300" alt="Lidless panel on air indefinitely, the sign counts time on air">
  &nbsp;
  <img src="docs/images/panel-off.png" width="300" alt="Lidless panel off air, the sign is dark">
</p>

> **New in 0.4.0:** Lidless updates itself. A new version shows up in the panel with a blue dot on the icon, and one press installs it. A session on air carries on after the restart, closed-lid mode included.

---

## Why Lidless

Most keep-awake utilities stop at "don't sleep while the lid is open". Lidless is built for the moments when you actually walk away.

- **Works with the lid closed.** The screen goes dark and the Mac keeps running your build, download, render, AI agent, SSH session or AirPlay stream. With an external display connected, Lidless leaves your screens alone.
- **Guards itself.** It stops on low battery, pauses closed-lid mode when the Mac runs hot, and limits how long a closed laptop runs on battery, so a forgotten MacBook doesn't cook in a bag.
- **Never leaves your Mac broken.** Quit, crash, force-quit or reboot: normal sleep always comes back. A sleep setting you changed yourself is never touched.
- **One press.** The ON AIR sign *is* the button. It counts down a timed session or counts up time on air.
- **Legible at a glance.** On air, the menu-bar icon is a small lit red lamp that burns down with a timer. An orange dot means something needs you.
- **Native and private.** SwiftUI + AppKit, universal binary, one small update check a day, no analytics, no accounts.

## Install

1. [Download `Lidless.dmg`](https://github.com/aesarva/lidless/releases/latest/download/Lidless.dmg), open it and drag **Lidless** to **Applications**.
2. Launch it. Lidless lives in the menu bar only, with no Dock icon.
3. The first time you turn on **Closed-lid mode**, macOS opens **System Settings → General → Login Items & Extensions**. Switch Lidless on under **Allow in the Background**. You do this once, with no password.

Releases are signed with a Developer ID and notarized by Apple. Requires macOS 14 Sonoma or later, on Apple Silicon or Intel.

## Quick start

1. Click the menu-bar icon.
2. Press the **ON AIR** sign, or pick a length (15 min, 1 h, 3 h, *Until…*, ∞) to start with it.
3. Going to close the lid? Turn on **Closed-lid mode**.
4. Press the sign again to go off air. Quitting Lidless also ends the session.

Esc or another click on the icon closes the panel; right-click the icon for a quick menu.

## Features

| | |
|---|---|
| **Sessions** | 15 min, 1 h, 3 h (editable presets), *Until…* a time of day, or indefinitely (∞). Picking a length starts a session or restarts the running one with it. |
| **The sign** | Press it (or hit Return) to go on air and off air. Lit red with a countdown or time-on-air clock; dark glass when off. |
| **Display** | *Keep display on* keeps the screen lit; otherwise the screen may sleep while the Mac stays awake. |
| **Closed-lid mode** | The Mac keeps running with the lid shut and the screen turns off at once. [How it works](#closed-lid-mode). |
| **Safety meters** | Battery and heat as studio meters on the panel, with the battery stop line drawn in. |
| **Notifications** | A heads-up 5 minutes before a timed session ends, with **+30 min** and **+1 h**; a note when a safety rule stops or pauses something. |
| **Menu-bar icon** | A quiet line when off, a lit lamp on air, optional remaining time next to it. |
| **Settings** | Launch at login, default length, presets, menu-bar timer, start at launch, safety thresholds, the helper, and the interface language. |
| **Updates** | Once a day Lidless reads a feed on GitHub. A new version appears in the panel and as a blue dot on the icon; one press installs it and restarts. A session on air continues after the update. Can be switched off in Settings → General. |
| **Languages** | English and Russian, switchable in Settings → General → Language, independent of the system language. |

### Menu-bar icon

<p>
  <img src="docs/images/menubar-light.png" width="536" alt="Menu-bar icon states in a light menu bar">
  <br>
  <img src="docs/images/menubar-dark.png" width="536" alt="Menu-bar icon states in a dark menu bar">
</p>

Left to right: **off** · **on air** · **on air with a timer** (the lamp burns down, remaining time shown) · **closed-lid mode** (a horizon line under the lamp) · **needs attention** (a safety rule fired, or the helper is unavailable).

### Safety rules

<img src="docs/images/panel-safety.png" width="320" align="right" alt="Closed-lid mode paused because the Mac is hot">

| Rule | Default | What happens |
|---|---|---|
| Low battery | on, 20% (5–50%) | On battery below the threshold the session stops, and it won't start below it. |
| Heat | on | At *serious* thermal pressure closed-lid mode pauses and the session goes on; at *critical* pressure with the lid closed the session stops. |
| Closed-lid time on battery | on, 4 h (30 min–12 h) | After that long closed on battery, closed-lid mode pauses. |

Turn off or tune any rule in **Settings → Safety**.

<br clear="right">

## Closed-lid mode

Ordinary sessions use a standard macOS power assertion and need nothing extra. Staying awake with the lid closed and no external display takes `pmset -a disablesleep 1`, which needs root. So Lidless ships a small helper daemon inside the app and registers it with macOS through `SMAppService`; you approve it once in Login Items.

When the lid closes, Lidless turns the screen off (`pmset displaysleepnow`, no privileges needed) and keeps the Mac awake. When the lid opens, your display choice applies again.

### When something goes wrong

Closed-lid mode is tied to Lidless's live connection to the helper, so normal sleep has a way back in every case:

| If… | Then… |
|---|---|
| Lidless quits, crashes or is force-quit | The helper restores normal sleep at once. |
| The Mac reboots mid-session | The helper resets `disablesleep` at boot. |
| The helper crashes | macOS starts it again and Lidless re-applies closed-lid mode. |
| You switch Lidless off in Login Items | macOS quits Lidless and normal sleep is restored. |
| You set `disablesleep` yourself | Lidless leaves it alone. |

### Security model

- **One command.** The helper's only privileged action is `pmset -a disablesleep 0|1`. It takes no paths or arguments from the app beyond that on/off choice. The one exception: when it first starts, it removes the 0.2.0 helper (`launchctl bootout` of its watchdog job and deleting its files).
- **Signatures checked both ways.** The helper accepts connections only from Lidless signed by the same Developer ID team, and Lidless talks only to a helper signed by that team. Ad-hoc builds are refused on both sides, and macOS refuses to launch the helper at all if its signature no longer matches.
- **One location.** macOS ties the helper to the app's path, so run Lidless from one place, such as `/Applications`.

| Path | Purpose |
|---|---|
| `Lidless.app/Contents/MacOS/LidlessHelper` | the helper daemon; runs as root, started by macOS on demand and at boot |
| `Lidless.app/Contents/Library/LaunchDaemons/io.github.aesarva.Lidless.helper.plist` | the launchd job that `SMAppService` registers |
| `/Library/Application Support/Lidless/sleep-owned` | exists only while the helper has turned `disablesleep` on |

Found a security problem? See [SECURITY.md](SECURITY.md).

### Upgrading from 0.2.0

Install 0.3.0 over 0.2.0 and approve the new helper. It removes the old sudoers rule, watchdog script and launchd job before accepting any connection, and Settings → Helper confirms it. If a 0.2.0 closed-lid session was cut short, Lidless resets `disablesleep` at launch even before you approve. Nothing to run by hand.

### Uninstall

Open **Settings → Helper → Remove** (it turns closed-lid mode off first; no password), then delete `Lidless.app`. If you deleted the app first, switch the leftover Lidless entry off in **System Settings → General → Login Items & Extensions**.

## FAQ

**Do I need closed-lid mode with an external display?**
No. With a display and power connected, macOS already keeps a closed Mac awake. A regular session is enough, and Lidless leaves your screens alone.

**Why isn't Lidless in the Mac App Store?**
The App Store doesn't allow privileged helpers, and closed-lid mode needs one. Releases are signed and notarized instead.

**Will my MacBook overheat in a bag?**
That's what the safety rules are for: closed-lid mode pauses at serious thermal pressure, the session stops when the Mac is critically hot with the lid closed, and a time limit caps closed-lid time on battery.

**Does Lidless send any data?**
Almost nothing. The only network request is one read of the update feed from GitHub a day. It carries no system data, and release notes are not downloaded. You can switch it off in Settings. There is no analytics and no account. Battery, power source, heat and the lid sensor are read locally for the safety rules.

**How do I update?**
From 0.4.0 on it is automatic: the panel shows the new version and one press installs it. Lidless 0.3.0 has no updater, so download 0.4.0 once by hand; after that you are covered.

## Build from source

Requirements: Xcode 16 or later, and `brew install xcodegen shellcheck`.

```sh
make test      # Swift package tests, shellcheck, helper plist lint
make run       # build and launch the Debug app
make app       # Release universal build → build/Lidless.app
```

Closed-lid mode works only in builds signed with a Developer ID, because the helper and the app check each other's signature:

```sh
SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" make app
```

Unsigned builds run normal sessions and show "needs a signed build" for closed-lid mode. Releases, the hardware checklist, debug aids and the project layout are in [CONTRIBUTING.md](CONTRIBUTING.md).

## Roadmap

- **Triggers:** stay awake while an app runs, on power, with a display or a Wi-Fi network, during downloads, on a schedule.
- **Integrations:** a global hotkey, a URL scheme, a CLI, Shortcuts actions.
- **Statistics and widgets:** session history, a desktop widget, a Control Center control.

Contributions are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md) for the branch workflow.

## License

Lidless is free software under the [GNU General Public License v3.0](LICENSE).

The ON AIR lettering uses [Unbounded](https://github.com/googlefonts/unbounded) (SIL Open Font License 1.1, bundled with its license). The app icon was generated with OpenAI gpt-image; see [docs/asset-provenance.md](docs/asset-provenance.md).
