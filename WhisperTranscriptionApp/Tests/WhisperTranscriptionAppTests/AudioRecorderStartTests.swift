import AVFoundation
import XCTest
@testable import WhisperTranscriptionApp

final class AudioRecorderStartTests: XCTestCase {
    func testEngineStartSucceedsOnFirstAttemptWithoutRetryOrSleep() async throws {
        var startCount = 0
        var retryCount = 0
        var sleepCount = 0

        try await AudioRecorder.startEngineWithBoundedRetry(
            maxAttempts: 3,
            retryDelayNanoseconds: 300_000_000,
            startEngine: { startCount += 1 },
            onRetry: { _, _ in retryCount += 1 },
            sleep: { _ in sleepCount += 1 }
        )

        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(retryCount, 0)
        XCTAssertEqual(sleepCount, 0)
    }

    func testEngineStartRetriesTwiceThenSucceedsInOrder() async throws {
        var attempts = 0
        var events: [String] = []

        try await AudioRecorder.startEngineWithBoundedRetry(
            maxAttempts: 3,
            retryDelayNanoseconds: 300_000_000,
            startEngine: {
                attempts += 1
                events.append("start")
                if attempts < 3 { throw StartError(attempt: attempts) }
            },
            onRetry: { attempt, _ in events.append("retry(\(attempt))") },
            sleep: { delay in events.append("sleep(\(delay))") }
        )

        XCTAssertEqual(events, [
            "start", "retry(1)", "sleep(300000000)",
            "start", "retry(2)", "sleep(300000000)", "start"
        ])
    }

    func testEngineStartThrowsUnmodifiedLastErrorAfterAllAttempts() async {
        var retryAttempts: [Int] = []

        do {
            try await AudioRecorder.startEngineWithBoundedRetry(
                maxAttempts: 3,
                retryDelayNanoseconds: 1,
                startEngine: { throw StartError(attempt: retryAttempts.count + 1) },
                onRetry: { attempt, _ in retryAttempts.append(attempt) },
                sleep: { _ in }
            )
            XCTFail("Expected engine startup to fail")
        } catch {
            XCTAssertEqual(error as? StartError, StartError(attempt: 3))
        }

        XCTAssertEqual(retryAttempts, [1, 2])
    }

    func testEngineStartWithOneAttemptDoesNotRetry() async {
        var retryCount = 0
        do {
            try await AudioRecorder.startEngineWithBoundedRetry(
                maxAttempts: 1,
                retryDelayNanoseconds: 1,
                startEngine: { throw StartError(attempt: 1) },
                onRetry: { _, _ in retryCount += 1 },
                sleep: { _ in XCTFail("Sleep must not run") }
            )
            XCTFail("Expected engine startup to fail")
        } catch {
            XCTAssertEqual(error as? StartError, StartError(attempt: 1))
        }
        XCTAssertEqual(retryCount, 0)
    }

    func testForegroundNonBluetoothCategoryOptionsKeepMixing() {
        let options = AudioRecorder.recordingCategoryOptions(
            usesBluetoothHFP: false,
            context: .foreground
        )
        XCTAssertTrue(options.contains(.defaultToSpeaker))
        XCTAssertTrue(options.contains(.mixWithOthers))
    }

    func testBackgroundIntentNonBluetoothCategoryOptionsDisableMixing() {
        let options = AudioRecorder.recordingCategoryOptions(
            usesBluetoothHFP: false,
            context: .backgroundIntent
        )
        XCTAssertEqual(options, [.defaultToSpeaker])
        XCTAssertFalse(options.contains(.mixWithOthers))
    }

    func testBluetoothCategoryOptionsUseOnlyHFPInBothContexts() {
        XCTAssertEqual(
            AudioRecorder.recordingCategoryOptions(usesBluetoothHFP: true, context: .foreground),
            [.allowBluetoothHFP]
        )
        XCTAssertEqual(
            AudioRecorder.recordingCategoryOptions(usesBluetoothHFP: true, context: .backgroundIntent),
            [.allowBluetoothHFP]
        )
    }
}

private struct StartError: Error, Equatable {
    let attempt: Int
}
