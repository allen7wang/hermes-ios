import Foundation

struct MessageContentBlock: Identifiable, Equatable {
    enum Kind: Equatable {
        case prose(String)
        case code(language: String?, text: String)
    }
    let id: Int
    let kind: Kind
}

/// Fenced code remains literal, including indentation and trailing newlines.
enum MessageContent {
    static func blocks(_ text: String) -> [MessageContentBlock] {
        let lines = text.components(separatedBy: "\n")
        var result: [MessageContentBlock] = []
        var prose = ""
        var code = ""
        var open: Fence?
        func append(_ kind: MessageContentBlock.Kind) {
            result.append(MessageContentBlock(id: result.count, kind: kind))
        }
        for (index, line) in lines.enumerated() {
            let raw = line + (index < lines.count - 1 ? "\n" : "")
            if let fence = open {
                if isClosing(line, fence: fence) {
                    append(.code(language: fence.language, text: code))
                    code = ""
                    open = nil
                } else { code += raw }
            } else if let fence = opening(line) {
                if !prose.isEmpty { append(.prose(prose)); prose = "" }
                open = fence
            } else { prose += raw }
        }
        if let open { append(.code(language: open.language, text: code)) }
        if !prose.isEmpty { append(.prose(prose)) }
        return result
    }

    private struct Fence {
        let marker: Character
        let length: Int
        let language: String?
    }

    private static func unindent(_ line: String) -> Substring? {
        let spaces = line.prefix { $0 == " " }.count
        guard spaces <= 3 else { return nil }
        return line.dropFirst(spaces)
    }

    private static func opening(_ line: String) -> Fence? {
        guard let trimmed = unindent(line), let marker = trimmed.first,
              marker == "`" || marker == "~" else { return nil }
        let length = trimmed.prefix { $0 == marker }.count
        guard length >= 3 else { return nil }
        let info = trimmed.dropFirst(length).trimmingCharacters(in: .whitespacesAndNewlines)
        guard marker != "`" || !info.contains("`") else { return nil }
        let language = info.split(whereSeparator: { $0.isWhitespace }).first.map { String($0.prefix(40)) }
        return Fence(marker: marker, length: length, language: language)
    }

    private static func isClosing(_ line: String, fence: Fence) -> Bool {
        guard let trimmed = unindent(line) else { return false }
        let length = trimmed.prefix { $0 == fence.marker }.count
        return length >= fence.length && trimmed.dropFirst(length).allSatisfy { $0.isWhitespace }
    }
}

struct MessageSearchEntry: Identifiable, Equatable {
    let id: String
    let label: String
    let text: String
}

struct MessageSearchHit: Identifiable, Equatable {
    let entry: MessageSearchEntry
    let before: String
    let match: String
    let after: String
    var id: String { entry.id }
}

enum MessageSearch {
    static func hits(in entries: [MessageSearchEntry], query: String) -> [MessageSearchHit] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return entries.compactMap { entry in
            let text = entry.text
            guard let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) else { return nil }
            let start = text.index(range.lowerBound, offsetBy: -48, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(range.upperBound, offsetBy: 80, limitedBy: text.endIndex) ?? text.endIndex
            return MessageSearchHit(entry: entry,
                before: (start == text.startIndex ? "" : "…") + text[start..<range.lowerBound],
                match: String(text[range]),
                after: String(text[range.upperBound..<end]) + (end == text.endIndex ? "" : "…"))
        }
    }
}
