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
            return String(localized: "This language is not supported by iOS SpeechTranscriber.")
        case .assetsNotReady:
            return String(localized: "Speech model is not ready. Please download it from settings.")
        case .transcriptionUnavailable:
            return String(localized: "Speech transcription is not available on this device.")
        case .emptyTranscription:
            return String(localized: "Transcription finished, but no text was produced.")
        }
    }
}

@available(iOS 26.0, *)
struct AppleSpeechTranscriptionService {
    func assetsInstalled(for locale: AppleSpeechLocale) async -> Bool {
        guard SpeechTranscriber.isAvailable,
              let transcriber = try? await makeTranscriber(locale: locale, includeTimestamps: false) else {
            return false
        }
        return await AssetInventory.status(forModules: [transcriber]) == .installed
    }

    func ensureAssetsInstalled(
        for locale: AppleSpeechLocale,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw AppleSpeechTranscriptionError.transcriptionUnavailable
        }

        let transcriber = try await makeTranscriber(locale: locale, includeTimestamps: false)
        let status = await AssetInventory.status(forModules: [transcriber])
        if status == .installed {
            await MainActor.run { onProgress(1) }
            return
        }
        if status == .unsupported {
            throw AppleSpeechTranscriptionError.localeNotSupported
        }

        let reservedLocale = transcriber.selectedLocales.first ?? locale.locale
        _ = try await AssetInventory.reserve(locale: reservedLocale)

        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            let refreshed = await AssetInventory.status(forModules: [transcriber])
            if refreshed == .installed {
                await MainActor.run { onProgress(1) }
                return
            }
            throw AppleSpeechTranscriptionError.assetsNotReady
        }

        let progress = request.progress
        let observation = progress.observe(\.fractionCompleted, options: [.initial, .new]) { _, change in
            let value = change.newValue ?? progress.fractionCompleted
            Task { @MainActor in
                onProgress(min(max(value, 0), 1))
            }
        }
        defer { observation.invalidate() }

        try await request.downloadAndInstall()
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
        let preparedAudio = try await AudioConverter.shared.prepareAudioFileForSpeechTranscriber(inputURL: inputURL)
        defer {
            if preparedAudio.requiresCleanup {
                try? FileManager.default.removeItem(at: preparedAudio.url)
            }
        }
        let audioFile = try AVAudioFile(forReading: preparedAudio.url)
        let duration = preparedAudio.duration
        AppLogger.info(
            "Apple SpeechTranscriber audio prepared: source=\(inputURL.lastPathComponent), audio=\(preparedAudio.url.lastPathComponent), duration=\(String(format: "%.2f", duration))s, temporary=\(preparedAudio.requiresCleanup)",
            context: "AppleSpeechTranscriptionService"
        )

        await MainActor.run { onProgress(0.25) }

        let collector = ResultCollector(includeTimestamps: includeTimestamps)
        let resultsTask = Task {
            try await collector.collect(from: transcriber.results)
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile)
        if let lastSampleTime {
            try await analyzer.finalizeAndFinish(through: lastSampleTime)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        let collected = try await resultsTask.value
        await MainActor.run { onProgress(1) }

        guard !collected.text.isEmpty else {
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
}

private struct CollectedSpeechResult {
    let text: String
    let segments: [TranscriptionSegment]
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
        for try await result in results {
            try Task.checkCancellation()
            guard result.isFinal else { continue }
            attributed.append(result.text)
        }

        let plainText = String(attributed.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        let segments: [TranscriptionSegment]
        if includeTimestamps {
            segments = Self.segments(from: attributed)
        } else if plainText.isEmpty {
            segments = []
        } else {
            segments = [TranscriptionSegment(id: 0, start: 0, end: 0, text: plainText)]
        }

        return CollectedSpeechResult(text: plainText, segments: segments)
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
