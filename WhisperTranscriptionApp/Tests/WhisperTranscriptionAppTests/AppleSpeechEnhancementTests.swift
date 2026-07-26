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

        XCTAssertEqual(outputURL.pathExtension.lowercased(), "m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        let asset = AVURLAsset(url: outputURL)
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
