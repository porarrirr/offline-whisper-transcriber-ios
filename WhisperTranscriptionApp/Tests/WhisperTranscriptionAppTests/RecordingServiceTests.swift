import XCTest
@testable import WhisperTranscriptionApp

@MainActor
final class RecordingServiceTests: XCTestCase {
    func testRequiredLiveActivityStartsBeforeAudioRecording() async throws {
        var events: [String] = []

        try await RecordingService.startRecordingWithRequiredLiveActivity(
            startLiveActivity: {
                events.append("live activity started")
            },
            startAudioRecording: {
                events.append("audio recording started")
            },
            endLiveActivity: {
                events.append("live activity ended")
            }
        )

        XCTAssertEqual(events, ["live activity started", "audio recording started"])
    }

    func testAudioStartFailureEndsRequiredLiveActivityAndPreservesError() async {
        var events: [String] = []
        let expectedError = TestError.audioStartFailed

        do {
            try await RecordingService.startRecordingWithRequiredLiveActivity(
                startLiveActivity: {
                    events.append("live activity started")
                },
                startAudioRecording: {
                    events.append("audio recording failed")
                    throw expectedError
                },
                endLiveActivity: {
                    events.append("live activity ended")
                }
            )
            XCTFail("Expected audio recording startup to fail")
        } catch {
            XCTAssertEqual(error as? TestError, expectedError)
        }

        XCTAssertEqual(
            events,
            ["live activity started", "audio recording failed", "live activity ended"]
        )
    }

    func testLiveActivityFailureDoesNotAttemptAudioRecording() async {
        var events: [String] = []
        let expectedError = TestError.liveActivityStartFailed

        do {
            try await RecordingService.startRecordingWithRequiredLiveActivity(
                startLiveActivity: {
                    events.append("live activity failed")
                    throw expectedError
                },
                startAudioRecording: {
                    events.append("audio recording started")
                },
                endLiveActivity: {
                    events.append("live activity ended")
                }
            )
            XCTFail("Expected Live Activity startup to fail")
        } catch {
            XCTAssertEqual(error as? TestError, expectedError)
        }

        XCTAssertEqual(events, ["live activity failed"])
    }
}

private enum TestError: Error, Equatable {
    case liveActivityStartFailed
    case audioStartFailed
}
