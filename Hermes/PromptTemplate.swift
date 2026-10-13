import Foundation

struct PromptTemplate: Identifiable, Codable, Equatable {
    static let titleLimit = 60
    static let bodyLimit = 10_000
    static let countLimit = 100
    let id: UUID
    var title: String
    var body: String
    let createdAt: Date
    var updatedAt: Date
    var pinned: Bool

    init(id: UUID = UUID(), title: String, body: String, createdAt: Date = Date(), updatedAt: Date = Date(), pinned: Bool = false) {
        self.id = id; self.title = title; self.body = body
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.pinned = pinned
    }

    func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= Self.titleLimit,
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, body.count <= Self.bodyLimit,
              createdAt.timeIntervalSince1970.isFinite, updatedAt.timeIntervalSince1970.isFinite else { throw PromptError.invalidTemplate }
        _ = try PromptRendering.variables(in: body)
    }

    static func validateCollection(_ templates: [Self]) throws {
        guard templates.count <= countLimit, Set(templates.map(\.id)).count == templates.count else { throw PromptError.tooManyTemplates }
        for template in templates { try template.validate() }
    }

    static let builtIns: [Self] = [
        sample(1, "会议纪要", "请将下面的会议记录整理为：\n1. 关键结论\n2. 待办事项（负责人、截止时间；未说明的标为待确认）\n3. 尚待解决的问题\n\n会议记录：\n{{会议记录}}"),
        sample(2, "代码检查", "请检查下面的 {{语言}} 代码，说明潜在问题、原因和建议修复。优先关注正确性与边界情况，并给出必要的验证方法。\n\n代码：\n{{代码}}"),
        sample(3, "写作润色", "请为 {{读者}} 润色以下文字，保留原意与事实，语气为 {{语气}}。先给出修改后的版本，再简述主要调整。\n\n原文：\n{{原文}}"),
        sample(4, "学习讲解", "请向 {{基础水平}} 的学习者解释 {{主题}}。使用一个具体例子，说明常见误区，并给出三道练习题及参考答案。"),
        sample(5, "任务拆解", "请把目标「{{目标}}」拆解为可执行的步骤。可用时间：{{时间}}。列出每步产出、依赖和需要确认的问题。")
    ]

    private static func sample(_ number: Int, _ title: String, _ body: String) -> Self {
        Self(id: UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", number))!, title: title, body: body,
             createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }

    static func filtered(_ templates: [Self], query: String) -> [Self] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return templates.filter {
            query.isEmpty || [$0.title, $0.body].contains { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) != nil }
        }.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

enum PromptDraftMode: String, CaseIterable, Identifiable {
    case append, replace
    var id: Self { self }
    var label: String { self == .append ? "追加到草稿" : "替换草稿" }
}

enum PromptRendering {
    static let variableLimit = 20
    static let valueLimit = 10_000
    static let renderedLimit = 50_000
    private struct Token { let range: Range<String.Index>; let name: String }

    private static func tokens(in text: String) throws -> [Token] {
        var cursor = text.startIndex
        var tokens: [Token] = []
        while cursor < text.endIndex {
            let rest = cursor..<text.endIndex
            guard let start = text.range(of: "{{", range: rest) else {
                guard text.range(of: "}}", range: rest) == nil else { throw PromptError.invalidVariables }
                break
            }
            guard text.range(of: "}}", range: cursor..<start.lowerBound) == nil,
                  let end = text.range(of: "}}", range: start.upperBound..<text.endIndex) else { throw PromptError.invalidVariables }
            let name = String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.count <= 40, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
                throw PromptError.invalidVariables
            }
            tokens.append(Token(range: start.lowerBound..<end.upperBound, name: name))
            cursor = end.upperBound
        }
        return tokens
    }

    static func variables(in text: String) throws -> [String] {
        var names: [String] = []
        for token in try tokens(in: text) where !names.contains(token.name) { names.append(token.name) }
        guard names.count <= variableLimit else { throw PromptError.tooManyVariables }
        return names
    }

    static func render(_ body: String, values: [String: String]) throws -> String {
        guard body.count <= PromptTemplate.bodyLimit else { throw PromptError.invalidTemplate }
        for name in try variables(in: body) {
            guard let value = values[name], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PromptError.missingValue(name) }
            guard value.count <= valueLimit else { throw PromptError.valueTooLong(name) }
        }
        var result = ""
        var cursor = body.startIndex
        for token in try tokens(in: body) {
            result += body[cursor..<token.range.lowerBound]
            result += values[token.name] ?? ""
            guard result.count <= renderedLimit else { throw PromptError.renderedTooLong }
            cursor = token.range.upperBound
        }
        result += body[cursor...]
        guard result.count <= renderedLimit else { throw PromptError.renderedTooLong }
        return result
    }

    static func draft(current: String, rendered: String, mode: PromptDraftMode) throws -> String {
        guard !rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              rendered.count <= renderedLimit else { throw PromptError.renderedTooLong }
        let next = mode == .replace || current.isEmpty ? rendered : current + "\n\n" + rendered
        guard next.count <= 100_000 else { throw PromptError.draftTooLong }
        return next
    }
}

enum PromptError: LocalizedError {
    case invalidTemplate, invalidVariables, tooManyVariables, tooManyTemplates, missing, changedContext
    case missingValue(String), valueTooLong(String), renderedTooLong, draftTooLong
    var errorDescription: String? {
        switch self {
        case .invalidTemplate: "请填写模板名称（最多 60 字符）和正文（最多 10,000 字符）。"
        case .invalidVariables: "变量请写作 {{主题}}。名称最多 40 字符，只使用文字、数字或下划线，双大括号需成对。"
        case .tooManyVariables: "每个模板最多使用 20 个不同变量。"
        case .tooManyTemplates: "每个连接最多保存 100 个模板，且模板标识不能重复。"
        case .missing: "这个模板已删除或不属于当前连接。"
        case .changedContext: "当前连接或对话已变更，请关闭后重新打开提示词模板。"
        case .missingValue(let name): "请填写「\(name)」。"
        case .valueTooLong(let name): "「\(name)」最多填写 10,000 字符。"
        case .renderedTooLong: "套用后的提示词需包含文字，且最多 50,000 字符。"
        case .draftTooLong: "追加后草稿超过 100,000 字符，请先缩短草稿或选择替换。"
        }
    }
}
