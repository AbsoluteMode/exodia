import Foundation

/// The mode and route a Drop take started with. `begin` runs once, when the
/// take starts; everything that happens to the take afterwards (finishing the
/// stream, Retry, delivery) reads the mode from here, not from the current
/// preference, so a mode switch in the island mid-take changes the next take
/// and never this one. The Fast/Smart output rules stay in `DropOutputPolicy`.
// WHY: .project-docs/decisions/2026-10-19-api-and-models.md
@MainActor
final class DropTake {
    static let shared = DropTake()

    /// `.fast` until the first take begins.
    private(set) var mode: TranscriptionMode = .fast
    /// The route `feature` had when the take began; `nil` when it was Not set.
    private(set) var route: FeatureRoute?

    init() {}

    /// The feature the take runs on.
    var feature: AIFeature { .drop(mode) }

    func begin(mode: TranscriptionMode, route: FeatureRoute?) {
        self.mode = mode
        self.route = route
    }
}
