import Foundation

/// Compatible with Easy Monitoring's local snapshots. A dashboard is data,
/// never executable code: collectors are installed and run separately.
struct MonitorDashboard: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var subtitle: String = ""
    var systemImage: String = "rectangle.3.group"
    var accentHex: String?
    var preferredWidth: Double = 440
    var preferredHeight: Double = 560
    var updatedAt: Date?
    var staleAfterSeconds: Double = 60
    var widgets: [MonitorWidget]

    enum CodingKeys: String, CodingKey {
        case id, title, subtitle, systemImage, accentHex, preferredWidth,
             preferredHeight, updatedAt, staleAfterSeconds, widgets
    }

    init(id: String, title: String, subtitle: String = "", updatedAt: Date? = nil,
         staleAfterSeconds: Double = 60, widgets: [MonitorWidget]) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.updatedAt = updatedAt
        self.staleAfterSeconds = staleAfterSeconds
        self.widgets = widgets
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        systemImage = try c.decodeIfPresent(String.self, forKey: .systemImage) ?? "rectangle.3.group"
        accentHex = try c.decodeIfPresent(String.self, forKey: .accentHex)
        preferredWidth = try c.decodeIfPresent(Double.self, forKey: .preferredWidth) ?? 440
        preferredHeight = try c.decodeIfPresent(Double.self, forKey: .preferredHeight) ?? 560
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        staleAfterSeconds = try c.decodeIfPresent(Double.self, forKey: .staleAfterSeconds) ?? 60
        widgets = try c.decode([MonitorWidget].self, forKey: .widgets)
    }

    func validate() throws {
        guard Self.validID(id), id != "server-status" else {
            throw MonitorValidationError.invalidDashboard
        }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.count <= 200, subtitle.count <= 1_000,
              (320...1_200).contains(preferredWidth),
              (360...1_200).contains(preferredHeight),
              (5...86_400).contains(staleAfterSeconds),
              !widgets.isEmpty, widgets.count <= 128,
              Set(widgets.map(\.id)).count == widgets.count else {
            throw MonitorValidationError.invalidDashboard
        }
        for widget in widgets {
            guard Self.validID(widget.id), !widget.title.isEmpty, widget.title.count <= 200,
                  (widget.value?.count ?? 0) <= 20_000,
                  (widget.detail?.count ?? 0) <= 20_000,
                  (widget.points?.count ?? 0) <= 512 else {
                throw MonitorValidationError.invalidWidget
            }
            if let progress = widget.progress, !(0...1).contains(progress) {
                throw MonitorValidationError.invalidWidget
            }
            if let trend = widget.trendPercent, !trend.isFinite {
                throw MonitorValidationError.invalidWidget
            }
            if let points = widget.points,
               points.contains(where: { !$0.value.isFinite || $0.label.count > 200 }) {
                throw MonitorValidationError.invalidWidget
            }
        }
    }

    func freshness(at now: Date) -> MonitorFreshness {
        guard let updatedAt else { return .unknown }
        let age = now.timeIntervalSince(updatedAt)
        guard age >= -30 else { return .unknown }
        return age <= staleAfterSeconds ? .live : .stale
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 2_000_000 else { throw MonitorValidationError.invalidDashboard }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let dashboard = try decoder.decode(Self.self, from: data)
        try dashboard.validate()
        return dashboard
    }

    static func validID(_ id: String) -> Bool {
        id.count <= 120 && id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#,
                                    options: .regularExpression) != nil
    }
}

enum MonitorFreshness: String, Sendable {
    case live = "Live"
    case stale = "Stale"
    case unknown = "Unknown freshness"
}

enum MonitorWidgetKind: String, Codable, Sendable {
    case metric, progress, status, text, chart
}

struct MonitorWidget: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var kind: MonitorWidgetKind
    var title: String
    var value: String?
    var unit: String?
    var detail: String?
    var progress: Double?
    var trendPercent: Double?
    var status: String?
    var accentHex: String?
    var points: [MonitorDataPoint]?
}

struct MonitorDataPoint: Codable, Equatable, Sendable {
    var label: String
    var value: Double
}

enum MonitorValidationError: Error, LocalizedError {
    case invalidDashboard, invalidWidget, invalidServers

    var errorDescription: String? {
        switch self {
        case .invalidDashboard: return "Invalid dashboard. Check its id, title, size and widgets."
        case .invalidWidget: return "Invalid widget. Use unique ids, finite values and progress from 0 to 1."
        case .invalidServers: return "Invalid server configuration. Check ids, SSH targets and credential references."
        }
    }
}

enum MonitorPaths {
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(BuildConfig.bundleID, isDirectory: true)
            .appendingPathComponent("Monitor", isDirectory: true)
    }
    static var dashboards: URL { root.appendingPathComponent("dashboards", isDirectory: true) }
    static var servers: URL { root.appendingPathComponent("servers.json") }
}
