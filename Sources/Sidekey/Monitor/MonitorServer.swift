import Foundation

/// Private, user-installed configuration. Secrets are references only; no
/// password or token is accepted in this JSON file.
struct MonitorServerConfiguration: Codable, Equatable, Sendable {
    var refreshSeconds: Double = 15
    var servers: [MonitorServer]

    enum CodingKeys: String, CodingKey { case refreshSeconds, servers }

    init(refreshSeconds: Double = 15, servers: [MonitorServer]) {
        self.refreshSeconds = refreshSeconds
        self.servers = servers
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        refreshSeconds = try c.decodeIfPresent(Double.self, forKey: .refreshSeconds) ?? 15
        servers = try c.decode([MonitorServer].self, forKey: .servers)
    }

    func validate() throws {
        guard (10...3_600).contains(refreshSeconds), servers.count <= 16,
              Set(servers.map(\.id)).count == servers.count else {
            throw MonitorValidationError.invalidServers
        }
        for server in servers { try server.validate() }
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 128_000 else { throw MonitorValidationError.invalidServers }
        // Reject credentials accidentally pasted into a source definition.
        // JSONDecoder normally ignores unknown fields, which would hide this
        // mistake while leaving a plaintext password on disk.
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["refreshSeconds", "servers"]),
              let servers = object["servers"] as? [[String: Any]] else {
            throw MonitorValidationError.invalidServers
        }
        for server in servers {
            guard Set(server.keys).isSubset(of: ["id", "name", "group", "sshTarget", "doppler"]) else {
                throw MonitorValidationError.invalidServers
            }
            if let doppler = server["doppler"] as? [String: Any],
               !Set(doppler.keys).isSubset(of: ["project", "config", "prefix"]) {
                throw MonitorValidationError.invalidServers
            }
        }
        let result = try JSONDecoder().decode(Self.self, from: data)
        try result.validate()
        return result
    }
}

struct MonitorServer: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var group: String
    /// An existing SSH alias or user@host. Never an SSH command string.
    var sshTarget: String?
    /// Optional password-authenticated source, read in memory from Doppler.
    /// Host/user/password secret names are prefix + _HOSTNAME/_USER/_PASSWORD.
    var doppler: MonitorDopplerReference?

    func validate() throws {
        guard MonitorDashboard.validID(id), !name.isEmpty, name.count <= 200,
              !group.isEmpty, group.count <= 200,
              (sshTarget != nil) != (doppler != nil) else {
            throw MonitorValidationError.invalidServers
        }
        if let target = sshTarget, !Self.validSSHTarget(target) {
            throw MonitorValidationError.invalidServers
        }
        if let doppler {
            for component in [doppler.project, doppler.config, doppler.prefix] {
                guard MonitorDashboard.validID(component) else {
                    throw MonitorValidationError.invalidServers
                }
            }
        }
    }

    static func validSSHTarget(_ target: String) -> Bool {
        target.count <= 253 && !target.hasPrefix("-") &&
        target.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.@:\[\]-]*$"#,
                     options: .regularExpression) != nil &&
        target.filter({ $0 == "@" }).count <= 1
    }
}

struct MonitorDopplerReference: Codable, Equatable, Sendable {
    var project: String
    var config: String
    var prefix: String
}

struct MonitorServerMetrics: Codable, Equatable, Sendable {
    var cpuPercent: Double
    var memoryUsedBytes: Double
    var memoryTotalBytes: Double
    var load1: Double
    var uptimeSeconds: Double
    var gpus: [MonitorGPUMetrics]
    var gpuState: String

    func validate() throws {
        guard cpuPercent.isFinite, (0...100).contains(cpuPercent),
              memoryTotalBytes.isFinite, memoryTotalBytes > 0,
              memoryUsedBytes.isFinite, (0...memoryTotalBytes).contains(memoryUsedBytes),
              load1.isFinite, load1 >= 0, uptimeSeconds.isFinite, uptimeSeconds >= 0,
              gpus.count <= 32, Set(gpus.map(\.index)).count == gpus.count,
              ["available", "not-present", "unavailable"].contains(gpuState),
              (gpuState == "available") == !gpus.isEmpty else {
            throw MonitorValidationError.invalidServers
        }
        for gpu in gpus {
            guard gpu.index >= 0, gpu.name.count <= 200, gpu.utilizationPercent.isFinite,
                  (0...100).contains(gpu.utilizationPercent),
                  gpu.memoryTotalMiB.isFinite, gpu.memoryTotalMiB > 0,
                  gpu.memoryUsedMiB.isFinite,
                  (0...gpu.memoryTotalMiB).contains(gpu.memoryUsedMiB) else {
                throw MonitorValidationError.invalidServers
            }
        }
    }
}

struct MonitorGPUMetrics: Codable, Equatable, Sendable {
    var index: Int
    var name: String
    var utilizationPercent: Double
    var memoryUsedMiB: Double
    var memoryTotalMiB: Double
}

struct MonitorServerReading: Identifiable, Equatable, Sendable {
    var server: MonitorServer
    var metrics: MonitorServerMetrics?
    var observedAt: Date?
    var refreshFailed = false
    var refreshing = false
    var id: String { server.id }

    func status(at now: Date, staleAfter: Double) -> String {
        guard let observedAt, metrics != nil else { return "Unavailable" }
        if refreshFailed || now.timeIntervalSince(observedAt) > staleAfter { return "Stale" }
        return "Live"
    }
}
