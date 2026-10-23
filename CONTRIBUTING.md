# Contributing

## Branches

- **`main`** — released code only. It changes only by merging `develop` for a release.
- **`develop`** — integration branch. Every change lands here first.
- **Work branches** — one per feature, fix or improvement, created from `develop` and merged back into `develop`:

  | Prefix | For |
  |---|---|
  | `feature/<name>` | new functionality |
  | `fix/<name>` | bug fixes |
  | `improve/<name>` | refinements, refactors, UI polish |
  | `docs/<name>` | documentation only |

```sh
git switch develop && git pull
git switch -c feature/hotkey
# … commits …
git switch develop && git merge --no-ff feature/hotkey
git branch -d feature/hotkey
```

Merge with `--no-ff` (or a pull request into `develop`) so each change stays visible as one unit in the history.

## Building

```sh
make test      # Swift package tests, shellcheck, helper plist lint
make build     # generate the Xcode project and build (Debug)
make run       # build and launch the Debug app
make app       # Release universal build (arm64 + x86_64), hardened runtime → build/Lidless.app
make dmg       # make app + dist/Lidless-<VERSION>.dmg without a Developer ID
```

`scripts/build-app.sh` honours `ARCHS` (e.g. `ARCHS=arm64`), `VERSION` and `SIGN_IDENTITY` (default `-`, ad-hoc). The build number is the commit count. Closed-lid mode needs a Developer ID signature (`SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)"`); run that build from one place, since macOS ties the helper registration to the bundle path.

### Project layout

```
App/                     SwiftUI/AppKit app: menu-bar panel, settings, icon, notifications
Packages/LidlessCore/    sessions, safety policy, helper client and daemon logic, IOKit adapters (+ tests)
LidlessHelper/           the root helper daemon and its launchd plist
scripts/                 build-app.sh and release.sh
docs/                    images, asset provenance, design specs and implementation plans
DESIGN.md                the "On Air" visual system
PRODUCT.md               who Lidless is for and what it promises
```

### Debug aids

Debug builds accept `-SnapshotDir <dir>` (render every panel state and settings tab to PNGs, then quit) and `-OpenPanelOnLaunch YES -CapturePanelTo <png>` (capture the live panel). These runs use in-memory settings and a fake helper, so they never touch your real settings or `disablesleep`.

## Before merging

- `make test` passes (Swift tests, shellcheck, helper plist lint).
- `make build` succeeds without new warnings.
- New user-visible text has a Russian translation in `App/Resources/Localizable.xcstrings`.
- UI changes follow [DESIGN.md](DESIGN.md).
- README.md and README.ru.md stay in sync.

## Releases

Lidless is distributed outside the App Store, as a DMG signed with a **Developer ID Application** certificate and notarized by Apple. Store the notarization credentials once:

```sh
xcrun notarytool store-credentials Lidless --apple-id <you@example.com> --team-id <TEAMID>
```

1. On `develop`: update `CHANGELOG.md`, the version in `project.yml` (`MARKETING_VERSION`, set once at the top for both the app and the helper) and the `VERSION` default in the `Makefile`.
2. Build, sign, notarize and staple the app and the DMG, and check Gatekeeper:

   ```sh
   scripts/release.sh 0.3.0      # --unsigned checks everything except signing and notarization
   ```

3. Run the hardware checklist below on the signed build.
4. Merge, tag and publish:

   ```sh
   git switch main && git merge --no-ff develop -m "Release 0.3.0"
   git tag -a v0.3.0 -m "Lidless 0.3.0" && git push origin main v0.3.0
   gh release create v0.3.0 dist/Lidless-0.3.0.dmg dist/Lidless.dmg --title "Lidless 0.3.0"
   ```

   `Lidless.dmg` keeps the README's `releases/latest/download/Lidless.dmg` link working.

### Hardware checklist

These need a real MacBook and a Developer ID–signed build. Last passed in full for 0.3.0.

1. First closed-lid mode: macOS shows a notification and opens Login Items; after you allow Lidless, closed-lid mode turns on by itself.
2. Lid closed for 5 minutes, no charger and no external display: the Mac does not sleep and an SSH session stays alive.
3. Force-quit Lidless in closed-lid mode: `pmset -g` shows `SleepDisabled 0` within a couple of seconds.
4. `sudo kill -9` the helper daemon mid-session: launchd starts it again, closed-lid mode is restored and `SleepDisabled 1` comes back.
5. Reboot mid-session: after boot `SleepDisabled 0`.
6. Switch Lidless off in Login Items mid-session: macOS quits Lidless and `SleepDisabled 0`.
7. `sudo pmset -a disablesleep 1` by hand, then turn closed-lid mode on and off: it stays 1.
8. Upgrading from 0.2.0 on the same Mac: the sudoers file and watchdog are gone and the `app.lidless.watchdog` job is unloaded.
9. Settings → Helper → Remove: the daemon is unregistered and `SleepDisabled 0`.

A helper plist change only reaches launchd when the helper is registered again: bump the version, or use Settings → Helper → Remove and Set Up on a dev build.
