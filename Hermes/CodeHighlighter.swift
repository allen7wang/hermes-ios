import Foundation
import Highlightr
import UIKit

/// Cached syntax highlighting for fenced code blocks in messages.
/// Returns nil when highlighting is unavailable (missing, unknown or plain-text
/// language, oversized input, engine failure); callers fall back to plain
/// monospaced text. Highlightr would silently auto-detect unknown languages,
/// so the language is validated against the engine's list first.
enum CodeHighlighter {
    static let maximumCodeLength = 20_000

    /// Common fence-tag aliases mapped to canonical highlight.js language names.
    static let languageAliases: [String: String] = [
        "sh": "bash", "zsh": "bash", "shell": "bash", "console": "bash",
        "py": "python",
        "js": "javascript", "jsx": "javascript", "node": "javascript", "mjs": "javascript",
        "ts": "typescript", "tsx": "typescript",
        "yml": "yaml",
        "rb": "ruby",
        "golang": "go",
        "c++": "cpp", "cc": "cpp", "cxx": "cpp", "hpp": "cpp",
        "cs": "csharp", "c#": "csharp",
        "kt": "kotlin", "kts": "kotlin",
        "rs": "rust",
        "md": "markdown", "mkd": "markdown",
        "html": "xml", "htm": "xml", "xhtml": "xml",
        "objc": "objectivec", "mm": "objectivec",
        "f#": "fsharp",
        "gql": "graphql",
    ]

    private static let cache = NSCache<NSString, NSAttributedString>()
    private static let lock = NSLock()
    private static var engine: Highlightr?
    private static var supportedLanguages: Set<String>?

    /// Must be called while holding `lock`.
    private static func sharedEngine() -> Highlightr? {
        if let engine { return engine }
        guard let created = Highlightr() else { return nil }
        _ = created.setTheme(to: "atom-one-dark")
        engine = created
        supportedLanguages = Set(created.supportedLanguages())
        return created
    }

    /// Resolves a fence tag to a canonical language the engine knows.
    /// Plain text resolves to nil because highlighting it adds nothing.
    static func canonicalLanguage(_ language: String, supported: Set<String>) -> String? {
        let lowered = language.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lowered.isEmpty else { return nil }
        let canonical = supported.contains(lowered) ? lowered : languageAliases[lowered]
        guard let canonical, supported.contains(canonical), canonical != "plaintext" else { return nil }
        return canonical
    }

    static func highlighted(code: String, language: String?) -> AttributedString? {
        guard let language, !code.isEmpty, code.count <= maximumCodeLength else { return nil }
        let key = "\(language.lowercased())\u{0}\(code)" as NSString
        if let cached = cache.object(forKey: key) {
            return AttributedString(cached)
        }
        let highlighted: NSAttributedString? = lock.withLock {
            guard let engine = sharedEngine(),
                  let supported = supportedLanguages,
                  let canonical = canonicalLanguage(language, supported: supported) else { return nil }
            return engine.highlight(code, as: canonical)
        }
        guard let highlighted, highlighted.length > 0 else { return nil }
        let cleaned = tokenColorsOnly(from: highlighted)
        cache.setObject(cleaned, forKey: key)
        return AttributedString(cleaned)
    }

    /// Drops the theme's background and font attributes so the app's own code card
    /// styling stays in charge; keeps token colors only.
    private static func tokenColorsOnly(from source: NSAttributedString) -> NSAttributedString {
        let cleaned = NSMutableAttributedString(string: source.string)
        source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { attributes, range, _ in
            var tokenAttributes = attributes
            tokenAttributes[.backgroundColor] = nil
            tokenAttributes[.font] = nil
            cleaned.setAttributes(tokenAttributes, range: range)
        }
        return cleaned
    }

    static func resetCacheForTesting() {
        cache.removeAllObjects()
    }
}
