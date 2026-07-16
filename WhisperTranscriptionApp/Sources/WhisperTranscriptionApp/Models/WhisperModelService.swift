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

    private let context = WhisperContext()
    private var accelerationMode: WhisperAccelerationMode = .metal(reason: .encoderMissing)
    private var loadTask: Task<Void, Error>?
    private var loadGeneration: UInt64 = 0
    private var activeTranscriptionCount = 0

    private init() {}

    /// Resolves acceleration exactly once for the session. Core ML is never probed or
    /// loaded before the OS policy and the versioned encoder have both been validated.
    func startSession(
        modelPath: String,
        encoderPath: String?,
        useFlashAttention: Bool,
        coreMLMelBinCount: Int
    ) {
        _ = modelPath
        _ = useFlashAttention
        _ = coreMLMelBinCount
        accelerationMode = CoreMLCompatibilityPolicy.accelerationMode(
            hasVerifiedEncoder: encoderPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
        )
        AppLogger.info(
            "Whisper acceleration policy: \(accelerationMode.description)",
            context: "WhisperModelService"
        )
        Task { await publishRuntimeSnapshot(isLoadingModel: false) }
    }

    func ensureModelLoaded(path: String, useFlashAttention: Bool) async throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw WhisperModelServiceError.modelFileMissing
        }

        if context.isLoaded(
            path: path,
            useFlashAttention: useFlashAttention,
            useCoreML: accelerationMode.usesCoreML
        ) {
            await publishRuntimeSnapshot(isLoadingModel: false)
            return
        }

        if let loadTask {
            try await loadTask.value
            guard context.isLoaded(
                path: path,
                useFlashAttention: useFlashAttention,
                useCoreML: accelerationMode.usesCoreML
            ) else {
                throw WhisperModelServiceError.modelLoadFailed
            }
            return
        }

        let generation = loadGeneration + 1
        loadGeneration = generation
        await publishRuntimeSnapshot(isLoadingModel: true)

        let requestedMode = accelerationMode
        let task = Task<Void, Error> {
            do {
                try await self.context.loadModel(
                    path: path,
                    useFlashAttention: useFlashAttention,
                    useCoreML: requestedMode.usesCoreML
                )
            } catch {
                guard requestedMode.usesCoreML else { throw error }

                // This is the single explicitly authorised fallback. It only handles
                // errors returned by whisper/Core ML; OS-level exit()/abort failures are
                // prevented by CoreMLCompatibilityPolicy before this point.
                self.accelerationMode = .metal(reason: .coreMLLoadFailed)
                await MainActor.run {
                    AppLogger.error(
                        "Core ML load failed; retrying this session once with Metal",
                        context: "WhisperModelService",
                        error: error
                    )
                }
                try await self.context.loadModel(
                    path: path,
                    useFlashAttention: useFlashAttention,
                    useCoreML: false
                )
            }
        }
        loadTask = task

        do {
            try await task.value
            loadTask = nil
            guard generation == loadGeneration else { throw CancellationError() }
            guard context.isLoaded(
                path: path,
                useFlashAttention: useFlashAttention,
                useCoreML: accelerationMode.usesCoreML
            ) else {
                throw WhisperModelServiceError.modelLoadFailed
            }
            AppLogger.info(
                "Whisper model load completed: \(accelerationMode.description)",
                context: "WhisperModelService"
            )
            await publishRuntimeSnapshot(isLoadingModel: false)
        } catch {
            loadTask = nil
            await publishRuntimeSnapshot(isLoadingModel: false)
            throw error
        }
    }

    func transcribe(
        inputURL: URL,
        language: String,
        translate: Bool,
        prompt: String,
        useVAD: Bool,
        vadModelPath: String?,
        onChunkProgress: @escaping (WhisperAudioChunk, Double) -> Void
    ) async throws -> ChunkedTranscriptionResult {
        activeTranscriptionCount += 1
        defer { activeTranscriptionCount -= 1 }

        return try await TranscriptionChunkProcessor().transcribe(
            inputURL: inputURL,
            whisperContext: context,
            language: language,
            translate: translate,
            prompt: prompt,
            useVAD: useVAD,
            vadModelPath: vadModelPath,
            onChunkProgress: onChunkProgress
        )
    }

    func releaseForRecording() async {
        AppLogger.info("Whisper model release requested: reason=recording started", context: "WhisperModelService")
        await cancelAndWaitForInFlightLoads()

        guard activeTranscriptionCount == 0 else {
            await publishRuntimeSnapshot(isLoadingModel: false)
            AppLogger.info(
                "Whisper model release deferred: activeTranscriptions=\(activeTranscriptionCount)",
                context: "WhisperModelService"
            )
            return
        }

        await context.unloadModelAndWait()
        await publishRuntimeSnapshot(isLoadingModel: false)
    }

    func invalidateAndUnload() async {
        await cancelAndWaitForInFlightLoads()
        await waitForActiveTranscriptionsToFinish()
        await context.unloadModelAndWait()
        accelerationMode = .metal(reason: .encoderMissing)
        await publishRuntimeSnapshot(isLoadingModel: false)
    }

    func cancelLoad() async {
        await cancelAndWaitForInFlightLoads()
        if activeTranscriptionCount == 0 {
            await context.unloadModelAndWait()
            await publishRuntimeSnapshot(isLoadingModel: false)
        }
    }

    private func cancelInFlightLoad() -> Task<Void, Error>? {
        loadGeneration += 1
        let task = loadTask
        task?.cancel()
        loadTask = nil
        return task
    }

    private func cancelAndWaitForInFlightLoads() async {
        while let task = cancelInFlightLoad() {
            do {
                try await task.value
            } catch is CancellationError {
                continue
            } catch {
                await MainActor.run {
                    AppLogger.error("Cancelled model load finished with error", context: "WhisperModelService", error: error)
                }
            }
        }
    }

    private func waitForActiveTranscriptionsToFinish() async {
        while activeTranscriptionCount > 0 {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
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
