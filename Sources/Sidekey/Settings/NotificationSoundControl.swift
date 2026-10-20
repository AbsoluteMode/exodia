import SwiftUI

/// A separate labeled row leaves room for long source names and the enable switch.
struct NotificationSoundControl: View {
    @ObservedObject var settings: NotificationSoundSettings
    let sourceID: String
    let sourceName: String
    var preview: (NotificationSound) -> Void = { NotificationSoundPlayer.shared.play($0, preview: true) }

    var body: some View {
        MacRow(title: "Notification sound") {
            MacPopup(items: NotificationSound.allCases.map { .init(value: $0, label: $0.title) },
                     selection: Binding(
                        get: { settings.sound(for: sourceID) },
                        set: { sound in
                            settings.setSound(sound, for: sourceID)
                            preview(sound)
                        }
                     ), minWidth: 110)
                .accessibilityLabel("Notification sound for \(sourceName)")
                .help("Choose a sound to hear a preview. Off keeps this source silent.")
        }
    }
}
