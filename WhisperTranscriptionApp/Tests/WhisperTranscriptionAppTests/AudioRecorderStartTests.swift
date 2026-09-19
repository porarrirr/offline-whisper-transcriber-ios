import AVFoundation
import XCTest
@testable import WhisperTranscriptionApp

final class AudioRecorderStartTests: XCTestCase {
    func testStartingNewRecordingKeepsInterruptedRecordingAvailable() {
        let recorder = AudioRecorder()
        let interruptedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("interrupted-\(UUID().uuidString).m4a")
        recorder.interruptedRecordingURL = interruptedURL

        recorder.publishStartedRecording()

        let published = expectation(description: "recording start published")
        DispatchQueue.main.async {
            XCTAssertTrue(recorder.isRecording)
            XCTAssertEqual(recorder.interruptedRecordingURL, interruptedURL)
            published.fulfill()
        }
        wait(for: [published], timeout: 1)
    }

    func testMatchingRecordingFormatUsesOriginalBufferWithoutChangingSamples() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
            channels: 1, interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
        buffer.frameLength = 1_024
        for frame in 0..<1_024 { buffer.floatChannelData![0][frame] = Float(frame) / 1_024 }
        let converter = try RecordingInputConverter(from: format, to: format)
        let result = try converter.convert(buffer)
        XCTAssertTrue(result === buffer)
        XCTAssertEqual(result.frameLength, 1_024)
        XCTAssertEqual(result.floatChannelData![0][1_023], Float(1_023) / 1_024)
    }

    func testDisplayUpdatesAreLimitedToTenPerSecondOfRecordedAudio() {
        var policy = RecordingDisplayUpdatePolicy()
        policy.isActive = true
        let updates = (0..<48_000).filter { policy.shouldPublish(at: Double($0) / 48_000) }
        XCTAssertEqual(updates.count, 10)
    }

    func testDisplayUpdatesStopWhileInactiveAndResumeAtCurrentRecordingTime() {
        var policy = RecordingDisplayUpdatePolicy()
        XCTAssertFalse(policy.shouldPublish(at: 0))
        policy.isActive = true
        XCTAssertTrue(policy.shouldPublish(at: 0))
        XCTAssertFalse(policy.shouldPublish(at: 0.02))
        policy.isActive = false
        XCTAssertFalse(policy.shouldPublish(at: 600))
        policy.isActive = true
        policy.reset()
        XCTAssertTrue(policy.shouldPublish(at: 600.02))
        XCTAssertFalse(policy.shouldPublish(at: 600.04))
        policy.reset()
        XCTAssertTrue(policy.shouldPublish(at: 0), "A new recording starts its own display timeline")
    }

    func testRecordingFileSettingsUseCrashRecoverableMono16BitPCM() {
        let settings = AudioRecorder.recordingFileSettings(sampleRate: 48_000)

        XCTAssertEqual(settings[AVFormatIDKey] as? Int, Int(kAudioFormatLinearPCM))
        XCTAssertEqual(settings[AVSampleRateKey] as? Double, 48_000)
        XCTAssertEqual(settings[AVNumberOfChannelsKey] as? Int, 1)
        XCTAssertEqual(settings[AVLinearPCMBitDepthKey] as? Int, 16)
        XCTAssertEqual(settings[AVLinearPCMIsFloatKey] as? Bool, false)
        XCTAssertEqual(settings[AVLinearPCMIsBigEndianKey] as? Bool, false)
    }

    func testNormalStopFinalizationPublishesM4AAndRemovesDurableSource() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording-finalization-\(UUID().uuidString).caf")
        let outputURL = sourceURL.deletingPathExtension().appendingPathExtension("m4a")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: outputURL)
        }
        try makeDurableRecording(at: sourceURL, duration: 0.25)

        let finalizedURL = try await RecordingAudioFinalizer.finalize(sourceURL)

        XCTAssertEqual(finalizedURL, outputURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        let finalizedFile = try AVAudioFile(forReading: outputURL)
        XCTAssertGreaterThan(finalizedFile.length, 0)
    }

    func testFinalizationCanKeepDurableSourceUntilHistoryReferenceIsUpdated() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording-finalization-retained-\(UUID().uuidString).caf")
        let outputURL = sourceURL.deletingPathExtension().appendingPathExtension("m4a")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: outputURL)
        }
        try makeDurableRecording(at: sourceURL, duration: 0.25)

        let finalizedURL = try await RecordingAudioFinalizer.finalize(sourceURL, removeSource: false)

        XCTAssertEqual(finalizedURL, outputURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
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

    private func makeDurableRecording(at url: URL, duration: TimeInterval) throws {
        let sampleRate = 48_000.0
        var file: AVAudioFile? = try AVAudioFile(
            forWriting: url,
            settings: AudioRecorder.recordingFileSettings(sampleRate: sampleRate),
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ))
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        try file?.write(from: buffer)
        file = nil
    }

    func testMicrophoneRouteFormatsAppendToOneRecording() throws {
        // Both switching from HFP to built-in and the reverse must preserve
        // one file format and duration, without treating upsampling as quality gain.
        for recordingRate in [16_000.0, 48_000.0] {
            let outputFormat = try XCTUnwrap(AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: recordingRate,
                channels: 1, interleaved: false
            ))
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
            defer { try? FileManager.default.removeItem(at: url) }
            var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: outputFormat.settings)
            var totalFrames: AVAudioFramePosition = 0
            for (rate, channels) in [(48_000.0, AVAudioChannelCount(2)), (16_000.0, 1), (48_000.0, 1)] {
                let inputFormat = try XCTUnwrap(AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: rate,
                    channels: channels, interleaved: false
                ))
                let converter = try RecordingInputConverter(from: inputFormat, to: outputFormat)
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 1_024))
                buffer.frameLength = 1_024
                for channel in 0..<Int(channels) {
                    for frame in 0..<1_024 { buffer.floatChannelData![channel][frame] = 0.25 }
                }
                for _ in 0..<10 {
                    let converted = try converter.convert(buffer)
                    XCTAssertEqual(converted.format, outputFormat)
                    XCTAssertGreaterThan(converted.frameLength, 0)
                    XCTAssertTrue(converted.floatChannelData![0][Int(converted.frameLength) - 1].isFinite)
                    try file?.write(from: converted)
                    totalFrames += AVAudioFramePosition(converted.frameLength)
                }
            }
            file = nil
            let saved = try AVAudioFile(forReading: url)
            XCTAssertEqual(saved.length, totalFrames)
            let expectedDuration = 10 * 1_024 * (2.0 / 48_000 + 1.0 / 16_000)
            XCTAssertEqual(Double(saved.length) / recordingRate, expectedDuration, accuracy: 0.02)
        }
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
        XCTAssertEqual(options, [.defaultToSpeaker, .allowBluetoothHFP])
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
