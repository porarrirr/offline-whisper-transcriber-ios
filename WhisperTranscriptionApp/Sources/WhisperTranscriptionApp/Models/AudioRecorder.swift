import AVFoundation
import Foundation

final class AudioRecorder: NSObject, ObservableObject {
    typealias AudioBufferHandler = (AVAudioPCMBuffer, AVAudioTime, AVAudioFormat) -> Void

    private static let recordingSampleRate = 48_000.0
    private static let bluetoothHFPRecordingSampleRate = 16_000.0

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

    func startRecording() async throws {
        try beginStartingState()

        do {
            try setupSession()
            let url = try makeRecordingURL()
            let inputNode = audioEngine.inputNode
            let format = try await waitForStableInputTapFormat(on: inputNode)

            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: Int(format.channelCount),
                AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue
            ]
            let file: AVAudioFile
            do {
                file = try AVAudioFile(forWriting: url, settings: settings)
            } catch {
                throw makeRecordingStartError(stage: "create recording file", error: error)
            }

            inputNode.removeTap(onBus: 0)
            AppLogger.info(
                "Installing audio input tap: sampleRate=\(format.sampleRate), channels=\(format.channelCount)",
                context: "AudioRecorder"
            )
            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, time in
                self?.handleAudioBuffer(buffer, time: time, format: format)
            }

            audioEngine.prepare()
            do {
                try audioEngine.start()
            } catch {
                throw makeRecordingStartError(stage: "start audio engine", error: error)
            }

            setStartedRecording(file: file, url: url, format: format)
            publishStartedRecording()
        } catch {
            cleanupFailedStart()
            throw error
        }
    }

    private func beginStartingState() throws {
        stateLock.lock()
        if recordingState == .starting, !audioEngine.isRunning, recordingURL == nil {
            AppLogger.info("Recovering stale recording start state before retry", context: "AudioRecorder")
            recordingState = .idle
        }

        let busy = recordingState != .idle || audioEngine.isRunning
        if !busy {
            recordingState = .starting
        }
        stateLock.unlock()

        guard !busy else {
            throw AudioRecorderError.stopInProgress
        }
    }

    private func setStartedRecording(file: AVAudioFile, url: URL, format: AVAudioFormat) {
        stateLock.lock()
        recordingFile = file
        recordingURL = url
        inputFormat = format
        recordedFrames = 0
        recordingState = .recording
        stateLock.unlock()
    }

    private func publishStartedRecording() {
        DispatchQueue.main.async {
            self.recordingError = nil
            self.interruptionMessage = nil
            self.interruptedRecordingURL = nil
            self.currentTime = 0
            self.audioLevel = 0
            self.isRecording = true
        }
    }

    private func waitForStableInputTapFormat(on inputNode: AVAudioInputNode) async throws -> AVAudioFormat {
        let maxAttempts = 16
        let retryDelayNanoseconds: UInt64 = 50_000_000
        var previousFormat: AVAudioFormat?
        var stableReadCount = 0

        for attempt in 1...maxAttempts {
            let session = AVAudioSession.sharedInstance()
            let format = inputNode.outputFormat(forBus: 0)
            if isUsableInputTapFormat(format, session: session) {
                if let previousFormat, sameAudioHardwareShape(previousFormat, format) {
                    stableReadCount += 1
                } else {
                    stableReadCount = 1
                    previousFormat = format
                }

                if stableReadCount >= 2 {
                    if attempt > 2 {
                        AppLogger.info(
                            "Audio input tap format stabilized after session activation: sampleRate=\(format.sampleRate), channels=\(format.channelCount), attempts=\(attempt)",
                            context: "AudioRecorder"
                        )
                    }
                    return format
                }
            } else {
                if attempt == 1 {
                    AppLogger.info(
                        "Waiting for audio input tap format: outputSampleRate=\(format.sampleRate), outputChannels=\(format.channelCount), sessionSampleRate=\(session.sampleRate)",
                        context: "AudioRecorder"
                    )
                }
                stableReadCount = 0
                previousFormat = nil
            }

            if attempt < maxAttempts {
                try await Task.sleep(nanoseconds: retryDelayNanoseconds)
            }
        }

        let finalInputFormat = inputNode.inputFormat(forBus: 0)
        let finalOutputFormat = inputNode.outputFormat(forBus: 0)
        let session = AVAudioSession.sharedInstance()
        let route = currentRouteDescription(session: session)
        AppLogger.error(
            "Audio input tap format did not stabilize after session activation: inputSampleRate=\(finalInputFormat.sampleRate), inputChannels=\(finalInputFormat.channelCount), outputSampleRate=\(finalOutputFormat.sampleRate), outputChannels=\(finalOutputFormat.channelCount), sessionSampleRate=\(session.sampleRate), preferredSampleRate=\(session.preferredSampleRate), inputs=[\(route.inputs)], outputs=[\(route.outputs)]",
            context: "AudioRecorder"
        )
        throw AudioRecorderError.recordingStartFailed("input tap format did not stabilize after session activation")
    }

    private func isUsableInputTapFormat(_ format: AVAudioFormat, session: AVAudioSession) -> Bool {
        guard format.sampleRate > 0, format.channelCount > 0 else {
            return false
        }

        let sessionSampleRate = session.sampleRate
        guard sessionSampleRate > 0 else {
            return false
        }

        return abs(format.sampleRate - sessionSampleRate) < 1
    }

    private func sameAudioHardwareShape(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        abs(lhs.sampleRate - rhs.sampleRate) < 1
            && lhs.channelCount == rhs.channelCount
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
        try performAudioSessionStep("set category") {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers]
            )
        }

        let preferredSampleRate = preferredRecordingSampleRate(for: session)
        try performAudioSessionStep("set preferred sample rate \(preferredSampleRate)") {
            try session.setPreferredSampleRate(preferredSampleRate)
        }

        try performAudioSessionStep("activate session") {
            try session.setActive(true)
        }
        try selectBluetoothHFPInputIfAvailable(session)
        logCurrentAudioRoute(session: session, event: "Recording audio session activated")
    }

    private func preferredRecordingSampleRate(for session: AVAudioSession) -> Double {
        if routeCanUseBluetoothHFP(session) {
            return Self.bluetoothHFPRecordingSampleRate
        }
        return Self.recordingSampleRate
    }

    private func routeCanUseBluetoothHFP(_ session: AVAudioSession) -> Bool {
        session.currentRoute.inputs.contains { $0.portType == .bluetoothHFP }
            || session.currentRoute.outputs.contains { $0.portType == .bluetoothHFP }
            || (session.availableInputs?.contains { $0.portType == .bluetoothHFP } ?? false)
    }

    private func selectBluetoothHFPInputIfAvailable(_ session: AVAudioSession) throws {
        guard let bluetoothInput = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) else {
            return
        }

        try performAudioSessionStep("set Bluetooth HFP preferred input \(bluetoothInput.portName)") {
            try session.setPreferredInput(bluetoothInput)
        }
    }

    private func performAudioSessionStep(_ stage: String, operation: () throws -> Void) throws {
        do {
            try operation()
            AppLogger.info("Recording audio session step completed: \(stage)", context: "AudioRecorder")
        } catch {
            throw makeRecordingStartError(stage: stage, error: error)
        }
    }

    private func makeRecordingStartError(stage: String, error: Error) -> AudioRecorderError {
        let nsError = error as NSError
        let detail = "\(stage): \(error.localizedDescription) [\(nsError.domain) \(nsError.code)]"
        AppLogger.error("Recording start failed at \(detail)", context: "AudioRecorder", error: error)
        return .recordingStartFailed(detail)
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
        let route = currentRouteDescription(session: session)
        AppLogger.info(
            "\(event): sampleRate=\(session.sampleRate), preferredSampleRate=\(session.preferredSampleRate), inputs=[\(route.inputs)], outputs=[\(route.outputs)]",
            context: "AudioRecorder"
        )

        if session.currentRoute.inputs.contains(where: { $0.portType == .bluetoothHFP }) {
            AppLogger.info(
                "Bluetooth HFP microphone is active; recording is preserved, but the input route can be limited to call-quality audio.",
                context: "AudioRecorder"
            )
        }
    }

    private func currentRouteDescription(session: AVAudioSession) -> (inputs: String, outputs: String) {
        let inputs = session.currentRoute.inputs.map { "\($0.portName)(\($0.portType.rawValue))" }.joined(separator: ", ")
        let outputs = session.currentRoute.outputs.map { "\($0.portName)(\($0.portType.rawValue))" }.joined(separator: ", ")
        return (inputs: inputs, outputs: outputs)
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
    case recordingStartFailed(String)
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
        case .recordingStartFailed(let detail):
            return String(localized: "Failed to start recording.") + " \(detail)"
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
