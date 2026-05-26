import AVFoundation
import CoreMedia
import Foundation
import Speech

enum LiveTranscriptionState: String {
    case idle
    case preparing
    case recording
    case finalizing
    case saving
    case failed

    var isActive: Bool {
        switch self {
        case .preparing, .recording, .finalizing, .saving:
            return true
        case .idle, .failed:
            return false
        }
    }
}

struct LiveTranscriptionSnapshot {
    var state: LiveTranscriptionState = .idle
    var elapsedTime: TimeInterval = 0
    var audioLevel: Float = -80
    var finalizedText: String = ""
    var volatileText: String = ""
    var segments: [TranscriptionSegment] = []
    var recordingURL: URL?
    var errorMessage: String?
    var language: String?
}

enum LiveTranscriptionError: LocalizedError {
    case unavailable
    case speechPermissionDenied
    case microphonePermissionDenied
    case unsupportedLocale
    case assetsNotReady
    case audioFormatUnavailable
    case recordingFileMissing
    case emptyTranscription

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return String(localized: "Live transcription requires iOS 26 and a device that supports SpeechTranscriber.")
        case .speechPermissionDenied:
            return String(localized: "Speech recognition permission is required for live transcription.")
        case .microphonePermissionDenied:
            return String(localized: "Microphone permission is required")
        case .unsupportedLocale:
            return String(localized: "This language is not supported by on-device speech recognition.")
        case .assetsNotReady:
            return String(localized: "Speech model could not be prepared automatically.")
        case .audioFormatUnavailable:
            return String(localized: "Could not prepare the live audio format.")
        case .recordingFileMissing:
            return String(localized: "Recording stopped, but the recording file was not saved.")
        case .emptyTranscription:
            return String(localized: "Transcription finished, but no text was produced.")
        }
    }
}

@available(iOS 26.0, *)
final class LiveTranscriptionService {
    typealias SnapshotHandler = @MainActor (LiveTranscriptionSnapshot) -> Void

    private let locale: AppleSpeechLocale
    private let onSnapshot: SnapshotHandler

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analysisTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var timer: Timer?
    private var recordingURL: URL?
    private var converter: AVAudioConverter?
    private var compatibleFormat: AVAudioFormat?
    private var inputFormat: AVAudioFormat?
    private var startedAt: Date?
    private var snapshot = LiveTranscriptionSnapshot()
    private let snapshotLock = NSLock()
    private var finalizedAttributedText = AttributedString()
    private var segmentID = 0
    private let lifecycleLock = NSLock()
    private var isStopping = false
    private var needsFinalTranscriptionRecovery = false

    init(locale: AppleSpeechLocale, onSnapshot: @escaping SnapshotHandler) {
        self.locale = locale
        self.onSnapshot = onSnapshot
        snapshot.language = locale.locale.language.languageCode?.identifier
    }

    func start(inputFormat: AVAudioFormat, recordingURL: URL?) async throws {
        guard !currentSnapshot().state.isActive else { return }

        do {
            resetLifecycle()
            setState(.preparing)

            guard SpeechTranscriber.isAvailable else {
                throw LiveTranscriptionError.unavailable
            }
            try await requestSpeechPermission()

            guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale.locale) else {
                throw LiveTranscriptionError.unsupportedLocale
            }

            let transcriber = SpeechTranscriber(locale: supportedLocale, preset: .timeIndexedProgressiveTranscription)
            try await ensureAssetsInstalled(for: transcriber)

            guard let compatibleFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw LiveTranscriptionError.audioFormatUnavailable
            }

            let (inputSequence, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            self.transcriber = transcriber
            self.analyzer = analyzer
            self.inputContinuation = inputContinuation
            self.compatibleFormat = compatibleFormat
            self.inputFormat = inputFormat
            self.recordingURL = recordingURL
            guard let converter = AVAudioConverter(from: inputFormat, to: compatibleFormat) else {
                throw LiveTranscriptionError.audioFormatUnavailable
            }
            self.converter = converter
            updateSnapshot { snapshot in
                snapshot.recordingURL = recordingURL
            }

            resultsTask = Task { [weak self, transcriber] in
                do {
                    try await self?.consumeResults(from: transcriber)
                } catch is CancellationError {
                } catch {
                    self?.reportRecoverableTranscriptionError(error)
                }
            }
            analysisTask = Task { [weak self, analyzer, inputSequence] in
                do {
                    _ = try await analyzer.analyzeSequence(inputSequence)
                } catch is CancellationError {
                } catch {
                    self?.reportRecoverableTranscriptionError(error)
                }
            }

            startedAt = Date()
            startTimer()
            setState(.recording)
        } catch {
            await cancel()
            throw error
        }
    }

    func stop(recordingURL: URL? = nil) async throws -> LiveTranscriptionSnapshot {
        guard currentSnapshot().state.isActive else { return currentSnapshot() }
        markStopping()
        setState(.finalizing)

        inputContinuation?.finish()
        inputContinuation = nil
        stopTimer()

        if let analyzer {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                reportRecoverableTranscriptionError(error)
            }
        }
        await analysisTask?.value
        await resultsTask?.value

        setState(.saving)

        let finalRecordingURL = recordingURL ?? self.recordingURL
        updateSnapshot { snapshot in
            if let volatileText = nonEmpty(snapshot.volatileText),
               !snapshot.finalizedText.hasSuffix(volatileText) {
                snapshot.finalizedText = joinedText(snapshot.finalizedText, volatileText)
                snapshot.volatileText = ""
            }
            snapshot.recordingURL = finalRecordingURL
        }

        setState(.idle)
        return currentSnapshot()
    }

    func cancel() async {
        markStopping()
        inputContinuation?.finish()
        inputContinuation = nil
        stopTimer()
        await analyzer?.cancelAndFinishNow()
        analysisTask?.cancel()
        resultsTask?.cancel()
        setState(.idle)
    }

    func handleAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard !isStoppingNow() else { return }

        updateAudioLevel(from: buffer)

        do {
            if let converted = try convert(buffer) {
                inputContinuation?.yield(AnalyzerInput(buffer: converted))
            }
        } catch {
            reportRecoverableTranscriptionError(error)
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
        guard let compatibleFormat, let inputFormat, let converter else {
            throw LiveTranscriptionError.audioFormatUnavailable
        }

        if inputFormat == compatibleFormat {
            return buffer
        }

        let ratio = compatibleFormat.sampleRate / inputFormat.sampleRate
        let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: compatibleFormat, frameCapacity: frameCapacity) else {
            throw LiveTranscriptionError.audioFormatUnavailable
        }

        var didProvideBuffer = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if didProvideBuffer {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvideBuffer = true
            outStatus.pointee = .haveData
            return buffer
        }

        var error: NSError?
        converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)
        if let error {
            throw error
        }
        return convertedBuffer.frameLength > 0 ? convertedBuffer : nil
    }

    private func consumeResults(from transcriber: SpeechTranscriber) async throws {
        for try await result in transcriber.results {
            try Task.checkCancellation()
            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            updateSnapshot { snapshot in
                if result.isFinal {
                    finalizedAttributedText.append(result.text)
                    snapshot.finalizedText = String(finalizedAttributedText.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    snapshot.volatileText = ""
                    appendSegment(from: result, text: text, snapshot: &snapshot)
                } else {
                    snapshot.volatileText = text
                }
            }
        }
    }

    private func appendSegment(
        from result: SpeechTranscriber.Result,
        text: String,
        snapshot: inout LiveTranscriptionSnapshot
    ) {
        let start = result.range.start.seconds.isFinite ? result.range.start.seconds : snapshot.elapsedTime
        let end = result.range.end.seconds.isFinite ? result.range.end.seconds : start
        snapshot.segments.append(
            TranscriptionSegment(id: segmentID, start: max(0, start), end: max(start, end), text: text)
        )
        segmentID += 1
    }

    private func ensureAssetsInstalled(for transcriber: SpeechTranscriber) async throws {
        let status = await AssetInventory.status(forModules: [transcriber])
        if status == .installed {
            return
        }
        if status == .unsupported {
            throw LiveTranscriptionError.unsupportedLocale
        }

        let reservedLocale = transcriber.selectedLocales.first ?? locale.locale
        _ = try await AssetInventory.reserve(locale: reservedLocale)

        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            let refreshed = await AssetInventory.status(forModules: [transcriber])
            if refreshed == .installed {
                return
            }
            throw LiveTranscriptionError.assetsNotReady
        }
        try await request.downloadAndInstall()
    }

    private func requestSpeechPermission() async throws {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else {
            throw LiveTranscriptionError.speechPermissionDenied
        }
    }

    private func updateAudioLevel(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let frameLength = Int(buffer.frameLength)
        var sum: Float = 0
        for frame in 0..<frameLength {
            let sample = channelData[frame]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frameLength))
        let decibels = 20 * log10(max(rms, 0.000_001))

        updateSnapshot { snapshot in
            snapshot.audioLevel = decibels
        }
    }

    private func reportRecoverableTranscriptionError(_ error: Error) {
        markFinalTranscriptionRecoveryNeeded()
        AppLogger.error("Live transcription stream error; recording continues", context: "LiveTranscriptionService", error: error)
        updateSnapshot { snapshot in
            if snapshot.state.isActive {
                snapshot.errorMessage = String(localized: "Live transcription was interrupted; recording will continue.")
            }
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let startedAt else { return }
            updateSnapshot { snapshot in
                snapshot.elapsedTime = Date().timeIntervalSince(startedAt)
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        if let startedAt {
            updateSnapshot { snapshot in
                snapshot.elapsedTime = Date().timeIntervalSince(startedAt)
            }
        }
    }

    private func setState(_ state: LiveTranscriptionState) {
        updateSnapshot { snapshot in
            snapshot.state = state
        }
    }

    private func currentSnapshot() -> LiveTranscriptionSnapshot {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return snapshot
    }

    @discardableResult
    private func updateSnapshot(_ update: (inout LiveTranscriptionSnapshot) -> Void) -> LiveTranscriptionSnapshot {
        snapshotLock.lock()
        update(&snapshot)
        let snapshot = snapshot
        snapshotLock.unlock()
        publish(snapshot)
        return snapshot
    }

    private func markStopping() {
        lifecycleLock.lock()
        isStopping = true
        lifecycleLock.unlock()
    }

    private func resetLifecycle() {
        lifecycleLock.lock()
        isStopping = false
        needsFinalTranscriptionRecovery = false
        lifecycleLock.unlock()
    }

    private func isStoppingNow() -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return isStopping
    }

    private func markFinalTranscriptionRecoveryNeeded() {
        lifecycleLock.lock()
        needsFinalTranscriptionRecovery = true
        lifecycleLock.unlock()
    }

    private func publish(_ snapshot: LiveTranscriptionSnapshot) {
        Task { @MainActor in
            onSnapshot(snapshot)
        }
    }

    private func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func joinedText(_ first: String, _ second: String) -> String {
        let first = first.trimmingCharacters(in: .whitespacesAndNewlines)
        let second = second.trimmingCharacters(in: .whitespacesAndNewlines)
        if first.isEmpty { return second }
        if second.isEmpty { return first }
        return first + "\n" + second
    }
}
