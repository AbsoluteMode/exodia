import Combine
import CryptoKit
import XCTest
@testable import Sidekey

@MainActor
final class CaseViewModelTests: XCTestCase {
    func test_explicitly_opened_menus_survive_pointer_exit() {
        for mode in IslandHoverPanelMode.allCases {
            let held = IslandView.menuStaysOpen(mode, glance: false)
            XCTAssertEqual(held, mode != .controls)
            XCTAssertEqual(IslandView.mouseHoldsDrawer(pillHovering: false, panelHovering: false,
                wasExpanded: true, glance: false, interactionHeld: held), held)
        }
        XCTAssertFalse(IslandView.menuStaysOpen(.brightness, glance: true), "Hardware brightness feedback still expires")
        XCTAssertFalse(IslandView.mouseHoldsDrawer(pillHovering: false, panelHovering: true,
            wasExpanded: false, glance: false), "A dismissed drawer cannot reopen from a stale hover band")
    }

    func test_system_authentication_suspends_dismissal_through_success_or_cancel() async throws {
        for denied in [false, true] {
            let env = TestCaseEnvironment(payload: CaseVaultPayload())
            let vm = env.makeViewModel()
            env.authenticator.duringAuthentication = {
                XCTAssertTrue(vm.isSystemInteractionActive)
                await Task.yield()
            }
            if denied { env.authenticator.error = CaseAuthenticationError.denied }
            do { try await vm.unlock() } catch { XCTAssertTrue(denied) }
            XCTAssertFalse(vm.isSystemInteractionActive)
        }
    }

    func test_unlock_loads_payload_and_exposes_rows_without_values() async throws {
        let secretID = UUID()
        let payload = CaseVaultPayload(
            secrets: [secret(id: secretID, name: "OPENAI_API_KEY")],
            values: [CaseSecretValue(secretID: secretID, value: "sk-secret-value")]
        )
        let env = TestCaseEnvironment(payload: payload)
        let vm = env.makeViewModel()

        try await vm.unlock()

        XCTAssertEqual(vm.unlockState, .unlocked)
        XCTAssertEqual(vm.rows.map(\.displayName), ["OPENAI_API_KEY"])
        XCTAssertFalse(String(describing: vm.rows).contains("sk-secret-value"))
    }

    func test_create_key_moves_from_name_to_hidden_value_mode_and_saves() async throws {
        let env = TestCaseEnvironment(payload: CaseVaultPayload())
        let vm = env.makeViewModel()
        try await vm.unlock()

        try vm.submitName("open ai api key")
        XCTAssertEqual(vm.inputMode, .value(name: "OPEN_AI_API_KEY", projectID: CaseProject.generalID))

        try vm.submitValue("sk-secret-value")

        XCTAssertEqual(env.savedPayload?.secrets.map(\.name), ["OPEN_AI_API_KEY"])
        XCTAssertEqual(env.savedPayload?.values.map(\.value), ["sk-secret-value"])
        XCTAssertEqual(vm.inputMode, .name)
    }

    func test_short_values_are_flagged_as_not_masked_without_exposing_them() async throws {
        let env = TestCaseEnvironment(payload: CaseVaultPayload())
        let vm = env.makeViewModel()
        try await vm.unlock()
        try vm.submitName("pin")
        try vm.submitValue("abc")                 // 3 bytes: below the masking minimum
        try vm.submitName("port")
        try vm.submitValue("8080")                // 4 bytes: masked
        try vm.submitName("emoji")
        try vm.submitValue("é€")                  // 2 characters, 5 bytes: masked

        let rows = vm.secretRows(inProject: CaseProject.generalID)
        let flags = Dictionary(uniqueKeysWithValues: rows.map { ($0.displayName, $0.valueNotMasked) })
        XCTAssertEqual(flags, ["PIN": true, "PORT": false, "EMOJI": false])
        let sectionFlags = vm.projectSections.first?.secrets.map(\.valueNotMasked)
        XCTAssertEqual(sectionFlags?.filter { $0 }.count, 1)

        vm.query = "pin"
        XCTAssertEqual(vm.rows.first { $0.displayName == "PIN" }?.valueNotMasked, true, "search results too")
        XCTAssertFalse(String(describing: vm.rows).contains("abc"), "only a Bool reaches the row")
        XCTAssertEqual(IslandCaseSecretRow.notMaskedHint, "Not masked in output")
    }

    func test_copy_writes_value_to_injected_pasteboard_and_updates_usage() async throws {
        let secretID = UUID()
        let env = TestCaseEnvironment(payload: CaseVaultPayload(
            secrets: [secret(id: secretID, name: "OPENAI_API_KEY")],
            values: [CaseSecretValue(secretID: secretID, value: "sk-secret-value")]
        ))
        let vm = env.makeViewModel()
        try await vm.unlock()

        try vm.copySecret(secretID)

        XCTAssertEqual(env.pasteboard.lastString, "sk-secret-value")
        XCTAssertEqual(env.savedPayload?.secrets.first?.copyCount, 1)
        XCTAssertNotNil(env.savedPayload?.secrets.first?.lastCopiedAt)
    }

    func test_edit_replaces_value_without_revealing_old_value() async throws {
        let secretID = UUID()
        let env = TestCaseEnvironment(payload: CaseVaultPayload(
            secrets: [secret(id: secretID, name: "OLD_NAME")],
            values: [CaseSecretValue(secretID: secretID, value: "old-secret")]
        ))
        let vm = env.makeViewModel()
        try await vm.unlock()

        try vm.replaceSecret(secretID, rawName: "new name", newValue: "new-secret")

        XCTAssertEqual(env.savedPayload?.secrets.first?.name, "NEW_NAME")
        XCTAssertEqual(env.savedPayload?.values.first?.value, "new-secret")
        XCTAssertFalse(String(describing: vm.rows).contains("old-secret"))
    }

    func test_rename_preserves_hidden_value_without_revealing_it() async throws {
        let secretID = UUID()
        let env = TestCaseEnvironment(payload: CaseVaultPayload(
            secrets: [secret(id: secretID, name: "OLD_NAME")],
            values: [CaseSecretValue(secretID: secretID, value: "old-secret")]
        ))
        let vm = env.makeViewModel()
        try await vm.unlock()

        try vm.renameSecret(secretID, rawName: "new name")

        XCTAssertEqual(env.savedPayload?.secrets.first?.name, "NEW_NAME")
        XCTAssertEqual(env.savedPayload?.values.first?.value, "old-secret")
        XCTAssertFalse(String(describing: vm.rows).contains("old-secret"))
    }

    func test_idle_timeout_locks_and_drops_rows() async throws {
        let env = TestCaseEnvironment(payload: CaseVaultPayload(
            secrets: [secret(name: "OPENAI_API_KEY")],
            values: []
        ))
        let vm = env.makeViewModel()
        try await vm.unlock()

        vm.expireUnlockedSessionForTesting()

        XCTAssertEqual(vm.unlockState, .locked)
        XCTAssertTrue(vm.rows.isEmpty)
    }

    func test_unlock_schedules_fifteen_minute_idle_lock() async throws {
        let env = TestCaseEnvironment(payload: CaseVaultPayload())
        let vm = env.makeViewModel()

        try await vm.unlock()

        XCTAssertEqual(vm.unlockedSessionSecondsForTesting, 15 * 60)
        XCTAssertTrue(vm.hasScheduledIdleLockForTesting)
    }

    func test_stale_idle_lock_does_not_lock_after_session_refresh() async throws {
        let secretID = UUID()
        let scheduler = CapturingIdleLockScheduler()
        let env = TestCaseEnvironment(payload: CaseVaultPayload(
            secrets: [secret(id: secretID, name: "OPENAI_API_KEY")],
            values: [CaseSecretValue(secretID: secretID, value: "sk-secret-value")]
        ))
        let vm = env.makeViewModel(scheduleIdleLock: scheduler.schedule)
        try await vm.unlock()
        let staleLock = try XCTUnwrap(scheduler.scheduled.first?.action)

        try vm.copySecret(secretID)
        XCTAssertEqual(scheduler.scheduled.count, 2)

        staleLock()

        XCTAssertEqual(vm.unlockState, .unlocked)
        XCTAssertEqual(vm.rows.map(\.displayName), ["OPENAI_API_KEY"])
    }

    func test_unlock_failure_publishes_sanitized_message() async {
        let env = TestCaseEnvironment(
            payload: CaseVaultPayload(),
            loadError: ScaryCaseVaultError(message: "storage blew up with sk-secret-value")
        )
        let vm = env.makeViewModel()

        await XCTAssertAsyncThrows(try await vm.unlock()) { error in
            XCTAssertFalse(String(describing: error).contains("sk-secret-value"))
        }

        XCTAssertEqual(vm.unlockState, .failed("Couldn’t open Case"))
        XCTAssertFalse(String(describing: vm.unlockState).contains("sk-secret-value"))
    }

    func test_unlock_failure_after_unlocked_session_clears_stale_state() async throws {
        let secretID = UUID()
        let env = TestCaseEnvironment(payload: CaseVaultPayload(
            secrets: [secret(id: secretID, name: "OPENAI_API_KEY")],
            values: [CaseSecretValue(secretID: secretID, value: "sk-stale-value")]
        ))
        let vm = env.makeViewModel()
        try await vm.unlock()
        try vm.submitName("new key")

        // The shared service keeps its payload, so a re-unlock fails at the
        // Touch ID gate, not at the disk read.
        env.authenticator.error = ScaryCaseVaultError(message: "auth blew up with sk-stale-value")

        await XCTAssertAsyncThrows(try await vm.unlock())

        XCTAssertEqual(vm.unlockState, .failed("Couldn’t open Case"))
        XCTAssertTrue(vm.rows.isEmpty)
        XCTAssertEqual(vm.inputMode, .name)
        XCTAssertFalse(String(describing: vm.rows).contains("sk-stale-value"))
        XCTAssertFalse(String(describing: vm.unlockState).contains("sk-stale-value"))
    }

    func test_unlock_key_provider_failure_publishes_and_throws_sanitized_error() async {
        let env = TestCaseEnvironment(
            payload: CaseVaultPayload(),
            keyError: ScaryCaseVaultError(message: "keychain leaked sk-secret-value")
        )
        let vm = env.makeViewModel()

        await XCTAssertAsyncThrows(try await vm.unlock()) { error in
            XCTAssertFalse(String(describing: error).contains("sk-secret-value"))
        }

        XCTAssertEqual(vm.unlockState, .failed("Couldn’t open Case"))
        XCTAssertFalse(String(describing: vm.unlockState).contains("sk-secret-value"))
    }

    func test_unlock_missing_file_save_failure_publishes_and_throws_sanitized_error() async {
        let env = TestCaseEnvironment(
            payload: CaseVaultPayload(),
            loadError: CaseVaultStoreError.missingFile,
            saveError: ScaryCaseVaultError(message: "save leaked sk-secret-value")
        )
        let vm = env.makeViewModel()

        await XCTAssertAsyncThrows(try await vm.unlock()) { error in
            XCTAssertFalse(String(describing: error).contains("sk-secret-value"))
        }

        XCTAssertEqual(vm.unlockState, .failed("Couldn’t open Case"))
        XCTAssertFalse(String(describing: vm.unlockState).contains("sk-secret-value"))
    }

    func test_unlock_undecryptable_vault_enters_needs_reset() async {
        let env = TestCaseEnvironment(
            payload: CaseVaultPayload(),
            loadError: CryptoKitError.authenticationFailure
        )
        let vm = env.makeViewModel()

        await XCTAssertAsyncThrows(try await vm.unlock())

        XCTAssertEqual(vm.unlockState, .needsReset("Couldn’t open this Case. Reset creates a new one and keeps the old file."))
        XCTAssertTrue(vm.rows.isEmpty)
    }

    func test_unlock_invalid_envelope_enters_needs_reset() async {
        let env = TestCaseEnvironment(
            payload: CaseVaultPayload(),
            loadError: CaseVaultStoreError.invalidEnvelope
        )
        let vm = env.makeViewModel()

        await XCTAssertAsyncThrows(try await vm.unlock())

        XCTAssertEqual(vm.unlockState, .needsReset("Couldn’t open this Case. Reset creates a new one and keeps the old file."))
    }

    func test_unlock_newer_schema_vault_enters_needs_newer_app_not_needs_reset() async {
        // A vault written by a future build has schemaVersion > current. The
        // vault decrypted fine — the user just needs to update the app. This
        // must NOT be classified as undecryptable and must NOT offer Reset.
        let env = TestCaseEnvironment(
            payload: CaseVaultPayload(),
            loadError: CaseVaultStoreError.needsNewerApp
        )
        let vm = env.makeViewModel()

        await XCTAssertAsyncThrows(try await vm.unlock())

        XCTAssertEqual(vm.unlockState, .needsNewerApp("Update Whytap to open this Case."))
    }

    func test_newer_schema_vault_does_not_classify_as_undecryptable() async {
        // isUndecryptableVault must return false for needsNewerApp so the
        // "Reset to start over" path is never reached.
        let env = TestCaseEnvironment(
            payload: CaseVaultPayload(),
            loadError: CaseVaultStoreError.needsNewerApp
        )
        let vm = env.makeViewModel()

        await XCTAssertAsyncThrows(try await vm.unlock())

        // Crucially, must not be .needsReset — that would offer destructive Reset.
        if case .needsReset = vm.unlockState {
            XCTFail("needsNewerApp vault must not surface as needsReset")
        }
    }

    func test_reset_requires_confirm_step_first_call_arms_then_second_executes() async throws {
        // The confirm step lives on the view model: first resetVault() arms the
        // confirmation, second actually deletes. This prevents accidental reset
        // from a single misclick.
        let env = TestCaseEnvironment(
            payload: CaseVaultPayload(),
            loadError: CryptoKitError.authenticationFailure
        )
        let vm = env.makeViewModel()
        await XCTAssertAsyncThrows(try await vm.unlock())

        // First call must arm, NOT delete.
        let armed = vm.armResetVault()
        XCTAssertTrue(armed, "First call must return true (armed), not execute reset")
        XCTAssertEqual(env.store.resetCallCount, 0, "First call must not delete the vault")

        // Second call while armed executes the reset.
        try vm.resetVault()
        XCTAssertEqual(env.store.resetCallCount, 1, "Second call must delete the vault")
    }

    func test_arm_reset_publishes_change_so_confirm_ui_can_render() async throws {
        // The panel's "Confirm reset" label and warning copy key off
        // isResetArmed. Arming must emit objectWillChange or SwiftUI never
        // re-renders and the confirm step is invisible to the user.
        let env = TestCaseEnvironment(
            payload: CaseVaultPayload(),
            loadError: CryptoKitError.authenticationFailure
        )
        let vm = env.makeViewModel()
        await XCTAssertAsyncThrows(try await vm.unlock())

        var changeCount = 0
        let cancellable = vm.objectWillChange.sink { changeCount += 1 }
        defer { cancellable.cancel() }

        vm.armResetVault()

        XCTAssertEqual(changeCount, 1)
        XCTAssertTrue(vm.isResetArmed)
    }

    func test_reset_arm_expires_so_misclick_recovery_requires_re_arm() async throws {
        // Arming must auto-disarm: if the user navigates away and back,
        // the confirm state should not persist indefinitely.
        let env = TestCaseEnvironment(
            payload: CaseVaultPayload(),
            loadError: CryptoKitError.authenticationFailure
        )
        let vm = env.makeViewModel()
        await XCTAssertAsyncThrows(try await vm.unlock())

        _ = vm.armResetVault()
        // Simulate disarm (e.g. panel closed/reopened)
        vm.disarmResetVault()
        // resetVault without prior arm must not delete
        XCTAssertThrowsError(try vm.resetVault()) { error in
            XCTAssertEqual(error as? CaseViewModelError, .resetNotArmed)
        }
        XCTAssertEqual(env.store.resetCallCount, 0)
    }

    func test_unlock_generic_storage_error_stays_failed_not_needs_reset() async {
        let env = TestCaseEnvironment(
            payload: CaseVaultPayload(),
            loadError: ScaryCaseVaultError(message: "io blew up")
        )
        let vm = env.makeViewModel()

        await XCTAssertAsyncThrows(try await vm.unlock())

        XCTAssertEqual(vm.unlockState, .failed("Couldn’t open Case"))
    }

    func test_reset_vault_discards_file_and_allows_fresh_unlock() async throws {
        let env = TestCaseEnvironment(
            payload: CaseVaultPayload(),
            loadError: CryptoKitError.authenticationFailure
        )
        let vm = env.makeViewModel()
        await XCTAssertAsyncThrows(try await vm.unlock())
        XCTAssertEqual(vm.unlockState, .needsReset("Couldn’t open this Case. Reset creates a new one and keeps the old file."))

        vm.armResetVault()
        try vm.resetVault()
        XCTAssertEqual(env.store.resetCallCount, 1)
        XCTAssertEqual(vm.unlockState, .locked)

        // Stub reset() flips load to missingFile -> a fresh empty vault unlocks.
        try await vm.unlock()
        XCTAssertEqual(vm.unlockState, .unlocked)
        XCTAssertTrue(vm.rows.isEmpty)
    }

    func test_unlock_authenticates_before_reading_key() async throws {
        let env = TestCaseEnvironment(payload: CaseVaultPayload())
        let vm = env.makeViewModel()

        try await vm.unlock()

        XCTAssertEqual(env.authenticator.authenticateCallCount, 1)
        XCTAssertEqual(env.keys.readCallCount, 1)
    }

    func test_unlock_authentication_failure_does_not_read_key() async {
        let env = TestCaseEnvironment(
            payload: CaseVaultPayload(),
            authError: CaseAuthenticationError.denied
        )
        let vm = env.makeViewModel()

        await XCTAssertAsyncThrows(try await vm.unlock())

        XCTAssertEqual(env.authenticator.authenticateCallCount, 1)
        XCTAssertEqual(env.keys.readCallCount, 0)
        XCTAssertEqual(vm.unlockState, .failed("Couldn’t open Case"))
    }

    func test_query_change_refreshes_idle_lock() async throws {
        let scheduler = CapturingIdleLockScheduler()
        let env = TestCaseEnvironment(payload: CaseVaultPayload(
            secrets: [secret(name: "OPENAI_API_KEY")],
            values: []
        ))
        let vm = env.makeViewModel(scheduleIdleLock: scheduler.schedule)
        try await vm.unlock()

        vm.query = "open"

        XCTAssertEqual(scheduler.scheduled.count, 2)
        XCTAssertTrue(scheduler.scheduled[0].cancellable.isCancelled)
        XCTAssertEqual(scheduler.scheduled[1].delaySeconds, 15 * 60)
    }

    func test_delete_secret_keeps_the_project_with_its_remaining_key() async throws {
        let groupID = UUID()
        let deletedID = UUID()
        let survivingID = UUID()
        let payload = CaseVaultPayload(
            projects: [.general(now: Date()), group(id: groupID, name: "AWS")],
            secrets: [
                secret(id: deletedID, name: "AWS_ACCESS_KEY", groupID: groupID),
                secret(id: survivingID, name: "AWS_SECRET_KEY", groupID: groupID)
            ],
            values: [
                CaseSecretValue(secretID: deletedID, value: "deleted-value"),
                CaseSecretValue(secretID: survivingID, value: "surviving-value")
            ]
        )
        let env = TestCaseEnvironment(payload: payload)
        let vm = env.makeViewModel()
        try await vm.unlock()

        try vm.deleteSecret(deletedID)

        XCTAssertEqual(env.savedPayload?.projects.map(\.id), [CaseProject.generalID, groupID])
        XCTAssertEqual(env.savedPayload?.secrets.first(where: { $0.id == survivingID })?.projectID, groupID)
        let section = vm.projectSections.first { $0.id == groupID }
        XCTAssertEqual(section?.name, "AWS")
        XCTAssertEqual(section?.secrets.map(\.id), [survivingID])
    }

    func test_migrated_one_key_project_survives_unrelated_delete() async throws {
        let gid = UUID(), keptID = UUID(), looseID = UUID()
        let plaintext = try CaseVaultMigrationTests.v1Plaintext(
            secrets: [(keptID, "SOLO_KEY", gid), (looseID, "LOOSE_KEY", nil)],
            groups: [(gid, "solo project", [keptID])], at: Date(timeIntervalSince1970: 1_500_000_000))
        let migrated = try CaseVaultMigration.decodePayload(plaintext)
        XCTAssertEqual(migrated.projects.map(\.id), [CaseProject.generalID, gid])

        let env = TestCaseEnvironment(payload: migrated)
        let vm = env.makeViewModel()
        try await vm.unlock()
        try vm.deleteSecret(looseID)

        let saved = try XCTUnwrap(env.savedPayload)
        XCTAssertEqual(saved.project(gid)?.name, "solo project")
        XCTAssertEqual(saved.secrets.first { $0.id == keptID }?.projectID, gid)
        XCTAssertEqual(env.store.payload.project(gid)?.name, "solo project")
        XCTAssertEqual(env.store.payload.secrets.map(\.id), [keptID])
    }

    func test_create_key_directly_inside_opened_group() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let groupID = UUID()
        let group = CaseProject(id: groupID, name: "AI keys", description: "", createdAt: Date(), updatedAt: Date())
        let env = TestCaseEnvironment(payload: CaseVaultPayload(
            projects: [.general(now: Date()), group],
            secrets: [secret(id: firstID, name: "OPENAI_API_KEY", groupID: groupID), secret(id: secondID, name: "ANTHROPIC_API_KEY", groupID: groupID)],
            values: []
        ))
        let vm = env.makeViewModel()
        try await vm.unlock()

        try vm.submitName("github token", projectID: groupID)
        try vm.submitValue("ghp-secret")

        XCTAssertEqual(env.savedPayload?.secrets.last?.projectID, groupID)
        XCTAssertEqual(env.savedPayload?.secrets.filter { $0.projectID == groupID }.count, 3)
    }

    func test_move_secret_out_of_two_key_project_keeps_the_project() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let groupID = UUID()
        let env = TestCaseEnvironment(payload: CaseVaultPayload(
            projects: [.general(now: Date()), group(id: groupID, name: "AI keys")],
            secrets: [secret(id: firstID, name: "OPENAI_API_KEY", groupID: groupID), secret(id: secondID, name: "ANTHROPIC_API_KEY", groupID: groupID)],
            values: []
        ))
        let vm = env.makeViewModel()
        try await vm.unlock()

        try vm.moveSecret(firstID, toProject: CaseProject.generalID)

        XCTAssertEqual(env.savedPayload?.projects.map(\.id), [CaseProject.generalID, groupID])
        XCTAssertEqual(env.savedPayload?.secrets.first { $0.id == firstID }?.projectID, CaseProject.generalID)
        XCTAssertEqual(env.savedPayload?.secrets.first { $0.id == secondID }?.projectID, groupID)
    }

    func test_secret_rows_in_project_expose_names_and_descriptions_without_values() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let groupID = UUID()
        let env = TestCaseEnvironment(payload: CaseVaultPayload(
            projects: [.general(now: Date()), group(id: groupID, name: "AI keys")],
            secrets: [
                secret(id: firstID, name: "OPENAI_API_KEY", groupID: groupID),
                secret(id: secondID, name: "ANTHROPIC_API_KEY", groupID: groupID)
            ],
            values: [
                CaseSecretValue(secretID: firstID, value: "sk-openai"),
                CaseSecretValue(secretID: secondID, value: "sk-anthropic")
            ]
        ))
        let vm = env.makeViewModel()
        try await vm.unlock()
        try vm.setSecretDescription(firstID, "main key")

        let rows = vm.secretRows(inProject: groupID)

        XCTAssertEqual(rows.map(\.displayName), ["OPENAI_API_KEY", "ANTHROPIC_API_KEY"])
        XCTAssertEqual(rows.first?.description, "main key")
        XCTAssertEqual(rows.first?.projectID, groupID)
        XCTAssertFalse(String(describing: rows).contains("sk-openai"))
        XCTAssertFalse(String(describing: rows).contains("sk-anthropic"))
    }

    func test_names_unique_per_project_not_global() async throws {
        let env = TestCaseEnvironment(payload: CaseVaultPayload())
        let vm = env.makeViewModel()
        try await vm.unlock()
        let servers = try vm.createProject(name: "servers", description: "")

        try vm.submitName("db pass")
        try vm.submitValue("one")
        try vm.submitName("db pass", projectID: servers)
        try vm.submitValue("two")

        XCTAssertEqual(env.savedPayload?.secrets.map(\.name), ["DB_PASS", "DB_PASS"])
        XCTAssertThrowsError(try vm.submitName("db pass", projectID: servers)) {
            XCTAssertEqual($0 as? CaseViewModelError, .duplicateName)
        }
        XCTAssertThrowsError(try vm.submitName("DB_pass")) {
            XCTAssertEqual($0 as? CaseViewModelError, .duplicateName)
        }
    }

    func test_submit_name_for_unknown_project_is_refused() async throws {
        let env = TestCaseEnvironment(payload: CaseVaultPayload())
        let vm = env.makeViewModel()
        try await vm.unlock()

        XCTAssertThrowsError(try vm.submitName("x key", projectID: UUID())) {
            XCTAssertEqual($0 as? CaseViewModelError, .missingProject)
        }
    }

    func test_delete_project_removes_its_secrets_and_values() async throws {
        let inID = UUID(), outID = UUID(), groupID = UUID()
        let env = TestCaseEnvironment(payload: CaseVaultPayload(
            projects: [.general(now: Date()), group(id: groupID, name: "servers")],
            secrets: [secret(id: inID, name: "IN_KEY", groupID: groupID), secret(id: outID, name: "OUT_KEY")],
            values: [CaseSecretValue(secretID: inID, value: "in"), CaseSecretValue(secretID: outID, value: "out")]
        ))
        let vm = env.makeViewModel()
        try await vm.unlock()

        try vm.deleteProject(groupID)

        let saved = try XCTUnwrap(env.savedPayload)
        XCTAssertEqual(saved.projects.map(\.id), [CaseProject.generalID])
        XCTAssertEqual(saved.secrets.map(\.id), [outID])
        XCTAssertEqual(saved.values.map(\.secretID), [outID])
    }

    func test_general_cannot_be_deleted_or_renamed() async throws {
        let env = TestCaseEnvironment(payload: CaseVaultPayload())
        let vm = env.makeViewModel()
        try await vm.unlock()

        XCTAssertThrowsError(try vm.deleteProject(CaseProject.generalID)) {
            XCTAssertEqual($0 as? CaseViewModelError, .invalidProjectOperation)
        }
        XCTAssertThrowsError(try vm.renameProject(CaseProject.generalID, name: "Other")) {
            XCTAssertEqual($0 as? CaseViewModelError, .invalidProjectOperation)
        }
        XCTAssertEqual(env.store.payload.project(CaseProject.generalID)?.name, "General")
    }

    func test_move_secret_with_name_clash_is_refused() async throws {
        let aID = UUID(), bID = UUID(), groupID = UUID()
        let env = TestCaseEnvironment(payload: CaseVaultPayload(
            projects: [.general(now: Date()), group(id: groupID, name: "servers")],
            secrets: [secret(id: aID, name: "DB_PASS"), secret(id: bID, name: "db_pass", groupID: groupID)],
            values: []
        ))
        let vm = env.makeViewModel()
        try await vm.unlock()

        XCTAssertThrowsError(try vm.moveSecret(aID, toProject: groupID)) {
            XCTAssertEqual($0 as? CaseViewModelError, .duplicateName)
        }
        XCTAssertEqual(env.store.payload.secrets.first { $0.id == aID }?.projectID, CaseProject.generalID)
    }

    func test_project_validation_and_description_limits() async throws {
        let env = TestCaseEnvironment(payload: CaseVaultPayload())
        let vm = env.makeViewModel()
        try await vm.unlock()
        let id = try vm.createProject(name: "  servers  ", description: "prod boxes")
        XCTAssertEqual(env.store.payload.project(id)?.name, "servers")

        for bad in ["   ", String(repeating: "a", count: 49)] {
            XCTAssertThrowsError(try vm.createProject(name: bad, description: "")) {
                XCTAssertEqual($0 as? CaseViewModelError, .invalidProjectName)
            }
        }
        XCTAssertThrowsError(try vm.createProject(name: "SERVERS", description: "")) {
            XCTAssertEqual($0 as? CaseViewModelError, .duplicateName)
        }
        XCTAssertThrowsError(try vm.createProject(name: "general", description: "")) {
            XCTAssertEqual($0 as? CaseViewModelError, .duplicateName)
        }
        XCTAssertThrowsError(try vm.createProject(name: "x", description: String(repeating: "d", count: 201))) {
            XCTAssertEqual($0 as? CaseViewModelError, .descriptionTooLong)
        }
        XCTAssertThrowsError(try vm.setProjectDescription(id, String(repeating: "d", count: 201))) {
            XCTAssertEqual($0 as? CaseViewModelError, .descriptionTooLong)
        }
        try vm.setProjectDescription(id, String(repeating: "d", count: 200))
        try vm.renameProject(id, name: "boxes")
        XCTAssertEqual(env.store.payload.project(id)?.name, "boxes")
        XCTAssertThrowsError(try vm.renameProject(id, name: "General")) {
            XCTAssertEqual($0 as? CaseViewModelError, .duplicateName)
        }
    }

    func test_expanded_projects_default_to_general() async throws {
        let env = TestCaseEnvironment(payload: CaseVaultPayload())
        let vm = env.makeViewModel()
        XCTAssertEqual(vm.expandedProjectIDs, [CaseProject.generalID])
    }

    func test_two_view_models_share_one_service_without_clobbering() async throws {
        let env = TestCaseEnvironment(payload: CaseVaultPayload())
        let a = env.makeViewModel()
        let b = env.makeViewModel()
        try await a.unlock()
        try await b.unlock()

        try a.submitName("key a")
        try a.submitValue("va")
        try b.submitName("key b")
        try b.submitValue("vb")

        XCTAssertEqual(Set(env.store.payload.secrets.map(\.name)), ["KEY_A", "KEY_B"])
        XCTAssertEqual(Set(a.rows.map(\.displayName)), ["KEY_A", "KEY_B"])
    }

    func test_lock_hides_ui_but_keeps_service_payload() async throws {
        let env = TestCaseEnvironment(payload: CaseVaultPayload(secrets: [secret(name: "K_ONE")]))
        let vm = env.makeViewModel()
        try await vm.unlock()

        vm.lock()

        XCTAssertTrue(vm.rows.isEmpty)
        XCTAssertNotNil(env.service.payload)
    }

    func test_cancel_input_returns_to_name_mode_and_clears_query() async throws {
        let env = TestCaseEnvironment(payload: CaseVaultPayload())
        let vm = env.makeViewModel()
        try await vm.unlock()
        vm.query = "github token"
        try vm.submitName("github token")

        vm.cancelInput()

        XCTAssertEqual(vm.inputMode, .name)
        XCTAssertEqual(vm.query, "")
    }

    func test_search_matches_projects_or_keys_without_turning_project_headers_into_keys() async throws {
        let projectID = UUID()
        var project = group(id: projectID, name: "billing")
        project.description = "invoices"
        var key = secret(name: "PAYMENT_TOKEN", groupID: projectID)
        key.description = "Stripe webhooks"
        let other = secret(name: "DATABASE_URL", groupID: projectID)
        let env = TestCaseEnvironment(payload: CaseVaultPayload(projects: [.general(now: Date()), project], secrets: [key, other]))
        let vm = env.makeViewModel()
        try await vm.unlock()
        vm.query = "invoices"
        XCTAssertEqual(vm.projectSections.map(\.id), [projectID])
        XCTAssertEqual(Set(vm.projectSections[0].secrets.map(\.id)), [key.id, other.id], "a project match includes all its keys")
        XCTAssertTrue(vm.projectSections[0].secrets.allSatisfy { $0.kind == .secret })
        vm.query = "stripe"
        XCTAssertEqual(vm.projectSections.first?.secrets.map(\.id), [key.id])
        XCTAssertEqual(vm.inputMode, .name)
        XCTAssertNil(env.savedPayload, "search never writes the vault")
        vm.lock()
        XCTAssertTrue(vm.projectSections.isEmpty)
    }

    func test_new_empty_project_is_searchable_by_name_and_description_without_an_extra_save() async throws {
        let env = TestCaseEnvironment(payload: CaseVaultPayload())
        let vm = env.makeViewModel()
        try await vm.unlock()
        vm.query = "no previous match"
        let id = try vm.createProject(name: "Новый проект", description: "draft workspace")
        env.savedPayload = nil
        for query in ["новый", "НОВЫЙ ПРОЕКТ", "workspace"] {
            vm.query = query
            XCTAssertEqual(vm.projectSections.map(\.id), [id])
            XCTAssertEqual(vm.projectSections[0].keyCount, 0)
            XCTAssertTrue(vm.projectSections[0].secrets.isEmpty)
            XCTAssertTrue(IslandCaseVaultPanel.isExpanded(vm.projectSections[0], expandedIDs: [], isSearching: true))
        }
        XCTAssertNil(env.savedPayload, "typing a query never saves or creates a key")
        vm.query = "General"
        XCTAssertEqual(vm.projectSections.map(\.id), [CaseProject.generalID])
        XCTAssertTrue(vm.projectSections[0].secrets.isEmpty)
    }

    func test_large_vault_search_and_cached_sections() async throws {
        let date = Date()
        let projects = (0..<120).map { group(name: "project-\($0)") }
        let keys = (0..<2400).map { secret(name: "TOKEN_\($0)", groupID: projects[$0 % 120].id) }
        let env = TestCaseEnvironment(payload: CaseVaultPayload(projects: [.general(now: date)] + projects, secrets: keys,
            values: keys.map { CaseSecretValue(secretID: $0.id, value: "fake-test-value") }))
        let vm = env.makeViewModel()
        let start = Date()
        try await vm.unlock()
        let unlocked = Date().timeIntervalSince(start)
        let searchStart = Date()
        for q in ["T", "TO", "TOK", "TOKEN_1", "no_match", ""] {
            vm.query = q
            _ = vm.projectSections
        }
        print("Case synthetic 2400 keys / 120 projects: unlock_ms=\(unlocked * 1000), search_ms_per_query=\(Date().timeIntervalSince(searchStart) * 1000 / 6)")
        XCTAssertEqual(vm.projectSections.count, 121)
        XCTAssertEqual(vm.projectSections.reduce(0) { $0 + $1.secrets.count }, 2400)
        XCTAssertNil(env.savedPayload)
    }

    private func secret(id: UUID = UUID(), name: String, groupID: UUID? = nil) -> CaseSecret {
        CaseSecret(id: id, name: name, projectID: groupID ?? CaseProject.generalID, description: "", copyCount: 0, lastCopiedAt: nil, createdAt: Date(), updatedAt: Date())
    }

    private func group(id: UUID = UUID(), name: String) -> CaseProject {
        CaseProject(id: id, name: name, description: "", createdAt: Date(), updatedAt: Date())
    }
}

@MainActor
private final class TestCaseEnvironment {
    var savedPayload: CaseVaultPayload?
    let pasteboard = StubCasePasteboard()
    let store: StubCaseVaultStore
    let keys: StubCaseVaultKeyProvider
    let authenticator: StubCaseAuthenticator
    let service: CaseVaultService

    init(
        payload: CaseVaultPayload,
        loadError: Error? = nil,
        saveError: Error? = nil,
        keyError: Error? = nil,
        authError: Error? = nil
    ) {
        self.store = StubCaseVaultStore(payload: payload, loadError: loadError, saveError: saveError)
        self.keys = StubCaseVaultKeyProvider(error: keyError)
        self.authenticator = StubCaseAuthenticator(error: authError)
        self.service = CaseVaultService(store: store, keyProvider: keys)
        self.store.onSave = { [weak self] payload in self?.savedPayload = payload }
    }

    func makeViewModel(
        scheduleIdleLock: CaseViewModel.IdleLockScheduler? = nil
    ) -> CaseViewModel {
        CaseViewModel(
            service: service,
            authenticator: authenticator,
            pasteboard: pasteboard,
            now: Date.init,
            scheduleIdleLock: scheduleIdleLock
        )
    }

    func failLoads(with error: Error) {
        store.loadError = error
    }
}

private final class StubCaseVaultStore: CaseVaultStoring {
    var payload: CaseVaultPayload
    var loadError: Error?
    var saveError: Error?
    var resetError: Error?
    private(set) var resetCallCount = 0
    var onSave: ((CaseVaultPayload) -> Void)?

    init(payload: CaseVaultPayload, loadError: Error? = nil, saveError: Error? = nil) {
        self.payload = payload
        self.loadError = loadError
        self.saveError = saveError
    }

    func load(using key: SymmetricKey) throws -> CaseVaultPayload {
        if let loadError {
            throw loadError
        }
        return payload
    }

    func save(_ payload: CaseVaultPayload, using key: SymmetricKey) throws {
        if let saveError {
            throw saveError
        }
        self.payload = payload
        onSave?(payload)
    }

    func reset() throws {
        resetCallCount += 1
        if let resetError {
            throw resetError
        }
        // Model "file deleted": the next load behaves as a fresh (missing) vault.
        loadError = CaseVaultStoreError.missingFile
        payload = CaseVaultPayload()
    }
}

@MainActor
private final class StubCaseVaultKeyProvider: CaseVaultKeyProviding {
    var error: Error?
    private(set) var readCallCount = 0

    init(error: Error? = nil) {
        self.error = error
    }

    func readOrCreateKey() throws -> SymmetricKey {
        readCallCount += 1
        if let error {
            throw error
        }
        return SymmetricKey(size: .bits256)
    }
}

@MainActor
private final class StubCaseAuthenticator: CaseAuthenticating {
    var duringAuthentication: (() async -> Void)?
    var error: Error?
    private(set) var authenticateCallCount = 0

    init(error: Error? = nil) {
        self.error = error
    }

    func authenticate(reason: String) async throws {
        authenticateCallCount += 1
        XCTAssertEqual(reason, "open Case")
        await duringAuthentication?()
        if let error {
            throw error
        }
    }
}

private final class StubCasePasteboard: CasePasteboardWriting {
    var lastString: String?

    func writeString(_ value: String) {
        lastString = value
    }
}

private struct ScaryCaseVaultError: Error, CustomStringConvertible {
    let message: String

    var description: String {
        message
    }
}

private func XCTAssertAsyncThrows(
    _ expression: @autoclosure () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ handler: (Error) -> Void = { _ in }
) async {
    do {
        try await expression()
        XCTFail("Expected async expression to throw", file: file, line: line)
    } catch {
        handler(error)
    }
}

@MainActor
private final class CapturingIdleLockScheduler {
    struct Scheduled {
        let delaySeconds: Int
        let action: @MainActor () -> Void
        let cancellable: StubIdleLockCancellable
    }

    private(set) var scheduled: [Scheduled] = []

    func schedule(delaySeconds: Int, action: @escaping @MainActor () -> Void) -> CaseIdleLockCancellable {
        let cancellable = StubIdleLockCancellable()
        scheduled.append(Scheduled(delaySeconds: delaySeconds, action: action, cancellable: cancellable))
        return cancellable
    }
}

private final class StubIdleLockCancellable: CaseIdleLockCancellable {
    private(set) var isCancelled = false

    func cancel() {
        isCancelled = true
    }
}
