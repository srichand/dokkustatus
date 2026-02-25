import Foundation

enum TimeZoneOffsetParser {
    static func normalizedUTCOffset(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        let normalized = value.replacingOccurrences(of: ":", with: "")
        guard normalized.count == 5, normalized.first == "+" || normalized.first == "-" else {
            return nil
        }

        let sign = normalized.prefix(1)
        let digits = normalized.dropFirst()
        guard digits.count == 4 else {
            return nil
        }

        let hours = digits.prefix(2)
        let minutes = digits.suffix(2)
        return "\(sign)\(hours)\(minutes)"
    }

    static func secondsFromGMT(offset: String?) -> Int? {
        guard let normalized = normalizedUTCOffset(offset) else {
            return nil
        }

        guard let signCharacter = normalized.first, let value = Int(normalized.dropFirst()) else {
            return nil
        }

        let hours = value / 100
        let minutes = value % 100
        let seconds = (hours * 3600) + (minutes * 60)

        switch signCharacter {
        case "+":
            return seconds
        case "-":
            return -seconds
        default:
            return nil
        }
    }
}
