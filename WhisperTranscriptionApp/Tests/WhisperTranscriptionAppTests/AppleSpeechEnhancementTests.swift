import AVFoundation
import Speech
import XCTest
@testable import WhisperTranscriptionApp

final class AppleSpeechEnhancementTests: XCTestCase {
    func testAppleSpeechConfigurationUsesLowVADAndLiveAlternatives() throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("SpeechAnalyzer enhancements require iOS 26")
        }

        XCTAssertEqual(AppleSpeechModuleFactory.vadSensitivity, .low)
        XCTAssertTrue(
            AppleSpeechModuleFactory.livePreset.reportingOptions.contains(
                .alternativeTranscriptions
            )
        )
        XCTAssertTrue(
            AppleSpeechModuleFactory.livePreset.reportingOptions.contains(
                .volatileResults
            )
        )
        XCTAssertTrue(
            AppleSpeechModuleFactory.livePreset.attributeOptions.contains(
                .audioTimeRange
            )
        )
    }

    func testIOS27AnalyzerInputConverterConvertsAndFlushesTimedLiveAudio() throws {
        guard #available(iOS 27.0, *) else {
            throw XCTSkip("AnalyzerInputConverter requires iOS 27")
        }

        let inputFormat = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 1
        ))
        let analyzerFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ))
        let frameCount: AVAudioFrameCount = 4_800
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: frameCount
        ))
        buffer.frameLength = frameCount
        if let samples = buffer.floatChannelData?[0] {
            for frame in 0..<Int(frameCount) {
                samples[frame] = sin(Float(frame) * 0.05) * 0.2
            }
        }

        let converter = SystemLiveAnalyzerInputConverter(
            converter: AnalyzerInputConverter(analyzerFormat: analyzerFormat)
        )
        let audioTime = AVAudioTime(sampleTime: 48_000, atRate: inputFormat.sampleRate)
        let inputs = try converter.convert(buffer, at: audioTime) + converter.flush()

        XCTAssertFalse(inputs.isEmpty)
        XCTAssertTrue(inputs.allSatisfy {
            $0.bufferFormat.sampleRate == analyzerFormat.sampleRate
                && $0.bufferFormat.channelCount == analyzerFormat.channelCount
        })
        let firstStartTime = try XCTUnwrap(inputs.first?.bufferStartTime?.seconds)
        XCTAssertEqual(firstStartTime, 1, accuracy: 0.001)
        let convertedDuration = inputs.reduce(0) { $0 + $1.bufferDuration.seconds }
        XCTAssertEqual(convertedDuration, 0.1, accuracy: 0.01)
    }

    func testIOS27AssetInputSequenceProviderReadsAssetDirectly() async throws {
        guard #available(iOS 27.0, *) else {
            throw XCTSkip("AssetInputSequenceProvider requires iOS 27")
        }

        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("asset-provider-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        try makeSilentM4A(at: sourceURL, duration: 0.25)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: sourceURL)
        }

        let analyzerFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ))
        let asset = AVURLAsset(url: sourceURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audioTrack = try XCTUnwrap(audioTracks.first)
        let provider = AssetInputSequenceProvider(
            asset: asset,
            track: audioTrack,
            analyzerFormat: analyzerFormat
        )

        var inputCount = 0
        var totalDuration: TimeInterval = 0
        for try await input in provider.analyzerInputs {
            inputCount += 1
            totalDuration += input.bufferDuration.seconds
            XCTAssertEqual(input.bufferFormat.sampleRate, analyzerFormat.sampleRate)
            XCTAssertEqual(input.bufferFormat.channelCount, analyzerFormat.channelCount)
            XCTAssertEqual(input.bufferFormat.commonFormat, analyzerFormat.commonFormat)
        }

        XCTAssertGreaterThan(inputCount, 0)
        XCTAssertEqual(totalDuration, 0.25, accuracy: 0.02)
    }

    func testAudioPlayerSeekClampsToPreparedDuration() {
        let player = AudioPlayer()
        player.duration = 10

        player.seek(to: -2)
        XCTAssertEqual(player.currentTime, 0)

        player.seek(to: 12)
        XCTAssertEqual(player.currentTime, 10)
    }

    @MainActor
    func testAudioPlayerPausePreservesCurrentPosition() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pause-position-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        try makeSilentM4A(at: sourceURL, duration: 2)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: sourceURL)
        }

        let player = AudioPlayer()
        player.prepare(url: sourceURL)
        player.play(from: 0.5)
        try await Task.sleep(for: .milliseconds(150))
        player.pause()

        let pausedTime = player.currentTime
        XCTAssertGreaterThan(pausedTime, 0.4)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(player.currentTime, pausedTime, accuracy: 0.01)
        XCTAssertFalse(player.isPlaying)
    }

    /// `@Observable`へ移行しても再生位置の変更通知が届くこと。
    /// これが壊れると`AudioPlaybackPanel`のSliderとタイムコードが固まる。
    @MainActor
    func testAudioPlayerCurrentTimeChangeIsObservable() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("observation-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        try makeSilentM4A(at: sourceURL, duration: 2)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: sourceURL)
        }

        let player = AudioPlayer()
        player.prepare(url: sourceURL)

        let changed = expectation(description: "currentTime observation fires")
        withObservationTracking {
            _ = player.currentTime
        } onChange: {
            changed.fulfill()
        }

        player.play()
        await fulfillment(of: [changed], timeout: 1)
        player.stop()
    }

    func testImportedAudioStorePersistsPlayableM4A() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-source-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        try makeSilentM4A(at: sourceURL)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: sourceURL)
        }

        let outputURL = try await ImportedAudioStore.shared.persistAudio(from: sourceURL)
        defer {
            Task {
                await ImportedAudioStore.shared.removePersistedAudio(at: outputURL)
            }
        }
        let storedPath = try RecordingFileReference.storedPath(for: outputURL)
        try FileManager.default.removeItem(at: sourceURL)
        let resolvedOutputURL = try RecordingFileReference.fileURL(for: storedPath)

        XCTAssertEqual(outputURL.pathExtension.lowercased(), "m4a")
        XCTAssertEqual(resolvedOutputURL, outputURL.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolvedOutputURL.path))
        let asset = AVURLAsset(url: resolvedOutputURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertFalse(audioTracks.isEmpty)
    }

    private func makeSilentM4A(at url: URL, duration: TimeInterval = 0.25) throws {
        let sampleRate = 44_100.0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(sampleRate * duration)
              ) else {
            XCTFail("Failed to create test audio buffer")
            return
        }
        buffer.frameLength = buffer.frameCapacity
        if let samples = buffer.floatChannelData?[0] {
            samples.initialize(repeating: 0, count: Int(buffer.frameLength))
        }
        try file.write(from: buffer)
    }
}
