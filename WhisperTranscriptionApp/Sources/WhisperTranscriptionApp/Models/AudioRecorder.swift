import Foundation
import AVFoundation

class AudioRecorder: NSObject, ObservableObject {
    private static let recordingSampleRate = 48_000.0
    private static let recordingBitRate = 128_000

    @Published var isRecording = false
    @Published var currentTime: TimeInterval = 0
    @Published var audioLevel: Float = 0.0
    @Published var recordingError: String?
    @Published var interruptionMessage: String?
    @Published var interruptedRecordingURL: URL?

    private var audioRecorder: AVAudioRecorder?
    private var timer: Timer?
    private var recordingURL: URL?
    private var stopContinuation: CheckedContinuation<URL, Error>?
    private var stopDuration: TimeInterval = 0

    override init() {
        super.init()
        observeAudioSessionNotifications()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    var currentRecordingURL: URL? {
        recordingURL
    }

    private func setupSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setPreferredSampleRate(Self.recordingSampleRate)
        try session.setActive(true)
        logCurrentAudioRoute(session: session, event: "Recording audio session activated")
    }

    func startRecording() throws {
        guard stopContinuation == nil else {
            throw AudioRecorderError.stopInProgress
        }
        try setupSession()
        let audioFilename = try makeRecordingURL()

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: Self.recordingSampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: Self.recordingBitRate,
            AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue
        ]

        let recorder = try AVAudioRecorder(url: audioFilename, settings: settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord(), recorder.record() else {
            throw AudioRecorderError.recordingStartFailed
        }

        audioRecorder = recorder
        recordingURL = audioFilename
        recordingError = nil
        interruptionMessage = nil
        interruptedRecordingURL = nil
        isRecording = true
        currentTime = 0

        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.updateRecordingState()
        }
    }

    func stopRecording() async throws -> URL {
        guard let recorder = audioRecorder, let recordingURL else {
            if let interruptedRecordingURL {
                let validatedURL = try validateRecordingFile(at: interruptedRecordingURL)
                self.interruptedRecordingURL = nil
                return validatedURL
            }
            throw AudioRecorderError.noActiveRecording
        }
        guard stopContinuation == nil else {
            throw AudioRecorderError.stopInProgress
        }

        stopDuration = recorder.currentTime
        let stoppedURL = try await withCheckedThrowingContinuation { continuation in
            stopContinuation = continuation
            recorder.stop()
        }

        guard stoppedURL == recordingURL else {
            throw AudioRecorderError.recordingFileMissing
        }
        return try validateRecordingFile(at: stoppedURL)
    }

    private func updateRecordingState() {
        guard let recorder = audioRecorder else { return }
        currentTime = recorder.currentTime
        recorder.updateMeters()
        audioLevel = recorder.averagePower(forChannel: 0)
    }

    private func finishRecordingState() {
        timer?.invalidate()
        timer = nil
        isRecording = false
        audioLevel = 0
        currentTime = stopDuration
        audioRecorder = nil
        recordingURL = nil
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            AppLogger.error("Failed to deactivate audio session after recording", context: "AudioRecorder", error: error)
        }
    }

    private func resumeStopContinuation(with result: Result<URL, Error>) {
        guard let continuation = stopContinuation else { return }
        stopContinuation = nil
        continuation.resume(with: result)
    }

    private func validateRecordingFile(at url: URL) throws -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AudioRecorderError.recordingFileMissing
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = attributes[.size] as? NSNumber
        guard fileSize?.int64Value ?? 0 > 0 else {
            throw AudioRecorderError.recordingFileEmpty
        }
        return url
    }

    func requestPermission(completion: @escaping (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }

    private func makeRecordingURL() throws -> URL {
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw AudioRecorderError.documentsDirectoryUnavailable
        }

        let recordingsDirectory = documentsPath.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        return recordingsDirectory.appendingPathComponent("recording_\(timestamp).m4a")
    }

    private func observeAudioSessionNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    @objc private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else {
            return
        }

        switch type {
        case .began:
            handleRecordingInterruptionBegan()
        case .ended:
            AppLogger.info("Audio session interruption ended; recording will not auto-resume", context: "AudioRecorder")
        @unknown default:
            AppLogger.info("Unknown audio session interruption received", context: "AudioRecorder")
        }
    }

    private func handleRecordingInterruptionBegan() {
        guard let recorder = audioRecorder, isRecording else { return }

        stopDuration = recorder.currentTime
        let interruptedURL = recorder.url
        let message = String(localized: "Recording was interrupted. A partial recording may be available for transcription.")
        interruptionMessage = message
        recordingError = message
        AppLogger.error(message, context: "AudioRecorder")

        recorder.stop()
        if FileManager.default.fileExists(atPath: interruptedURL.path) {
            interruptedRecordingURL = interruptedURL
        }
    }

    @objc private func handleAudioRouteChange(_ notification: Notification) {
        guard isRecording else { return }
        let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
        AppLogger.info("Audio route changed while recording: reason=\(reasonValue)", context: "AudioRecorder")
        logCurrentAudioRoute(session: AVAudioSession.sharedInstance(), event: "Recording audio route changed")
    }

    private func logCurrentAudioRoute(session: AVAudioSession, event: String) {
        let inputs = session.currentRoute.inputs.map { "\($0.portName)(\($0.portType.rawValue))" }.joined(separator: ", ")
        let outputs = session.currentRoute.outputs.map { "\($0.portName)(\($0.portType.rawValue))" }.joined(separator: ", ")
        AppLogger.info(
            "\(event): sampleRate=\(session.sampleRate), preferredSampleRate=\(session.preferredSampleRate), inputs=[\(inputs)], outputs=[\(outputs)]",
            context: "AudioRecorder"
        )

        if session.currentRoute.inputs.contains(where: { $0.portType == .bluetoothHFP }) {
            AppLogger.info(
                "Bluetooth HFP microphone is active; recording is preserved, but the input route can be limited to call-quality audio.",
                context: "AudioRecorder"
            )
        }
    }
}

extension AudioRecorder: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        finishRecordingState()
        if !flag {
            let message: String
            if FileManager.default.fileExists(atPath: recorder.url.path) {
                message = String(localized: "Recording ended unsuccessfully. A partial recording file was saved.")
            } else {
                message = String(localized: "Recording ended unsuccessfully and no recording file was saved.")
            }
            recordingError = message
            AppLogger.error(message, context: "AudioRecorder")
            resumeStopContinuation(with: .failure(AudioRecorderError.recordingEndedUnsuccessfully(message)))
            return
        }
        resumeStopContinuation(with: .success(recorder.url))
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        finishRecordingState()
        let detail = error?.localizedDescription ?? String(localized: "Unknown encoding error")
        let message = String(localized: "Recording encoding failed") + ": \(detail)"
        recordingError = message
        AppLogger.error(message, context: "AudioRecorder", error: error)
        resumeStopContinuation(with: .failure(AudioRecorderError.recordingEncodingFailed(message)))
    }
}

enum AudioRecorderError: LocalizedError {
    case documentsDirectoryUnavailable
    case noActiveRecording
    case recordingStartFailed
    case recordingFileMissing
    case recordingFileEmpty
    case stopInProgress
    case recordingEndedUnsuccessfully(String)
    case recordingEncodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .documentsDirectoryUnavailable:
            return String(localized: "Could not retrieve document directory for saving recording.")
        case .noActiveRecording:
            return String(localized: "No active recording was found.")
        case .recordingStartFailed:
            return String(localized: "Failed to start recording.")
        case .recordingFileMissing:
            return String(localized: "Recording stopped, but the recording file was not saved.")
        case .recordingFileEmpty:
            return String(localized: "Recording stopped, but the recording file is empty.")
        case .stopInProgress:
            return String(localized: "Recording is already stopping.")
        case .recordingEndedUnsuccessfully(let message), .recordingEncodingFailed(let message):
            return message
        }
    }
}
