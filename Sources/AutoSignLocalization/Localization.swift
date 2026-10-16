import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    public static let preferenceKey = "appLanguage"
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: L10n.tr("跟随系统")
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }

    public static func resolve(_ selection: String?, preferredLanguages: [String]) -> AppLanguage {
        if let selection, let language = AppLanguage(rawValue: selection), language != .system { return language }
        for identifier in preferredLanguages {
            let code = identifier.lowercased().replacingOccurrences(of: "_", with: "-")
            if code == "zh" || code.hasPrefix("zh-") { return .simplifiedChinese }
            if code == "en" || code.hasPrefix("en-") { return .english }
        }
        return .english
    }

    public static var current: AppLanguage {
        resolve(ProcessInfo.processInfo.environment["AUTOSIGN_LANGUAGE"]
            ?? UserDefaults.standard.string(forKey: preferenceKey), preferredLanguages: Locale.preferredLanguages)
    }

    public var locale: Locale {
        Locale(identifier: self == .system ? Self.current.rawValue : rawValue)
    }
}

/// Keeps interpolation values separate from the lookup key. Translators can
/// reorder {0}, {1}, … without formatting user data as a format string.
public struct LocalizedMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation, Sendable {
    public let key: String
    public let arguments: [String]

    public init(stringLiteral value: String) {
        key = value
        arguments = []
    }

    public init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key
        arguments = stringInterpolation.arguments
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []

        public init(literalCapacity: Int, interpolationCount: Int) {
            key.reserveCapacity(literalCapacity)
            arguments.reserveCapacity(interpolationCount)
        }

        public mutating func appendLiteral(_ literal: String) { key += literal }
        public mutating func appendInterpolation<T>(_ value: T) {
            key += "{\(arguments.count)}"
            arguments.append(String(describing: value))
        }
    }
}

public enum L10n {
    // SwiftPM's generated accessor uses the build directory as a fallback. Prefer
    // the resources shipped inside the .app so installed copies are self-contained.
    public static let resourceBundle: Bundle = {
        let bundleName = "AutoSign_AutoSignLocalization.bundle"
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(bundleName),
            Bundle.main.executableURL?.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/\(bundleName)")
        ]
        for url in candidates.compactMap({ $0 }) {
            if let bundle = Bundle(url: url) { return bundle }
        }
        return Bundle.module
    }()

    private static let catalogs: [AppLanguage: [String: String]] = {
        Dictionary(uniqueKeysWithValues: [AppLanguage.english, .simplifiedChinese].map { language in
            let url = resourceBundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: "\(language.rawValue).lproj")
            let data = url.flatMap { try? Data(contentsOf: $0) }
            let catalog = data.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: String] } ?? [:]
            return (language, catalog)
        })
    }()

    private struct SavedTemplate {
        let key: String
        let expression: NSRegularExpression
        let indices: [Int]
        let literalLength: Int
    }

    private static let savedTemplates: [SavedTemplate] = {
        let token = try! NSRegularExpression(pattern: #"\{(\d+)\}"#)
        return (catalogs[.english] ?? [:]).flatMap { key, english -> [SavedTemplate] in
            [key, english].compactMap { template in
                let matches = token.matches(in: template, range: NSRange(template.startIndex..., in: template))
                guard !matches.isEmpty else { return nil }
                var pattern = #"\A"#, cursor = template.startIndex, indices: [Int] = []
                var literalLength = 0
                for match in matches {
                    let range = Range(match.range, in: template)!
                    let literal = String(template[cursor..<range.lowerBound])
                    pattern += NSRegularExpression.escapedPattern(for: literal) + #"([\s\S]*?)"#
                    literalLength += literal.count
                    indices.append(Int(template[Range(match.range(at: 1), in: template)!])!)
                    cursor = range.upperBound
                }
                let suffix = String(template[cursor...])
                pattern += NSRegularExpression.escapedPattern(for: suffix) + #"\z"#
                return SavedTemplate(key: key, expression: try! NSRegularExpression(pattern: pattern),
                                     indices: indices, literalLength: literalLength + suffix.count)
            }
        }.sorted { $0.literalLength > $1.literalLength }
    }()

    public static var locale: Locale { AppLanguage.current.locale }

    public static func tr(_ message: LocalizedMessage, language: AppLanguage = .system) -> String {
        render(text(message.key, language: language), arguments: message.arguments)
    }

    public static func text(_ key: String, language: AppLanguage = .system) -> String {
        let language = language == .system ? AppLanguage.current : language
        return catalogs[language]?[key] ?? catalogs[.english]?[key] ?? key
    }

    /// Translate saved statuses and helper diagnostics at the display boundary.
    /// Only known, complete templates match; captured user data is left untouched.
    public static func stored(_ value: String, language: AppLanguage = .system) -> String {
        if catalogs[.english]?[value] != nil { return text(value, language: language) }
        if let key = catalogs[.english]?.first(where: { $0.value == value })?.key {
            return text(key, language: language)
        }
        for template in savedTemplates {
            guard let match = template.expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { continue }
            var arguments = Array(repeating: "", count: (template.indices.max() ?? 0) + 1)
            for (offset, index) in template.indices.enumerated() {
                arguments[index] = String(value[Range(match.range(at: offset + 1), in: value)!])
            }
            return render(text(template.key, language: language), arguments: arguments)
        }
        return value
    }

    public static func helperMessage(_ value: String, language: AppLanguage = .system) -> String {
        let prefix = "当前系统不支持单独管理描述文件："
        if value.hasPrefix(prefix) {
            return text(prefix, language: language) + value.dropFirst(prefix.count)
        }
        return stored(value, language: language)
    }

    public static func date(_ value: Date, language: AppLanguage = .system) -> String {
        let locale = (language == .system ? AppLanguage.current : language).locale
        return value.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
    }

    static func render(_ template: String, arguments: [String]) -> String {
        // Scan the template only once; inserted values can safely contain {0}, %,
        // quotes, or newlines and are never interpreted as further placeholders.
        var result = ""
        var cursor = template.startIndex
        while cursor < template.endIndex {
            if template[cursor] == "{", let end = template[cursor...].firstIndex(of: "}"),
               let index = Int(template[template.index(after: cursor)..<end]), arguments.indices.contains(index) {
                result += arguments[index]
                cursor = template.index(after: end)
            } else {
                result.append(template[cursor])
                cursor = template.index(after: cursor)
            }
        }
        return result
    }
}
