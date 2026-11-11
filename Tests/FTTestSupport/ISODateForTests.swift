import Foundation

/// A date a test writes as ISO 8601 text in UTC, with or without milliseconds ("2026-03-02T10:30:00.000Z").
public enum ISODateForTests {
    public static func parse(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    public static func date(_ text: String) -> Date { parse(text) ?? Date(timeIntervalSince1970: 0) }

    /// A decoder that reads the dates of a test's JSON written this way.
    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = parse(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(text)")
            }
            return date
        }
        return decoder
    }
}
