import XCTest
import SwiftData
@testable import WhisperTranscriptionApp

final class TranscriptionRecordTests: XCTestCase {
    func testCloudMergeCombinesDifferentFieldsWithoutConflict() {
        let record = TranscriptionRecord(title: "Original", text: "Body", sourceType: .recording, duration: 10)
        let base = CloudHistorySnapshot(record)
        var local = base
        var remote = base
        local.title = "Local title"
        remote.tagsJSON = "[\"Cloud tag\"]"

        let result = CloudHistorySnapshot.merged(base: base, local: local, remote: remote)

        XCTAssertFalse(result.conflict)
        XCTAssertEqual(result.value.title, "Local title")
        XCTAssertEqual(result.value.tagsJSON, "[\"Cloud tag\"]")
    }

    func testCloudMergeMarksSameFieldConflict() {
        let record = TranscriptionRecord(title: "Original", text: "Body", sourceType: .recording, duration: 10)
        let base = CloudHistorySnapshot(record)
        var local = base
        var remote = base
        local.title = "Local title"
        remote.title = "Cloud title"

        let result = CloudHistorySnapshot.merged(base: base, local: local, remote: remote)

        XCTAssertTrue(result.conflict)
        XCTAssertEqual(result.value.title, "Cloud title")
    }

    func testCloudMergeTreatsTranscriptAndSegmentsAsOneEdit() {
        let record = TranscriptionRecord(title: "Original", text: "Body", sourceType: .recording, duration: 10)
        let base = CloudHistorySnapshot(record)
        var local = base
        var remote = base
        local.text = "Locally edited"
        remote.segmentsJSON = "[{\"id\":1}]"

        XCTAssertTrue(CloudHistorySnapshot.merged(base: base, local: local, remote: remote).conflict)
    }

    func testCloudSnapshotComparisonIgnoresJSONKeyOrderAndWhitespace() throws {
        let record = TranscriptionRecord(title: "Original", text: "Body", sourceType: .recording, duration: 10)
        let snapshot = CloudHistorySnapshot(record)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let differentlyFormatted = try XCTUnwrap(String(data: encoder.encode(snapshot), encoding: .utf8))

        XCTAssertFalse(snapshot.differs(fromEncodedSnapshot: differentlyFormatted))
        var changed = snapshot
        changed.text = "Updated"
        XCTAssertTrue(changed.differs(fromEncodedSnapshot: differentlyFormatted))
        XCTAssertTrue(snapshot.differs(fromEncodedSnapshot: nil))
    }

    func testCloudDeletionPreservesUnsyncedLocalContentOrAudio() {
        let record = TranscriptionRecord(title: "Original", text: "Body", sourceType: .recording, duration: 10)
        record.lastSyncedSnapshotJSON = CloudHistorySnapshot(record).json
        XCTAssertFalse(CloudHistorySnapshot.needsPreservationAfterCloudDeletion(record))

        record.text = "Offline edit"
        XCTAssertTrue(CloudHistorySnapshot.needsPreservationAfterCloudDeletion(record))

        record.text = "Body"
        record.audioFilePath = "Recordings/offline.m4a"
        XCTAssertTrue(CloudHistorySnapshot.needsPreservationAfterCloudDeletion(record))

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        record.deletedAt = now
        XCTAssertTrue(CloudHistorySnapshot.needsPreservationAfterCloudDeletion(record, asOf: now))

        record.deletedAt = now.addingTimeInterval(-31 * 24 * 60 * 60)
        XCTAssertFalse(CloudHistorySnapshot.needsPreservationAfterCloudDeletion(record, asOf: now))
    }

    @MainActor
    func testCloudDeletionDetachesUnsyncedRecordWithoutRemovingLocalContent() {
        let record = TranscriptionRecord(
            title: "Offline title", text: "Offline edit", sourceType: .recording,
            audioFilePath: "Recordings/offline.m4a", duration: 10)
        let previousCloudID = record.cloudID
        record.cloudAudioID = "deleted-audio"
        record.cloudAudioChunkCount = 2
        record.cloudAudioByteCount = 1024
        record.cloudAudioSHA256 = "digest"
        record.lastSyncedSnapshotJSON = CloudHistorySnapshot(record).json

        HistoryCloudSync.preserveLocalRecordAfterCloudDeletion(record)

        XCTAssertNotEqual(record.cloudID, previousCloudID)
        XCTAssertNil(record.lastSyncedSnapshotJSON)
        XCTAssertNil(record.cloudAudioID)
        XCTAssertEqual(record.cloudAudioChunkCount, 0)
        XCTAssertEqual(record.audioFilePath, "Recordings/offline.m4a")
        XCTAssertEqual(record.text, "Offline edit")
        XCTAssertNil(record.deletedAt)
        XCTAssertEqual(record.title, "Offline title (Conflict Copy)")
    }

    func testDeleteVersusRemoteEditKeepsAnActiveConflictCopy() {
        let record = TranscriptionRecord(title: "Original", text: "Body", sourceType: .recording, duration: 10)
        let base = CloudHistorySnapshot(record)
        var local = base
        local.deletedAt = Date()
        var remote = base
        remote.text = "Remote edit"
        let merged = CloudHistorySnapshot.merged(base: base, local: local, remote: remote)

        XCTAssertTrue(merged.conflict)
        XCTAssertNotNil(merged.value.deletedAt)
        let preserved = CloudHistorySnapshot.versionToPreserveOnConflict(
            base: base, local: local, remote: remote, merged: merged.value)
        XCTAssertNil(preserved.deletedAt)
        XCTAssertEqual(preserved.text, "Remote edit")
    }

    func testDefaultDateTitleUsesTranscriptionOpeningAsDisplayTitle() {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let record = TranscriptionRecord(
            title: TranscriptionRecord.defaultTitle(for: createdAt),
            text: "  今日のミーティングについて話します。次の話題です。 ",
            sourceType: .recording,
            duration: 1,
            createdAt: createdAt
        )

        XCTAssertEqual(record.displayTitle, "今日のミーティングについて話します")
    }

    func testGeneratedDisplayTitleDoesNotReplaceCustomTitle() {
        let record = TranscriptionRecord(
            title: "ユーザーのタイトル",
            text: "文字起こし本文",
            sourceType: .file,
            duration: 1
        )

        XCTAssertEqual(record.displayTitle, "ユーザーのタイトル")
    }

    func testHasTranscriptionTextTreatsWhitespaceOnlyTextAsEmpty() {
        func record(text: String) -> TranscriptionRecord {
            TranscriptionRecord(title: "t", text: text, sourceType: .file, duration: 1)
        }

        XCTAssertFalse(record(text: "").hasTranscriptionText)
        XCTAssertFalse(record(text: " ").hasTranscriptionText)
        XCTAssertFalse(record(text: "\n\t ").hasTranscriptionText)
        XCTAssertFalse(record(text: "\u{3000}").hasTranscriptionText, "全角スペースのみ")
        XCTAssertFalse(record(text: "\u{00A0}").hasTranscriptionText, "ノーブレークスペースのみ")

        XCTAssertTrue(record(text: "  a  ").hasTranscriptionText)
        XCTAssertTrue(record(text: "\u{200B}").hasTranscriptionText, "ゼロ幅スペースは本文扱い")
    }

    func testNormalizedTagsTrimDeduplicateAndPreserveFirstSpelling() {
        let tags = TranscriptionRecord.normalizedTags(from: "  Work, work, Audio、Cafe\ncafe, Research ,, ")

        XCTAssertEqual(tags, ["Work", "Audio", "Cafe", "Research"])
    }

    func testRecordStoresSegmentsAndTagsAsDecodedValues() {
        let segments = [
            TranscriptionSegment(id: 7, start: 1.25, end: 2.5, text: "first"),
            TranscriptionSegment(id: 8, start: 2.5, end: 3.75, text: "second")
        ]
        let record = TranscriptionRecord(
            title: "Interview",
            text: "first second",
            sourceType: .file,
            duration: 3.75,
            segments: segments,
            language: "en",
            tags: [" Client ", "client", "Follow-up"]
        )

        XCTAssertEqual(record.segments, segments)
        XCTAssertEqual(record.tags, ["Client", "Follow-up"])
        XCTAssertEqual(record.tagsInputText, "Client, Follow-up")
    }

    func testSearchMatchesTitleTextTagsAndTreatsBlankSearchAsMatchAll() {
        let record = TranscriptionRecord(
            title: "Planning Meeting",
            text: "Budget and launch notes",
            sourceType: .recording,
            duration: 12,
            tags: ["Client", "Roadmap"]
        )

        XCTAssertTrue(record.matchesSearchText(" planning "))
        XCTAssertTrue(record.matchesSearchText("LAUNCH"))
        XCTAssertTrue(record.matchesSearchText("roadmap"))
        XCTAssertTrue(record.matchesSearchText("  "))
        XCTAssertFalse(record.matchesSearchText("invoice"))
    }

    func testTagLookupIsCaseAndDiacriticInsensitive() {
        let record = TranscriptionRecord(
            title: "Cafe notes",
            text: "Summary",
            sourceType: .file,
            duration: 4,
            tags: ["Cafe"]
        )

        XCTAssertTrue(record.hasTag("cafe"))
        XCTAssertTrue(record.hasTag("CAFE"))
        XCTAssertFalse(record.hasTag("coffee"))
    }

    func testCorruptSegmentAndTagJSONDecodeAsEmptyCollections() {
        let record = TranscriptionRecord(
            title: "Broken import",
            text: "Text",
            sourceType: .file,
            duration: 1,
            segments: [TranscriptionSegment(id: 0, start: 0, end: 1, text: "Text")],
            tags: ["Imported"]
        )

        record.segmentsJSON = "{"
        record.tagsJSON = "{"

        XCTAssertEqual(record.segments, [])
        XCTAssertEqual(record.tags, [])
    }

    func testRecordStoresChatMessagesForItsTranscription() throws {
        let record = TranscriptionRecord(
            title: "Interview",
            text: "Transcript",
            sourceType: .recording,
            duration: 3
        )
        let messages = [
            TranscriptChatMessage(id: UUID(), role: .user, text: "要約して"),
            TranscriptChatMessage(id: UUID(), role: .assistant, text: "要約です")
        ]

        try record.updateChatMessages(messages)

        XCTAssertEqual(record.chatMessages, messages)
    }

    func testCorruptChatHistoryJSONDecodesAsEmptyCollection() {
        let record = TranscriptionRecord(
            title: "Interview",
            text: "Transcript",
            sourceType: .recording,
            duration: 3
        )
        record.chatMessagesJSON = "{"

        XCTAssertEqual(record.chatMessages, [])
    }

    @MainActor
    func testChatHistoryPersistsInSwiftDataStore() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: TranscriptionRecord.self,
            configurations: configuration
        )
        let writer = ModelContext(container)
        let record = TranscriptionRecord(
            title: "Meeting",
            text: "Transcript",
            sourceType: .recording,
            duration: 4
        )
        let messages = [
            TranscriptChatMessage(role: .user, text: "決定事項は？"),
            TranscriptChatMessage(role: .assistant, text: "決定事項です")
        ]
        try record.updateChatMessages(messages)
        writer.insert(record)
        try writer.save()

        let reader = ModelContext(container)
        let fetched = try XCTUnwrap(reader.fetch(FetchDescriptor<TranscriptionRecord>()).first)

        XCTAssertEqual(fetched.chatMessages, messages)
    }

    func testChatMarkdownParserPreservesBlockStructure() {
        let markdown = """
        # 概要

        本文は **重要** です。

        - 項目1
          1. 入れ子
        > 引用

        ```swift
        let answer = 42
        ```
        """

        XCTAssertEqual(
            ChatMarkdownParser.parse(markdown),
            [
                .heading(level: 1, text: "概要"),
                .paragraph("本文は **重要** です。"),
                .unorderedItem(indentation: 0, text: "項目1"),
                .orderedItem(indentation: 1, number: "1", text: "入れ子"),
                .quote("引用"),
                .code(language: "swift", text: "let answer = 42")
            ]
        )
    }

    func testChatMarkdownParserPreservesPlainLineBreaksAndUnclosedCodeFence() {
        XCTAssertEqual(
            ChatMarkdownParser.parse("1行目\n2行目\n\n~~~\ncode"),
            [
                .paragraph("1行目\n2行目"),
                .code(language: nil, text: "code")
            ]
        )
    }
}
