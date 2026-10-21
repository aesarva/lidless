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

## Releases

```sh
git switch main && git merge --no-ff develop
git tag v0.3.0
```

Update `CHANGELOG.md`, the version in `project.yml` (`MARKETING_VERSION`) and the `VERSION` default in the `Makefile` on `develop` before the merge.

## Before merging

- `make test` passes (Swift tests, shellcheck, helper plist lint).
- `make build` succeeds without new warnings.
- New user-visible text has a Russian translation in `App/Resources/Localizable.xcstrings`.
- UI changes follow [DESIGN.md](DESIGN.md).
