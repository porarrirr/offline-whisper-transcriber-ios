import Foundation
import AVFoundation

struct TranscriptionResult {
    let text: String
    let segments: [TranscriptionSegment]
    let language: String?
}

private struct WhisperContextPointer: @unchecked Sendable {
    let value: OpaquePointer
}

protocol WhisperContextManaging: Sendable {
    func isLoaded(path: String, useFlashAttention: Bool, useCoreML: Bool) -> Bool
    func loadModel(path: String, useFlashAttention: Bool, useCoreML: Bool) async throws
    func unloadModel()
    func unloadModelAndWait() async
    func transcribeChunk(samples: [Float], startOffset: TimeInterval, segmentIDOffset: Int,
                         language: String, translate: Bool, prompt: String, useVAD: Bool,
                         vadModelPath: String?, cancellationToken: WhisperCancellationToken?,
                         onProgress: ((Double) -> Void)?) async throws -> TranscriptionResult
}

final class WhisperContext: WhisperContextManaging, @unchecked Sendable {
    private var _isModelLoaded: Bool = false
    private(set) var isModelLoaded: Bool {
        get { onWorkQueue { _isModelLoaded } }
        set { onWorkQueue { _isModelLoaded = newValue } }
    }
    private var _errorMessage: String? = nil
    private(set) var errorMessage: String? {
        get { onWorkQueue { _errorMessage } }
        set { onWorkQueue { _errorMessage = newValue } }
    }

    private let workQueue = DispatchQueue(label: "com.porarrirr.whisper-context", qos: .userInitiated)
    private var whisperContext: OpaquePointer?
    private var _loadedModelPath: String? = nil
    private(set) var loadedModelPath: String? {
        get { onWorkQueue { _loadedModelPath } }
        set { onWorkQueue { _loadedModelPath = newValue } }
    }
    private var _loadedUseFlashAttention: Bool = false
    private(set) var loadedUseFlashAttention: Bool {
        get { onWorkQueue { _loadedUseFlashAttention } }
        set { onWorkQueue { _loadedUseFlashAttention = newValue } }
    }
    private var _loadedUseCoreML: Bool = false
    private(set) var loadedUseCoreML: Bool {
        get { onWorkQueue { _loadedUseCoreML } }
        set { onWorkQueue { _loadedUseCoreML = newValue } }
    }

    private let queueKey = DispatchSpecificKey<Bool>()

    init() { workQueue.setSpecific(key: queueKey, value: true) }

    private func onWorkQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return body() }
        return workQueue.sync(execute: body)
    }

    func isLoaded(path: String, useFlashAttention: Bool, useCoreML: Bool) -> Bool {
        let effectiveUseFlashAttention = Self.effectiveUseFlashAttention(useFlashAttention)
        let effectiveUseCoreML = Self.effectiveUseCoreML(useCoreML)

        return onWorkQueue { isModelLoaded
            && loadedModelPath == path
            && loadedUseFlashAttention == effectiveUseFlashAttention
            && loadedUseCoreML == effectiveUseCoreML }
    }

    func loadModel(path: String, useFlashAttention: Bool, useCoreML: Bool) async throws {
        guard FileManager.default.fileExists(atPath: path) else {
            errorMessage = "モデルファイルが見つかりません"
            throw WhisperModelServiceError.modelFileMissing
        }

        let effectiveUseFlashAttention = Self.effectiveUseFlashAttention(useFlashAttention)
        let effectiveUseCoreML = Self.effectiveUseCoreML(useCoreML)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            workQueue.async { [self] in
                if isLoaded(path: path, useFlashAttention: useFlashAttention, useCoreML: useCoreML) {
                    continuation.resume()
                    return
                }
                if let old = detachLoadedContext() { whisper_free(old.value) }
                errorMessage = nil

                var params = whisper_context_default_params()
                params.use_gpu = Self.supportsGPUAcceleration
                params.flash_attn = effectiveUseFlashAttention
                params.use_coreml = effectiveUseCoreML

                let context = whisper_init_from_file_with_params(path, params)
                if let context {
                    self.whisperContext = context
                    self.loadedModelPath = path
                    self.loadedUseFlashAttention = effectiveUseFlashAttention
                    self.loadedUseCoreML = effectiveUseCoreML
                    self.isModelLoaded = true
                    self.errorMessage = nil
                    continuation.resume()
                } else {
                    self.errorMessage = "モデルの読み込みに失敗しました"
                    continuation.resume(throwing: WhisperModelServiceError.modelLoadFailed)
                }
            }
        }
    }

    private static var supportsGPUAcceleration: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }

    private static var supportsCoreMLAcceleration: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }

    private static func effectiveUseFlashAttention(_ requested: Bool) -> Bool {
        requested && supportsGPUAcceleration
    }

    private static func effectiveUseCoreML(_ requested: Bool) -> Bool {
        requested && supportsCoreMLAcceleration
    }
    
    func transcribe(
        audioPath: String,
        language: String = "ja",
        translate: Bool = false,
        prompt: String = "",
        useVAD: Bool = false,
        vadModelPath: String? = nil,
        cancellationToken: WhisperCancellationToken? = nil,
        onProgress: ((Double) -> Void)? = nil
    ) async -> TranscriptionResult? {
        return await withCheckedContinuation { continuation in
            workQueue.async { [self] in
                guard let context = whisperContext else {
                    setError("モデルが読み込まれていません")
                    continuation.resume(returning: nil)
                    return
                }
                let result = self.performTranscription(
                    context: context,
                    audioPath: audioPath,
                    language: language,
                    translate: translate,
                    prompt: prompt,
                    useVAD: useVAD,
                    vadModelPath: vadModelPath,
                    cancellationToken: cancellationToken,
                    onProgress: onProgress
                )
                
                continuation.resume(returning: result)
            }
        }
    }

    func transcribe(
        samples: [Float],
        language: String = "ja",
        translate: Bool = false,
        prompt: String = "",
        useVAD: Bool = false,
        vadModelPath: String? = nil,
        cancellationToken: WhisperCancellationToken? = nil,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> TranscriptionResult {
        return try await withCheckedThrowingContinuation { continuation in
            workQueue.async { [self] in
                guard let context = whisperContext else {
                    let message = "モデルが読み込まれていません"
                    setError(message)
                    continuation.resume(throwing: WhisperContextError.transcriptionFailed(message))
                    return
                }
                do {
                    let result = try self.runWhisper(
                        context: context,
                        samples: samples,
                        language: language,
                        translate: translate,
                        prompt: prompt,
                        useVAD: useVAD,
                        vadModelPath: vadModelPath,
                        cancellationToken: cancellationToken,
                        onProgress: onProgress
                    )
                    continuation.resume(returning: result)
                } catch {
                    if !(error is CancellationError) {
                        self.setError(error.localizedDescription)
                    }
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func transcribeChunk(
        samples: [Float],
        startOffset: TimeInterval,
        segmentIDOffset: Int,
        language: String = "ja",
        translate: Bool = false,
        prompt: String = "",
        useVAD: Bool = false,
        vadModelPath: String? = nil,
        cancellationToken: WhisperCancellationToken? = nil,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> TranscriptionResult {
        let result = try await transcribe(
            samples: samples,
            language: language,
            translate: translate,
            prompt: prompt,
            useVAD: useVAD,
            vadModelPath: vadModelPath,
            cancellationToken: cancellationToken,
            onProgress: onProgress
        )

        let offsetSegments = result.segments.enumerated().map { index, segment in
            TranscriptionSegment(
                id: segmentIDOffset + index,
                start: segment.start + startOffset,
                end: segment.end + startOffset,
                text: segment.text
            )
        }

        return TranscriptionResult(
            text: result.text,
            segments: offsetSegments,
            language: result.language
        )
    }
    
    private func performTranscription(
        context: OpaquePointer,
        audioPath: String,
        language: String,
        translate: Bool,
        prompt: String,
        useVAD: Bool,
        vadModelPath: String?,
        cancellationToken: WhisperCancellationToken?,
        onProgress: ((Double) -> Void)?
    ) -> TranscriptionResult? {
        do {
            let samples = try readMonoSamples(from: URL(fileURLWithPath: audioPath))
            return try runWhisper(
                context: context,
                samples: samples,
                language: language,
                translate: translate,
                prompt: prompt,
                useVAD: useVAD,
                vadModelPath: vadModelPath,
                cancellationToken: cancellationToken,
                onProgress: onProgress
            )
        } catch {
            if error is CancellationError {
                return nil
            }
            setError(error.localizedDescription)
            return nil
        }
    }
    
    private func readMonoSamples(from url: URL) throws -> [Float] {
        let audioFile = try AVAudioFile(forReading: url)
        let sourceFormat = audioFile.processingFormat
        guard sourceFormat.channelCount > 0 else {
            throw WhisperContextError.invalidAudioFile
        }
        
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(audioFile.length)
        ) else {
            throw WhisperContextError.audioBufferCreationFailed
        }
        
        try audioFile.read(into: buffer)
        guard buffer.frameLength > 0 else {
            throw WhisperContextError.emptyAudioFile
        }
        
        let frameCount = Int(buffer.frameLength)
        var samples = [Float](repeating: 0, count: frameCount)
        
        if let floatChannels = buffer.floatChannelData {
            let channelCount = Int(sourceFormat.channelCount)
            for frame in 0..<frameCount {
                var mixedSample: Float = 0
                for channel in 0..<channelCount {
                    mixedSample += floatChannels[channel][frame]
                }
                samples[frame] = mixedSample / Float(channelCount)
            }
            return samples
        }
        
        if let int16Channels = buffer.int16ChannelData {
            let channelCount = Int(sourceFormat.channelCount)
            for frame in 0..<frameCount {
                var mixedSample: Float = 0
                for channel in 0..<channelCount {
                    mixedSample += Float(int16Channels[channel][frame]) / Float(Int16.max)
                }
                samples[frame] = mixedSample / Float(channelCount)
            }
            return samples
        }
        
        throw WhisperContextError.unsupportedPCMFormat
    }
    
    private func runWhisper(
        context: OpaquePointer,
        samples: [Float],
        language: String,
        translate: Bool,
        prompt: String,
        useVAD: Bool,
        vadModelPath: String?,
        cancellationToken: WhisperCancellationToken?,
        onProgress: ((Double) -> Void)?
    ) throws -> TranscriptionResult {
        guard !samples.isEmpty else {
            throw WhisperContextError.emptyAudioFile
        }
        
        var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.translate = translate
        params.no_timestamps = false
        params.token_timestamps = false
        // Keep decoding stable on long audio while allowing whisper.cpp to recover from repetition loops.
        params.temperature = 0.0
        params.temperature_inc = 0.2
        params.beam_search.beam_size = 5
        params.suppress_nst = true
        params.max_tokens = 96
        // `detect_language` は言語検出のみで終了するモード。自動言語の文字起こしでは false のまま language を "auto" にする。
        params.detect_language = false
        let whisperLanguage = (language.isEmpty || language == "auto") ? "auto" : language
        let languageCString = strdup(whisperLanguage)
        defer {
            if let languageCString {
                free(languageCString)
            }
        }
        params.language = UnsafePointer(languageCString!)
        params.n_threads = Int32(max(1, min(ProcessInfo.processInfo.processorCount - 1, 4)))
        params.offset_ms = 0
        params.duration_ms = 0
        
        let promptCString = strdup(prompt)
        defer {
            if let promptCString {
                free(promptCString)
            }
        }
        params.initial_prompt = UnsafePointer(promptCString!)
        
        let vadModelCString: UnsafeMutablePointer<CChar>?
        if useVAD {
            guard let vadModelPath, FileManager.default.fileExists(atPath: vadModelPath) else {
                throw WhisperContextError.transcriptionFailed(
                    "VADモデルが見つかりません。設定からVADモデルをダウンロードしてください。"
                )
            }

            params.vad = true
            vadModelCString = strdup(vadModelPath)
            params.vad_model_path = UnsafePointer(vadModelCString!)
            var vadParams = whisper_vad_default_params()
            vadParams.threshold = 0.5
            vadParams.min_speech_duration_ms = 250
            vadParams.min_silence_duration_ms = 500
            vadParams.speech_pad_ms = 100
            params.vad_params = vadParams
        } else {
            vadModelCString = nil
        }
        defer {
            if let vadModelCString {
                free(vadModelCString)
            }
        }
        
        let progressStorage = WhisperProgressCallbackStorage(callback: onProgress)
        defer { withExtendedLifetime(progressStorage) {} }
        let progressPointer = progressStorage.pointer

        if onProgress != nil {
            params.progress_callback = whisperProgressCallback
            params.progress_callback_user_data = UnsafeMutableRawPointer(progressPointer)
        }

        if let cancellationToken {
            params.abort_callback = whisperAbortCallback
            params.abort_callback_user_data = Unmanaged.passUnretained(cancellationToken).toOpaque()
        }
        
        let ret = samples.withUnsafeBufferPointer { buffer in
            whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
        }
        
        guard ret == 0 else {
            if cancellationToken?.isCancelled == true {
                throw CancellationError()
            }
            throw WhisperContextError.transcriptionFailed(
                "Whisperの文字起こし処理に失敗しました（code: \(ret)）"
            )
        }
        
        let nSegments = whisper_full_n_segments(context)
        var segments: [TranscriptionSegment] = []
        segments.reserveCapacity(Int(nSegments))
        
        for i in 0..<nSegments {
            let t0 = whisper_full_get_segment_t0(context, i)
            let t1 = whisper_full_get_segment_t1(context, i)
            
            if let segmentText = whisper_full_get_segment_text(context, i) {
                let text = String(cString: segmentText).trimmingCharacters(in: .whitespacesAndNewlines)
                let start = Double(t0) / 100.0
                let end = Double(t1) / 100.0
                
                let segment = TranscriptionSegment(
                    id: Int(i),
                    start: start,
                    end: end,
                    text: text
                )
                segments.append(segment)
            }
        }
        
        var detectedLanguage: String? = nil
        if language == "auto" || language.isEmpty {
            detectedLanguage = detectLanguage(context: context)
        }
        
        return TranscriptionResult(
            text: TranscriptionSegment.plainText(from: segments),
            segments: segments,
            language: detectedLanguage ?? language
        )
    }
    
    private func detectLanguage(context: OpaquePointer) -> String? {
        let langId = whisper_full_lang_id(context)
        guard langId >= 0 else { return nil }
        if let langStr = whisper_lang_str(Int32(langId)) {
            return String(cString: langStr)
        }
        return nil
    }
    
    func unloadModel() {
        onWorkQueue {
            if let context = detachLoadedContext() { whisper_free(context.value) }
        }
    }

    func unloadModelAndWait() async {
        await withCheckedContinuation { continuation in
            workQueue.async { [self] in
                unloadModel()
                continuation.resume()
            }
        }
    }

    private func detachLoadedContext() -> WhisperContextPointer? {
        guard let context = whisperContext else {
            clearLoadedModelState()
            return nil
        }
        whisperContext = nil
        clearLoadedModelState()
        return WhisperContextPointer(value: context)
    }

    private func clearLoadedModelState() {
        isModelLoaded = false
        loadedModelPath = nil
        loadedUseFlashAttention = false
        loadedUseCoreML = false
    }

    private func setError(_ message: String) {
        errorMessage = message
        AppLogger.error(message, context: "WhisperContext")
    }
    
    deinit {
        unloadModel()
    }
}

final class WhisperCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

final class WhisperProgressCallbackStorage {
    let pointer: UnsafeMutablePointer<WhisperProgressCallbackData>

    init(callback: ((Double) -> Void)?) {
        pointer = .allocate(capacity: 1)
        pointer.initialize(to: WhisperProgressCallbackData(callback: callback))
    }

    deinit {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }
}

struct WhisperProgressCallbackData {
    var callback: ((Double) -> Void)?
}

private func whisperProgressCallback(_: OpaquePointer?, _: OpaquePointer?, progress: Int32, userData: UnsafeMutableRawPointer?) {
    guard let userData = userData else { return }
    let data = userData.assumingMemoryBound(to: WhisperProgressCallbackData.self).pointee
    let progressValue = Double(progress) / 100.0
    DispatchQueue.main.async {
        data.callback?(progressValue)
    }
}

private func whisperAbortCallback(userData: UnsafeMutableRawPointer?) -> Bool {
    guard let userData else { return false }
    let token = Unmanaged<WhisperCancellationToken>.fromOpaque(userData).takeUnretainedValue()
    return token.isCancelled
}

enum WhisperContextError: LocalizedError {
    case invalidAudioFile
    case audioBufferCreationFailed
    case emptyAudioFile
    case unsupportedPCMFormat
    case transcriptionFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidAudioFile:
            return "音声ファイルのチャンネル情報が不正です"
        case .audioBufferCreationFailed:
            return "音声バッファの作成に失敗しました"
        case .emptyAudioFile:
            return "音声データが空です"
        case .unsupportedPCMFormat:
            return "対応していないPCM形式です"
        case .transcriptionFailed(let message):
            return message
        }
    }
}
