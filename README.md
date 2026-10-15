# WakeUp

A macOS menu-bar app that keeps your Mac awake, optionally with the lid closed.

- Start a session for a preset duration, until a given time, or indefinitely.
- Optionally keep the display on, or let it sleep while the system stays awake.
- Closed-lid mode keeps the Mac running with the lid shut (needs a one-time helper install, see below).
- Safety rules stop a session on low battery, overheating, or after too long on battery with the lid closed.
- Interface in English and Russian (follows the system language).

Requires macOS 14 or later.

## Install

1. Download `WakeUp.zip` from the GitHub Releases page and unzip it.
2. Move `WakeUp.app` to `/Applications`.
3. The app is ad-hoc signed (not notarized), so Gatekeeper will block the first launch. Either right-click the app and choose **Open**, or remove the quarantine flag:

   ```
   xattr -dr com.apple.quarantine /Applications/WakeUp.app
   ```

## The helper (closed-lid mode)

Normal sessions use a standard power assertion and need nothing extra. Closed-lid mode has to run `pmset -a disablesleep 1`, which requires root. On first use WakeUp asks for your administrator password once and installs:

| Path | Purpose |
|---|---|
| `/etc/sudoers.d/wakeup` | allows your user to run `/usr/bin/pmset -a disablesleep 0` and `... 1` without a password, and nothing else |
| `/Library/PrivilegedHelperTools/app.wakeup.watchdog.sh` | watchdog script that restores normal sleep if WakeUp is gone |
| `/Library/LaunchDaemons/app.wakeup.watchdog.plist` | launchd job (`app.wakeup.watchdog`) that runs the watchdog every 60 seconds and at load |

A marker file, `/Users/Shared/WakeUp/lid-mode.marker`, records that WakeUp turned closed-lid mode on. If WakeUp quits, crashes, or the Mac reboots mid-session, the watchdog sees the marker without a running app and runs `pmset -a disablesleep 0`.

### Security model

Be aware of what this does and does not protect against:

- Until the app is signed with a Developer ID and the helper is registered through `SMAppService`, the helper scripts are copied from inside the app bundle at install time. That bundle is user-writable, so the install is only as trustworthy as the app you downloaded. Only install the helper from a copy of WakeUp you trust.
- After installation, everything that runs with privileges lives in root-owned locations (the three paths above).
- The sudoers rule allows exactly `pmset -a disablesleep 0|1` and no other command or argument.

### Uninstall

Open **Settings -> Helper -> Uninstall**, enter your password, then delete `WakeUp.app`. This removes the sudoers file, watchdog script, launchd job and marker, and restores normal sleep.

## Build

Requirements: Xcode 16 or later, plus

```
brew install xcodegen shellcheck
```

```
make build     # generate the Xcode project and build (Debug)
make run       # build and launch
make test      # Swift package tests, shellcheck, watchdog script tests
make release   # Release build, ad-hoc signed, build/WakeUp.zip
```

## Manual verification

These checks need a real MacBook and are not automated. Status: pending.

1. 15-minute session with the lid open and "display may sleep": the display turns off, the system stays awake (`pmset -g assertions`).
2. Closed-lid mode, no external display and no charger, lid closed for 5 minutes: `pmset -g log` shows no Sleep; an SSH session stays alive.
3. Force Quit WakeUp while closed-lid mode is active: within 60 seconds `pmset -g` shows `SleepDisabled 0`.
4. Reboot in the middle of a session without WakeUp launching at login: after boot `SleepDisabled 0`.
5. Battery rule with a threshold above the current charge: the session stops and a notification appears.
6. Uninstall the helper: the sudoers file, plist and script are removed and `SleepDisabled 0`.

## По-русски

WakeUp - приложение в строке меню macOS, которое не даёт Mac уснуть, в том числе с закрытой крышкой.

**Установка.** Скачайте `WakeUp.zip` из GitHub Releases, распакуйте, перенесите `WakeUp.app` в «Программы». Приложение подписано ad-hoc и не нотаризовано: при первом запуске нажмите правой кнопкой -> «Открыть» или выполните `xattr -dr com.apple.quarantine /Applications/WakeUp.app`.

**Помощник.** Режим закрытой крышки требует прав root для `pmset -a disablesleep`. При первом включении WakeUp один раз запросит пароль администратора и установит `/etc/sudoers.d/wakeup` (разрешает только `pmset -a disablesleep 0|1`), сторожа `/Library/PrivilegedHelperTools/app.wakeup.watchdog.sh` и launchd-задачу `/Library/LaunchDaemons/app.wakeup.watchdog.plist`; маркер состояния - `/Users/Shared/WakeUp/lid-mode.marker`. Если WakeUp завершится аварийно, сторож вернёт обычный сон. Пока приложение не подписано Developer ID и не использует SMAppService, скрипты ставятся из пакета приложения, доступного пользователю на запись, поэтому установка настолько надёжна, насколько надёжно скачанное приложение; после установки всё выполняется из каталогов, принадлежащих root.

**Удаление.** Настройки -> Помощник -> Удалить, затем удалите `WakeUp.app`.

**Сборка.** `make build`, `make test`, `make release`; нужны Xcode 16+ и `brew install xcodegen shellcheck`.
