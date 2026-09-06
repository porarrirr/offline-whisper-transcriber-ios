import Foundation
import AVFoundation
import UniformTypeIdentifiers

struct WhisperAudioChunk {
    let index: Int
    let startTime: TimeInterval
    let samples: [Float]
    let sampleRate: Double
    let totalDuration: TimeInterval

    var duration: TimeInterval {
        Double(samples.count) / sampleRate
    }
}

struct PreparedSpeechAudioFile {
    let url: URL
    let duration: TimeInterval
    let requiresCleanup: Bool
}

private final class AudioConverterInputState: @unchecked Sendable {
    var reachedEndOfInput = false
    var inputReadError: Error?
    var inputReadPosition: AVAudioFramePosition = 0
}

class AudioConverter {
    static let shared = AudioConverter()

    private init() {}

    func convertToWhisperSamples(inputURL: URL, sampleRate: Double = 16000) async throws -> [Float] {
        var allSamples: [Float] = []
        try await convertToWhisperChunks(inputURL: inputURL, sampleRate: sampleRate, chunkDuration: .greatestFiniteMagnitude, chunkOverlapDuration: 0) { chunk in
            allSamples.append(contentsOf: chunk.samples)
        }
        return allSamples
    }

    func convertToWhisperChunks(
        inputURL: URL,
        sampleRate: Double = 16000,
        chunkDuration: TimeInterval = 300,
        chunkOverlapDuration: TimeInterval = 0,
        onChunk: (WhisperAudioChunk) async throws -> Void
    ) async throws {
        guard sampleRate > 0, chunkDuration > 0, chunkOverlapDuration >= 0, chunkOverlapDuration < chunkDuration else {
            throw AudioConverterError.invalidAudioFile
        }

        if Self.isVideoFile(inputURL) {
            try await convertVideoAudioToWhisperChunks(
                inputURL: inputURL,
                sampleRate: sampleRate,
                chunkDuration: chunkDuration,
                chunkOverlapDuration: chunkOverlapDuration,
                onChunk: onChunk
            )
            return
        }

        try await convertAudioFileToWhisperChunks(
            inputURL: inputURL,
            sampleRate: sampleRate,
            chunkDuration: chunkDuration,
            chunkOverlapDuration: chunkOverlapDuration,
            onChunk: onChunk
        )
    }

    private func convertAudioFileToWhisperChunks(
        inputURL: URL,
        sampleRate: Double,
        chunkDuration: TimeInterval,
        chunkOverlapDuration: TimeInterval,
        onChunk: (WhisperAudioChunk) async throws -> Void
    ) async throws {
        let inputFile = try AVAudioFile(forReading: inputURL)
        let inputFormat = inputFile.processingFormat
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw AudioConverterError.invalidAudioFile
        }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioConverterError.outputFormatCreationFailed
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioConverterError.converterCreationFailed
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering

        let inputCapacity: AVAudioFrameCount = 4096
        let outputCapacity = AVAudioFrameCount(
            max(1024, ceil(Double(inputCapacity) * sampleRate / inputFormat.sampleRate) + 16)
        )

        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputCapacity) else {
            throw AudioConverterError.bufferCreationFailed
        }

        let totalDuration = durationForAudioFile(inputFile, inputFormat: inputFormat)
        let chunkSampleCount = sampleCount(for: chunkDuration, sampleRate: sampleRate)
        let chunkOverlapSampleCount = sampleCount(for: chunkOverlapDuration, sampleRate: sampleRate)
        var pendingSamples: [Float] = []
        if chunkSampleCount < Int.max {
            pendingSamples.reserveCapacity(min(chunkSampleCount + Int(outputCapacity), chunkSampleCount * 2))
        }
        var chunkIndex = 0
        var nextChunkStartSample = 0
        var producedSamples = 0
        let inputState = AudioConverterInputState()
        inputState.inputReadPosition = inputFile.framePosition
        let conversionDetails = Self.conversionDetails(
            inputURL: inputURL,
            inputFormat: inputFormat,
            outputFormat: outputFormat,
            inputFile: inputFile
        )

        AppLogger.info(
            "音声チャンク変換を開始しました: \(conversionDetails), chunkDuration=\(chunkDuration)s",
            context: "AudioConverter"
        )

        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if inputState.reachedEndOfInput {
                outStatus.pointee = .endOfStream
                return nil
            }

            inputState.inputReadPosition = inputFile.framePosition
            if inputFile.length > 0 && inputState.inputReadPosition >= inputFile.length {
                inputState.reachedEndOfInput = true
                outStatus.pointee = .endOfStream
                return nil
            }

            do {
                try inputFile.read(into: inputBuffer)
                if inputBuffer.frameLength == 0 {
                    inputState.reachedEndOfInput = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return inputBuffer
            } catch {
                inputState.inputReadError = error
                outStatus.pointee = .endOfStream
                return nil
            }
        }

        while true {
            try Task.checkCancellation()
            if let inputReadError = inputState.inputReadError {
                throw AudioConverterError.conversionFailed(inputReadError)
            }

            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
                throw AudioConverterError.bufferCreationFailed
            }

            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
            if let inputReadError = inputState.inputReadError {
                throw AudioConverterError.conversionFailed(inputReadError)
            }

            try appendFloatSamples(from: outputBuffer, to: &pendingSamples)
            try await emitReadyChunks(
                from: &pendingSamples,
                chunkSampleCount: chunkSampleCount,
                chunkOverlapSampleCount: chunkOverlapSampleCount,
                sampleRate: sampleRate,
                totalDuration: totalDuration,
                nextChunkStartSample: &nextChunkStartSample,
                chunkIndex: &chunkIndex,
                producedSamples: &producedSamples,
                includeFinalPartialChunk: false,
                onChunk: onChunk
            )

            switch status {
            case .haveData:
                continue
            case .inputRanDry:
                if inputState.reachedEndOfInput && outputBuffer.frameLength == 0 {
                    try await emitFinalChunkOrFail(
                        from: &pendingSamples,
                        chunkOverlapSampleCount: chunkOverlapSampleCount,
                        sampleRate: sampleRate,
                        totalDuration: totalDuration,
                        nextChunkStartSample: &nextChunkStartSample,
                        chunkIndex: &chunkIndex,
                        producedSamples: &producedSamples,
                        conversionDetails: conversionDetails,
                        onChunk: onChunk
                    )
                    return
                }
                continue
            case .endOfStream:
                try await emitFinalChunkOrFail(
                    from: &pendingSamples,
                    chunkOverlapSampleCount: chunkOverlapSampleCount,
                    sampleRate: sampleRate,
                    totalDuration: totalDuration,
                    nextChunkStartSample: &nextChunkStartSample,
                    chunkIndex: &chunkIndex,
                    producedSamples: &producedSamples,
                    conversionDetails: conversionDetails,
                    onChunk: onChunk
                )
                return
            case .error:
                throw AudioConverterError.conversionFailed(error ?? AudioConverterError.conversionEndedUnexpectedly)
            @unknown default:
                throw AudioConverterError.conversionEndedUnexpectedly
            }
        }
    }

    private func convertVideoAudioToWhisperChunks(
        inputURL: URL,
        sampleRate: Double,
        chunkDuration: TimeInterval,
        chunkOverlapDuration: TimeInterval,
        onChunk: (WhisperAudioChunk) async throws -> Void
    ) async throws {
        let asset = AVURLAsset(url: inputURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else {
            AppLogger.error(
                "動画に音声トラックがありません: file=\(inputURL.lastPathComponent)",
                context: "AudioConverter"
            )
            throw AudioConverterError.missingAudioTrack
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true
        ]

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw AudioConverterError.readerOutputCreationFailed
        }
        reader.add(output)

        guard reader.startReading() else {
            throw AudioConverterError.readerFailed(reader.error)
        }

        guard let whisperOutputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioConverterError.outputFormatCreationFailed
        }

        let assetDuration = try await asset.load(.duration)
        let totalDuration = Self.seconds(from: assetDuration)
        let chunkSampleCount = sampleCount(for: chunkDuration, sampleRate: sampleRate)
        let chunkOverlapSampleCount = sampleCount(for: chunkOverlapDuration, sampleRate: sampleRate)
        var pendingSamples: [Float] = []
        if chunkSampleCount < Int.max {
            pendingSamples.reserveCapacity(chunkSampleCount)
        }
        var chunkIndex = 0
        var nextChunkStartSample = 0
        var producedSamples = 0

        AppLogger.info(
            "動画の音声チャンク抽出を開始しました: file=\(inputURL.lastPathComponent), chunkDuration=\(chunkDuration)s",
            context: "AudioConverter"
        )

        var streamConverter: AVAudioConverter?
        while reader.status == .reading {
            try Task.checkCancellation()
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                break
            }
            guard let inputBuffer = try makePCMBuffer(from: sampleBuffer) else {
                continue
            }
            if streamConverter == nil {
                guard let converter = AVAudioConverter(from: inputBuffer.format, to: whisperOutputFormat) else {
                    throw AudioConverterError.converterCreationFailed
                }
                converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
                converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
                streamConverter = converter
            }
            guard let streamConverter, streamConverter.inputFormat == inputBuffer.format else {
                throw AudioConverterError.unsupportedPCMFormat
            }
            try appendConvertedSamples(
                from: inputBuffer,
                converter: streamConverter,
                to: &pendingSamples
            )
            try await emitReadyChunks(
                from: &pendingSamples,
                chunkSampleCount: chunkSampleCount,
                chunkOverlapSampleCount: chunkOverlapSampleCount,
                sampleRate: sampleRate,
                totalDuration: totalDuration,
                nextChunkStartSample: &nextChunkStartSample,
                chunkIndex: &chunkIndex,
                producedSamples: &producedSamples,
                includeFinalPartialChunk: false,
                onChunk: onChunk
            )
        }

        switch reader.status {
        case .completed:
            if let streamConverter {
                try appendConvertedSamples(from: nil, converter: streamConverter, to: &pendingSamples)
            }
            try await emitFinalChunkOrFail(
                from: &pendingSamples,
                chunkOverlapSampleCount: chunkOverlapSampleCount,
                sampleRate: sampleRate,
                totalDuration: totalDuration,
                nextChunkStartSample: &nextChunkStartSample,
                chunkIndex: &chunkIndex,
                producedSamples: &producedSamples,
                conversionDetails: "file=\(inputURL.lastPathComponent)",
                onChunk: onChunk
            )
        case .failed:
            throw AudioConverterError.readerFailed(reader.error)
        case .cancelled:
            throw AudioConverterError.readerCancelled
        default:
            throw AudioConverterError.conversionEndedUnexpectedly
        }
    }

    private func emitFinalChunkOrFail(
        from samples: inout [Float],
        chunkOverlapSampleCount: Int,
        sampleRate: Double,
        totalDuration: TimeInterval,
        nextChunkStartSample: inout Int,
        chunkIndex: inout Int,
        producedSamples: inout Int,
        conversionDetails: String,
        onChunk: (WhisperAudioChunk) async throws -> Void
    ) async throws {
        if chunkIndex > 0 && samples.count <= chunkOverlapSampleCount {
            samples.removeAll(keepingCapacity: true)
            AppLogger.info(
                "音声チャンク変換が完了しました: \(conversionDetails), samples=\(producedSamples), chunks=\(chunkIndex), duration=\(Self.sampleDuration(producedSamples, sampleRate: sampleRate))",
                context: "AudioConverter"
            )
            return
        }

        try await emitReadyChunks(
            from: &samples,
            chunkSampleCount: sampleCount(for: .greatestFiniteMagnitude, sampleRate: sampleRate),
            chunkOverlapSampleCount: 0,
            sampleRate: sampleRate,
            totalDuration: totalDuration,
            nextChunkStartSample: &nextChunkStartSample,
            chunkIndex: &chunkIndex,
            producedSamples: &producedSamples,
            includeFinalPartialChunk: true,
            onChunk: onChunk
        )
        guard producedSamples > 0 else {
            AppLogger.error("音声変換結果が空です: \(conversionDetails)", context: "AudioConverter")
            throw AudioConverterError.emptyAudioFile
        }
        AppLogger.info(
            "音声チャンク変換が完了しました: \(conversionDetails), samples=\(producedSamples), chunks=\(chunkIndex), duration=\(Self.sampleDuration(producedSamples, sampleRate: sampleRate))",
            context: "AudioConverter"
        )
    }

    private func emitReadyChunks(
        from samples: inout [Float],
        chunkSampleCount: Int,
        chunkOverlapSampleCount: Int,
        sampleRate: Double,
        totalDuration: TimeInterval,
        nextChunkStartSample: inout Int,
        chunkIndex: inout Int,
        producedSamples: inout Int,
        includeFinalPartialChunk: Bool,
        onChunk: (WhisperAudioChunk) async throws -> Void
    ) async throws {
        while samples.count >= chunkSampleCount || (includeFinalPartialChunk && !samples.isEmpty) {
            let emittedCount = min(samples.count, chunkSampleCount)
            let chunkSamples = Array(samples.prefix(emittedCount))
            let chunk = WhisperAudioChunk(
                index: chunkIndex,
                startTime: Double(nextChunkStartSample) / sampleRate,
                samples: chunkSamples,
                sampleRate: sampleRate,
                totalDuration: totalDuration
            )
            try await onChunk(chunk)
            let retainedCount = includeFinalPartialChunk ? 0 : min(chunkOverlapSampleCount, emittedCount)
            let removedCount = emittedCount - retainedCount
            samples.removeFirst(removedCount)
            chunkIndex += 1
            producedSamples = max(producedSamples, nextChunkStartSample + emittedCount)
            nextChunkStartSample += removedCount
        }
    }

    private func makePCMBuffer(from sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let format = AVAudioFormat(streamDescription: streamDescription) else {
            throw AudioConverterError.invalidAudioFile
        }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else {
            return nil
        }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw AudioConverterError.bufferCreationFailed
        }
        pcmBuffer.frameLength = frameCount

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        )
        guard status == noErr else {
            throw AudioConverterError.sampleBufferCopyFailed(status)
        }

        guard format.commonFormat == .pcmFormatFloat32 else {
            throw AudioConverterError.unsupportedPCMFormat
        }

        return pcmBuffer
    }

    func appendConvertedSamples(
        from inputBuffer: AVAudioPCMBuffer?,
        converter: AVAudioConverter,
        to samples: inout [Float]
    ) throws {
        let outputFormat = converter.outputFormat
        let outputCapacity = AVAudioFrameCount(4096)
        var hasProvidedInput = false

        while true {
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
                throw AudioConverterError.bufferCreationFailed
            }

            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                if inputBuffer == nil || hasProvidedInput {
                    outStatus.pointee = inputBuffer == nil ? .endOfStream : .noDataNow
                    return nil
                }

                hasProvidedInput = true
                outStatus.pointee = .haveData
                return inputBuffer
            }

            try appendFloatSamples(from: outputBuffer, to: &samples)

            switch status {
            case .haveData:
                continue
            case .inputRanDry, .endOfStream:
                return
            case .error:
                throw AudioConverterError.conversionFailed(error ?? AudioConverterError.conversionEndedUnexpectedly)
            @unknown default:
                throw AudioConverterError.conversionEndedUnexpectedly
            }
        }
    }

    private func appendFloatSamples(from pcmBuffer: AVAudioPCMBuffer, to samples: inout [Float]) throws {
        guard pcmBuffer.frameLength > 0 else {
            return
        }
        guard pcmBuffer.format.commonFormat == .pcmFormatFloat32 else {
            throw AudioConverterError.unsupportedPCMFormat
        }

        let frameLength = Int(pcmBuffer.frameLength)
        guard let channelData = pcmBuffer.floatChannelData?[0] else {
            throw AudioConverterError.unsupportedPCMFormat
        }
        samples.append(contentsOf: UnsafeBufferPointer(start: channelData, count: frameLength))
    }

    func getAudioDuration(url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let duration = Self.seconds(from: try await asset.load(.duration))
        return duration
    }

    func naturalAudioFormatForSpeechInput(inputURL: URL) async throws -> AVAudioFormat? {
        let asset = AVURLAsset(url: inputURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else {
            return nil
        }
        let formatDescriptions = try await audioTrack.load(.formatDescriptions)
        for formatDescription in formatDescriptions {
            guard let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
                continue
            }
            return AVAudioFormat(streamDescription: streamDescription)
        }
        return nil
    }

    func prepareAudioFileForSpeechTranscriber(
        inputURL: URL,
        compatibleFormat: AVAudioFormat,
        preprocessAudio: Bool = false
    ) async throws -> PreparedSpeechAudioFile {
        guard compatibleFormat.commonFormat != .otherFormat else {
            throw AudioConverterError.outputFormatCreationFailed
        }

        let asset = AVURLAsset(url: inputURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let audioTrack = audioTracks.first else {
            AppLogger.error(
                "Apple SpeechTranscriber入力に音声トラックがありません: file=\(inputURL.lastPathComponent), videoTracks=\(videoTracks.count)",
                context: "AudioConverter"
            )
            throw AudioConverterError.missingAudioTrack
        }

        AppLogger.info(
            "Apple SpeechTranscriber音声準備を開始しました: file=\(inputURL.lastPathComponent), audioTracks=\(audioTracks.count), videoTracks=\(videoTracks.count), output=\(Self.formatDescription(compatibleFormat))",
            context: "AudioConverter"
        )

        return try await extractAssetAudioForSpeechTranscriber(
            asset: asset,
            audioTrack: audioTrack,
            inputURL: inputURL,
            outputFormat: compatibleFormat,
            preprocessAudio: preprocessAudio
        )
    }

    func openAudioFileForSpeechTranscriber(
        at url: URL,
        compatibleFormat: AVAudioFormat
    ) throws -> AVAudioFile {
        let audioFile = try AVAudioFile(
            forReading: url,
            commonFormat: compatibleFormat.commonFormat,
            interleaved: compatibleFormat.isInterleaved
        )
        let actualFormat = audioFile.processingFormat
        guard Self.matchesSpeechTranscriberFormat(actualFormat, compatibleFormat) else {
            let expected = Self.formatDescription(compatibleFormat)
            let actual = Self.formatDescription(actualFormat)
            AppLogger.error(
                "Apple SpeechTranscriber入力形式が互換形式と一致しません: file=\(url.lastPathComponent), expected=\(expected), actual=\(actual)",
                context: "AudioConverter"
            )
            throw AudioConverterError.speechTranscriberFormatMismatch(
                expected: expected,
                actual: actual
            )
        }
        return audioFile
    }

    /// Creates one pull-based conversion stream. The converter and level
    /// conditioner retain their state until the real end of the asset.
    func makeSpeechAudioConversionSession(
        inputURL: URL,
        compatibleFormat: AVAudioFormat,
        preprocessAudio: Bool = true
    ) async throws -> SpeechAudioConversionSession {
        let asset = AVURLAsset(url: inputURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw AudioConverterError.missingAudioTrack }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw AudioConverterError.emptyAudioFile }
        try Task.checkCancellation()
        return try SpeechAudioConversionSession(
            asset: asset, track: track, outputFormat: compatibleFormat,
            preprocessAudio: preprocessAudio, duration: duration
        )
    }

    private func extractAssetAudioForSpeechTranscriber(
        asset: AVURLAsset,
        audioTrack: AVAssetTrack,
        inputURL: URL,
        outputFormat: AVAudioFormat,
        preprocessAudio: Bool
    ) async throws -> PreparedSpeechAudioFile {
        let duration = try await asset.load(.duration).seconds
        let session = try SpeechAudioConversionSession(
            asset: asset, track: audioTrack, outputFormat: outputFormat,
            preprocessAudio: preprocessAudio, duration: duration
        )
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-audio-\(UUID().uuidString)")
            .appendingPathExtension("caf")
        do {
            let outputFile = try AVAudioFile(
                forWriting: outputURL, settings: outputFormat.settings,
                commonFormat: outputFormat.commonFormat,
                interleaved: outputFormat.isInterleaved
            )
            while let buffer = try session.nextBuffer() {
                try outputFile.write(from: buffer)
            }
            guard session.writtenFrameCount > 0 else { throw AudioConverterError.emptyAudioFile }
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
        return PreparedSpeechAudioFile(
            url: outputURL,
            duration: Double(session.writtenFrameCount) / outputFormat.sampleRate,
            requiresCleanup: true
        )
    }

    /// Single-consumer stream with bounded storage. No background producer or
    /// unbounded queue: decoding advances only when the analyzer requests audio.
    final class SpeechAudioConversionSession {
        let outputFormat: AVAudioFormat
        let duration: TimeInterval
        private(set) var writtenFrameCount = 0
        private let reader: AVAssetReader
        private let trackOutput: AVAssetReaderTrackOutput
        private let converter: AVAudioConverter
        private let inputFormat: AVAudioFormat
        private let preprocessor: SpeechAudioPreprocessor?
        private var pendingBuffer: AVAudioPCMBuffer?
        private var reachedEnd = false
        private var finished = false
        private var signalSampleCount = 0
        private var signalSquareSum = 0.0
        private var signalPeak = 0.0

        init(
            asset: AVAsset, track: AVAssetTrack, outputFormat: AVAudioFormat,
            preprocessAudio: Bool, duration: TimeInterval
        ) throws {
            guard outputFormat.commonFormat != .otherFormat else {
                throw AudioConverterError.outputFormatCreationFailed
            }
            self.outputFormat = outputFormat
            self.duration = duration
            preprocessor = preprocessAudio ? SpeechAudioPreprocessor() : nil
            reader = try AVAssetReader(asset: asset)
            trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: true
            ])
            trackOutput.alwaysCopiesSampleData = false
            guard reader.canAdd(trackOutput) else { throw AudioConverterError.readerOutputCreationFailed }
            reader.add(trackOutput)
            guard reader.startReading() else { throw AudioConverterError.readerFailed(reader.error) }
            do {
                var firstBuffer: AVAudioPCMBuffer?
                while firstBuffer == nil, let sample = trackOutput.copyNextSampleBuffer() {
                    try Task.checkCancellation()
                    firstBuffer = try AudioConverter.shared.makePCMBuffer(from: sample)
                }
                guard let firstBuffer else {
                    if reader.status == .failed { throw AudioConverterError.readerFailed(reader.error) }
                    throw AudioConverterError.emptyAudioFile
                }
                inputFormat = firstBuffer.format
                pendingBuffer = firstBuffer
                guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                    throw AudioConverterError.converterCreationFailed
                }
                self.converter = converter
                converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
                converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            } catch {
                reader.cancelReading()
                throw error
            }
        }

        deinit { reader.cancelReading() }

        func nextBuffer() throws -> AVAudioPCMBuffer? {
            do {
                return try readNextBuffer()
            } catch {
                finished = true
                reader.cancelReading()
                throw error
            }
        }

        private func readNextBuffer() throws -> AVAudioPCMBuffer? {
            try Task.checkCancellation()
            guard !finished else { return nil }
            while true {
                // Each returned buffer owns its samples, even when the consumer
                // retains an earlier input. Frame boundaries stay at 8192.
                guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 8_192) else {
                    throw AudioConverterError.bufferCreationFailed
                }
                var inputError: Error?
                var conversionError: NSError?
                let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
                    if self.reachedEnd {
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    do {
                        try Task.checkCancellation()
                        let buffer: AVAudioPCMBuffer?
                        if let pending = self.pendingBuffer {
                            buffer = pending
                            self.pendingBuffer = nil
                        } else {
                            buffer = try self.readInputBuffer()
                        }
                        guard let buffer else {
                            self.reachedEnd = true
                            outStatus.pointee = .endOfStream
                            return nil
                        }
                        guard buffer.format == self.inputFormat else { throw AudioConverterError.invalidAudioFile }
                        AudioConverter.accumulateSignalStatistics(
                            from: buffer, sampleCount: &self.signalSampleCount,
                            squareSum: &self.signalSquareSum, peak: &self.signalPeak
                        )
                        outStatus.pointee = .haveData
                        return buffer
                    } catch {
                        inputError = error
                        self.reachedEnd = true
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                }
                if let inputError { throw inputError }
                switch status {
                case .haveData: break
                case .endOfStream:
                    guard reader.status == .completed else {
                        if reader.status == .failed { throw AudioConverterError.readerFailed(reader.error) }
                        if reader.status == .cancelled { throw AudioConverterError.readerCancelled }
                        throw AudioConverterError.conversionEndedUnexpectedly
                    }
                    finished = true
                case .inputRanDry: throw AudioConverterError.conversionEndedUnexpectedly
                case .error:
                    throw AudioConverterError.conversionFailed(conversionError ?? AudioConverterError.conversionEndedUnexpectedly)
                @unknown default: throw AudioConverterError.conversionEndedUnexpectedly
                }
                try Task.checkCancellation()
                let prepared = output.frameLength > 0 ? try preprocessor.map { try $0.process(output) } ?? output : nil
                writtenFrameCount += Int(prepared?.frameLength ?? 0)
                if finished {
                    guard writtenFrameCount > 0 else { throw AudioConverterError.emptyAudioFile }
                    let rms = signalSampleCount > 0 ? sqrt(signalSquareSum / Double(signalSampleCount)) : 0
                    AppLogger.info(
                        "Apple SpeechTranscriber conversion completed: frames=\(writtenFrameCount), format=\(AudioConverter.formatDescription(outputFormat)), signalSamples=\(signalSampleCount), rms=\(AudioConverter.decibelDescription(rms))dBFS, peak=\(AudioConverter.decibelDescription(signalPeak))dBFS, preprocessed=\(preprocessor != nil)",
                        context: "AudioConverter"
                    )
                }
                if let prepared { return prepared }
                if finished { return nil }
            }
        }

        private func readInputBuffer() throws -> AVAudioPCMBuffer? {
            while reader.status == .reading {
                try Task.checkCancellation()
                guard let sample = trackOutput.copyNextSampleBuffer() else { return nil }
                if let buffer = try AudioConverter.shared.makePCMBuffer(from: sample) { return buffer }
            }
            return nil
        }
    }

    private static func seconds(from time: CMTime) -> Double {
        let duration = CMTimeGetSeconds(time)
        return duration.isFinite && duration > 0 ? duration : 0
    }

    private func durationForAudioFile(_ inputFile: AVAudioFile, inputFormat: AVAudioFormat) -> TimeInterval {
        guard inputFormat.sampleRate > 0 else { return 0 }
        return Double(inputFile.length) / inputFormat.sampleRate
    }

    private func sampleCount(for duration: TimeInterval, sampleRate: Double) -> Int {
        if duration == .greatestFiniteMagnitude {
            return Int.max
        }
        return max(0, Int((duration * sampleRate).rounded(.up)))
    }

    private static func conversionDetails(
        inputURL: URL,
        inputFormat: AVAudioFormat,
        outputFormat: AVAudioFormat,
        inputFile: AVAudioFile
    ) -> String {
        "url=\(inputURL.lastPathComponent), input=\(formatDescription(inputFormat)), output=\(formatDescription(outputFormat)), length=\(inputFile.length)"
    }

    private static func formatDescription(_ format: AVAudioFormat) -> String {
        "\(Int(format.sampleRate))Hz/\(format.channelCount)ch/\(format.commonFormat)/interleaved=\(format.isInterleaved)"
    }

    private static func matchesSpeechTranscriberFormat(
        _ actual: AVAudioFormat,
        _ expected: AVAudioFormat
    ) -> Bool {
        abs(actual.sampleRate - expected.sampleRate) < 0.5
            && actual.channelCount == expected.channelCount
            && actual.commonFormat == expected.commonFormat
            && actual.isInterleaved == expected.isInterleaved
    }

    private static func accumulateSignalStatistics(
        from buffer: AVAudioPCMBuffer,
        sampleCount: inout Int,
        squareSum: inout Double,
        peak: inout Double
    ) {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              let channelData = buffer.floatChannelData else {
            return
        }

        let frameLength = Int(buffer.frameLength)
        let sampleStride = 32
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = channelData[channel]
            for frame in stride(from: 0, to: frameLength, by: sampleStride) {
                let magnitude = abs(Double(samples[frame]))
                squareSum += magnitude * magnitude
                peak = max(peak, magnitude)
                sampleCount += 1
            }
        }
    }

    private static func decibelDescription(_ amplitude: Double) -> String {
        guard amplitude > 0 else { return "-inf" }
        return String(format: "%.1f", 20 * log10(amplitude))
    }

    private static func sampleDuration(_ sampleCount: Int, sampleRate: Double) -> String {
        String(format: "%.2fs", Double(sampleCount) / sampleRate)
    }

    private static func isVideoFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            return false
        }
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }

    enum AudioConverterError: LocalizedError {
        case outputFormatCreationFailed
        case bufferCreationFailed
        case converterCreationFailed
        case invalidAudioFile
        case emptyAudioFile
        case missingAudioTrack
        case readerOutputCreationFailed
        case readerCancelled
        case readerFailed(Error?)
        case sampleBufferCopyFailed(OSStatus)
        case unsupportedPCMFormat
        case conversionFailed(Error)
        case conversionEndedUnexpectedly
        case speechTranscriberFormatMismatch(expected: String, actual: String)

        var errorDescription: String? {
            switch self {
            case .outputFormatCreationFailed:
                return "Whisper用の16kHz/mono PCM形式を作成できませんでした"
            case .bufferCreationFailed:
                return "音声変換用バッファを作成できませんでした"
            case .converterCreationFailed:
                return "音声コンバーターを作成できませんでした"
            case .invalidAudioFile:
                return "音声ファイルのチャンネル情報が不正です"
            case .emptyAudioFile:
                return "音声データが空です"
            case .missingAudioTrack:
                return "動画に音声トラックがありません"
            case .readerOutputCreationFailed:
                return "動画の音声トラックを読み込む準備ができませんでした"
            case .readerCancelled:
                return "動画の音声読み込みがキャンセルされました"
            case .readerFailed(let error):
                if let error {
                    let nsError = error as NSError
                    return "動画の音声読み込みに失敗しました: \(nsError.localizedDescription)（domain: \(nsError.domain), code: \(nsError.code)）"
                }
                return "動画の音声読み込みに失敗しました"
            case .sampleBufferCopyFailed(let status):
                return "動画の音声データを読み取れませんでした（OSStatus: \(status)）"
            case .unsupportedPCMFormat:
                return "対応していないPCM形式です"
            case .conversionFailed(let error):
                let nsError = error as NSError
                return "音声変換に失敗しました: \(nsError.localizedDescription)（domain: \(nsError.domain), code: \(nsError.code)）"
            case .conversionEndedUnexpectedly:
                return "音声変換が予期せず終了しました"
            case .speechTranscriberFormatMismatch(let expected, let actual):
                return "SpeechTranscriber用音声形式が一致しません（期待: \(expected)、実際: \(actual)）"
            }
        }
    }
}
