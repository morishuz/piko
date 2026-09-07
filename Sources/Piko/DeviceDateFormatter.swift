import Foundation

/// Display-only conversion. Keep the original metadata intact for selection
/// validation, transfer verification and Bin recovery records.
@MainActor
final class DeviceDateFormatter {
    private static let timestamp = try! NSRegularExpression(pattern:
        #"^([0-9]{8}T[0-9]{6}|[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?:\.[0-9]{1,9})?(Z|[+-][0-9]{2}:?[0-9]{2})?$"#)
    private let parser = DateFormatter()
    private let wallClock = DateFormatter()
    private let zoned = DateFormatter()

    init(locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) {
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.calendar = Calendar(identifier: .gregorian)
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "yyyyMMdd'T'HHmmss"
        parser.isLenient = false
        for formatter in [wallClock, zoned] {
            formatter.locale = locale
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
        }
        // A camera timestamp without a zone is a wall-clock reading, not UTC.
        // Using the same neutral zone for parsing and display preserves it,
        // including times that fall in a daylight-saving gap on this Mac.
        wallClock.timeZone = TimeZone(secondsFromGMT: 0)
        zoned.timeZone = timeZone
    }

    func string(from raw: String) -> String {
        guard raw.utf8.count <= 64 else { return "—" }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = Self.timestamp.firstMatch(in: text, range: range),
              let baseRange = Range(match.range(at: 1), in: text) else { return "—" }
        let base = text[baseRange].replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
        guard !base.hasPrefix("0000"), let date = parser.date(from: base),
              parser.string(from: date) == base else { return "—" }
        guard let zoneRange = Range(match.range(at: 2), in: text) else {
            return wallClock.string(from: date)
        }
        let zone = text[zoneRange]
        var offset = 0
        if zone != "Z" {
            let digits = zone.dropFirst().replacingOccurrences(of: ":", with: "")
            guard let hours = Int(digits.prefix(2)), hours < 24,
                  let minutes = Int(digits.suffix(2)), minutes < 60 else { return "—" }
            offset = (hours * 60 + minutes) * 60 * (zone.first == "-" ? -1 : 1)
        }
        return zoned.string(from: date.addingTimeInterval(TimeInterval(-offset)))
    }
}
