# WakeUp Core (этап 1) Implementation Plan

> **2026-10-16:** приложение переименовано в **Lidless**. Все идентификаторы в коде заменены по схеме `WakeUp`→`Lidless`, `wakeup`→`lidless` (Bundle ID `io.github.alexsarva.Lidless`, пакет `LidlessCore`, `/etc/sudoers.d/lidless`, label `app.lidless.watchdog`, маркер `/Users/Shared/Lidless/lid-mode.marker`). Ниже — исходный текст без изменений.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Нативное приложение строки меню macOS «WakeUp», которое держит Mac бодрствующим (в том числе с закрытой крышкой через `pmset disablesleep`), с защитой батареи/нагрева, сторожем от падений и поповером из плиток.

**Architecture:** Вся логика и системные адаптеры живут в SPM-пакете `Packages/WakeUpCore` (тестируется `swift test` без Xcode); адаптеры закрыты протоколами и подменяются фейками. Таргет `App/` (генерируется XcodeGen) — тонкий AppKit/SwiftUI-слой: `NSStatusItem` + `NSPopover` + окно настроек, собирающий объекты ядра в `AppDelegate`. Привилегии — через `SudoersBackend` (правило sudoers на одну команду) + root-LaunchDaemon-сторож, оба ставятся shell-скриптами из `Helper/`.

**Tech Stack:** Swift 6, SwiftUI, AppKit, IOKit (`IOPMAssertion`, `IOPowerSources`, IORegistry), UserNotifications, ServiceManagement, Swift Testing, XcodeGen, shellcheck, bash.

**Spec:** `docs/superpowers/specs/2026-10-15-wakeup-core-design.md`

## Global Constraints

- Минимальная ОС: macOS 14 (`.macOS(.v14)`, `MACOSX_DEPLOYMENT_TARGET = 14.0`); Swift language mode 6.
- Bundle ID: `io.github.alexsarva.WakeUp`; имя исполняемого файла: `WakeUp`.
- Без App Sandbox. `LSUIElement = YES` (нет иконки в Dock).
- Локализация: английский (исходный) + русский, String Catalog `Localizable.xcstrings`.
- Логирование: `os.Logger(subsystem: "io.github.alexsarva.WakeUp", category:)`, категории `session`, `safety`, `helper`, `ui`.
- Пути помощника (точно): `/etc/sudoers.d/wakeup`, `/Library/PrivilegedHelperTools/app.wakeup.watchdog.sh`, `/Library/LaunchDaemons/app.wakeup.watchdog.plist`, launchd label `app.wakeup.watchdog`, маркер `/Users/Shared/WakeUp/lid-mode.marker`.
- Единственные привилегированные команды в рантайме: `/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0|1`.
- Xcode выбирается через `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` в Makefile (не трогаем `xcode-select`).
- Значения по умолчанию: длительность — бессрочно; пресеты 15/60/180 мин; экран «может гаснуть»; режим крышки выкл; таймер в строке меню выкл; старт сессии при запуске выкл; правило батареи вкл, порог 20% (диапазон 5–50); правило нагрева вкл; лимит крышки вкл, 240 мин (диапазон 30–720).
- Предупреждение об окончании — за 300 с; опрос мониторов — каждые 15 с; сторож — каждые 60 с + `RunAtLoad`.

## Review Focus

1. **Отказ `sudo` при включении режима крышки** — маркер не должен остаться на диске, иначе сторож и проверка при старте будут «чинить» то, чего мы не ставили. → тест `enableFailureRemovesMarker` в Task 4.
2. **Выход приложения при активном режиме крышки** (`applicationWillTerminate`) — `disablesleep` обязан вернуться в 0 синхронно до завершения. → тест `appQuitDisablesLidMode` в Task 6.
3. **Небезопасное имя пользователя в sudoers** (пробел, запятая, `%group`, `ALL`) — установка должна отказать, а не записать широкое правило. → тест `rejectsUnsafeUserNames` в Task 3.
4. **Приложение лежит по пути с пробелом/кавычками** (`~/Downloads/WakeUp 2.app`, `O'Brien`) — команда установки для osascript должна экранироваться корректно. → тест `installCommandEscapesPaths` в Task 3.
5. **Mac без батареи** (Mac mini/Studio: `batteryLevel == nil`, `onBattery == false`) — правило батареи не срабатывает, старт не блокируется. → тест `noBatteryNeverBlocksOrStops` в Task 2.

---

## File Structure

```
Makefile
project.yml
README.md
Packages/WakeUpCore/
  Package.swift
  Sources/WakeUpCore/
    Model/SessionDuration.swift       SessionDuration
    Model/Session.swift               Session, SessionState, StopReason, SafetyReason
    Model/WakeUpSettings.swift        WakeUpSettings, SafetySettings
    Model/Clock.swift                 WakeClock, SystemClock
    Safety/SafetyPolicy.swift         ThermalLevel, SafetyReadings, SafetyDecision, SafetyPolicy
    Safety/SafetyEngine.swift         PowerReading, PowerMonitoring, ThermalMonitoring, LidMonitoring, SafetyEngine
    Helper/CommandRunner.swift        CommandResult, CommandRunner, ProcessCommandRunner
    Helper/PrivilegedBackend.swift    HelperStatus, HelperError, PrivilegedBackend
    Helper/PmsetParser.swift
    Helper/SudoersRule.swift
    Helper/SudoersBackend.swift
    Helper/LidSleepService.swift      LidSleepControlling, LidSleepService
    Session/SessionServices.swift     SleepAssertionService, Notifier, WakeNotification, SettingsStore
    Session/SessionController.swift
    Presentation/StatusPresentation.swift  IconGlyph, StatusPresentation
    System/IOPMSleepAssertionService.swift
    System/IOPowerMonitor.swift
    System/SystemThermalMonitor.swift
    System/IORegistryLidMonitor.swift
    System/UserDefaultsSettingsStore.swift
  Tests/WakeUpCoreTests/
    Fakes.swift, ModelTests.swift, SafetyPolicyTests.swift, HelperTests.swift,
    LidSleepServiceTests.swift, SessionControllerTests.swift, SessionControllerSafetyTests.swift,
    SafetyEngineTests.swift, StatusPresentationTests.swift, SystemAdapterTests.swift
Helper/
  install.sh, uninstall.sh, watchdog.sh, app.wakeup.watchdog.plist
  tests/watchdog_test.sh
App/
  WakeUpApp.swift, AppDelegate.swift
  StatusItem/StatusItemController.swift, StatusItem/IconRenderer.swift, StatusItem/QuickMenu.swift
  Popover/PopoverView.swift, Popover/Tiles.swift, Popover/DurationPills.swift
  Settings/SettingsWindowController.swift, Settings/SettingsView.swift (+ GeneralTab, SafetyTab, HelperTab, AboutTab в том же каталоге)
  Services/UserNotifier.swift, Services/LoginItem.swift, Services/HelperModel.swift
  Resources/Info.plist, Resources/Localizable.xcstrings
```

Все типы ядра — `public`. Всё, что трогает состояние сессии или UI, — `@MainActor`; тесты контроллера/движка помечены `@MainActor`.

---

### Task 1: Пакет WakeUpCore, модели и инструменты

**Files:**
- Create: `Packages/WakeUpCore/Package.swift`, `Sources/WakeUpCore/Model/{SessionDuration,Session,WakeUpSettings,Clock}.swift`, `Tests/WakeUpCoreTests/ModelTests.swift`, `Makefile`

**Interfaces — Produces:**
```swift
public enum SessionDuration: Codable, Equatable, Sendable {
    case minutes(Int), until(Date), indefinite
    public func endDate(from now: Date) -> Date?   // .minutes → now+m*60, .until(d) → d, .indefinite → nil
}
public enum SafetyReason: String, Codable, Equatable, Sendable { case lowBattery, thermal, lidOnBatteryLimit, helperUnavailable }
public enum StopReason: Equatable, Sendable { case user, timerExpired, safety(SafetyReason), appQuit, assertionFailed }
public struct Session: Equatable, Sendable {
    public var startedAt: Date
    public var endsAt: Date?
    public var keepDisplayOn: Bool
    public var lidModeActive: Bool              // disablesleep=1 установлен нами
    public var lidModeEnabledAt: Date?          // момент последнего успешного включения
    public var lidModeSuspendedReason: SafetyReason?
    public var endingSoonNotified: Bool         // true → предупреждение не слать
}
public enum SessionState: Equatable, Sendable { case off, active(Session) }
public struct SafetySettings: Codable, Equatable, Sendable {
    public var batteryRuleEnabled = true, batteryThreshold = 20
    public var thermalRuleEnabled = true
    public var lidLimitRuleEnabled = true, lidLimitMinutes = 240
}
public struct WakeUpSettings: Codable, Equatable, Sendable {
    public var defaultDuration: SessionDuration = .indefinite
    public var presetMinutes: [Int] = [15, 60, 180]
    public var keepDisplayOn = false
    public var lidModeEnabled = false
    public var showTimerInMenuBar = false
    public var startSessionOnLaunch = false
    public var safety = SafetySettings()
}
public protocol WakeClock: Sendable { var now: Date { get } }
public struct SystemClock: WakeClock { public init(); public var now: Date { Date() } }
```

- [ ] **Step 1:** `brew install xcodegen shellcheck`. Expected: `xcodegen --version` и `shellcheck --version` печатают версии.
- [ ] **Step 2:** Создать `Package.swift` (tools 6.0, `platforms: [.macOS(.v14)]`, library `WakeUpCore`, testTarget `WakeUpCoreTests`) и `Makefile` с `export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer` и целью `test: ; cd Packages/WakeUpCore && swift test`.
- [ ] **Step 3: Write failing tests** в `ModelTests.swift`:
```swift
@Test func minutesEndDate() { let t0 = Date(timeIntervalSince1970: 1000)
    #expect(SessionDuration.minutes(15).endDate(from: t0) == t0.addingTimeInterval(900))
    #expect(SessionDuration.indefinite.endDate(from: t0) == nil)
    #expect(SessionDuration.until(t0.addingTimeInterval(42)).endDate(from: t0) == t0.addingTimeInterval(42)) }
@Test func settingsDefaults() { let s = WakeUpSettings()
    #expect(s.defaultDuration == .indefinite); #expect(s.presetMinutes == [15, 60, 180])
    #expect(!s.keepDisplayOn && !s.lidModeEnabled && !s.showTimerInMenuBar && !s.startSessionOnLaunch)
    #expect(s.safety == SafetySettings(batteryRuleEnabled: true, batteryThreshold: 20, thermalRuleEnabled: true, lidLimitRuleEnabled: true, lidLimitMinutes: 240)) }
@Test func settingsCodableRoundTrip() throws { var s = WakeUpSettings(); s.defaultDuration = .minutes(60); s.safety.batteryThreshold = 35
    #expect(try JSONDecoder().decode(WakeUpSettings.self, from: JSONEncoder().encode(s)) == s) }
```
- [ ] **Step 4:** `make test` → FAIL (типы не определены).
- [ ] **Step 5:** Реализовать модели из блока Interfaces (memberwise init `SafetySettings` должен быть public — объявить явно).
- [ ] **Step 6:** `make test` → PASS.
- [ ] **Step 7:** `git add Packages Makefile && git commit -m "feat(core): models, settings and package scaffold"`

---

### Task 2: SafetyPolicy

**Files:** Create `Sources/WakeUpCore/Safety/SafetyPolicy.swift`, `Tests/WakeUpCoreTests/SafetyPolicyTests.swift`

**Interfaces:**
- Consumes: `Session`, `SafetySettings`, `SafetyReason` (Task 1).
- Produces:
```swift
public enum ThermalLevel: Int, Comparable, Sendable { case nominal, fair, serious, critical }
public struct SafetyReadings: Equatable, Sendable {
    public var batteryLevel: Int?; public var onBattery: Bool; public var thermal: ThermalLevel
    public var lidClosed: Bool; public var lidClosedOnBatterySince: Date?; public var now: Date
}
public enum SafetyDecision: Equatable, Sendable { case none, suspendLidMode(SafetyReason), stopSession(SafetyReason) }
public enum SafetyPolicy {
    public static func evaluate(_ r: SafetyReadings, session: Session, settings: SafetySettings) -> SafetyDecision
    public static func canStart(_ r: SafetyReadings, settings: SafetySettings) -> Bool
}
```

Правила, в порядке проверки (первое сработавшее — результат):
1. `batteryRuleEnabled && onBattery && batteryLevel != nil && batteryLevel! < batteryThreshold` → `.stopSession(.lowBattery)`
2. `thermalRuleEnabled && lidClosed && thermal == .critical` → `.stopSession(.thermal)`
3. `thermalRuleEnabled && session.lidModeActive && thermal >= .serious` → `.suspendLidMode(.thermal)`
4. `lidLimitRuleEnabled && session.lidModeActive && lidClosed && onBattery && since != nil` где `start = max(since, session.lidModeEnabledAt ?? since)` и `now - start >= lidLimitMinutes*60` → `.suspendLidMode(.lidOnBatteryLimit)`
5. иначе `.none`

`canStart` = `!(batteryRuleEnabled && onBattery && batteryLevel.map { $0 < batteryThreshold } == true)`.

- [ ] **Step 1: Write failing tests** — табличный `@Test(arguments:)` с хелпером `readings(battery:onBattery:thermal:lidClosed:since:)` (по умолчанию `80, false, .nominal, false, nil`, `now = t0`) и `session(lidActive:enabledAt:)`:
  - `lowBatteryStops`: 19%, onBattery → `.stopSession(.lowBattery)`; 20% → `.none`; 10% на сети → `.none`; правило выключено → `.none`.
  - `criticalWithLidClosedStops`: lidClosed, `.critical` → `.stopSession(.thermal)`; lid open, `.critical`, lidActive → `.suspendLidMode(.thermal)`.
  - `seriousSuspendsLidOnlyWhenActive`: `.serious`, lidActive → `.suspendLidMode(.thermal)`; lidActive=false → `.none`.
  - `lidLimit`: since = t0−14400, enabledAt = nil, closed, onBattery, lidActive → `.suspendLidMode(.lidOnBatteryLimit)`; since = t0−14399 → `.none`; since = t0−20000 но enabledAt = t0−60 → `.none` (сброс счётчика повторным включением).
  - `stopBeatsSuspend`: 10% onBattery + `.serious` + lidActive → `.stopSession(.lowBattery)`.
  - `noBatteryNeverBlocksOrStops` (Review Focus 5): `batteryLevel: nil, onBattery: false` → `evaluate == .none`, `canStart == true`.
  - `canStartBlocksBelowThreshold`: 15% onBattery → false; 15% на сети → true.
- [ ] **Step 2:** `make test` → FAIL.
- [ ] **Step 3:** Реализовать по правилам выше.
- [ ] **Step 4:** `make test` → PASS.
- [ ] **Step 5:** `git commit -am "feat(core): safety policy"` (с `git add` новых файлов).

---

### Task 3: Привилегированный бэкенд (sudoers)

**Files:** Create `Helper/{CommandRunner,PrivilegedBackend,PmsetParser,SudoersRule,SudoersBackend}.swift` (в `Sources/WakeUpCore/`), `Tests/WakeUpCoreTests/HelperTests.swift`, `Tests/WakeUpCoreTests/Fakes.swift`

**Interfaces — Produces:**
```swift
public struct CommandResult: Equatable, Sendable { public let exitCode: Int32; public let stdout: String; public let stderr: String }
public protocol CommandRunner: Sendable { func run(_ executable: String, _ arguments: [String]) throws -> CommandResult }
public struct ProcessCommandRunner: CommandRunner { public init() }   // Foundation.Process, ждёт завершения

public enum HelperStatus: Equatable, Sendable { case notInstalled, installed, error(String) }
public enum HelperError: Error, Equatable { case cancelled, invalidUserName(String), commandFailed(String), installFailed(String) }
public protocol PrivilegedBackend: Sendable {
    func status() -> HelperStatus
    func install() throws
    func uninstall() throws
    func setSleepDisabled(_ disabled: Bool) throws
    func isSleepDisabled() throws -> Bool
}

public enum PmsetParser { public static func sleepDisabled(in pmsetOutput: String) -> Bool }
public enum SudoersRule {
    public static func isValidUserName(_ name: String) -> Bool   // ^[A-Za-z_][A-Za-z0-9_.-]{0,31}$ и name != "ALL"
    public static func render(userName: String) throws -> String
}
public final class SudoersBackend: PrivilegedBackend {
    public static let sudoersPath = "/etc/sudoers.d/wakeup"
    public static let watchdogScriptPath = "/Library/PrivilegedHelperTools/app.wakeup.watchdog.sh"
    public static let watchdogPlistPath = "/Library/LaunchDaemons/app.wakeup.watchdog.plist"
    public init(runner: CommandRunner, helperDirectory: URL, userName: String,
                temporaryDirectory: URL = FileManager.default.temporaryDirectory,
                fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
    static func shellQuote(_ s: String) -> String          // '…' с заменой ' на '\''
    static func appleScriptString(_ s: String) -> String   // "…" с экранированием \ и "
    func installCommand(sudoersFile: URL) -> String        // для тестов
}
```

Точный текст `SudoersRule.render(userName: "alex")`:
```
# Installed by WakeUp. Remove via WakeUp → Settings → Helper.
alex ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
```
(с завершающим `\n`; при невалидном имени — `throw HelperError.invalidUserName(name)`).

Поведение `SudoersBackend`:
- `setSleepDisabled(d)`: `runner.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", d ? "1" : "0"])`; `exitCode != 0` → `throw .commandFailed(stderr)`.
- `isSleepDisabled()`: `run("/usr/bin/pmset", ["-g"])` → `PmsetParser`.
- `status()`: `sudo -n -l /usr/bin/pmset -a disablesleep 1` с кодом 0 **и** существуют оба пути сторожа → `.installed`; sudo не 0 → `.notInstalled`; sudo 0, но нет файлов сторожа → `.error("watchdog missing")`.
- `install()`: записать `render(userName:)` в `temporaryDirectory/wakeup-sudoers-<UUID>`; выполнить `run("/usr/bin/osascript", ["-e", "do shell script " + appleScriptString(installCommand(...)) + " with administrator privileges"])`, где `installCommand = "/bin/bash " + [install.sh, sudoersFile, userName, helperDirectory].map(shellQuote).joined(" ")`; stderr содержит `(-128)` → `.cancelled`; иной ненулевой код → `.installFailed(stderr)`; временный файл удаляется всегда.
- `uninstall()`: то же через `uninstall.sh` (аргументы: путь маркера `/Users/Shared/WakeUp/lid-mode.marker`).

`PmsetParser.sleepDisabled`: `true`, если есть строка, которая после trim начинается с `SleepDisabled` и чьё последнее поле — `1`; отсутствие строки → `false` (macOS не печатает её при 0).

`Fakes.swift`: `final class FakeCommandRunner: CommandRunner, @unchecked Sendable` — словарь ответов по `"exe arg1 arg2"` и журнал вызовов `calls: [[String]]` под `NSLock`.

- [ ] **Step 1: Write failing tests** (`HelperTests.swift`):
  - `parsesSleepDisabled`: `" SleepDisabled\t\t1"` в выводе → true; `"SleepDisabled 0"` → false; вывод без строки → false.
  - `rendersExactRule`: `render(userName: "alex")` == текст выше.
  - `renderedRulePassesVisudo`: записать `render(userName: NSUserName())` во временный файл, `Process` `/usr/sbin/visudo -cf <file>` → exit 0.
  - `rejectsUnsafeUserNames` (Review Focus 3): для `"bad user"`, `"a,b"`, `"%admin"`, `"ALL"`, `""`, `"1abc"`, `"x\ny"` → `throws HelperError.invalidUserName`; `"alex"`, `"a.b-c_d"` → ок.
  - `setSleepDisabledRunsSudoN`: вызов `setSleepDisabled(true)` → `calls == [["/usr/bin/sudo","-n","/usr/bin/pmset","-a","disablesleep","1"]]`; ответ с exit 1 и stderr `"a password is required"` → `throws .commandFailed("a password is required")`.
  - `statusMatrix`: (sudo 0, файлы есть) → `.installed`; (sudo 1) → `.notInstalled`; (sudo 0, файлов нет) → `.error("watchdog missing")`.
  - `installCommandEscapesPaths` (Review Focus 4): helperDirectory `/Users/o'brien/Down loads/WakeUp "2".app/Contents/Resources/Helper`; проверить, что `installCommand` равен ожидаемой строке с `'\''`, а `appleScriptString` превращает `"` в `\"` и `\` в `\\`; дополнительно — прогнать `installCommand`, заменив `/bin/bash` на `/usr/bin/printf '%s\n'`, через `/bin/sh -c` и убедиться, что получены ровно 4 аргумента, совпадающие с исходными.
  - `installCancelled`: osascript отвечает exit 1, stderr `"execution error: User canceled. (-128)"` → `throws .cancelled`; временный файл удалён.
- [ ] **Step 2:** `make test` → FAIL.
- [ ] **Step 3:** Реализовать файлы по Interfaces.
- [ ] **Step 4:** `make test` → PASS.
- [ ] **Step 5:** Commit `feat(core): sudoers privileged backend`.

---

### Task 4: LidSleepService (маркер)

**Files:** Create `Sources/WakeUpCore/Helper/LidSleepService.swift`, `Tests/WakeUpCoreTests/LidSleepServiceTests.swift`; Modify `Fakes.swift` (+ `FakeBackend`)

**Interfaces:**
- Consumes: `PrivilegedBackend`, `HelperStatus`, `HelperError` (Task 3).
- Produces:
```swift
@MainActor public protocol LidSleepControlling: AnyObject {
    func helperStatus() -> HelperStatus
    func enable() throws
    func disable() throws
    func recoverIfNeeded()
}
@MainActor public final class LidSleepService: LidSleepControlling {
    public static let defaultMarkerURL = URL(fileURLWithPath: "/Users/Shared/WakeUp/lid-mode.marker")
    public init(backend: PrivilegedBackend, markerURL: URL = LidSleepService.defaultMarkerURL)
}
```
Поведение: `enable()` — создать каталог маркера при необходимости, записать маркер, затем `backend.setSleepDisabled(true)`; при ошибке удалить маркер и пробросить. `disable()` — нет маркера → no-op; иначе `setSleepDisabled(false)`, затем удалить маркер (при ошибке маркер остаётся, ошибка пробрасывается). `recoverIfNeeded()` — если маркер есть, `try? disable()` с логом в категорию `helper`.

`FakeBackend: PrivilegedBackend, @unchecked Sendable` — `var status`, `var failNextSet: HelperError?`, `var setCalls: [Bool]`.

- [ ] **Step 1: Write failing tests** (маркер во временном каталоге):
  - `enableWritesMarkerThenDisables`: `enable()` → маркер существует, `setCalls == [true]`; `disable()` → маркера нет, `setCalls == [true, false]`.
  - `enableFailureRemovesMarker` (Review Focus 1): `failNextSet = .commandFailed("x")` → `enable()` throws, маркера нет.
  - `disableWithoutMarkerIsNoop`: `disable()` → `setCalls == []`.
  - `recoverResetsWhenMarkerPresent`: создать маркер вручную → `recoverIfNeeded()` → `setCalls == [false]`, маркера нет.
- [ ] **Step 2:** `make test` → FAIL. **Step 3:** реализовать. **Step 4:** `make test` → PASS.
- [ ] **Step 5:** Commit `feat(core): lid sleep service with marker`.

---

### Task 5: SessionController — жизненный цикл и таймер

**Files:** Create `Sources/WakeUpCore/Session/{SessionServices,SessionController}.swift`, `Tests/WakeUpCoreTests/SessionControllerTests.swift`; Modify `Fakes.swift` (+ `FakeAssertions`, `FakeNotifier`, `FakeLid`, `MemorySettingsStore`, `MutableClock`)

**Interfaces:**
- Consumes: Task 1 models, `SafetyPolicy`/`SafetyReadings` (Task 2), `LidSleepControlling` (Task 4).
- Produces:
```swift
@MainActor public protocol SleepAssertionService: AnyObject { func acquire(keepDisplayOn: Bool) throws; func release() }  // acquire заменяет текущие
public enum WakeNotification: Equatable, Sendable {
    case endingSoon(endsAt: Date), sessionEnded(StopReason), lidModeSuspended(SafetyReason), assertionFailed(String)
}
@MainActor public protocol Notifier: AnyObject { func post(_ n: WakeNotification); func cancelEndingSoon() }
@MainActor public protocol SettingsStore: AnyObject { func load() -> WakeUpSettings; func save(_ s: WakeUpSettings) }
public enum StartBlock: Equatable, Sendable { case lowBattery(threshold: Int) }

@MainActor @Observable public final class SessionController {
    public init(assertions: SleepAssertionService, lid: LidSleepControlling, notifier: Notifier,
                settingsStore: SettingsStore, clock: WakeClock)
    public private(set) var state: SessionState            // .off
    public private(set) var attention: SafetyReason?
    public private(set) var startBlock: StartBlock?
    public private(set) var readings: SafetyReadings?
    public var settings: WakeUpSettings                     // didSet → settingsStore.save
    public var session: Session? { get }
    @discardableResult public func start(_ duration: SessionDuration) -> Bool
    public func stop(_ reason: StopReason)
    public func restart(_ duration: SessionDuration)        // off → start
    public func extend(byMinutes: Int)                      // endsAt = max(endsAt, now) + m; бессрочная — no-op
    public func toggle()                                    // off → start(settings.defaultDuration); active → stop(.user)
    public func setKeepDisplayOn(_ on: Bool)
    public func setLidMode(_ on: Bool)                      // Task 6
    public func tick()
    public func update(readings: SafetyReadings)            // Task 6
    public func clearAttention()
    public func recoverAtLaunch()
}
```
Поведение этого таска:
- `start`: если `readings` есть и `!SafetyPolicy.canStart` → `startBlock = .lowBattery(threshold)`, вернуть false. Иначе `assertions.acquire(keepDisplayOn: settings.keepDisplayOn)`; ошибка → `notifier.post(.assertionFailed(String(describing: error)))`, false. Создать `Session` (`endingSoonNotified = endsAt.map { $0.timeIntervalSince(now) <= 300 } ?? true`), `startBlock = nil`; если `settings.lidModeEnabled` → включить режим крышки (Task 6; в этом таске — заглушка-вызов того же приватного `enableLidMode()`).
- `stop`: no-op если off; `assertions.release()`; если `lidModeActive` → `try lid.disable()` (ошибка → `attention = .helperUnavailable`, `post(.lidModeSuspended(.helperUnavailable))`); `notifier.cancelEndingSoon()`; при `.timerExpired` или `.safety` → `post(.sessionEnded(reason))`; `state = .off`.
- `restart`/`extend`: пересчитать `endsAt` и `endingSoonNotified` (по тому же правилу 300 с), `cancelEndingSoon()`.
- `tick`: active, `endsAt != nil`: `now >= endsAt` → `stop(.timerExpired)`; иначе если `!endingSoonNotified && endsAt - now <= 300` → `post(.endingSoon(endsAt:))`, флаг = true.
- `setKeepDisplayOn`: сохранить в settings; если active — `acquire(keepDisplayOn:)` повторно и обновить `session.keepDisplayOn`.
- `recoverAtLaunch`: `lid.recoverIfNeeded()`; если `settings.startSessionOnLaunch` → `start(settings.defaultDuration)`.
- `update(readings:)` — в этом таске только: сохранить `readings`; если off → `startBlock = canStart ? nil : .lowBattery(threshold)`. Ветку для активной сессии добавляет Task 6.

- [ ] **Step 1: Write failing tests** (`MutableClock` с `advance(_:)`):
  - `startAcquiresAndStopReleases`: `start(.minutes(60))` → `assertions.acquired == [false]`, `session?.endsAt == t0+3600`; `stop(.user)` → `released == 1`, `state == .off`, нет `.sessionEnded`.
  - `timerExpiresEvenAfterOversleep`: старт 15 мин, `clock.advance(7200)`, `tick()` → off, `notifier.posted.last == .sessionEnded(.timerExpired)`.
  - `endingSoonOnceAt300s`: старт 15 мин; advance 599 → tick → нет `endingSoon`; advance 1 → tick → один `.endingSoon(endsAt: t0+900)`; ещё tick → всё ещё один.
  - `noEndingSoonForShortSession`: `start(.until(t0+240))` → tick на t0+10 → нет `endingSoon`.
  - `extendPushesEndAndRearmsWarning`: старт 15 мин, advance 700, tick (warning), `extend(byMinutes: 30)` → `endsAt == t0+2700`, `cancelEndingSoonCount == 1`, на t0+2400 tick → второй `endingSoon`.
  - `restartReplacesDuration`: старт 15 мин → `restart(.minutes(180))` → `endsAt == t0+10800`.
  - `toggleUsesDefaultDuration`: settings.defaultDuration = `.indefinite` → `toggle()` → `endsAt == nil`; `toggle()` → off.
  - `displayToggleReacquires`: старт, `setKeepDisplayOn(true)` → `acquired == [false, true]`, `settings.keepDisplayOn == true`, сохранено в store.
  - `assertionFailureDoesNotStart`: `FakeAssertions.failNext` → `start` false, off, posted `.assertionFailed`.
  - `lowBatteryBlocksStart`: `update(readings:)` с 10% onBattery → `start` false, `startBlock == .lowBattery(threshold: 20)`.
  - `recoverAtLaunchCallsLidAndOptionallyStarts`: `lid.recoverCalls == 1`; с `startSessionOnLaunch = true` → active.
- [ ] **Step 2:** `make test` → FAIL. **Step 3:** реализовать. **Step 4:** `make test` → PASS.
- [ ] **Step 5:** Commit `feat(core): session controller lifecycle and timer`.

---

### Task 6: SessionController — режим крышки и защита

**Files:** Modify `Sources/WakeUpCore/Session/SessionController.swift`; Create `Tests/WakeUpCoreTests/SessionControllerSafetyTests.swift`

**Interfaces:** Consumes Task 2 (`SafetyPolicy.evaluate`), Task 4 (`LidSleepControlling`), Task 5 (controller). Новых публичных API нет.

Поведение:
- `enableLidMode()` (private): `try lid.enable()` → `lidModeActive = true`, `lidModeEnabledAt = now`, `lidModeSuspendedReason = nil`; ошибка → `lidModeActive = false`, `lidModeSuspendedReason = .helperUnavailable`, `attention = .helperUnavailable`, `post(.lidModeSuspended(.helperUnavailable))`. Сессия продолжается.
- `setLidMode(on)`: `settings.lidModeEnabled = on`; если active: `on` → `enableLidMode()`; `off` → `try? lid.disable()`, `lidModeActive = false`, `lidModeSuspendedReason = nil`.
- `update(readings:)` (дополнить ветку из Task 5): если active → `SafetyPolicy.evaluate`:
  - `.stopSession(r)` → `attention = r`, `stop(.safety(r))`.
  - `.suspendLidMode(r)` → `try? lid.disable()`, `lidModeActive = false`, `lidModeSuspendedReason = r`, `attention = r`, `post(.lidModeSuspended(r))`. `settings.lidModeEnabled` не меняется.
- `clearAttention()` → `attention = nil`.

- [ ] **Step 1: Write failing tests:**
  - `startWithLidModeEnables`: `settings.lidModeEnabled = true`, `start` → `lid.enableCalls == 1`, `session?.lidModeActive == true`, `lidModeEnabledAt == t0`.
  - `stopDisablesLid`: затем `stop(.user)` → `lid.disableCalls == 1`.
  - `appQuitDisablesLidMode` (Review Focus 2): lid активен → `stop(.appQuit)` → `lid.disableCalls == 1`, нет `.sessionEnded`.
  - `lidEnableFailureKeepsSession`: `FakeLid.failEnable = true` → active, `lidModeActive == false`, `attention == .helperUnavailable`, posted `.lidModeSuspended(.helperUnavailable)`.
  - `thermalSuspendsLidButKeepsSession`: lid активен, `update` с `.serious` → active, `lidModeActive == false`, `lidModeSuspendedReason == .thermal`, `settings.lidModeEnabled == true`, `lid.disableCalls == 1`.
  - `userReenableClearsSuspensionAndResetsLimit`: после suspend `.lidOnBatteryLimit` → `advance(60)`, `setLidMode(true)` → `lidModeActive`, `lidModeSuspendedReason == nil`, `lidModeEnabledAt == t0+60`; следующий `update` с тем же старым `since` → остаётся активным.
  - `lowBatteryStopsWithAttention`: `update` 10% onBattery → off, `attention == .lowBattery`, posted `.sessionEnded(.safety(.lowBattery))`.
  - `clearAttention` → nil.
- [ ] **Step 2:** FAIL. **Step 3:** реализовать. **Step 4:** `make test` → PASS (включая тесты Task 5).
- [ ] **Step 5:** Commit `feat(core): lid mode and safety handling in controller`.

---

### Task 7: SafetyEngine

**Files:** Create `Sources/WakeUpCore/Safety/SafetyEngine.swift`, `Tests/WakeUpCoreTests/SafetyEngineTests.swift`; Modify `Fakes.swift` (+ `FakePower`, `FakeThermal`, `FakeLidMonitor`)

**Interfaces — Produces:**
```swift
public struct PowerReading: Equatable, Sendable { public var batteryLevel: Int?; public var onBattery: Bool }
@MainActor public protocol PowerMonitoring: AnyObject { func current() -> PowerReading; var onChange: (() -> Void)? { get set } }
@MainActor public protocol ThermalMonitoring: AnyObject { func current() -> ThermalLevel; var onChange: (() -> Void)? { get set } }
@MainActor public protocol LidMonitoring: AnyObject { func isLidClosed() -> Bool }
@MainActor public final class SafetyEngine {
    public static let pollInterval: TimeInterval = 15
    public init(power: PowerMonitoring, thermal: ThermalMonitoring, lid: LidMonitoring, clock: WakeClock,
                onReadings: @escaping @MainActor (SafetyReadings) -> Void)
    public private(set) var lidClosedOnBatterySince: Date?
    public func start()     // onChange-подписки + Timer каждые pollInterval + немедленный refresh()
    public func stop()
    public func refresh()   // собрать SafetyReadings, обновить since, вызвать onReadings
}
```
`since`: если `lidClosed && onBattery` — сохранить существующее или выставить `now`; иначе `nil`.

> Отклонение от спецификации: один таймер 15 с вместо «крышка 15 с + политика 30 с» — политика оценивается не реже, чем требовалось.

- [ ] **Step 1: Write failing tests:**
  - `sinceStartsAndPersists`: closed+battery на t0 → refresh → since t0; advance 100 → refresh → since всё ещё t0.
  - `sinceResetsOnOpenOrPower`: открыть крышку → nil; снова закрыть на t0+200 → since t0+200; подключить сеть → nil.
  - `refreshEmitsReadings`: `onReadings` получает `SafetyReadings(batteryLevel: 55, onBattery: true, thermal: .fair, lidClosed: false, lidClosedOnBatterySince: nil, now: t0)`.
  - `monitorChangeTriggersRefresh`: после `start()` вызов `FakePower.onChange?()` → `onReadings` вызван ещё раз.
- [ ] **Step 2–4:** FAIL → реализовать → `make test` PASS.
- [ ] **Step 5:** Commit `feat(core): safety engine`.

---

### Task 8: StatusPresentation

**Files:** Create `Sources/WakeUpCore/Presentation/StatusPresentation.swift`, `Tests/WakeUpCoreTests/StatusPresentationTests.swift`

**Interfaces — Produces:**
```swift
public enum IconGlyph: String, Sendable { case off, active, timer, lid, attention }
public struct StatusPresentation: Equatable, Sendable {
    public let glyph: IconGlyph
    public let progress: Double?     // доля ОСТАВШЕГОСЯ времени 0...1, только для сессии с endsAt
    public let timerText: String?    // только showTimerText && active && endsAt != nil
    public static func make(state: SessionState, attention: SafetyReason?, showTimerText: Bool, now: Date) -> StatusPresentation
    public static func formatRemaining(_ seconds: TimeInterval) -> String   // ceil до минут, "H:MM"
}
```
Приоритет глифа: `attention != nil` → `.attention`; active && `lidModeActive` → `.lid`; active && `endsAt != nil` → `.timer`; active → `.active`; иначе `.off`.

- [ ] **Step 1: Write failing tests:**
  - `formatRemaining`: 3480 → "0:58"; 3599 → "1:00"; 59 → "0:01"; 0 → "0:00"; 90000 → "25:00"; −5 → "0:00".
  - `glyphPriority`: attention + lid → `.attention`; lid + timer → `.lid`; timer → `.timer`; бессрочная → `.active`; off → `.off`; off + attention → `.attention`.
  - `progressAndText`: старт t0, endsAt t0+3600, now t0+900 → `progress == 0.75`; `showTimerText: true` → `"0:45"`; `false` → nil; бессрочная → progress nil, text nil.
- [ ] **Step 2–4:** FAIL → реализовать → PASS.
- [ ] **Step 5:** Commit `feat(core): status presentation`.

---

### Task 9: Системные адаптеры

**Files:** Create `Sources/WakeUpCore/System/{IOPMSleepAssertionService,IOPowerMonitor,SystemThermalMonitor,IORegistryLidMonitor,UserDefaultsSettingsStore}.swift`, `Tests/WakeUpCoreTests/SystemAdapterTests.swift`

**Interfaces — Produces** (реализуют протоколы Tasks 5, 7):
- `IOPMSleepAssertionService: SleepAssertionService` — `IOPMAssertionCreateWithName` с `kIOPMAssertionTypePreventUserIdleSystemSleep` (всегда) и дополнительно `kIOPMAssertionTypePreventUserIdleDisplaySleep` при `keepDisplayOn`; имя `"WakeUp session"`; `acquire` сначала создаёт новые, затем освобождает старые (без окна, когда Mac может уснуть); ошибка → `throw AssertionError.createFailed(IOReturn)`.
- `IOPowerMonitor: PowerMonitoring` — `IOPSCopyPowerSourcesInfo`/`IOPSCopyPowerSourcesList`, процент = `CurrentCapacity*100/MaxCapacity` для `kIOPSInternalBatteryType`, нет батареи → `batteryLevel = nil`; `onBattery` = `IOPSGetProvidingPowerSourceType == kIOPSBatteryPowerValue`; `onChange` через `IOPSNotificationCreateRunLoopSource` на main run loop.
- `SystemThermalMonitor: ThermalMonitoring` — `ProcessInfo.thermalState` → `ThermalLevel` 1:1; `onChange` через `ProcessInfo.thermalStateDidChangeNotification` (доставлять на main).
- `IORegistryLidMonitor: LidMonitoring` — `IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))`, свойство `AppleClamshellState` как `Bool`; отсутствует → `false`.
- `UserDefaultsSettingsStore: SettingsStore` — `init(defaults: UserDefaults = .standard)`, ключ `"settings.v1"`, JSON; битые/отсутствующие данные → `WakeUpSettings()`.

- [ ] **Step 1: Write failing tests** (смоук на реальном железе, без root):
  - `settingsStoreRoundTripAndCorruption`: `UserDefaults(suiteName: "wakeup.tests.<UUID>")`; save/load равны; записать `Data("x".utf8)` в ключ → `load() == WakeUpSettings()`.
  - `assertionAppearsInPmset`: `acquire(keepDisplayOn: true)` → `pmset -g assertions` (через `ProcessCommandRunner`) содержит `"WakeUp session"`; `release()` → не содержит.
  - `powerReadingIsSane`: `batteryLevel` nil или в 0...100.
  - `lidMonitorDoesNotCrash`: `isLidClosed()` возвращает Bool (при запуске тестов крышка открыта → `false`).
- [ ] **Step 2–4:** FAIL → реализовать → `make test` PASS.
- [ ] **Step 5:** Commit `feat(core): system adapters`.

---

### Task 10: Скрипты помощника и сторож

**Files:** Create `Helper/{install.sh,uninstall.sh,watchdog.sh,app.wakeup.watchdog.plist}`, `Helper/tests/watchdog_test.sh`; Modify `Makefile` (`test` += `shellcheck Helper/*.sh Helper/tests/*.sh`, `bash Helper/tests/watchdog_test.sh`, `plutil -lint Helper/app.wakeup.watchdog.plist`)

**Interfaces:**
- Consumes: аргументы, которые передаёт `SudoersBackend` (Task 3): `install.sh <sudoers_tmp_file> <user> <helper_dir>`, `uninstall.sh <marker_path>`.
- Produces: установленные пути из Global Constraints.

Содержимое (все скрипты `#!/bin/bash`, `set -euo pipefail`):
- `install.sh`: (1) `grep -Eq '^[#@]includedir /private/etc/sudoers.d' /etc/sudoers` иначе `exit 3` с сообщением; (2) `visudo -cf "$1"` иначе `exit 2`; (3) `install -m 0440 -o root -g wheel "$1" /etc/sudoers.d/wakeup`; (4) `install -m 0755 -o root -g wheel "$3/watchdog.sh" /Library/PrivilegedHelperTools/app.wakeup.watchdog.sh`; (5) `install -m 0644 -o root -g wheel "$3/app.wakeup.watchdog.plist" /Library/LaunchDaemons/`; (6) `launchctl bootout system/app.wakeup.watchdog 2>/dev/null || true; launchctl bootstrap system /Library/LaunchDaemons/app.wakeup.watchdog.plist`; (7) `mkdir -p /Users/Shared/WakeUp && chown "$2" /Users/Shared/WakeUp`.
- `uninstall.sh`: если `-e "$1"` → `pmset -a disablesleep 0; rm -f "$1"`; `launchctl bootout system/app.wakeup.watchdog || true`; `rm -f` plist, скрипт сторожа, `/etc/sudoers.d/wakeup`.
- `watchdog.sh`: переменные с переопределением для тестов — `MARKER=${WAKEUP_MARKER:-/Users/Shared/WakeUp/lid-mode.marker}`, `PROC=${WAKEUP_PROCESS_NAME:-WakeUp}`; флаг `--dry-run`. Если маркер есть и `! pgrep -x "$PROC" >/dev/null` → (dry-run: `echo "reset"`; иначе `pmset -a disablesleep 0`) и `rm -f "$MARKER"`; иначе (dry-run) `echo "noop"`.
- `app.wakeup.watchdog.plist`: `Label` = `app.wakeup.watchdog`, `ProgramArguments` = `[/bin/bash, /Library/PrivilegedHelperTools/app.wakeup.watchdog.sh]`, `StartInterval` = 60, `RunAtLoad` = true.

- [ ] **Step 1: Write failing test** `watchdog_test.sh` (временный маркер через `mktemp`):
  - маркер есть, `WAKEUP_PROCESS_NAME=wakeup-no-such-proc-$$` → вывод `reset`, маркер удалён;
  - маркер есть, `WAKEUP_PROCESS_NAME=launchd` → вывод `noop`, маркер на месте;
  - маркера нет → `noop`.
  Скрипт завершается `exit 1` при первом несовпадении и печатает `PASS` в конце.
- [ ] **Step 2:** `make test` → FAIL (скриптов нет).
- [ ] **Step 3:** Написать скрипты и plist.
- [ ] **Step 4:** `make test` → swift-тесты PASS, shellcheck без замечаний, `watchdog_test.sh` → `PASS`, `plutil` → `OK`.
- [ ] **Step 5:** Commit `feat(helper): install/uninstall scripts and watchdog daemon`.

---

### Task 11: Каркас приложения и значок в строке меню

**Files:** Create `project.yml`, `App/WakeUpApp.swift`, `App/AppDelegate.swift`, `App/StatusItem/{StatusItemController,IconRenderer,QuickMenu}.swift`, `App/Services/UserNotifier.swift`, `App/Resources/Info.plist`; Modify `Makefile` (+ `generate`, `build`, `run`)

**Interfaces:**
- Consumes: всё ядро (Tasks 1–10).
- Produces: `AppDelegate` с собранными `controller: SessionController`, `engine: SafetyEngine`, `backend: SudoersBackend`, `lid: LidSleepService`; `StatusItemController.init(controller:, onOpenPopover:)` и `refresh()`; `SettingsWindowController.show(tab:)` будет добавлен в Task 13 (здесь пункт «Settings…» вызывает заглушку).

Решения:
- `project.yml`: таргет `WakeUp` (application, macOS 14.0), sources `App`, ресурс — папка `Helper` (folder reference, копируется как `Contents/Resources/Helper`, без `tests/`), local package `Packages/WakeUpCore`; settings: `PRODUCT_BUNDLE_IDENTIFIER: io.github.alexsarva.WakeUp`, `PRODUCT_NAME: WakeUp`, `SWIFT_VERSION: 6.0`, `CODE_SIGN_IDENTITY: "-"`, `ENABLE_APP_SANDBOX: NO`, `INFOPLIST_FILE: App/Resources/Info.plist`; `Info.plist` содержит `LSUIElement = true`, `CFBundleDevelopmentRegion = en`, `CFBundleLocalizations = [en, ru]`.
- `Makefile`: `generate: xcodegen generate`; `build: generate` + `xcodebuild -project WakeUp.xcodeproj -scheme WakeUp -configuration Debug -derivedDataPath build build`; `run: build` + `open build/Build/Products/Debug/WakeUp.app`.
- `AppDelegate.applicationDidFinishLaunching`: собрать `SudoersBackend(runner: ProcessCommandRunner(), helperDirectory: Bundle.main.resourceURL!.appending(path: "Helper"), userName: NSUserName())`, `LidSleepService`, `IOPMSleepAssertionService`, `UserNotifier`, `UserDefaultsSettingsStore`, `SessionController`, `SafetyEngine(onReadings: controller.update)`; `controller.recoverAtLaunch()`; `engine.start()`; `Timer` 1 с → `controller.tick(); statusItem.refresh()`; `NSWorkspace.didWakeNotification` → `engine.refresh(); controller.tick()`.
- `applicationWillTerminate`: если active → `controller.stop(.appQuit)`.
- `IconRenderer.image(for: StatusPresentation) -> NSImage` — 18×18 pt, рисует пути из viewBox 24×24 через `NSBezierPath` (координаты — из макета `menubar-icon-v2.html`, символы `p0`, `p1`, `ptimer`, `plid`, `pwarn`); для `.timer` дуга кольца = `progress` по часовой от 12 часов, трек — альфа 0.28; все глифы `isTemplate = true`, кроме `.attention`: `NSImage(size:flipped:drawingHandler:)` рисует `NSColor.labelColor` + точку `#FF9F0A` (r = 3.6 в координатах 24) и `isTemplate = false`.
- `StatusItemController`: левый клик → `onOpenPopover()` (в этом таске — no-op), правый клик (`sendAction(on: [.leftMouseUp, .rightMouseUp])`, проверка `NSApp.currentEvent?.type`) → `QuickMenu`; `refresh()` ставит `button.image` и `button.title` из `StatusPresentation.make(..., showTimerText: controller.settings.showTimerInMenuBar, now:)` (моноширинные цифры: `NSFont.monospacedDigitSystemFont(ofSize: 0, weight: .regular)`).
- `QuickMenu.build(controller:) -> NSMenu`: «Turn On»/«Turn Off», пресеты из `settings.presetMinutes` + «Indefinitely», разделитель, «Keep Display On» (✓), «Closed-Lid Mode» (✓), разделитель, «Settings…», «Quit WakeUp» (`⌘Q`).
- `UserNotifier: Notifier` — `UNUserNotificationCenter`, запрос разрешения при первом `post`; категория `ENDING_SOON` с действиями `extend30` («+30 min»), `extend60` («+1 h»), обработчик вызывает `onExtend(Int)` → `controller.extend(byMinutes:)`; `cancelEndingSoon()` удаляет запрос с id `ending-soon`. Тексты уведомлений — в Task 14.

- [ ] **Step 1:** `make build` → FAIL (нет `project.yml`).
- [ ] **Step 2:** Создать файлы по решениям выше.
- [ ] **Step 3:** `make build` → `** BUILD SUCCEEDED **`; `make test` по-прежнему PASS.
- [ ] **Step 4:** `make run` → значок «ровная линия» в строке меню, нет иконки в Dock; правый клик → меню; «Turn On» → значок «кардиограмма», `pmset -g assertions | grep "WakeUp session"` находит assertion; «Turn Off» → пропадает; «Quit WakeUp» завершает приложение.
- [ ] **Step 5:** Commit `feat(app): app shell, status item, icon renderer, quick menu`.

---

### Task 12: Поповер с плитками

**Files:** Create `App/Popover/{PopoverView,Tiles,DurationPills}.swift`, `App/Services/HelperModel.swift`; Modify `App/StatusItem/StatusItemController.swift` (левый клик → `NSPopover`, `behavior = .transient`, при показе `controller.clearAttention()`)

**Interfaces:**
- Consumes: `SessionController` (Tasks 5–6), `SudoersBackend`/`LidSleepControlling.helperStatus()` (Tasks 3–4).
- Produces:
```swift
@MainActor @Observable final class HelperModel {
    init(backend: PrivilegedBackend)
    private(set) var status: HelperStatus
    private(set) var isWorking: Bool
    func refresh()
    func install() async -> HelperError?     // backend.install() в Task.detached, затем refresh()
    func uninstall() async -> HelperError?
}
```
`PopoverView(controller:, helper:, openSettings: (SettingsTab) -> Void)` — `SettingsTab` объявить здесь: `enum SettingsTab { case general, safety, helper, about }`.

Макет (вариант B, ширина 300 pt, отступ 14, сетка 2×2 с зазором 8, радиус плиток 12, акцент `#FFB340`, активная иконка плитки — на акцентном круге):
- **MainTile** (на всю ширину): иконка-пульс, заголовок «Awake»/«Off», подзаголовок — «%@ left · until %@» / «Indefinitely» / «Off»; при `startBlock == .lowBattery(t)` — «Battery below %d% — connect power or change the limit»; переключатель → `controller.toggle()`.
- **Display**: «Display» / «stays on» | «may sleep»; клик → `setKeepDisplayOn(!…)`.
- **Lid**: «Lid» / «keeps awake» (активен) | «off» | «needs helper» (`helper.status != .installed`) | «paused: overheating» / «paused: battery time limit» / «paused: helper error» (по `lidModeSuspendedReason`); клик: если помощник не установлен → `await helper.install()` и при успехе `controller.setLidMode(true)`; иначе `setLidMode(!settings.lidModeEnabled)` (если приостановлен — `setLidMode(true)`).
- **Battery**: «%d%» или «—» (нет батареи) / «stop at %d%» | «rule off»; клик → `openSettings(.safety)`.
- **Thermal**: «Thermal» / «normal» (nominal, fair) | «elevated» (serious) | «high» (critical); клик → `openSettings(.safety)`.
- **DurationPills**: пресеты (`"15 min"`, `"1 h"`, `"3 h"` — минуты < 60 → «%d min», кратные 60 → «%d h», иначе «%d h %d min»), «Until…» (popover с `DatePicker(.hourAndMinute)` и кнопкой «Start»; время раньше текущего → следующий день), «∞». Подсветка выбранной: совпадение `endsAt − startedAt` с пресетом / `.indefinite`. Клик: off → `start`, active → `restart`.
- Нижняя строка: иконки «Settings» (gear) → `openSettings(.general)`, «Quit» (power) → `NSApp.terminate(nil)`.
- SwiftUI `#Preview` для: off, active ∞, active с таймером + крышка, startBlock, lid paused (thermal), needs helper.

- [ ] **Step 1:** Реализовать файлы.
- [ ] **Step 2:** `make build` → `** BUILD SUCCEEDED **`; Previews компилируются.
- [ ] **Step 3:** `make run`, ручная проверка: левый клик открывает поповер, клик вне — закрывает; главный переключатель включает/выключает; пилюля «15 min» → подзаголовок «15 min left · until HH:MM», значок с кольцом; «∞» → «Indefinitely»; плитка Display переключается и `pmset -g assertions` показывает `PreventUserIdleDisplaySleep`; Lid без помощника показывает «needs helper».
- [ ] **Step 4:** Commit `feat(app): tile popover`.

---

### Task 13: Окно настроек и автозапуск

**Files:** Create `App/Settings/{SettingsWindowController,SettingsView,GeneralTab,SafetyTab,HelperTab,AboutTab}.swift`, `App/Services/LoginItem.swift`; Modify `AppDelegate.swift`, `QuickMenu.swift`, `PopoverView` callers (подключить `SettingsWindowController.show(tab:)`)

**Interfaces:**
- Consumes: `SessionController.settings`, `HelperModel` (Task 12), `SettingsTab` (Task 12).
- Produces: `@MainActor final class SettingsWindowController { func show(tab: SettingsTab) }` — одно переиспользуемое `NSWindow` с `NSHostingView(SettingsView)`, `NSApp.activate()` перед показом; `@MainActor @Observable final class LoginItem { var isEnabled: Bool { get set } }` поверх `SMAppService.mainApp` (`register`/`unregister`; ошибка → алерт с текстом; источник истины — `SMAppService.mainApp.status == .enabled`).

Вкладки (`TabView` с выбором из `SettingsTab`):
- **General:** «Launch at login» (LoginItem); «Default duration» (Picker: пресеты + «Indefinitely»); редактор пресетов (список минут, добавление `Stepper` 5–720 с шагом 5, удаление; минимум один пресет); «Show remaining time in menu bar»; «Start a session when WakeUp launches».
- **Safety:** для каждого правила `Toggle` + порог: батарея — `Slider` 5…50 шаг 5 с подписью «%d%»; нагрев — без порога, текст-пояснение; лимит крышки — `Stepper` 30…720 мин шаг 30 с форматом из DurationPills.
- **Helper:** статус («Not installed» / «Installed» / «Error: %@»); кнопки «Install…» / «Uninstall…» (`isWorking` → `ProgressView`); пояснение: «Closed-lid mode needs a one-time administrator password to allow WakeUp to run exactly one command: pmset disablesleep. A background watchdog restores normal sleep if WakeUp quits unexpectedly.»; ошибки install/uninstall (кроме `.cancelled`) — красным под кнопками.
- **About:** иконка, «WakeUp», версия из `CFBundleShortVersionString`, ссылка `https://github.com/alexsarva/wakeup`.

- [ ] **Step 1:** Реализовать.
- [ ] **Step 2:** `make build` → `** BUILD SUCCEEDED **`.
- [ ] **Step 3:** `make run`, ручная проверка: «Settings…» из меню и из поповера открывает окно; клик по плитке Battery открывает вкладку Safety; изменение порога сохраняется после перезапуска приложения; «Launch at login» отражается в System Settings → General → Login Items; «Install…» запрашивает пароль, после — статус «Installed», `ls /etc/sudoers.d/wakeup /Library/LaunchDaemons/app.wakeup.watchdog.plist` существуют, `sudo -n /usr/bin/pmset -a disablesleep 0` проходит без пароля; «Uninstall…» всё удаляет.
- [ ] **Step 4:** Commit `feat(app): settings window, helper management, launch at login`.

---

### Task 14: Локализация, релизная сборка, README, ручной чек-лист

**Files:** Create `App/Resources/Localizable.xcstrings`, `README.md`; Modify `App/Services/UserNotifier.swift` (тексты), `Makefile` (+ `release`)

**Interfaces:** Consumes все строки UI из Tasks 11–13 (исходный язык — английский).

Обязательные русские переводы (остальные строки UI переводятся по смыслу в том же стиле):

| en | ru |
|---|---|
| Awake | Не сплю |
| Off | Выключено |
| %@ left · until %@ | ещё %@ · до %@ |
| Indefinitely | Бессрочно |
| Display / stays on / may sleep | Экран / не гаснет / может гаснуть |
| Lid / keeps awake / needs helper | Крышка / не усыпляет / нужен помощник |
| paused: overheating / paused: battery time limit / paused: helper error | пауза: перегрев / пауза: лимит на батарее / пауза: ошибка помощника |
| Battery below %d% — connect power or change the limit | Заряд ниже %d% — подключите питание или измените порог |
| stop at %d% | стоп при %d% |
| Thermal / normal / elevated / high | Нагрев / норма / повышен / высокий |
| Until… | До… |
| Closed-Lid Mode | Закрытая крышка |
| Keep Display On | Экран не гаснет |
| Turn On / Turn Off | Включить / Выключить |
| Quit WakeUp | Выйти из WakeUp |

Уведомления (`UserNotifier`):
- `endingSoon` — «WakeUp ends in 5 minutes» / «WakeUp выключится через 5 минут»; тело — «Mac can sleep after %@.» / «После %@ Mac сможет уснуть.»
- `sessionEnded(.timerExpired)` — «WakeUp session ended» / «Сессия WakeUp завершена».
- `sessionEnded(.safety(.lowBattery))` — «Stopped: battery below %d%» / «Остановлено: заряд ниже %d%».
- `sessionEnded(.safety(.thermal))` — «Stopped: Mac is overheating with the lid closed» / «Остановлено: Mac перегревается с закрытой крышкой».
- `lidModeSuspended(.thermal)` — «Closed-lid mode paused: Mac is getting hot» / «Режим крышки на паузе: Mac нагревается».
- `lidModeSuspended(.lidOnBatteryLimit)` — «Closed-lid mode paused after %@ on battery» / «Режим крышки на паузе: %@ на батарее».
- `lidModeSuspended(.helperUnavailable)` — «Closed-lid mode unavailable — reinstall the helper in Settings» / «Режим крышки недоступен — переустановите помощника в настройках».
- `assertionFailed(msg)` — «Couldn't keep Mac awake: %@» / «Не удалось запретить сон: %@».

`make release`: `xcodebuild … -configuration Release -derivedDataPath build build`, `codesign --force --deep -s - build/Build/Products/Release/WakeUp.app`, `ditto -c -k --keepParent build/Build/Products/Release/WakeUp.app build/WakeUp.zip`.

README (en, с кратким ru-разделом): что делает, установка из zip (правый клик → Open / `xattr -dr com.apple.quarantine WakeUp.app`), зачем нужен помощник и что именно он ставит (три пути + маркер), как удалить (Settings → Helper → Uninstall, затем удалить приложение), сборка (`make build`, `make test`, требования: Xcode 16+, `brew install xcodegen shellcheck`).

- [ ] **Step 1:** Создать String Catalog и тексты; переключить систему на русский (или `-AppleLanguages "(ru)"` в схеме) → `make run` → все строки поповера, меню, настроек и уведомлений по-русски, без английских остатков.
- [ ] **Step 2:** `make release` → `build/WakeUp.zip` существует; `codesign -dv build/Build/Products/Release/WakeUp.app` показывает `Signature=adhoc`.
- [ ] **Step 3:** Пройти ручной чек-лист из спецификации §8 (6 пунктов) на MacBook; результаты записать в описание коммита.
- [ ] **Step 4:** `make test` → всё PASS.
- [ ] **Step 5:** Commit `feat: localization, release build, README`.
