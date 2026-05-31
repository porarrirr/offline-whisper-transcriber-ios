import Foundation

struct TranscriptionChunkingConfig {
    let chunkDuration: TimeInterval
    let overlapDuration: TimeInterval
    let promptContextLimit: Int

    static let standard = TranscriptionChunkingConfig(
        chunkDuration: 5 * 60,
        overlapDuration: 10,
        promptContextLimit: 800
    )
}

struct ChunkedTranscriptionResult {
    let text: String
    let segments: [TranscriptionSegment]
    let language: String?
    let processedDuration: TimeInterval
}

struct TranscriptionChunkProcessor {
    let config: TranscriptionChunkingConfig

    init(config: TranscriptionChunkingConfig = .standard) {
        self.config = config
    }

    func transcribe(
        inputURL: URL,
        whisperContext: WhisperContext,
        language: String,
        translate: Bool,
        prompt basePrompt: String,
        useVAD: Bool,
        vadModelPath: String?,
        onChunkProgress: @escaping (WhisperAudioChunk, Double) -> Void = { _, _ in }
    ) async throws -> ChunkedTranscriptionResult {
        let cancellationToken = WhisperCancellationToken()

        return try await withTaskCancellationHandler {
            try await transcribe(
                inputURL: inputURL,
                whisperContext: whisperContext,
                language: language,
                translate: translate,
                prompt: basePrompt,
                useVAD: useVAD,
                vadModelPath: vadModelPath,
                cancellationToken: cancellationToken,
                onChunkProgress: onChunkProgress
            )
        } onCancel: {
            cancellationToken.cancel()
        }
    }

    private func transcribe(
        inputURL: URL,
        whisperContext: WhisperContext,
        language: String,
        translate: Bool,
        prompt basePrompt: String,
        useVAD: Bool,
        vadModelPath: String?,
        cancellationToken: WhisperCancellationToken,
        onChunkProgress: @escaping (WhisperAudioChunk, Double) -> Void
    ) async throws -> ChunkedTranscriptionResult {
        var combinedSegments: [TranscriptionSegment] = []
        var detectedLanguage: String?
        var processedAudioDuration: TimeInterval = 0
        var recentPromptContext = ""

        try Task.checkCancellation()
        try await AudioConverter.shared.convertToWhisperChunks(
            inputURL: inputURL,
            chunkDuration: config.chunkDuration,
            chunkOverlapDuration: config.overlapDuration
        ) { chunk in
            try Task.checkCancellation()
            let chunkPrompt = makeChunkPrompt(basePrompt: basePrompt, recentContext: recentPromptContext)
            let chunkStartedAt = Date()
            let result = await whisperContext.transcribeChunk(
                samples: chunk.samples,
                startOffset: chunk.startTime,
                segmentIDOffset: 0,
                language: language,
                translate: translate,
                prompt: chunkPrompt,
                useVAD: useVAD,
                vadModelPath: vadModelPath,
                cancellationToken: cancellationToken,
                onProgress: { progress in
                    onChunkProgress(chunk, progress)
                }
            )
            try Task.checkCancellation()

            guard let result else {
                throw TranscriptionProcessingError.whisperFailed(whisperContext.errorMessage)
            }

            logChunkCompletion(chunk: chunk, startedAt: chunkStartedAt)

            let acceptedStart = chunk.index == 0 ? chunk.startTime : chunk.startTime + min(config.overlapDuration, chunk.duration)
            let acceptedSegments = result.segments
                .filter { $0.end > acceptedStart }
                .enumerated()
                .map { index, segment in
                    TranscriptionSegment(
                        id: combinedSegments.count + index,
                        start: segment.start,
                        end: segment.end,
                        text: segment.text
                    )
                }

            let acceptedText = TranscriptionSegment.plainText(from: acceptedSegments)

            if !acceptedText.isEmpty {
                appendPromptContext(acceptedText, to: &recentPromptContext)
            }

            combinedSegments.append(contentsOf: acceptedSegments)
            detectedLanguage = detectedLanguage ?? result.language
            processedAudioDuration = max(processedAudioDuration, chunk.startTime + chunk.duration)
        }

        let finalText = TranscriptionSegment.plainText(from: combinedSegments)
        guard !finalText.isEmpty else {
            throw TranscriptionProcessingError.emptyTranscription
        }

        return ChunkedTranscriptionResult(
            text: finalText,
            segments: combinedSegments,
            language: detectedLanguage,
            processedDuration: processedAudioDuration
        )
    }

    private func logChunkCompletion(chunk: WhisperAudioChunk, startedAt: Date) {
        let elapsed = max(0, Date().timeIntervalSince(startedAt))
        let realtimeFactor = chunk.duration > 0 ? elapsed / chunk.duration : 0
        AppLogger.info(
            "Transcription chunk completed: index=\(chunk.index), start=\(formatSeconds(chunk.startTime)), duration=\(formatSeconds(chunk.duration)), elapsed=\(formatSeconds(elapsed)), rtf=\(formatNumber(realtimeFactor))",
            context: "TranscriptionChunkProcessor"
        )
    }

    private func formatSeconds(_ seconds: TimeInterval) -> String {
        String(format: "%.2fs", seconds)
    }

    private func formatNumber(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private func makeChunkPrompt(basePrompt: String, recentContext: String) -> String {
        let trimmedBasePrompt = basePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRecentContext = recentContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRecentContext.isEmpty else {
            return trimmedBasePrompt
        }
        guard !trimmedBasePrompt.isEmpty else {
            return trimmedRecentContext
        }
        return "\(trimmedBasePrompt)\n\(trimmedRecentContext)"
    }

    private func appendPromptContext(_ text: String, to recentPromptContext: inout String) {
        if recentPromptContext.isEmpty {
            recentPromptContext = text
        } else {
            recentPromptContext += "\n\(text)"
        }

        if recentPromptContext.count > config.promptContextLimit {
            recentPromptContext = String(recentPromptContext.suffix(config.promptContextLimit))
        }
    }
}

enum TranscriptionProcessingError: LocalizedError {
    case whisperFailed(String?)
    case emptyTranscription

    var errorDescription: String? {
        switch self {
        case .whisperFailed(let message):
            return message ?? String(localized: "Transcription failed")
        case .emptyTranscription:
            return String(localized: "Transcription finished, but no text was produced.")
        }
    }
}
