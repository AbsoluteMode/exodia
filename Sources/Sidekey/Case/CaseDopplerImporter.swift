import CryptoKit
import Foundation

// WHY: docs/decisions/2026-10-19-case-secrets-broker.md

enum CaseDopplerImportError: Error, Equatable {
    case unavailable, fetchFailed, invalidData, conflict, busy

    var userMessage: String {
        switch self {
        case .unavailable: return "Установите Doppler CLI и выполните doppler login в Терминале."
        case .fetchFailed: return "Не удалось прочитать все проекты Doppler. Проверьте вход и доступ. Case не изменён."
        case .invalidData: return "Данные Doppler не помещаются в Case или имеют неподдерживаемый формат. Case не изменён."
        case .conflict: return "В ранее импортированном проекте есть ключ с другим значением. Case не изменён."
        case .busy: return "Импорт уже идёт."
        }
    }
}

struct CaseDopplerImportResult: Equatable {
    var configurations = 0
    var added = 0
    var unchanged = 0

    var message: String { "Импортировано ключей: \(added). Уже в Case: \(unchanged). Конфигураций: \(configurations)." }
}

protocol CaseDopplerImporting {
    func fetch() async throws -> CaseDopplerSnapshot
}

/// Secret values stay in process memory until the vault's encrypted atomic save.
/// There is no plaintext export, shell, fallback cache or diagnostic payload.
struct CaseDopplerSnapshot {
    struct Configuration {
        var project: String
        var config: String
        var secrets: [String: String]

        var projectID: UUID {
            let identity = try! JSONEncoder().encode(["whytap.case.doppler.v1", project, config])
            var bytes = Array(SHA256.hash(data: identity).prefix(16))
            bytes[6] = (bytes[6] & 0x0f) | 0x50
            bytes[8] = (bytes[8] & 0x3f) | 0x80
            return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        }
    }

    var configurations: [Configuration]
    static let generatedNames: Set<String> = ["DOPPLER_PROJECT", "DOPPLER_ENVIRONMENT", "DOPPLER_CONFIG"]

    /// Merge into a copy so even validation/conflict errors after many configs
    /// leave the caller unchanged. Existing local values are never overwritten.
    func merge(into payload: inout CaseVaultPayload, now: Date) throws -> CaseDopplerImportResult {
        var working = payload
        var result = CaseDopplerImportResult()
        var seen = Set<UUID>()
        for configuration in configurations {
            guard !configuration.project.isEmpty, !configuration.config.isEmpty,
                  seen.insert(configuration.projectID).inserted else { throw CaseDopplerImportError.invalidData }
            let projectID = configuration.projectID
            let sourceDescription = "Doppler: \(configuration.project) / \(configuration.config)"
            guard sourceDescription.count <= 200 else { throw CaseDopplerImportError.invalidData }
            let importedSecrets = configuration.secrets.filter { !Self.generatedNames.contains($0.key) }
            for (name, value) in importedSecrets {
                guard name.range(of: "^[A-Z_][A-Z0-9_]{0,63}$", options: .regularExpression) != nil,
                      value.utf8.count <= 16 * 1024 else { throw CaseDopplerImportError.invalidData }
            }
            if working.project(projectID) == nil {
                let name = CaseProject.uniqueName("\(configuration.project) / \(configuration.config)",
                                                  taken: Set(working.projects.map { $0.name.lowercased() }))
                working.projects.append(CaseProject(id: projectID, name: name,
                    description: sourceDescription, createdAt: now, updatedAt: now))
            }
            for name in importedSecrets.keys.sorted() {
                let value = importedSecrets[name]!
                if let existing = working.secrets.first(where: { $0.projectID == projectID && $0.name == name }) {
                    guard working.value(for: existing.id) == value else { throw CaseDopplerImportError.conflict }
                    result.unchanged += 1
                    continue
                }
                let id = UUID()
                working.secrets.append(CaseSecret(id: id, name: name, projectID: projectID, description: "",
                    copyCount: 0, lastCopiedAt: nil, createdAt: now, updatedAt: now))
                working.values.append(CaseSecretValue(secretID: id, value: value))
                result.added += 1
            }
            result.configurations += 1
        }
        payload = working
        return result
    }
}

struct CaseDopplerImporter: CaseDopplerImporting {
    typealias Command = ([String]) async throws -> Data
    private let command: Command

    init(command: Command? = nil) {
        self.command = command ?? { arguments in
            guard let executable = MonitorProcessRunner.executable(named: "doppler") else {
                throw CaseDopplerImportError.unavailable
            }
            return try await MonitorProcessRunner().run(executable: executable, arguments: arguments + [
                "--json", "--silent", "--no-check-version", "--no-read-env",
                "--scope", FileManager.default.homeDirectoryForCurrentUser.path,
                "--timeout", "10s", "--attempts", "2"
            ], timeout: 30, maxOutputBytes: 32 * 1024 * 1024)
        }
    }

    func fetch() async throws -> CaseDopplerSnapshot {
        struct Project: Decodable { let id: String }
        struct Config: Decodable { let name: String }
        do {
            let projects: [Project] = try await pages(["projects"])
            var configurations: [CaseDopplerSnapshot.Configuration] = []
            var totalBytes = 0
            for project in projects {
                try Task.checkCancellation()
                let configs: [Config] = try await pages(["configs", "--project", project.id])
                for config in configs {
                    try Task.checkCancellation()
                    let data = try await command(["secrets", "download", "--project", project.id,
                        "--config", config.name, "--no-file", "--no-fallback", "--no-cache", "--format", "json"])
                    totalBytes += data.count
                    guard totalBytes <= 32 * 1024 * 1024 else { throw CaseDopplerImportError.invalidData }
                    let secrets = try JSONDecoder().decode([String: String].self, from: data)
                    configurations.append(.init(project: project.id, config: config.name, secrets: secrets))
                }
            }
            return CaseDopplerSnapshot(configurations: configurations)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CaseDopplerImportError {
            throw error
        } catch {
            // Never propagate decoder/process errors: they may include values.
            throw CaseDopplerImportError.fetchFailed
        }
    }

    private func pages<T: Decodable>(_ arguments: [String]) async throws -> [T] {
        var result: [T] = []
        for page in 1...100 {
            try Task.checkCancellation()
            let data = try await command(arguments + ["--number", "100", "--page", String(page)])
            let items = try JSONDecoder().decode([T].self, from: data)
            result += items
            if items.count < 100 { return result }
        }
        throw CaseDopplerImportError.invalidData
    }
}
