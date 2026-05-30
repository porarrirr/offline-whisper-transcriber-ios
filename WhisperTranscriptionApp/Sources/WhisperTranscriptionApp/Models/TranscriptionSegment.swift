import Foundation

struct TranscriptionSegment: Codable, Identifiable, Hashable {
    let id: Int
    let start: Double
    let end: Double
    let text: String
    
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
}
