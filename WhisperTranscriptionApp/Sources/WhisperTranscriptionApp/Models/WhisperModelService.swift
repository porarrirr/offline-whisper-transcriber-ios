import Foundation

enum WhisperModelServiceError: LocalizedError {
    case modelFileMissing
    case modelLoadFailed

    var errorDescription: String? {
        switch self {
        case .modelFileMissing:
            return String(localized: "Model file was not found.")
        case .modelLoadFailed:
            return String(localized: "Failed to load model")
        }
    }
}

actor WhisperModelService {
    static let shared = WhisperModelService()

    private let context: any WhisperContextManaging
    private var accelerationMode: WhisperAccelerationMode = .metal(reason: .encoderMissing)
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var sessionEncoders: [String: String] = [:]
    private var releaseWhenFinished = false

    init(context: any WhisperContextManaging = WhisperContext()) {
        self.context = context
    }

    // A lease covers loading AND all chunks. Actor isolation alone does not protect
    // the native model across suspension points.
    private func acquire() async throws {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    private func release() {
        if releaseWhenFinished {
            context.unloadModel()
            releaseWhenFinished = false
        }
        if waiters.isEmpty { busy = false }
        else { waiters.removeFirst().resume() }
    }

    func startSession(modelPath: String, encoderPath: String?, useFlashAttention: Bool, coreMLMelBinCount: Int) {
        sessionEncoders[modelPath] = encoderPath
    }

    func ensureModelLoaded(path: String, useFlashAttention: Bool) async throws {
        try await acquire()
        defer { release() }
        try await load(path: path, useFlashAttention: useFlashAttention)
    }

    private func load(path: String, useFlashAttention: Bool) async throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw WhisperModelServiceError.modelFileMissing
        }
        let encoder = sessionEncoders[path]
        accelerationMode = CoreMLCompatibilityPolicy.accelerationMode(hasVerifiedEncoder: encoder != nil)
        // whisper.cpp derives the encoder path from the model basename. Verify the
        // exact canonical path it will open; never claim a different artifact is used.
        if accelerationMode.usesCoreML {
            let expected = String(path.dropLast(4)).replacingOccurrences(of: "-q[0-9]_[0-9]$", with: "", options: .regularExpression) + "-encoder.mlmodelc"
            guard encoder == expected else { throw WhisperModelServiceError.modelLoadFailed }
        }
        if context.isLoaded(path: path, useFlashAttention: useFlashAttention, useCoreML: accelerationMode.usesCoreML) { return }
        await publishRuntimeSnapshot(isLoadingModel: true)
        do {
            try Task.checkCancellation()
            try await context.loadModel(path: path, useFlashAttention: useFlashAttention, useCoreML: accelerationMode.usesCoreML)
            try Task.checkCancellation()
            await publishRuntimeSnapshot(isLoadingModel: false)
        } catch {
            await publishRuntimeSnapshot(isLoadingModel: false)
            throw error
        }
    }

    func transcribe(
        modelPath: String,
        useFlashAttention: Bool,
        inputURL: URL,
        language: String,
        translate: Bool,
        prompt: String,
        useVAD: Bool,
        vadModelPath: String?,
        preprocessAudio: Bool,
        onChunkProgress: @escaping (WhisperAudioChunk, Double) -> Void
    ) async throws -> ChunkedTranscriptionResult {
        try await acquire()
        defer { release() }
        try await load(path: modelPath, useFlashAttention: useFlashAttention)
        return try await TranscriptionChunkProcessor().transcribe(
            inputURL: inputURL,
            whisperContext: context,
            language: language,
            translate: translate,
            prompt: prompt,
            useVAD: useVAD,
            vadModelPath: vadModelPath,
            preprocessAudio: preprocessAudio,
            onChunkProgress: onChunkProgress
        )
    }

    func releaseForRecording() async {
        if busy {
            releaseWhenFinished = true
            return
        }
        busy = true
        defer { release() }
        await context.unloadModelAndWait()
        await publishRuntimeSnapshot(isLoadingModel: false)
    }

    func invalidateAndUnload() async {
        do { try await acquire() } catch { return }
        defer { release() }
        await context.unloadModelAndWait()
        accelerationMode = .metal(reason: .encoderMissing)
        await publishRuntimeSnapshot(isLoadingModel: false)
    }

    func cancelLoad() async {
        await invalidateAndUnload()
    }

    private func publishRuntimeSnapshot(isLoadingModel: Bool) async {
        let mode = accelerationMode
        await MainActor.run {
            WhisperRuntimeStatus.shared.applySnapshot(
                isLoadingModel: isLoadingModel,
                accelerationMode: mode
            )
        }
    }
}
