# Local data and source-change boundaries

Use the stores and migrations in the app. Do not turn a customization task into a
new account system, hosted service or second copy of the user's knowledge.

| Data | Canonical code | Storage contract |
| --- | --- | --- |
| Provider keys | `Auth/KeychainStore.swift`, `Auth/CredentialMigration.swift` | macOS Keychain, service selected by `BuildConfig.keychainService` |
| Preferences and vocabulary | `Settings/UserPreferencesCache.swift`, `Settings/VocabularyCache.swift` | UserDefaults; preserve existing keys |
| Hover selection | `Settings/HoverLayoutStore.swift` | UserDefaults key `sidekey.b2b.hover.layout`; its historical name is not a cloud dependency |
| Clipboard, Drop and agent history | `History/HistoryStore.swift`, `History/SQLiteHistoryStore.swift` | `Application Support/<bundle ID>/history.sqlite`, with local image sidecars |
| Meeting notes and checkpoints | `Meetings/MeetingsStore.swift`, `Meetings/MeetingFinalizeManifest.swift` | `Application Support/Sidekey/Meetings/`; staged audio and durable processing state |
| Case snippets | `Case/CaseVaultStore.swift` | AES-GCM encrypted file under `Application Support/<bundle ID>/`, Keychain encryption key, backup before save |
| Agent memory and sessions | `AgentDaemon/AgentDaemonWorkingDirectory.swift`, `AgentDaemon/AgentSessionStore.swift` | `Application Support/whytap/agent/` with AGENTS.md, sessions.json and isolated OpenCode runtime data |

Paths in the code column start at `Sources/Sidekey/`. Application Support is the
current macOS user's directory. Whytap retains the historical `Sidekey`, `whytap`
and `Whytap` store names to preserve existing keys, notes and memory. Do not
rename them without an explicit migration and recovery path.

The app's agent uses OpenCode and the user's chosen OpenRouter model. Actions are
enabled by default so implementation and review can edit files and run tests;
the user may disable them in Settings. Per-project memory and session separation
is not a filesystem sandbox. Source customization can use any coding harness.

Tests should inject temporary directories, UserDefaults suites, fake credentials
and provider adapters. They must not need the user's API keys, SSH connections,
notes or agent memory. A review may build and run tests: read-only filesystem
permissions are not a default requirement for a review.

Keep API keys out of arguments, source, snapshots and logs. Do not read Keychain
items just to discover whether the app can build. Logging may record timings,
counts and stable non-sensitive identifiers, never transcripts, prompts, model
responses or private paths. A local store does not make a configured model API
offline: the selected provider still receives the material sent to it.

Run the affected store checks and the privacy guards when changing persistence or
network routes:

```bash
python3 scripts/customize.py test --filter 'CloudRemovalTests|LocalPathLoggingInvariantTests|KeychainStoreTests'
```

Use `docs/privacy.md` for user-facing privacy behavior and `docs/build-and-release.md`
for distribution. The customization helpers do not publish code, release binaries,
reset permissions, remove stores or install over the production application.
