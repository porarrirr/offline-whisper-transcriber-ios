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

    func testSpeechTranscriberInputSequenceReadsRequestedFormatThroughEnd() async throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("SpeechAnalyzer requires iOS 26")
        }
        let requestedFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ))
        let audioURL = try makeAudioFile(
            duration: 0.25,
            format: requestedFormat
        )

        let standardAudioFile = try AVAudioFile(forReading: audioURL)
        XCTAssertEqual(standardAudioFile.processingFormat.commonFormat, .pcmFormatFloat32)

        let speechAudioFile = try AudioConverter.shared.openAudioFileForSpeechTranscriber(
            at: audioURL,
            compatibleFormat: requestedFormat
        )
        XCTAssertEqual(speechAudioFile.processingFormat.sampleRate, requestedFormat.sampleRate)
        XCTAssertEqual(speechAudioFile.processingFormat.channelCount, requestedFormat.channelCount)
        XCTAssertEqual(speechAudioFile.processingFormat.commonFormat, requestedFormat.commonFormat)
        XCTAssertEqual(speechAudioFile.processingFormat.isInterleaved, requestedFormat.isInterleaved)

        var bufferCount = 0
        var frameCount: AVAudioFramePosition = 0
        let inputSequence = SpeechAudioFileInputSequence(
            audioFile: speechAudioFile,
            frameCapacity: 1_024
        )
        for try await input in inputSequence {
            bufferCount += 1
            frameCount += AVAudioFramePosition(input.buffer.frameLength)
        }

        XCTAssertEqual(bufferCount, 4)
        XCTAssertEqual(frameCount, 4_000)
        XCTAssertEqual(speechAudioFile.framePosition, speechAudioFile.length)
    }

    func testSpeechConversionPreservesContinuousWaveformAcrossReaderPackets() async throws {
        for sampleRate in [44_100.0, 48_000.0] {
            let source = try makeAudioFile(duration: 3.73, sampleRate: sampleRate)
            let format = try XCTUnwrap(AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                channels: 1, interleaved: false
            ))
            let prepared = try await AudioConverter.shared.prepareAudioFileForSpeechTranscriber(
                inputURL: source, compatibleFormat: format
            )
            defer { try? FileManager.default.removeItem(at: prepared.url) }
            let file = try AVAudioFile(forReading: prepared.url)
            XCTAssertEqual(Double(file.length), 3.73 * 16_000, accuracy: 2)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)
            ))
            try file.read(into: buffer)
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            var errorPower = 0.0
            // Exclude only the true file edges, not internal packet boundaries.
            for frame in 160..<(Int(buffer.frameLength) - 160) {
                let expected = 0.2 * sin(2 * Double.pi * 440 * Double(frame) / 16_000)
                errorPower += pow(Double(samples[frame]) - expected, 2)
            }
            XCTAssertLessThan(sqrt(errorPower / Double(Int(buffer.frameLength) - 320)), 0.002)
        }
    }

    func testPreparedSpeechAudioNormalizesQuietInputAndPreservesTimeline() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Requires SpeechAnalyzer") }
        let sourceFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let source = try makeAudioFile(duration: 3, format: sourceFormat, amplitude: 0.01)
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true
        ))
        let prepared = try await AudioConverter.shared.prepareAudioFileForSpeechTranscriber(
            inputURL: source, compatibleFormat: format, preprocessAudio: true
        )
        defer { try? FileManager.default.removeItem(at: prepared.url) }
        let file = try AudioConverter.shared.openAudioFileForSpeechTranscriber(at: prepared.url, compatibleFormat: format)
        var frameCount = 0
        var tailPower = 0.0
        for try await input in SpeechAudioFileInputSequence(audioFile: file, frameCapacity: 137) {
            XCTAssertEqual(input.bufferStartTime?.seconds ?? -1, Double(frameCount) / 16_000, accuracy: 0.00001)
            let buffer = input.buffer
            for index in 0..<Int(buffer.frameLength) {
                if frameCount + index >= 32_000 {
                    let sample = Double(buffer.int16ChannelData![0][index]) / 32_768
                    tailPower += sample * sample
                }
            }
            frameCount += Int(buffer.frameLength)
        }
        XCTAssertEqual(frameCount, 48_000)
        XCTAssertEqual(prepared.duration, 3, accuracy: 0.0001)
        XCTAssertGreaterThan(sqrt(tailPower / 16_000), 0.035)
        XCTAssertLessThan(sqrt(tailPower / 16_000), 0.05)
    }

    func testStreamingSpeechInputIsLazyAndPreservesPCMAndTimestamps() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Requires SpeechAnalyzer") }
        for rate in [44_100.0, 48_000.0] {
            for commonFormat in [AVAudioCommonFormat.pcmFormatFloat32, .pcmFormatInt16] {
                let source = try makeAudioFile(duration: 3.73, sampleRate: rate)
                let format = try XCTUnwrap(AVAudioFormat(
                    commonFormat: commonFormat, sampleRate: 16_000, channels: 1, interleaved: true
                ))
                let prepared = try await AudioConverter.shared.prepareAudioFileForSpeechTranscriber(
                    inputURL: source, compatibleFormat: format, preprocessAudio: true
                )
                defer { try? FileManager.default.removeItem(at: prepared.url) }
                let referenceFile = try AudioConverter.shared.openAudioFileForSpeechTranscriber(at: prepared.url, compatibleFormat: format)
                let session = try await AudioConverter.shared.makeSpeechAudioConversionSession(inputURL: source, compatibleFormat: format)
                XCTAssertEqual(session.writtenFrameCount, 0)
                var iterator = SpeechConvertedAudioInputSequence(session: session).makeAsyncIterator()
                var frameCount = 0
                var retainedFirst: AVAudioPCMBuffer?
                var retainedBytes: Data?
                while true {
                    let actual: AVAudioPCMBuffer
                    if commonFormat == .pcmFormatInt16 {
                        guard let input = try await iterator.next() else { break }
                        actual = input.buffer
                        XCTAssertEqual(input.bufferStartTime?.seconds ?? -1, Double(frameCount) / 16_000, accuracy: 0.000001)
                    } else {
                        // SpeechAnalyzer's input is Int16; verify the general
                        // converter's Float32 support before wrapping in Speech.
                        guard let buffer = try session.nextBuffer() else { break }
                        actual = buffer
                    }
                    XCTAssertEqual(actual.format, format)
                    let reference = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: actual.frameLength))
                    try referenceFile.read(into: reference)
                    XCTAssertEqual(actual.frameLength, reference.frameLength)
                    let a = actual.audioBufferList.pointee.mBuffers
                    let b = reference.audioBufferList.pointee.mBuffers
                    XCTAssertEqual(Data(bytes: a.mData!, count: Int(a.mDataByteSize)), Data(bytes: b.mData!, count: Int(b.mDataByteSize)))
                    if frameCount == 0 {
                        XCTAssertEqual(session.writtenFrameCount, 8_192)
                        retainedFirst = actual
                        retainedBytes = Data(bytes: a.mData!, count: Int(a.mDataByteSize))
                    }
                    frameCount += Int(actual.frameLength)
                }
                XCTAssertEqual(frameCount, Int(referenceFile.length))
                XCTAssertEqual(session.writtenFrameCount, frameCount)
                let afterEnd = try await iterator.next()
                XCTAssertNil(afterEnd)
                let first = try XCTUnwrap(retainedFirst).audioBufferList.pointee.mBuffers
                XCTAssertEqual(Data(bytes: first.mData!, count: Int(first.mDataByteSize)), retainedBytes)
            }
        }
    }

    func testStreamingSpeechConversionHonorsCancellation() async throws {
        let source = try makeAudioFile(duration: 3, sampleRate: 48_000)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let session = try await AudioConverter.shared.makeSpeechAudioConversionSession(inputURL: source, compatibleFormat: format)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try session.nextBuffer()
                XCTFail("Cancelled conversion must not produce audio")
            } catch is CancellationError {
                // Expected: the reader is stopped by nextBuffer's error path.
            }
        }
        try await task.value
        XCTAssertEqual(session.writtenFrameCount, 0)
        XCTAssertNil(try session.nextBuffer())
    }

    private func makeAudioFile(duration: Double, sampleRate: Double) throws -> URL {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ))
        return try makeAudioFile(duration: duration, format: format)
    }

    private func makeAudioFile(duration: Double, format: AVAudioFormat, amplitude: Double = 0.2) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperAudioTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("input.caf")
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        let frameCount = AVAudioFrameCount((duration * format.sampleRate).rounded())
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount

        switch format.commonFormat {
        case .pcmFormatFloat32:
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            for frame in 0..<Int(frameCount) {
                let phase = 2 * Double.pi * 440 * Double(frame) / format.sampleRate
                samples[frame] = Float(sin(phase) * amplitude)
            }
        case .pcmFormatInt16:
            let samples = try XCTUnwrap(buffer.int16ChannelData?[0])
            for frame in 0..<Int(frameCount) {
                let phase = 2 * Double.pi * 440 * Double(frame) / format.sampleRate
                samples[frame] = Int16(sin(phase) * Double(Int16.max) * amplitude)
            }
        default:
            XCTFail("Unsupported test format: \(format.commonFormat)")
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
