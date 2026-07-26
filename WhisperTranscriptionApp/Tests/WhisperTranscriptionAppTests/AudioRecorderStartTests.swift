import AVFoundation
import XCTest
@testable import WhisperTranscriptionApp

final class AudioRecorderStartTests: XCTestCase {
    func testRecordingFileSettingsUseMono64KbpsHighQualityAAC() {
        let settings = AudioRecorder.recordingFileSettings(sampleRate: 48_000)

        XCTAssertEqual(settings[AVFormatIDKey] as? Int, Int(kAudioFormatMPEG4AAC))
        XCTAssertEqual(settings[AVSampleRateKey] as? Double, 48_000)
        XCTAssertEqual(settings[AVNumberOfChannelsKey] as? Int, 1)
        XCTAssertEqual(settings[AVEncoderBitRateKey] as? Int, 64_000)
        XCTAssertEqual(
            settings[AVEncoderAudioQualityKey] as? Int,
            AVAudioQuality.high.rawValue
        )
    }

    func testStereoRecordingBufferIsAveragedToMono() throws {
        let inputFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))
        let outputFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let inputBuffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: 2
        ))
        inputBuffer.frameLength = 2
        let channels = try XCTUnwrap(inputBuffer.floatChannelData)
        channels[0][0] = 1
        channels[1][0] = -1
        channels[0][1] = 0.5
        channels[1][1] = 0.5

        let monoBuffer = try AudioRecorder.monoBuffer(
            from: inputBuffer,
            outputFormat: outputFormat
        )

        XCTAssertEqual(monoBuffer.format.channelCount, 1)
        XCTAssertEqual(monoBuffer.frameLength, 2)
        let monoSamples = try XCTUnwrap(monoBuffer.floatChannelData?[0])
        XCTAssertEqual(monoSamples[0], 0, accuracy: 0.000_001)
        XCTAssertEqual(monoSamples[1], 0.5, accuracy: 0.000_001)
    }

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

    func testBackgroundSessionActivationDenialMatchesKnownDenialCodes() {
        // '!int' cannotInterruptOthers and '!rec' cannotStartRecording, as
        // observed when a background intent tries to activate the session.
        XCTAssertEqual(AVAudioSession.ErrorCode.cannotInterruptOthers.rawValue, 560_557_684)
        XCTAssertEqual(AVAudioSession.ErrorCode.cannotStartRecording.rawValue, 561_145_187)

        XCTAssertTrue(AudioRecorder.isBackgroundSessionActivationDenial(
            context: .backgroundIntent,
            domain: NSOSStatusErrorDomain,
            code: 560_557_684
        ))
        XCTAssertTrue(AudioRecorder.isBackgroundSessionActivationDenial(
            context: .backgroundIntent,
            domain: NSOSStatusErrorDomain,
            code: 561_145_187
        ))
    }

    func testBackgroundSessionActivationDenialIgnoresOtherErrorsAndContexts() {
        XCTAssertFalse(AudioRecorder.isBackgroundSessionActivationDenial(
            context: .backgroundIntent,
            domain: NSOSStatusErrorDomain,
            code: -50
        ))
        XCTAssertFalse(AudioRecorder.isBackgroundSessionActivationDenial(
            context: .backgroundIntent,
            domain: NSURLErrorDomain,
            code: 560_557_684
        ))
        XCTAssertFalse(AudioRecorder.isBackgroundSessionActivationDenial(
            context: .foreground,
            domain: NSOSStatusErrorDomain,
            code: 560_557_684
        ))
    }
}

private struct StartError: Error, Equatable {
    let attempt: Int
}
