import Foundation
import AVFoundation

class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var currentTime: TimeInterval = 0
    @Published var audioLevel: Float = 0.0
    @Published var recordingError: String?

    private var audioRecorder: AVAudioRecorder?
    private var timer: Timer?
    private var recordingURL: URL?
    private var stopContinuation: CheckedContinuation<URL, Error>?
    private var stopDuration: TimeInterval = 0

    var currentRecordingURL: URL? {
        recordingURL
    }

    private func setupSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
    }

    func startRecording() throws {
        guard stopContinuation == nil else {
            throw AudioRecorderError.stopInProgress
        }
        try setupSession()
        let audioFilename = try makeRecordingURL()

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
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
        isRecording = true
        currentTime = 0

        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.updateRecordingState()
        }
    }

    func stopRecording() async throws -> URL {
        guard let recorder = audioRecorder, let recordingURL else {
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

        guard stoppedURL == recordingURL, FileManager.default.fileExists(atPath: stoppedURL.path) else {
            throw AudioRecorderError.recordingFileMissing
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: stoppedURL.path)
        let fileSize = attributes[.size] as? NSNumber
        guard fileSize?.int64Value ?? 0 > 0 else {
            throw AudioRecorderError.recordingFileEmpty
        }

        return stoppedURL
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
