import Foundation
import SwiftData

@Model
class TranscriptionRecord: Identifiable {
    @Attribute(.unique) var id: UUID
    var title: String
    var text: String
    var sourceType: String
    var audioFilePath: String?
    var duration: Double
    var createdAt: Date
    var isFavorite: Bool
    var segmentsJSON: String?
    var language: String?
    
    var segments: [TranscriptionSegment] {
        guard let segmentsJSON = segmentsJSON,
              let data = segmentsJSON.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([TranscriptionSegment].self, from: data)) ?? []
    }
    
    init(
        id: UUID = UUID(),
        title: String,
        text: String,
        sourceType: SourceType,
        audioFilePath: String? = nil,
        duration: Double,
        createdAt: Date = Date(),
        isFavorite: Bool = false,
        segments: [TranscriptionSegment] = [],
        language: String? = nil
    ) {
        self.id = id
        self.title = title
        self.text = text
        self.sourceType = sourceType.rawValue
        self.audioFilePath = audioFilePath
        self.duration = duration
        self.createdAt = createdAt
        self.isFavorite = isFavorite
        if let data = try? JSONEncoder().encode(segments),
           let json = String(data: data, encoding: .utf8) {
            self.segmentsJSON = json
        }
        self.language = language
    }
    
    enum SourceType: String, Codable {
        case recording
        case file
    }
    
    var sourceTypeEnum: SourceType {
        SourceType(rawValue: sourceType) ?? .recording
    }
    
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: createdAt)
    }
    
    var displayTitle: String {
        if title.isEmpty {
            return "文字起こし \(formattedDate)"
        }
        return title
    }
}
