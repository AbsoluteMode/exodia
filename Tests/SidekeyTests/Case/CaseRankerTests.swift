import XCTest
@testable import Sidekey

final class CaseRankerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func test_recently_used_key_beats_old_high_copy_key() {
        let old = secret(name: "OLD_PROJECT_KEY", copyCount: 200, lastCopiedDaysAgo: 120, createdDaysAgo: 200)
        let recent = secret(name: "CURRENT_PROJECT_KEY", copyCount: 3, lastCopiedDaysAgo: 1, createdDaysAgo: 2)

        let sorted = CaseRanker.sortedEntries(secrets: [old, recent], projects: [], query: "", now: now)

        XCTAssertEqual(sorted.map(\.displayName), ["CURRENT_PROJECT_KEY", "OLD_PROJECT_KEY"])
    }

    func test_new_key_gets_short_lived_boost() {
        let new = secret(name: "NEW_TOKEN", copyCount: 0, lastCopiedDaysAgo: nil, createdDaysAgo: 0.5)
        let unusedOld = secret(name: "OLD_UNUSED", copyCount: 0, lastCopiedDaysAgo: nil, createdDaysAgo: 90)

        let sorted = CaseRanker.sortedEntries(secrets: [unusedOld, new], projects: [], query: "", now: now)

        XCTAssertEqual(sorted.first?.displayName, "NEW_TOKEN")
    }

    func test_search_exact_and_prefix_matches_outrank_plain_score() {
        let veryPopular = secret(name: "STRIPE_PROD", copyCount: 50, lastCopiedDaysAgo: 1, createdDaysAgo: 30)
        let exact = secret(name: "GITHUB_TOKEN", copyCount: 0, lastCopiedDaysAgo: nil, createdDaysAgo: 30)
        let prefix = secret(name: "GITHUB_BACKUP", copyCount: 0, lastCopiedDaysAgo: nil, createdDaysAgo: 30)

        let sorted = CaseRanker.sortedEntries(secrets: [veryPopular, prefix, exact], projects: [], query: "github token", now: now)

        XCTAssertEqual(sorted.map(\.displayName), ["GITHUB_TOKEN", "GITHUB_BACKUP"])
    }

    func test_search_complete_token_matches_outrank_first_token_only_matches() {
        let firstTokenOnly = secret(name: "AWS_STAGING", copyCount: 10, lastCopiedDaysAgo: 1, createdDaysAgo: 30)
        let completeTokenMatch = secret(name: "MY_AWS_PROD_KEY", copyCount: 0, lastCopiedDaysAgo: nil, createdDaysAgo: 30)

        let sorted = CaseRanker.sortedEntries(secrets: [firstTokenOnly, completeTokenMatch], projects: [], query: "aws prod", now: now)

        XCTAssertEqual(sorted.map(\.displayName), ["MY_AWS_PROD_KEY", "AWS_STAGING"])
    }

    func test_group_uses_group_name_and_child_usage_for_ranking() {
        let groupID = UUID()
        let child = secret(name: "AWS_PROD_KEY", groupID: groupID, copyCount: 8, lastCopiedDaysAgo: 1, createdDaysAgo: 20)
        let group = CaseProject(
            id: groupID,
            name: "AWS prod",
            description: "",
            createdAt: now.addingTimeInterval(-20 * 86_400),
            updatedAt: now
        )

        let sorted = CaseRanker.sortedEntries(secrets: [child], projects: [group], query: "aws", now: now)

        XCTAssertEqual(sorted.first?.displayName, "AWS prod")
    }

    func test_every_key_is_an_entry_next_to_its_project() {
        let groupID = UUID()
        let child = secret(name: "STALE_CHILD", groupID: groupID, copyCount: 3, lastCopiedDaysAgo: 1, createdDaysAgo: 20)
        let group = CaseProject(
            id: groupID,
            name: "Stale group",
            description: "",
            createdAt: now.addingTimeInterval(-20 * 86_400),
            updatedAt: now
        )

        let sorted = CaseRanker.sortedEntries(secrets: [child], projects: [group], query: "", now: now)

        XCTAssertEqual(Set(sorted.map(\.displayName)), ["Stale group", "STALE_CHILD"])
    }

    func test_group_child_usage_includes_secret_group_id_when_group_key_ids_are_stale() {
        let staleGroupID = UUID()
        let oldGroupID = UUID()
        let child = secret(name: "STALE_CHILD", groupID: staleGroupID, copyCount: 8, lastCopiedDaysAgo: 1, createdDaysAgo: 20)
        let staleGroup = CaseProject(
            id: staleGroupID,
            name: "Stale group",
            description: "",
            createdAt: now.addingTimeInterval(-20 * 86_400),
            updatedAt: now
        )
        let oldGroup = CaseProject(
            id: oldGroupID,
            name: "Old group",
            description: "",
            createdAt: now.addingTimeInterval(-200 * 86_400),
            updatedAt: now
        )

        let sorted = CaseRanker.sortedEntries(secrets: [child], projects: [oldGroup, staleGroup], query: "", now: now)

        XCTAssertEqual(sorted.first?.displayName, "Stale group")
    }

    func test_query_matches_names_and_descriptions_across_projects() {
        let projectID = UUID()
        var byName = secret(name: "STRIPE_KEY", groupID: projectID, copyCount: 0, lastCopiedDaysAgo: nil, createdDaysAgo: 30)
        byName.description = "payments"
        var byDescription = secret(name: "TOKEN_A", copyCount: 0, lastCopiedDaysAgo: nil, createdDaysAgo: 30)
        byDescription.description = "used for stripe webhooks"
        let unrelated = secret(name: "OTHER", groupID: projectID, copyCount: 0, lastCopiedDaysAgo: nil, createdDaysAgo: 30)
        let project = CaseProject(id: projectID, name: "billing", description: "", createdAt: now.addingTimeInterval(-30 * 86_400), updatedAt: now)

        let sorted = CaseRanker.sortedEntries(secrets: [unrelated, byDescription, byName], projects: [project], query: "stripe", now: now)

        XCTAssertEqual(sorted.map(\.displayName), ["STRIPE_KEY", "TOKEN_A"])
        XCTAssertEqual(sorted.first?.projectID, projectID)
        XCTAssertEqual(sorted.last?.description, "used for stripe webhooks")
    }

    func test_query_matches_project_description() {
        let project = CaseProject(id: UUID(), name: "billing", description: "Stripe and invoices", createdAt: now, updatedAt: now)

        let sorted = CaseRanker.sortedEntries(secrets: [], projects: [project], query: "invoices", now: now)

        XCTAssertEqual(sorted.map(\.displayName), ["billing"])
        XCTAssertEqual(sorted.first?.kind, .project)
    }

    func test_later_query_parts_match_the_start_of_key_name_parts() {
        let token = secret(name: "GITHUB_TOKEN", copyCount: 5, lastCopiedDaysAgo: 1, createdDaysAgo: 30)
        let landing = secret(name: "GITHUB_LENDING_KEY", copyCount: 0, lastCopiedDaysAgo: nil, createdDaysAgo: 30)

        for query in ["github_len", "github lending", "github key", "github_lan_key"] {
            let sorted = CaseRanker.sortedEntries(secrets: [token, landing], projects: [], query: query, now: now)
            XCTAssertEqual(sorted.map(\.displayName), ["GITHUB_LENDING_KEY", "GITHUB_TOKEN"], query)
        }
    }

    func test_query_part_naming_a_project_narrows_to_its_keys() {
        let whytap = project(name: "whytap")
        let acme = project(name: "acme / dev")
        let landing = secret(name: "GITHUB_LENDING_KEY", groupID: whytap.id, copyCount: 0, lastCopiedDaysAgo: nil, createdDaysAgo: 30)
        let token = secret(name: "GITHUB_TOKEN", groupID: acme.id, copyCount: 9, lastCopiedDaysAgo: 1, createdDaysAgo: 30)
        let other = secret(name: "OPENAI_API_KEY", groupID: whytap.id, copyCount: 9, lastCopiedDaysAgo: 1, createdDaysAgo: 30)

        for query in ["whytap github", "github whytap", "WHY git"] {
            let sorted = CaseRanker.sortedEntries(secrets: [token, other, landing], projects: [acme, whytap], query: query, now: now)
            XCTAssertEqual(sorted.first?.displayName, "GITHUB_LENDING_KEY", query)
            XCTAssertFalse(sorted.contains { $0.displayName == "OPENAI_API_KEY" }, query)
        }

        let devToken = CaseRanker.sortedEntries(secrets: [token, landing], projects: [acme, whytap], query: "dev github", now: now)
        XCTAssertEqual(devToken.map(\.displayName), ["GITHUB_TOKEN"], "a part of a project name works like a whole one")
    }

    func test_project_order_follows_the_best_match_and_keeps_order_on_ties() {
        let alpha = project(name: "alpha")
        let beta = project(name: "beta")
        let gamma = project(name: "gamma")
        let alphaToken = secret(name: "GITHUB_TOKEN", groupID: alpha.id, copyCount: 0, lastCopiedDaysAgo: nil, createdDaysAgo: 30)
        let betaToken = secret(name: "GITHUB_TOKEN", groupID: beta.id, copyCount: 0, lastCopiedDaysAgo: nil, createdDaysAgo: 30)
        let gammaToken = secret(name: "GITHUB_TOKEN", groupID: gamma.id, copyCount: 0, lastCopiedDaysAgo: nil, createdDaysAgo: 30)
        let defaultOrder = [alpha.id, beta.id, gamma.id]

        func order(_ secrets: [CaseSecret], _ query: String) -> [UUID] {
            let entries = CaseRanker.sortedEntries(secrets: secrets, projects: [gamma, beta, alpha], query: query, now: now)
            return CaseRanker.projectOrder(entries, defaultOrder: defaultOrder)
        }

        XCTAssertEqual(order([gammaToken, betaToken, alphaToken], "github token"), defaultOrder, "equal matches keep the order")
        var usedGamma = gammaToken
        usedGamma.copyCount = 4
        usedGamma.lastCopiedAt = now
        XCTAssertEqual(order([usedGamma, betaToken, alphaToken], "github token"), [gamma.id, alpha.id, beta.id],
                       "the project with the more used key goes first")
        XCTAssertEqual(order([gammaToken, betaToken, alphaToken], "gamma"), [gamma.id], "a project name match on its own")
        XCTAssertEqual(order([gammaToken, betaToken, alphaToken], "beta github"), [beta.id])
    }

    /// Typing `github_to` must not let a project called `tokens` pull its
    /// more used GITHUB_CLIENT_ID above the GITHUB_TOKEN the query spells out.
    func test_key_matching_the_whole_query_stays_ahead_of_a_project_qualified_key() {
        let tokens = project(name: "tokens")
        let zeta = project(name: "zeta")
        let client = secret(name: "GITHUB_CLIENT_ID", groupID: tokens.id, copyCount: 3, lastCopiedDaysAgo: 1, createdDaysAgo: 30)
        let token = secret(name: "GITHUB_TOKEN", groupID: zeta.id, copyCount: 0, lastCopiedDaysAgo: nil, createdDaysAgo: 30)

        for query in ["github_t", "github_to", "github_tok"] {
            let entries = CaseRanker.sortedEntries(secrets: [client, token], projects: [tokens, zeta], query: query, now: now)
            XCTAssertEqual(entries.first?.displayName, "GITHUB_TOKEN", query)
            XCTAssertEqual(CaseRanker.projectOrder(entries, defaultOrder: [tokens.id, zeta.id]), [zeta.id, tokens.id], query)
        }

        let keys = project(name: "Keys")
        let prod = project(name: "Prod")
        let org = secret(name: "OPENAI_ORG", groupID: keys.id, copyCount: 3, lastCopiedDaysAgo: 1, createdDaysAgo: 30)
        let apiKey = secret(name: "OPENAI_API_KEY", groupID: prod.id, copyCount: 0, lastCopiedDaysAgo: nil, createdDaysAgo: 30)
        let sorted = CaseRanker.sortedEntries(secrets: [org, apiKey], projects: [keys, prod], query: "openai key", now: now)
        XCTAssertEqual(sorted.filter { $0.kind == .secret }.map(\.displayName), ["OPENAI_API_KEY", "OPENAI_ORG"])
    }

    func test_a_single_letter_names_no_project() {
        let xeno = project(name: "xeno")
        let zeta = project(name: "zeta")
        let client = secret(name: "GITHUB_CLIENT_ID", groupID: xeno.id, copyCount: 0, lastCopiedDaysAgo: nil, createdDaysAgo: 30)
        let token = secret(name: "GITHUB_TOKEN", groupID: zeta.id, copyCount: 3, lastCopiedDaysAgo: 1, createdDaysAgo: 30)

        let sorted = CaseRanker.sortedEntries(secrets: [client, token], projects: [xeno, zeta], query: "github x", now: now)

        XCTAssertEqual(sorted.map(\.displayName), ["GITHUB_TOKEN", "GITHUB_CLIENT_ID"], "both match only by `github`; usage decides")
        XCTAssertEqual(sorted.map(\.match.bucket), [.firstTokenPrefix, .firstTokenPrefix])
    }

    private func project(name: String) -> CaseProject {
        CaseProject(id: UUID(), name: name, description: "", createdAt: now.addingTimeInterval(-30 * 86_400), updatedAt: now)
    }

    private func secret(
        name: String,
        groupID: UUID? = nil,
        copyCount: Int,
        lastCopiedDaysAgo: Double?,
        createdDaysAgo: Double
    ) -> CaseSecret {
        CaseSecret(
            id: UUID(),
            name: name,
            projectID: groupID ?? CaseProject.generalID,
            description: "",
            copyCount: copyCount,
            lastCopiedAt: lastCopiedDaysAgo.map { now.addingTimeInterval(-$0 * 86_400) },
            createdAt: now.addingTimeInterval(-createdDaysAgo * 86_400),
            updatedAt: now
        )
    }
}
