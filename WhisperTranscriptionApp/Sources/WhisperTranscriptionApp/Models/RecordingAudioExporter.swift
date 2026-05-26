import Foundation

struct RecordingAudioExporter {
    static func export(record: TranscriptionRecord) -> URL? {
        guard let path = record.audioFilePath,
              FileManager.default.fileExists(atPath: path) else {
            return nil
        }

        let sourceURL = URL(fileURLWithPath: path)
        let ext = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
        let fileName = "\(sanitizedFileNameBase(from: record.displayTitle))_\(record.id.uuidString.prefix(8)).\(ext)"
        let destinationURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            return destinationURL
        } catch {
            AppLogger.error("Failed to export recording audio", context: "RecordingAudioExporter", error: error)
            return nil
        }
    }

    private static func sanitizedFileNameBase(from title: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r")
        var sanitized = title
            .components(separatedBy: invalidCharacters)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        while sanitized.contains("__") {
            sanitized = sanitized.replacingOccurrences(of: "__", with: "_")
        }

        sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "_"))

        if sanitized.isEmpty {
            sanitized = "recording"
        }

        let maxLength = 80
        if sanitized.count > maxLength {
            sanitized = String(sanitized.prefix(maxLength))
        }

        return sanitized
    }
}
