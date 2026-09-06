import AVFoundation
import Combine
import Speech
import SwiftUI
import UIKit

protocol RecordingAudioCapturing: AnyObject {
    var recordingPublisher: AnyPublisher<Bool, Never> { get }
    var timePublisher: AnyPublisher<TimeInterval, Never> { get }
    var levelPublisher: AnyPublisher<Float, Never> { get }
    var interruptionPublisher: AnyPublisher<String?, Never> { get }
    var interruptedURLPublisher: AnyPublisher<URL?, Never> { get }
    var errorPublisher: AnyPublisher<String?, Never> { get }
    var currentInputFormat: AVAudioFormat? { get }
    var currentRecordingURL: URL? { get }
    func requestPermission() async -> Bool
    func startRecording(context: RecordingStartContext) async throws
    func stopRecording() async throws -> URL
    func setAudioBufferHandler(_ handler: AudioRecorder.AudioBufferHandler?)
}

extension AudioRecorder: RecordingAudioCapturing {
    var recordingPublisher: AnyPublisher<Bool, Never> { $isRecording.eraseToAnyPublisher() }
    var timePublisher: AnyPublisher<TimeInterval, Never> { $currentTime.eraseToAnyPublisher() }
    var levelPublisher: AnyPublisher<Float, Never> { $audioLevel.eraseToAnyPublisher() }
    var interruptionPublisher: AnyPublisher<String?, Never> { $interruptionMessage.eraseToAnyPublisher() }
    var interruptedURLPublisher: AnyPublisher<URL?, Never> { $interruptedRecordingURL.eraseToAnyPublisher() }
    var errorPublisher: AnyPublisher<String?, Never> { $recordingError.eraseToAnyPublisher() }
}

protocol RecordingLiveRecognizing: AnyObject {
    func start(inputFormat: AVAudioFormat, recordingURL: URL?) async throws
    func stop(recordingURL: URL?) async throws -> LiveTranscriptionSnapshot
    func cancel() async
    func handleAudioBuffer(_ buffer: AVAudioPCMBuffer, at audioTime: AVAudioTime)
}

@MainActor
final class RecordingService: ObservableObject {
    static let shared = RecordingService()

    @Published var isRecording = false
    @Published var currentTime: TimeInterval = 0
    @Published var audioLevel: Float = 0
    @Published var errorMessage: String?
    @Published var interruptionMessage: String?
    @Published var interruptedRecordingURL: URL?
    @Published var liveState: LiveTranscriptionState = .idle
    @Published var liveElapsedTime: TimeInterval = 0
    @Published var liveAudioLevel: Float = -80
    @Published var liveFinalizedText: String = ""
    @Published var liveVolatileText: String = ""
    @Published var liveSegments: [TranscriptionSegment] = []
    @Published var liveRecordingURL: URL?
    @Published var liveMessage: String?
    @Published var isStartingRecording = false
    @Published var isStoppingRecording = false

    private let audioRecorder: any RecordingAudioCapturing
    private let settings = AppSettings.shared
    private var cancellables = Set<AnyCancellable>()
    private var liveService: (any RecordingLiveRecognizing)?
    private var liveGeneration: UInt64 = 0
    private var liveTask: Task<Void, Never>?
    private var recordingStartedAt: Date?
    private let liveServiceFactory: (AppleSpeechLocale, @escaping @MainActor (LiveTranscriptionSnapshot) -> Void) -> any RecordingLiveRecognizing
    private let supportsLiveRecognition: () -> Bool
    private let resolveLiveLocale: () async -> AppleSpeechLocale?

    var hasInterruptedRecording: Bool {
        interruptedRecordingURL != nil
    }

    var isLiveTranscriptionActive: Bool {
        liveState.isActive
    }

    var isChangingRecordingState: Bool {
        isStartingRecording || isStoppingRecording
    }

    var canStartLiveTranscription: Bool {
        if #available(iOS 26.0, *) {
            return SpeechTranscriber.isAvailable
        }
        return false
    }

    var liveUnavailableMessage: String? {
        if #available(iOS 26.0, *) {
            if !SpeechTranscriber.isAvailable {
                return String(localized: "Speech transcription is not available on this device.")
            }
            return nil
        }
        return String(localized: "Live transcription requires iOS 26 and a device that supports SpeechTranscriber.")
    }

    init(
        audioRecorder: any RecordingAudioCapturing = AudioRecorder(),
        supportsLiveRecognition: @escaping () -> Bool = {
            if #available(iOS 26.0, *) { return SpeechTranscriber.isAvailable }
            return false
        },
        resolveLiveLocale: @escaping () async -> AppleSpeechLocale? = {
            if let locale = AppSettings.shared.selectedTranscriptionModel.appleSpeechLocale { return locale }
            return await AppSettings.preferredAppleSpeechLocaleForDevice()
        },
        liveServiceFactory: @escaping (AppleSpeechLocale, @escaping @MainActor (LiveTranscriptionSnapshot) -> Void) -> any RecordingLiveRecognizing = { locale, handler in
            guard #available(iOS 26.0, *) else { preconditionFailure("Live transcription requires iOS 26") }
            return LiveTranscriptionService(locale: locale, onSnapshot: handler)
        }
    ) {
        self.audioRecorder = audioRecorder
        self.supportsLiveRecognition = supportsLiveRecognition
        self.resolveLiveLocale = resolveLiveLocale
        self.liveServiceFactory = liveServiceFactory
        audioRecorder.recordingPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$isRecording)
        audioRecorder.recordingPublisher
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording in
                guard let self, !isRecording, !self.isStoppingRecording, self.liveTask != nil || self.liveService != nil else { return }
                Task {
                    await self.cancelLiveTranscription(message: String(localized: "Live transcription stopped because recording was interrupted. The saved part is available for transcription."))
                }
            }
            .store(in: &cancellables)
        audioRecorder.timePublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$currentTime)
        audioRecorder.levelPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$audioLevel)
        audioRecorder.interruptionPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$interruptionMessage)
        audioRecorder.interruptedURLPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$interruptedRecordingURL)
        audioRecorder.errorPublisher
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                guard let self else { return }
                self.errorMessage = message
                self.recordingStartedAt = nil
                self.isStartingRecording = false
                self.isStoppingRecording = false
                UIApplication.shared.isIdleTimerDisabled = false
                Task {
                    await RecordingLiveActivityManager.shared.endRecordingActivity()
                }
            }
            .store(in: &cancellables)
    }

    func startRecording() {
        Task {
            do {
                _ = try await startRecordingFromApp()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func startRecordingFromApp() async throws -> RecordingStartResult {
        try await startRecording(requiresLiveActivity: false, releaseWhisperModel: true)
    }

    func startRecordingFromIntent() async throws -> RecordingStartResult {
        try await startRecording(requiresLiveActivity: true, releaseWhisperModel: true)
    }

    func stopRecording() async throws -> URL {
        guard !isStoppingRecording else {
            throw AudioRecorderError.stopInProgress
        }
        isStoppingRecording = true
        defer { isStoppingRecording = false }
        do {
            let url = try await audioRecorder.stopRecording()
            isRecording = false
            await stopLiveTranscription(recordingURL: url)
            UIApplication.shared.isIdleTimerDisabled = false
            await RecordingLiveActivityManager.shared.endRecordingActivity()
            recordingStartedAt = nil
            return url
        } catch {
            errorMessage = error.localizedDescription
            isRecording = false
            UIApplication.shared.isIdleTimerDisabled = false
            await RecordingLiveActivityManager.shared.endRecordingActivity()
            recordingStartedAt = nil
            throw error
        }
    }

    func consumeInterruptedRecording() async throws -> URL {
        let url = try await stopRecording()
        interruptionMessage = nil
        interruptedRecordingURL = nil
        return url
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            handleBecameActive()
        case .inactive:
            guard isRecording else { return }
            AppLogger.info("App became inactive while recording; recording continues", context: "RecordingService")
        case .background:
            guard isRecording else { return }
            AppLogger.info("App entered background while recording; recording continues", context: "RecordingService")
            Task {
                await cancelLiveTranscription(message: String(localized: "Live transcription stopped in the background. Recording continues and will be transcribed when stopped."))
            }
        @unknown default:
            AppLogger.info("Unknown scene phase", context: "RecordingService")
        }
    }

    /// Called when the app becomes active, including the first launch.
    /// `onChange(of:scenePhase)` does not fire for the initial `.active` value,
    /// so this is also invoked from the view's `onAppear`.
    func handleBecameActive() {
        handleBecameActive(applicationState: UIApplication.shared.applicationState)
    }

    func handleBecameActive(applicationState: UIApplication.State) {
        guard applicationState == .active else {
            AppLogger.info(
                "Skipping foreground recording maintenance while applicationState=\(applicationState.rawValue)",
                context: "RecordingService"
            )
            return
        }

        guard isRecording else {
            // Not recording: dismiss any stale recording Live Activity left over
            // from a previous session (e.g. the app was terminated mid-recording).
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard Self.shouldEndStaleRecordingActivity(
                    applicationState: UIApplication.shared.applicationState,
                    isRecording: self.isRecording,
                    isChangingRecordingState: self.isChangingRecordingState
                ) else {
                    AppLogger.info(
                        "Skipped stale Live Activity cleanup because recording state changed",
                        context: "RecordingService"
                    )
                    return
                }
                await RecordingLiveActivityManager.shared.endRecordingActivity()
            }
            return
        }

        AppLogger.info("App became active while recording", context: "RecordingService")
        let startedAt = recordingStartedAt ?? Date()
        Task {
            await RecordingLiveActivityManager.shared.ensureRecordingActivity(startedAt: startedAt)
        }
    }

    static func shouldEndStaleRecordingActivity(
        applicationState: UIApplication.State,
        isRecording: Bool,
        isChangingRecordingState: Bool
    ) -> Bool {
        applicationState == .active && !isRecording && !isChangingRecordingState
    }

    func startLiveTranscription() {
        guard isRecording, !isStoppingRecording, !isLiveTranscriptionActive else { return }
        guard #available(iOS 26.0, *) else {
            setLiveFailure(String(localized: "Live transcription requires iOS 26 and a device that supports SpeechTranscriber."))
            return
        }
        guard supportsLiveRecognition() else {
            setLiveFailure(String(localized: "Speech transcription is not available on this device."))
            return
        }
        guard let inputFormat = audioRecorder.currentInputFormat else {
            setLiveFailure(String(localized: "Could not prepare the live audio format."))
            return
        }

        resetLiveSnapshot()
        liveState = .preparing
        liveTask?.cancel()
        liveGeneration &+= 1
        let generation = liveGeneration
        liveTask = Task { @MainActor in
            do {
                guard let locale = await resolveLiveLocale() else {
                    throw LiveTranscriptionError.unsupportedLocale
                }

                try Task.checkCancellation()
                guard generation == liveGeneration, isRecording, !isStoppingRecording else { return }
                let service = self.makeLiveTranscriptionService(locale: locale, generation: generation)
                liveService = service
                try await service.start(inputFormat: inputFormat, recordingURL: audioRecorder.currentRecordingURL)
                guard generation == liveGeneration, isRecording, !isStoppingRecording, !Task.isCancelled else {
                    await service.cancel()
                    return
                }
                audioRecorder.setAudioBufferHandler { [weak service] buffer, audioTime, _ in
                    service?.handleAudioBuffer(buffer, at: audioTime)
                }
            } catch {
                guard generation == liveGeneration else { return }
                self.audioRecorder.setAudioBufferHandler(nil)
                self.setLiveFailure(error.localizedDescription)
                self.liveService = nil
            }
        }
    }

    func stopLiveTranscription(recordingURL: URL? = nil) async {
        liveGeneration &+= 1
        let generation = liveGeneration
        liveTask?.cancel()
        let startingTask = liveTask
        liveTask = nil
        audioRecorder.setAudioBufferHandler(nil)
        guard let service = liveService else {
            resetLiveSnapshot(keepingText: true)
            return
        }

        liveService = nil
        await startingTask?.value
        guard generation == liveGeneration else { return }
        do {
            let snapshot = try await service.stop(recordingURL: recordingURL ?? audioRecorder.currentRecordingURL)
            guard generation == liveGeneration else { return }
            applyLiveSnapshot(snapshot)
        } catch {
            guard generation == liveGeneration else { return }
            setLiveFailure(error.localizedDescription)
        }
    }

    func cancelLiveTranscription(message: String? = nil) async {
        liveGeneration &+= 1
        let generation = liveGeneration
        liveTask?.cancel()
        liveTask = nil
        audioRecorder.setAudioBufferHandler(nil)
        guard let service = liveService else {
            resetLiveSnapshot(keepingText: true)
            if let message { liveMessage = message }
            return
        }

        liveService = nil
        await service.cancel()
        guard generation == liveGeneration else { return }
        resetLiveSnapshot(keepingText: true)
        if let message {
            liveMessage = message
            AppLogger.info(message, context: "RecordingService")
        }
    }

    private func startRecording(
        requiresLiveActivity: Bool,
        releaseWhisperModel: Bool
    ) async throws -> RecordingStartResult {
        if isRecording {
            return .alreadyRecording
        }
        guard !isChangingRecordingState else {
            throw AudioRecorderError.stopInProgress
        }

        isStartingRecording = true
        defer { isStartingRecording = false }

        if releaseWhisperModel {
            await WhisperModelService.shared.releaseForRecording()
        }

        guard await audioRecorder.requestPermission() else {
            let error = AudioRecorderError.microphonePermissionRequired
            errorMessage = error.localizedDescription
            throw error
        }

        do {
            let startedAt = Date()
            if requiresLiveActivity {
                try await Self.startRecordingWithRequiredLiveActivity(
                    startLiveActivity: {
                        try await RecordingLiveActivityManager.shared.startRequiredRecordingActivity(
                            startedAt: startedAt
                        )
                        AppLogger.info(
                            "Required recording Live Activity started before audio capture",
                            context: "RecordingService"
                        )
                    },
                    startAudioRecording: {
                        do {
                            try await self.audioRecorder.startRecording(context: .backgroundIntent)
                        } catch {
                            let diagnostics = RecordingLiveActivityManager.shared.activityDiagnosticsDescription()
                            AppLogger.error(
                                "Background intent recording start failed: \(diagnostics)",
                                context: "RecordingService",
                                error: error
                            )
                            throw error
                        }
                    },
                    endLiveActivity: {
                        await RecordingLiveActivityManager.shared.endRecordingActivity()
                    }
                )
            } else {
                try await audioRecorder.startRecording(context: .foreground)
            }

            recordingStartedAt = startedAt
            isRecording = true
            errorMessage = nil
            interruptionMessage = nil
            liveMessage = nil
            UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn

            if !requiresLiveActivity {
                Task {
                    await RecordingLiveActivityManager.shared.ensureRecordingActivity(startedAt: startedAt)
                }
            }

            return .started
        } catch {
            errorMessage = error.localizedDescription
            recordingStartedAt = nil
            isRecording = false
            UIApplication.shared.isIdleTimerDisabled = false
            throw error
        }
    }

    static func startRecordingWithRequiredLiveActivity(
        startLiveActivity: () async throws -> Void,
        startAudioRecording: () async throws -> Void,
        endLiveActivity: () async -> Void
    ) async throws {
        try await startLiveActivity()
        do {
            try await startAudioRecording()
        } catch {
            await endLiveActivity()
            throw error
        }
    }

    /// スナップショットは1つの値が変わっただけでも届く。無条件に代入すると`@Published`が
    /// 7回`objectWillChange`を流し、購読側のビューがその都度無効化されるため、変化した分だけ代入する。
    private func applyLiveSnapshot(_ snapshot: LiveTranscriptionSnapshot) {
        if liveState != snapshot.state {
            liveState = snapshot.state
        }
        if liveElapsedTime != snapshot.elapsedTime {
            liveElapsedTime = snapshot.elapsedTime
        }
        if liveAudioLevel != snapshot.audioLevel {
            liveAudioLevel = snapshot.audioLevel
        }
        if liveFinalizedText != snapshot.finalizedText {
            liveFinalizedText = snapshot.finalizedText
        }
        if liveVolatileText != snapshot.volatileText {
            liveVolatileText = snapshot.volatileText
        }
        if liveSegments != snapshot.segments {
            liveSegments = snapshot.segments
        }
        if liveRecordingURL != snapshot.recordingURL {
            liveRecordingURL = snapshot.recordingURL
        }
        if let errorMessage = snapshot.errorMessage, liveMessage != errorMessage {
            liveMessage = errorMessage
        }
    }

    @available(iOS 26.0, *)
    private func makeLiveTranscriptionService(locale: AppleSpeechLocale, generation: UInt64) -> any RecordingLiveRecognizing {
        liveServiceFactory(locale, { [weak self] snapshot in
            guard let self, self.liveGeneration == generation else { return }
            self.applyLiveSnapshot(snapshot)
        })
    }

    private func resetLiveSnapshot(keepingText: Bool = false) {
        liveState = .idle
        liveElapsedTime = 0
        liveAudioLevel = -80
        if !keepingText {
            liveFinalizedText = ""
            liveVolatileText = ""
            liveSegments = []
        } else {
            liveVolatileText = ""
        }
        liveRecordingURL = nil
        liveMessage = nil
    }

    private func setLiveFailure(_ message: String) {
        liveState = .failed
        liveMessage = message
        AppLogger.error(message, context: "RecordingService")
    }
}

enum RecordingStartResult {
    case started
    case alreadyRecording
}
