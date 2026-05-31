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

    enum ProbeState: Sendable {
        case pending
        case resolved(useCoreML: Bool, summary: String)
    }

    private let context = WhisperContext()
    private var probeState: ProbeState = .pending
    private var sessionModelPath: String?
    private var sessionEncoderPath: String?
    private var sessionUseFlashAttention = false
    private var sessionGeneration: UInt64 = 0
    private var warmupTask: Task<Void, Never>?
    private var probeTask: Task<Void, Never>?
    private var loadTask: Task<Void, Error>?
    private var releaseCleanupTask: Task<Void, Never>?
    private var loadGeneration: UInt64 = 0
    private var activeTranscriptionCount = 0

    private init() {}

    func startSession(modelPath: String, encoderPath: String?, useFlashAttention: Bool, coreMLMelBinCount: Int) {
        sessionGeneration += 1
        let generation = sessionGeneration
        sessionModelPath = modelPath
        sessionEncoderPath = encoderPath
        sessionUseFlashAttention = useFlashAttention
        probeState = .pending
        releaseCleanupTask?.cancel()
        releaseCleanupTask = nil
        Task { await publishRuntimeSnapshot(isLoadingModel: false) }

        warmupTask?.cancel()
        warmupTask = nil

        probeTask?.cancel()
        probeTask = Task {
            await self.runProbe(encoderPath: encoderPath, melBinCount: coreMLMelBinCount, generation: generation)
        }

        warmupTask = Task {
            await self.scheduleWarmup(
                modelPath: modelPath,
                useFlashAttention: useFlashAttention,
                generation: generation
            )
        }
    }

    func ensureModelLoaded(path: String, useFlashAttention: Bool) async throws {
        releaseCleanupTask?.cancel()
        releaseCleanupTask = nil

        guard FileManager.default.fileExists(atPath: path) else {
            throw WhisperModelServiceError.modelFileMissing
        }

        let useCoreML = useCoreMLForLoad()
        if context.isLoaded(path: path, useFlashAttention: useFlashAttention, useCoreML: useCoreML) {
            AppLogger.info("Whisper model already resident: useCoreML=\(useCoreML)", context: "WhisperModelService")
            await publishRuntimeSnapshot(isLoadingModel: false)
            return
        }

        if let loadTask {
            try await loadTask.value
            let stillUseCoreML = useCoreMLForLoad()
            guard context.isLoaded(path: path, useFlashAttention: useFlashAttention, useCoreML: stillUseCoreML) else {
                throw WhisperModelServiceError.modelLoadFailed
            }
            return
        }

        let generation = loadGeneration + 1
        loadGeneration = generation

        await publishRuntimeSnapshot(isLoadingModel: true)

        let task = Task<Void, Error> {
            try await self.context.loadModel(
                path: path,
                useFlashAttention: useFlashAttention,
                useCoreML: useCoreML
            )
        }
        loadTask = task

        do {
            try await task.value
            loadTask = nil
            guard generation == loadGeneration else {
                throw CancellationError()
            }
            guard context.isLoaded(path: path, useFlashAttention: useFlashAttention, useCoreML: useCoreML) else {
                throw WhisperModelServiceError.modelLoadFailed
            }
            AppLogger.info(
                "Whisper model load completed: useCoreML=\(useCoreML), probe=\(probeStateLabel)",
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

        let processor = TranscriptionChunkProcessor()
        return try await processor.transcribe(
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
        sessionGeneration += 1
        warmupTask?.cancel()
        probeTask?.cancel()
        let cancelledWarmupTask = warmupTask
        let cancelledProbeTask = probeTask
        let cancelledLoadTask = cancelInFlightLoad()
        warmupTask = nil
        probeTask = nil
        releaseCleanupTask?.cancel()

        if cancelledLoadTask == nil && activeTranscriptionCount == 0 {
            context.unloadModel()
        }

        await publishRuntimeSnapshot(isLoadingModel: false)
        AppLogger.info("Whisper model release requested: reason=recording started", context: "WhisperModelService")

        releaseCleanupTask = Task {
            await cancelledWarmupTask?.value
            await cancelledProbeTask?.value
            if let cancelledLoadTask {
                _ = try? await cancelledLoadTask.value
            }
            guard !Task.isCancelled else { return }
            await self.finishReleaseCleanup()
        }
    }

    func invalidateAndUnload() async {
        releaseCleanupTask?.cancel()
        releaseCleanupTask = nil
        let cancelledLoadTask = cancelInFlightLoad()
        probeTask?.cancel()
        warmupTask?.cancel()
        if let cancelledLoadTask {
            _ = try? await cancelledLoadTask.value
        }
        await waitForActiveTranscriptionsToFinish()
        context.unloadModel()
        probeState = .pending
        sessionModelPath = nil
        sessionEncoderPath = nil
        sessionGeneration += 1
        Task { await publishRuntimeSnapshot(isLoadingModel: false) }
    }

    func cancelLoad() async {
        releaseCleanupTask?.cancel()
        releaseCleanupTask = nil
        if let cancelledLoadTask = cancelInFlightLoad() {
            _ = try? await cancelledLoadTask.value
        }
        if activeTranscriptionCount == 0 {
            context.unloadModel()
            await publishRuntimeSnapshot(isLoadingModel: false)
        }
    }

    private func runProbe(encoderPath: String?, melBinCount: Int, generation: UInt64) async {
        #if targetEnvironment(simulator)
        guard generation == sessionGeneration else { return }
        await applyProbeResolved(useCoreML: false, summary: "Core ML encoder disabled on Simulator")
        #else
        guard let encoderPath, FileManager.default.fileExists(atPath: encoderPath) else {
            guard generation == sessionGeneration else { return }
            await applyProbeResolved(useCoreML: false, summary: "encoder package missing")
            return
        }

        let result = await CoreMLProbeRunner.run(encoderPath: encoderPath, melBinCount: melBinCount)
        guard !Task.isCancelled, generation == sessionGeneration else { return }
        let useCoreML = result.ok && result.elapsedMS < CoreMLProbeRunner.slowProbeThresholdMS
        let summary = result.summary

        await MainActor.run {
            AppLogger.info("Core ML encoder probe: \(summary)", context: "CoreMLProbeRunner")
        }

        await applyProbeResolved(useCoreML: useCoreML, summary: summary)

        if useCoreML {
            await reloadIfIdle(useCoreML: true)
        }
        #endif
    }

    private func applyProbeResolved(useCoreML: Bool, summary: String) async {
        probeState = .resolved(useCoreML: useCoreML, summary: summary)
        await MainActor.run {
            AppLogger.info(
                "Core ML session policy: useCoreML=\(useCoreML) (\(summary))",
                context: "WhisperModelService"
            )
        }
        await publishRuntimeSnapshot(isLoadingModel: false)
    }

    private func scheduleWarmup(modelPath: String, useFlashAttention: Bool, generation: UInt64) async {
        guard generation == sessionGeneration else { return }
        do {
            try await ensureModelLoaded(path: modelPath, useFlashAttention: useFlashAttention)
            guard generation == sessionGeneration else {
                unloadModelIfItDoesNotMatchCurrentSession()
                return
            }
        } catch is CancellationError {
            return
        } catch {
            await MainActor.run {
                AppLogger.error("Whisper warmup failed", context: "WhisperModelService", error: error)
            }
        }
    }

    private func reloadIfIdle(useCoreML: Bool) async {
        guard activeTranscriptionCount == 0 else { return }
        guard let path = sessionModelPath else { return }
        guard context.isModelLoaded else { return }
        guard !context.isLoaded(
            path: path,
            useFlashAttention: sessionUseFlashAttention,
            useCoreML: useCoreML
        ) else { return }

        AppLogger.info(
            "Reloading Whisper model for Core ML policy change: useCoreML=\(useCoreML)",
            context: "WhisperModelService"
        )
        context.unloadModel()
        do {
            try await ensureModelLoaded(path: path, useFlashAttention: sessionUseFlashAttention)
        } catch {
            await MainActor.run {
                AppLogger.error("Whisper reload after probe failed", context: "WhisperModelService", error: error)
            }
        }
    }

    private func useCoreMLForLoad() -> Bool {
        switch probeState {
        case .pending:
            return false
        case .resolved(let useCoreML, _):
            return useCoreML
        }
    }

    private func unloadModelIfItDoesNotMatchCurrentSession() {
        guard let path = sessionModelPath else {
            context.unloadModel()
            return
        }

        if context.loadedModelPath != path
            || context.loadedUseFlashAttention != sessionUseFlashAttention
            || context.loadedUseCoreML != useCoreMLForLoad() {
            context.unloadModel()
        }
    }

    private var probeStateLabel: String {
        switch probeState {
        case .pending:
            return "pending"
        case .resolved(let useCoreML, let summary):
            return "resolved(useCoreML=\(useCoreML), \(summary))"
        }
    }

    private func cancelInFlightLoad() -> Task<Void, Error>? {
        loadGeneration += 1
        let task = loadTask
        task?.cancel()
        loadTask = nil
        return task
    }

    private func waitForActiveTranscriptionsToFinish() async {
        while activeTranscriptionCount > 0 {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func finishReleaseCleanup() async {
        releaseCleanupTask = nil
        guard activeTranscriptionCount == 0, loadTask == nil else { return }
        context.unloadModel()
        await publishRuntimeSnapshot(isLoadingModel: false)
        AppLogger.info("Whisper model released: reason=recording started", context: "WhisperModelService")
    }

    private func publishRuntimeSnapshot(isLoadingModel: Bool) async {
        let useCoreML: Bool
        let probeDescription: String
        switch probeState {
        case .pending:
            useCoreML = false
            probeDescription = "pending"
        case .resolved(let resolvedUseCoreML, let summary):
            useCoreML = resolvedUseCoreML
            probeDescription = summary
        }

        await MainActor.run {
            WhisperRuntimeStatus.shared.applySnapshot(
                isLoadingModel: isLoadingModel,
                probeStateDescription: probeDescription,
                useCoreMLForSession: useCoreML
            )
        }
    }
}
