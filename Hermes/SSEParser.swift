import Foundation

struct SSEFrame: Equatable {
    let event: String?
    let data: String
}

struct SSEParser {
    private var event: String?
    private var dataLines: [String] = []

    mutating func consume(_ line: String) -> SSEFrame? {
        if line.isEmpty { return flush() }
        if line.hasPrefix(":") { return nil }

        let fields = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(fields[0])
        var value = fields.count > 1 ? String(fields[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        switch name {
        case "event": event = value
        case "data": dataLines.append(value)
        default: break
        }
        return nil
    }

    mutating func flush() -> SSEFrame? {
        defer {
            event = nil
            dataLines.removeAll(keepingCapacity: true)
        }
        guard !dataLines.isEmpty else { return nil }
        return SSEFrame(event: event, data: dataLines.joined(separator: "\n"))
    }
}
