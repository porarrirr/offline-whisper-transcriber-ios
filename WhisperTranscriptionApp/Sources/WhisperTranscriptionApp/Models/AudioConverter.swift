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

        while reader.status == .reading {
            try Task.checkCancellation()
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                break
            }
            guard let inputBuffer = try makePCMBuffer(from: sampleBuffer) else {
                continue
            }
            try appendConvertedSamples(
                from: inputBuffer,
                outputFormat: whisperOutputFormat,
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

    private func appendConvertedSamples(
        from inputBuffer: AVAudioPCMBuffer,
        outputFormat: AVAudioFormat,
        to samples: inout [Float]
    ) throws {
        guard let converter = AVAudioConverter(from: inputBuffer.format, to: outputFormat) else {
            throw AudioConverterError.converterCreationFailed
        }

        let outputCapacity = AVAudioFrameCount(
            max(
                1024,
                ceil(Double(inputBuffer.frameLength) * outputFormat.sampleRate / inputBuffer.format.sampleRate) + 16
            )
        )
        var hasProvidedInput = false

        while true {
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
                throw AudioConverterError.bufferCreationFailed
            }

            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                if hasProvidedInput {
                    outStatus.pointee = .endOfStream
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

    func prepareAudioFileForSpeechTranscriber(inputURL: URL, sampleRate: Double = 16000) async throws -> PreparedSpeechAudioFile {
        if Self.isVideoFile(inputURL) {
            return try await extractVideoAudioForSpeechTranscriber(inputURL: inputURL, sampleRate: sampleRate)
        }

        let inputFile = try AVAudioFile(forReading: inputURL)
        return PreparedSpeechAudioFile(
            url: inputURL,
            duration: durationForAudioFile(inputFile, inputFormat: inputFile.processingFormat),
            requiresCleanup: false
        )
    }

    private func extractVideoAudioForSpeechTranscriber(inputURL: URL, sampleRate: Double) async throws -> PreparedSpeechAudioFile {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioConverterError.outputFormatCreationFailed
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-audio-\(UUID().uuidString)")
            .appendingPathExtension("caf")
        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: outputFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        var writtenSampleCount = 0
        do {
            try await convertToWhisperChunks(
                inputURL: inputURL,
                sampleRate: sampleRate,
                chunkDuration: 300,
                chunkOverlapDuration: 0
            ) { chunk in
                try Self.write(samples: chunk.samples, format: outputFormat, to: outputFile)
                writtenSampleCount += chunk.samples.count
            }
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }

        guard writtenSampleCount > 0 else {
            try? FileManager.default.removeItem(at: outputURL)
            throw AudioConverterError.emptyAudioFile
        }

        return PreparedSpeechAudioFile(
            url: outputURL,
            duration: Double(writtenSampleCount) / sampleRate,
            requiresCleanup: true
        )
    }

    private static func write(samples: [Float], format: AVAudioFormat, to outputFile: AVAudioFile) throws {
        guard !samples.isEmpty else { return }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw AudioConverterError.bufferCreationFailed
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channelData = buffer.floatChannelData?[0] else {
            throw AudioConverterError.unsupportedPCMFormat
        }
        samples.withUnsafeBufferPointer { pointer in
            channelData.update(from: pointer.baseAddress!, count: samples.count)
        }
        try outputFile.write(from: buffer)
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
        "\(Int(format.sampleRate))Hz/\(format.channelCount)ch/\(format.commonFormat)"
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
            }
        }
    }
}
