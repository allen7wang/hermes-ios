import Foundation

enum RemoteTimestamp {
    static func date(from raw: String?) -> Date? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Never guess the timezone of a server's naive timestamp.
        guard value.range(of: #"(?:[Zz]|[+-]\d{2}:?\d{2})$"#, options: .regularExpression) != nil else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func display(_ raw: String?, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        guard let raw, !raw.isEmpty else { return "未提供" }
        guard let date = date(from: raw) else { return raw }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
