import AVFoundation
import Darwin
import XCTest
@testable import WhisperTranscriptionApp

final class AudioConverterTests: XCTestCase {
    func testChunkConversionDropsFinalOverlapOnlyTail() async throws {
        let audioURL = try makeAudioFile(duration: 2.5, sampleRate: 16_000)
        var chunks: [WhisperAudioChunk] = []

        try await AudioConverter.shared.convertToWhisperChunks(
            inputURL: audioURL,
            sampleRate: 16_000,
            chunkDuration: 1,
            chunkOverlapDuration: 0.25
        ) { chunk in
            chunks.append(chunk)
        }

        XCTAssertEqual(chunks.map(\.index), [0, 1, 2])
        XCTAssertEqual(chunks.map { $0.samples.count }, [16_000, 16_000, 16_000])
        assertStartTimes(chunks, equal: [0, 0.75, 1.5])
        XCTAssertEqual(chunks.last?.totalDuration ?? 0, 2.5, accuracy: 0.001)
    }

    func testChunkConversionEmitsFinalPartialChunkWhenTailIsMoreThanOverlap() async throws {
        let audioURL = try makeAudioFile(duration: 2.4, sampleRate: 16_000)
        var chunks: [WhisperAudioChunk] = []

        try await AudioConverter.shared.convertToWhisperChunks(
            inputURL: audioURL,
            sampleRate: 16_000,
            chunkDuration: 1,
            chunkOverlapDuration: 0.25
        ) { chunk in
            chunks.append(chunk)
        }

        XCTAssertEqual(chunks.map(\.index), [0, 1, 2])
        XCTAssertEqual(chunks.map { $0.samples.count }, [16_000, 16_000, 14_400])
        assertStartTimes(chunks, equal: [0, 0.75, 1.5])
        XCTAssertEqual(chunks.last?.duration ?? 0, 0.9, accuracy: 0.001)
    }

    func testInvalidChunkConfigurationThrowsBeforeReadingInput() async throws {
        do {
            try await AudioConverter.shared.convertToWhisperChunks(
                inputURL: URL(fileURLWithPath: "/definitely/not/audio.caf"),
                sampleRate: 16_000,
                chunkDuration: 1,
                chunkOverlapDuration: 1
            ) { _ in
                XCTFail("No chunk should be emitted for invalid configuration")
            }
            XCTFail("Expected invalidAudioFile")
        } catch {
            guard case AudioConverter.AudioConverterError.invalidAudioFile = error else {
                XCTFail("Expected invalidAudioFile, got \(error)")
                return
            }
        }
    }

    private func makeAudioFile(duration: Double, sampleRate: Double) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperAudioTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("input.caf")
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ))
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        let frameCount = AVAudioFrameCount((duration * sampleRate).rounded())
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])

        for frame in 0..<Int(frameCount) {
            let phase = 2 * Double.pi * 440 * Double(frame) / sampleRate
            samples[frame] = Float(sin(phase) * 0.2)
        }

        try file.write(from: buffer)
        return url
    }

    private func assertStartTimes(
        _ chunks: [WhisperAudioChunk],
        equal expected: [TimeInterval],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(chunks.count, expected.count, file: file, line: line)
        for (chunk, expectedStart) in zip(chunks, expected) {
            XCTAssertEqual(chunk.startTime, expectedStart, accuracy: 0.0001, file: file, line: line)
        }
    }
}
