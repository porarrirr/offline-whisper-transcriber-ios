import XCTest
@testable import WhisperTranscriptionApp

final class TranscriptContextBuilderTests: XCTestCase {
    func testChunksNeverExceedConfiguredSize() {
        let builder = TranscriptContextBuilder(maximumChunkCharacters: 10)
        let chunks = builder.chunks(from: "abcdefghijk\nsecond paragraph")
        XCTAssertFalse(chunks.isEmpty)
        XCTAssertTrue(chunks.allSatisfy { $0.text.count <= 10 })
    }

    func testRelevantChunksPreferQuestionTerms() {
        let builder = TranscriptContextBuilder(maximumChunkCharacters: 30)
        let chunks = builder.chunks(from: "apples and oranges\n\nrelease schedule Friday")
        let result = builder.relevantChunks(for: "When is the release schedule?", in: chunks, limit: 1)
        XCTAssertEqual(result.first?.text, "release schedule Friday")
    }

    func testRelevantChunksSupportJapaneseQuestions() {
        let builder = TranscriptContextBuilder(maximumChunkCharacters: 20)
        let chunks = builder.chunks(from: "予算について説明します\n\n発売日は金曜日です")
        let result = builder.relevantChunks(for: "発売日はいつですか", in: chunks, limit: 1)
        XCTAssertEqual(result.first?.text, "発売日は金曜日です")
    }
}
