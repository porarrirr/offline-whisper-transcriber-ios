import XCTest
@testable import WhisperTranscriptionApp

final class WhisperContextTests: XCTestCase {
    func testTranscribeChunkThrowsCurrentFailureReasonWhenModelIsNotLoaded() async {
        let context = WhisperContext()

        do {
            _ = try await context.transcribeChunk(
                samples: [0],
                startOffset: 0,
                segmentIDOffset: 0
            )
            XCTFail("Expected transcription to fail without a loaded model")
        } catch {
            XCTAssertEqual(error.localizedDescription, "モデルが読み込まれていません")
            XCTAssertEqual(context.errorMessage, "モデルが読み込まれていません")
        }
    }
}
