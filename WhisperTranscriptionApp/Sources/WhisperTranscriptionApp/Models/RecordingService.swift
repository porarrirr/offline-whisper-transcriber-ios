import Combine
import Speech
import SwiftUI
import UIKit

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

    private let audioRecorder = AudioRecorder()
    private let settings = AppSettings.shared
    private var cancellables = Set<AnyCancellable>()
    private var liveService: AnyObject?
    private var liveTask: Task<Void, Never>?
    private var recordingStartedAt: Date?

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

    init() {
        audioRecorder.$isRecording
            .receive(on: DispatchQueue.main)
            .assign(to: &$isRecording)
        audioRecorder.$isRecording
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording in
                guard let self, !isRecording, self.liveService != nil else { return }
                Task {
                    await self.cancelLiveTranscription(message: String(localized: "Live transcription stopped because recording was interrupted. The saved part is available for transcription."))
                }
            }
            .store(in: &cancellables)
        audioRecorder.$currentTime
            .receive(on: DispatchQueue.main)
            .assign(to: &$currentTime)
        audioRecorder.$audioLevel
            .receive(on: DispatchQueue.main)
            .assign(to: &$audioLevel)
        audioRecorder.$interruptionMessage
            .receive(on: DispatchQueue.main)
            .assign(to: &$interruptionMessage)
        audioRecorder.$interruptedRecordingURL
            .receive(on: DispatchQueue.main)
            .assign(to: &$interruptedRecordingURL)
        audioRecorder.$recordingError
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
            await stopLiveTranscription()
            let url = try await audioRecorder.stopRecording()
            isRecording = false
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
        guard isRecording else {
            // Not recording: dismiss any stale recording Live Activity left over
            // from a previous session (e.g. the app was terminated mid-recording).
            Task {
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

    func startLiveTranscription() {
        guard isRecording, !isLiveTranscriptionActive else { return }
        guard #available(iOS 26.0, *) else {
            setLiveFailure(String(localized: "Live transcription requires iOS 26 and a device that supports SpeechTranscriber."))
            return
        }
        guard SpeechTranscriber.isAvailable else {
            setLiveFailure(String(localized: "Speech transcription is not available on this device."))
            return
        }
        guard let inputFormat = audioRecorder.currentInputFormat else {
            setLiveFailure(String(localized: "Could not prepare the live audio format."))
            return
        }

        resetLiveSnapshot()
        liveTask?.cancel()
        liveTask = Task { @MainActor in
            do {
                let locale: AppleSpeechLocale
                if let selectedLocale = settings.selectedTranscriptionModel.appleSpeechLocale {
                    locale = selectedLocale
                } else if let deviceLocale = await AppSettings.preferredAppleSpeechLocaleForDevice() {
                    locale = deviceLocale
                } else {
                    throw LiveTranscriptionError.unsupportedLocale
                }

                let service = self.makeLiveTranscriptionService(locale: locale)
                liveService = service
                try await service.start(inputFormat: inputFormat, recordingURL: audioRecorder.currentRecordingURL)
                audioRecorder.setAudioBufferHandler { [weak service] buffer, _, _ in
                    service?.handleAudioBuffer(buffer)
                }
            } catch {
                self.audioRecorder.setAudioBufferHandler(nil)
                self.setLiveFailure(error.localizedDescription)
                self.liveService = nil
            }
        }
    }

    func stopLiveTranscription() async {
        audioRecorder.setAudioBufferHandler(nil)
        guard #available(iOS 26.0, *),
              let service = liveService as? LiveTranscriptionService else {
            return
        }

        liveTask?.cancel()
        do {
            let snapshot = try await service.stop(recordingURL: audioRecorder.currentRecordingURL)
            applyLiveSnapshot(snapshot)
        } catch {
            setLiveFailure(error.localizedDescription)
        }
        liveService = nil
    }

    func cancelLiveTranscription(message: String? = nil) async {
        audioRecorder.setAudioBufferHandler(nil)
        guard #available(iOS 26.0, *),
              let service = liveService as? LiveTranscriptionService else {
            if let message {
                liveMessage = message
            }
            return
        }

        liveTask?.cancel()
        await service.cancel()
        liveService = nil
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

    private func applyLiveSnapshot(_ snapshot: LiveTranscriptionSnapshot) {
        liveState = snapshot.state
        liveElapsedTime = snapshot.elapsedTime
        liveAudioLevel = snapshot.audioLevel
        liveFinalizedText = snapshot.finalizedText
        liveVolatileText = snapshot.volatileText
        liveSegments = snapshot.segments
        liveRecordingURL = snapshot.recordingURL
        if let errorMessage = snapshot.errorMessage {
            liveMessage = errorMessage
        }
    }

    @available(iOS 26.0, *)
    private func makeLiveTranscriptionService(locale: AppleSpeechLocale) -> LiveTranscriptionService {
        LiveTranscriptionService(locale: locale) { [weak self] snapshot in
            self?.applyLiveSnapshot(snapshot)
        }
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
