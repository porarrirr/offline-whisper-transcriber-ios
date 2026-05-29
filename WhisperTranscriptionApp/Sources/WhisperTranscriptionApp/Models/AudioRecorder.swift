import AVFoundation
import Foundation

final class AudioRecorder: NSObject, ObservableObject {
    typealias AudioBufferHandler = (AVAudioPCMBuffer, AVAudioTime, AVAudioFormat) -> Void

    private static let recordingSampleRate = 48_000.0

    @Published var isRecording = false
    @Published var currentTime: TimeInterval = 0
    @Published var audioLevel: Float = 0.0
    @Published var recordingError: String?
    @Published var interruptionMessage: String?
    @Published var interruptedRecordingURL: URL?

    private let audioEngine = AVAudioEngine()
    private let stateLock = NSLock()
    private let handlerLock = NSLock()
    private var recordingFile: AVAudioFile?
    private var recordingURL: URL?
    private var inputFormat: AVAudioFormat?
    private var recordedFrames: AVAudioFramePosition = 0
    private var recordingState: RecordingState = .idle
    private var audioBufferHandler: AudioBufferHandler?

    override init() {
        super.init()
        observeAudioSessionNotifications()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    var currentRecordingURL: URL? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return recordingURL
    }

    var currentInputFormat: AVAudioFormat? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return inputFormat
    }

    func setAudioBufferHandler(_ handler: AudioBufferHandler?) {
        handlerLock.lock()
        audioBufferHandler = handler
        handlerLock.unlock()
    }

    func requestPermission(completion: @escaping (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            requestPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func startRecording() throws {
        stateLock.lock()
        let busy = recordingState != .idle || audioEngine.isRunning
        if !busy {
            recordingState = .starting
        }
        stateLock.unlock()
        guard !busy else {
            throw AudioRecorderError.stopInProgress
        }

        do {
            try setupSession()
            let url = try makeRecordingURL()
            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw AudioRecorderError.recordingStartFailed
            }

            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: Int(format.channelCount),
                AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue
            ]
            let file = try AVAudioFile(forWriting: url, settings: settings)

            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, time in
                self?.handleAudioBuffer(buffer, time: time, format: format)
            }

            audioEngine.prepare()
            try audioEngine.start()

            stateLock.lock()
            recordingFile = file
            recordingURL = url
            inputFormat = format
            recordedFrames = 0
            recordingState = .recording
            stateLock.unlock()

            DispatchQueue.main.async {
                self.recordingError = nil
                self.interruptionMessage = nil
                self.interruptedRecordingURL = nil
                self.currentTime = 0
                self.audioLevel = 0
                self.isRecording = true
            }
        } catch {
            cleanupFailedStart()
            throw error
        }
    }

    func stopRecording() async throws -> URL {
        let url = try recordingURLForStop()
        finishActiveRecording()
        return try validateRecordingFile(at: url)
    }

    private func recordingURLForStop() throws -> URL {
        stateLock.lock()
        if recordingState == .stopping {
            stateLock.unlock()
            throw AudioRecorderError.stopInProgress
        }
        if let activeURL = recordingURL, recordingState == .recording, audioEngine.isRunning {
            recordingState = .stopping
            stateLock.unlock()
            return activeURL
        } else if let interruptedRecordingURL {
            stateLock.unlock()
            DispatchQueue.main.async {
                self.interruptedRecordingURL = nil
            }
            return try validateRecordingFile(at: interruptedRecordingURL)
        } else {
            stateLock.unlock()
            throw AudioRecorderError.noActiveRecording
        }
    }

    private func setupSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers]
        )
        try session.setPreferredSampleRate(Self.recordingSampleRate)
        try session.setActive(true)
        logCurrentAudioRoute(session: session, event: "Recording audio session activated")
    }

    private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime, format: AVAudioFormat) {
        stateLock.lock()
        let file = recordingFile
        recordedFrames += AVAudioFramePosition(buffer.frameLength)
        let elapsedTime = format.sampleRate > 0 ? TimeInterval(recordedFrames) / format.sampleRate : 0
        stateLock.unlock()

        do {
            try file?.write(from: buffer)
        } catch {
            reportEncodingFailure(error)
            return
        }

        let level = averagePower(from: buffer)
        DispatchQueue.main.async {
            self.currentTime = elapsedTime
            self.audioLevel = level
        }

        handlerLock.lock()
        let handler = audioBufferHandler
        handlerLock.unlock()
        handler?(buffer, time, format)
    }

    private func finishActiveRecording() {
        setAudioBufferHandler(nil)
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()

        stateLock.lock()
        let duration = inputFormat.map { format in
            format.sampleRate > 0 ? TimeInterval(recordedFrames) / format.sampleRate : currentTime
        } ?? currentTime
        recordingFile = nil
        recordingURL = nil
        inputFormat = nil
        recordedFrames = 0
        recordingState = .idle
        stateLock.unlock()

        DispatchQueue.main.async {
            self.currentTime = duration
            self.audioLevel = 0
            self.isRecording = false
        }
        deactivateSession()
    }

    private func reportEncodingFailure(_ error: Error) {
        let detail = error.localizedDescription
        let message = String(localized: "Recording encoding failed") + ": \(detail)"
        AppLogger.error(message, context: "AudioRecorder", error: error)
        DispatchQueue.main.async {
            self.recordingError = message
        }
        finishActiveRecording()
    }

    private func cleanupFailedStart() {
        setAudioBufferHandler(nil)
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        stateLock.lock()
        recordingFile = nil
        recordingURL = nil
        inputFormat = nil
        recordedFrames = 0
        recordingState = .idle
        stateLock.unlock()
        deactivateSession()
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

    private func averagePower(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return -80 }
        let frameLength = Int(buffer.frameLength)
        var sum: Float = 0
        for frame in 0..<frameLength {
            let sample = channelData[frame]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frameLength))
        return 20 * log10(max(rms, 0.000_001))
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
        stateLock.lock()
        let url = recordingURL
        let wasRecording = recordingState == .recording || audioEngine.isRunning
        stateLock.unlock()
        guard let url, wasRecording else { return }

        finishActiveRecording()
        let message = String(localized: "Recording was interrupted by another audio app. The saved part is available for transcription.")
        AppLogger.error(message, context: "AudioRecorder")
        DispatchQueue.main.async {
            self.interruptionMessage = message
            self.recordingError = message
            if FileManager.default.fileExists(atPath: url.path) {
                self.interruptedRecordingURL = url
            }
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

    private func deactivateSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            AppLogger.error("Failed to deactivate audio session after recording", context: "AudioRecorder", error: error)
        }
    }
}

enum AudioRecorderError: LocalizedError {
    case documentsDirectoryUnavailable
    case noActiveRecording
    case recordingStartFailed
    case recordingFileMissing
    case recordingFileEmpty
    case stopInProgress
    case recordingEncodingFailed(String)
    case microphonePermissionRequired

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
        case .recordingEncodingFailed(let message):
            return message
        case .microphonePermissionRequired:
            return String(localized: "Microphone permission is required")
        }
    }
}

private enum RecordingState {
    case idle
    case starting
    case recording
    case stopping
}
