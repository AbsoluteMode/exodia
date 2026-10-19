import Foundation

enum DeepgramLanguageConfigurationError: Error, Equatable, LocalizedError {
    case automaticLanguageUnavailable
    case unsupportedLanguage

    var errorDescription: String? {
        switch self {
        case .automaticLanguageUnavailable:
            return "Auto is unavailable for this saved Deepgram model. Choose an input language, or choose nova-3 and Save."
        case .unsupportedLanguage:
            return "This input language isn't supported by the selected Deepgram model. Choose a supported input language below."
        }
    }
}

/// Nova's omitted `language` means English, never automatic detection. Both
/// realtime and batch use `multi` for the model's bounded Auto capability;
/// detect_language is deliberately absent because it can substitute models.
/// Source: https://developers.deepgram.com/docs/models-languages-overview
/// WHY: .project-docs/decisions/2026-10-19-deepgram-language-policy.md
enum DeepgramLanguagePolicy {
    private static let nova3Automatic = ["en", "es", "fr", "de", "hi", "ru", "pt", "ja", "it", "nl"]
    private static let nova2Automatic = ["en", "es"]
    private static let englishVariants: Set<String> = ["en", "en-US", "en-AU", "en-CA", "en-GB", "en-IE", "en-IN", "en-NZ"]

    private static let nova3Languages = Set("""
    af af-ZA ar ar-AE ar-SA ar-QA ar-KW ar-SY ar-LB ar-PS ar-JO ar-EG ar-SD ar-TD ar-MA ar-DZ ar-TN ar-IQ ar-IR
    hy as as-IN be bn bs bg ca zh-HK zh zh-CN zh-Hans zh-TW zh-Hant hr cs cs-CZ da da-DK nl
    en en-US en-AU en-GB en-IN en-NZ et fi nl-BE fr fr-CA ka ka-GE de de-CH el gu gu-IN he hi hu id it ja
    kn kk kk-KZ ko ko-KR lv lt mk ms mr mn ne no ps ps-AF fa pl pt pt-BR pt-PT pa pa-IN ro ru sr sk sl
    es es-419 sv sv-SE tl ta te th th-TH tr tr-TR uk ur vi
    """.split(whereSeparator: \.isWhitespace).map(String.init))

    private static let nova2Languages = Set("""
    bg ca zh zh-CN zh-Hans zh-TW zh-Hant zh-HK cs da da-DK nl en en-US en-AU en-GB en-NZ en-IN et fi nl-BE
    fr fr-CA de de-CH el hi hu id it ja ko ko-KR lv lt ms no pl pt pt-BR pt-PT ro ru sk es es-419 sv sv-SE th th-TH tr uk vi
    """.split(whereSeparator: \.isWhitespace).map(String.init))

    static func automaticLanguageCodes(for model: String) -> [String]? {
        switch model {
        case "nova-3", "nova-3-general", "nova-3-medical": return nova3Automatic
        case "nova-2", "nova-2-general": return nova2Automatic
        default: return nil
        }
    }

    /// Unknown persisted/custom models may still accept an explicit language.
    /// Their capabilities are unknown: never guess an Auto protocol for them.
    static func supportedLanguageCodes(for model: String) -> Set<String>? {
        switch model {
        case "nova-3", "nova-3-general": return nova3Languages
        case "nova-2", "nova-2-general": return nova2Languages
        case "nova-3-medical": return englishVariants
        default: return nil
        }
    }

    static func queryLanguage(model: String, language: String?) throws -> String {
        guard let language, !language.isEmpty else {
            guard automaticLanguageCodes(for: model) != nil else {
                throw DeepgramLanguageConfigurationError.automaticLanguageUnavailable
            }
            return "multi"
        }
        if let supported = supportedLanguageCodes(for: model), !supported.contains(language) {
            throw DeepgramLanguageConfigurationError.unsupportedLanguage
        }
        return language
    }

    static func configurationError(model: String, language: String?) -> DeepgramLanguageConfigurationError? {
        do {
            _ = try queryLanguage(model: model, language: language)
            return nil
        } catch let error as DeepgramLanguageConfigurationError {
            return error
        } catch {
            return .unsupportedLanguage
        }
    }

    static func automaticLanguageDescription(for model: String) -> String {
        guard let codes = automaticLanguageCodes(for: model) else {
            return "Auto coverage is unknown for this saved model. Choose an input language explicitly."
        }
        let names = codes.compactMap { AppLanguage.find(code: $0)?.englishName }.joined(separator: ", ")
        return "Auto detects \(codes.count) languages: \(names). Choose other supported languages explicitly."
    }
}
