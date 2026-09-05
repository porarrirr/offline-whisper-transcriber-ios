import AppIntents
import CoreSpotlight
import Foundation
import SwiftData
import UniformTypeIdentifiers

@available(iOS 18.0, *)
struct TranscriptionEntity: IndexedEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Transcription",
        numericFormat: "\(placeholder: .int) Transcriptions"
    )
    static var defaultQuery = TranscriptionEntityQuery()

    let id: UUID

    @Property
    var title: String

    @Property
    var text: String

    @Property
    var createdAt: Date

    @Property
    var tags: [String]

    @Property
    var duration: Double

    @Property
    var language: String?

    @Property
    var isFavorite: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(Self.subtitle(createdAt: createdAt, duration: duration))",
            image: .init(systemName: "quote.bubble")
        )
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.title = title
        attributes.textContent = text
        attributes.contentCreationDate = createdAt
        attributes.keywords = tags
        attributes.duration = NSNumber(value: duration)
        attributes.contentType = UTType.plainText.identifier
        attributes.userCurated = NSNumber(value: isFavorite)
        return attributes
    }

    init(record: TranscriptionRecord) {
        id = record.id
        title = record.displayTitle
        text = record.text
        createdAt = record.createdAt
        tags = record.tags
        duration = record.duration
        language = record.language
        isFavorite = record.isFavorite
    }

    init(
        id: UUID,
        title: String,
        text: String,
        createdAt: Date,
        tags: [String],
        duration: Double,
        language: String?,
        isFavorite: Bool
    ) {
        self.id = id
        self.title = title
        self.text = text
        self.createdAt = createdAt
        self.tags = tags
        self.duration = duration
        self.language = language
        self.isFavorite = isFavorite
    }

    private static func subtitle(createdAt: Date, duration: Double) -> String {
        let durationText = Duration.seconds(duration).formatted(
            .time(pattern: .minuteSecond(padMinuteToLength: 1))
        )
        return "\(createdAt.formatted(date: .abbreviated, time: .shortened)) · \(durationText)"
    }
}

@available(iOS 18.0, *)
struct TranscriptionEntityQuery: EntityStringQuery {
    init() {}

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [TranscriptionEntity] {
        let records = try Self.fetchRecords()
        let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        return identifiers.compactMap { recordsByID[$0].map(TranscriptionEntity.init(record:)) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [TranscriptionEntity] {
        try Self.fetchRecords()
            .filter { $0.matchesSearchText(string) }
            .prefix(100)
            .map(TranscriptionEntity.init(record:))
    }

    @MainActor
    func suggestedEntities() async throws -> [TranscriptionEntity] {
        try Self.fetchRecords()
            .prefix(20)
            .map(TranscriptionEntity.init(record:))
    }

    @MainActor
    private static func fetchRecords() throws -> [TranscriptionRecord] {
        let container = try ModelContainer(for: TranscriptionRecord.self)
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<TranscriptionRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        ))
    }
}

@available(iOS 18.0, *)
@MainActor
enum TranscriptionEntityRecordStore {
    static func markAsFavorite(_ entity: TranscriptionEntity) throws -> TranscriptionEntity {
        let (record, context) = try recordAndContext(for: entity.id)
        record.isFavorite = true
        try context.save()
        TranscriptionSpotlightSync.index(record)
        return TranscriptionEntity(record: record)
    }

    static func addTag(_ tag: String, to entity: TranscriptionEntity) throws -> TranscriptionEntity {
        let (record, context) = try recordAndContext(for: entity.id)
        let newTags = try mergedTags(existing: record.tags, input: tag)
        record.updateTags(newTags)
        try context.save()
        TranscriptionSpotlightSync.index(record)
        return TranscriptionEntity(record: record)
    }

    static func mergedTags(existing: [String], input: String) throws -> [String] {
        let requestedTags = TranscriptionRecord.normalizedTags(from: input)
        guard !requestedTags.isEmpty else {
            throw IntentError.emptyTag
        }

        return TranscriptionRecord.normalizedTags(
            from: (existing + requestedTags).joined(separator: ",")
        )
    }

    private static func recordAndContext(for id: UUID) throws -> (TranscriptionRecord, ModelContext) {
        let container = try ModelContainer(for: TranscriptionRecord.self)
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<TranscriptionRecord>(
            predicate: #Predicate<TranscriptionRecord> { record in
                record.id == id
            }
        )
        guard let record = try context.fetch(descriptor).first else {
            throw IntentError.transcriptionNotFound
        }
        return (record, context)
    }
}

@available(iOS 18.0, *)
actor TranscriptionSpotlightIndexer {
    static let shared = TranscriptionSpotlightIndexer()

    private let index = CSSearchableIndex(name: "Transcriptions")

    func index(_ entity: TranscriptionEntity) async {
        do {
            try await index.indexAppEntities([entity])
        } catch {
            AppLogger.error(
                "文字起こし履歴のSpotlight更新に失敗しました: id=\(entity.id)",
                context: "Spotlight",
                error: error
            )
        }
    }

    func delete(identifiers: [UUID]) async {
        guard !identifiers.isEmpty else { return }
        do {
            try await index.deleteAppEntities(
                identifiedBy: identifiers,
                ofType: TranscriptionEntity.self
            )
        } catch {
            AppLogger.error(
                "文字起こし履歴のSpotlight削除に失敗しました: count=\(identifiers.count)",
                context: "Spotlight",
                error: error
            )
        }
    }

    func indexAll(_ entities: [TranscriptionEntity]) async {
        guard !entities.isEmpty else { return }
        do {
            try await index.indexAppEntities(entities)
        } catch {
            AppLogger.error(
                "文字起こし履歴のSpotlight一括更新に失敗しました: count=\(entities.count)",
                context: "Spotlight",
                error: error
            )
        }
    }
}

@MainActor
enum TranscriptionSpotlightSync {
    static func index(_ record: TranscriptionRecord) {
        guard #available(iOS 18.0, *) else { return }
        let entity = TranscriptionEntity(record: record)
        Task {
            await TranscriptionSpotlightIndexer.shared.index(entity)
        }
    }

    static func delete(identifiers: [UUID]) {
        guard #available(iOS 18.0, *) else { return }
        Task {
            await TranscriptionSpotlightIndexer.shared.delete(identifiers: identifiers)
        }
    }

    static func indexAll(using modelContainer: ModelContainer) {
        guard #available(iOS 18.0, *) else { return }

        do {
            let context = ModelContext(modelContainer)
            let records = try context.fetch(FetchDescriptor<TranscriptionRecord>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            ))
            let entities = records.map(TranscriptionEntity.init(record:))
            Task {
                await TranscriptionSpotlightIndexer.shared.indexAll(entities)
            }
        } catch {
            AppLogger.error(
                "Spotlight再構築用の文字起こし履歴取得に失敗しました",
                context: "Spotlight",
                error: error
            )
        }
    }
}
