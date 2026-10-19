import Combine
import Foundation

/// Persist language choices only, never the submitted text or subtitle content.
@MainActor
struct TranslationPreferences {
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func bind(text: TextTranslationModel, subtitles: LiveSubtitleModel) -> Set<AnyCancellable> {
        let textCode = code("textTarget", fallback: "auto", allowsAuto: true)
        text.target = textCode == "auto" ? .automatic : .language(textCode)
        subtitles.targetCode = code("subtitleTarget", fallback: "ru")
        subtitles.sourceCode = code("source", fallback: "auto", allowsAuto: true)
        if let original = defaults.object(forKey: key("original")) as? Bool { subtitles.showsOriginal = original }
        return [
            text.$target.dropFirst().sink { target in
                let value: String
                switch target { case .automatic: value = "auto"; case .language(let code): value = code }
                defaults.set(value, forKey: key("textTarget"))
            },
            subtitles.$targetCode.dropFirst().sink { defaults.set($0, forKey: key("subtitleTarget")) },
            subtitles.$sourceCode.dropFirst().sink { defaults.set($0, forKey: key("source")) },
            subtitles.$showsOriginal.dropFirst().sink { defaults.set($0, forKey: key("original")) }
        ]
    }

    private func code(_ suffix: String, fallback: String, allowsAuto: Bool = false) -> String {
        guard let value = defaults.string(forKey: key(suffix)),
              (allowsAuto && value == "auto") || AppLanguage.all.contains(where: { $0.code == value }) else { return fallback }
        return value
    }
    private func key(_ suffix: String) -> String { "sidekey.translation." + suffix }
}
