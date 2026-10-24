# Lidless 0.4.0 — автообновления и доработки помощника. Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lidless сам находит и ставит новые версии (Sparkle 2 со своим интерфейсом, эфир переживает перезапуск), а все вызовы помощника становятся асинхронными, упорядоченными и подтверждаемыми демоном.

**Architecture:** сначала помощник (Tasks 1–5): протокол `info` расширяется сборкой и владением, клиент различает тайм-аут, перерегистрация ждёт ухода старого демона, `LidSleepService` переходит на последовательную очередь с завершениями на главном акторе, `SessionController` — на эти завершения с номером операции. Затем обновления (Tasks 6–10): чистые модели в LidlessCore, Sparkle и драйвер в App, интерфейс, продолжение эфира, релиз. Логика — в LidlessCore на подделках; App — тонкая обвязка.

**Tech Stack:** Swift 6, Sparkle 2.10.0 (SPM через XcodeGen), ServiceManagement, NSXPCConnection, Swift Testing, XcodeGen, bash.

**Spec:** `docs/superpowers/specs/2026-10-24-auto-updates-design.md`

## Global Constraints

- macOS 14+, Swift 6 language mode, без App Sandbox. Hardened runtime — только при подписи Developer ID (spec §6); ad-hoc и Debug — без него.
- Sparkle ровно `2.10.0`, `https://github.com/sparkle-project/Sparkle`.
- `SUFeedURL` = `https://github.com/aesarva/lidless/releases/latest/download/appcast.xml`; `SUEnableAutomaticChecks` = `YES`; `SUScheduledCheckInterval` = `86400`; `minimumSystemVersion` в ленте = `14.0`.
- Team ID релизов: `6H45P75YYV`. Идентификаторы и пути помощника — как в 0.3.0 (`HelperIDs`).
- Снимок эфира: ключ `UserDefaults` `resumeAfterUpdate`, срок годности 120 с.
- Перерегистрация: ожидание обработчика `unregister` ≤ 10 с; повтор `info` после тайм-аута — через 1 с.
- Логи приложения: `Logger(subsystem: "io.github.aesarva.Lidless", category: …)`, категория обновлений `updates`.
- Каждая новая строка интерфейса — английский исходник + русский в `App/Resources/Localizable.xcstrings`; вид — DESIGN.md (красный только эфир, оранжевая точка — внимание, синяя — `NSColor.controlAccentColor` — обновление).
- `make test` зелёный после каждой задачи. Одна ветка `feature/auto-updates`, коммит(ы) на задачу, трейлеры:
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` и `Claude-Session: https://claude.ai/code/session_01USv9twnwN9ZMVV3p7yfm2h`.
- Исполнители не запускают `sudo`, не подписывают, не запускают и не закрывают приложения, не трогают `main`/`develop`; живые проверки делает контроллер (Task 11).
- Образец кода обновлений: `/Users/alexsarva/projects/ochre` — `Sources/MetricsCore/Updates/UpdateState.swift`, `Sources/Ochre/Updates/{PanelUserDriver,UpdateController}.swift`, `Sources/Ochre/Popover/Components/UpdateRow.swift`, `scripts/make-appcast.sh`, `scripts/build-app.sh`. Переносить с заменой идентификаторов и стиля Lidless.

## Review Focus

1. **Остановка сессии, пока включение режима крышки в пути** — после ответа демона удержание снято, `disablesleep` не остаётся 1. → `stopDuringPendingEnableReleases` (Task 4).
2. **Нагрев или лимит на батарее, пока включение в пути** — режим крышки не становится активным. → `safetyBlockDuringPendingEnable` (Task 4).
3. **Обновление при паузе по нагреву** — после перезапуска режим крышки не включается сам. → `resumeKeepsSafetySuspension` (Task 9).
4. **Крышку закрыли во время скачивания** — установка ждёт открытия. → `installWaitsForOpenLid` (Task 6).
5. **Демон отвечает ошибкой `pmset -g`, но жив** — нет перерегистрации, статус «ошибка». → `errorReplyDoesNotReregister` (Task 3).

---

## File Structure

```
Packages/LidlessCore/Sources/LidlessCore/
  Helper/HelperProtocol.swift      info: + build, owned
  Helper/HelperClient.swift        HelperInfo + build, owned; HelperError.timedOut
  Helper/HelperConnection.swift    отвечает build и owned
  Helper/SleepGuard.swift          ownsSetting; .stale после подтверждённого 0; recoverAtStart по текущему значению
  Helper/PrivilegedBackend.swift   HelperError.timedOut; lastInfo()
  Helper/HelperRegistration.swift  unregisterAndWait(timeout:)
  Helper/DaemonBackend.swift       классификация сбоев, сборка, повтор перерегистрации
  Helper/LidSleepService.swift     асинхронный, последовательная очередь, confirmReleased
  Session/SessionController.swift  завершения с номером операции; resume(from:); unsigned тихо
  Updates/UpdateState.swift        (новый) модель обновления, перенос из ochre
  Updates/ResumeSnapshot.swift     (новый) снимок эфира
LidlessHelper/main.swift           build в Daemon
LidlessHelper/Daemon.swift         build в HelperConnection
App/Updates/PanelUserDriver.swift  (новый)
App/Updates/UpdateController.swift (новый)
App/Popover/UpdateRow.swift        (новый)
App/StatusItem/{IconRenderer,StatusItemController,QuickMenu}.swift
App/Settings/{GeneralTab,AboutTab,HelperTab}.swift
App/Services/HelperModel.swift
App/AppDelegate.swift
App/Resources/{Info.plist,Localizable.xcstrings}
project.yml, scripts/build-app.sh, scripts/release.sh, scripts/make-appcast.sh (новый)
README.md, README.ru.md, CONTRIBUTING.md, CHANGELOG.md, PRODUCT.md, SECURITY.md, Makefile
```

---

### Task 1: `info` со сборкой и владением; маркер `.stale` после подтверждённого 0

Spec §8.4, §8.8 (часть демона).

**Files:**
- Modify: `Packages/LidlessCore/Sources/LidlessCore/Helper/{HelperProtocol,HelperClient,HelperConnection,SleepGuard}.swift`, `LidlessHelper/{main,Daemon}.swift`
- Test: `Packages/LidlessCore/Tests/LidlessCoreTests/{SleepGuardTests,HelperConnectionTests,XPCHelperClientTests}.swift`, `Fakes.swift`

**Interfaces:**
- Produces:
  - `HelperProtocol.info(reply: @escaping @Sendable (String, String, Bool, Bool, String?) -> Void)` — версия, сборка, `disablesleep`, владеет ли демон, ошибка.
  - `HelperInfo(version: String, build: String, sleepDisabled: Bool, owned: Bool)`.
  - `SleepGuard.ownsSetting: Bool` — маркер `.owned`.
  - `HelperConnection.init(holder:guard:cleaner:version:build:setting: SleepSetting = PmsetSleepSetting(), onGuardChange:)` (существующий параметр `setting` сохраняется — на нём держится `infoReadErrorIsReported`); `Daemon.init(guard:cleaner:version:build:lifecycle:)`; `main.swift` берёт `CFBundleVersion` демона (`"unknown"`, если нет).

- [ ] **Step 1: Failing tests** — в `SleepGuardTests`:
  - `confirmedResetThenMarkerRemoveFailureDoesNotWriteAgain`: держатель, `release` при `store.remove` падающем один раз → `setting` записал `false` один раз; затем `retryPendingReset()` → `setting` новых записей нет, файл удалён.
  - `recoverAtStartWithZeroOnlyRemovesMarker`: файл есть, `setting` = 0 → `recoverAtStart()` не пишет, файл удалён.
  - `recoverAtStartWithOneResets`: файл есть, `setting` = 1 → пишет 0, файл удалён (как сейчас).
  - `ownsSettingFollowsMarker`: `false` → после `acquire` `true` → после `release` `false`.
  - В `HelperConnectionTests`: `infoRepliesBuildAndOwned` — ответ содержит переданную сборку и `owned == guard.ownsSetting`.
  - В `XPCHelperClientTests`: `infoDecodesBuildAndOwned` через существующий `Harness(serving: .current)`.
- [ ] **Step 2:** `swift test --package-path Packages/LidlessCore` → новые тесты FAIL (не компилируются).
- [ ] **Step 3: Implement.** `cleanUpIfUnheld` при `.owned`: `try setting.setDisabled(false)`, затем `marker = .stale`, затем `try store.remove()`, затем `.none`. `recoverAtStart`: файл есть → `marker = try setting.isDisabled() ? .owned : .stale` (ошибка чтения → `.owned`, как сейчас), затем `cleanUpIfUnheld()`. Используй существующий метод чтения `SleepSetting`; если его нет — добавь `func isDisabled() throws -> Bool` (в `PmsetSleepSetting` уже читается `pmset -g`). `OldHelperProtocol` в тестах `XPCHelperClientTests` остаётся старой сигнатурой — тест `olderDaemonInterfaceIsRejected` должен продолжать проходить.
- [ ] **Step 4:** `make test` → PASS.
- [ ] **Step 5: Commit** `fix(helper): info reports build and ownership; no second reset after a confirmed 0`.

### Task 2: перерегистрация ждёт ухода старого демона и повторяется

Spec §8.9.

**Files:**
- Modify: `Packages/LidlessCore/Sources/LidlessCore/Helper/{HelperRegistration,DaemonBackend}.swift`
- Test: `DaemonBackendTests.swift`, `Fakes.swift` (`FakeRegistration`)

**Interfaces:**
- Produces: `HelperRegistration.unregisterAndWait(timeout: TimeInterval) throws` — в `SMAppServiceRegistration` через `SMAppService.unregister(completionHandler:)` и семафор; тайм-аут → ошибка `HelperError.installFailed("unregister timed out")`. Синхронный `unregister()` остаётся для `uninstall()`.
- `DaemonBackend.unregisterWait: TimeInterval = 10` (инициализатор принимает, тесты дают 0).

- [ ] **Step 1: Failing tests** в `DaemonBackendTests`:
  - `reregisterWaitsForUnregisterCompletion`: `FakeRegistration` записывает порядок вызовов → `["unregisterAndWait", "register"]`, синхронный `unregister` не вызван.
  - `failedReregistrationIsRetriedOnNextRefresh`: все 3 `register` падают → статус `.error`; затем `register` проходит → следующий `refreshInfo()` регистрирует снова и при ответе `info` с совпадающими версией и сборкой статус `.installed`.
  - Существующий `reregistrationGivesUpAfterThreeRegisterFailures` переписать под новое поведение (ожидание — `.error` с текстом причины и повтор на следующем `refreshInfo`, а не `.notInstalled` навсегда).
- [ ] **Step 2:** FAIL.
- [ ] **Step 3: Implement.** В `reregister`: `unregisterAndWait(timeout: unregisterWait)` вместо `unregister()`. Состояние повтора — `enum Reregistration { case none, unregisterPending, registerPending, done }`: тайм-аут или ошибка `unregisterAndWait` → `.unregisterPending` (следующий `refreshInfo` начинает снова с `unregisterAndWait`, `register()` не вызывается); `unregister` подтверждён, но `register()` не прошёл → `.registerPending` (следующий `refreshInfo` повторяет только `registerAfterUnregister()`); успех → `.done` (больше не перерегистрирует в этом запуске). Всё под `mutationLock`, с проверкой `userRemoved`; `uninstall()` сбрасывает в `.none`.
  Дополнительный тест: `unregisterTimeoutNeverRegisters` — `FakeRegistration` не вызывает обработчик `unregister` → `register` не вызван ни в этом, ни в следующем `refreshInfo`, пока обработчик не пришёл.
- [ ] **Step 4:** `make test` → PASS.
- [ ] **Step 5: Commit** `fix(helper): re-register after launchd confirms the old daemon is gone, retry a failed one`.

### Task 3: перерегистрация только при сбое связи или другой сборке; версия на вкладке

Spec §8.6, §8.7, §8.8 (сторона приложения).

**Files:**
- Modify: `Packages/LidlessCore/Sources/LidlessCore/Helper/{PrivilegedBackend,HelperClient,DaemonBackend}.swift`, `App/Services/HelperModel.swift`, `App/Settings/HelperTab.swift`, `App/Debug/PreviewSupport.swift`, `App/AppDelegate.swift`, `App/Resources/Localizable.xcstrings`
- Test: `DaemonBackendTests.swift`, `XPCHelperClientTests.swift`, `Fakes.swift`

**Interfaces:**
- Consumes: `HelperInfo.build` (Task 1).
- Produces:
  - `HelperError.timedOut` — клиент бросает его вместо `.commandFailed("timed out")`; `message` = `"timed out"`.
  - `DaemonBackend.init(registration:client:appVersion:appBuild:…)` — `AppDelegate` передаёт `Bundle.main` `CFBundleVersion`.
  - `PrivilegedBackend.lastInfo() -> HelperInfo?` — последний успешный ответ демона текущей регистрации (сбрасывается при install/uninstall); только для показа.
  - `PrivilegedBackend.freshInfo() throws -> HelperInfo` — синхронный вызов `info` сейчас, без кеша (для `confirmReleased`, Task 4); ошибки — как у `info`.
  - `HelperStatus.checking` — регистрация `.enabled`, но совпадающий `info` для текущей регистрации ещё не получен (после запуска, `install`, перерегистрации). `status()` даёт `.installed` только после такой проверки. Все `switch` по `HelperStatus` в App и LidlessCore получают ветку: для режима крышки — как `.needsApproval` (ждёт молча), подпись на вкладке и в строке — «Checking…» / «Проверка…».
  - `HelperCoordinator` вызывает `onChange` после каждого завершённого `refresh` (не только при смене статуса), `HelperModel.sync()` копирует `daemonInfo = backend.lastInfo()`; `onBecameInstalled` — при переходе в `.installed` из любого другого статуса, включая `.checking`.
  - `HelperModel.daemonInfo: HelperInfo?`.

- [ ] **Step 1: Failing tests:**
  - `errorReplyDoesNotReregister`: `info` бросает `.commandFailed("pmset failed")` → статус `.error("pmset failed")`, `unregister`/`register` не вызывались.
  - `singleTimeoutRetriesBeforeReregistering`: первый `info` — `.timedOut`, второй (через `retryDelay`) отвечает совпадающими версией и сборкой → `.installed`, перерегистрации нет.
  - `twoTimeoutsReregister`: два `.timedOut` подряд → одна перерегистрация.
  - `buildMismatchReregisters`: версия совпадает, сборка другая → перерегистрация.
  - `rejectedReregisters` (существующий `rejectedInfoReregistersOnce` остаётся зелёным).
  - `lastInfoAfterSuccessfulInfo` / `lastInfoClearedByUninstall`.
  - `statusIsCheckingUntilMatchingInfo`: регистрация `.enabled`, `info` ещё не спрашивали → `.checking`; после совпадающего `info` → `.installed`; после перерегистрации снова `.checking` до ответа.
  - В `HelperCoordinatorTests`: `onChangeAfterRefreshWithUnchangedStatus` — `.installed` → успешный `refresh` с тем же статусом → `onChange` вызван.
  - В `XPCHelperClientTests`: `timeoutThrowsTimedOut` (сервис, который не отвечает, клиент с малым тайм-аутом).
- [ ] **Step 2:** FAIL.
- [ ] **Step 3: Implement** `check(_:)` возвращает тип причины: `.mismatch` (версия или сборка), `.dropped` (`.rejected`), `.timedOut` (после одной повторной попытки через `retryDelay`, по умолчанию 1 с, тесты — 0), `.failed(String)` (ответ с ошибкой и прочее). Перерегистрация — только для первых трёх. Строка вкладки Helper для `.installed`: `"Running — version \(v) (build \(b))"` / «Работает — версия \(v) (сборка \(b))»; без `daemonInfo` — как сейчас.
- [ ] **Step 4:** `make test`, `make build` → PASS.
- [ ] **Step 5: Commit** `fix(helper): re-register only on a lost connection, a timeout twice or another build; show the daemon build`.

### Task 4: `LidSleepService` приводит демона к желаемому состоянию; `SessionController` задаёт желание

Spec §8.2, §8.3, §8.5. Самая рискованная задача: точно сохраняй существующее поведение пауз, уведомлений и `attention`; меняется только то, кто и когда зовёт демона.

**Files:**
- Modify: `Packages/LidlessCore/Sources/LidlessCore/Helper/LidSleepService.swift`, `Packages/LidlessCore/Sources/LidlessCore/Session/SessionController.swift`, `Packages/LidlessCore/Sources/LidlessCore/Model/Session.swift`, `App/AppDelegate.swift`, `App/Debug/PreviewSupport.swift`, `App/Popover/ControlRows.swift`, `App/Resources/Localizable.xcstrings`
- Test: `LidSleepServiceTests.swift`, `SessionControllerSafetyTests.swift`, новый `SessionLidHoldTests.swift`, `Fakes.swift`

**Interfaces:**
- Consumes: `PrivilegedBackend.freshInfo()`, `HelperStatus.checking` (Task 3); `HelperInfo.owned` (Task 1).
- Produces:
  ```swift
  public struct LidHold: Equatable, Sendable {
      public var held: Bool          // подтверждено демоном
      public var pending: Bool       // сервис ещё не привёл демона к желанию
      public var failure: String?    // последняя ошибка, пока желание не достигнуто
  }
  @MainActor public protocol LidSleepControlling: AnyObject {
      func helperStatus() -> HelperStatus
      /// Последнее желание побеждает; сервис приводит демона к нему по очереди, повторяет после ошибки при `retry()`.
      func setWanted(_ wanted: Bool)
      var onChange: ((LidHold) -> Void)? { get set }
      var hold: LidHold { get }
      /// Повторить недостигнутое желание (вызывается по опросу показаний).
      func retry()
      /// Свежий `info` на очереди после всех отправленных команд: true — демон ответил и не владеет.
      /// Ответ, пришедший после нового `setWanted`, отбрасывается (номер желания сверяется в сервисе).
      func confirmReleased(_ done: @escaping @MainActor (Bool) -> Void)
      func connectionLost(generation: UInt64)
  }
  ```
  `enable()`, `disable()`, `recoverIfNeeded()` удаляются.
- `LidSleepService.init(backend: PrivilegedBackend, first: (@Sendable () -> Void)? = nil)`:
  - одна последовательная `DispatchQueue`; `first` — первая работа на ней (сброс 0.2.0, §8.2);
  - `setWanted` запоминает желание и ставит на очередь шаг «привести»: шаг читает текущее желание (под замком), и если подтверждённое `held` не равно ему — `backend.setSleepDisabled(wanted)`; результат (поколение соединения или ошибка) возвращается на главный актор, `hold` обновляется, и если желание за это время изменилось — ставится ещё шаг;
  - при желании «нет» команда отправляется, даже если локально `held == false` (демон мог держать от прошлого запроса); успешный ответ на `setSleepDisabled(false)` — подтверждение снятия нашего удержания (свежий `info` нужен только для восстановления после ошибки и для Remove — иначе вторая копия Lidless, держащая режим, вечно держала бы предупреждение);
  - включение (`true`) отправляется только при статусе `.installed` (проверенный демон, Task 3); выключение — при `.installed`, `.error` и `.checking`; при `.notInstalled`/`.needsApproval`/`.unsigned` «нет» достигнуто без вызова (зарегистрированного демона нет), «да» — `failure = "helper not ready"`, `pending = false`;
  - `setWanted` сразу публикует `pending = (wanted != held)` через `onChange`, до ответа демона;
  - `connectionLost(generation:)`: поколения ≥ поколения удержания и ещё не записанные (ответ включения не дошёл) запоминаются в `lostGenerations`; удержание с таким поколением считается `held = false`; если желание «да» — ставится шаг «привести».
- `Session.lidModePending: Bool` — для строки «Turning on…» / «Включается…».
- `SessionController`:
  - `private func syncLidWanted()` — единственное место, где задаётся желание: `wanted = !helperRemovalInProgress && session != nil && settings.lidModeEnabled && session.lidModeSuspendedReason ∈ {nil, .helperUnavailable}`; вызывается после каждой смены сессии, настройки, паузы и показаний.
  - Правила защиты действуют и на желаемое, ещё не подтверждённое включение: в `update(readings:)` при `settings.lidModeEnabled`, без паузы по правилу и `safetyBlock(session) != nil` — `suspendLidMode(reason)` (пауза фиксируется, `attention` и одно уведомление, как при паузе активного режима), затем `syncLidWanted()`. Остывание после этого режим сам не включает — снять паузу может только пользователь, как сейчас.
  - `lid.onChange` → `applyLidHold(_:)`: `lidModeActive = hold.held && wanted`, `lidModePending = hold.pending && wanted`; ошибка при желании «да» → пауза `.helperUnavailable` и `raiseHelperUnavailable()` (как сейчас при неудачном включении); ошибка при желании «нет» → «сброс ожидается» (`recoveryPending = true`, `raiseHelperUnavailable()`); переход `held` в `true` при закрытой крышке (`readings?.lidClosed`) без внешнего дисплея → `display.sleepDisplayNow()` и `displayHeldForLid` как в `handleLidTransition`.
  - `update(readings:)` в обеих ветках: `lid.retry()`; если `recoveryPending` и желание «нет» — `lid.confirmReleased { ok in if ok { recoveryPending = false; снять attention .helperUnavailable } }` (ответ применяется, только если желание всё ещё «нет»).
  - `enableLidMode` при `.unsigned` и `.checking` — как `.notInstalled` (тихо).
- `FakeLid`: записывает историю `wanted`; `setWanted` сразу публикует `pending = (wanted != held)`; `autoConfirm = true` по умолчанию (сразу `onChange(held: wanted, pending: false)`), при `false` тест вызывает `deliver(held:pending:failure:)`; `confirmResult: Bool`, `confirmCalls`, `holdConfirm` + `deliverConfirm()`; подтверждение, отложенное до нового `setWanted`, при `deliverConfirm()` не вызывает `done` (как сервис).

- [ ] **Step 1: Failing tests:**
  - `LidSleepServiceTests` (с `FakeBackend`, у которого вызовы `setSleepDisabled` блокируются семафором):
    - `lastWishWins`: `setWanted(true)`, `setWanted(false)`, `setWanted(true)` пока первая команда висит → после отпускания итог `held == true`, команд не больше трёх, последняя — `true`.
    - `wantedFalseAlwaysCallsDaemon`: `held == false`, `setWanted(false)` при `.installed` → `setSleepDisabled(false)` вызван.
    - `lossBeforeEnableReplyMeansNotHeld`: команда включения висит, `connectionLost(generation:)` для её поколения, затем отпустить → `held == false` и новый шаг включения поставлен.
    - `enableWaitsBehindLegacyReset`: `first` блокирует → `setSleepDisabled(true)` не вызван до отпускания.
    - `confirmUsesFreshInfoAfterCommands`: `lastInfo` говорит «не владеет», `freshInfo` бросает → `confirmReleased` → `false`.
  - `SessionLidHoldTests` (с `FakeLid`, `autoConfirm = false`):
    - `stopDuringPendingEnableReleases`: `setLidMode(true)` → `stop(.user)` → история желаний `[true, false]`.
    - `timerAndSafetyStopDuringPendingEnableRelease`: то же для `tick()` по истечении и `stop(.safety)`.
    - `safetyBlockDuringPendingEnable`: желание `true`, затем показания с серьёзным нагревом → пауза по нагреву записана, одно уведомление, желание `false`; после `deliver(held: true)` `lidModeActive == false`.
    - `coolingAfterBlockedPendingStaysPaused`: продолжение — нормальные показания → желание остаётся `false`, пауза та же. То же для лимита времени на батарее.
    - `heldAppliedOnlyWhileWanted`: `setLidMode(true)`, `setLidMode(false)`, `deliver(held: true)` → `lidModeActive == false`.
    - `rapidOffOnKeepsHold`: `true`, `false`, `true`, `deliver(held: true)` → `lidModeActive == true`.
    - `pendingShownUntilConfirmed`: `lidModePending` до `deliver`, потом `lidModeActive`.
    - `closedLidAtConfirmationSleepsDisplay`: крышка закрыта до `deliver(held: true)` → `FakeDisplay.sleepCalls == 1`; с внешним дисплеем → 0.
    - `failedReleaseKeepsRecoveryUntilFreshConfirm`: `deliver(held: true, failure: "x")` при желании `false` → `attention == .helperUnavailable`, одно уведомление; `update(readings:)` при идущей сессии → `confirmCalls == 1`; `confirmResult = false` → остаётся; `true` → снято.
    - `staleConfirmIgnoredAfterReenable`: `holdConfirm`; запрос подтверждения; `setLidMode(true)`; `deliverConfirm()` с `false` → новое желание не изменилось на `false`.
    - `staleTrueConfirmDoesNotClearNewRecovery`: неудачное выключение → запрос подтверждения (задержан) → `setLidMode(true)` → `setLidMode(false)` снова с ошибкой → `deliverConfirm()` с `true` → `attention == .helperUnavailable` остаётся.
  - `LidSleepServiceTests` дополнительно: `enableRefusedUnlessVerified` — статус `.error` или `.checking`, `setWanted(true)` → `setSleepDisabled(true)` не вызван, `failure` задан; `releaseAllowedUnderError` — статус `.error`, `setWanted(false)` → `setSleepDisabled(false)` вызван; `lossThenFailedVerificationDoesNotReacquire` — удержание, `connectionLost`, статус `.error` → повторного включения нет.
    - `unsignedWaitsQuietly`, `checkingWaitsQuietly`: статус `.unsigned` / `.checking`, `start` при `lidModeEnabled` → ни уведомления, ни `attention`, пауза `.helperUnavailable`.
  - Существующие тесты `SessionController` переводятся с `enableCalls`/`disableCalls` на историю желаний `FakeLid`; поведение пауз, уведомлений и `attention` не меняется. Исключение — тесты, ожидающие `lidModeActive == true` после неудачного выключения: по новому контракту выключение сразу «выкл», ошибка даёт «сброс ожидается» (`attention == .helperUnavailable`, одно уведомление) — переписать их ожидания под это и назвать в отчёте каждый переписанный тест.
- [ ] **Step 2:** FAIL.
- [ ] **Step 3: Implement** по интерфейсам выше. `AppDelegate`: `LidSleepService(backend:first:)` с `LegacySleepReset().resetIfNeeded(…)` вместо отдельного `DispatchQueue.global`; `controller.helperConnectionLost` зовёт `lid.connectionLost`; при выходе `stop(.appQuit)` без ожидания (демон снимает удержание при разрыве), `recoverIfNeeded` убрать. `PreviewLid` — сразу подтверждает желание. Строка режима крышки: «Turning on…» / «Включается…» при `lidModePending`.
- [ ] **Step 4:** `make test` (все существующие и новые), `make build` → PASS.
- [ ] **Step 5: Commit** `fix(session): lid mode as a wanted state the helper service converges to, off the main thread`.

### Task 5: Remove только после подтверждённого сброса

Spec §8.1.

**Files:**
- Modify: `Packages/LidlessCore/Sources/LidlessCore/Session/SessionController.swift`, `App/Settings/HelperTab.swift`, `App/Resources/Localizable.xcstrings`
- Test: тесты `SessionController` (удаление помощника), `Fakes.swift`

**Interfaces:**
- Consumes: `LidSleepControlling.setWanted/confirmReleased` (Task 4).
- Produces: `SessionController.beginHelperRemoval(_ done: @escaping @MainActor (LidModeRestorePoint, Bool) -> Void)` — ставит `helperRemovalInProgress = true` (желание «нет» до `endHelperRemoval()`, включение невозможно), снимает настройку `lidModeEnabled = false`, затем `confirmReleased`; повторный вызов, пока удаление идёт, ничего не делает (не вызывает `done`); `SessionController.endHelperRemoval()` снимает флаг (после `uninstall` или `restoreAfterFailedRemoval`); `Bool` — можно ли удалять. Старый синхронный `beginHelperRemoval() -> LidModeRestorePoint` удаляется. `LidModeRestorePoint` получает `wasPending: Bool`; `restoreAfterFailedRemoval` при `wasActive || wasPending` возвращает настройку и паузу `.helperUnavailable` с прежним `lidModeEnabledAt` — желание восстанавливает `syncLidWanted()`.

- [ ] **Step 1: Failing tests:**
  - `removalProceedsAfterConfirmedRelease`: `confirmResult = true` → `done(_, true)`.
  - `removalStopsWhenReleaseFails`: `deliver(held: true, failure:)` при желании `false`, `confirmResult = false` → `done(_, false)`.
  - `removalStopsWhenDaemonStillOwns`: `confirmResult = false` → `done(_, false)`.
  - `removalWithoutLocalHoldStillAsksDaemon`: режим крышки не включён → `confirmReleased` всё равно вызван.
  - `secondRemovalWhileRunningIgnored`: два `beginHelperRemoval` подряд → `done` вызван один раз.
  - `noAcquireDuringRemoval`: во время удаления `setLidMode(true)` → желание остаётся `false` до `endHelperRemoval()`.
  - `failedRemovalRestoresPendingEnable`: включение в пути (`autoConfirm = false`) → удаление → `confirmResult = false` → настройка вернулась, желание снова `true`, `lidModeEnabledAt` прежний.
- [ ] **Step 2:** FAIL.
- [ ] **Step 3: Implement.** `HelperModel.isWorking` ставится до `beginHelperRemoval` и снимается после `uninstall`/восстановления (кнопки заблокированы всё удаление). `HelperTab.remove()`: `beginHelperRemoval { point, ok in … }`, в конце обоих путей `endHelperRemoval()`; при `!ok` — `errorText = String(localized: "Couldn't restore normal sleep — the helper was not removed.")` («Не удалось вернуть обычный сон — помощник не удалён.»), `restoreAfterFailedRemoval(point)`, `uninstall()` не вызывается; при `ok` — как сейчас.
- [ ] **Step 4:** `make test`, `make build` → PASS.
- [ ] **Step 5: Commit** `fix(helper): remove the helper only after it confirms normal sleep is back`.

### Task 6: модели обновления и снимка эфира

Spec §3.1, §4 (чистая часть).

**Files:**
- Create: `Packages/LidlessCore/Sources/LidlessCore/Updates/UpdateState.swift` (перенос ochre `UpdateState`, `UpdateEvent`, `UpdateModel`, `UpdateLocation`), `Packages/LidlessCore/Sources/LidlessCore/Updates/UpdateErrors.swift` (перенос ochre `Sources/MetricsCore/Updates/UpdateErrors.swift` с его тестами — его зовёт `UpdateController`), `Packages/LidlessCore/Sources/LidlessCore/Updates/ResumeSnapshot.swift`, `Packages/LidlessCore/Sources/LidlessCore/Updates/InstallGate.swift`
- Test: `Packages/LidlessCore/Tests/LidlessCoreTests/{UpdateStateTests,ResumeSnapshotTests,InstallGateTests}.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct ResumeSnapshot: Codable, Equatable, Sendable {
      public var savedAt: Date, startedAt: Date, endsAt: Date?, keepDisplayOn: Bool
      public var lidModeActive: Bool, lidModeSuspendedReason: SafetyReason?, lidModeEnabledAt: Date?
      public static let maxAge: TimeInterval = 120
      public init(session: Session, savedAt: Date)
      /// nil — не восстанавливать (старше maxAge или endsAt в прошлом).
      public func usable(now: Date) -> ResumeSnapshot?
  }
  public protocol ResumeStore: Sendable { func save(_ s: ResumeSnapshot); func take() -> ResumeSnapshot? }
  public struct UserDefaultsResumeStore: ResumeStore  // ключ "resumeAfterUpdate", take() читает и удаляет
  ```
  `SafetyReason` делается `Codable`, если ещё не.
- `UpdateModel.showsBadge`, `UpdateState`, `UpdateEvent` — как в ochre, плюс `UpdateState.waitingForLid(version: String)` и `UpdateEvent.waitingForOpenLid`: из `installing` → `waitingForLid`; `installing` снова → `installing`; `showsBadge` включает `waitingForLid`; `dismissed` из `waitingForLid` → `idle`; приватные `version` и `isInstalling` учитывают `waitingForLid` (версия сохраняется в `installing`, ошибка в ожидании → `failed`).
- ```swift
  /// Ответ Sparkle «ставить» отдаётся только при открытой крышке (spec §4).
  @MainActor public final class InstallGate {
      public init()
      /// Отдаёт reply сразу, если lidOpen; иначе хранит и возвращает false.
      @discardableResult public func ready(lidOpen: Bool, reply: @escaping () -> Void) -> Bool
      /// Крышка открыта: отдать сохранённый reply (один раз). true — отдан именно сейчас.
      @discardableResult public func lidOpened() -> Bool
      public func cancel()   // dismiss: забыть reply
  }
  ```

- [ ] **Step 1: Failing tests:** `UpdateStateTests` — перенести тесты ochre (`Tests/MetricsCoreTests/UpdateStateTests.swift`) целиком. `UpdateStateTests` дополнительно: `waitingForLidShowsBadge`, `dismissedFromWaitingIsIdle`, `waitingThenInstallingKeepsVersion`, `errorWhileWaitingFails`. `UpdateErrorsTests` — перенос из ochre. `InstallGateTests`: `installWaitsForOpenLid` (закрыта → reply не вызван; `lidOpened()` → вызван ровно раз и вернул `true`; повторный `lidOpened()` — не вызван, `false`), `repeatedOpenWithoutPendingDoesNothing`, `openLidRepliesAtOnce`, `cancelForgetsReply`. `ResumeSnapshotTests`: `freshSnapshotUsable` (59 с), `oldSnapshotUnusable` (121 с), `expiredEndUnusable`, `indefiniteUsable`, `takeReadsOnce` (второй `take()` → nil), `roundTripsSuspension` (`lidModeSuspendedReason = .thermal` переживает кодирование; подставь фактическое имя случая нагрева из `SafetyReason`).
- [ ] **Step 2:** FAIL. **Step 3:** реализовать. **Step 4:** `make test` → PASS.
- [ ] **Step 5: Commit** `feat(updates): update state and resume snapshot models`.

### Task 7: Sparkle в сборке, драйвер и контроллер

Spec §2, §3.2, §6.

**Перед задачей (контроллер, не исполнитель):** пользователь создаёт ключ EdDSA — после первого `xcodebuild -resolvePackageDependencies` бинарник лежит в `build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys`; пользователь запускает его сам и `generate_keys -x <файл>` для резервной копии; публичный ключ контроллер передаёт исполнителю как значение `SUPublicEDKey`.

**Files:**
- Create: `App/Updates/PanelUserDriver.swift`, `App/Updates/UpdateController.swift`
- Modify: `project.yml`, `App/Resources/Info.plist`, `scripts/build-app.sh`, `App/AppDelegate.swift`, `Makefile` (если `make test`/`build` нужно `-resolvePackageDependencies`)

**Interfaces:**
- Consumes: `UpdateModel`, `UpdateEvent`, `UpdateLocation` (Task 6).
- Produces: `@MainActor @Observable final class UpdateController: NSObject, SPUUpdaterDelegate` с `model: UpdateModel`, `currentVersion`, `currentBuild`, `automaticallyChecks`, `start()`, `install()`, `checkNow()`; `init(feedOverride: String?, onShowPanel: @escaping () -> Void, lidIsOpen: @escaping @MainActor () -> Bool, onWillRelaunch: @escaping @MainActor () -> Void)`. `PanelUserDriver` как в ochre, плюс: `showReady(toInstallAndRelaunch:)` отдаёт ответ через `InstallGate.ready(lidOpen: lidIsOpen(), reply: { reply(.install) })`; если гейт придержал ответ — событие `.waitingForOpenLid`; `UpdateController.lidDidOpen()` → событие `.installing` только если `gate.lidOpened()` вернул `true` (обычные показания открытой крышки ничего не меняют — тест в Task 6 `repeatedOpenWithoutPendingDoesNothing`); `dismissUpdateInstallation` → `gate.cancel()`.
- Делегат: `feedURLString(for:)` → `feedOverride`; `updater(_:shouldDownloadReleaseNotesForUpdate:)` → `false`; `updaterWillRelaunchApplication(_:)` → `onWillRelaunch()`; `didFinishUpdateCycleFor` — как в ochre.
- `AppDelegate`: `-UpdateFeedURL` из argument domain (`UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)`), `UpdateController` создаётся после `SessionController`, `start()` после первого показания безопасности; `lidIsOpen` — `!(controller.readings?.lidClosed ?? false)`; при каждом `update(readings:)` с открытой крышкой — `updates.lidDidOpen()`.

- [ ] **Step 1:** `project.yml`: пакет `Sparkle` (`url`, `exactVersion: 2.10.0`), зависимость цели `Lidless` `- package: Sparkle` (встраивание фреймворка); `ENABLE_HARDENED_RUNTIME: YES` перенести в `configs: Release` обеих целей. `Info.plist`: ключи из Global Constraints и `SUPublicEDKey`.
- [ ] **Step 2:** `build-app.sh`: `SIGN_FLAGS=(--force --sign "$SIGN_IDENTITY")`; при Developer ID добавить `--options runtime --timestamp`; подписать вложенный код Sparkle (порядок spec §6), потом демон, потом приложение; `codesign --verify --deep --strict`. Комментарий в скрипте про hardened runtime исправить.
- [ ] **Step 3:** перенести `PanelUserDriver`, `UpdateController` с изменениями выше; подключить в `AppDelegate`.
- [ ] **Step 4:** `make test`; `make build`; `scripts/build-app.sh` (ad-hoc) → `build/Lidless.app/Contents/Frameworks/Sparkle.framework` есть, `codesign --verify --deep --strict build/Lidless.app` OK. Запуск — контроллер (Task 11).
- [ ] **Step 5: Commit** `feat(updates): Sparkle with a panel driver; hardened runtime only for Developer ID builds`.

### Task 8: интерфейс обновления

Spec §3.3.

**Files:**
- Create: `App/Popover/UpdateRow.swift`
- Modify: `App/Popover/PopoverView.swift`, `App/StatusItem/{IconRenderer,StatusItemController,QuickMenu}.swift`, `App/Settings/{GeneralTab,AboutTab}.swift`, `App/Debug/{SnapshotExporter,PreviewSupport}.swift`, `App/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: `UpdateController` (Task 7).
- Produces: `IconRenderer` — новый вариант точки `updateAvailable` (акцентный цвет, нешаблонный), приоритет `attention` > `updateAvailable`; снимки отладки для каждого `UpdateState` (`-SnapshotDir`).

- [ ] **Step 1:** строки из spec §3.3 (английский исходник, русский перевод — дословно из спецификации). Кнопка установки — не красная (DESIGN.md).
- [ ] **Step 2:** `UpdateRow` между переключателями и подвалом; скрыта в `idle`/`upToDate`.
- [ ] **Step 3:** точка на значке и VoiceOver «update available» / «доступно обновление»; пункт быстрого меню «Install version %@» / «Установить версию %@» при `available`.
- [ ] **Step 4:** Настройки → Основные: `Toggle("Check for updates automatically")` («Проверять обновления автоматически»), кнопка «Check Now» («Проверить сейчас») с подписью результата; О программе: «Version %@ (build %@)» («Версия %@ (сборка %@)»).
- [ ] **Step 5:** `make build`; Debug-снимки `-SnapshotDir` для всех состояний строки в en и ru — колонка 320pt не расширяется (контроллер смотрит PNG).
- [ ] **Step 6: Commit** `feat(updates): update row, blue dot, quick menu and settings`.

### Task 8b: окно настроек — стандартное окно настроек macOS

Запрос пользователя, переданный из сессии ochre (решение проверено там): `.superpowers/sdd/2026-10-24-auto-updates/settings-window-request.md` — исполнитель получает этот файл.

**Files:**
- Modify: `App/Settings/SettingsWindowController.swift`, `App/Settings/SettingsView.swift` (обёртка `TabView` удаляется), при необходимости `App/Settings/{GeneralTab,SafetyTab,HelperTab,AboutTab}.swift`, `App/Debug/SnapshotExporter.swift`

**Interfaces:**
- Consumes: `SettingsTab` (существующий enum вкладок), `SettingsNavigation` / `show(tab:)` — выбор вкладки сохраняется через `NSTabViewController.selectedTabViewItemIndex`.
- Produces: `NSTabViewController` с `tabStyle = .toolbar`, окно `toolbarStyle = .preference`, заголовок окна = имя вкладки; высота окна следует содержимому вкладки (`sizingOptions = [.preferredContentSize]`).

- [ ] **Step 1:** у `SettingsTab` — `title` (локализованный, существующие строки) и `symbol` (gearshape, shield, wrench.and.screwdriver, info.circle).
- [ ] **Step 2:** `SettingsWindowController` строит окно по образцу из файла запроса; `show(tab:)` выбирает вкладку и в уже открытом окне.
- [ ] **Step 3:** формы — `Form { … }.formStyle(.grouped)` без собственной внешней рамки или фона; ширина 420.
- [ ] **Step 4:** снимки окна для каждой вкладки (en и ru) через `window.contentView?.superview` → `bitmapImageRepForCachingDisplay` + `cacheDisplay` в отладочном экспортере (`-SnapshotDir`), чтобы контроллер посмотрел PNG.
- [ ] **Step 5:** `make test`, `make build` → PASS.
- [ ] **Step 6: Commit** `improve(settings): native macOS preferences window with toolbar tabs`.

### Task 9: эфир переживает обновление

Spec §4.

**Files:**
- Modify: `Packages/LidlessCore/Sources/LidlessCore/Session/SessionController.swift`, `App/AppDelegate.swift`, `App/Updates/UpdateController.swift`
- Test: `SessionControllerSafetyTests.swift` (или новый `SessionResumeTests.swift`)

**Interfaces:**
- Consumes: `ResumeSnapshot`, `ResumeStore` (Task 6); асинхронный `enableLidMode` (Task 4); `onWillRelaunch`, `lidDidOpen` (Task 7).
- Produces: `SessionController.snapshot(now: Date) -> ResumeSnapshot?` (nil без сессии); `@discardableResult SessionController.resume(_ s: ResumeSnapshot) -> Bool` — старт с `startedAt`, `endsAt`, `keepDisplayOn` через общую с `start` часть (проверка низкого заряда и утверждения); режим крышки: пауза по правилу → та же пауза, без включения; `lidModeActive` или пауза `.helperUnavailable` → пауза `.helperUnavailable` с прежним `lidModeEnabledAt` (включит `retryHelperSuspendedLidMode` после `safetyBlock`); иначе выкл.

- [ ] **Step 1: Failing tests:**
  - `resumeRestoresTimedSession`: `startedAt`, `endsAt` сохранены.
  - `resumeKeepsSafetySuspension`: снимок с паузой по нагреву → после `resume` и `update(readings:)` с нормальными показаниями `enableCalls == 0`, пауза та же.
  - `resumeReenablesLidModeThroughSafetyCheck`: снимок `lidModeActive` → первый `update(readings:)` без блокировки → `enable` вызван, `lidModeEnabledAt` прежний; с блокировкой (лимит на батарее) → пауза по правилу.
  - `resumeBlockedByLowBattery` → `false`, сессии нет.
- [ ] **Step 2:** FAIL. **Step 3:** реализовать; `AppDelegate`: при запуске один раз `let snapshot = UserDefaultsResumeStore().take()?.usable(now: Date())`; после первых показаний `if let snapshot, controller.resume(snapshot) {} else { controller.startOnLaunchIfEnabled() }`; `onWillRelaunch` → `if let s = controller.snapshot(now: Date()) { store.save(s) }`. Тесты на запуск: `missingSnapshotFallsBackToStartOnLaunch`, `staleSnapshotFallsBack`, `expiredSnapshotFallsBack` — логику выбора вынести в `SessionController.launch(resuming: ResumeSnapshot?)`, чтобы она тестировалась.
- [ ] **Step 4:** `make test`, `make build` → PASS.
- [ ] **Step 5: Commit** `feat(updates): a session on air carries over an update`.

### Task 10: лента, релиз, версия и документация

Spec §6, §10.

**Files:**
- Create: `scripts/make-appcast.sh`
- Modify: `scripts/release.sh`, `project.yml` и `Makefile` (0.4.0), `README.md`, `README.ru.md`, `CONTRIBUTING.md`, `CHANGELOG.md`, `PRODUCT.md`, `SECURITY.md`

- [ ] **Step 1:** `make-appcast.sh <dmg> <версия> <сборка>` по образцу ochre: `sign_update` ищется в `build/DerivedData/SourcePackages/artifacts`; без `releaseNotesLink`; `<link>` элемента — страница релиза; `minimumSystemVersion` 14.0; `enclosure` на `${DOWNLOAD_BASE:-https://github.com/aesarva/lidless/releases/download/v<версия>}/Lidless-<версия>.dmg` (переменная `DOWNLOAD_BASE` — для локальной проверки, Task 11).
- [ ] **Step 2:** `release.sh`: перед лентой — проверка, что приложение, `Contents/MacOS/LidlessHelper` и `Sparkle.framework` подписаны Team ID `6H45P75YYV` (`codesign -dv` → `TeamIdentifier=6H45P75YYV`) и `spctl` принял приложение и DMG; иначе выход с ошибкой; затем `make-appcast.sh … > dist/appcast.xml` и `xmllint --noout`. В режиме `--unsigned` ленты нет. Номер сборки — тот же `git rev-list --count HEAD`.
- [ ] **Step 3:** версия 0.4.0 в `project.yml` и `Makefile`; CHANGELOG `## 0.4.0 — Unreleased` (обновления; продолжение эфира; пункты §8 простыми словами).
- [ ] **Step 4:** README en/ru (синхронно): «Возможности» — обновления; FAQ «Does Lidless send any data?» — одно чтение ленты на GitHub в сутки, без данных о системе, отключается; «How do I update?» — 0.3.0 один раз вручную; бейджи и раздел помощника без изменений. CONTRIBUTING: ключ EdDSA (`generate_keys`, `-x` — резервная копия), три файла в релизе (`gh release create … dist/appcast.xml`), `-UpdateFeedURL`, проверка обновления в чек-листе. PRODUCT.md: сетевой запрос и обновления. SECURITY.md: обновления подписаны EdDSA и Developer ID.
- [ ] **Step 5:** `shellcheck scripts/*.sh`, `make test` → PASS.
- [ ] **Step 6: Commit** `chore(release): appcast in release.sh, 0.4.0, docs`.

### Task 11: живая проверка (контроллер)

Spec §9. Выполняет контроллер с пользователем, не исполнитель.

- [ ] Ad-hoc `make app` запускается и грузит Sparkle (лог `updates`, нет «different Team IDs»).
- [ ] Подписанная сборка N в `/Applications`-подобном месте (`build/old/Lidless.app`), эфир с режимом крышки; новая сборка N+1 (пустой коммит в ветке или `CURRENT_PROJECT_VERSION`), её DMG и лента через `DOWNLOAD_BASE=http://127.0.0.1:<порт> make-appcast.sh` (проверить `enclosure url` в ленте), `python3 -m http.server` на `127.0.0.1`; старая запущена с `-UpdateFeedURL http://127.0.0.1:<порт>/appcast.xml`.
- [ ] Строка и синяя точка; «Установить» → N+1 запущена; эфир с тем же концом; режим крышки снова включён; вкладка Helper — сборка N+1.
- [ ] Крышку закрыть во время скачивания → «Установится, когда откроешь крышку», Mac не спит; открыть → ставится.
- [ ] DMG с испорченной подписью → «Не удалось обновить».
- [ ] §8.1: Remove при остановленном демоне (`sudo kill -STOP`, пользователь) → «помощник не удалён», регистрация на месте; `kill -CONT`.
- [ ] §8.3: выключение режима крышки при ошибке помощника — меню отзывается сразу.
- [ ] §8.8: пересборка без смены версии → демон перерегистрирован (лог `re-registering`, сборка на вкладке).
- [ ] Финальное ревью ветки: Claude (самая сильная модель) и Codex; одна волна исправлений; затем слияние в `develop`.
