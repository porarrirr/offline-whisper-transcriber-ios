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
        let prepared = try await AudioConverter.shared.prepareAudioFileForSpeechTranscriber(
            inputURL: sourceURL, compatibleFormat: analyzerFormat, preprocessAudio: true
        )
        defer { try? FileManager.default.removeItem(at: prepared.url) }
        let asset = AVURLAsset(url: prepared.url)
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

    func testSpeechPreprocessingIsIndependentOfPacketSizeAndPreservesInput() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let samples = (0..<48_000).map { Float(0.01 * sin(2 * Double.pi * 440 * Double($0) / 16_000)) }
        func process(packetSize: Int) throws -> [Float] {
            let processor = SpeechAudioPreprocessor()
            var result: [Float] = []
            for start in stride(from: 0, to: samples.count, by: packetSize) {
                let count = min(packetSize, samples.count - start)
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
                buffer.frameLength = AVAudioFrameCount(count)
                let data = try XCTUnwrap(buffer.floatChannelData?[0])
                for index in 0..<count { data[index] = samples[start + index] }
                let output = try processor.process(buffer)
                XCTAssertEqual(output.frameLength, buffer.frameLength)
                XCTAssertEqual(output.format, buffer.format)
                XCTAssertEqual(data[0], samples[start])
                result += Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: count))
            }
            return result
        }
        let whole = try process(packetSize: samples.count)
        XCTAssertEqual(try process(packetSize: 137), whole)
        let tail = whole.suffix(16_000)
        let rms = sqrt(tail.reduce(0.0) { $0 + Double($1 * $1) } / Double(tail.count))
        XCTAssertGreaterThan(rms, 0.035)
        XCTAssertLessThan(rms, 0.05)
    }

    func testSpeechPreprocessingLimitsClicksLocallyAndLeavesSilenceSilent() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 80_000))
        buffer.frameLength = buffer.frameCapacity
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        samples.initialize(repeating: 0, count: 80_000)
        let silence = try SpeechAudioPreprocessor().process(buffer)
        XCTAssertTrue((0..<80_000).allSatisfy { silence.floatChannelData![0][$0] == 0 })
        for frame in 0..<80_000 {
            samples[frame] = Float(0.01 * sin(2 * Double.pi * 440 * Double(frame) / 16_000))
        }
        samples[48_000] = 1
        let processed = try SpeechAudioPreprocessor().process(buffer)
        let data = try XCTUnwrap(processed.floatChannelData?[0])
        XCTAssertTrue((0..<80_000).allSatisfy { data[$0].isFinite && abs(data[$0]) <= 0.95001 })
        let recoveredRMS = sqrt((64_000..<80_000).reduce(0.0) { $0 + Double(data[$1] * data[$1]) } / 16_000)
        XCTAssertGreaterThan(recoveredRMS, 0.035)
    }

    func testSpeechPreprocessingPreservesInt16StereoChannels() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 2, interleaved: true
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        buffer.frameLength = buffer.frameCapacity
        let data = try XCTUnwrap(buffer.int16ChannelData?[0])
        for frame in 0..<4_800 {
            data[frame * 2] = Int16(1_000 * sin(2 * Double.pi * 440 * Double(frame) / 48_000))
            data[frame * 2 + 1] = -data[frame * 2]
        }
        let result = try SpeechAudioPreprocessor().process(buffer)
        XCTAssertEqual(result.format, format)
        XCTAssertEqual(result.frameLength, 4_800)
        let output = try XCTUnwrap(result.int16ChannelData?[0])
        for frame in 0..<4_800 { XCTAssertEqual(output[frame * 2], -output[frame * 2 + 1]) }
    }

    func testSpeechPreprocessingRejectsNonFiniteAudio() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        buffer.frameLength = 1
        buffer.floatChannelData![0][0] = .nan
        XCTAssertThrowsError(try SpeechAudioPreprocessor().process(buffer))
    }

    func testSpeechPreprocessingMatchesOriginalBitsForEveryPCMLayout() throws {
        for commonFormat in [AVAudioCommonFormat.pcmFormatFloat32, .pcmFormatInt16] {
            for interleaved in [false, true] {
                for channels: AVAudioChannelCount in [1, 2] {
                    let format = try XCTUnwrap(AVAudioFormat(
                        commonFormat: commonFormat, sampleRate: 16_000,
                        channels: channels, interleaved: interleaved
                    ))
                    let original = SpeechAudioPreprocessorReference()
                    let updated = SpeechAudioPreprocessor()
                    var position = 0
                    for count in [1, 137, 8_192, 1_601, 8_192, 13] {
                        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
                        buffer.frameLength = AVAudioFrameCount(count)
                        for frame in 0..<count {
                            for channel in 0..<Int(channels) {
                                let plane = interleaved ? 0 : channel
                                let offset = interleaved ? frame * Int(channels) + channel : frame
                                let value = Float(sin(Double(position + frame) * 0.17)) * (channel == 0 ? 0.01 : 0.3)
                                if commonFormat == .pcmFormatFloat32 {
                                    buffer.floatChannelData![plane][offset] = value
                                } else {
                                    buffer.int16ChannelData![plane][offset] = Int16(value * 32_768)
                                }
                            }
                        }
                        let expected = try original.process(buffer)
                        let actual = try updated.process(buffer)
                        let expectedPlanes = UnsafeMutableAudioBufferListPointer(expected.mutableAudioBufferList)
                        let actualPlanes = UnsafeMutableAudioBufferListPointer(actual.mutableAudioBufferList)
                        for plane in 0..<expectedPlanes.count {
                            XCTAssertEqual(actualPlanes[plane].mDataByteSize, expectedPlanes[plane].mDataByteSize)
                            XCTAssertEqual(memcmp(actualPlanes[plane].mData!, expectedPlanes[plane].mData!, Int(expectedPlanes[plane].mDataByteSize)), 0)
                        }
                        position += count
                    }
                }
            }
        }
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
