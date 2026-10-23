# Lidless 0.3.0 — помощник через SMAppService

Дата: 2026-10-21
Статус: черновик на ревью

## 1. Цель и контекст

В 0.2.0 режим закрытой крышки держится на правиле `/etc/sudoers.d/lidless`, которое ставится через `osascript … with administrator privileges` скриптом `install.sh` из бандла, и на root-стороже `app.lidless.watchdog` (опрос раз в 60 с по маркеру в `/Users/Shared/Lidless`). Скрипты копируются из бандла, доступного пользователю на запись, — это оговорка в README «Security model».

С Developer ID (`6H45P75YYV`) привилегированную часть заменяет демон в подписанном бандле, зарегистрированный через `SMAppService.daemon`. Подпись проверяет macOS, пользователь разрешает демон в «Системных настройках → Основные → Объекты входа», пароль администратора не нужен.

**Критерии успеха:**
- в подписанной сборке режим крышки включается без пароля, после одного разрешения в Системных настройках;
- после вылета, Force Quit или выхода Lidless обычный сон возвращается сразу (вместо «до 60 с»), после перезагрузки посреди сессии — при загрузке;
- `disablesleep`, выставленный не Lidless, не трогается;
- установка 0.2.0 убирается автоматически, без пароля;
- оговорка о доверии к бандлу уходит из README.

**Решения, принятые на обсуждении:**
- схема sudoers удаляется полностью; режим крышки работает только в подписанных сборках (релизы и сборки разработчика со своим сертификатом);
- файлы 0.2.0 удаляет новый демон после разрешения;
- реакция на исчезновение приложения — по разрыву XPC-соединения (подход 1), без опроса.

## 2. Компоненты

### 2.1 Бандл

```
Lidless.app/Contents/
  MacOS/Lidless
  MacOS/LidlessHelper                                   демон (root), hardened runtime
  Library/LaunchDaemons/io.github.aesarva.Lidless.helper.plist
```

plist демона:

| Ключ | Значение |
|---|---|
| `Label` | `io.github.aesarva.Lidless.helper` |
| `BundleProgram` | `Contents/MacOS/LidlessHelper` |
| `MachServices` | `{ io.github.aesarva.Lidless.helper = true }` |
| `RunAtLoad` | `true` — сброс зависшего `disablesleep` при загрузке |
| `AssociatedBundleIdentifiers` | `[io.github.aesarva.Lidless]` — в «Объектах входа» виден как Lidless |

### 2.2 LidlessCore (логика, покрыта тестами)

| Тип | Назначение |
|---|---|
| `HelperProtocol` (`@objc`) | XPC-интерфейс: `setSleepDisabled(_:reply:)`, `info(reply:)` → версия демона и текущий `disablesleep`, `removeLegacyHelper(reply:)` |
| `SleepGuard` | вся логика демона (раздел 3); зависимости — `SleepSetting` (чтение/запись `disablesleep`), `OwnershipStore` (файл состояния); без XPC и root |
| `PmsetSleepSetting` | реальный `SleepSetting`: `pmset -a disablesleep 0|1` и `pmset -g` через `ProcessCommandRunner` (таймаут 15 с) и `PmsetParser` |
| `LegacyHelperCleaner` | удаление установки 0.2.0 по фиксированному списку путей (раздел 5); корень файловой системы и `CommandRunner` подставляются |
| `HelperRegistration` (протокол) | обёртка над `SMAppService.daemon(plistName:)`: `status`, `register()`, `unregister()`, `openSystemSettings()` |
| `DaemonBackend` | сторона приложения, реализует `PrivilegedBackend` (раздел 4) |
| `CodeSigningRequirement` | строит требование подписи для собеседника из team ID собственной подписи |

### 2.3 Обвязка демона (`LidlessHelper/main.swift`, без логики)

- `NSXPCListener(machServiceName:)`; в `listener(_:shouldAcceptNewConnection:)` — `setCodeSigningRequirement` (раздел 6), экспорт объекта, привязанного к соединению; `invalidationHandler` соединения → `SleepGuard.release(holder:)`.
- При старте — `SleepGuard.recoverAtStart()`.
- SIGTERM (выключение в «Объектах входа», `unregister`, выключение Mac) → `SleepGuard.releaseAll()`, выход.
- Простой: нет соединений и ничего не удерживается 10 с → `exit(0)`; launchd запустит снова по требованию.

### 2.4 Что удаляется

`SudoersBackend`, `SudoersRule`, `Helper/install.sh`, `uninstall.sh`, `watchdog.sh`, `app.lidless.watchdog.plist`, `Helper/tests/watchdog_test.sh`, вызов `osascript`, маркер `/Users/Shared/Lidless/lid-mode.marker`, `HelperError.invalidUserName`, shellcheck для `Helper/` в `make test`. Остаются `ProcessCommandRunner`, `PmsetParser`, `PrivilegedBackend` (с изменённым набором статусов).

## 3. Логика демона (`SleepGuard`)

**Состояние:** множество держателей (идентификаторы соединений, включивших режим крышки); флаг `owned` — «`disablesleep 1` выставили мы»; файл `/Library/Application Support/Lidless/sleep-owned` (каталог root:wheel 0755, файл 0644) — сохранённое `owned` на случай вылета демона или перезагрузки.

**`acquire(holder)`** — `setSleepDisabled(true)`:
1. Если держателей нет и не `owned`:
   - `disablesleep` = 0 → записать файл, затем выставить 1; `owned = true`. Ошибка записи 1 → удалить файл, вернуть ошибку.
   - `disablesleep` = 1 и файл есть → `owned = true` (наш, остался с прошлого раза).
   - `disablesleep` = 1, файла нет → чужой; `owned = false`, ничего не меняем.
2. Добавить держателя. Повторный `acquire` того же держателя — без эффекта.

**`release(holder)`** — `setSleepDisabled(false)` или разрыв соединения: убрать держателя; если держателей не осталось и `owned` → выставить 0, затем удалить файл, `owned = false`. Ошибка `pmset` → файл и `owned` остаются, ошибка уходит вызывающему (при разрыве — в лог); повтор при следующем `release`/`acquire`/старте.

**`releaseAll()`** — SIGTERM: убрать всех держателей, далее как `release`.

**`recoverAtStart()`** — файл есть → выставить 0, удалить файл. Если в этот момент Lidless ещё работает (вылетел только демон), приложение заметит разрыв и вызовет `acquire` заново (раздел 4).

**Несколько пользователей:** у каждого Lidless своё соединение; 0 возвращается, только когда отпустили все.

## 4. Сторона приложения

### 4.1 `DaemonBackend: PrivilegedBackend`

`HelperStatus` становится:

```swift
public enum HelperStatus: Equatable, Sendable {
    case notInstalled          // SMAppService .notRegistered
    case needsApproval         // .requiresApproval
    case installed             // .enabled и демон ответил на info()
    case unsigned              // сборка без team ID: режим крышки недоступен
    case error(String)         // .notFound, нет ответа, несовпадение версий после перерегистрации
}
```

- `install()` → `register()`; при `.requiresApproval` → `openSystemSettings()`. Ошибка регистрации → `HelperError.installFailed`.
- `uninstall()` → `unregister()` (демон получает SIGTERM и возвращает сон сам).
- `setSleepDisabled(_:)` — синхронный вызов через `synchronousRemoteObjectProxyWithErrorHandler` с таймаутом 5 с (ожидание на семафоре, без прокрутки run loop); таймаут или ошибка → `HelperError.commandFailed`.
- `isSleepDisabled()` → `info()`.
- Соединение одно, `NSXPCConnection(machServiceName:options: .privileged)`, ленивое; `interruptionHandler`/`invalidationHandler` сбрасывают его и вызывают `onConnectionLost`.
- Версия: если `info().version` ≠ версия приложения или `info()` не удался у включённой регистрации (демон другой сборки рвёт соединение; launchd снял задание) → `unregister()` + `register()` один раз за запуск; не помогло → `.error`.
- `status()` вызывается на главном потоке: только чтение `SMAppService.status`; ответ демона на `info()` кэшируется при последнем успешном вызове и обновляется в `refresh` фоновой задачей.

### 4.2 `LidSleepService`

Маркер убирается. Остаётся `enabledHere`. На `onConnectionLost` при `enabledHere` → повторный `setSleepDisabled(true)`; ошибка → существующий путь `SessionController`: оранжевая точка, уведомление «помощник недоступен» (одно), повтор каждые 15 с. `recoverIfNeeded()` возвращает `true` без действий (восстановление на демоне); вызов при запуске остаётся ради единообразия протокола.

### 4.3 Интерфейс

**Переключатель «Режим крышки» в панели:**
- `.notInstalled` → `install()`: регистрация, macOS показывает своё уведомление «Добавлен фоновый объект», открываются «Объекты входа». Желание включить режим сохраняется (`lidModeEnabled = true`).
- `.needsApproval` → подпись «разреши Lidless в Системных настройках» (цвет caution), нажатие — снова открыть настройки. Статус опрашивается при открытии панели, при `didBecomeActive` и раз в 1 с, пока ждём; при переходе в `.installed` → `controller.helperDidChange()`, режим включается сам.
- `.unsigned` → подпись «нужна подписанная сборка», переключатель недоступен.
- `.error` после работы (выключен в «Объектах входа», демон не отвечает) → оранжевая точка и подпись «помощник выключен в Системных настройках» / «ошибка помощника».

**Настройки → Помощник:** статус («Не настроен» / «Ждёт разрешения» + «Открыть Системные настройки» / «Работает, версия X» / «Нужна подписанная сборка» / «Ошибка: …»), кнопки «Настроить» и «Удалить» (сначала выключает режим крышки, как сейчас, затем `unregister`), строка «Помощник 0.2.0 удалён» после миграции, новый поясняющий текст: без пароля и sudoers; демон умеет только `pmset disablesleep` и принимает команды только от Lidless с той же подписью; при выходе или вылете Lidless сон возвращается сразу.

**Меню по правому клику:** пункт режима крышки недоступен при `.needsApproval`/`.unsigned`, как сейчас при отсутствии помощника.

Все строки — английский и русский в `Localizable.xcstrings`.

## 5. Переход с 0.2.0

Признак: существует хотя бы один из `/etc/sudoers.d/lidless`, `/Library/LaunchDaemons/app.lidless.watchdog.plist`, `/Library/PrivilegedHelperTools/app.lidless.watchdog.sh` (проверка существования доступна без root).

Когда статус стал `.installed` и признак есть → один вызов `removeLegacyHelper`. Демон (`LegacyHelperCleaner`):
1. если есть `/Users/Shared/Lidless/lid-mode.marker` → `pmset -a disablesleep 0`;
2. `launchctl bootout system/app.lidless.watchdog` (ошибка «не загружен» игнорируется);
3. удаляет ровно эти пути: три файла выше и маркер; каталог `/Users/Shared/Lidless` — только если пуст. Пути не приходят из запроса; симлинки не разыменовываются (`unlink`). `/Users/Shared` доступен всем на запись, поэтому маркер и каталог трогаются, только если `/Users/Shared/Lidless` — настоящий каталог (`lstat`, не симлинк); иначе шаги 1 и маркер пропускаются.

Ответ — список удалённого; приложение показывает строку в настройках. Ошибка — в лог и в строку статуса, повтор при следующем запуске. До разрешения старые файлы безвредны: правилом sudoers никто не пользуется, сторож без маркера ничего не делает.

## 6. Подпись и безопасность

- Демон при старте читает свой team ID (`SecCodeCopySelf` → `kSecCodeInfoTeamIdentifier`). Требование к клиенту: `anchor apple generic and identifier "io.github.aesarva.Lidless" and certificate leaf[subject.OU] = "<team>"`. Нет team ID (ad-hoc) → все соединения отклоняются.
- Приложение ставит соединению симметричное требование: `identifier "io.github.aesarva.Lidless.helper"` и тот же team ID. Своего team ID нет → статус `.unsigned`, соединение не открывается.
- Интерфейс демона — три операции без аргументов-путей; единственная привилегированная команда — `pmset -a disablesleep 0|1` (плюс фиксированные удаления из раздела 5).
- Файл состояния — в каталоге root; общедоступный маркер больше не используется.

## 7. Сборка

- `project.yml`: цель `LidlessHelper` (`type: tool`, зависимость LidlessCore, `PRODUCT_BUNDLE_IDENTIFIER: io.github.aesarva.Lidless.helper`, `CREATE_INFOPLIST_SECTION_IN_BINARY: YES`, `ENABLE_HARDENED_RUNTIME: YES`); цель приложения зависит от неё и копирует бинарник в `Contents/MacOS`, plist — в `Contents/Library/LaunchDaemons`.
- `scripts/build-app.sh`: подписать `Contents/MacOS/LidlessHelper` (`--options runtime`, `--timestamp` при Developer ID, `--identifier io.github.aesarva.Lidless.helper`), затем приложение; без `--deep`. `codesign --verify --strict --deep` в конце.
- `scripts/release.sh` без изменений: нотаризация проверяет вложенный код.
- `MARKETING_VERSION` → `0.3.0`; версия демона = версия приложения (`CFBundleShortVersionString` во встроенном Info.plist).
- Разработка режима крышки — только на подписанной сборке, запускаемой из одного места: регистрация привязана к пути бандла.

## 8. Тестирование

**Автоматически (Swift Testing, `make test`):**
- `SleepGuard`: включение при 0; чужая 1 (не сбрасывается при `release`); своя 1 с прошлого раза; повторный `acquire`; два держателя; `release` последнего; ошибка записи 1 (файл удалён); ошибка записи 0 (файл остаётся, повтор успешен); `recoverAtStart` с файлом и без; `releaseAll`.
- `LegacyHelperCleaner`: временный корень; с маркером и без; частично удалённая установка; симлинк вместо файла не разыменовывается; ошибка `launchctl` «не загружен» игнорируется.
- `DaemonBackend`: перевод статусов `HelperRegistration` → `HelperStatus`; таймаут вызова → `commandFailed`; несовпадение версии → одна перерегистрация.
- `CodeSigningRequirement`: строка требования для team ID; `nil` → отказ.
- `LidSleepService`: повтор `acquire` после `onConnectionLost`; ошибка → `SessionController` поднимает предупреждение один раз.
- Удаляются тесты sudoers и `watchdog_test.sh`.

**Первым шагом плана — спайк** на подписанной сборке: регистрация, одобрение, один XPC-вызов с проверкой подписи в обе стороны, поведение статуса после одобрения. Расхождение с дизайном → остановка и обсуждение до основной работы.

**Вручную на подписанной сборке** (заменяет чек-лист README):
1. Первое включение: уведомление macOS, открываются «Объекты входа», после разрешения режим крышки включается сам.
2. Крышка закрыта 5 минут без зарядки и монитора: Mac не спит, SSH жив.
3. Force Quit в режиме крышки: `SleepDisabled 0` в течение пары секунд.
4. `sudo kill -9` демона посреди сессии: режим крышки восстанавливается, `SleepDisabled 1`.
5. Перезагрузка посреди сессии: после загрузки `SleepDisabled 0`.
6. Выключение Lidless в «Объектах входа» посреди сессии: `SleepDisabled 0`, оранжевая точка.
7. `sudo pmset -a disablesleep 1` вручную, затем включить и выключить режим крышки: остаётся 1.
8. Переход с 0.2.0 на этом Mac: файлы sudoers и сторожа удалены, задача `app.lidless.watchdog` выгружена.
9. «Удалить» в настройках: демон снят, `SleepDisabled 0`.

## 9. Документация и релиз

README (en, ru): раздел «Closed-lid mode and the helper» и «Security model» переписаны под демон; таблица путей — бандл и файл состояния; удаление — «Настройки → Помощник → Удалить», затем удалить приложение; чек-лист из раздела 8. CHANGELOG: 0.3.0. Релиз — `scripts/release.sh 0.3.0`, слияние в main и GitHub Release (по просьбе).

## 10. Вне объёма

Автообновление (Sparkle), Homebrew cask, триггеры и интеграции (этапы 2–4), запуск демона без подписанной сборки.
