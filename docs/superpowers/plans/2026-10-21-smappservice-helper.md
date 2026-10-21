# Lidless 0.3.0 — помощник через SMAppService. Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** заменить sudoers + `osascript` + root-сторож на демон `LidlessHelper` в подписанном бандле, зарегистрированный через `SMAppService.daemon`, с XPC и проверкой подписи в обе стороны.

**Architecture:** вся логика демона (`SleepGuard`, `LegacyHelperCleaner`) и стороны приложения (`DaemonBackend`, `CodeSigningRequirement`) живёт в `LidlessCore` и тестируется на подделках; цель `LidlessHelper` — тонкая обвязка `NSXPCListener`. Приложение говорит с демоном через существующий `PrivilegedBackend`, поэтому `SessionController` меняется точечно (повторное включение после обрыва).

**Tech Stack:** Swift 6, ServiceManagement (`SMAppService`), `NSXPCConnection`/`NSXPCListener`, Security (`SecCode`), Swift Testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-21-smappservice-helper-design.md`

## Global Constraints

- macOS 14+, Swift 6 language mode, без App Sandbox, hardened runtime для приложения и демона.
- Идентификаторы: приложение `io.github.aesarva.Lidless`; демон — label, Mach-сервис и идентификатор подписи `io.github.aesarva.Lidless.helper`; plist `Contents/Library/LaunchDaemons/io.github.aesarva.Lidless.helper.plist`; бинарник `Contents/MacOS/LidlessHelper`.
- Файл состояния: `/Library/Application Support/Lidless/sleep-owned` (каталог 0755, файл 0644, root:wheel).
- Единственная привилегированная команда: `/usr/bin/pmset -a disablesleep 0|1`; плюс фиксированные удаления файлов 0.2.0 (раздел 5 спеки).
- Требование к клиенту: `anchor apple generic and identifier "io.github.aesarva.Lidless" and certificate leaf[subject.OU] = "<team>"`; к демону — то же с `io.github.aesarva.Lidless.helper`. Team ID — ровно `^[A-Z0-9]{10}$`, иначе считаем, что его нет.
- Таймауты: XPC-вызов из приложения 5 с; `pmset` в демоне — `CommandRunner.defaultTimeout` (15 с); простой демона 10 с; опрос статуса в ожидании разрешения — 1 с.
- Логи: `Logger(subsystem: "io.github.aesarva.Lidless", category: "helper")`; в демоне subsystem `io.github.aesarva.Lidless.helper`.
- Строки интерфейса — английский исходник + русский в `App/Resources/Localizable.xcstrings`.
- Git: каждая задача на ветке от `develop` (`feature/smappservice-helper` — одна ветка на весь план, коммит на задачу), слияние `--no-ff` в `develop` в конце; трейлеры коммитов из CONTRIBUTING/сессии.
- Режим крышки проверяется только на сборке, подписанной Developer ID: `SIGN_IDENTITY="Developer ID Application: Alex Sarva (6H45P75YYV)" scripts/build-app.sh`, запуск из `build/Lidless.app`. Перед пересборкой запущенный `build/Lidless.app` закрыть штатно (`osascript -e 'tell application id "io.github.aesarva.Lidless" to quit'`), предупредив пользователя.

## Review Focus

1. **Две копии Lidless одного пользователя одновременно** (`build/` и «Программы») — выход одной не должен сбросить `disablesleep`, пока другая держит режим. → `twoHoldersResetOnlyAfterBoth` (Task 3).
2. **Соединение, которое только спросило `info()` и закрылось** (настройки, проверка статуса) — не должно ничего сбрасывать. → `releaseOfUnknownHolderIsNoop` (Task 3).
3. **`pmset -g` падает во время `acquire`** — файл состояния не должен остаться, ошибка уходит приложению. → `readFailureDuringAcquireLeavesNoFile` (Task 3).
4. **Разрешение отозвано посреди сессии** (выключили в «Объектах входа») — режим крышки помечен приостановленным, одно уведомление, повтор на следующем опросе. → `connectionLostAndReenableFailsSuspendsOnce` (Task 6).
5. **Демон убит посреди сессии** — приложение включает режим снова, без уведомления, если получилось. → `connectionLostReenablesLidMode` (Task 6).

---

## File Structure

```
Packages/LidlessCore/Sources/LidlessCore/Helper/
  HelperProtocol.swift          @objc XPC-интерфейс + константы имён
  CodeSigningRequirement.swift  team ID из своей подписи, строки требований
  SleepGuard.swift              SleepGuard, SleepSetting, OwnershipStore, FileOwnershipStore
  PmsetSleepSetting.swift       реальный SleepSetting поверх pmset
  LegacyHelperCleaner.swift     удаление установки 0.2.0
  HelperRegistration.swift      протокол + SMAppServiceRegistration
  HelperClient.swift            протокол + XPCHelperClient (таймаут, обрыв)
  DaemonBackend.swift           PrivilegedBackend поверх регистрации и клиента
  PrivilegedBackend.swift       (изменён) HelperStatus, HelperError, протокол
  LidSleepService.swift         (изменён) без маркера
  CommandRunner.swift, PmsetParser.swift   без изменений
  SudoersBackend.swift, SudoersRule.swift  удаляются (Task 6)
LidlessHelper/
  main.swift                    listener, SIGTERM, простой
  HelperConnection.swift        экспортируемый объект на соединение
  io.github.aesarva.Lidless.helper.plist
Helper/                         удаляется целиком (Task 6)
```

---

### Task 1: CodeSigningRequirement и XPC-интерфейс

**Files:**
- Create: `Packages/LidlessCore/Sources/LidlessCore/Helper/CodeSigningRequirement.swift`, `.../Helper/HelperProtocol.swift`
- Test: `Packages/LidlessCore/Tests/LidlessCoreTests/CodeSigningRequirementTests.swift`

**Interfaces:**
- Produces:
  - `public enum HelperIDs { static let app = "io.github.aesarva.Lidless"; static let helper = "io.github.aesarva.Lidless.helper"; static let plistName = "io.github.aesarva.Lidless.helper.plist" }`
  - `@objc public protocol HelperProtocol { func setSleepDisabled(_ disabled: Bool, reply: @escaping @Sendable (String?) -> Void); func info(reply: @escaping @Sendable (String, Bool) -> Void); func removeLegacyHelper(reply: @escaping @Sendable ([String], String?) -> Void) }` — `String?` = текст ошибки или `nil`; `info` → (версия демона, текущий `disablesleep`).
  - `public enum CodeSigningRequirement { static func ownTeamID() -> String?; static func validTeamID(_ s: String?) -> String?; static func requirement(identifier: String, teamID: String?) -> String? }`

- [ ] **Step 1: тесты**
  - `requirementForValidTeam`: `requirement(identifier: HelperIDs.app, teamID: "6H45P75YYV") == #"anchor apple generic and identifier "io.github.aesarva.Lidless" and certificate leaf[subject.OU] = "6H45P75YYV""#`
  - `requirementWithoutTeamIsNil`: `teamID: nil` → `nil`
  - `malformedTeamRejected`: для `"6H45P75YY"`, `"6h45p75yyv"`, `"6H45P75YYV\" or true"`, `""` → `validTeamID` = `nil` и `requirement` = `nil`
  - `testRunnerHasNoTeam`: `ownTeamID()` в `swift test` (ad-hoc/без подписи) → `nil`
- [ ] **Step 2:** `cd Packages/LidlessCore && swift test --filter CodeSigningRequirementTests` → FAIL (нет типов)
- [ ] **Step 3: реализация.** `ownTeamID`: `SecCodeCopySelf` → `SecCodeCopyStaticCode` → `SecCodeCopySigningInformation(…, kSecCSSigningInformation)` → `kSecCodeInfoTeamIdentifier`, пропущенный через `validTeamID`.
- [ ] **Step 4:** тот же фильтр → PASS; `make test` → PASS
- [ ] **Step 5:** commit `feat(helper): code-signing requirements and the XPC interface`

---

### Task 2: Спайк — демон, регистрация и один XPC-вызов (контрольная точка с пользователем)

**Files:**
- Create: `LidlessHelper/main.swift`, `LidlessHelper/io.github.aesarva.Lidless.helper.plist`, `.../Helper/HelperRegistration.swift`, `.../Helper/HelperClient.swift`
- Modify: `project.yml`, `scripts/build-app.sh`, `App/AppDelegate.swift` (временная проба)

**Interfaces:**
- Consumes: `HelperIDs`, `HelperProtocol`, `CodeSigningRequirement` (Task 1)
- Produces:
  - `public enum RegistrationStatus: Equatable, Sendable { case notRegistered, enabled, requiresApproval, notFound }`
  - `public protocol HelperRegistration: Sendable { var status: RegistrationStatus { get }; func register() throws; func unregister() throws; func openSystemSettings() }`; `public struct SMAppServiceRegistration: HelperRegistration { init(plistName: String = HelperIDs.plistName) }` (`openSystemSettings` → `SMAppService.openSystemSettingsLoginItems()`)
  - `public struct HelperInfo: Equatable, Sendable { let version: String; let sleepDisabled: Bool }`
  - `public protocol HelperClient: AnyObject, Sendable { func setSleepDisabled(_ disabled: Bool) throws; func info() throws -> HelperInfo; func removeLegacyHelper() throws -> [String]; var onConnectionLost: (@Sendable () -> Void)? { get set } }`
  - `public final class XPCHelperClient: HelperClient { init(requirement: String, timeout: TimeInterval = 5) }`; ошибки — `HelperError.commandFailed(String)` (в т.ч. `"timed out"`)

- [ ] **Step 1: plist** по таблице 2.1 спеки (`Label`, `BundleProgram` = `Contents/MacOS/LidlessHelper`, `MachServices`, `RunAtLoad` = true, `AssociatedBundleIdentifiers`). Проверка: `plutil -lint`.
- [ ] **Step 2: project.yml.** Цель `LidlessHelper`: `type: tool`, `platform: macOS`, sources `LidlessHelper` (без plist), зависимость `package: LidlessCore`; settings `PRODUCT_NAME: LidlessHelper`, `PRODUCT_BUNDLE_IDENTIFIER: io.github.aesarva.Lidless.helper`, `GENERATE_INFOPLIST_FILE: YES`, `CREATE_INFOPLIST_SECTION_IN_BINARY: YES`, `ENABLE_HARDENED_RUNTIME: YES`, `SKIP_INSTALL: YES`, `SWIFT_VERSION: "6.0"`, `CODE_SIGN_IDENTITY: "-"`, `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` как у приложения. Цель `Lidless`: зависимость `target: LidlessHelper` с `embed: true`, `copy: {destination: executables}`; plist — source с `buildPhase: {copyFiles: {destination: wrapper, subpath: Contents/Library/LaunchDaemons}}`. Если XcodeGen не поддерживает такое копирование зависимости — фаза `postBuildScripts`, копирующая `$BUILT_PRODUCTS_DIR/LidlessHelper` в `$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/`.
- [ ] **Step 3: build-app.sh.** Перед подписью приложения: `codesign "${SIGN_FLAGS[@]}" --identifier io.github.aesarva.Lidless.helper "$APP/Contents/MacOS/LidlessHelper"`; в конце `codesign --verify --strict --deep "$APP"`.
- [ ] **Step 4: минимальный демон** (`main.swift`): `NSXPCListener(machServiceName: HelperIDs.helper)`, делегат: `requirement(identifier: HelperIDs.app, teamID: ownTeamID())` → `nil` → отклонить; иначе `connection.setCodeSigningRequirement(req)`, `exportedInterface = NSXPCInterface(with: HelperProtocol.self)`, экспорт объекта, у которого пока реализован только `info` (версия из `Bundle.main.infoDictionary["CFBundleShortVersionString"]`, `disablesleep` через `PmsetParser`), остальные отвечают `"not implemented"`; `listener.resume()`; `dispatchMain()`.
- [ ] **Step 5: `XPCHelperClient`**: ленивое `NSXPCConnection(machServiceName: HelperIDs.helper, options: .privileged)`, `remoteObjectInterface`, `setCodeSigningRequirement(requirement)`, `interruptionHandler`/`invalidationHandler` → обнулить соединение и вызвать `onConnectionLost`. Синхронные вызовы — `synchronousRemoteObjectProxyWithErrorHandler`, ожидание ответа на `DispatchSemaphore` с таймаутом (без прокрутки run loop, как в `ProcessCommandRunner`); по таймауту `commandFailed("timed out")`.
- [ ] **Step 6: временная проба** в `AppDelegate.applicationDidFinishLaunching`: если `ProcessInfo.processInfo.environment["LIDLESS_HELPER_PROBE"] == "1"` — `SMAppServiceRegistration().register()` (ошибку — в лог), лог статуса, при `.enabled` — `info()` и лог результата; при `.requiresApproval` — `openSystemSettings()`. Помечена `// TEMP: probe, removed in Task 6`.
- [ ] **Step 7: сборка.** `make test` → PASS; закрыть запущенный Lidless (предупредив пользователя); `SIGN_IDENTITY="Developer ID Application: Alex Sarva (6H45P75YYV)" scripts/build-app.sh` → успех; `ls build/Lidless.app/Contents/MacOS build/Lidless.app/Contents/Library/LaunchDaemons` показывает `LidlessHelper` и plist; `codesign -dv build/Lidless.app/Contents/MacOS/LidlessHelper 2>&1 | grep -E "Identifier|TeamIdentifier|runtime"` → `io.github.aesarva.Lidless.helper`, `6H45P75YYV`, флаг runtime.
- [ ] **Step 8: проверка с пользователем.** `LIDLESS_HELPER_PROBE=1 build/Lidless.app/Contents/MacOS/Lidless &`; пользователь включает Lidless в «Объектах входа»; повторный запуск пробы; `log show --last 5m --predicate 'subsystem BEGINSWITH "io.github.aesarva.Lidless"'` показывает статус `enabled` и `info` с версией и `disablesleep`. Негатив: Debug-сборка (`make build`, ad-hoc) с той же переменной — `info()` возвращает ошибку (соединение отклонено демоном). **Если любой пункт расходится со спекой — стоп, отчёт пользователю.**
- [ ] **Step 9:** commit `feat(helper): LidlessHelper daemon skeleton registered via SMAppService`

---

### Task 3: SleepGuard — логика демона

**Files:**
- Create: `.../Helper/SleepGuard.swift`, `.../Helper/PmsetSleepSetting.swift`
- Test: `Packages/LidlessCore/Tests/LidlessCoreTests/SleepGuardTests.swift` (+ `FakeSleepSetting`, `MemoryOwnershipStore` в `Fakes.swift`)

**Interfaces:**
- Produces:
  - `public protocol SleepSetting: Sendable { func isDisabled() throws -> Bool; func setDisabled(_ disabled: Bool) throws }`
  - `public struct PmsetSleepSetting: SleepSetting { init(runner: CommandRunner = ProcessCommandRunner()) }` — `pmset -g` + `PmsetParser.sleepDisabled`, `pmset -a disablesleep 0|1`; ненулевой код → `HelperError.commandFailed(stderr)`
  - `public protocol OwnershipStore: Sendable { func exists() -> Bool; func create() throws; func remove() throws }`; `public struct FileOwnershipStore: OwnershipStore { static let defaultURL = URL(fileURLWithPath: "/Library/Application Support/Lidless/sleep-owned"); init(url: URL = defaultURL) }` (каталог 0755, файл 0644; `remove` отсутствующего — не ошибка)
  - `public final class SleepGuard: @unchecked Sendable { init(setting: SleepSetting, store: OwnershipStore); func acquire(_ holder: UUID) throws; func release(_ holder: UUID) throws; func releaseAll() throws; func recoverAtStart() throws; var isIdle: Bool { get } }` — потокобезопасен (`NSLock`); `isIdle` = нет держателей и не `owned`

- [ ] **Step 1: тесты** (имена → ожидание; `setting.writes` — массив записанных значений):
  - `acquireFromZeroWritesFileThenOne`: старт 0 → `acquire(a)`: `store.exists()`, `writes == [true]`; порядок: файл создан до записи (`FakeSleepSetting` проверяет `store.exists()` в момент `setDisabled(true)`)
  - `releaseLastResetsAndRemovesFile`: после него `release(a)` → `writes == [true, false]`, файла нет
  - `foreignOneIsLeftAlone`: старт 1, файла нет → `acquire(a)`, `release(a)` → `writes == []`
  - `ownOneFromEarlierIsAdopted`: старт 1, файл есть → `acquire(a)`, `release(a)` → `writes == [false]`, файла нет
  - `repeatedAcquireIsIdempotent`: `acquire(a)` ×2, `release(a)` → `writes == [true, false]`
  - `twoHoldersResetOnlyAfterBoth`: `acquire(a)`, `acquire(b)`, `release(a)` → `writes == [true]`; `release(b)` → `[true, false]`
  - `releaseOfUnknownHolderIsNoop`: `acquire(a)`, `release(b)` → `writes == [true]`, файл есть
  - `writeOneFailureRemovesFile`: `setDisabled(true)` бросает → `acquire` бросает, файла нет, `isIdle`
  - `readFailureDuringAcquireLeavesNoFile`: `isDisabled()` бросает → `acquire` бросает, файла нет, `writes == []`
  - `writeZeroFailureKeepsFileAndRetries`: `setDisabled(false)` бросает один раз → `release(a)` бросает, файл есть, `!isIdle`; затем `releaseAll()` → `writes` оканчивается `false`, файла нет
  - `recoverAtStartWithFileResets`: файл есть → `recoverAtStart()` → `writes == [false]`, файла нет
  - `recoverAtStartWithoutFileDoesNothing` → `writes == []`
  - `releaseAllDropsEveryHolder`: `acquire(a)`, `acquire(b)`, `releaseAll()` → `writes == [true, false]`
- [ ] **Step 2:** `swift test --filter SleepGuardTests` → FAIL
- [ ] **Step 3: реализация** по разделу 3 спеки; `owned` в памяти синхронизирован с `store`.
- [ ] **Step 4:** фильтр → PASS; `make test` → PASS
- [ ] **Step 5:** commit `feat(helper): SleepGuard owns disablesleep per connection`

---

### Task 4: LegacyHelperCleaner

**Files:**
- Create: `.../Helper/LegacyHelperCleaner.swift`
- Test: `Packages/LidlessCore/Tests/LidlessCoreTests/LegacyHelperCleanerTests.swift`

**Interfaces:**
- Consumes: `CommandRunner`, `FakeCommandRunner`
- Produces: `public struct LegacyHelperCleaner: Sendable { static let paths = ["/etc/sudoers.d/lidless", "/Library/LaunchDaemons/app.lidless.watchdog.plist", "/Library/PrivilegedHelperTools/app.lidless.watchdog.sh"]; static let markerDirectory = "/Users/Shared/Lidless"; init(root: URL = URL(fileURLWithPath: "/"), runner: CommandRunner = ProcessCommandRunner()); func isPresent() -> Bool; func clean() throws -> [String] }` — возвращает удалённые пути (абсолютные, без `root`).

- [ ] **Step 1: тесты** (временный корень с созданными файлами):
  - `cleansFullInstall`: три файла + маркер → `clean()` возвращает 4 пути, файлов нет, каталог `Users/Shared/Lidless` удалён; `runner.calls` = `[["/usr/bin/pmset","-a","disablesleep","0"], ["/bin/launchctl","bootout","system/app.lidless.watchdog"]]` в этом порядке
  - `noMarkerNoPmset`: без маркера → нет вызова `pmset`
  - `partialInstall`: только plist → возвращает 1 путь, без ошибок
  - `bootoutNotLoadedIsIgnored`: `launchctl` с кодом 3 → без ошибки, файлы удалены
  - `symlinkedMarkerDirIsSkipped`: `Users/Shared/Lidless` — симлинк на другой каталог с файлом `lid-mode.marker` → нет `pmset`, цель симлинка не тронута, сам симлинк не удалён
  - `nonEmptyMarkerDirKept`: в каталоге есть посторонний файл → каталог остаётся
  - `isPresentMatchesAnyPath`: пустой корень → `false`; только sudoers → `true`
- [ ] **Step 2:** `swift test --filter LegacyHelperCleanerTests` → FAIL
- [ ] **Step 3: реализация.** Удаление — `unlink` (не разыменовывает симлинки); проверка каталога маркера — `lstat`, тип `S_IFDIR`; каталог — `rmdir` (удаляет только пустой). Ошибка `pmset` → бросить, ничего не удалив.
- [ ] **Step 4:** фильтр → PASS; `make test` → PASS
- [ ] **Step 5:** commit `feat(helper): remove the 0.2.0 helper install`

---

### Task 5: Демон целиком

**Files:**
- Create: `LidlessHelper/HelperConnection.swift`
- Modify: `LidlessHelper/main.swift`

**Interfaces:**
- Consumes: `SleepGuard`, `PmsetSleepSetting`, `FileOwnershipStore`, `LegacyHelperCleaner`, `HelperProtocol`, `CodeSigningRequirement`
- Produces: `final class HelperConnection: NSObject, HelperProtocol` — `init(holder: UUID, guard: SleepGuard, cleaner: LegacyHelperCleaner, version: String)`

- [ ] **Step 1: `HelperConnection`**: `setSleepDisabled` → `acquire`/`release(holder)`, ошибка → `reply(String(describing: error))`; `info` → `(version, (try? PmsetSleepSetting().isDisabled()) ?? false)`; `removeLegacyHelper` → `cleaner.clean()`.
- [ ] **Step 2: `main.swift`** в этом порядке: logger; `SleepGuard` с реальными зависимостями; `try? guard.recoverAtStart()` (ошибку — в лог) **до** `listener.resume()`; SIGTERM через `DispatchSource.makeSignalSource` (+ `signal(SIGTERM, SIG_IGN)`) → `try? guard.releaseAll()`, `exit(0)`; на каждое соединение — новый `UUID`, `invalidationHandler` → `try? guard.release(holder)` + пересчёт счётчика соединений; таймер простоя: при 0 соединений и `guard.isIdle` 10 с → `exit(0)`, любое новое соединение таймер отменяет. Доступ к счётчику — на одной последовательной очереди.
- [ ] **Step 3: проверка.** `make test` → PASS; подписанная сборка (как Task 2 Step 7) → успех; с пробой из Task 2: `info()` работает; `sudo launchctl print system/io.github.aesarva.Lidless.helper` (выполняет пользователь через `!`) показывает задачу; через ~10 с после выхода пробы процесса `LidlessHelper` нет (`pgrep -x LidlessHelper`).
- [ ] **Step 4:** commit `feat(helper): daemon guards disablesleep by connection, cleans 0.2.0`

---

### Task 6: DaemonBackend и переход приложения на демон; удаление sudoers

**Files:**
- Create: `.../Helper/DaemonBackend.swift`; Test: `DaemonBackendTests.swift`
- Modify: `.../Helper/PrivilegedBackend.swift`, `.../Helper/LidSleepService.swift`, `.../Session/SessionController.swift`, `App/AppDelegate.swift` (+ убрать пробу), `App/Debug/PreviewSupport.swift`, `Tests/.../Fakes.swift`, `LidSleepServiceTests.swift`, `SessionControllerSafetyTests.swift`, `Makefile`, `project.yml`
- Delete: `.../Helper/SudoersBackend.swift`, `.../Helper/SudoersRule.swift`, `Tests/.../HelperTests.swift` (оставить `parsesSleepDisabled` → перенести в `SystemAdapterTests`), каталог `Helper/`

**Interfaces:**
- Consumes: `HelperRegistration`, `HelperClient`, `HelperInfo`, `LegacyHelperCleaner`, `CodeSigningRequirement`
- Produces:
  - `public enum HelperStatus: Equatable, Sendable { case notInstalled, needsApproval, installed, unsigned, error(String) }`
  - `public enum HelperError: Error, Equatable { case commandFailed(String), installFailed(String) }` (`.cancelled`, `.invalidUserName` удалены)
  - `PrivilegedBackend` += `func legacyHelperPresent() -> Bool; func removeLegacyHelper() throws -> [String]; func openSystemSettings()`
  - `public final class DaemonBackend: PrivilegedBackend, @unchecked Sendable { init(registration: HelperRegistration, client: HelperClient?, appVersion: String, legacy: LegacyHelperCleaner = LegacyHelperCleaner()); var onConnectionLost: (@Sendable () -> Void)? }` — `client == nil` ⇔ нет team ID ⇔ `.unsigned`
  - `SessionController.helperConnectionLost()` (public)
  - `LidSleepService.init(backend: PrivilegedBackend)` (без `markerURL`)

- [ ] **Step 1: тесты `DaemonBackendTests`** (`FakeRegistration`, `FakeHelperClient` в `Fakes.swift`):
  - `statusMapping`: `notRegistered→.notInstalled`, `requiresApproval→.needsApproval`, `enabled`+ответ `info`→`.installed`, `notFound→.error`, `client nil→.unsigned`
  - `installRegistersAndOpensSettingsWhenApprovalNeeded`: после `register()` статус `requiresApproval` → `openSystemSettings` вызван 1 раз
  - `installFailureIsInstallFailed`: `register()` бросает → `HelperError.installFailed`
  - `setSleepDisabledPassesThrough` и `clientErrorBecomesCommandFailed`
  - `versionMismatchReregistersOnce`: `info().version == "0.2.9"`, `appVersion == "0.3.0"` → `unregister`+`register` один раз за два вызова `status()`; после — `.error`
  - `unsignedNeverTouchesRegistration`: `client nil` → `install()` бросает `installFailed`, `register` не вызван
- [ ] **Step 2:** `swift test --filter DaemonBackendTests` → FAIL
- [ ] **Step 3: реализация `DaemonBackend`** по разделу 4.1 спеки. `status()` не делает XPC на главном потоке: при `enabled` использует кэш последнего `info()`; `refreshInfo()` (фоновая) обновляет кэш и проверяет версию; до первого ответа `enabled` считается `.installed`. `isSleepDisabled()` → `client.info().sleepDisabled`.
- [ ] **Step 4: `LidSleepService` без маркера**: `enable()` → `setSleepDisabled(true)`, `enabledHere = true`; `disable()` → при `enabledHere` `setSleepDisabled(false)`, затем `enabledHere = false`; `recoverIfNeeded()` → `true`. Тесты `LidSleepServiceTests` переписать: `enableThenDisable`, `disableWithoutEnableIsNoop`, `disableFailureKeepsEnabled` (повторный `disable` снова зовёт backend), `recoverIsNoop`.
- [ ] **Step 5: тесты `SessionController`** (`SessionControllerSafetyTests`):
  - `connectionLostReenablesLidMode`: активная сессия с режимом крышки → `helperConnectionLost()` → `lid.enableCalls` +1, `lidModeActive`, уведомлений нет
  - `connectionLostAndReenableFailsSuspendsOnce`: `failEnable = true` → дважды `helperConnectionLost()` → `lidModeActive == false`, `lidModeSuspendedReason == .helperUnavailable`, `attention == .helperUnavailable`, одно уведомление
  - `pollRetriesHelperSuspendedLidMode`: после предыдущего `failEnable = false`, `update(readings:)` → режим снова активен
  - `connectionLostWithoutLidModeDoesNothing`: сессии нет → `enableCalls == 0`
  - `helperDidChangeRetriesSuspendedLidMode`: сессия, режим приостановлен `.helperUnavailable` → `helperDidChange()` → `enableCalls` +1
- [ ] **Step 6: `SessionController`** (отступление от спеки 4.2: повторное включение после обрыва делает `SessionController`, а не `LidSleepService` — там уже есть путь ошибок и уведомлений): `helperConnectionLost()` — при `session?.lidModeActive == true` → `enableLidMode()`; при неудаче (уже обрабатывается `enableLidMode`) дополнительно `lidModeActive = false`. В `update(readings:)` при активной сессии, `settings.lidModeEnabled`, `lidModeSuspendedReason == .helperUnavailable` → `enableLidMode()`. `helperDidChange()` при активной сессии делает то же; при `.off` — как сейчас.
- [ ] **Step 7: приложение.** `AppDelegate`: `let team = CodeSigningRequirement.ownTeamID()`; `client = CodeSigningRequirement.requirement(identifier: HelperIDs.helper, teamID: team).map { XPCHelperClient(requirement: $0) }`; `backend = DaemonBackend(registration: SMAppServiceRegistration(), client: client, appVersion: Bundle.main.shortVersion)`; `backend.onConnectionLost = { Task { @MainActor [weak controller] in controller?.helperConnectionLost() } }`. Убрать пробу Task 2, `helperDir`, тип поля `backend` → `DaemonBackend`. `PreviewBackend`, `FakeBackend` — новые методы. Удалить файлы из списка Delete, ресурсы `Helper/*` из `project.yml`, строки `shellcheck … Helper/*.sh Helper/tests/*.sh`, `watchdog_test.sh`, `plutil -lint Helper/...` из `make test` (оставить `shellcheck scripts/*.sh` и добавить `plutil -lint LidlessHelper/io.github.aesarva.Lidless.helper.plist`). Временно поправить `switch` по `HelperError`/`HelperStatus` в `ControlRows`, `HelperTab`, чтобы собиралось (полный UI — Task 7).
- [ ] **Step 8:** `make test` → PASS; `make build` → `BUILD SUCCEEDED` без новых предупреждений; `grep -rn "Sudoers\|osascript\|lid-mode.marker\|watchdog" App Packages/LidlessCore/Sources project.yml Makefile` → только `LegacyHelperCleaner`.
- [ ] **Step 9:** commit `feat(helper): talk to the daemon, drop the sudoers helper`

---

### Task 7: Интерфейс — панель, настройки, меню, миграция

**Files:**
- Modify: `App/Services/HelperModel.swift`, `App/Popover/ControlRows.swift`, `App/Settings/HelperTab.swift`, `App/StatusItem/StatusItemController.swift`, `App/StatusItem/QuickMenu.swift`, `App/AppDelegate.swift`, `App/Debug/SnapshotExporter.swift`, `App/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: `HelperStatus`, `PrivilegedBackend.legacyHelperPresent/removeLegacyHelper/openSystemSettings`, `SessionController.helperDidChange`
- Produces: `HelperModel`: `status`, `isWorking`, `legacyRemoved: Bool`, `func install() async -> HelperError?`, `func uninstall() async -> HelperError?`, `func openSystemSettings()`, `func refresh()`, `var onBecameInstalled: (() -> Void)?`

- [ ] **Step 1: `HelperModel`.** `refresh()` фиксирует переход в `.installed` → `onBecameInstalled?()` и, если `backend.legacyHelperPresent()`, один раз за запуск фоновый `removeLegacyHelper()` → `legacyRemoved = true` (ошибка — в лог). Пока `status == .needsApproval` — таймер 1 с (`RunLoop.main`, `.common`) вызывает `refresh()`; останавливается при выходе из `.needsApproval`. `AppDelegate`: `helper.onBecameInstalled = { controller.helperDidChange() }`; `refresh()` на `NSApplication.didBecomeActiveNotification`.
- [ ] **Step 2: `LidRow`.** Подписи (en → ru):
  - `.notInstalled` → «needs a one-time approval in System Settings» → «нужно один раз разрешить в Системных настройках»
  - `.needsApproval` → «allow Lidless in System Settings → Login Items» → «разреши Lidless в Системных настройках → Объекты входа» (нажатие → `openSystemSettings()`)
  - `.unsigned` → «needs a signed build» → «нужна подписанная сборка» (переключатель недоступен)
  - `.error` при включённом режиме → «helper is off in System Settings» → «помощник выключен в Системных настройках»
  - нажатие при `.notInstalled` → `install()`, `settings.lidModeEnabled = true` (через `controller.setLidMode(true)`), без ожидания разрешения.
- [ ] **Step 3: `HelperTab`.** Статусы: «Not set up» / «Waiting for approval» + кнопка «Open System Settings…» / «Running, version X» / «Needs a signed build» / «Error: …» (ru: «Не настроен» / «Ждёт разрешения» + «Открыть Системные настройки…» / «Работает, версия X» / «Нужна подписанная сборка» / «Ошибка: …»). Кнопки «Set Up…» / «Remove» (ru «Настроить…» / «Удалить»); «Remove» сначала `controller.setLidMode(false)`, при ошибке возвращает прежнее значение. Строка `legacyRemoved`: «The 0.2.0 helper was removed.» / «Помощник 0.2.0 удалён.» Пояснение: «Closed-lid mode uses a small background helper that can do one thing: turn pmset disablesleep on and off. It accepts commands only from Lidless signed by the same developer, needs no password, and restores normal sleep the moment Lidless quits or crashes.» / «Режим крышки использует небольшой фоновый помощник, который умеет одно: включать и выключать pmset disablesleep. Он принимает команды только от Lidless с той же подписью, не требует пароля и возвращает обычный сон, как только Lidless завершается или падает.»
- [ ] **Step 4: меню и снимки.** `QuickMenu`: пункт режима крышки недоступен при `.needsApproval`/`.unsigned` (параметр `helperInstalled` заменить на `helperStatus: HelperStatus`). `SnapshotExporter`/`PreviewSupport`: состояния `needs-approval`, `unsigned` вместо `needs-helper`. Удалить из каталога строк ключи, которые больше не используются (`needs a one-time helper install`, `installing the helper…`, `helper install failed: %@`, старое пояснение).
- [ ] **Step 5: проверка.** `make test` → PASS; `make build` без предупреждений; `build/Build/Products/Debug/Lidless.app/Contents/MacOS/Lidless -SnapshotDir <scratchpad>/snap` → просмотреть PNG `needs-approval`, `unsigned`, вкладку «Помощник» на en и ru (язык переключается в настройках снимков так же, как раньше); подписи не обрезаются.
- [ ] **Step 6:** commit `feat(ui): approve the helper in System Settings; migrate from 0.2.0`

---

### Task 8: Документация и версия

**Files:**
- Modify: `README.md`, `README.ru.md`, `CHANGELOG.md`, `project.yml` (`MARKETING_VERSION: "0.3.0"`), `Makefile` (`VERSION ?= 0.3.0`), `CONTRIBUTING.md` (если упоминает `Helper/`)

- [ ] **Step 1: README (en, ru)** по разделу 9 спеки: «Closed-lid mode and the helper» — демон в бандле, разрешение в «Объектах входа», без пароля; таблица путей: `Contents/MacOS/LidlessHelper`, plist в бандле, `/Library/Application Support/Lidless/sleep-owned`; «Security model» — проверка подписи в обе стороны, одна команда, сброс при разрыве соединения и при загрузке; оговорка о бандле, доступном на запись, удаляется; Uninstall — «Settings → Helper → Remove», затем удалить приложение; переход с 0.2.0; «Build from source» — режим крышки только в подписанной сборке, команда `SIGN_IDENTITY=… scripts/build-app.sh`; «Manual verification» — 9 пунктов из раздела 8 спеки; Roadmap — убрать пункт про SMAppService; Quick start шаг 3 — «approve the helper in System Settings» вместо пароля.
- [ ] **Step 2: CHANGELOG** — `## 0.3.0 — <дата релиза>`: помощник через SMAppService без пароля и sudoers; сон возвращается сразу после выхода/вылета; чужой `disablesleep` не трогается; 0.2.0 удаляется автоматически после разрешения; режим крышки только в подписанных сборках.
- [ ] **Step 3:** `grep -rn "sudoers\|watchdog\|osascript\|administrator password\|пароль администратора" README*.md` → только раздел о переходе с 0.2.0; `make test` → PASS.
- [ ] **Step 4:** commit `docs: the SMAppService helper (0.3.0)`

---

### Task 9: Ручная проверка на подписанной сборке (с пользователем) и слияние

- [ ] **Step 1:** закрыть запущенный Lidless (предупредив пользователя); `SIGN_IDENTITY="Developer ID Application: Alex Sarva (6H45P75YYV)" scripts/build-app.sh`; запуск `open build/Lidless.app`.
- [ ] **Step 2:** пройти с пользователем 9 пунктов раздела 8 спеки, фиксируя `pmset -g | grep SleepDisabled` и `log show … subsystem BEGINSWITH "io.github.aesarva.Lidless"` после каждого. Пункт 8 (переход с 0.2.0) — первым, пока установка 0.2.0 на этом Mac цела: до запуска `ls /etc/sudoers.d/lidless /Library/LaunchDaemons/app.lidless.watchdog.plist`, после разрешения — файлов нет, `launchctl print system/app.lidless.watchdog` (пользователь, через `!`) — «не найдено».
- [ ] **Step 3:** всё, что не прошло, — отдельные исправления (TDD) на той же ветке, повтор пункта.
- [ ] **Step 4:** финальное ревью ветки; слияние `feature/smappservice-helper` в `develop` (`--no-ff`, трейлеры), push `develop`. Релиз 0.3.0 (`release.sh`, main, тег, GitHub Release) — только по просьбе пользователя.
