import Foundation

enum ExportFormat: String, CaseIterable, Identifiable {
    case txt = "txt"
    case json = "json"
    case csv = "csv"
    case srt = "srt"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .txt: return "テキスト (.txt)"
        case .json: return "JSON (.json)"
        case .csv: return "CSV (.csv)"
        case .srt: return "字幕 (.srt)"
        }
    }
    
    var fileExtension: String { rawValue }
    var mimeType: String {
        switch self {
        case .txt: return "text/plain"
        case .json: return "application/json"
        case .csv: return "text/csv"
        case .srt: return "application/x-subrip"
        }
    }
}

struct TranscriptionExporter {
    static func export(record: TranscriptionRecord, format: ExportFormat) -> URL? {
        switch format {
        case .txt:
            return exportAsTXT(record: record)
        case .json:
            return exportAsJSON(record: record)
        case .csv:
            return exportAsCSV(record: record)
        case .srt:
            return exportAsSRT(record: record)
        }
    }
    
    private static func exportAsTXT(record: TranscriptionRecord) -> URL? {
        let fileName = "transcription_\(record.id.uuidString).txt"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        
        var content = """
        \(record.title)
        作成日: \(record.formattedDate)
        言語: \(record.language ?? "不明")
        """
        
        if !record.segments.isEmpty {
            content += "\n\n--- タイムスタンプ付き ---\n\n"
            for segment in record.segments {
                content += "\(segment.formattedTimestamp) \(segment.text)\n"
            }
        } else {
            content += "\n\n\(record.text)"
        }
        
        do {
            try content.write(to: tempURL, atomically: true, encoding: .utf8)
            return tempURL
        } catch {
            return nil
        }
    }
    
    private static func exportAsJSON(record: TranscriptionRecord) -> URL? {
        let fileName = "transcription_\(record.id.uuidString).json"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        
        let exportData: [String: Any] = [
            "title": record.title,
            "text": record.text,
            "language": record.language ?? "unknown",
            "createdAt": ISO8601DateFormatter().string(from: record.createdAt),
            "duration": record.duration,
            "segments": record.segments.map { segment in
                [
                    "id": segment.id,
                    "start": segment.start,
                    "end": segment.end,
                    "text": segment.text
                ]
            }
        ]
        
        do {
            let data = try JSONSerialization.data(withJSONObject: exportData, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: tempURL)
            return tempURL
        } catch {
            return nil
        }
    }
    
    private static func exportAsCSV(record: TranscriptionRecord) -> URL? {
        let fileName = "transcription_\(record.id.uuidString).csv"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        
        var content = "id,start,end,text\n"
        
        for segment in record.segments {
            let escapedText = segment.text.replacingOccurrences(of: "\"", with: "\"\"")
            content += "\(segment.id),\(segment.start),\(segment.end),\"\(escapedText)\"\n"
        }
        
        if record.segments.isEmpty {
            let escapedText = record.text.replacingOccurrences(of: "\"", with: "\"\"")
            content += "0,0,\(record.duration),\"\(escapedText)\"\n"
        }
        
        do {
            try content.write(to: tempURL, atomically: true, encoding: .utf8)
            return tempURL
        } catch {
            return nil
        }
    }
    
    private static func exportAsSRT(record: TranscriptionRecord) -> URL? {
        let fileName = "transcription_\(record.id.uuidString).srt"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        
        var content = ""
        
        if record.segments.isEmpty {
            content = "1\n00:00:00,000 --> \(formatDurationForSRT(record.duration))\n\(record.text)\n"
        } else {
            for (index, segment) in record.segments.enumerated() {
                content += "\(index + 1)\n"
                content += "\(segment.srtTimestamp)\n"
                content += "\(segment.text)\n\n"
            }
        }
        
        do {
            try content.write(to: tempURL, atomically: true, encoding: .utf8)
            return tempURL
        } catch {
            return nil
        }
    }
    
    private static func formatDurationForSRT(_ duration: Double) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        let milliseconds = Int((duration - Double(Int(duration))) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, milliseconds)
    }
}
