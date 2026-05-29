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
    var tagsJSON: String?
    
    var segments: [TranscriptionSegment] {
        guard let segmentsJSON = segmentsJSON,
              let data = segmentsJSON.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([TranscriptionSegment].self, from: data)) ?? []
    }

    var tags: [String] {
        guard let tagsJSON,
              let data = tagsJSON.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    var tagsInputText: String {
        tags.joined(separator: ", ")
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
        language: String? = nil,
        tags: [String] = []
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
        self.tagsJSON = Self.encodedTags(tags)
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
        formatter.locale = Locale.current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: createdAt)
    }
    
    var displayTitle: String {
        if title.isEmpty {
            return Self.defaultTitle(for: createdAt)
        }
        return title
    }

    var hasTranscriptionText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func updateTranscription(text: String, duration: Double, segments: [TranscriptionSegment], language: String?) {
        self.text = text
        self.duration = duration
        self.language = language
        if let data = try? JSONEncoder().encode(segments),
           let json = String(data: data, encoding: .utf8) {
            self.segmentsJSON = json
        }
    }

    func updateTags(_ tags: [String]) {
        self.tagsJSON = Self.encodedTags(tags)
    }

    func matchesSearchText(_ searchText: String) -> Bool {
        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSearchText.isEmpty else { return true }
        return text.localizedCaseInsensitiveContains(trimmedSearchText) ||
            title.localizedCaseInsensitiveContains(trimmedSearchText) ||
            tags.contains { $0.localizedCaseInsensitiveContains(trimmedSearchText) }
    }

    func hasTag(_ tag: String) -> Bool {
        tags.contains { $0.compare(tag, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    static func defaultTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func normalizedTags(from input: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",、\n")
        let rawTags = input.components(separatedBy: separators)
        var seenTags: Set<String> = []
        var normalizedTags: [String] = []

        for rawTag in rawTags {
            let tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty else { continue }

            let key = tag.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seenTags.insert(key).inserted else { continue }
            normalizedTags.append(tag)
        }

        return normalizedTags
    }

    private static func encodedTags(_ tags: [String]) -> String? {
        let normalizedTags = normalizedTags(from: tags.joined(separator: ","))
        guard !normalizedTags.isEmpty,
              let data = try? JSONEncoder().encode(normalizedTags) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
