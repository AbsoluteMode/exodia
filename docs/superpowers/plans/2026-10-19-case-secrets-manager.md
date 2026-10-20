# Case Secrets Manager Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn Case into a project-based local secrets manager whose keys registered AI apps can use through a `whytap` CLI and MCP server without ever receiving values.

**Architecture:** Vault schema v2 (projects, descriptions, app registrations) with lossless v1 migration, owned by one `CaseVaultService` shared by the island UI and a Unix-socket broker in the app. A separate `whytap` executable (CLI + stdio MCP) talks to the broker; the broker verifies the peer is the bundled `whytap`, identifies the calling app by walking the parent-process chain, applies Approve/Bypass policy (island prompt with Y/N/A keys), and returns values only to `whytap case run`, which injects them into a child's environment and masks them in its output.

**Tech Stack:** Swift 6 toolchain in Swift 5 mode, SwiftPM, SwiftUI/AppKit, CryptoKit, Security.framework (SecCode), LocalAuthentication, POSIX sockets, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-19-case-secrets-manager-design.md` — read it with this plan; labels **[Максим]** there are not negotiable.

## Global Constraints

- Before starting and before any integration: read `.project-docs/processes/shared-app-development.md` and `git show origin/main:AGENTS.md`. Feature work never runs `scripts/dev-run.sh`, `swift run`, `customize.py build/run` or opens a bundle; verify with `swift build` and `swift test --filter …` only.
- Product name is **Whytap**; module/executable names stay `Sidekey`; preserve bundle IDs (`com.rootwise.sidekey`, `.beta`), Keychain services, Application Support paths, vault AAD `com.rootwise.sidekey.case-vault.v1`.
- CLI names: prod `whytap` (symlink `${HOME}/.local/bin/whytap` → `/Applications/Whytap.app/Contents/Helpers/whytap`), beta `whytap-beta`, dev `whytap-dev`. Never `case` (shell keyword).
- Values never appear in: argv, MCP traffic, client config files, `os_log`, files written by Whytap other than the encrypted vault, error messages, test fixtures with real secrets. `LocalPathLoggingInvariantTests` and `CloudRemovalTests` must stay green.
- Values reach commands only as environment variables of the child spawned by `whytap`, never by the app process (no Whytap TCC inheritance).
- Names: `A–Z 0–9 _`, no leading digit, max normalized 64 (existing). Project name ≤ 48 chars. Value ≤ 16 KB. Idle lock 15 min (existing).
- Timed approval default N = 15 minutes, user-editable, in-memory only.
- Approval keys by physical keycode: Y `kVK_ANSI_Y` = allow, N `kVK_ANSI_N` = deny, A `kVK_ANSI_A` = allow for N minutes, Escape = deny; intercepted only while a prompt is visible; 300 ms arming delay; 60 s timeout = deny.
- No new network endpoints; no telemetry; GitHub Actions stay disabled.
- Out of scope (spec non-goals): environments UI, usage journal, key requests from AI, Copy all, chat-only assistants, HTTP placeholder tool, renaming Settings → Projects tab.

## Review Focus

1. A v1 vault with a group named `General` (any case) or keys whose names start with a digit — migration must keep every key and value (owner: Task 1).
2. A backup archive written by v1 restored into a v2 vault, and v2 archive into v2 — no key lost, `projectID`s valid (owner: Task 1).
3. A secret value shorter than the mask minimum (4 bytes) or one that appears split across two output reads — masked when ≥ 4, chunk boundary never leaks (owner: Task 6).
4. Same key name in two projects requested without `-p` — command not run, exit code 3, project list with descriptions on stderr, no prompt (owner: Task 7).
5. User typing in another app while an Approve prompt appears — no key within the first 300 ms is consumed; non-Y/N/A/Esc keys always pass through (owner: Task 10).

---

### Task 0: Bring the branch up to date

- [ ] **Step 1:** If the app still refuses `sync_with_base_branch` because `origin` moved to `AbsoluteMode/whytap`, ask Maxim to re-pin (Help → Troubleshooting → Review Pinned Git Origins); then sync. Expected: branch contains `origin/main` (Whytap rename, backup feature).
- [ ] **Step 2:** `swift build 2>&1 | tail -c 2000` and `swift test --filter Case 2>&1 | tail -c 2000`. Expected: build OK, Case tests pass.

### Task 1: Vault schema v2 and migration

**Files:**
- Modify: `Sources/Sidekey/Case/CaseModels.swift`
- Create: `Sources/Sidekey/Case/CaseVaultMigration.swift`
- Modify: `Sources/Sidekey/Case/CaseVaultStore.swift` (`decode`, `load`)
- Modify: `Sources/Sidekey/Backup/ArtifactBackupRestore.swift` (`ArtifactCaseMerge.merge`, `applyCase`), `ArtifactBackupStaging.swift:302-320`, `ArtifactBackupVerify.swift:157`
- Modify: `Sources/Sidekey/Case/CaseNameNormalizer.swift`
- Test: `Tests/SidekeyTests/Case/CaseVaultMigrationTests.swift`, `Tests/SidekeyTests/Case/CaseVaultStoreTests.swift`, `Tests/SidekeyTests/Backup/ArtifactBackupEngineTests.swift`, `Tests/SidekeyTests/Case/CaseNameNormalizerTests.swift`

**Interfaces — Produces:**
```swift
struct CaseProject: Identifiable, Codable, Equatable { var id: UUID; var name: String; var description: String; var createdAt: Date; var updatedAt: Date
  static let generalID = UUID(uuidString: "00000000-0000-0000-0000-00000000CA5E")!
  static func general(now: Date) -> CaseProject }          // name "General"
struct CaseSecret { var id; var name; var projectID: UUID; var description: String; var copyCount; var lastCopiedAt; var createdAt; var updatedAt }
enum CaseAccessMode: String, Codable { case approve, bypass }
enum CaseAppIdentity: Codable, Equatable, Hashable {
  case developerID(teamID: String, signingIdentifier: String)
  case executablePath(String)
  case builtInOpenCode }
struct CaseAppRegistration: Identifiable, Codable, Equatable { var id: UUID; var displayName: String; var identity: CaseAppIdentity
  var defaultMode: CaseAccessMode; var projectModes: [UUID: CaseAccessMode]; var createdAt: Date }
struct CaseVaultPayload: Codable, Equatable { static let currentSchemaVersion = 2
  var schemaVersion: Int; var projects: [CaseProject]; var secrets: [CaseSecret]; var values: [CaseSecretValue]
  var apps: [CaseAppRegistration]; var timedApprovalMinutes: Int   // default 15
  func value(for: UUID) -> String?; func project(_ id: UUID) -> CaseProject? }
enum CaseVaultMigration { static func decodePayload(_ plaintext: Data) throws -> CaseVaultPayload }   // v1 or v2 JSON → v2
extension CaseNameNormalizer { static func repairedLegacyName(_ name: String) -> String }           // "1PASSWORD" → "_1PASSWORD"
```
`CaseGroup` stays only as a private legacy decoding type inside `CaseVaultMigration.swift`.

- [ ] **Step 1: Write failing tests** in `CaseVaultMigrationTests`:
  - `test_v1_ungrouped_secrets_move_to_general` — v1 JSON with 2 ungrouped secrets → both `projectID == CaseProject.generalID`, values intact, `projects.first?.id == generalID`.
  - `test_v1_groups_become_projects_with_same_name` — group "servers" with 2 keys → project "servers", both secrets in it.
  - `test_v1_group_named_general_merges_into_builtin_general` — group "general" → no second General; its keys in General.
  - `test_v1_leading_digit_names_are_repaired_not_dropped` — "1PASSWORD" → "_1PASSWORD", value intact; if "_1PASSWORD" already exists in that project → "_1PASSWORD_2".
  - `test_v2_round_trips_unchanged` and `test_schema_3_throws_needsNewerApp` (via `CaseVaultStore.decode`).
  - `CaseNameNormalizerTests.test_leading_digit_is_rejected_for_new_names` — `normalizedName("2fa key")` throws `.invalid…` (existing error case or new `leadingDigit`).
- [ ] **Step 2:** `swift test --filter CaseVaultMigrationTests` → FAIL (types missing).
- [ ] **Step 3:** Implement models and `CaseVaultMigration.decodePayload`: read `schemaVersion` first (`{"schemaVersion":Int}` probe); 1 → decode legacy, build General + one project per group (dedupe names case-insensitively against General), assign `projectID`, repair names, `description = ""`, `apps = []`, `timedApprovalMinutes = 15`; 2 → decode; >2 → `CaseVaultStoreError.needsNewerApp`. Missing `description`/`apps`/`timedApprovalMinutes` keys decode to defaults. `CaseVaultStore.decode` and `load` call it; `save` always writes v2 (existing `.bak` keeps the v1 bytes).
- [ ] **Step 4:** Update backup: `ArtifactCaseMerge.merge(source:into:)` merges `projects` (by id, newer `updatedAt` wins, General always present), `secrets`, `values`, `apps` (by id) and keeps target `timedApprovalMinutes`; drop group reconciliation. Staging/verify accept schema ≤ 2 through `CaseVaultStore.decode`. Add `ArtifactBackupEngineTests.test_v1_case_archive_restores_into_v2_vault` (v1 archive + v2 target → union, all secrets have existing `projectID`).
- [ ] **Step 5:** `swift test --filter "Case|Backup" 2>&1 | tail -c 3000` → PASS (update existing Case/Backup tests that construct `groupID`/`CaseGroup` to the v2 shapes).
- [ ] **Step 6:** Commit `feat(case): vault schema v2 with projects and lossless v1 migration`.

### Task 2: Shared vault service and project operations

**Files:**
- Create: `Sources/Sidekey/Case/CaseVaultService.swift`
- Modify: `Sources/Sidekey/Case/CaseViewModel.swift`, `Sources/Sidekey/Case/CaseRanker.swift`
- Modify: `Sources/Sidekey/DynamicIsland/IslandView.swift:242`, `Sources/Sidekey/Settings/ToolboxSettingsView.swift:35` (use the shared instance)
- Test: `Tests/SidekeyTests/Case/CaseVaultServiceTests.swift`, `CaseViewModelTests.swift`, `CaseRankerTests.swift`

**Interfaces — Consumes:** Task 1 models. **Produces:**
```swift
@MainActor final class CaseVaultService: ObservableObject {
  static let shared: CaseVaultService
  init(store: CaseVaultStoring, keyProvider: CaseVaultKeyProviding)
  @Published private(set) var payload: CaseVaultPayload?          // nil until first load
  func loadIfNeeded() throws -> CaseVaultPayload                    // no Touch ID; broker + UI
  func mutate(_ change: (inout CaseVaultPayload) throws -> Void) throws   // validate, save, publish
}
// CaseViewModel(service: CaseVaultService = .shared, authenticator:, pasteboard:, now:, unlockedSessionSeconds:, scheduleIdleLock:)
enum CaseInputMode { case name, value(name: String, projectID: UUID) }
struct CaseDisplayRow { enum Kind { case project, secret }; let id: UUID; let kind: Kind; let displayName: String; let description: String; let projectID: UUID }
// new CaseViewModel API (replaces createGroup/addSecretToGroup/removeSecretFromGroup/copyAll):
func submitName(_ raw: String, projectID: UUID = CaseProject.generalID) throws
func createProject(name: String, description: String) throws -> UUID
func renameProject(_ id: UUID, name: String) throws          // General → .invalidProjectOperation
func setProjectDescription(_ id: UUID, _ text: String) throws
func deleteProject(_ id: UUID) throws                         // deletes its secrets+values; General refused
func moveSecret(_ secretID: UUID, toProject: UUID) throws     // name clash → .duplicateName
func setSecretDescription(_ secretID: UUID, _ text: String) throws
func secretRows(inProject: UUID) -> [CaseDisplayRow]
var expandedProjectIDs: Set<UUID>                              // General expanded by default
```
Errors: replace `missingGroup/invalidGroupName/invalidGroupOperation` with `missingProject/invalidProjectName/invalidProjectOperation`. Description max 200 chars (builder call per spec; reject longer with `.descriptionTooLong`).

- [ ] **Step 1: Failing tests:** `test_names_unique_per_project_not_global` (same name in General and servers OK, twice in servers → `.duplicateName`); `test_delete_project_removes_its_secrets_and_values`; `test_general_cannot_be_deleted_or_renamed`; `test_move_secret_with_name_clash_is_refused`; `test_two_view_models_share_one_service_without_clobbering` (VM A adds key, VM B adds key, reload → both present); `test_service_loads_without_touch_id` (fake authenticator never called by `loadIfNeeded`); ranker `test_query_matches_names_and_descriptions_across_projects`.
- [ ] **Step 2:** Run `swift test --filter "CaseVaultServiceTests|CaseViewModelTests|CaseRankerTests"` → FAIL.
- [ ] **Step 3:** Implement. `CaseViewModel.unlock()` keeps Touch ID as the UI gate, then reads `service.loadIfNeeded()`; `lock()` only hides UI state (service keeps payload for the broker). `copySecret` unchanged behaviour.
- [ ] **Step 4:** Tests PASS; `swift build` OK.
- [ ] **Step 5:** Commit `feat(case): shared vault service and project operations`.

### Task 3: Island Case panel — variant C

**Files:**
- Modify: `Sources/Sidekey/DynamicIsland/IslandCaseVaultPanel.swift` (rewrite list section; remove group prompt/Copy all)
- Create: `Sources/Sidekey/DynamicIsland/IslandCaseProjectRow.swift`, `IslandCaseSecretRow.swift`
- Test: `Tests/SidekeyTests/Case/IslandCaseVaultPanelLayoutTests.swift` (offscreen render, no visible windows — same approach as existing hover renders)

**Interfaces — Consumes:** Task 2 API.

Layout (spec + mockup `case-layout-v2`): top bar = field «Имя ключа или поиск» + «+ Проект»; one list of collapsible project sections, General first then by name; project header: chevron, name, key count, pencil (rename + description), trash (not on General) with confirm text «Удалить проект <name> и N ключей?»; secret row: monospace name, optional description line, icon buttons pencil / copy / trash; «+ Ключ в <project>» row at the end of each expanded section; drag a secret onto a project header → `moveSecret`; bottom row «ИИ: <registered names>» + «Подключить ›» opening the access screen (Task 11; until then the button is hidden behind `isAccessScreenAvailable = false`).

- [ ] **Step 1: Failing tests:** `test_general_section_first_and_expanded`, `test_no_copy_all_control`, `test_general_header_has_no_delete`, `test_secret_row_has_edit_copy_delete_in_that_order` (inspect accessibility identifiers `case.secret.edit/copy/delete`), `test_renders_at_310pt_without_horizontal_overflow`.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit `feat(case): project list UI in the island`.

### Task 4: Shared package target with protocol and masker skeleton

**Files:**
- Modify: `Package.swift` — add `.target(name: "WhytapCaseKit", path: "Sources/WhytapCaseKit")` (no dependencies), make `Sidekey` depend on it, add `.executableTarget(name: "WhytapCLI", dependencies: ["WhytapCaseKit"], path: "Sources/WhytapCLI")` and `.executable(name: "whytap", targets: ["WhytapCLI"])`, test target `WhytapCaseKitTests`.
- Create: `Sources/WhytapCaseKit/CaseBrokerProtocol.swift`, `Sources/WhytapCLI/main.swift` (prints usage)
- Test: `Tests/WhytapCaseKitTests/CaseBrokerProtocolTests.swift`

**Produces (newline-delimited JSON over the socket, one request per connection):**
```swift
public enum CaseBrokerRequest: Codable, Equatable {
  case listProjects
  case listKeys(project: String?)
  case resolveRun(project: String?, only: [String]?, command: String, cwd: String) }
public struct CaseProjectInfo: Codable, Equatable { public let name: String; public let description: String; public let keyCount: Int }
public struct CaseKeyInfo: Codable, Equatable { public let name: String; public let description: String; public let project: String }
public enum CaseBrokerResponse: Codable, Equatable {
  case projects([CaseProjectInfo])
  case keys([CaseKeyInfo])
  case runEnvironment([String: String])            // only for resolveRun
  case ambiguous(key: String, projects: [CaseProjectInfo])
  case denied(reason: CaseDenyReason) }
public enum CaseDenyReason: String, Codable { case notRegistered, unknownAIApp, userDeclined, timedOut, touchIDFailed, unknownProject, unknownKey, untrustedHelper, vaultUnavailable }
public enum CaseBrokerPaths { public static func socketURL(bundleID: String) -> URL }   // ${HOME}/Library/Application Support/<bundleID>/case-broker.sock
```
- [ ] **Step 1:** Test `test_requests_and_responses_round_trip_as_single_json_lines` (encode → no `\n` inside → decode equal) and `test_socket_path_is_under_bundle_application_support_and_shorter_than_104_bytes` (sun_path limit; for long home dirs fall back to `${HOME}/Library/Application Support/<bundleID>/cb.sock`).
- [ ] **Step 2–4:** fail → implement → `swift build --product whytap` and `swift test --filter WhytapCaseKitTests` pass.
- [ ] **Step 5:** Commit `build: add WhytapCaseKit and whytap CLI targets`.

### Task 5: Access policy (pure)

**Files:** Create `Sources/Sidekey/Case/CaseAccessPolicy.swift`; Test `Tests/SidekeyTests/Case/CaseAccessPolicyTests.swift`

**Produces:**
```swift
enum CaseCaller: Equatable { case registered(CaseAppRegistration), knownUnregisteredAI(name: String), human }
enum CaseAccessDecision: Equatable { case allow, askApproval, askTouchID, deny(CaseDenyReason) }
struct CaseTimedGrants { mutating func grant(appID: UUID, projectID: UUID, until: Date); func isGranted(appID: UUID, projectID: UUID, now: Date) -> Bool }
enum CaseAccessPolicy {
  static func decideList(caller: CaseCaller) -> CaseAccessDecision            // registered → allow; human → askTouchID; unknown AI → deny(.unknownAIApp)
  static func decideRun(caller: CaseCaller, projectID: UUID, grants: CaseTimedGrants, now: Date) -> CaseAccessDecision }
```
Rules: project override else `defaultMode`; bypass → allow; approve → allow if timed grant active else askApproval; human → askTouchID.

- [ ] Steps: tests `test_project_override_beats_default`, `test_timed_grant_expires_after_minutes`, `test_unknown_ai_is_denied_not_asked`, `test_listing_never_asks_approval_for_registered_app`, `test_human_needs_touch_id` → fail → implement → pass → commit `feat(case): access policy`.

### Task 6: Output masker

**Files:** Create `Sources/WhytapCaseKit/CaseOutputMasker.swift`; Test `Tests/WhytapCaseKitTests/CaseOutputMaskerTests.swift`

**Produces:**
```swift
public final class CaseOutputMasker {
  public static let minimumMaskedLength = 4
  public static let placeholder = "[case:hidden]"
  public init(secrets: [String])                  // builds variant set
  public func feed(_ chunk: Data) -> Data         // returns safe-to-emit prefix, retains tail
  public func finish() -> Data }
```
Variants per value (≥ 4 bytes): raw; base64 std and url-safe at byte offsets 0,1,2 (stable inner substring, like GitHub `Base64StringEscapeShift1/2`); hex lower/upper; percent-encoding (`urlQueryAllowed` inverse); JSON string escape; each line of a multi-line value (lines ≥ 4). Retained tail = longest variant length − 1.

- [ ] Steps: tests `test_masks_raw_value`, `test_masks_base64_all_offsets`, `test_masks_hex_and_json_and_percent`, `test_value_split_across_feeds_is_masked`, `test_multiline_value_masked_per_line`, `test_values_shorter_than_4_are_not_masked`, `test_output_without_secrets_is_byte_identical` → fail → implement → pass → commit `feat(case): output masker`.

### Task 7: `whytap case` CLI (ls, run)

**Files:** Create `Sources/WhytapCLI/CaseCommand.swift`, `Sources/WhytapCLI/BrokerClient.swift`, `Sources/WhytapCLI/MaskedProcessRunner.swift`; Test `Tests/WhytapCaseKitTests/MaskedProcessRunnerTests.swift` (move runner core into `WhytapCaseKit` as `public struct MaskedProcessRunner` so it is testable).

**Produces:**
```
whytap case ls [-p <project>]                       → table: NAME  project  description   (exit 0)
whytap case run [-p <project>] [--only A,B] '<cmd>' → /bin/sh -c <cmd>, env = inherited + values; exit = child's
public struct MaskedProcessRunner { public static func run(command: String, environment: [String: String], cwd: URL, masker: CaseOutputMasker) throws -> Int32 }
```
Exit codes: 2 denied (stderr: reason in plain English + hint «Register this app in Whytap → Case → Подключить»), 3 ambiguous (stderr lists `project — description` lines and «Re-run with -p <project>; if unsure, ask the user which project»), 4 broker unavailable. If socket missing: `open -g -b <bundleID>` then poll socket for 5 s. Bundle ID baked per flavor via `-DBETA` / dev define matching `BuildConfig`.

- [ ] Steps: tests `test_child_sees_value_in_env_not_argv` (child prints `$X | rev` length only), `test_stdout_and_stderr_masked`, `test_exit_code_passthrough`, `test_ambiguous_response_exits_3_without_running` (fake broker) → fail → implement → pass → commit `feat(case): whytap case ls/run`.

### Task 8: Caller and helper identification

**Files:** Create `Sources/Sidekey/Case/Broker/CaseProcessInspector.swift`, `CaseCallerResolver.swift`; Test `Tests/SidekeyTests/Case/CaseCallerResolverTests.swift`

**Produces:**
```swift
struct CaseProcessInfo: Equatable { let pid: pid_t; let parentPID: pid_t; let executablePath: String; let teamID: String?; let signingIdentifier: String? }
// CaseProcessInspecting reads process metadata and the socket peer audit identity.
// isTrustedHelper pins the peer cdhash to the bundled helper; see the source protocol.
struct CaseCallerResolver { init(inspector: CaseProcessInspecting, registrations: [CaseAppRegistration], builtInOpenCodePIDs: Set<pid_t>)
  func resolve(peerPID: pid_t) -> CaseCaller }      // walks parents up to 32 hops / pid 1
static let knownAIApps: [(name: String, teamID: String, identifier: String)] =
  [("Claude Code", "Q6L2SF6YDW", "com.anthropic.claude-code"), ("Codex", "2DC432GLL2", "codex")]
```
Cursor and other apps: match `.executablePath` prefix (bundle path); builder verifies Cursor's signing identity on a machine that has it before adding it to `knownAIApps`.

- [ ] Steps: tests with a fake inspector: `test_claude_code_ancestor_matches_developer_id_registration`, `test_unregistered_known_ai_is_reported`, `test_terminal_only_chain_is_human`, `test_path_registration_matches_ancestor`, `test_builtin_opencode_pid_matches` → fail → implement (real inspector: `proc_pidinfo(PROC_PIDTBSDINFO)`, `proc_pidpath`, `SecCodeCopyGuestWithAttributes` + `kSecCodeInfoTeamIdentifier`/`kSecCodeInfoIdentifier`/`kSecCodeInfoUnique`, `getsockopt(LOCAL_PEERTOKEN)`) → pass → commit `feat(case): identify calling app and helper`.

### Task 9: Broker server in the app

**Files:** Create `Sources/Sidekey/Case/Broker/CaseBrokerServer.swift`, `CaseBroker.swift`; Modify `Sources/Sidekey/AppDelegate.swift` (start/stop with app); Test `Tests/SidekeyTests/Case/CaseBrokerTests.swift`

**Interfaces — Consumes:** Tasks 2, 4, 5, 8. **Produces:**
```swift
@MainActor protocol CaseApprovalPresenting { func requestApproval(_ r: CaseApprovalRequest) async -> CaseApprovalOutcome }   // Task 10
struct CaseApprovalRequest: Equatable { let appName: String; let projectName: String; let keyNames: [String]; let command: String; let timedMinutes: Int }
enum CaseApprovalOutcome { case allow, allowTimed, deny, timedOut }
@MainActor final class CaseBroker { init(service: CaseVaultService, resolver: …, approvals: CaseApprovalPresenting, authenticator: CaseAuthenticating, now: () -> Date)
  func handle(_ request: CaseBrokerRequest, peerPID: pid_t) async -> CaseBrokerResponse }
final class CaseBrokerServer { init(socketURL: URL, broker: CaseBroker, inspector: CaseProcessInspecting, helperURL: URL); func start() throws; func stop() }
```
Rules: untrusted helper → `.denied(.untrustedHelper)` before reading the request body; key resolution without `-p` searches all projects → one hit ok, several → `.ambiguous`, none → `.denied(.unknownKey)`; `only == nil` with `-p` → all keys of that project; `only == nil` without `-p` → `.denied(.unknownProject)`; socket dir 0700, socket file 0600, stale socket unlinked on start. Touch ID reason text: «Терминал хочет использовать ключи проекта <name>».

- [ ] Steps: tests with fakes: `test_bypass_returns_environment_without_prompt`, `test_approve_prompts_and_timed_grant_skips_next_prompt`, `test_ambiguous_name_without_project`, `test_untrusted_helper_rejected`, `test_listing_contains_no_values` (encode response, assert no value substring), `test_socket_permissions_0600_and_dir_0700` (real server on temp path) → fail → implement → pass → commit `feat(case): broker server`.

### Task 10: Approval prompt with Y/N/A keys

**Files:** Create `Sources/Sidekey/Case/Approval/CaseApprovalController.swift`, `CaseApprovalView.swift`, `CaseApprovalKeyTap.swift`; Modify `IslandView.swift` (host the prompt like `IslandUpdateAvailablePill`), `AppState.swift` (`caseApprovalActive` for idle-hide blockers), `HelpWindowController.swift` (row), `docs/hotkey.md`; Test `Tests/SidekeyTests/Case/CaseApprovalControllerTests.swift`

**Produces:** `@MainActor final class CaseApprovalController: ObservableObject, CaseApprovalPresenting` with `@Published var current: CaseApprovalRequest?`, FIFO queue, `func resolve(_ outcome: CaseApprovalOutcome)`, injectable clock and `keyTap: CaseApprovalKeyIntercepting` (`start(onKey: (CaseApprovalKey) -> Void) throws; stop()`, `enum CaseApprovalKey { yes, no, timed, escape }`). Tap follows `SpaceHoldMonitor` (active `CGEventTap`, keycode match, swallow only the four keys, never log keys), started when a prompt shows and stopped when the queue empties.

View: one compact card in island width — line 1 «<App> хочет запустить команду», line 2 «<project>: KEY_A, KEY_B», line 3 monospace command truncated with «…»; buttons «Отклонить» (N), «На <N> мин» (A), «Разрешить» (Y) via `HotkeyHintView`.

- [ ] Steps: tests `test_keys_ignored_during_first_300ms`, `test_y_allows_n_denies_a_timed_escape_denies`, `test_timeout_after_60s_denies`, `test_queue_shows_one_at_a_time`, `test_tap_stopped_when_queue_empty` → fail → implement → pass → commit `feat(case): approval prompt with Y/N/A keys`.

### Task 11: App access screen and client registration

**Files:** Create `Sources/Sidekey/DynamicIsland/IslandCaseAccessPanel.swift`, `Sources/Sidekey/Case/Clients/CaseClientConnector.swift` (+ `ClaudeCodeCaseConnector`, `CodexCaseConnector`, `CursorCaseConnector`), `Sources/Sidekey/Case/Clients/CaseCLIInstaller.swift`; Modify `OpenCodeEnvironment.swift` (`mcp` entry + permission when the built-in agent is registered), `CaseViewModel.swift` (registration API), `IslandCaseVaultPanel.swift` (enable «Подключить ›»); Test `Tests/SidekeyTests/Case/CaseClientConnectorTests.swift`, `CaseRegistrationTests.swift`

**Produces:**
```swift
protocol CaseClientConnector { var displayName: String { get }; func isInstalled() -> Bool; func install(helperPath: String) throws; func uninstall() throws }
// Claude: `claude mcp add -s user case -- <helper> case mcp` / `claude mcp remove -s user case`; if ${HOME}/.claude/settings.json has sandbox enabled, add socket path to sandbox.network.allowUnixSockets
// Codex: `codex mcp add case -- <helper> case mcp` / `codex mcp remove case`; sandbox config untouched
// Cursor: edit ${HOME}/.cursor/mcp.json mcpServers.case = {command, args}; preserve other keys
enum CaseCLIInstaller { static func install(flavorName: String, helperURL: URL, binDir: URL) throws }   // whytap / whytap-beta / whytap-dev symlink; never overwrite a non-symlink
// CaseViewModel: registerApp(_ identity:, name:) async throws (Touch ID), setMode(_:for:project:) async throws (Touch ID only when target == .bypass), unregisterApp(_:), setTimedApprovalMinutes(_:) (1...240)
```
Screen (mockup `case-ai-connect-v2`): rows per registration with Approve/Bypass segmented control, per-project overrides «как у приложения / Approve / Bypass», «+ Зарегистрировать приложение» listing detected Claude Code/Codex/Cursor/OpenCode plus «Выбрать программу…» (NSOpenPanel), field «Разрешение на N мин» with N; hint under Bypass for editors with shared terminals.

- [ ] Steps: tests `test_claude_connector_runs_mcp_add_with_helper_path_and_no_secrets` (fake process runner captures argv; assert no env/values), `test_cursor_connector_preserves_other_servers`, `test_bypass_requires_touch_id_approve_does_not`, `test_unregister_removes_client_config_and_access`, `test_cli_installer_refuses_to_replace_regular_file`, `test_opencode_config_contains_case_mcp_only_when_registered` → fail → implement → pass → commit `feat(case): app registration and client connectors`.

### Task 12: MCP server mode

**Files:** Create `Sources/WhytapCaseKit/CaseMCPServer.swift`; Modify `Sources/WhytapCLI/CaseCommand.swift` (`whytap case mcp`); Test `Tests/WhytapCaseKitTests/CaseMCPServerTests.swift`

**Produces:** stdio JSON-RPC 2.0 (newline-delimited), protocol version echo of client's, `initialize` result with `instructions` (exact text below), tools `case_list_projects` (no args) and `case_list_keys` (`project`: string, optional); results are text content with `NAME — description` lines; no tool returns values; never wraps stdio in the masker.

Instructions text (exact):
```
Whytap Case keeps secrets on this Mac. You can see project and key names, never values.
To use keys, run in your terminal: whytap case run -p <project> '<command using $KEY_NAME>'
Use single quotes so your shell does not expand $KEY_NAME; Case injects values and hides them in output.
Without -p, pass --only KEY_NAME; if several projects have it, Case lists them: pick by description, or ask the user.
```
- [ ] Steps: tests `test_initialize_returns_instructions`, `test_tools_list_has_two_tools`, `test_list_keys_output_has_no_values` (fake broker with value "sk-secret-123" → absent), `test_unknown_method_returns_jsonrpc_error` → fail → implement → pass → commit `feat(case): MCP server`.

### Task 13: Packaging, docs, final verification

**Files:** Modify `scripts/dev-run.sh` (build `--product whytap` with same defines; copy to `Contents/Helpers/whytap`; codesign before the app signature at ~L385), `scripts/build-dmg.sh` (build both arches, lipo, copy, sign before ~L824), `CLAUDE.md`, `docs/privacy.md`, `docs/customization/local-data.md`, `docs/hotkey.md`, `docs/SPEC.md`; Create `docs/decisions/2026-10-19-case-secrets-broker.md` with `// WHY:` anchors in `CaseBroker.swift`, `CaseCallerResolver.swift`, `MaskedProcessRunner.swift`.

- [ ] **Step 1:** `bash -n scripts/dev-run.sh scripts/build-dmg.sh` OK; `swift build --product whytap` and `swift build` OK (do not run the scripts in a feature session).
- [ ] **Step 2:** Full `swift test > "$SCRATCH/test.log" 2>&1; tail -c 3000 "$SCRATCH/test.log"` → 0 failures; record counts in the PR.
- [ ] **Step 3:** `grep -rn "os_log\|Logger" Sources/Sidekey/Case Sources/WhytapCaseKit Sources/WhytapCLI | head -40` — confirm no value/command text is logged.
- [ ] **Step 4:** Commit `docs(case): secrets broker decision, privacy and hotkeys`; open PR marked `[docs: CLAUDE.md, docs/privacy.md, docs/hotkey.md, docs/decisions/2026-10-19-case-secrets-broker.md]`. Integration/installation follows the shared workflow (not this session).
