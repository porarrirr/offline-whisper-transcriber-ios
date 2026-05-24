import Combine
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

    private let audioRecorder = AudioRecorder()
    private let settings = AppSettings.shared
    private var cancellables = Set<AnyCancellable>()

    var hasInterruptedRecording: Bool {
        interruptedRecordingURL != nil
    }

    init() {
        audioRecorder.$isRecording
            .receive(on: DispatchQueue.main)
            .assign(to: &$isRecording)
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
                UIApplication.shared.isIdleTimerDisabled = false
                Task {
                    await RecordingLiveActivityManager.shared.endRecordingActivity()
                }
            }
            .store(in: &cancellables)
    }

    func startRecording() {
        audioRecorder.requestPermission { [weak self] granted in
            guard let self else { return }
            if granted {
                self.startRecordingWithPermission()
            } else {
                self.errorMessage = String(localized: "Microphone permission is required")
            }
        }
    }

    func stopRecording() async throws -> URL {
        do {
            let url = try await audioRecorder.stopRecording()
            UIApplication.shared.isIdleTimerDisabled = false
            await RecordingLiveActivityManager.shared.endRecordingActivity()
            return url
        } catch {
            errorMessage = error.localizedDescription
            UIApplication.shared.isIdleTimerDisabled = false
            await RecordingLiveActivityManager.shared.endRecordingActivity()
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
                await RecordingLiveActivityManager.shared.startRecordingActivity()
            }
        case .inactive:
            AppLogger.info("App became inactive while recording; recording continues", context: "RecordingService")
        case .background:
            AppLogger.info("App entered background while recording; recording continues", context: "RecordingService")
            Task {
                await RecordingLiveActivityManager.shared.startRecordingActivity()
            }
        @unknown default:
            AppLogger.info("Unknown scene phase while recording", context: "RecordingService")
        }
    }

    private func startRecordingWithPermission() {
        do {
            try audioRecorder.startRecording()
            errorMessage = nil
            interruptionMessage = nil
            UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn
            Task {
                await RecordingLiveActivityManager.shared.startRecordingActivity()
            }
        } catch {
            errorMessage = error.localizedDescription
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}
