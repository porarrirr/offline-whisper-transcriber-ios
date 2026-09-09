import AVFoundation
import Foundation

enum RecordingStartContext {
    case foreground
    case backgroundIntent
}

final class AudioRecorder: NSObject, ObservableObject {
    typealias AudioBufferHandler = (AVAudioPCMBuffer, AVAudioTime, AVAudioFormat) -> Void

    private static let recordingSampleRate = 48_000.0
    private static let bluetoothHFPRecordingSampleRate = 16_000.0
    private static let recordingBitRate = 96_000

    @Published var microphoneInputs: [RecordingMicrophone] = []
    @Published var selectedMicrophoneID: String?
    @Published var isRecording = false
    @Published var currentTime: TimeInterval = 0
    @Published var audioLevel: Float = 0.0
    @Published var recordingError: String?
    @Published var interruptionMessage: String?
    @Published var interruptedRecordingURL: URL?

    private let audioEngine = AVAudioEngine()
    private let stateLock = NSLock()
    private let fileWriteLock = NSLock()
    private let handlerLock = NSLock()
    private let recordingStopQueue = DispatchQueue(
        label: "com.porarrirr.audio-recorder.stop",
        qos: .userInitiated
    )
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

    func startRecording(context: RecordingStartContext = .foreground) async throws {
        try beginStartingState()

        do {
            try await setupSession(context: context)
            let url = try makeRecordingURL()
            let inputNode = audioEngine.inputNode
            let hardwareFormat = try await waitForStableInputTapFormat(on: inputNode)
            // A fixed 48 kHz timeline preserves built-in microphone bandwidth
            // even when recording started on HFP. Upsampling HFP adds no detail.
            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Self.recordingSampleRate,
                channels: 1,
                interleaved: false
            ) else { throw AudioRecorderError.recordingStartFailed("Invalid recording format") }
            let converter = try RecordingInputConverter(from: hardwareFormat, to: format)

            let settings = Self.recordingFileSettings(sampleRate: format.sampleRate)
            let file: AVAudioFile
            do {
                file = try AVAudioFile(
                    forWriting: url,
                    settings: settings,
                    commonFormat: .pcmFormatFloat32,
                    interleaved: false
                )
            } catch {
                throw makeRecordingStartError(stage: "create recording file", error: error)
            }
            setPreparedRecording(file: file, url: url, format: format)

            inputNode.removeTap(onBus: 0)
            AppLogger.info(
                "Installing audio input tap: sampleRate=\(format.sampleRate), channels=\(format.channelCount)",
                context: "AudioRecorder"
            )
            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: hardwareFormat) { [weak self] buffer, time in
                do {
                    let converted = try converter.convert(buffer)
                    self?.handleAudioBuffer(converted, time: time, format: format)
                } catch {
                    self?.reportEncodingFailure(error)
                }
            }

            audioEngine.prepare()
            do {
                try await Self.startEngineWithBoundedRetry(
                    maxAttempts: 3,
                    retryDelayNanoseconds: 300_000_000,
                    startEngine: { try self.audioEngine.start() },
                    onRetry: { attempt, error in
                        AppLogger.error(
                            "Bounded retry of audioEngine.start() triggered: attempt=\(attempt)",
                            context: "AudioRecorder",
                            error: error
                        )
                        self.logEngineStartFailureDiagnostics(attempt: attempt, error: error)
                    }
                )
            } catch {
                logEngineStartFailureDiagnostics(attempt: 3, error: error)
                throw makeRecordingStartError(stage: "start audio engine", error: error)
            }

            try await waitForFirstRecordedBuffer()
            try markRecordingStarted()
            publishStartedRecording()
        } catch {
            cleanupFailedStart()
            throw error
        }
    }

    private func refreshMicrophones() {
        let session = AVAudioSession.sharedInstance()
        let inputs = (session.availableInputs ?? []).map {
            RecordingMicrophone(id: $0.uid, name: $0.portName, isBluetooth: $0.portType == .bluetoothHFP)
        }
        let selected = session.currentRoute.inputs.first?.uid
        DispatchQueue.main.async {
            self.microphoneInputs = inputs
            self.selectedMicrophoneID = selected
        }
    }

    @MainActor
    func switchMicrophone(to id: String) async throws {
        let session = AVAudioSession.sharedInstance()
        guard let port = session.availableInputs?.first(where: { $0.uid == id }) else {
            throw AudioRecorderError.microphoneSwitchFailed("The selected microphone is no longer available.")
        }
        guard session.currentRoute.inputs.first?.uid != id else { return }
        try beginMicrophoneSwitch()
        do {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
            let usesBluetoothHFP = port.portType == .bluetoothHFP
            try session.setMode(usesBluetoothHFP ? .voiceChat : .default)
            try session.setPreferredSampleRate(preferredRecordingSampleRate(usesBluetoothHFP: usesBluetoothHFP))
            try session.setPreferredInput(port)
            var routeReady = false
            for _ in 0..<40 {
                try ensureMicrophoneSwitchActive()
                if session.currentRoute.inputs.contains(where: { $0.uid == id }) {
                    routeReady = true
                    break
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            guard routeReady else {
                throw AudioRecorderError.microphoneSwitchFailed("The selected microphone did not become active.")
            }
            let node = audioEngine.inputNode
            let hardwareFormat = try await waitForStableInputTapFormat(on: node)
            try ensureMicrophoneSwitchActive()
            guard let format = currentInputFormat else { throw AudioRecorderError.noActiveRecording }
            let converter = try RecordingInputConverter(from: hardwareFormat, to: format)
            node.installTap(onBus: 0, bufferSize: 1_024, format: hardwareFormat) { [weak self] buffer, time in
                do {
                    let converted = try converter.convert(buffer)
                    self?.handleAudioBuffer(converted, time: time, format: format)
                } catch {
                    self?.reportEncodingFailure(error)
                }
            }
            audioEngine.prepare()
            try audioEngine.start()
            let initialFrames = recordedFrameCount()
            var receivedAudio = false
            for _ in 0..<100 {
                try ensureMicrophoneSwitchActive()
                if recordedFrameCount() > initialFrames, audioEngine.isRunning {
                    receivedAudio = true
                    break
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            guard receivedAudio else {
                throw AudioRecorderError.microphoneSwitchFailed("No audio was received from the selected microphone.")
            }
            try completeMicrophoneSwitch()
            refreshMicrophones()
            AppLogger.info("Recording microphone switched to \(port.portName)", context: "AudioRecorder")
        } catch {
            stopRecordingAfterUnexpectedAudioChange(
                message: String(localized: "Microphone switching failed. The saved part is available for transcription.") + " " + error.localizedDescription
            )
            throw error
        }
    }

    private func beginMicrophoneSwitch() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard recordingState == .recording else { throw AudioRecorderError.noActiveRecording }
        recordingState = .switchingMicrophone
    }

    private func ensureMicrophoneSwitchActive() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard recordingState == .switchingMicrophone else { throw AudioRecorderError.noActiveRecording }
    }

    private func completeMicrophoneSwitch() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard recordingState == .switchingMicrophone else { throw AudioRecorderError.noActiveRecording }
        recordingState = .recording
    }

    private func recordedFrameCount() -> AVAudioFramePosition {
        stateLock.lock()
        defer { stateLock.unlock() }
        return recordedFrames
    }

    static func recordingFileSettings(sampleRate: Double) -> [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: recordingBitRate,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
    }

    static func startEngineWithBoundedRetry(
        maxAttempts: Int,
        retryDelayNanoseconds: UInt64,
        startEngine: () throws -> Void,
        onRetry: (_ attempt: Int, _ error: Error) -> Void,
        sleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) async throws {
        precondition(maxAttempts > 0)

        for attempt in 1...maxAttempts {
            do {
                try startEngine()
                return
            } catch {
                guard attempt < maxAttempts else { throw error }
                onRetry(attempt, error)
                try await sleep(retryDelayNanoseconds)
            }
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

    private func setPreparedRecording(file: AVAudioFile, url: URL, format: AVAudioFormat) {
        stateLock.lock()
        recordingFile = file
        recordingURL = url
        inputFormat = format
        recordedFrames = 0
        stateLock.unlock()
    }

    private func waitForFirstRecordedBuffer() async throws {
        let maxAttempts = 100
        let retryDelayNanoseconds: UInt64 = 50_000_000

        for attempt in 1...maxAttempts {
            let progress = recordingProgressSnapshot()

            if progress.hasRecordedAudio, audioEngine.isRunning {
                AppLogger.info(
                    "Confirmed first recorded audio buffer: attempts=\(attempt)",
                    context: "AudioRecorder"
                )
                return
            }

            guard progress.state == .starting, audioEngine.isRunning else {
                throw AudioRecorderError.recordingStartFailed(
                    "audio engine stopped before the first audio buffer was recorded"
                )
            }

            if attempt < maxAttempts {
                try await Task.sleep(nanoseconds: retryDelayNanoseconds)
            }
        }

        let session = AVAudioSession.sharedInstance()
        let route = currentRouteDescription(session: session)
        AppLogger.error(
            "Audio engine started but no input buffer was recorded: sampleRate=\(session.sampleRate), inputs=[\(route.inputs)], outputs=[\(route.outputs)]",
            context: "AudioRecorder"
        )
        throw AudioRecorderError.recordingStartFailed(
            "audio engine started, but no microphone audio was received"
        )
    }

    private func recordingProgressSnapshot() -> (hasRecordedAudio: Bool, state: RecordingState) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (recordedFrames > 0, recordingState)
    }

    private func markRecordingStarted() throws {
        stateLock.lock()
        let canStart = recordingState == .starting
            && recordedFrames > 0
            && audioEngine.isRunning
        if canStart {
            recordingState = .recording
        }
        stateLock.unlock()

        guard canStart else {
            throw AudioRecorderError.recordingStartFailed(
                "recording stopped while confirming microphone audio"
            )
        }
    }

    private func publishStartedRecording() {
        DispatchQueue.main.async {
            self.recordingError = nil
            self.interruptionMessage = nil
            self.interruptedRecordingURL = nil
            self.currentTime = 0
            self.audioLevel = 0
            self.isRecording = true
            self.refreshMicrophones()
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
            if isUsableInputTapFormat(format) {
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

    private func isUsableInputTapFormat(_ format: AVAudioFormat) -> Bool {
        format.sampleRate > 0 && format.channelCount > 0
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

    private func setupSession(context: RecordingStartContext) async throws {
        AudioSessionOwnership.shared.beginRecording()
        let session = AVAudioSession.sharedInstance()
        let bluetoothInput = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP })
        let usesBluetoothHFP = bluetoothInput != nil || session.currentRoute.inputs.contains { $0.portType == .bluetoothHFP }
        let sessionMode: AVAudioSession.Mode = usesBluetoothHFP ? .voiceChat : .default
        let categoryOptions = Self.recordingCategoryOptions(
            usesBluetoothHFP: usesBluetoothHFP,
            context: context
        )

        try performAudioSessionStep(
            "set category (context=\(context), options=\(categoryOptions.rawValue))"
        ) {
            try session.setCategory(
                .playAndRecord,
                mode: sessionMode,
                options: categoryOptions
            )
        }

        let preferredSampleRate = preferredRecordingSampleRate(usesBluetoothHFP: usesBluetoothHFP)
        try performAudioSessionStep("set preferred sample rate \(preferredSampleRate)") {
            try session.setPreferredSampleRate(preferredSampleRate)
        }

        do {
            try session.setActive(true)
            AppLogger.info("Recording audio session step completed: activate session", context: "AudioRecorder")
        } catch {
            let nsError = error as NSError
            if Self.isBackgroundSessionActivationDenial(
                context: context,
                domain: nsError.domain,
                code: nsError.code
            ) {
                AppLogger.error(
                    "Audio session activation denied while app is in background: domain=\(nsError.domain), code=\(nsError.code); foreground continuation is required to start recording",
                    context: "AudioRecorder",
                    error: error
                )
                throw AudioRecorderError.backgroundSessionActivationDenied
            }
            throw makeRecordingStartError(stage: "activate session", error: error)
        }
        if let bluetoothInput {
            try selectBluetoothHFPInput(bluetoothInput, session: session)
            try await waitForBluetoothHFPRoute(session: session, preferredInput: bluetoothInput)
        }
        logCurrentAudioRoute(session: session, event: "Recording audio session activated")
    }

    // iOS never lets a third-party app activate a recording session from the
    // background — not even inside an AudioRecordingIntent with an active Live
    // Activity. The denial surfaces as '!int' (cannotInterruptOthers) or
    // '!rec' (cannotStartRecording); callers must continue in the foreground.
    static func isBackgroundSessionActivationDenial(
        context: RecordingStartContext,
        domain: String,
        code: Int
    ) -> Bool {
        guard context == .backgroundIntent, domain == NSOSStatusErrorDomain else { return false }
        return code == AVAudioSession.ErrorCode.cannotInterruptOthers.rawValue
            || code == AVAudioSession.ErrorCode.cannotStartRecording.rawValue
    }

    static func recordingCategoryOptions(
        usesBluetoothHFP: Bool,
        context: RecordingStartContext
    ) -> AVAudioSession.CategoryOptions {
        // iOS refuses to start recording I/O from the background when the
        // session is mixable (AUIOClient_StartIO fails with 'what' 2003329396),
        // so background-intent starts must use a non-mixable session.
        switch context {
        case .foreground:
            return usesBluetoothHFP
                ? [.allowBluetoothHFP]
                : [.defaultToSpeaker, .mixWithOthers, .allowBluetoothHFP]
        case .backgroundIntent:
            return usesBluetoothHFP
                ? [.allowBluetoothHFP]
                : [.defaultToSpeaker, .allowBluetoothHFP]
        }
    }

    private func preferredRecordingSampleRate(usesBluetoothHFP: Bool) -> Double {
        usesBluetoothHFP ? Self.bluetoothHFPRecordingSampleRate : Self.recordingSampleRate
    }

    private func selectBluetoothHFPInput(_ bluetoothInput: AVAudioSessionPortDescription, session: AVAudioSession) throws {
        try performAudioSessionStep("set Bluetooth HFP preferred input \(bluetoothInput.portName)") {
            try session.setPreferredInput(bluetoothInput)
        }
    }

    private func waitForBluetoothHFPRoute(
        session: AVAudioSession,
        preferredInput: AVAudioSessionPortDescription
    ) async throws {
        let maxAttempts = 20
        let retryDelayNanoseconds: UInt64 = 50_000_000
        var stableReadCount = 0

        for attempt in 1...maxAttempts {
            let route = session.currentRoute
            let usesPreferredInput = route.inputs.contains { input in
                input.uid == preferredInput.uid
                    || (input.portType == .bluetoothHFP && input.portName == preferredInput.portName)
            }
            let usesA2DPOutput = route.outputs.contains { $0.portType == .bluetoothA2DP }

            if usesPreferredInput, !usesA2DPOutput {
                stableReadCount += 1
                if stableReadCount >= 2 {
                    if attempt > 2 {
                        AppLogger.info(
                            "Bluetooth HFP route stabilized after preferred input selection: attempts=\(attempt)",
                            context: "AudioRecorder"
                        )
                    }
                    return
                }
            } else {
                stableReadCount = 0
            }

            if attempt < maxAttempts {
                try await Task.sleep(nanoseconds: retryDelayNanoseconds)
            }
        }

        let route = currentRouteDescription(session: session)
        AppLogger.error(
            "Bluetooth HFP route did not become active after selecting preferred input: preferredInput=\(preferredInput.portName)(\(preferredInput.portType.rawValue)), sampleRate=\(session.sampleRate), preferredSampleRate=\(session.preferredSampleRate), inputs=[\(route.inputs)], outputs=[\(route.outputs)]",
            context: "AudioRecorder"
        )
        throw AudioRecorderError.recordingStartFailed("Bluetooth HFP route unavailable after selecting preferred input")
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

    private func logEngineStartFailureDiagnostics(attempt: Int, error: Error) {
        let session = AVAudioSession.sharedInstance()
        let nsError = error as NSError
        let route = currentRouteDescription(session: session)
        let availableInputs = session.availableInputs?.map {
            "\($0.portName)(\($0.portType.rawValue))"
        }.joined(separator: ", ") ?? "none"
        AppLogger.error(
            "audioEngine.start() failure diagnostics: attempt=\(attempt), errorDomain=\(nsError.domain), errorCode=\(nsError.code), isOtherAudioPlaying=\(session.isOtherAudioPlaying), secondaryAudioShouldBeSilencedHint=\(session.secondaryAudioShouldBeSilencedHint), availableInputs=[\(availableInputs)], inputs=[\(route.inputs)], outputs=[\(route.outputs)], sampleRate=\(session.sampleRate), preferredSampleRate=\(session.preferredSampleRate), category=\(session.category.rawValue), categoryOptions=\(session.categoryOptions.rawValue), audioEngine=\(audioEngine.description)",
            context: "AudioRecorder",
            error: error
        )
    }

    private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime, format: AVAudioFormat) {
        switch writeAudioBuffer(buffer) {
        case .ignored:
            return
        case .failed(let error):
            reportEncodingFailure(error)
            return
        case .written(let elapsedTime):
            let level = averagePower(from: buffer)
            DispatchQueue.main.async {
                self.currentTime = elapsedTime
                self.audioLevel = level
            }

            handlerLock.lock()
            let handler = audioBufferHandler
            handlerLock.unlock()
            let sampleTime = AVAudioFramePosition((elapsedTime * format.sampleRate).rounded()) - AVAudioFramePosition(buffer.frameLength)
            handler?(buffer, AVAudioTime(sampleTime: sampleTime, atRate: format.sampleRate), format)
        }
    }

    private func writeAudioBuffer(_ buffer: AVAudioPCMBuffer) -> AudioBufferWriteResult {
        fileWriteLock.lock()
        var file: AVAudioFile?
        defer {
            file = nil
            fileWriteLock.unlock()
        }

        stateLock.lock()
        file = recordingFile
        let shouldRecord = recordingState == .starting || recordingState == .recording || recordingState == .switchingMicrophone
        stateLock.unlock()

        guard shouldRecord else { return .ignored }
        guard file != nil else {
            return .failed(AudioRecorderError.recordingEncodingFailed(
                String(localized: "Recording encoding failed") + ": recording file was not prepared"
            ))
        }

        let monoBuffer: AVAudioPCMBuffer
        do {
            monoBuffer = try Self.monoBuffer(
                from: buffer,
                outputFormat: file!.processingFormat
            )
            try file!.write(from: monoBuffer)
        } catch {
            return .failed(error)
        }

        stateLock.lock()
        recordedFrames += AVAudioFramePosition(monoBuffer.frameLength)
        let outputSampleRate = monoBuffer.format.sampleRate
        let elapsedTime = outputSampleRate > 0
            ? TimeInterval(recordedFrames) / outputSampleRate
            : 0
        stateLock.unlock()

        return .written(elapsedTime)
    }

    static func monoBuffer(
        from inputBuffer: AVAudioPCMBuffer,
        outputFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        let inputFormat = inputBuffer.format
        guard inputFormat.commonFormat == .pcmFormatFloat32,
              inputFormat.channelCount > 0,
              outputFormat.commonFormat == .pcmFormatFloat32,
              outputFormat.channelCount == 1,
              !outputFormat.isInterleaved,
              abs(inputFormat.sampleRate - outputFormat.sampleRate) < 0.5 else {
            throw AudioRecorderError.recordingEncodingFailed(
                String(localized: "Recording encoding failed")
                    + ": unsupported microphone format conversion"
            )
        }

        if inputFormat.channelCount == 1, !inputFormat.isInterleaved {
            return inputBuffer
        }

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: inputBuffer.frameLength
        ), let inputData = inputBuffer.floatChannelData,
           let outputData = outputBuffer.floatChannelData?[0] else {
            throw AudioRecorderError.recordingEncodingFailed(
                String(localized: "Recording encoding failed")
                    + ": could not allocate a mono recording buffer"
            )
        }

        let frameLength = Int(inputBuffer.frameLength)
        let channelCount = Int(inputFormat.channelCount)
        let channelScale = 1 / Float(channelCount)
        outputBuffer.frameLength = inputBuffer.frameLength

        if inputFormat.isInterleaved {
            let interleavedInput = inputData[0]
            for frame in 0..<frameLength {
                var sum: Float = 0
                let frameOffset = frame * channelCount
                for channel in 0..<channelCount {
                    sum += interleavedInput[frameOffset + channel]
                }
                outputData[frame] = sum * channelScale
            }
        } else {
            for frame in 0..<frameLength {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += inputData[channel][frame]
                }
                outputData[frame] = sum * channelScale
            }
        }

        return outputBuffer
    }

    private func finishActiveRecording() {
        setAudioBufferHandler(nil)
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        audioEngine.reset()

        // Wait for an in-flight tap callback to finish using AVAudioFile before
        // releasing it so the AAC container is finalized before validation.
        fileWriteLock.lock()
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
        fileWriteLock.unlock()

        DispatchQueue.main.async {
            self.currentTime = duration
            self.audioLevel = 0
            self.isRecording = false
        }
        deactivateSession()
    }

    private func reportEncodingFailure(_ error: Error) {
        guard transitionActiveRecordingToStopping(includingStarting: true) != nil else { return }
        let detail = error.localizedDescription
        let message = String(localized: "Recording encoding failed") + ": \(detail)"
        AppLogger.error(message, context: "AudioRecorder", error: error)
        DispatchQueue.main.async {
            self.recordingError = message
        }
        recordingStopQueue.async { [self] in
            finishActiveRecording()
        }
    }

    private func cleanupFailedStart() {
        setAudioBufferHandler(nil)
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.reset()
        fileWriteLock.lock()
        stateLock.lock()
        let failedRecordingURL = recordingURL
        recordingFile = nil
        recordingURL = nil
        inputFormat = nil
        recordedFrames = 0
        recordingState = .idle
        stateLock.unlock()
        fileWriteLock.unlock()
        if let failedRecordingURL, FileManager.default.fileExists(atPath: failedRecordingURL.path) {
            do {
                try FileManager.default.removeItem(at: failedRecordingURL)
            } catch {
                AppLogger.error(
                    "Failed to remove incomplete recording after startup failure",
                    context: "AudioRecorder",
                    error: error
                )
            }
        }
        DispatchQueue.main.async {
            self.currentTime = 0
            self.audioLevel = 0
            self.isRecording = false
        }
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioEngineConfigurationChange),
            name: .AVAudioEngineConfigurationChange,
            object: audioEngine
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMediaServicesWereReset),
            name: AVAudioSession.mediaServicesWereResetNotification,
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
        let message = String(localized: "Recording was interrupted by another audio app. The saved part is available for transcription.")
        stopRecordingAfterUnexpectedAudioChange(message: message)
    }

    @objc private func handleAudioEngineConfigurationChange(_ notification: Notification) {
        stateLock.lock()
        let switching = recordingState == .switchingMicrophone
        stateLock.unlock()
        guard !switching else { return }
        let message = String(localized: "Recording stopped because the audio input changed. The saved part is available for transcription.")
        stopRecordingAfterUnexpectedAudioChange(message: message)
    }

    @objc private func handleMediaServicesWereReset(_ notification: Notification) {
        AppLogger.error("Audio media services were reset", context: "AudioRecorder")
        let message = String(localized: "Recording stopped because audio services were reset. The saved part is available for transcription.")
        stopRecordingAfterUnexpectedAudioChange(message: message)
    }

    private func stopRecordingAfterUnexpectedAudioChange(message: String) {
        guard let url = transitionActiveRecordingToStopping(includingStarting: false) else { return }

        finishActiveRecording()
        let savedRecordingURL: URL?
        let publishedMessage: String
        do {
            savedRecordingURL = try validateRecordingFile(at: url)
            publishedMessage = message
        } catch {
            savedRecordingURL = nil
            publishedMessage = "\(message) \(error.localizedDescription)"
        }

        AppLogger.error(publishedMessage, context: "AudioRecorder")
        DispatchQueue.main.async {
            self.interruptionMessage = publishedMessage
            self.recordingError = publishedMessage
            self.interruptedRecordingURL = savedRecordingURL
        }
    }

    private func transitionActiveRecordingToStopping(includingStarting: Bool) -> URL? {
        stateLock.lock()
        defer { stateLock.unlock() }
        let canStop = recordingState == .recording || recordingState == .switchingMicrophone
            || (includingStarting && recordingState == .starting)
        guard canStop, let recordingURL else { return nil }
        recordingState = .stopping
        return recordingURL
    }

    @objc private func handleAudioRouteChange(_ notification: Notification) {
        refreshMicrophones()
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
        AudioSessionOwnership.shared.endRecording {
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                AppLogger.error("Failed to deactivate audio session after recording", context: "AudioRecorder", error: error)
            }
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
    case backgroundSessionActivationDenied
    case microphoneSwitchFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphoneSwitchFailed(let detail):
            return String(localized: "Microphone switching failed.") + " " + detail
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
        case .backgroundSessionActivationDenied:
            return String(localized: "iOS does not allow starting recording while the app is in the background. Open the app to start recording.")
        }
    }
}

struct RecordingMicrophone: Identifiable, Equatable {
    let id: String
    let name: String
    let isBluetooth: Bool
}

private enum RecordingState {
    case switchingMicrophone
    case idle
    case starting
    case recording
    case stopping
}

private enum AudioBufferWriteResult {
    case ignored
    case written(TimeInterval)
    case failed(Error)
}

/// Keeps the recording and live recognizer format unchanged across hardware routes.
final class RecordingInputConverter {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat

    init(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioRecorderError.microphoneSwitchFailed("Unsupported microphone audio format.")
        }
        self.converter = converter
        self.outputFormat = outputFormat
    }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * outputFormat.sampleRate / buffer.format.sampleRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw AudioRecorderError.microphoneSwitchFailed("Could not allocate an audio conversion buffer.")
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard !supplied else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        guard status != .error else {
            throw AudioRecorderError.microphoneSwitchFailed("Microphone audio conversion failed.")
        }
        return output
    }
}
