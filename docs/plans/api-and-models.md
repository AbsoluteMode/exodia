# API & Models — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Заменить вкладку Models вкладкой API & Models: реестр ключей провайдеров и своя модель у каждой из восьми AI-фич, с каталогами моделей от провайдеров и автопроверкой новых моделей (вариант B).

**Architecture:** Новая папка `Sources/Sidekey/AIRouting/` хранит маршрут каждой фичи «аккаунт провайдера + модель» (JSON в UserDefaults); ключи остаются в прежних Keychain-аккаунтах. Рантайм (Drop, митинги, агент, голосовой поиск) при каждом вызове читает маршрут своей фичи вместо `SelfKeyPreferences`. Поверх маршрутов — каталоги моделей, проверка ключей, пробы и новая вкладка на MacUI.

**Tech Stack:** Swift 5 language mode (swift-tools 6.0), SwiftUI + AppKit, XCTest; заглушки `StubURLProtocol`, `StubWebSocketTransport`, `InMemoryTokenStore`.

**Spec:** `docs/specs/api-and-models.md` (утверждена Максимом 19.10.2026). Исполнитель читает спеку и план вместе.

**База:** `origin/main` a316508 (после PR #35); worktree `/Users/maxim/exodia/.claude/worktrees/keys-and-models`; ветка `claude/keys-and-models` (upstream снят). Номера строк в задачах сняты с 2a85e6d и могли сдвинуться: место в коде ищется по имени символа. Что изменил PR #35 и как план это учитывает — раздел «Сверка с main a316508».

## Global Constraints

- Swift 5 mode, macOS 14.2, без новых зависимостей и без ресурсов SwiftPM. Case (сейф ключей для агентов) не трогаем.
- TDD в каждой задаче. Фича-сессия только собирает и тестирует: `swift build`, `swift test --filter <классы>`; полный `swift test` — в конце частей A, B и C. Запрещено: `scripts/dev-run.sh`, `customize.py build/run`, `swift run`, `open`, регистрация в LaunchServices, установка поверх `/Applications/Exodia.app` (`.project-docs/processes/shared-app-development.md`).
- Вывод сборки и тестов — в файл: `<команда> > /tmp/exodia-akm.log 2>&1; tail -c 3000 /tmp/exodia-akm.log`. В шагах ниже указана только сама команда.
- Коммит после каждой задачи, локально в `claude/keys-and-models`, conventional commits, последняя строка `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Push и PR — только после «пушим» Максима. PR один, в конце: часть A без части C ломает старую вкладку Models (она пишет `sidekey.models.*`, которые рантайм больше не читает).
- Keychain: service `BuildConfig.keychainService`; accounts не меняются: `byok.soniox.api_key`, `byok.deepgram.api_key`, `byok.elevenLabs.api_key`, `byok.selfHosted.api_key`, `byok.openrouter.llm_api_key`, `byok.custom_llm.api_key`. Новые серверы — `byok.server.<uuid в нижнем регистре>.api_key`. `CredentialMigration.migratedAccounts` не трогать: новые accounts никогда не писались в `.token`-файлы.
- Старые ключи UserDefaults (`sidekey.models.*`, `agent.opencode.model`) новый код только читает: не пишет и не удаляет.
- Ключи, транскрипты, промпты и ответы моделей не попадают в `os_log`, UserDefaults и файлы. Каждый новый файл с `os_log` — в `LocalPathLoggingInvariantTests.guardedFiles`; в логах только провайдер, режим, исход и миллисекунды.
- Модель и провайдер меняются только действием пользователя. Данные фичи, её запасного пути и пробы идут только к провайдеру маршрута этой фичи.
- Сеть в тестах — только `StubURLProtocol`, `StubWebSocketTransport` или фейк протокола. Живые запросы с ключами Максима — только с его отдельного «да».
- UI — английский, sentence case, только MacUI (`MacCard`, `MacRow`, `MacRowSeparator`, `MacGroupTitle`, `MacBanner`, `MacField`, `MacButton`, `MacPill`, `MacSwitch`, `ProviderBrandIcon`). Строки дословно: вкладка `API & Models`; блоки `API keys`, `Models`; фичи `Drop Fast`, `Drop Smart`, `Drop Smart cleanup`, `Meetings`, `Meeting notes`, `Agent`, `Agent voice`, `Voice search`; режимы `real-time`, `recorded`, `LLM`, `LLM with tools`; статусы `Not verified`, `Deprecated alias`, `Removed by provider`, `Not supported yet`, `Key problem`, `Not set`, `Limited key`; действия `Add key`, `Replace key`, `Remove`, `Check now`, `Choose model`, `Refresh models`, `Other model ID…`, `Use`, `Not now`, `Set up`, `Change in API & Models`; подписи `checked when picked`, `Couldn't refresh`.
- View-тесты в этом репо сверяют текст исходника (как `AgentModeViewTests`); новые view-тесты — так же.

## Review Focus

1. **Apple Silicon без сохранённого уровня или с retired `local`, но с ключами в Keychain.** После миграции все фичи Not set, ни одна не включилась сама; Drop открывает API & Models на своей строке. Тесты — Задача 3 (`test_apple_silicon_without_a_level_stays_not_set_even_with_keys`), Задача 17 (`test_show_with_feature_focuses_that_row`).
2. **Drop начат в Fast, режим переключён в острове до Retry.** Retry идёт к провайдеру Fast-маршрута, зафиксированного на старте; LLM-чистка не запускается. Тесты — Задача 4 (`test_begin_latches_mode_and_route`), Задача 5 (`test_drop_batch_uses_the_route_latched_at_take_start`).
3. **Удалён ключ провайдера, на котором стоят фичи.** Фичи Not set, ничего не переехало на другой провайдер, запасной путь недоступен. Тесты — Задача 2 (`test_missing_key_never_falls_back_to_another_provider`), Задача 5 (`test_no_key_means_no_batch_and_no_other_provider`), Задача 15 (`test_remove_key_unsets_features_and_reassigns_nothing`).
4. **Нет сети или 5xx при обновлении каталога.** Остаётся кэш с «Couldn't refresh», ни одна модель не становится Removed, фичи работают. Тесты — Задача 10 (`test_offline_refresh_keeps_models_and_marks_couldnt_refresh`), Задача 13 (`test_removed_only_when_the_catalog_is_authoritative`).
5. **Свой сервер без ключа.** Real-time, batch, LLM, каталог и проба не шлют `Authorization`. Тесты — Задачи 2, 5, 6, 9, 12.

## Решения исполнителя (на проверку Максиму)

1. **Drop Fast не зовёт LLM.** Уже сделано в main PR #35 (`DropOutputPolicy`, решение `.project-docs/decisions/2026-10-19-strict-drop-modes.md`). План это не дублирует: режим на старте дропа фиксирует `DropTake` вместо `dropTurnMode` (Задача 4), чистка Smart идёт по маршруту `.dropSmartCleanup` (Задача 6).
2. Ключ, который провайдер не принял (401), при Add key не сохраняется: окно показывает ошибку. Ключ без денег (402) сохраняется с красной точкой.
3. Миграция назначает маршрут, только если у провайдера есть ключ (у сервера — всегда).
4. Рекомендуемые модели (сверено с публичным каталогом OpenRouter и докой провайдеров 19.10): real-time — Soniox `stt-rt-v5`, Deepgram `nova-3`, ElevenLabs `scribe_v2_realtime`; Meetings на Soniox — `stt-async-v5`; LLM — `google/gemini-3.8-flash`; Agent — `anthropic/claude-sonnet-5.5`.
5. N = M = 64 000 токенов; срок каталога и проверки ключа — 24 ч; таймаут пробы — 15 с.
6. STT-проба шлёт 1 с цифровой тишины (спека это допускает). Вшитый клип речи не делаем: у таргета нет ресурсов SwiftPM, а у голосов macOS спорная лицензия.
7. Проба без сети — «Couldn't check»: модель не меняется, результат не кэшируется.
8. Deepgram отдаёт `nova-3` в каталоге как `nova-3-general` (проверено на публичном `/v1/models` 19.10). Каталог Deepgram добавляет id `<arch>` для `<arch>-general`, иначе все Deepgram-строки ложно получили бы «Removed by provider».
9. OpenRouter `403` на `/key` (guardrail или бюджет ключа) — красная точка, как кончившиеся деньги.
10. Сервер, который отвечает `404` на `/models`, считается рабочим; модели — через «Other model ID…» и пробу.
11. `SettingsWindowTab.models` переименовывается в `.apiAndModels`: raw value вкладки нигде не хранится (проверено). Иконка прежняя, `cpu`.
12. Отказ модели в рантайме записывается для LLM-фич (Drop Smart cleanup, Meeting notes) и виден статусом строки. Для real-time отказ при открытии сокета отдельно не разбирается: Drop уходит в запасную расшифровку, как сейчас, а снятую модель показывает статус каталога «Removed by provider».

## Сверка с main a316508 (PR #35)

PR #35 влит после того, как спека и план были написаны. Он не противоречит спеке; план сохраняет его поведение так:

- **Строгие Fast/Smart** (`DropOutputPolicy`, `DropProcessingRetry`, `pendingProcessingRetry`) остаются как есть и остаются единственным владельцем правила «Fast без LLM, Smart без тихой вставки сырого текста». `DropTake` (Задача 4) заменяет `dropTurnMode`: одна фиксация режима и маршрута на старте дропа, без второй копии. Свойства `runsCleanup` у `DropTake` нет.
- **Языковая политика Deepgram** (`DeepgramLanguagePolicy`) остаётся во всех путях: real-time фабрика проверяет язык до ключа (`FeatureRouteError.invalidLanguageConfiguration`, Задача 4), batch — в `ProviderBatchTranscriber.deepgram` с моделью маршрута (Задача 5). Проба (Задача 12) открывает сокет с `language: "en"` — это проходит политику для всех моделей Deepgram.
- **Меню языка ввода** из старой вкладки Models в API & Models не переносится: язык ввода общий для всех голосовых фич и меняется в острове и в настройках митингов. Вместо меню строка фичи на Deepgram показывает предупреждение, если её модель не подходит к текущему языку ввода (Задача 15). Тексты `DeepgramLanguageConfigurationError.errorDescription` ссылаются на старую вкладку («below», «Save») и меняются на тексты Задачи 15.
- **Ошибка настройки Smart** в острове: `"Set up Smart in Models"` → `"Set up Smart in API & Models"`; `requiresConfiguration` открывает API & Models на строке Drop Smart cleanup (Задача 17).
- **Идентичность сборки** в окне настроек (`AppBuildIdentity`: заголовок окна, блок версии в сайдбаре, пункт Quit) сохраняется при замене вкладки (Задача 17).
- **Остров:** на `.inserting` метки провайдера нет (#35) — Задача 8 это не трогает.

## Карта файлов

Новые — `Sources/Sidekey/AIRouting/`:

| Файл | Ответственность |
|---|---|
| `AIFeature.swift` | `AIFeature`, `AIFeatureMode`, `ModelUse`, `AIProviderKind`, правило «фича × провайдер → тип модели» |
| `ProviderAccount.swift` | `ProviderAccount`, `ServerEndpoint`, имя Keychain-аккаунта |
| `AIRoutingStore.swift` | `FeatureRoute`, `AIRoutingState`, хранилище маршрутов и серверов |
| `ProviderKeyStore.swift` | ключ по имени Keychain-аккаунта |
| `FeatureRouteResolver.swift` | маршрут фичи → `ResolvedRoute` с ключом или `FeatureRouteError` |
| `RealtimeAdapterFactory.swift` | `ResolvedRoute` → real-time адаптер |
| `AIRoutingMigration.swift` | одноразовый перенос старых настроек |
| `DropTake.swift` | режим и маршрут Drop, зафиксированные на старте |
| `ModelRegistry.swift` | вшитые модели, рекомендуемые, recorded-модели, версии адаптеров, пороги |
| `ModelCatalog.swift` | `CatalogModel`, загрузка каталогов провайдеров |
| `ModelCatalogStore.swift` | кэш каталогов, срок жизни, работа без сети |
| `ProviderKeyChecker.swift` | проверка ключей, `KeyStatusStore` |
| `ModelProbe.swift` | пробы моделей, `ModelCheckStore` |
| `ModelStatusResolver.swift` | статусы строк, секции выпадашки, групповое «Switch» |

Новые — `Sources/Sidekey/Settings/APIAndModels/`: `APIAndModelsViewModel.swift`, `APIAndModelsView.swift`, `ModelMenu.swift`, `KeyChipPopover.swift`, `AddKeySheet.swift`, `AssignModelsSheet.swift`.

Меняются: `TranscriptionSessionFactory`, `ProviderBatchTranscriber`, `OpenAIRealtimeAdapter`, `SonioxBYOKAdapter` (только статический запрос для пробы), `DirectLLMRouteResolver`, `PostProcessor`, `MeetingBYOKProcessor`, `SonioxMeetingTranscriber`, `MeetingsCoordinator`, `AgentSettingsStore`, `AgentRunOptions`, `OpenCodeEnvironment`, `OpenCodeProvider`, `OpenCodeEventMapper`, `AgentController`, `TranscriptionProviderBrand`, `OpenRouterLLMClient`, `SettingsWindowTab`, `SettingsWindowView`, `SettingsWindowController`, `AgentModeView`, `AppDelegate`.

Удаляются: `Settings/SettingsModelsView.swift`, `Settings/SettingsModelsViewModel.swift`, их тесты и `SettingsWindowTabModelsTests.swift`.

`SelfKeyPreferences` и `BYOKProvider` остаются — их читает миграция. Сеттеры `SelfKeyPreferences` после удаления старой вкладки зовут только тесты: сообщить Максиму как мёртвый код, в этом PR не удалять.

---

## Часть A — маршруты фич и рантайм

### Task 1: Реестр фич и хранилище маршрутов

**Files:**
- Create: `Sources/Sidekey/AIRouting/AIFeature.swift`, `Sources/Sidekey/AIRouting/ProviderAccount.swift`, `Sources/Sidekey/AIRouting/AIRoutingStore.swift`
- Test: `Tests/SidekeyTests/AIRouting/AIFeatureTests.swift`, `Tests/SidekeyTests/AIRouting/AIRoutingStoreTests.swift`

**Interfaces:**
- Consumes: `TranscriptionMode` (`Settings/TranscriptionMode.swift`).
- Produces:
```swift
enum AIFeatureMode: String, Codable, Sendable { case realtime, recorded, llm, llmWithTools; var label: String { get } }
enum AIFeature: String, CaseIterable, Codable, Sendable {
    case dropFast, dropSmart, dropSmartCleanup, meetings, meetingNotes, agent, agentVoice, voiceSearch
    var title: String { get }
    var mode: AIFeatureMode { get }
    static func drop(_ mode: TranscriptionMode) -> AIFeature
    func modelUse(on kind: AIProviderKind) -> ModelUse?
}
enum ModelUse: String, Codable, Sendable { case realtimeSTT, asyncSTT, chat, chatWithTools }
enum AIProviderKind: String, CaseIterable, Codable, Sendable {
    case soniox, deepgram, elevenLabs, openRouter, openAICompatible
    var displayName: String { get }   // "Soniox", "Deepgram", "ElevenLabs", "OpenRouter", "OpenAI-compatible server"
}
enum ProviderAccount: Hashable, Codable, Sendable {
    case soniox, deepgram, elevenLabs, openRouter, server(UUID)
    var kind: AIProviderKind { get }
    var storageID: String { get }      // "soniox" … "openRouter", "server:<uuid lowercased>"
    init?(storageID: String)           // Codable — одна такая строка
}
struct ServerEndpoint: Codable, Equatable, Identifiable, Sendable { let id: UUID; var name: String; var baseURL: String; let keyAccount: String }
struct FeatureRoute: Codable, Equatable, Sendable { var account: ProviderAccount; var model: String }
struct AIRoutingState: Codable, Equatable {
    var routes: [String: FeatureRoute]          // ключ — AIFeature.rawValue
    var migratedRoutes: [String: FeatureRoute]  // снимок миграции: «выбрано до миграции»
    var servers: [ServerEndpoint]
    var migrationVersion: Int                   // 0 — миграции не было
}
@MainActor final class AIRoutingStore: ObservableObject {
    static let shared: AIRoutingStore
    static let defaultsKey = "sidekey.aiRouting.v1"
    init(defaults: UserDefaults = .standard)
    @Published private(set) var state: AIRoutingState
    var isMigrated: Bool { get }
    func route(for feature: AIFeature) -> FeatureRoute?
    func migratedRoute(for feature: AIFeature) -> FeatureRoute?
    func setRoute(_ route: FeatureRoute?, for feature: AIFeature)
    func server(_ id: UUID) -> ServerEndpoint?
    @discardableResult func addServer(name: String, baseURL: String) -> ServerEndpoint
    func removeServer(_ id: UUID)                          // и снимает маршруты на нём
    @discardableResult func clearRoutes(using account: ProviderAccount) -> [AIFeature]
    func completeMigration(routes: [AIFeature: FeatureRoute], servers: [ServerEndpoint])  // routes == migratedRoutes, version 1
}
```
`modelUse(on:)` (nil — провайдер не умеет фичу):

| Фича | soniox | deepgram | elevenLabs | openRouter | openAICompatible |
|---|---|---|---|---|---|
| dropFast, dropSmart, agentVoice, voiceSearch | realtimeSTT | realtimeSTT | realtimeSTT | nil | realtimeSTT |
| meetings | asyncSTT | realtimeSTT | realtimeSTT | nil | realtimeSTT |
| dropSmartCleanup, meetingNotes | nil | nil | nil | chat | chat |
| agent | nil | nil | nil | chatWithTools | nil |

- [ ] **Step 1: Failing tests**

```swift
func test_features_follow_the_spec_table() {
    XCTAssertEqual(AIFeature.allCases, [.dropFast, .dropSmart, .dropSmartCleanup, .meetings, .meetingNotes, .agent, .agentVoice, .voiceSearch])
    XCTAssertEqual(AIFeature.allCases.map(\.title), ["Drop Fast", "Drop Smart", "Drop Smart cleanup", "Meetings", "Meeting notes", "Agent", "Agent voice", "Voice search"])
    XCTAssertEqual(AIFeature.allCases.map(\.mode.label), ["real-time", "real-time", "LLM", "recorded", "LLM", "LLM with tools", "real-time", "real-time"])
    XCTAssertEqual(AIFeature.drop(.fast), .dropFast)
    XCTAssertEqual(AIFeature.drop(.smart), .dropSmart)
}
func test_model_use_matches_the_provider_table()   // все 40 клеток таблицы выше
```
`AIRoutingStoreTests` (у каждого теста свой `UserDefaults(suiteName: UUID().uuidString)`):
- `test_route_round_trips_through_user_defaults` — второй `AIRoutingStore` на тех же defaults читает `FeatureRoute(account: .soniox, model: "stt-rt-v4")` для `.dropFast`.
- `test_stored_json_uses_feature_and_account_ids` — данные по `"sidekey.aiRouting.v1"` через `JSONSerialization`: `routes["dropFast"]["account"] == "soniox"`; маршрут на сервер хранит `"server:<uuid lowercased>"`.
- `test_new_server_gets_its_own_keychain_account` — `keyAccount == "byok.server.\(id.uuidString.lowercased()).api_key"`.
- `test_clear_routes_using_account_unsets_only_that_account` — `.dropFast` и `.agentVoice` на Soniox, `.meetings` на Deepgram → возвращает `[.dropFast, .agentVoice]`, `.meetings` цел.
- `test_removing_a_server_unsets_its_features`.
- `test_unreadable_json_reads_as_empty_unmigrated_state` — мусор по ключу → `isMigrated == false`, маршрутов нет.

- [ ] **Step 2:** `swift test --filter "AIFeatureTests|AIRoutingStoreTests"` → FAIL (типов нет).
- [ ] **Step 3: Реализовать** типы и store по Interfaces. Store держит состояние в памяти и сохраняет JSON при каждом изменении.
- [ ] **Step 4:** тот же фильтр → PASS.
- [ ] **Step 5: Commit** `feat(ai-routing): add AI feature registry and route store`.

### Task 2: Ключи по аккаунтам, разрешение маршрута, real-time адаптер

**Files:**
- Create: `Sources/Sidekey/AIRouting/ProviderKeyStore.swift`, `FeatureRouteResolver.swift`, `RealtimeAdapterFactory.swift`
- Modify: `Sources/Sidekey/Streaming/BYOK/OpenAIRealtimeAdapter.swift:13-24`
- Test: `Tests/SidekeyTests/AIRouting/ProviderKeyStoreTests.swift`, `FeatureRouteResolverTests.swift`, `RealtimeAdapterFactoryTests.swift`; дописать `Tests/SidekeyTests/Streaming/BYOK/OpenAIRealtimeAdapterTests.swift`

**Interfaces:**
- Consumes: Task 1.
- Produces:
```swift
extension ProviderAccount { @MainActor func keychainAccount(in routing: AIRoutingStore) -> String? }
struct ProviderKeyStore {
    init(makeStore: @escaping (String) -> any TokenStore = { KeychainStore(service: BuildConfig.keychainService, account: $0) })
    func read(account: String) -> String?     // trim; "" и ошибки Keychain → nil
    func save(_ key: String, account: String) throws
    func delete(account: String) throws
}
enum FeatureRouteError: Error, Equatable {
    case notSet(AIFeature), missingKey(AIFeature), missingBaseURL(AIFeature), invalidBaseURL(AIFeature)
    case invalidLanguageConfiguration(AIFeature, DeepgramLanguageConfigurationError)   // бросает фабрика Задачи 4, не резолвер
    var feature: AIFeature { get }
}
struct ResolvedRoute: Equatable, Sendable { let feature: AIFeature; let account: ProviderAccount; let model: String; let apiKey: String?; let server: ServerEndpoint? }
@MainActor struct FeatureRouteResolver {
    init(routing: AIRoutingStore = .shared, keys: ProviderKeyStore = ProviderKeyStore())
    func resolve(_ feature: AIFeature) throws -> ResolvedRoute
    func resolve(_ route: FeatureRoute, for feature: AIFeature) throws -> ResolvedRoute
}
enum RealtimeAdapterFactory { static func make(_ route: ResolvedRoute) throws -> BYOKTranscriptionAdapter }
extension OpenAIRealtimeAdapter { static func handshakeRequest(url: URL, apiKey: String) -> URLRequest }
```
Правила:
- Имя аккаунта: `BYOKKeyStore.account(for:)` для трёх STT-провайдеров, `OpenRouterLLMKeyStore.account` для OpenRouter, `ServerEndpoint.keyAccount` для сервера; удалённый сервер → nil.
- `resolve`: нет маршрута, пустая модель или удалённый сервер → `notSet`; не сервер и нет ключа → `missingKey`; сервер с пустым base URL → `missingBaseURL`; ключ сервера необязателен (`apiKey == nil`).
- Фабрика: Soniox, Deepgram, ElevenLabs → их адаптеры `(apiKey:model:)`; сервер → `BYOKRealtimeURL.openAIRealtime(baseURL:)`, nil → `invalidBaseURL`, иначе `OpenAIRealtimeAdapter(apiKey: route.apiKey ?? "", url:model:)`; OpenRouter → `notSet`.
- `handshakeRequest` ставит `Authorization: Bearer` только для непустого ключа; production-init адаптера строит запрос через него.

- [ ] **Step 1: Failing tests**
  - `test_accounts_are_the_legacy_keychain_names` — `"byok.soniox.api_key"`, `"byok.deepgram.api_key"`, `"byok.elevenLabs.api_key"`, `"byok.openrouter.llm_api_key"`; у сервера — его `keyAccount`.
  - `test_blank_key_reads_as_missing` — `"  \n"` → nil.
  - `test_unset_feature_is_not_set` → `.notSet(.dropSmart)`.
  - `test_missing_key_never_falls_back_to_another_provider` — `.dropFast` на Deepgram, ключа Deepgram нет, ключ Soniox есть → `.missingKey(.dropFast)`.
  - `test_server_without_key_resolves_with_nil_key`.
  - `test_deleted_server_is_not_set`.
  - `test_builds_the_adapter_of_the_route_provider` — `XCTAssertTrue(try RealtimeAdapterFactory.make(route) is SonioxBYOKAdapter)`; так же для Deepgram, ElevenLabs и сервера (`OpenAIRealtimeAdapter`).
  - `test_server_without_host_fails_before_any_socket` → `.invalidBaseURL`.
  - `test_handshake_has_no_authorization_without_key`, `test_handshake_sends_bearer_with_key`.
- [ ] **Step 2:** `swift test --filter "ProviderKeyStoreTests|FeatureRouteResolverTests|RealtimeAdapterFactoryTests|OpenAIRealtimeAdapterTests"` → FAIL.
- [ ] **Step 3: Реализовать** по Interfaces.
- [ ] **Step 4:** тот же фильтр → PASS.
- [ ] **Step 5: Commit** `feat(ai-routing): resolve feature routes with per-account keys`.

### Task 3: Миграция старых настроек

**Files:**
- Create: `Sources/Sidekey/AIRouting/AIRoutingMigration.swift`
- Modify: `Sources/Sidekey/AppDelegate.swift:346` (сразу после `CredentialMigration().run()`)
- Test: `Tests/SidekeyTests/AIRouting/AIRoutingMigrationTests.swift`

**Interfaces:**
- Consumes: Tasks 1–2, `SelfKeyPreferences`, `OpenCodeEnvironment.normalizeModel`, `SonioxFileAPI.asyncModel`, `CustomLLMKeyStore.account`.
- Produces:
```swift
@MainActor struct AIRoutingMigration {
    init(prefs: SelfKeyPreferences, defaults: UserDefaults, routing: AIRoutingStore, keys: ProviderKeyStore)
    static func live() -> AIRoutingMigration
    func run()      // ничего не делает, если routing.isMigrated
}
```
Правила (таблица «Миграция» спеки):
1. **Серверы.** `prefs.selfHostedBaseURL` → S1 с `keyAccount` `"byok.selfHosted.api_key"`; `prefs.customLLMBaseURL` → S2 с `"byok.custom_llm.api_key"`. Одинаковый URL (после trim) и одинаковый ключ → один сервер S1. Имя — `host[:port]`; при совпадении имён S1 получает « (speech)», S2 — « (LLM)».
2. **Real-time** (`dropFast`, `dropSmart`, `agentVoice`, `voiceSearch`) — только при `prefs.transcriptionLevel == .yourKey`. Аккаунт — `prefs.selectedProvider` (`selfHosted` → S1); модель — `prefs.transcriptionModel(for:)` без замены (`stt-rt-v4` остаётся).
3. **meetings** — тот же аккаунт; Soniox → `SonioxFileAPI.asyncModel`, остальные — модель real-time.
4. **LLM** (`dropSmartCleanup`, `meetingNotes`): `.yourKey` → OpenRouter + `prefs.openRouterModel`; `.custom` → S2 + `prefs.customLLMModel`; nil → нет маршрута.
5. **agent** — `defaults.string(forKey: "agent.opencode.model")` через `OpenCodeEnvironment.normalizeModel`; непустая и без пробелов → OpenRouter.
6. Маршрут назначается, только если у аккаунта есть ключ (у сервера — всегда).
7. Итог — `routing.completeMigration(routes:servers:)`. Старые ключи UserDefaults не пишутся.

- [ ] **Step 1: Failing tests** (defaults — `UserDefaults(suiteName:)`; ключи — `ProviderKeyStore(makeStore:)` поверх общего `InMemoryTokenStore.Box`; `SelfKeyPreferences(defaults:isAppleSilicon:)`)

```swift
func test_maxims_prod_settings_migrate_without_changing_any_model() {
    // given: level "yourKey", provider "soniox", "sidekey.models.byokModel.soniox" = "stt-rt-v4", ключ Soniox;
    //        llmLevel "yourKey", openRouterModel "google/gemini-3.8-flash", ключ OpenRouter;
    //        "agent.opencode.model" = "anthropic/claude-sonnet-5.5"
    for f in [AIFeature.dropFast, .dropSmart, .agentVoice, .voiceSearch] {
        XCTAssertEqual(routing.route(for: f), FeatureRoute(account: .soniox, model: "stt-rt-v4"))
    }
    XCTAssertEqual(routing.route(for: .meetings), FeatureRoute(account: .soniox, model: "stt-async-v5"))
    XCTAssertEqual(routing.route(for: .dropSmartCleanup), FeatureRoute(account: .openRouter, model: "google/gemini-3.8-flash"))
    XCTAssertEqual(routing.route(for: .meetingNotes), FeatureRoute(account: .openRouter, model: "google/gemini-3.8-flash"))
    XCTAssertEqual(routing.route(for: .agent), FeatureRoute(account: .openRouter, model: "anthropic/claude-sonnet-5.5"))
    XCTAssertEqual(routing.migratedRoute(for: .dropFast), routing.route(for: .dropFast))
}
```
  - `test_apple_silicon_without_a_level_stays_not_set_even_with_keys` (Review Focus 1) — `isAppleSilicon: true`, уровни не сохранены, ключи Soniox и OpenRouter есть → у всех восьми фич `route == nil`.
  - `test_retired_local_level_stays_not_set` — оба уровня `"local"` на Intel → маршрутов нет.
  - `test_intel_without_a_level_keeps_its_key_default` — Intel, уровней нет, ключ Soniox → real-time фичи на `stt-rt-v5`.
  - `test_provider_without_key_stays_not_set`.
  - `test_self_hosted_and_custom_llm_become_two_servers_with_legacy_key_accounts` — `.dropFast` → `server(S1)` + `selfHostedModel`; `.dropSmartCleanup` → `server(S2)` + `customLLMModel`.
  - `test_same_url_and_key_become_one_server`.
  - `test_second_run_changes_nothing` — после первого прогона меняем prefs; второй прогон маршруты не трогает.
  - `test_old_user_defaults_are_left_untouched` — все `sidekey.models.*` и `agent.opencode.model` до и после совпадают.
- [ ] **Step 2:** `swift test --filter AIRoutingMigrationTests` → FAIL.
- [ ] **Step 3: Реализовать**; в `AppDelegate` — `AIRoutingMigration.live().run()` сразу после `CredentialMigration().run()` (синхронно, без сети).
- [ ] **Step 4:** тот же фильтр → PASS; `swift build` → OK.
- [ ] **Step 5: Commit** `feat(ai-routing): migrate existing provider and model choices`.

### Task 4: Real-time фичи читают свой маршрут; Drop фиксируется на старте

**Files:**
- Create: `Sources/Sidekey/AIRouting/DropTake.swift`
- Modify: `Sources/Sidekey/Streaming/BYOK/TranscriptionSessionFactory.swift` (целиком); в `AppDelegate.swift` — `StreamingSessionSetupError`, `dropTurnMode` и `startDropTurnTelemetry()`, `dropDeliverySink(targetApp:targetPID:)`, `runPostProcessAndPaste` (только откуда берётся режим), голос агента и голосовой поиск, `startStreamingSession()`, `makeStreamingSession`
- Test: `Tests/SidekeyTests/AIRouting/DropTakeTests.swift`; переписать `Tests/SidekeyTests/Streaming/BYOK/TranscriptionSessionFactoryTests.swift` (вместе с языковыми тестами Deepgram из PR #35) и real-time часть `Tests/SidekeyTests/Settings/RetiredLocalRouteTests.swift`

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces:
```swift
@MainActor final class DropTake {
    static let shared: DropTake
    init()
    private(set) var mode: TranscriptionMode      // .fast до первого begin
    private(set) var route: FeatureRoute?
    var feature: AIFeature { get }                // .drop(mode)
    func begin(mode: TranscriptionMode, route: FeatureRoute?)
}
@MainActor struct TranscriptionSessionFactory {
    init(resolver: FeatureRouteResolver = FeatureRouteResolver(), vocab: VocabularyCache = .shared,
         makeAdapter: @escaping (ResolvedRoute) throws -> BYOKTranscriptionAdapter = RealtimeAdapterFactory.make)
    func make(feature: AIFeature, language: String?, resilient: Bool = false) throws -> StreamingSessionRunning  // throws FeatureRouteError
}
enum StreamingSessionSetupError: Error { case byokMisconfigured(FeatureRouteError) }
```
`TranscriptionFactoryError` удаляется.

Фабрика: маршрут фичи → если аккаунт Deepgram и `DeepgramLanguagePolicy.configurationError(model: route.model, language: language)` не nil — `FeatureRouteError.invalidLanguageConfiguration(feature, error)` **до** проверки ключа (порядок из PR #35) → `resolver.resolve(feature)` → `makeAdapter`.

AppDelegate:
- `makeStreamingSession(feature: AIFeature, resilient: Bool = false)`.
- `startDropTurnTelemetry()` — единственное место, где начинается новый дроп (его зовут ветки `.startStreamingSession`, `.startRecording` и старт после `.discardFailedTakeAndStart`). Вместо `dropTurnMode = UserPreferencesCache.shared.currentMode` оно зовёт `let mode = UserPreferencesCache.shared.currentMode; DropTake.shared.begin(mode: mode, route: AIRoutingStore.shared.route(for: .drop(mode)))`. Свойство `dropTurnMode` удаляется; все его чтения (`runPostProcessAndPaste`, `dropDeliverySink`, лог старта) читают `DropTake.shared.mode`. Запасной `startRecording()` после сбоя стрима заново не фиксирует. `DropOutputPolicy`, `DropProcessingRetry` и `pendingProcessingRetry` из PR #35 не меняются.
- `startStreamingSession()` → `makeStreamingSession(feature: DropTake.shared.feature, resilient: AgentFeatureGate.resilientDropDeliveryEnabled)`.
- Голос агента → `.agentVoice`, поиск Google → `.voiceSearch` (оба `resilient: false`).
- `.byokMisconfigured` пока открывает `.models` (переход на строку — Задача 17).

- [ ] **Step 1: Failing tests**
  - `test_begin_latches_mode_and_route` — после `begin(mode: .fast, route: r)`: `mode == .fast`, `feature == .dropFast`, `route == r`; после `begin(mode: .smart, …)`: `mode == .smart`, `feature == .dropSmart`.
  - `test_deepgram_language_problem_is_reported_before_the_key` — `.dropFast` на Deepgram `nova-3`, ключа нет, язык `"cy"` → `.invalidLanguageConfiguration(.dropFast, .unsupportedLanguage)`; модель `"custom-model"`, язык nil → `.invalidLanguageConfiguration(.dropFast, .automaticLanguageUnavailable)`; адаптер не создаётся. Остальные языковые случаи PR #35 из `TranscriptionSessionFactoryTests` переносятся на новый API.
  - `test_each_realtime_feature_uses_its_own_route` — `.dropFast` на Soniox `stt-rt-v4`, `.agentVoice` на Deepgram `nova-3`; `makeAdapter` записывает `ResolvedRoute`: для `.agentVoice` — `account == .deepgram`, `model == "nova-3"`, `apiKey == "dg-key"`.
  - `test_unset_feature_throws_not_set_for_that_feature` → `FeatureRouteError.notSet(.voiceSearch)`.
  - `RetiredLocalRouteTests`: retired Local и Apple Silicon без уровня → после миграции `make(feature: .dropFast, …)` бросает `.notSet(.dropFast)`, адаптер не создаётся.
- [ ] **Step 2:** `swift test --filter "DropTakeTests|TranscriptionSessionFactoryTests|RetiredLocalRouteTests"` → FAIL.
- [ ] **Step 3: Реализовать** фабрику, `DropTake` и правки `AppDelegate`.
- [ ] **Step 4:** тот же фильтр → PASS; `swift build` → OK.
- [ ] **Step 5: Commit** `feat(ai-routing): open realtime sessions from each feature's route`.

### Task 5: Запасная расшифровка — к провайдеру своей фичи

**Files:**
- Create: `Sources/Sidekey/AIRouting/ModelRegistry.swift` (только константы этой задачи)
- Modify: `Sources/Sidekey/Streaming/BYOK/ProviderBatchTranscriber.swift:7-58, 80-103, 117-123, 171-201, 220`; `AppDelegate.swift:65, 1798, 2448, 3031, 3057`
- Test: `Tests/SidekeyTests/Streaming/BYOK/ProviderBatchTranscriberTests.swift`

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces:
```swift
enum ModelRegistry {
    static let sonioxRecordedModel = "stt-async-v5"        // == SonioxFileAPI.asyncModel
    static let elevenLabsRecordedModel = "scribe_v2"
}
enum ProviderBatchRoute: Equatable, Sendable {
    case soniox(apiKey: String, model: String)
    case deepgram(apiKey: String, model: String)
    case elevenLabs(apiKey: String, model: String)
    case selfHosted(apiKey: String?, endpoint: URL, model: String)
    static func make(for route: ResolvedRoute) -> ProviderBatchRoute?
}
extension ProviderBatchTranscriber {
    @MainActor static func forDrop(take: DropTake = .shared, resolver: FeatureRouteResolver = FeatureRouteResolver()) -> ProviderBatchTranscriber
    @MainActor static func forFeature(_ feature: AIFeature, resolver: FeatureRouteResolver = FeatureRouteResolver()) -> ProviderBatchTranscriber
}
```
- `make(for:)`: Soniox → `sonioxRecordedModel`; ElevenLabs → `elevenLabsRecordedModel`; Deepgram и сервер — модель маршрута; сервер — `selfHostedEndpoint(baseURL:)`, nil → nil; OpenRouter → nil.
- `forDrop` берёт `take.route` и `take.feature` (маршрут, зафиксированный на старте); `forFeature` читает маршрут на каждом вызове. Ключ всегда читается в момент вызова.
- У `init(route:…)` убрать значение по умолчанию. Задание Soniox шлёт `"model": model`, ElevenLabs — `model_id = model`; сервер ставит `Authorization` только при непустом ключе. Метки провайдера в `os_log` прежние.
- Deepgram batch сохраняет языковую политику PR #35: `DeepgramLanguagePolicy.queryLanguage(model:language:)` с моделью маршрута, ошибка — до отправки аудио. Языковые тесты PR #35 в `ProviderBatchTranscriberTests` переводятся на case с `model`.
- AppDelegate: `batchTranscriber` → `dropBatchTranscriber = ProviderBatchTranscriber.forDrop()` (recorder fallback, `recoverViaBatch`, `resolveViaSink`, Retry) и `agentBatchTranscriber = ProviderBatchTranscriber.forFeature(.agentVoice)` (`BatchAgentAudioTranscriber`).

- [ ] **Step 1: Failing tests**

```swift
func test_drop_batch_uses_the_route_latched_at_take_start() async throws {   // Review Focus 2
    let take = DropTake()
    take.begin(mode: .fast, route: FeatureRoute(account: .soniox, model: "stt-rt-v5"))
    routing.setRoute(FeatureRoute(account: .elevenLabs, model: "scribe_v2_realtime"), for: .dropFast)  // поменяли после старта
    routing.setRoute(FeatureRoute(account: .elevenLabs, model: "scribe_v2_realtime"), for: .dropSmart)
    _ = try await ProviderBatchTranscriber.forDrop(take: take, resolver: resolver).transcribe(audio: pcm, language: nil)
    // все запросы — на api.soniox.com; тело задания содержит "model":"stt-async-v5"
}
```
  - `test_agent_batch_voice_uses_the_agent_voice_provider` — `.agentVoice` на Deepgram `nova-3`, `.dropFast` на Soniox → запрос на `api.deepgram.com/v1/listen` с `model=nova-3`.
  - `test_no_key_means_no_batch_and_no_other_provider` — `.agentVoice` на ElevenLabs без ключа, ключ Soniox есть → `isAvailable() == false`, запросов 0.
  - `test_elevenlabs_batch_sends_the_registry_model` — форма содержит `scribe_v2`.
  - `test_self_hosted_batch_without_key_sends_no_authorization` (Review Focus 5).
  - Существующие тесты переводятся на case-ы с `model`.
- [ ] **Step 2:** `swift test --filter ProviderBatchTranscriberTests` → FAIL.
- [ ] **Step 3: Реализовать**; заменить вызовы в `AppDelegate`.
- [ ] **Step 4:** тот же фильтр → PASS; `swift build` → OK.
- [ ] **Step 5: Commit** `feat(ai-routing): send batch fallbacks to the feature's own provider`.

### Task 6: LLM-фичи; чистка Smart по своему маршруту

**Files:**
- Modify: `Sources/Sidekey/Streaming/BYOK/DirectLLMRouteResolver.swift` (целиком); `PostProcessor.swift` (`init`, `process`)
- Test: `Tests/SidekeyTests/PostProcessorOpenRouterTests.swift`; `Tests/SidekeyTests/AIRouting/DirectLLMRouteResolverTests.swift`; LLM-часть `RetiredLocalRouteTests`

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces:
```swift
struct DirectLLMRouteResolver {
    init(feature: AIFeature, routing: AIRoutingStore, keys: ProviderKeyStore = ProviderKeyStore())
    @MainActor static func live(_ feature: AIFeature) -> DirectLLMRouteResolver
    func routeIfEnabled() async throws -> DirectLLMRoute?    // nil — у фичи нет маршрута
}
struct PostProcessor {
    init(llmRoute: DirectLLMRouteResolver, openRouterClient: any OpenRouterLLMClienting = OpenRouterLLMClient(profile: .dictation))
    @MainActor init()                                        // .live(.dropSmartCleanup)
}
```
- Резолвер: маршрута нет → nil; OpenRouter без ключа → `OpenRouterLLMError.missingKey`; сервер — прежняя проверка base URL (`http`/`https` + host, иначе `.invalidBaseURL`), ключ необязателен → `.custom(baseURL:apiKey:)`; STT-аккаунт → nil. Маршрут читается на `MainActor` при каждом вызове.
- `AppDelegate` эта задача не меняет: правило Fast/Smart держит `DropOutputPolicy` (PR #35), режим уже читается из `DropTake.shared.mode` (Задача 4), `self.postProcessor = PostProcessor()` попадает в новый `@MainActor init()`.

- [ ] **Step 1: Failing tests**
  - `test_cleanup_uses_only_the_cleanup_route` — `.dropSmartCleanup` на сервере `http://llm.local:8080/v1` с моделью `qwen`, `.meetingNotes` на OpenRouter → запрос на `http://llm.local:8080/v1/chat/completions`, в теле `"model":"qwen"`, заголовка `Authorization` нет.
  - `test_cleanup_without_route_throws_not_configured` → `OpenRouterLLMError.notConfigured`, запросов 0.
  - `test_openrouter_route_without_key_throws_missing_key`.
  - `test_notes_resolver_reads_its_own_feature` — `.live(.meetingNotes)` отдаёт модель строки Meeting notes.
  - `RetiredLocalRouteTests`: retired LLM-уровень → маршрута нет → `notConfigured`.
- [ ] **Step 2:** `swift test --filter "PostProcessorOpenRouterTests|DirectLLMRouteResolverTests|RetiredLocalRouteTests"` → FAIL.
- [ ] **Step 3: Реализовать**; правки `AppDelegate`.
- [ ] **Step 4:** тот же фильтр → PASS; `swift build` → OK.
- [ ] **Step 5: Commit** `feat(ai-routing): route Drop Smart cleanup through its own feature`.

### Task 7: Митинги — своя модель записи и заметок

**Files:**
- Modify: `Sources/Sidekey/Meetings/MeetingBYOKProcessor.swift:45-127, 207-227`; `Meetings/SonioxMeetingTranscriber.swift:25, 76`; `Meetings/MeetingsCoordinator.swift:110-111`
- Test: `MeetingBYOKProcessorTests`, `SonioxMeetingTranscriberTests` (в `Tests/SidekeyTests/Meetings/`), meeting-часть `RetiredLocalRouteTests`

**Interfaces:**
- Consumes: Tasks 1–6.
- Produces:
```swift
// MeetingBYOKProcessor (convenience init() — .shared routing и .live(.meetingNotes))
init(routing: AIRoutingStore, keys: ProviderKeyStore = ProviderKeyStore(), vocab: VocabularyCache,
     notesRoute: DirectLLMRouteResolver, openRouterClient: any OpenRouterLLMClienting = OpenRouterLLMClient(),
     fileManager: FileManager = .default, sonioxSession: URLSession = .shared,
     makeAdapter: @escaping (ResolvedRoute) throws -> BYOKTranscriptionAdapter = RealtimeAdapterFactory.make)
// SonioxMeetingTranscriber
init(apiKey: String, model: String, session: URLSession = .shared, pollInterval: Duration = .seconds(3), timeout: TimeInterval = 1800)
```
- `shouldProcessDirectly()` — есть маршруты и у `.meetings`, и у `.meetingNotes`.
- `process`: `.meetings` через `FeatureRouteResolver` (`missingKey` → `.missingTranscriptionKey`; `missingBaseURL`/`invalidBaseURL` → `.missingSelfHostedBaseURL`); Soniox → `SonioxMeetingTranscriber(apiKey:model: route.model, …)`, иначе `MeetingBYOKTranscriber(adapter: makeAdapter(route), …)`. Заметки — через `notesRoute`.
- `processorNotConfiguredMessage` = `"Choose models for Meetings and Meeting notes in Settings > API & Models to process this meeting."`

- [ ] **Step 1: Failing tests**
  - `test_meeting_uses_the_meetings_route_not_the_drop_route` — `.meetings` на Deepgram `nova-3`, `.dropFast` на Soniox → `makeAdapter` получил `account == .deepgram`.
  - `test_soniox_meeting_sends_the_route_model` — тело задания содержит `"model":"stt-async-v5"`.
  - `test_notes_go_to_the_notes_route` — URL и модель заметок из `.meetingNotes`.
  - `test_meeting_waits_without_a_notes_model` — нет `.meetingNotes` → `shouldProcessDirectly() == false`.
  - `test_not_configured_message_points_to_api_and_models`.
- [ ] **Step 2:** `swift test --filter "MeetingBYOKProcessorTests|SonioxMeetingTranscriberTests|RetiredLocalRouteTests|MeetingsCoordinator"` → FAIL.
- [ ] **Step 3: Реализовать.**
- [ ] **Step 4:** тот же фильтр → PASS.
- [ ] **Step 5: Commit** `feat(ai-routing): give meetings and meeting notes their own routes`.

### Task 8: Агент и иконки острова; полный прогон части A

**Files:**
- Modify: `Sources/Sidekey/AgentDaemon/AgentSettingsStore.swift:43-87`; `TranscriptionProviderBrand.swift:25-85`
- Test: `AgentSettingsStoreTests`, `AgentRunOptionsMappingTests`, `Tests/SidekeyTests/TranscriptionProviderBrandTests.swift`

**Interfaces:**
- Consumes: Tasks 1, 4.
- Produces:
```swift
// AgentSettingsStore
init(defaults: UserDefaults = .standard, codexConfig: CodexConfigSnapshot = CodexConfigReader().read(), routing: AIRoutingStore = .shared)
var selectedOpenCodeModel: String? { get }   // маршрут .agent на OpenRouter → normalizeModel; иначе nil
// TranscriptionProviderBrand
@MainActor static func brand(for account: ProviderAccount, in routing: AIRoutingStore) -> TranscriptionProviderBrand
@MainActor static func currentDrop(take: DropTake = .shared, routing: AIRoutingStore = .shared) -> TranscriptionProviderBrand?
@MainActor static func currentDropCleanup(routing: AIRoutingStore = .shared) -> TranscriptionProviderBrand?
```
`brand(for:)`: Soniox, Deepgram, ElevenLabs — прежние ассеты; OpenRouter — `.openRouter`; сервер — `server.rack` с именем сервера. `currentDrop` — аккаунт `take.route`, без маршрута nil; `currentDropCleanup` — аккаунт `.dropSmartCleanup`. `openCodeModel` и каталог в `AgentSettingsStore` пока остаются (их убирает Задача 18). `IslandAgentFlowStore` не меняется: метка чистки только на `.verifying`, на `.inserting` её нет (PR #35).

- [ ] **Step 1: Failing tests**
  - `test_opencode_model_comes_from_the_agent_route` — `.agent` = OpenRouter `anthropic/claude-sonnet-5.5`, `openCodeModel = "x/y"` → `options(for: .opencode).model == "anthropic/claude-sonnet-5.5"`.
  - `test_no_agent_route_means_no_model`.
  - `test_drop_brand_follows_the_latched_take` — take на ElevenLabs → `label == "ElevenLabs"`; без маршрута → nil.
  - `test_cleanup_brand_follows_the_cleanup_route` — сервер `llm.local` → `systemName == "server.rack"`, `label == "llm.local"`.
- [ ] **Step 2:** `swift test --filter "AgentSettingsStoreTests|AgentRunOptionsMappingTests|TranscriptionProviderBrandTests"` → FAIL.
- [ ] **Step 3: Реализовать.**
- [ ] **Step 4:** тот же фильтр → PASS.
- [ ] **Step 5: Полный прогон части A:** `swift build`, `swift test` → `Executed N tests, with 0 failures`; N — в отчёт задачи. Упавшие тесты старых типов чинить здесь.
- [ ] **Step 6: Commit** `feat(ai-routing): read the agent model and island brands from feature routes`.

---

## Часть B — каталоги, проверка ключей и моделей

### Task 9: Вшитый реестр и загрузка каталогов

**Files:**
- Modify: `Sources/Sidekey/AIRouting/ModelRegistry.swift`
- Create: `Sources/Sidekey/AIRouting/ModelCatalog.swift`
- Test: `Tests/SidekeyTests/AIRouting/ModelRegistryTests.swift`, `ModelCatalogFetcherTests.swift`

**Interfaces:**
- Consumes: Tasks 1–2, `OpenRouterReasoningCapabilities`.
- Produces:
```swift
struct RegistryModel: Equatable, Sendable { let kind: AIProviderKind; let id: String; let uses: Set<ModelUse>; let diarization: Bool }
extension ModelRegistry {
    static let models: [RegistryModel]
    static func isVerified(_ id: String, kind: AIProviderKind, use: ModelUse) -> Bool
    static func recommended(for feature: AIFeature, kind: AIProviderKind) -> String?
    static func adapterVersion(_ kind: AIProviderKind, _ use: ModelUse) -> Int     // сейчас 1 везде
    static func knownUnsupportedReason(_ id: String, kind: AIProviderKind, use: ModelUse) -> String?
    static let meetingNotesMinContext = 64_000     // N
    static let agentMinContext = 64_000            // M
}
struct CatalogModel: Codable, Equatable, Sendable {
    let id: String
    var uses: Set<ModelUse>?            // nil — провайдер не сообщает (сервер)
    var aliasOf: String?                // Soniox aliased_model_id
    var contextLength: Int?
    var maxOutputTokens: Int?           // top_provider.max_completion_tokens
    var supportsTools: Bool?
    var supportsReasoning: Bool?        // "reasoning" в supported_parameters
    var reasoning: OpenRouterReasoningCapabilities?
    var expiresAt: Date?
}
enum CatalogFetchError: Error, Equatable { case http(Int, code: String?), offline, malformed }
protocol ModelCatalogFetching: Sendable {
    func fetch(account: ProviderAccount, apiKey: String?, server: ServerEndpoint?) async throws -> [CatalogModel]
}
struct ModelCatalogFetcher: ModelCatalogFetching { init(session: URLSession = .shared) }
extension ServerEndpoint { var modelsURL: URL? { get } }
```
Реестр:
- Soniox `stt-rt-v5` {realtimeSTT}, `stt-async-v5` {asyncSTT, спикеры}; Deepgram `nova-3` {realtimeSTT}; ElevenLabs `scribe_v2_realtime` {realtimeSTT}, `scribe_v2` {asyncSTT}; OpenRouter `google/gemini-3.8-flash` {chat}, `anthropic/claude-sonnet-5.5` {chat, chatWithTools}.
- Рекомендуемые: real-time фичи — `stt-rt-v5` / `nova-3` / `scribe_v2_realtime`; meetings — `stt-async-v5` / `nova-3` / `scribe_v2_realtime`; `dropSmartCleanup`, `meetingNotes` — `google/gemini-3.8-flash`; `agent` — `anthropic/claude-sonnet-5.5`; сервер — nil.
- `knownUnsupportedReason`: Deepgram `flux-*` → `"needs Deepgram's v2 streaming API"`.

Каталоги:
- **Soniox** — `GET https://api.soniox.com/v1/models`, `Authorization: Bearer <key>`; `models[]`: `transcription_mode` `real_time` → realtimeSTT, `async` → asyncSTT; `aliased_model_id` → `aliasOf`.
- **Deepgram** — `GET https://api.deepgram.com/v1/models` без `Authorization`; `stt[]` склеить по `canonical_name`: `streaming` → realtimeSTT, `batch` → asyncSTT. Для каждого `<arch>-general` добавить модель с id `<arch>` (`nova-3`) и теми же uses.
- **ElevenLabs** — `[]` без запроса (каталога STT нет).
- **OpenRouter** — `GET https://openrouter.ai/api/v1/models` без ключа. Убрать id с `:batch`, id с `~`, модели без `text` в `architecture.output_modalities`, модели с `pricing.prompt == "-1"`, кроме `openrouter/auto`. uses — {chat}, плюс chatWithTools при `tools`. `expiration_date` → `expiresAt`.
- **Сервер** — `GET modelsURL`, `Authorization` только при непустом ключе; `data[].id`; uses nil. `modelsURL`: схема `ws` → `http`, `wss` → `https`; путь, оканчивающийся на `/v1`, → `+/models`; иначе `/v1/models` на том же host:port.
- Не-2xx → `.http(status, code:)` (`code` — `error_type`, `err_code`/`category` или `detail.status`, если есть в теле); `URLError` → `.offline`; не JSON → `.malformed`.

- [ ] **Step 1: Failing tests**
  - `test_registry_recommendations_match_the_spec` — все пары выше.
  - `test_soniox_catalog_maps_modes_and_aliases` — фикстура: `stt-rt-v5` real_time, `stt-rt-v4` real_time с `aliased_model_id: "stt-rt-v5"`, `stt-async-v5` async → uses и `aliasOf`; заголовок `Bearer sx-key`.
  - `test_deepgram_catalog_merges_rows_and_keeps_nova_3` — две строки `nova-3-general` (streaming и batch) и `nova-3-medical` → ids `["nova-3", "nova-3-general", "nova-3-medical"]`; запрос без `Authorization`.
  - `test_openrouter_catalog_drops_batch_aliases_and_routers_but_keeps_auto` — фикстура `google/gemini-3.8-flash`, `google/gemini-3.8-flash:batch`, `~anthropic/claude-sonnet-latest`, `openrouter/fusion` (`"-1"`), `openrouter/auto` (`"-1"`) → `["google/gemini-3.8-flash", "openrouter/auto"]`; у gemini `contextLength == 1_048_576`, `maxOutputTokens == 65_536`, `supportsTools == true`.
  - `test_server_models_url_rules` — `http://h:8000/v1` → `http://h:8000/v1/models`; `wss://h/v1/realtime` → `https://h/v1/models`; `http://h:11434` → `http://h:11434/v1/models`.
  - `test_server_catalog_without_key_sends_no_authorization` (Review Focus 5).
  - `test_elevenlabs_catalog_makes_no_request`.
- [ ] **Step 2:** `swift test --filter "ModelRegistryTests|ModelCatalogFetcherTests"` → FAIL.
- [ ] **Step 3: Реализовать.**
- [ ] **Step 4:** тот же фильтр → PASS.
- [ ] **Step 5: Commit** `feat(ai-routing): add the built-in model registry and provider catalogs`.

### Task 10: Кэш каталогов

**Files:**
- Create: `Sources/Sidekey/AIRouting/ModelCatalogStore.swift`
- Test: `Tests/SidekeyTests/AIRouting/ModelCatalogStoreTests.swift`

**Interfaces:**
- Consumes: Task 9.
- Produces:
```swift
struct CatalogSnapshot: Codable, Equatable {
    var models: [CatalogModel]
    var fetchedAt: Date?            // последняя успешная загрузка
    var lastRefreshFailed: Bool     // → «Couldn't refresh»
    var limited: Bool               // ключ без права на список → только реестр
    var isAuthoritative: Bool { get }   // fetchedAt != nil && !lastRefreshFailed && !limited
}
@MainActor final class ModelCatalogStore: ObservableObject {
    static let shared: ModelCatalogStore
    static var defaultFileURL: URL { get }   // ~/Library/Caches/<BuildConfig.bundleID>/model-catalog-v1.json
    init(fileURL: URL = defaultFileURL, fetcher: any ModelCatalogFetching = ModelCatalogFetcher(),
         now: @escaping () -> Date = Date.init, ttl: TimeInterval = 86_400)
    @Published private(set) var snapshots: [String: CatalogSnapshot]   // ключ — ProviderAccount.storageID
    func snapshot(for account: ProviderAccount) -> CatalogSnapshot?
    func refreshIfStale(_ account: ProviderAccount, apiKey: String?, server: ServerEndpoint?) async
    func refresh(_ account: ProviderAccount, apiKey: String?, server: ServerEndpoint?) async
    func forget(_ account: ProviderAccount)
}
```
Успех → новые модели, `fetchedAt = now`, флаги сброшены. Soniox 403 и Deepgram 401/403 с `INSUFFICIENT_PERMISSIONS` → `limited = true`, модели прежние. `.offline`, 5xx и прочие ошибки → `lastRefreshFailed = true`, модели и `fetchedAt` прежние. Файл пишется атомарно; нечитаемый файл — пустой кэш.

- [ ] **Step 1: Failing tests** (фейковый fetcher, файл во временной папке, управляемые часы)
  - `test_offline_refresh_keeps_models_and_marks_couldnt_refresh` (Review Focus 4).
  - `test_server_error_keeps_the_cache`.
  - `test_fresh_cache_is_not_refetched_within_a_day` — два `refreshIfStale` за 23 ч → одна загрузка; через 25 ч — вторая.
  - `test_cache_survives_relaunch`.
  - `test_soniox_permission_denied_marks_limited`.
  - `test_forget_removes_the_account`.
- [ ] **Step 2:** `swift test --filter ModelCatalogStoreTests` → FAIL.
- [ ] **Step 3: Реализовать.**
- [ ] **Step 4:** → PASS.
- [ ] **Step 5: Commit** `feat(ai-routing): cache provider catalogs with an offline fallback`.

### Task 11: Проверка ключей

**Files:**
- Create: `Sources/Sidekey/AIRouting/ProviderKeyChecker.swift`
- Modify: `Tests/SidekeyTests/LLM/LocalPathLoggingInvariantTests.swift:19-24`
- Test: `Tests/SidekeyTests/AIRouting/ProviderKeyCheckerTests.swift`, `KeyStatusStoreTests.swift`

**Interfaces:**
- Consumes: Tasks 1, 5 (`ProviderBatchTranscriber` для платной пробы ElevenLabs), 9 (`modelsURL`).
- Produces:
```swift
enum KeyRejection: String, Codable { case invalidKey, outOfCredit }
enum KeyStatus: Codable, Equatable { case valid, limited, rejected(KeyRejection), unreachable }
struct KeyCheckRecord: Codable, Equatable { var status: KeyStatus; var checkedAt: Date }
protocol ProviderKeyChecking: Sendable {
    func check(_ account: ProviderAccount, apiKey: String?, server: ServerEndpoint?, allowPaidProbe: Bool) async -> KeyStatus
}
struct ProviderKeyChecker: ProviderKeyChecking { init(session: URLSession = .shared) }
@MainActor final class KeyStatusStore: ObservableObject {
    static let shared: KeyStatusStore
    init(defaults: UserDefaults = .standard)                 // ключ "sidekey.aiRouting.keyStatus.v1"
    func record(for account: ProviderAccount) -> KeyCheckRecord?
    func set(_ status: KeyStatus, for account: ProviderAccount, at date: Date)
    func needsCheck(_ account: ProviderAccount, now: Date) -> Bool     // нет записи или старше 24 ч
    func forget(_ account: ProviderAccount)
}
```
Запросы и разбор (спека: «Проверка ключа», «Факты о провайдерах»):

| Провайдер | Запрос | valid | rejected(invalidKey) | limited | rejected(outOfCredit) |
|---|---|---|---|---|---|
| Soniox | `GET api.soniox.com/v1/models`, Bearer | 2xx | 401 | 403 | 402 |
| Deepgram | `GET api.deepgram.com/v1/projects`, `Token` | 2xx | 401 без `INSUFFICIENT_PERMISSIONS` | 401 с ним, 403 | 402 |
| ElevenLabs | `GET api.elevenlabs.io/v1/user`, `xi-api-key` | 2xx | 401 | 403 (при `allowPaidProbe` — STT-проба, см. ниже) | 402 |
| OpenRouter | `GET openrouter.ai/api/v1/key`, Bearer | 2xx | 401 | — | 402, 403 |
| Сервер | `GET modelsURL`, Bearer, если ключ есть | 2xx, 404 | 401, 403 | — | — |

STT-проба ElevenLabs: 1 с тишины через `ProviderBatchTranscriber(route: { .elevenLabs(apiKey: key, model: "scribe_v2") })`; `httpStatus(401)` → `rejected(.invalidKey)`, иначе `limited`. Нет сети и 5xx → `unreachable` (вызывающий показывает жёлтый и хранит прежний статус). `os_log` — провайдер, статус, мс.

- [ ] **Step 1: Failing tests** — вся таблица через `StubURLProtocol`: URL и заголовок авторизации каждого провайдера, каждый код. Плюс:
  - `test_elevenlabs_scoped_key_is_limited_without_paid_probe` — 403 и `allowPaidProbe: false` → `.limited`, ровно один запрос.
  - `test_elevenlabs_paid_probe_rejects_a_dead_key` — 403, затем 401 на `/v1/speech-to-text` → `.rejected(.invalidKey)`.
  - `test_offline_is_unreachable`.
  - `KeyStatusStoreTests`: `test_needs_check_after_a_day`, `test_records_survive_relaunch`, `test_store_never_contains_the_key` (JSON по ключу defaults не содержит строку ключа).
- [ ] **Step 2:** `swift test --filter "ProviderKeyCheckerTests|KeyStatusStoreTests"` → FAIL.
- [ ] **Step 3: Реализовать**; `Sources/Sidekey/AIRouting/ProviderKeyChecker.swift` — в `guardedFiles`.
- [ ] **Step 4:** тот же фильтр + `LocalPathLoggingInvariantTests` → PASS.
- [ ] **Step 5: Commit** `feat(ai-routing): check provider keys with free requests`.

### Task 12: Пробы моделей

**Files:**
- Create: `Sources/Sidekey/AIRouting/ModelProbe.swift`
- Modify: `Sources/Sidekey/Streaming/BYOK/SonioxBYOKAdapter.swift` (только статический запрос с заголовком; рантайм не трогать — это отдельная задача до 15.01.2027); `LocalPathLoggingInvariantTests.swift:19-24`
- Test: `Tests/SidekeyTests/AIRouting/ModelProbeTests.swift`, `ModelCheckStoreTests.swift`

**Interfaces:**
- Consumes: Tasks 2, 5, 9.
- Produces:
```swift
enum ProbeOutcome: Codable, Equatable { case passed, failed(reason: String), inconclusive(reason: String) }
struct ModelCheckKey: Hashable, Codable { let account: String; let model: String; let use: ModelUse }
struct ModelCheckRecord: Codable, Equatable { let adapterVersion: Int; let outcome: ProbeOutcome; let at: Date }
@MainActor final class ModelCheckStore: ObservableObject {
    static let shared: ModelCheckStore
    init(defaults: UserDefaults = .standard)                 // "sidekey.aiRouting.modelChecks.v1"
    func record(for key: ModelCheckKey) -> ModelCheckRecord?
    func store(_ outcome: ProbeOutcome, for key: ModelCheckKey, adapterVersion: Int, at date: Date)   // inconclusive не хранится
    func recordRefusal(feature: AIFeature, model: String, at date: Date)
    func refusedModel(for feature: AIFeature) -> String?
}
protocol ModelProbing: Sendable { func probe(_ route: ResolvedRoute, use: ModelUse, catalog: CatalogModel?) async -> ProbeOutcome }
struct ModelProbe: ModelProbing {
    init(session: URLSession = .shared,
         makeRealtimeAdapter: @escaping @Sendable (ResolvedRoute) throws -> BYOKTranscriptionAdapter = ModelProbe.headerAuthenticatedAdapter,
         timeout: Duration = .seconds(15))
    static func headerAuthenticatedAdapter(_ route: ResolvedRoute) throws -> BYOKTranscriptionAdapter
    static let silence: Data     // 1 с PCM16 моно 16 кГц, нули: 32 000 байт
}
extension SonioxBYOKAdapter { static func handshakeRequest(apiKey: String) -> URLRequest }   // Authorization: Bearer <key>
```
Проба по `use`:
- **realtimeSTT** — адаптер из `headerAuthenticatedAdapter` (Soniox — `SonioxBYOKAdapter(apiKey:model:transport:)` поверх `handshakeRequest`, ключ в заголовке, как требует спека; остальные — `RealtimeAdapterFactory.make`). `open(language: "en", terms: [])`, `silence` кадрами по 3 200 байт, `endInput()`. `.error(m)` → `failed("Provider refused: <m, до 120 символов>")`; `.done` или конец потока → `passed`; таймаут → у сервера `failed("this server's realtime dialect")`, у остальных `failed("No answer from the provider")`; `URLError` при открытии → `inconclusive("No connection")`.
- **asyncSTT** — `ProviderBatchTranscriber(route: { .soniox(apiKey:model:) }, session:).transcribe(audio: silence, language: "en")`: без ошибки → `passed`; `httpStatus(400|404|422)` → `failed("Provider refused the model (HTTP <n>)")`; прочее → `inconclusive`.
- **chat / chatWithTools** — `POST <base>/chat/completions` с `{"model", "messages":[{"role":"user","content":"Reply with OK."}], "max_tokens":16, "stream":false}`. OpenRouter добавляет `"provider":{"require_parameters":true}` и `"reasoning"` из `catalog?.reasoning?.dictationSetting`. `chatWithTools` добавляет `"tools":[{"type":"function","function":{"name":"exodia_probe","description":"Probe tool. Do not call.","parameters":{"type":"object","properties":{}}}}]`. 2xx с непустым `choices` → `passed`; 400 с `max_tokens` в теле → один повтор с `512`; 400/404/422 → `failed("Provider refused: <message>")`; 401/402 → `inconclusive("Key problem")`; сеть и 5xx → `inconclusive`.
- `os_log` — провайдер, use, исход, мс; без id модели и текста ответа.

- [ ] **Step 1: Failing tests**
  - `test_realtime_probe_sends_one_second_of_silence_only` — фейковый адаптер собирает `sendAudio`: всего 32 000 байт, все нули.
  - `test_realtime_probe_passes_on_done`, `test_realtime_probe_fails_with_the_provider_reason` (`.error("model_not_available")`), `test_server_probe_timeout_reports_the_dialect` (`timeout: .milliseconds(50)`).
  - `test_soniox_probe_handshake_carries_the_key_in_the_header` — `SonioxBYOKAdapter.handshakeRequest(apiKey: "sx")`: `Authorization == "Bearer sx"`, URL `wss://stt-rt.soniox.com/transcribe-websocket`.
  - `test_chat_probe_body` — для OpenRouter `max_tokens == 16` и `provider.require_parameters == true`; у сервера без ключа нет `provider` и нет `Authorization` (Review Focus 5).
  - `test_agent_probe_offers_one_fake_tool` — `tools[0].function.name == "exodia_probe"`.
  - `test_max_tokens_rejection_retries_once_with_512`.
  - `test_offline_probe_is_inconclusive_and_not_stored`.
  - `ModelCheckStoreTests`: `test_adapter_version_is_part_of_the_record`, `test_refusal_is_kept_per_feature`.
- [ ] **Step 2:** `swift test --filter "ModelProbeTests|ModelCheckStoreTests"` → FAIL.
- [ ] **Step 3: Реализовать**; `ModelProbe.swift` — в `guardedFiles`.
- [ ] **Step 4:** тот же фильтр + `LocalPathLoggingInvariantTests` → PASS.
- [ ] **Step 5: Commit** `feat(ai-routing): probe new models with synthetic requests`.

### Task 13: Статусы строк и выпадашка

**Files:**
- Create: `Sources/Sidekey/AIRouting/ModelStatusResolver.swift`
- Modify: `PostProcessor.swift`, `Meetings/MeetingBYOKProcessor.swift` (запись отказа модели)
- Test: `Tests/SidekeyTests/AIRouting/ModelStatusResolverTests.swift`; дописать `PostProcessorOpenRouterTests`, `MeetingBYOKProcessorTests`

**Interfaces:**
- Consumes: Tasks 1–12.
- Produces:
```swift
enum ModelRowStatus: Equatable {
    case ok, notSet, keyProblem, notVerified, removedByProvider
    case deprecatedAlias(of: String)
    case expiring(Date)
    case notSupported(reason: String)
}
enum PickerOptionState: Equatable { case verified, new, notSupported(reason: String) }
struct PickerOption: Equatable { let model: String; let state: PickerOptionState; let isSelected: Bool; let hint: String? }
struct PickerSection: Equatable { let account: ProviderAccount; let title: String; let options: [PickerOption]; let notSupportedSummary: String?; let refreshFailed: Bool }
struct AliasGroupAction: Equatable { let account: ProviderAccount; let from: String; let to: String; let features: [AIFeature] }
@MainActor struct ModelStatusResolver {
    init(routing: AIRoutingStore, keys: ProviderKeyStore, catalogs: ModelCatalogStore, checks: ModelCheckStore,
         keyStatuses: KeyStatusStore, adapterVersion: @escaping (AIProviderKind, ModelUse) -> Int = ModelRegistry.adapterVersion)
    func status(for feature: AIFeature) -> ModelRowStatus
    func sections(for feature: AIFeature) -> [PickerSection]
    func missingProviderHint(for feature: AIFeature) -> String?   // "Add a key for Soniox, Deepgram, ElevenLabs or an OpenAI-compatible server"
    func aliasGroups() -> [AliasGroupAction]
    func verdict(model: String, account: ProviderAccount, for feature: AIFeature) -> PickerOptionState
}
```
Правила:
- **Проверена**: модель в реестре для этого use; или `ModelCheckStore` хранит `passed` с текущей версией адаптера; или маршрут фичи совпадает с `migratedRoute` и `adapterVersion(kind, use) == 1`.
- **verdict**: `knownUnsupportedReason` → notSupported; каталог есть и противоречит use → notSupported с причиной: realtimeSTT без realtimeSTT → `"recorded only"`, asyncSTT без asyncSTT → `"real-time only"`, chatWithTools без tools → `"no tool support"`, контекст меньше `agentMinContext` / `meetingNotesMinContext` → `"context under 64K tokens"`; проба провалена → её причина; проверена → verified; иначе new. Подсказки (`hint`): `"always reasons, slower"` у `dropSmartCleanup` при `reasoning.mandatory == true`; `"with speakers"` у `meetings` для модели реестра с `diarization`.
- **status** — первое подходящее: нет маршрута, у аккаунта нет ключа (кроме сервера) или сервер удалён → notSet; ключ `rejected` → keyProblem; снимок `isAuthoritative` и модели в нём нет → removedByProvider; `aliasOf` → deprecatedAlias; `expiresAt` → expiring; `refusedModel(for:) == route.model` → `notSupported("The provider refused this model")`; проба текущей модели провалена → notSupported; модель не в реестре и проверена только старой версией адаптера (или миграцией при версии > 1) → notVerified; иначе ok.
- **sections**: аккаунты с ключом (серверы всегда), чей вид умеет фичу; порядок Soniox, Deepgram, ElevenLabs, OpenRouter, серверы по имени. Модели — реестр + каталог для этого use, без `aliasOf` (кроме выбранной). Варианты notSupported уходят в `notSupportedSummary`: `"Not supported yet: a, b, c +N (reason)"`, не больше трёх имён на причину. `refreshFailed` — `lastRefreshFailed` снимка.
- **aliasGroups**: фичи с одинаковыми (аккаунт, from, to); группа — от двух фич.
- **Отказ в рантайме**: `PostProcessor` и `MeetingBYOKProcessor` при `OpenRouterLLMError.unexpectedStatus(400|404|422, _)` зовут `ModelCheckStore.shared.recordRefusal(feature:model:at:)` для своей фичи; Drop по-прежнему вставляет сырой текст.

- [ ] **Step 1: Failing tests**

```swift
func test_prod_after_migration_shows_one_switch_for_four_features() {
    // routes: dropFast, dropSmart, agentVoice, voiceSearch = soniox "stt-rt-v4" (миграция); meetings = soniox "stt-async-v5"
    // снимок Soniox (authoritative): stt-rt-v5, stt-rt-v4 aliasOf stt-rt-v5, stt-async-v5
    XCTAssertEqual(resolver.aliasGroups(), [AliasGroupAction(account: .soniox, from: "stt-rt-v4", to: "stt-rt-v5",
                                                             features: [.dropFast, .dropSmart, .agentVoice, .voiceSearch])])
    XCTAssertEqual(resolver.status(for: .dropFast), .deprecatedAlias(of: "stt-rt-v5"))
    XCTAssertEqual(resolver.status(for: .meetings), .ok)
}
```
  - `test_migrated_model_without_problem_signs_has_no_badge` — модель OpenRouter вне реестра, есть в каталоге → `.ok`.
  - `test_adapter_version_bump_marks_unregistered_models_not_verified`.
  - `test_removed_only_when_the_catalog_is_authoritative` — `lastRefreshFailed` или `limited` → `.ok`; свежий снимок без модели → `.removedByProvider` (Review Focus 4).
  - `test_deepgram_nova_3_is_not_removed` — снимок с `nova-3-general` по правилу Задачи 9 → `.ok`.
  - `test_agent_picker_marks_models_without_tools` — summary `"Not supported yet: x/no-tools (no tool support)"`.
  - `test_soniox_meetings_offer_async_models_only` — summary содержит `stt-rt-v5` и `(real-time only)`.
  - `test_picker_lists_only_keyed_providers_that_support_the_feature`.
  - `test_missing_provider_hint_lists_providers_for_the_feature` — `.agent` без OpenRouter → `"Add a key for OpenRouter"`.
  - `test_rejected_key_shows_key_problem`.
  - `test_runtime_refusal_shows_until_the_model_changes`.
  - `PostProcessorOpenRouterTests.test_model_refusal_is_recorded_for_cleanup` — ответ 404 → `refusedModel(for: .dropSmartCleanup) == model`.
- [ ] **Step 2:** `swift test --filter "ModelStatusResolverTests|PostProcessorOpenRouterTests|MeetingBYOKProcessorTests"` → FAIL.
- [ ] **Step 3: Реализовать.**
- [ ] **Step 4:** → PASS.
- [ ] **Step 5: Commit** `feat(ai-routing): derive row statuses and picker sections`.

### Task 14: Лимиты модели для OpenCode; полный прогон части B

**Files:**
- Modify: `Sources/Sidekey/AgentDaemon/AgentRunOptions.swift`; `AgentSettingsStore.swift:64-81`; `OpenCodeEnvironment.swift:7-45`; `OpenCodeProvider.swift:106-107`
- Test: `OpenCodeEnvironmentTests` (создать, если нет), `AgentSettingsStoreTests`, `OpenCodeProviderTests`

**Interfaces:**
- Consumes: Tasks 8, 10.
- Produces:
```swift
struct OpenCodeModelSpec: Equatable, Sendable { let toolCall: Bool; let reasoning: Bool; let contextLimit: Int; let outputLimit: Int }
// AgentRunOptions: + var openCodeModelSpec: OpenCodeModelSpec? (параметр init со значением nil)
// AgentSettingsStore.init: + catalogs: ModelCatalogStore = .shared
static func make(workingDirectory: URL, model: String, key: String?, allowActions: Bool,
                 modelSpec: OpenCodeModelSpec? = nil, inherited: [String: String] = ProcessInfo.processInfo.environment) throws -> [String: String]
```
`options(for: .opencode)` берёт `CatalogModel` выбранной модели из снимка OpenRouter: `toolCall = supportsTools ?? true`, `reasoning = supportsReasoning ?? false`, `contextLimit = contextLength`, `outputLimit = maxOutputTokens ?? 16_384`; без `contextLength` → spec nil. `OpenCodeEnvironment` пишет `"models": [model: ["tool_call": …, "reasoning": …, "limit": ["context": …, "output": …]]]`; без spec — пустой объект, как сейчас.

- [ ] **Step 1: Failing tests**
  - `test_declares_catalog_limits_for_the_model` — в разобранном `OPENCODE_CONFIG_CONTENT`: `provider.openrouter.models["anthropic/claude-sonnet-5.5"].limit.context == 1_000_000`, `.limit.output == 128_000`, `tool_call == true`, `reasoning == true`.
  - `test_without_catalog_declares_the_model_as_before`.
  - `test_agent_options_carry_the_catalog_spec`.
- [ ] **Step 2:** `swift test --filter "OpenCodeEnvironmentTests|AgentSettingsStoreTests|OpenCodeProviderTests"` → FAIL.
- [ ] **Step 3: Реализовать.**
- [ ] **Step 4:** → PASS.
- [ ] **Step 5: Проверка на настоящем OpenCode** (без запроса к модели, ключ фиктивный, XDG-папки во временной папке): JSON конфига из теста →
  `OPENROUTER_API_KEY=dummy XDG_CONFIG_HOME=… XDG_DATA_HOME=… XDG_STATE_HOME=… XDG_CACHE_HOME=… OPENCODE_DISABLE_AUTOUPDATE=true OPENCODE_CONFIG_CONTENT='<json>' opencode models openrouter --verbose`.
  Ожидание: у модели `limit.context` и `limit.output` из конфига. 19.10 так проверено на OpenCode 1.17.12 (`~/.npm-global/bin/opencode`): пустой объект → `"context": 0`, заполненный → значения конфига; `anthropic/claude-sonnet-5.5` в его снимке models.dev нет. Если есть копия, которую ставит Exodia (`OpenCodeBinaryLocator`), повторить на ней и записать версию в отчёт.
- [ ] **Step 6: Полный прогон части B:** `swift build`, `swift test` → 0 failures, N — в отчёт.
- [ ] **Step 7: Commit** `feat(agent): declare OpenCode model limits from the OpenRouter catalog`.

---

## Часть C — вкладка API & Models

### Task 15: Модель вкладки

**Files:**
- Create: `Sources/Sidekey/Settings/APIAndModels/APIAndModelsViewModel.swift`
- Test: `Tests/SidekeyTests/Settings/APIAndModelsViewModelTests.swift`

**Interfaces:**
- Consumes: Tasks 1–13.
- Produces:
```swift
enum KeyDot: Equatable { case green, yellow, red }
struct KeyChip: Equatable, Identifiable { let account: ProviderAccount; let title: String; let dot: KeyDot; let statusText: String; let checkedAt: Date?; var id: String { get } }
struct FeatureRow: Equatable, Identifiable { let feature: AIFeature; let selectionLabel: String; let status: ModelRowStatus; let isChecking: Bool; let message: String?; var id: AIFeature { get } }
struct AssignItem: Equatable, Identifiable { let feature: AIFeature; let account: ProviderAccount; let model: String; var id: AIFeature { get } }
struct AssignProposal: Equatable { let title: String; let items: [AssignItem] }
@MainActor final class APIAndModelsViewModel: ObservableObject {
    init(routing: AIRoutingStore = .shared, keys: ProviderKeyStore = ProviderKeyStore(), catalogs: ModelCatalogStore = .shared,
         checks: ModelCheckStore = .shared, keyStatuses: KeyStatusStore = .shared,
         keyChecker: any ProviderKeyChecking = ProviderKeyChecker(), probe: any ModelProbing = ModelProbe(), now: @escaping () -> Date = Date.init,
         inputLanguage: @escaping () -> String? = { PrivacyPreferences.shared.selectedLanguage?.code })
    @Published private(set) var chips: [KeyChip]
    @Published private(set) var rows: [FeatureRow]
    @Published private(set) var aliasGroups: [AliasGroupAction]
    @Published private(set) var unsetBanner: String?
    @Published var proposal: AssignProposal?
    var addableKinds: [AIProviderKind] { get }               // ещё без ключа; сервер — всегда
    func onAppear() async
    func addKey(_ key: String, kind: AIProviderKind) async -> String?          // nil — сохранён; иначе текст ошибки
    func addServer(name: String, baseURL: String, key: String?) async -> String?
    func replaceKey(_ key: String, for account: ProviderAccount) async -> String?
    func featuresUsing(_ account: ProviderAccount) -> [AIFeature]
    func remove(_ account: ProviderAccount)
    func checkKey(_ account: ProviderAccount) async
    func sections(for feature: AIFeature) -> [PickerSection]
    func missingProviderHint(for feature: AIFeature) -> String?
    func select(model: String, account: ProviderAccount, for feature: AIFeature) async
    func checkNow(_ feature: AIFeature) async
    func refreshModels() async
    func apply(_ group: AliasGroupAction) async
    func proposeSetup(for account: ProviderAccount?)
    func applyProposal(selected: Set<AIFeature>)
}
```
Поведение:
- `chips` — аккаунты с непустым ключом и все серверы. Точка: valid → green; limited, unreachable, нет записи → yellow; rejected → red. `statusText`: `"Key works"`, `"Limited key"`, `"Couldn't check"`, `"Key not accepted"`, `"Out of credit or key limit reached"`; у Soniox и ElevenLabs при invalidKey добавить `" Regional keys aren't supported yet."`.
- `selectionLabel` — `"<Provider> · <model>"` (у сервера — его имя); без маршрута `"Choose a model"`.
- `onAppear` — для каждого аккаунта `catalogs.refreshIfStale` и, если `keyStatuses.needsCheck`, `keyChecker.check(…, allowPaidProbe: false)`.
- `addKey` — сохранить → `check(allowPaidProbe: true)`; `rejected(.invalidKey)` → удалить ключ и вернуть ошибку; иначе записать статус, `catalogs.refresh`, `proposeSetup(for:)`. Ничего не назначает.
- `replaceKey` — как `addKey`, но при `rejected(.invalidKey)` остаётся прежний ключ; окно назначения не открывается.
- `checkKey` (кнопка Check now в поповере) — `check(allowPaidProbe: true)` и запись статуса.
- `checkNow(feature)` — проба текущей модели маршрута, результат — в `ModelCheckStore`; маршрут не меняется.
- `refreshModels()` — `catalogs.refresh` для всех аккаунтов с ключом и всех серверов.
- `applyProposal(selected:)` — назначить отмеченные items без пробы (это модели вшитого реестра).
- `proposeSetup(for: account)` — Not set фичи, которые аккаунт умеет и для которых есть `ModelRegistry.recommended`; заголовок `"Use <Provider> for"`. `for: nil` (кнопка Set up) — для каждой Not set фичи первый аккаунт с ключом в порядке Soniox, Deepgram, ElevenLabs, OpenRouter с рекомендуемой моделью; заголовок `"Set up models"`. Пустое предложение не показывается.
- `remove` — удалить ключ (у сервера — и запись), `routing.clearRoutes(using:)`, `catalogs.forget`, `keyStatuses.forget`. Ничего не переназначает.
- `select` — verified → назначить; new → `isChecking`, проба: passed — записать и назначить; failed — прежний маршрут, `message` = причина; inconclusive — прежний маршрут, `message = "Couldn't check: <reason>"`; notSupported → не назначать, `message` = причина.
- `apply(group)` — `to` проверена → назначить всем фичам группы; иначе сначала проба.
- `unsetBanner` — при хотя бы одном ключе и N > 0 фич в Not set: `"<N> features have no model"` (`"1 feature has no model"`).
- Язык Deepgram (PR #35): у строки, чей маршрут на Deepgram, `message` = `error.localizedDescription`, если `DeepgramLanguagePolicy.configurationError(model: route.model, language: inputLanguage())` не nil. Тексты `DeepgramLanguageConfigurationError.errorDescription` заменить: `.automaticLanguageUnavailable` → `"Auto language isn't available for this Deepgram model. Pick nova-3 or choose an input language."`; `.unsupportedLanguage` → `"This Deepgram model doesn't support the current input language. Pick another model or input language."` Строки пересчитываются на `UserDefaults.didChangeNotification` (язык меняют остров и настройки митингов).

- [ ] **Step 1: Failing tests** (фейковые checker и probe; store-ы на временных defaults и файле)
  - `test_chips_show_keyed_providers_and_servers_only`.
  - `test_add_key_proposes_but_never_assigns` — после `addKey` маршрутов нет; `proposal.title == "Use Soniox for"`; в items только Not set real-time фичи (`stt-rt-v5`) и Meetings (`stt-async-v5`).
  - `test_rejected_key_is_not_saved`.
  - `test_apply_proposal_assigns_only_checked_features`.
  - `test_remove_key_unsets_features_and_reassigns_nothing` (Review Focus 3).
  - `test_new_model_is_assigned_after_a_passed_probe`, `test_failed_probe_keeps_the_previous_model_and_says_why`, `test_offline_probe_keeps_the_previous_model`.
  - `test_switch_group_moves_all_four_features_to_stt_rt_v5`.
  - `test_opening_the_tab_runs_only_free_checks_older_than_a_day` — фейковый checker видит `allowPaidProbe == false` и только устаревшие аккаунты.
  - `test_banner_counts_unset_features_only_when_a_key_exists`.
  - `test_deepgram_row_warns_when_the_input_language_does_not_fit` — `.agentVoice` на Deepgram `nova-3`, `inputLanguage` = `"cy"` → `message` = новый текст `.unsupportedLanguage`; `"ru"` → `message == nil`; маршрут не меняется.
- [ ] **Step 2:** `swift test --filter "APIAndModelsViewModelTests|DeepgramLanguagePolicyTests"` → FAIL.
- [ ] **Step 3: Реализовать.**
- [ ] **Step 4:** → PASS.
- [ ] **Step 5: Commit** `feat(settings): add the API & Models view model`.

### Task 16: Вид вкладки, выпадашка и окна

**Files:**
- Create: `Sources/Sidekey/Settings/APIAndModels/APIAndModelsView.swift`, `ModelMenu.swift`, `KeyChipPopover.swift`, `AddKeySheet.swift`, `AssignModelsSheet.swift`
- Test: `Tests/SidekeyTests/Settings/APIAndModelsViewTests.swift` (текст исходников)

**Interfaces:**
- Consumes: Task 15.
- Produces: `struct APIAndModelsView: View { init(viewModel: APIAndModelsViewModel, focusedFeature: Binding<AIFeature?>) }`.

Раскладка — по макету спеки:
- `MacGroupTitle(title: "API keys")`; ряд чипов с переносом (свой `Layout`): `ProviderBrandIcon` + имя + точка; последний чип `+ Add key`. Клик по чипу → `KeyChipPopover`: `statusText`, `"Checked <относительное время>"`, `Replace key` (`SecureField`, очищается после сохранения), `Check now`, `Remove` с подтверждением `"<фичи> will have no model."` или `"No features use this key."`.
- `MacGroupTitle(title: "Models")`; над карточкой — `MacBanner` `"Switch <n> features to <to>"` на каждую группу и `"<unsetBanner> · Set up"`.
- `MacCard` со строкой на фичу: название, рядом мелко `mode.label` (`MacSettingsTheme.text2`), справа `ModelMenu`. Статус — только при проблеме: строка под названием с `exclamationmark.triangle`: `Not verified · Check now`, `Alias of <to>` и кнопка `Switch to <to>`, `Removed by provider · Choose model`, `Expires <дата>`, `Not supported yet: <reason>`, `Key problem`, `Not set`; `message` строки — тем же стилем. Во время проверки — `ProgressView().controlSize(.small)`.
- `ModelMenu` (SwiftUI `Menu`, одна на строку): секции `sections(for:)` — заголовок провайдера (с `· Couldn't refresh`, если `refreshFailed`), модели (у выбранной галочка, у new — `"New · checked when picked"`, `hint` серым), серая строка `notSupportedSummary`; внизу `Refresh models` и `Other model ID…` (окно: поле ID и выбор аккаунта, если их несколько → `select`). Без секций — пункт `missingProviderHint`, он открывает `AddKeySheet`.
- `AddKeySheet` — выбор из `addableKinds`, `SecureField` ключа; для сервера `Name`, `Base URL` (placeholder `http://localhost:8000/v1`), `API key (optional)`; `Save` → прогресс → ошибка под полем или закрытие.
- `AssignModelsSheet` — заголовок `proposal.title`; на каждый item `MacSwitch` (включён), название фичи и модель; кнопки `Not now` и `Use`.
- `focusedFeature` — `ScrollViewReader` прокручивает к строке и подсвечивает её 1 с, затем сбрасывает binding.
- Значение ключа в UI не читается никогда.

- [ ] **Step 1: Failing tests** — исходники содержат `MacCard`, `MacRow`, `MacGroupTitle`, `MacBanner`, `ProviderBrandIcon`, `SecureField`, `"API keys"`, `"Models"`, `"Add key"`, `"Replace key"`, `"Remove"`, `"Check now"`, `"Refresh models"`, `"Other model ID…"`, `"checked when picked"`, `"Use"`, `"Not now"`, `"Set up"`; не содержат `keys.read(` и обычного `TextField` для ключа; в `APIAndModelsView.swift` ровно одно использование `ModelMenu(` (второй выпадашки провайдера нет).
- [ ] **Step 2:** `swift test --filter APIAndModelsViewTests` → FAIL.
- [ ] **Step 3: Реализовать.**
- [ ] **Step 4:** → PASS; `swift build` → OK.
- [ ] **Step 5: Commit** `feat(settings): build the API & Models tab views`.

### Task 17: Вкладка вместо Models и переход на строку

**Files:**
- Modify: `Sources/Sidekey/Settings/SettingsWindowTab.swift`; `SettingsWindowView.swift` (выбор и показ вкладки); `SettingsWindowController.swift` (модель вкладки, `show`, `loadIfNeeded`); `AppDelegate.swift` (`openSettingsWindow` и все его вызовы с `.models`); `Sources/Sidekey/DropOutputPolicy.swift` (`failureMessage`)
- Delete: `Sources/Sidekey/Settings/SettingsModelsView.swift`, `SettingsModelsViewModel.swift`; `Tests/SidekeyTests/Settings/SettingsModelsViewModelTests.swift`, `SettingsModelsViewTests.swift`, `SettingsWindowTabModelsTests.swift`
- Test: `SettingsWindowTabTests`, `SettingsWindowControllerTests`, `SettingsWindowViewTests`

**Interfaces:**
- Consumes: Tasks 15–16.
- Produces:
```swift
// SettingsWindowTab: case apiAndModels — первый и defaultAvailable; title "API & Models"; fallbackSystemImageName "cpu"
// SettingsWindowSelection
@Published var focusedFeature: AIFeature?
init(selectedTab: SettingsWindowTab = .apiAndModels)
func focus(_ feature: AIFeature)          // select(.apiAndModels) + focusedFeature = feature
// SettingsWindowController
func show(tab: SettingsWindowTab = .apiAndModels, feature: AIFeature? = nil)
// AppDelegate
private func openSettingsWindow(tab: SettingsWindowTab = .apiAndModels, feature: AIFeature? = nil)
```
Контроллер держит `APIAndModelsViewModel` вместо `SettingsModelsViewModel`; `loadIfNeeded(.apiAndModels)` → `await viewModel.onAppear()`. `.byokMisconfigured(error)` → `openSettingsWindow(tab: .apiAndModels, feature: error.feature)` (в том числе `invalidLanguageConfiguration`). PR #35: `DropOutputPolicy.failureMessage` для ошибок настройки → `"Set up Smart in API & Models"`; в `runPostProcessAndPaste` при `requiresConfiguration` → `openSettingsWindow(tab: .apiAndModels, feature: .dropSmartCleanup)`. `SettingsWindowView` сохраняет `AppBuildIdentity` — заголовок окна, блок сборки в сайдбаре и пункт Quit.

- [ ] **Step 1: Failing tests**
  - `test_api_and_models_is_the_first_and_default_tab` — `allCases.first == .apiAndModels`, `defaultAvailable == .apiAndModels`, `SettingsWindowSelection().selectedTab == .apiAndModels`.
  - `test_api_and_models_tab_metadata` — `title == "API & Models"`, `id == "apiAndModels"`, иконка `"cpu"`.
  - `test_show_with_feature_focuses_that_row` — `show(tab: .apiAndModels, feature: .dropSmart)` → `selection.focusedFeature == .dropSmart`.
  - `test_no_models_tab_left` — ни один `title` не равен `"Models"`.
  - `DropOutputPolicyTests`: ожидаемый текст ошибки настройки — `"Set up Smart in API & Models"`.
  - `SettingsWindowViewTests`: исходник по-прежнему содержит `AppBuildIdentity.current.settingsTitle` и `buildIdentity`.
- [ ] **Step 2:** `swift test --filter "SettingsWindowTabTests|SettingsWindowControllerTests|SettingsWindowViewTests|DropOutputPolicyTests"` → FAIL.
- [ ] **Step 3: Реализовать**; удалить старые файлы.
- [ ] **Step 4:** → PASS; `swift build` → OK.
- [ ] **Step 5: Commit** `feat(settings): replace the Models tab with API & Models`.

### Task 18: Вкладка Agents и тексты

**Files:**
- Modify: `Sources/Sidekey/Settings/AgentModeView.swift:11-16, 49, 71-75, 96-153`; `AgentDaemon/AgentSettingsStore.swift` (убрать `openCodeModel`, каталог OpenRouter, `refreshOpenRouterCatalog`); `AgentDaemon/OpenCodeProvider.swift:89-96`; `AgentDaemon/OpenCodeEventMapper.swift:46`; `Agent/AgentController.swift:1030`; `Settings/SettingsWindowController.swift:181, 192`; `Settings/SettingsWindowView.swift` (передать колбэк); `Streaming/BYOK/OpenRouterLLMClient.swift:67`
- Test: `AgentModeViewTests`, `AgentModeViewModelTests`, `AgentSettingsStoreTests`, `OpenCodeProviderTests`, тесты `OpenCodeEventMapper` и `AgentController`, где сверяются строки

**Interfaces:**
- Consumes: Tasks 8, 17.
- Produces: `AgentModeView.init(…, openAPIAndModels: @escaping (AIFeature) -> Void)`; `SettingsWindowView` передаёт `{ selection.focus($0) }`.

Agents: убрать поле ключа, Model ID, Find a model, Choose model, Refresh и подпись «shared with Models». Вместо них `MacCard` с `MacRow(title: "Model", subtitle: "OpenRouter · <id>")` и `MacButton(title: "Change in API & Models")` → `openAPIAndModels(.agent)`; без модели — subtitle `"Choose a model in API & Models"`. `connect()` ключ не сохраняет; без модели — `message = "Choose a model in API & Models."`. Остальное без изменений.

| Где | Новый текст |
|---|---|
| `OpenCodeProvider` missing_key | `Add your OpenRouter key in Settings → API & Models.` |
| `OpenCodeProvider` missing_model (оба) | `Choose a model in API & Models.` |
| `OpenCodeEventMapper` auth | `Check your OpenRouter key in Settings → API & Models.` |
| `AgentController.showNotConnected` | `Connect OpenCode in Settings → Agents. Its model is set in API & Models.` |
| `SettingsWindowController.installHint(.opencode)` | `Install OpenCode in Settings → Agents, then press Connect.` |
| `SettingsWindowController.loginHint(.opencode)` | `Add your OpenRouter key in Settings → API & Models, then press Connect.` |
| `OpenRouterLLMError.notConfigured` | `No LLM is chosen in Settings > API & Models.` |

Комментарии `Settings -> Models` в коде заменить на `Settings -> API & Models`.

- [ ] **Step 1: Failing tests** — `AgentModeViewTests`: есть `"Change in API & Models"`, `"Choose a model in API & Models"`, `"Use Agent shortcuts"`, `"Allow agent actions"`, `"Save & connect"`, `OpenCodeInstaller`; нет `"Find a model"`, `"Choose model"`, `"shared with Models"`, `SecureField`, `OpenRouterLLMKeyStore().save`. Строки — по таблице.
- [ ] **Step 2:** `swift test --filter "AgentModeView|AgentSettingsStoreTests|OpenCodeProviderTests|OpenCodeEventMapper|AgentController"` → FAIL.
- [ ] **Step 3: Реализовать.** Перед удалением `openCodeModel` и каталога — `grep -rn` по `Sources` и `Tests`: других пользователей быть не должно.
- [ ] **Step 4:** → PASS.
- [ ] **Step 5: Commit** `feat(settings): move the agent key and model to API & Models`.

### Task 19: Документация, решение, финальный прогон

**Files:**
- Modify: `.project-docs/agent-context.md` (маршруты Drop, cleanup, митингов и агента; «Settings -> Models»), затем `python3 scripts/customize.py sync-guidance --write` (обновит `CLAUDE.md`); `docs/privacy.md` (провайдер на фичу, бесплатные проверки ключей, пробы только на синтетике при выборе модели и по Check now, публичные каталоги); `docs/SPEC.md` (настройки); `README.md` (настройка ключей); `docs/specs/api-and-models.md` (статус «реализовано», ссылка на план)
- Create: `.project-docs/decisions/2026-10-19-api-and-models.md` — Контекст, Решение, Почему, Что протестировали (в том числе OpenCode 1.17.12 и каталог Deepgram), Отвергли (две выпадашки в строке, автоназначение после ключа, тихая замена `stt-rt-v4`, общий сервер на миграции), дата и ссылка на PR. Раздел «Supersedes»: «Settings -> Models» в решениях `2026-10-19-strict-drop-modes` и `2026-10-19-deepgram-language-policy` теперь означает API & Models; меню языка ввода из настроек моделей убрано (язык — в острове и настройках митингов, у строки Deepgram — предупреждение). Сами старые решения не переписываются.
- Modify: якоря `// WHY: .project-docs/decisions/2026-10-19-api-and-models.md` у `AIRoutingStore`, `AIRoutingMigration`, `DropTake`, `ModelStatusResolver`, `ModelProbe`, `OpenCodeEnvironment.make`

- [ ] **Step 1:** правки документации; `python3 scripts/customize.py sync-guidance --write`; `git diff --stat` — только перечисленные файлы и `CLAUDE.md`.
- [ ] **Step 2:** `rg -n "Settings (->|→|>) Models" Sources docs README.md .project-docs CLAUDE.md --glob '!.project-docs/decisions/**'` → пусто (записи решений — история, их не правим).
- [ ] **Step 3: Финальный прогон:** `swift build`, `swift test` → 0 failures; N и время — в отчёт.
- [ ] **Step 4: Commit** `docs: document API & Models and record the decision`.
- [ ] **Step 5: Отчёт Максиму:** «готово, ещё не в рабочем приложении»; цифры тестов; что чем проверено; «Решения исполнителя». Push, PR (с `[docs: …]` и шагами приёмки ниже) и интеграция — после «пушим».

## Приёмка на рабочем приложении (в PR; выполняет интеграция)

1. Settings открывается на **API & Models**; в API keys — чипы провайдеров, чьи ключи уже были.
2. Models: Drop Fast, Drop Smart, Agent voice и Voice search — `Soniox · stt-rt-v4` с пометкой псевдонима и одна кнопка «Switch 4 features to stt-rt-v5»; Meetings — `Soniox · stt-async-v5`; Drop Smart cleanup и Meeting notes — прежняя модель OpenRouter; Agent — прежняя модель агента.
3. Drop Fast и Drop Smart вставляют текст; у Fast нет LLM-чистки, у Smart есть.
4. «Switch» переводит четыре строки на `stt-rt-v5`; Drop работает.
5. Agents: строка «Model: OpenRouter · <id>»; «Change in API & Models» открывает вкладку на строке Agent; агент отвечает.
6. Митинг записывается и получает заметки.
7. Без сети вкладка открывается, каталог помечен «Couldn't refresh», Drop работает.
