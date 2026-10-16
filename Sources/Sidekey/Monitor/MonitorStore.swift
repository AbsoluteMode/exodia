import Foundation
import Combine

@MainActor
final class MonitorStore: ObservableObject {
    @Published private(set) var dashboards: [MonitorDashboard] = []
    @Published private(set) var readings: [MonitorServerReading] = []
    @Published private(set) var dashboardError: String?
    @Published private(set) var serverError: String?
    @Published private(set) var refreshSeconds: Double = 15

    let root: URL
    private let collector: (MonitorServer) async throws -> MonitorServerMetrics
    private var configuration: MonitorServerConfiguration?
    private var task: Task<Void, Never>?
    private var lastServerRefresh: Date?
    private var refreshRequested = false
    private var generation: UInt64 = 0

    init(root: URL = MonitorPaths.root,
         collector: @escaping (MonitorServer) async throws -> MonitorServerMetrics = {
             try await MonitorServerCollector().collect($0)
         }) {
        self.root = root
        self.collector = collector
    }

    var dashboardsDirectory: URL { root.appendingPathComponent("dashboards", isDirectory: true) }

    func start() {
        guard task == nil else { return }
        try? FileManager.default.createDirectory(at: dashboardsDirectory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        generation &+= 1
        let runGeneration = generation
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == runGeneration else { break }
                self.reloadFiles()
                let due = self.lastServerRefresh.map { Date().timeIntervalSince($0) >= self.refreshSeconds } ?? true
                if due || self.refreshRequested {
                    self.refreshRequested = false
                    await self.refreshServers(generation: runGeneration)
                    guard !Task.isCancelled, self.generation == runGeneration else { break }
                    self.lastServerRefresh = Date()
                }
                do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                catch { break }
            }
        }
    }

    func stop() {
        generation &+= 1
        task?.cancel()
        task = nil
        lastServerRefresh = nil
        readings = readings.map { value in
            var reading = value
            reading.refreshing = false
            return reading
        }
    }

    func requestRefresh() {
        refreshRequested = true
    }

    func reloadFiles() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dashboardsDirectory,
                                                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                                                options: [.skipsHiddenFiles])) ?? []
        var decoded: [MonitorDashboard] = []
        var rejected = 0
        var ids = Set<String>()
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "json" {
            do {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      (values.fileSize ?? Int.max) <= 2_000_000 else {
                    throw MonitorValidationError.invalidDashboard
                }
                let dashboard = try MonitorDashboard.decode(Data(contentsOf: file))
                guard ids.insert(dashboard.id).inserted else { throw MonitorValidationError.invalidDashboard }
                decoded.append(dashboard)
            } catch { rejected += 1 }
        }
        dashboards = decoded.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        dashboardError = rejected > 0 ? "\(rejected) dashboard file(s) could not be loaded. Ask your agent to validate them." : nil

        let configFile = root.appendingPathComponent("servers.json")
        guard fm.fileExists(atPath: configFile.path) else {
            configuration = nil
            readings = []
            serverError = nil
            return
        }
        do {
            let values = try configFile.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? Int.max) <= 128_000 else {
                throw MonitorValidationError.invalidServers
            }
            let newConfiguration = try MonitorServerConfiguration.decode(Data(contentsOf: configFile))
            if newConfiguration != configuration {
                let previous = Dictionary(uniqueKeysWithValues: readings.map { ($0.id, $0) })
                readings = newConfiguration.servers.map { server in
                    if let reading = previous[server.id], reading.server == server { return reading }
                    return MonitorServerReading(server: server)
                }
                configuration = newConfiguration
                refreshSeconds = newConfiguration.refreshSeconds
                lastServerRefresh = nil
            }
            serverError = nil
        } catch {
            configuration = nil
            serverError = "Server configuration could not be loaded. Ask your agent to validate servers.json."
            readings = readings.map { reading in
                var stale = reading
                stale.refreshFailed = true
                return stale
            }
        }
    }

    func refreshServers(generation refreshGeneration: UInt64? = nil) async {
        guard let configuration else { return }
        readings = readings.map { reading in
            var pending = reading
            pending.refreshing = true
            return pending
        }
        let collector = self.collector
        await withTaskGroup(of: (MonitorServer, MonitorServerMetrics?).self) { group in
            for server in configuration.servers {
                group.addTask {
                    do { return (server, try await collector(server)) }
                    catch { return (server, nil) }
                }
            }
            for await (server, metrics) in group {
                guard !Task.isCancelled,
                      refreshGeneration == nil || refreshGeneration == generation,
                      self.configuration?.servers.contains(server) == true,
                      let index = readings.firstIndex(where: { $0.server == server }) else { continue }
                readings[index].refreshing = false
                readings[index].refreshFailed = metrics == nil
                if let metrics {
                    readings[index].metrics = metrics
                    readings[index].observedAt = Date()
                }
            }
        }
    }
}
