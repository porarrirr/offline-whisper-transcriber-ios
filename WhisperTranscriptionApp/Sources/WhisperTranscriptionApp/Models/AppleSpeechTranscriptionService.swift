import AVFoundation
import Foundation
import Speech

enum AppleSpeechTranscriptionError: LocalizedError {
    case localeNotSupported
    case assetsNotReady
    case reservationUpdateFailed(maximum: Int)
    case transcriptionUnavailable
    case emptyTranscription

    var errorDescription: String? {
        switch self {
        case .localeNotSupported:
            return String(localized: "This language is not supported by on-device speech recognition.")
        case .assetsNotReady:
            return String(localized: "Speech model could not be prepared automatically.")
        case .reservationUpdateFailed(let maximum):
            return String(
                format: String(localized: "Could not update the speech model language slot (this device allows up to %lld)."),
                maximum
            )
        case .transcriptionUnavailable:
            return String(localized: "Speech transcription is not available on this device.")
        case .emptyTranscription:
            return String(localized: "Transcription finished, but no text was produced.")
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .assetsNotReady:
            return String(localized: "Connect to Wi-Fi, then tap Retry. If the problem continues, restart the app and try again.")
        case .reservationUpdateFailed:
            return String(localized: "Tap Retry. If the problem continues, restart the app and try again.")
        case .localeNotSupported, .transcriptionUnavailable, .emptyTranscription:
            return nil
        }
    }
}

enum AppleSpeechReservationPolicy {
    static func releaseIndexes(
        reservedEquivalentLocales: [AppleSpeechLocale?],
        keeping target: AppleSpeechLocale
    ) -> [Int] {
        var keptTarget = false
        return reservedEquivalentLocales.indices.filter { index in
            guard reservedEquivalentLocales[index] == target, !keptTarget else {
                return true
            }
            keptTarget = true
            return false
        }
    }
}

enum AppleSpeechDownloadPresentation {
    static let waitingThresholdSeconds: TimeInterval = 10

    static func isWaitingForSystem(progress: Double, elapsedSeconds: TimeInterval) -> Bool {
        progress <= 0 && elapsedSeconds >= waitingThresholdSeconds
    }
}

@available(iOS 26.0, *)
actor AppleSpeechAssetReservationManager {
    static let shared = AppleSpeechAssetReservationManager()
    private var desiredLocale: AppleSpeechLocale?

    /// This app uses one SpeechTranscriber locale at a time. Keep that reservation and
    /// release every stale reservation before requesting another asset installation.
    func reserveExclusively(_ locale: Locale) async throws {
        try Task.checkCancellation()

        let target = AppleSpeechLocale(locale: locale)
        desiredLocale = target
        let reservedLocales = await AssetInventory.reservedLocales
        try ensureStillDesired(target)
        var equivalentLocales: [AppleSpeechLocale?] = []

        for reservedLocale in reservedLocales {
            try Task.checkCancellation()
            let equivalentLocale = await SpeechTranscriber.supportedLocale(equivalentTo: reservedLocale)
            try ensureStillDesired(target)
            equivalentLocales.append(equivalentLocale.map { AppleSpeechLocale(locale: $0) })
        }

        let releaseIndexes = AppleSpeechReservationPolicy.releaseIndexes(
            reservedEquivalentLocales: equivalentLocales,
            keeping: target
        )
        for index in releaseIndexes {
            try Task.checkCancellation()
            _ = await AssetInventory.release(reservedLocale: reservedLocales[index])
            try ensureStillDesired(target)
        }

        guard releaseIndexes.count == reservedLocales.count else { return }

        do {
            _ = try await AssetInventory.reserve(locale: locale)
            try ensureStillDesired(target)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            AppLogger.error(
                "Failed to reserve the selected SpeechTranscriber locale \(locale.identifier)",
                context: "AppleSpeechAssetReservationManager",
                error: error
            )
            throw AppleSpeechTranscriptionError.reservationUpdateFailed(
                maximum: AssetInventory.maximumReservedLocales
            )
        }
    }

    func releaseAll() async {
        desiredLocale = nil
        let reservedLocales = await AssetInventory.reservedLocales
        guard desiredLocale == nil else { return }
        for locale in reservedLocales {
            guard desiredLocale == nil else { return }
            _ = await AssetInventory.release(reservedLocale: locale)
        }
    }

    private func ensureStillDesired(_ locale: AppleSpeechLocale) throws {
        guard desiredLocale == locale else { throw CancellationError() }
    }
}

@available(iOS 26.0, *)
struct AppleSpeechTranscriptionService {
    func assetsInstalled(for locale: AppleSpeechLocale) async throws -> Bool {
        guard SpeechTranscriber.isAvailable else {
            throw AppleSpeechTranscriptionError.transcriptionUnavailable
        }
        let transcriber = try await makeTranscriber(locale: locale, includeTimestamps: false)
        let reservedLocale = transcriber.selectedLocales.first ?? locale.locale
        try await AppleSpeechAssetReservationManager.shared.reserveExclusively(reservedLocale)
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
        let reservedLocale = transcriber.selectedLocales.first ?? locale.locale
        try await AppleSpeechAssetReservationManager.shared.reserveExclusively(reservedLocale)

        let status = await AssetInventory.status(forModules: [transcriber])
        AppLogger.info(
            "Speech asset preparation started: locale=\(reservedLocale.identifier), status=\(String(describing: status))",
            context: "AppleSpeechTranscriptionService"
        )
        if status == .installed {
            await MainActor.run { onProgress(1) }
            return
        }
        if status == .unsupported {
            throw AppleSpeechTranscriptionError.localeNotSupported
        }

        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            let refreshed = await AssetInventory.status(forModules: [transcriber])
            if refreshed == .installed {
                await MainActor.run { onProgress(1) }
                return
            }
            throw AppleSpeechTranscriptionError.assetsNotReady
        }

        let progress = request.progress
        AppLogger.info(
            "Speech asset installation request created: locale=\(reservedLocale.identifier), progress=\(progress.fractionCompleted)",
            context: "AppleSpeechTranscriptionService"
        )
        let progressTask = Task {
            var lastReportedProgress = -1.0
            while !Task.isCancelled {
                let value = min(max(progress.fractionCompleted, 0), 1)
                if abs(value - lastReportedProgress) >= 0.001 {
                    lastReportedProgress = value
                    await MainActor.run { onProgress(value) }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { progressTask.cancel() }

        try await request.downloadAndInstall()
        try Task.checkCancellation()

        var finalStatus = await AssetInventory.status(forModules: [transcriber])
        var loggedDeferredDownload = false
        while finalStatus == .downloading {
            if !loggedDeferredDownload {
                AppLogger.info(
                    "Speech asset download is managed by iOS and is waiting or continuing: locale=\(reservedLocale.identifier)",
                    context: "AppleSpeechTranscriptionService"
                )
                loggedDeferredDownload = true
            }
            try await Task.sleep(for: .seconds(2))
            finalStatus = await AssetInventory.status(forModules: [transcriber])
        }

        guard finalStatus == .installed else {
            AppLogger.error(
                "Speech asset installation did not finish: locale=\(reservedLocale.identifier), status=\(String(describing: finalStatus))",
                context: "AppleSpeechTranscriptionService"
            )
            if finalStatus == .unsupported {
                throw AppleSpeechTranscriptionError.localeNotSupported
            }
            throw AppleSpeechTranscriptionError.assetsNotReady
        }

        AppLogger.info(
            "Speech asset installation finished: locale=\(reservedLocale.identifier)",
            context: "AppleSpeechTranscriptionService"
        )
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
        let audioFile = try AVAudioFile(forReading: preparedAudio.url)
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
                    "Apple SpeechTranscriber analyzer started: audio=\(preparedAudio.url.lastPathComponent), format=\(Self.formatDescription(audioFile.processingFormat))",
                    context: "AppleSpeechTranscriptionService"
                )
                await MainActor.run { onProgress(0.5) }

                let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile)
                try Task.checkCancellation()
                if let lastSampleTime {
                    try await analyzer.finalizeAndFinish(through: lastSampleTime)
                } else {
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
            throw error
        }

        try Task.checkCancellation()
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

    private static func formatDescription(_ format: AVAudioFormat?) -> String {
        guard let format else { return "unknown" }
        return "\(Int(format.sampleRate))Hz/\(format.channelCount)ch/\(format.commonFormat)"
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
        } else {
            segments = []
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
