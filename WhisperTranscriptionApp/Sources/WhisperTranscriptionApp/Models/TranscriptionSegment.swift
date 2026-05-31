import Foundation

struct TranscriptionSegment: Codable, Identifiable, Hashable {
    let id: Int
    let start: Double
    let end: Double
    let text: String

    static func plainText(from segments: [TranscriptionSegment], fallback: String = "") -> String {
        let text = joinedPlainText(from: segments.map(\.text))
        return text.isEmpty ? fallback : text
    }

    static func timestampedText(from segments: [TranscriptionSegment]) -> String {
        segments.map { "\($0.formattedTimestamp) \($0.text)" }.joined(separator: "\n")
    }
    
    var formattedTimestamp: String {
        let startStr = formatTime(start)
        let endStr = formatTime(end)
        return "[\(startStr) --> \(endStr)]"
    }
    
    var srtTimestamp: String {
        let startStr = formatSRTTime(start)
        let endStr = formatSRTTime(end)
        return "\(startStr) --> \(endStr)"
    }
    
    private func formatTime(_ time: Double) -> String {
        let hours = Int(time) / 3600
        let minutes = (Int(time) % 3600) / 60
        let seconds = Int(time) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
    
    private func formatSRTTime(_ time: Double) -> String {
        let totalMilliseconds = max(0, Int((time * 1000).rounded()))
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds % 3_600_000) / 60_000
        let seconds = (totalMilliseconds % 60_000) / 1000
        let milliseconds = totalMilliseconds % 1000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, milliseconds)
    }

    private static func joinedPlainText(from parts: [String]) -> String {
        let normalizedParts = parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard var text = normalizedParts.first else { return "" }

        for part in normalizedParts.dropFirst() {
            text += separator(between: text, and: part)
            text += part
        }

        return text
    }

    private static func separator(between previousText: String, and nextText: String) -> String {
        guard let previous = previousText.last, let next = nextText.first else { return "" }

        if leadingNoSpaceCharacters.contains(next) || trailingNoSpaceCharacters.contains(previous) {
            return ""
        }

        if isCJKOrFullwidth(previous) || isCJKOrFullwidth(next) {
            return ""
        }

        return " "
    }

    private static let leadingNoSpaceCharacters: Set<Character> = [
        ".", ",", "!", "?", ";", ":", "%", ")", "]", "}", ">", "\"", "'", "”", "’",
        "、", "。", "！", "？", "；", "：", "％", "）", "］", "｝", "」", "』", "】", "》", "〉", "…"
    ]

    private static let trailingNoSpaceCharacters: Set<Character> = [
        "(", "[", "{", "<", "\"", "'", "“", "‘", "（", "［", "｛", "「", "『", "【", "《", "〈"
    ]

    private static func isCJKOrFullwidth(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF:
                return true
            default:
                return false
            }
        }
    }
}
