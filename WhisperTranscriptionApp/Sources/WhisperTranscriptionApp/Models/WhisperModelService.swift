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
    private var warmupTask: Task<Void, Never>?
    private var probeTask: Task<Void, Never>?
    private var loadTask: Task<Void, Error>?
    private var loadGeneration: UInt64 = 0
    private var activeTranscriptionCount = 0

    private init() {}

    func startSession(modelPath: String, encoderPath: String?, useFlashAttention: Bool) {
        sessionModelPath = modelPath
        sessionEncoderPath = encoderPath
        sessionUseFlashAttention = useFlashAttention
        probeState = .pending
        Task { await publishRuntimeSnapshot(isLoadingModel: false) }

        warmupTask?.cancel()
        warmupTask = Task { [modelPath, useFlashAttention] in
            await self.scheduleWarmup(modelPath: modelPath, useFlashAttention: useFlashAttention)
        }

        probeTask?.cancel()
        probeTask = Task {
            await self.runProbe(encoderPath: encoderPath)
        }
    }

    func ensureModelLoaded(path: String, useFlashAttention: Bool) async throws {
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

    func releaseForRecording() {
        cancelInFlightLoad()
        context.unloadModel()
        AppLogger.info("Whisper model released: reason=recording started", context: "WhisperModelService")
    }

    func invalidateAndUnload() {
        cancelInFlightLoad()
        probeTask?.cancel()
        warmupTask?.cancel()
        context.unloadModel()
        probeState = .pending
        sessionModelPath = nil
        sessionEncoderPath = nil
        Task { await publishRuntimeSnapshot(isLoadingModel: false) }
    }

    func cancelLoad() {
        cancelInFlightLoad()
    }

    private func runProbe(encoderPath: String?) async {
        guard let encoderPath, FileManager.default.fileExists(atPath: encoderPath) else {
            await applyProbeResolved(useCoreML: false, summary: "encoder package missing")
            return
        }

        let result = await CoreMLProbeRunner.run(encoderPath: encoderPath)
        let useCoreML = result.ok && result.elapsedMS < CoreMLProbeRunner.slowProbeThresholdMS
        let summary = result.summary

        await MainActor.run {
            AppLogger.info("Core ML encoder probe: \(summary)", context: "CoreMLProbeRunner")
        }

        await applyProbeResolved(useCoreML: useCoreML, summary: summary)

        if useCoreML {
            await reloadIfIdle(useCoreML: true)
        }
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

    private func scheduleWarmup(modelPath: String, useFlashAttention: Bool) async {
        do {
            try await ensureModelLoaded(path: modelPath, useFlashAttention: useFlashAttention)
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

    private var probeStateLabel: String {
        switch probeState {
        case .pending:
            return "pending"
        case .resolved(let useCoreML, let summary):
            return "resolved(useCoreML=\(useCoreML), \(summary))"
        }
    }

    private func cancelInFlightLoad() {
        loadGeneration += 1
        loadTask?.cancel()
        loadTask = nil
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
