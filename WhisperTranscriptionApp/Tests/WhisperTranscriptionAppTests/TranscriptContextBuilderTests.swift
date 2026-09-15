import XCTest
@testable import WhisperTranscriptionApp

final class TranscriptContextBuilderTests: XCTestCase {
    func testRepairsCJKWordsSplitByWhitespace() {
        let builder = TranscriptContextBuilder(maximumChunkCharacters: 100, overlapCharacters: 10)
        XCTAssertEqual(builder.normalizedTranscript("おはよ\nうございま\nす あなた"), "おはようございますあなた")
    }

    func testChunksHaveOverlapAndStableCharacterLocations() {
        let builder = TranscriptContextBuilder(maximumChunkCharacters: 10, overlapCharacters: 2)
        let chunks = builder.chunks(from: "abcdefghijklmnopqrst")
        XCTAssertEqual(chunks.map(\.text), ["abcdefghij", "ijklmnopqr", "qrst"])
        XCTAssertEqual(chunks.map(\.startCharacter), [0, 8, 16])
        XCTAssertEqual(chunks.map(\.endCharacter), [10, 18, 20])
    }

    func testApproximateTimeRangeUsesCharacterPosition() {
        let chunk = TranscriptContextBuilder.Chunk(id: 1, text: "text", startCharacter: 250, endCharacter: 500)
        let range = chunk.approximateTimeRange(transcriptLength: 1_000, duration: 400)
        XCTAssertEqual(range?.lowerBound, 100)
        XCTAssertEqual(range?.upperBound, 200)
    }
}
