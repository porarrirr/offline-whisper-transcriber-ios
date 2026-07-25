import AVFoundation
import Foundation
import Speech

enum AppleSpeechTranscriptionError: LocalizedError {
    case localeNotSupported
    case assetsNotReady
    case transcriptionUnavailable
    case emptyTranscription

    var errorDescription: String? {
        switch self {
        case .localeNotSupported:
            return String(localized: "This language is not supported by on-device speech recognition.")
        case .assetsNotReady:
            return String(localized: "Speech model could not be prepared automatically.")
        case .transcriptionUnavailable:
            return String(localized: "Speech transcription is not available on this device.")
        case .emptyTranscription:
            return String(localized: "Transcription finished, but no text was produced.")
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .assetsNotReady:
            return String(localized: "Open the app's SpeechTranscriber model manager to prepare this language.")
        case .localeNotSupported, .transcriptionUnavailable, .emptyTranscription:
            return nil
        }
    }
}

@available(iOS 26.0, *)
struct AppleSpeechTranscriptionService {
    func ensureAssetsInstalled(
        for locale: AppleSpeechLocale,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw AppleSpeechTranscriptionError.transcriptionUnavailable
        }

        guard await SpeechAssetCoordinator.shared.isReady(locale: locale) else {
            throw AppleSpeechTranscriptionError.assetsNotReady
        }
        await MainActor.run { onProgress(1) }
    }

    func transcribe(
        inputURL: URL,
        locale: AppleSpeechLocale,
        includeTimestamps: Bool,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws -> ChunkedTranscriptionResult {
        guard SpeechTranscriber.isAvailable else {
            throw AppleSpeechTranscriptionError.transcriptionUnavailable
        }

        try await ensureAssetsInstalled(for: locale) { progress in
            onProgress(progress * 0.2)
        }

        let transcriber = try await makeTranscriber(locale: locale, includeTimestamps: includeTimestamps)
        let naturalFormat = try await AudioConverter.shared.naturalAudioFormatForSpeechInput(inputURL: inputURL)
        guard let compatibleFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber],
            considering: naturalFormat
        ) else {
            throw AudioConverter.AudioConverterError.outputFormatCreationFailed
        }
        AppLogger.info(
            "Apple SpeechTranscriber compatible format selected: source=\(inputURL.lastPathComponent), natural=\(Self.formatDescription(naturalFormat)), compatible=\(Self.formatDescription(compatibleFormat))",
            context: "AppleSpeechTranscriptionService"
        )

        await MainActor.run { onProgress(0.22) }
        let preparedAudio = try await AudioConverter.shared.prepareAudioFileForSpeechTranscriber(
            inputURL: inputURL,
            compatibleFormat: compatibleFormat
        )
        defer {
            if preparedAudio.requiresCleanup {
                try? FileManager.default.removeItem(at: preparedAudio.url)
            }
        }
        let audioFile = try AudioConverter.shared.openAudioFileForSpeechTranscriber(
            at: preparedAudio.url,
            compatibleFormat: compatibleFormat
        )
        let duration = preparedAudio.duration
        AppLogger.info(
            "Apple SpeechTranscriber audio prepared: source=\(inputURL.lastPathComponent), audio=\(preparedAudio.url.lastPathComponent), duration=\(String(format: "%.2f", duration))s, temporary=\(preparedAudio.requiresCleanup)",
            context: "AppleSpeechTranscriptionService"
        )

        await MainActor.run { onProgress(0.4) }

        let collector = ResultCollector(includeTimestamps: includeTimestamps)
        let resultsTask = Task {
            try await collector.collect(from: transcriber.results)
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await analyzer.prepareToAnalyze(in: audioFile.processingFormat)
                AppLogger.info(
                    "Apple SpeechTranscriber analyzer started: audio=\(preparedAudio.url.lastPathComponent), input=bufferSequence, frames=\(audioFile.length), format=\(Self.formatDescription(audioFile.processingFormat))",
                    context: "AppleSpeechTranscriptionService"
                )
                await MainActor.run { onProgress(0.5) }

                let inputSequence = SpeechAudioFileInputSequence(audioFile: audioFile)
                let lastSampleTime = try await analyzer.analyzeSequence(inputSequence)
                try Task.checkCancellation()
                if let lastSampleTime {
                    AppLogger.info(
                        "Apple SpeechTranscriber input consumed: audio=\(preparedAudio.url.lastPathComponent), through=\(Self.timeDescription(lastSampleTime)), expectedDuration=\(String(format: "%.2f", duration))s",
                        context: "AppleSpeechTranscriptionService"
                    )
                    try await analyzer.finalizeAndFinish(through: lastSampleTime)
                } else {
                    AppLogger.error(
                        "Apple SpeechTranscriber consumed no audio samples: audio=\(preparedAudio.url.lastPathComponent), frames=\(audioFile.length), format=\(Self.formatDescription(audioFile.processingFormat))",
                        context: "AppleSpeechTranscriptionService"
                    )
                    await analyzer.cancelAndFinishNow()
                }
            } onCancel: {
                resultsTask.cancel()
                Task {
                    await analyzer.cancelAndFinishNow()
                }
            }
            AppLogger.info(
                "Apple SpeechTranscriber analyzer finished: audio=\(preparedAudio.url.lastPathComponent)",
                context: "AppleSpeechTranscriptionService"
            )
        } catch {
            resultsTask.cancel()
            await analyzer.cancelAndFinishNow()
            AppLogger.error(
                "Apple SpeechTranscriber analyzer failed: audio=\(preparedAudio.url.lastPathComponent), consumedFrames=\(audioFile.framePosition), totalFrames=\(audioFile.length), format=\(Self.formatDescription(audioFile.processingFormat))",
                context: "AppleSpeechTranscriptionService",
                error: error
            )
            throw error
        }

        try Task.checkCancellation()
        let collected = try await resultsTask.value
        AppLogger.info(
            "Apple SpeechTranscriber results collected: audio=\(preparedAudio.url.lastPathComponent), events=\(collected.resultCount), final=\(collected.finalResultCount), nonFinal=\(collected.nonFinalResultCount), nonEmpty=\(collected.nonEmptyResultCount), characters=\(collected.text.count), segments=\(collected.segments.count)",
            context: "AppleSpeechTranscriptionService"
        )
        await MainActor.run { onProgress(1) }

        guard !collected.text.isEmpty else {
            AppLogger.error(
                "Apple SpeechTranscriber produced no final text: audio=\(preparedAudio.url.lastPathComponent), duration=\(String(format: "%.2f", duration))s, frames=\(audioFile.length), format=\(Self.formatDescription(audioFile.processingFormat)), events=\(collected.resultCount), final=\(collected.finalResultCount), nonFinal=\(collected.nonFinalResultCount), nonEmpty=\(collected.nonEmptyResultCount)",
                context: "AppleSpeechTranscriptionService"
            )
            throw AppleSpeechTranscriptionError.emptyTranscription
        }

        return ChunkedTranscriptionResult(
            text: collected.text,
            segments: collected.segments,
            language: locale.locale.language.languageCode?.identifier,
            processedDuration: duration
        )
    }

    private func makeTranscriber(
        locale: AppleSpeechLocale,
        includeTimestamps: Bool
    ) async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable else {
            throw AppleSpeechTranscriptionError.transcriptionUnavailable
        }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale.locale) else {
            throw AppleSpeechTranscriptionError.localeNotSupported
        }
        if includeTimestamps {
            return SpeechTranscriber(
                locale: supported,
                preset: .timeIndexedTranscriptionWithAlternatives
            )
        }
        return SpeechTranscriber(locale: supported, preset: .transcription)
    }

    private static func formatDescription(_ format: AVAudioFormat?) -> String {
        guard let format else { return "unknown" }
        return "\(Int(format.sampleRate))Hz/\(format.channelCount)ch/\(format.commonFormat)/interleaved=\(format.isInterleaved)"
    }

    private static func timeDescription(_ time: CMTime) -> String {
        let seconds = CMTimeGetSeconds(time)
        return seconds.isFinite ? "\(String(format: "%.3f", seconds))s" : "invalid"
    }
}

@available(iOS 26.0, *)
struct SpeechAudioFileInputSequence: AsyncSequence, @unchecked Sendable {
    typealias Element = AnalyzerInput

    struct AsyncIterator: AsyncIteratorProtocol {
        private let audioFile: AVAudioFile
        private let format: AVAudioFormat
        private let frameCapacity: AVAudioFrameCount

        init(audioFile: AVAudioFile, frameCapacity: AVAudioFrameCount) {
            self.audioFile = audioFile
            self.format = audioFile.processingFormat
            self.frameCapacity = frameCapacity
        }

        mutating func next() async throws -> AnalyzerInput? {
            try Task.checkCancellation()

            let startFrame = audioFile.framePosition
            let remainingFrames = audioFile.length - startFrame
            guard remainingFrames > 0 else {
                return nil
            }

            let requestedFrames = AVAudioFrameCount(
                Swift.min(AVAudioFramePosition(frameCapacity), remainingFrames)
            )
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: requestedFrames
            ) else {
                throw AudioConverter.AudioConverterError.bufferCreationFailed
            }

            try audioFile.read(into: buffer, frameCount: requestedFrames)
            guard buffer.frameLength > 0 else {
                throw SpeechAudioFileInputError.unexpectedEndOfFile(
                    expectedFrame: audioFile.length,
                    actualFrame: startFrame
                )
            }

            let timeScale = CMTimeScale(format.sampleRate.rounded())
            let startTime = timeScale > 0
                ? CMTime(value: startFrame, timescale: timeScale)
                : nil
            return AnalyzerInput(buffer: buffer, bufferStartTime: startTime)
        }
    }

    private let audioFile: AVAudioFile
    private let frameCapacity: AVAudioFrameCount

    init(audioFile: AVAudioFile, frameCapacity: AVAudioFrameCount = 8_192) {
        self.audioFile = audioFile
        self.frameCapacity = frameCapacity
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(audioFile: audioFile, frameCapacity: frameCapacity)
    }
}

private enum SpeechAudioFileInputError: LocalizedError {
    case unexpectedEndOfFile(expectedFrame: AVAudioFramePosition, actualFrame: AVAudioFramePosition)

    var errorDescription: String? {
        switch self {
        case .unexpectedEndOfFile(let expectedFrame, let actualFrame):
            return "SpeechTranscriber用音声を終端まで読み込めませんでした（期待フレーム: \(expectedFrame)、実際: \(actualFrame)）"
        }
    }
}

private struct CollectedSpeechResult {
    let text: String
    let segments: [TranscriptionSegment]
    let resultCount: Int
    let finalResultCount: Int
    let nonFinalResultCount: Int
    let nonEmptyResultCount: Int
}

@available(iOS 26.0, *)
private final class ResultCollector: @unchecked Sendable {
    private let includeTimestamps: Bool

    init(includeTimestamps: Bool) {
        self.includeTimestamps = includeTimestamps
    }

    func collect<Results: AsyncSequence>(
        from results: Results
    ) async throws -> CollectedSpeechResult where Results.Element == SpeechTranscriber.Result {
        var attributed = AttributedString()
        var resultCount = 0
        var finalResultCount = 0
        var nonFinalResultCount = 0
        var nonEmptyResultCount = 0
        for try await result in results {
            try Task.checkCancellation()
            resultCount += 1
            if String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                nonEmptyResultCount += 1
            }
            guard result.isFinal else {
                nonFinalResultCount += 1
                continue
            }
            finalResultCount += 1
            attributed.append(result.text)
        }

        let plainText = String(attributed.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        let segments: [TranscriptionSegment]
        if includeTimestamps {
            segments = Self.segments(from: attributed)
        } else {
            segments = []
        }

        return CollectedSpeechResult(
            text: plainText,
            segments: segments,
            resultCount: resultCount,
            finalResultCount: finalResultCount,
            nonFinalResultCount: nonFinalResultCount,
            nonEmptyResultCount: nonEmptyResultCount
        )
    }

    private static func segments(from attributed: AttributedString) -> [TranscriptionSegment] {
        var segments: [TranscriptionSegment] = []
        var segmentID = 0

        for run in attributed.runs {
            let runText = String(attributed[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !runText.isEmpty else { continue }

            let start: Double
            let end: Double
            if let timeRange = run.audioTimeRange {
                start = timeRange.start.seconds
                end = timeRange.end.seconds
            } else {
                start = 0
                end = 0
            }

            segments.append(
                TranscriptionSegment(id: segmentID, start: start, end: end, text: runText)
            )
            segmentID += 1
        }

        if segments.isEmpty, !String(attributed.characters).isEmpty {
            let text = String(attributed.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            segments.append(TranscriptionSegment(id: 0, start: 0, end: 0, text: text))
        }

        return segments
    }
}
