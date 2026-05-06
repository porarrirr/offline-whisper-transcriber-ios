import Foundation
import AVFoundation

struct TranscriptionResult {
    let text: String
    let segments: [TranscriptionSegment]
    let language: String?
}

class WhisperContext: ObservableObject {
    @Published var isModelLoaded = false
    @Published var isProcessing = false
    @Published var progress: Double = 0
    @Published var resultText: String = ""
    @Published var errorMessage: String?
    
    private var whisperContext: OpaquePointer?
    func loadModel(path: String, useFlashAttention: Bool = false) {
        guard FileManager.default.fileExists(atPath: path) else {
            errorMessage = "モデルファイルが見つかりません"
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var params = whisper_context_default_params()
            params.use_gpu = true
            params.flash_attn = useFlashAttention
            
            let context = whisper_init_from_file_with_params(path, params)
            
            DispatchQueue.main.async {
                if let context = context {
                    self?.whisperContext = context
                    self?.isModelLoaded = true
                    self?.errorMessage = nil
                } else {
                    self?.errorMessage = "モデルの読み込みに失敗しました"
                }
            }
        }
    }
    
    func transcribe(
        audioPath: String,
        language: String = "ja",
        translate: Bool = false,
        prompt: String = "",
        useVAD: Bool = false,
        vadModelPath: String? = nil,
        onProgress: ((Double) -> Void)? = nil
    ) async -> TranscriptionResult? {
        guard let context = whisperContext else {
            await MainActor.run {
                errorMessage = "モデルが読み込まれていません"
            }
            return nil
        }
        
        await MainActor.run {
            isProcessing = true
            progress = 0
            resultText = ""
        }
        
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else {
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
                    onProgress: onProgress
                )
                
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.progress = 1.0
                    if let result = result {
                        self.resultText = result.text
                    }
                    continuation.resume(returning: result)
                }
            }
        }
    }
    
    private func performTranscription(
        context: OpaquePointer,
        audioPath: String,
        language: String,
        translate: Bool,
        prompt: String,
        useVAD: Bool,
        vadModelPath: String?,
        onProgress: ((Double) -> Void)?
    ) -> TranscriptionResult? {
        do {
            let samples = try readMonoSamples(from: URL(fileURLWithPath: audioPath))
            return runWhisper(
                context: context,
                samples: samples,
                language: language,
                translate: translate,
                prompt: prompt,
                useVAD: useVAD,
                vadModelPath: vadModelPath,
                onProgress: onProgress
            )
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.errorMessage = error.localizedDescription
            }
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
        onProgress: ((Double) -> Void)?
    ) -> TranscriptionResult? {
        guard !samples.isEmpty else { return nil }
        
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.translate = translate
        params.no_timestamps = false
        params.token_timestamps = true
        params.detect_language = language.isEmpty || language == "auto"
        params.temperature_inc = 0
        let languageCString = params.detect_language ? nil : strdup(language)
        defer {
            if let languageCString {
                free(languageCString)
            }
        }
        params.language = languageCString
        params.n_threads = Int32(max(1, min(ProcessInfo.processInfo.processorCount - 1, 4)))
        params.offset_ms = 0
        params.duration_ms = 0
        
        let promptCString = prompt.isEmpty ? nil : strdup(prompt)
        defer {
            if let promptCString {
                free(promptCString)
            }
        }
        params.initial_prompt = promptCString
        
        let vadModelCString: UnsafeMutablePointer<CChar>?
        if useVAD {
            guard let vadModelPath, FileManager.default.fileExists(atPath: vadModelPath) else {
                DispatchQueue.main.async { [weak self] in
                    self?.errorMessage = "VADモデルが見つかりません。設定からVADモデルをダウンロードしてください。"
                }
                return nil
            }

            params.vad = true
            vadModelCString = strdup(vadModelPath)
            params.vad_model_path = vadModelCString
            var vadParams = whisper_vad_default_params()
            vadParams.threshold = 0.6
            vadParams.min_speech_duration_ms = 250
            vadParams.min_silence_duration_ms = 500
            params.vad_params = vadParams
        } else {
            vadModelCString = nil
        }
        defer {
            if let vadModelCString {
                free(vadModelCString)
            }
        }
        
        // Progress callback
        let progressPointer = UnsafeMutablePointer<WhisperProgressCallbackData>.allocate(capacity: 1)
        progressPointer.pointee = WhisperProgressCallbackData(callback: onProgress)
        defer { progressPointer.deallocate() }
        
        if onProgress != nil {
            params.progress_callback = whisperProgressCallback
            params.progress_callback_user_data = UnsafeMutableRawPointer(progressPointer)
        }
        
        let ret = samples.withUnsafeBufferPointer { buffer in
            whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
        }
        
        guard ret == 0 else {
            DispatchQueue.main.async { [weak self] in
                self?.errorMessage = "Whisperの文字起こし処理に失敗しました（code: \(ret)）"
            }
            return nil
        }
        
        let nSegments = whisper_full_n_segments(context)
        var segments: [TranscriptionSegment] = []
        var fullText = ""
        
        for i in 0..<nSegments {
            let t0 = whisper_full_get_segment_t0(context, i)
            let t1 = whisper_full_get_segment_t1(context, i)
            
            if let segmentText = whisper_full_get_segment_text(context, i) {
                let text = String(cString: segmentText).trimmingCharacters(in: .whitespacesAndNewlines)
                let start = Double(t0) / 100.0
                let end = Double(t1) / 100.0
                
                let segment = TranscriptionSegment(
                    id: i,
                    start: start,
                    end: end,
                    text: text
                )
                segments.append(segment)
                
                if !fullText.isEmpty {
                    fullText += "\n"
                }
                fullText += text
            }
        }
        
        var detectedLanguage: String? = nil
        if language == "auto" || language.isEmpty {
            detectedLanguage = detectLanguage(context: context)
        }
        
        return TranscriptionResult(
            text: fullText.trimmingCharacters(in: .whitespacesAndNewlines),
            segments: segments,
            language: detectedLanguage ?? language
        )
    }
    
    private func detectLanguage(context: OpaquePointer) -> String? {
        let langId = whisper_lang_auto_detect(context, 0, 4, nil)
        guard langId >= 0 else { return nil }
        if let langStr = whisper_lang_str(Int32(langId)) {
            return String(cString: langStr)
        }
        return nil
    }
    
    func unloadModel() {
        if let context = whisperContext {
            whisper_free(context)
            whisperContext = nil
        }
        isModelLoaded = false
    }
    
    deinit {
        unloadModel()
    }
}

private struct WhisperProgressCallbackData {
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

enum WhisperContextError: LocalizedError {
    case invalidAudioFile
    case audioBufferCreationFailed
    case emptyAudioFile
    case unsupportedPCMFormat
    
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
        }
    }
}
