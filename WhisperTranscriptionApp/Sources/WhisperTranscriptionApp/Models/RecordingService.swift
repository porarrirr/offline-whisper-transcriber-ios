import Combine
import Speech
import SwiftUI
import UIKit

@MainActor
final class RecordingService: ObservableObject {
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
        guard !isRecording, !isChangingRecordingState else {
            errorMessage = AudioRecorderError.stopInProgress.localizedDescription
            return
        }
        isStartingRecording = true
        audioRecorder.requestPermission { [weak self] granted in
            guard let self else { return }
            if granted {
                self.startRecordingWithPermission()
            } else {
                self.errorMessage = String(localized: "Microphone permission is required")
                self.isStartingRecording = false
            }
        }
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
        guard isRecording else { return }

        switch phase {
        case .active:
            AppLogger.info("App became active while recording", context: "RecordingService")
            Task {
                await RecordingLiveActivityManager.shared.startRecordingActivity(startedAt: recordingStartedAt ?? Date())
            }
        case .inactive:
            AppLogger.info("App became inactive while recording; recording continues", context: "RecordingService")
        case .background:
            AppLogger.info("App entered background while recording; recording continues", context: "RecordingService")
            Task {
                await cancelLiveTranscription(message: String(localized: "Live transcription stopped in the background. Recording continues and will be transcribed when stopped."))
                await RecordingLiveActivityManager.shared.startRecordingActivity(startedAt: recordingStartedAt ?? Date())
            }
        @unknown default:
            AppLogger.info("Unknown scene phase while recording", context: "RecordingService")
        }
    }

    func startLiveTranscription() {
        guard isRecording, !isLiveTranscriptionActive else { return }
        guard #available(iOS 26.0, *) else {
            setLiveFailure(String(localized: "Live transcription requires iOS 26 and a device that supports SpeechTranscriber."))
            return
        }
        guard let inputFormat = audioRecorder.currentInputFormat else {
            setLiveFailure(String(localized: "Could not prepare the live audio format."))
            return
        }

        resetLiveSnapshot()
        let locale = settings.selectedTranscriptionModel.appleSpeechLocale ?? .jaJP
        let service = LiveTranscriptionService(locale: locale) { [weak self] snapshot in
            self?.applyLiveSnapshot(snapshot)
        }
        liveService = service
        liveTask?.cancel()
        liveTask = Task { @MainActor in
            do {
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

    private func startRecordingWithPermission() {
        defer { isStartingRecording = false }
        do {
            try audioRecorder.startRecording()
            let startedAt = Date()
            recordingStartedAt = startedAt
            isRecording = true
            errorMessage = nil
            interruptionMessage = nil
            liveMessage = nil
            UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn
            Task {
                await RecordingLiveActivityManager.shared.startRecordingActivity(startedAt: startedAt)
            }
        } catch {
            errorMessage = error.localizedDescription
            recordingStartedAt = nil
            UIApplication.shared.isIdleTimerDisabled = false
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
