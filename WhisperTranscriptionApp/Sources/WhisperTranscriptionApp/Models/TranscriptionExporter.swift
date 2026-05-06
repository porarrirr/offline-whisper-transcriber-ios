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
        export(
            item: TranscriptionExportItem(
                id: record.id,
                title: record.title,
                text: record.text,
                duration: record.duration,
                createdAt: record.createdAt,
                segments: record.segments,
                language: record.language
            ),
            format: format
        )
    }

    static func export(
        title: String,
        text: String,
        duration: Double,
        segments: [TranscriptionSegment],
        language: String? = nil,
        format: ExportFormat
    ) -> URL? {
        export(
            item: TranscriptionExportItem(
                title: title,
                text: text,
                duration: duration,
                segments: segments,
                language: language
            ),
            format: format
        )
    }

    private static func export(item: TranscriptionExportItem, format: ExportFormat) -> URL? {
        switch format {
        case .txt:
            return exportAsTXT(item: item)
        case .json:
            return exportAsJSON(item: item)
        case .csv:
            return exportAsCSV(item: item)
        case .srt:
            return exportAsSRT(item: item)
        }
    }
    
    private static func exportAsTXT(item: TranscriptionExportItem) -> URL? {
        let fileName = "transcription_\(item.id.uuidString).txt"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        
        var content = """
        \(item.title)
        作成日: \(item.formattedDate)
        言語: \(item.language ?? "不明")
        """
        
        if !item.segments.isEmpty {
            content += "\n\n--- タイムスタンプ付き ---\n\n"
            for segment in item.segments {
                content += "\(segment.formattedTimestamp) \(segment.text)\n"
            }
        } else {
            content += "\n\n\(item.text)"
        }
        
        do {
            try content.write(to: tempURL, atomically: true, encoding: .utf8)
            return tempURL
        } catch {
            AppLogger.error("TXTエクスポートに失敗しました", context: "TranscriptionExporter", error: error)
            return nil
        }
    }
    
    private static func exportAsJSON(item: TranscriptionExportItem) -> URL? {
        let fileName = "transcription_\(item.id.uuidString).json"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        
        let exportData: [String: Any] = [
            "title": item.title,
            "text": item.text,
            "language": item.language ?? "unknown",
            "createdAt": ISO8601DateFormatter().string(from: item.createdAt),
            "duration": item.duration,
            "segments": item.segments.map { segment in
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
            AppLogger.error("JSONエクスポートに失敗しました", context: "TranscriptionExporter", error: error)
            return nil
        }
    }
    
    private static func exportAsCSV(item: TranscriptionExportItem) -> URL? {
        let fileName = "transcription_\(item.id.uuidString).csv"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        
        var content = "id,start,end,text\n"
        
        for segment in item.segments {
            let escapedText = segment.text.replacingOccurrences(of: "\"", with: "\"\"")
            content += "\(segment.id),\(segment.start),\(segment.end),\"\(escapedText)\"\n"
        }
        
        if item.segments.isEmpty {
            let escapedText = item.text.replacingOccurrences(of: "\"", with: "\"\"")
            content += "0,0,\(item.duration),\"\(escapedText)\"\n"
        }
        
        do {
            try content.write(to: tempURL, atomically: true, encoding: .utf8)
            return tempURL
        } catch {
            AppLogger.error("CSVエクスポートに失敗しました", context: "TranscriptionExporter", error: error)
            return nil
        }
    }
    
    private static func exportAsSRT(item: TranscriptionExportItem) -> URL? {
        let fileName = "transcription_\(item.id.uuidString).srt"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        
        var content = ""
        
        if item.segments.isEmpty {
            content = "1\n00:00:00,000 --> \(formatDurationForSRT(item.duration))\n\(item.text)\n"
        } else {
            for (index, segment) in item.segments.enumerated() {
                content += "\(index + 1)\n"
                content += "\(segment.srtTimestamp)\n"
                content += "\(segment.text)\n\n"
            }
        }
        
        do {
            try content.write(to: tempURL, atomically: true, encoding: .utf8)
            return tempURL
        } catch {
            AppLogger.error("SRTエクスポートに失敗しました", context: "TranscriptionExporter", error: error)
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

private struct TranscriptionExportItem {
    let id: UUID
    let title: String
    let text: String
    let duration: Double
    let createdAt: Date
    let segments: [TranscriptionSegment]
    let language: String?

    init(
        id: UUID = UUID(),
        title: String,
        text: String,
        duration: Double,
        createdAt: Date = Date(),
        segments: [TranscriptionSegment],
        language: String?
    ) {
        self.id = id
        self.title = title
        self.text = text
        self.duration = duration
        self.createdAt = createdAt
        self.segments = segments
        self.language = language
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: createdAt)
    }
}
