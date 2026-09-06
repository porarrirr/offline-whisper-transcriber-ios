import Foundation
import AppIntents
import Speech
import SwiftData
import UniformTypeIdentifiers

enum WhisperAppDestination: String {
    case transcribe
    case history

    static let pendingDestinationKey = "WhisperAppIntentPendingDestination"
    static let pendingRecordingActionKey = "WhisperAppIntentPendingRecordingAction"
    static let pendingTranscriptionIDKey = "WhisperAppIntentPendingTranscriptionID"

    var tabIndex: Int {
        switch self {
        case .transcribe:
            return 0
        case .history:
            return 1
        }
    }

    @MainActor
    func requestOpen(
        recordingAction: WhisperRecordingIntentAction? = nil,
        transcriptionID: UUID? = nil,
        userDefaults: UserDefaults = .standard
    ) {
        if let recordingAction {
            userDefaults.set(recordingAction.rawValue, forKey: Self.pendingRecordingActionKey)
        } else if self == .transcribe {
            userDefaults.removeObject(forKey: Self.pendingRecordingActionKey)
        }
        if let transcriptionID {
            userDefaults.set(transcriptionID.uuidString, forKey: Self.pendingTranscriptionIDKey)
        } else if self == .history {
            userDefaults.removeObject(forKey: Self.pendingTranscriptionIDKey)
        }
        userDefaults.set(rawValue, forKey: Self.pendingDestinationKey)
    }
}

enum WhisperRecordingIntentAction: String {
    case start
    case startLiveTranscription
    case stopAndTranscribe
}

@available(iOS 18.0, *)
struct OpenTranscriptionIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Whisper Transcriber"
    static var description = IntentDescription("Opens the app for recording or file transcription")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        WhisperAppDestination.transcribe.requestOpen()
        return .result()
    }
}

@available(iOS 18.0, *)
struct OpenTranscriptionHistoryIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Transcription History"
    static var description = IntentDescription("Opens saved transcription history")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        WhisperAppDestination.history.requestOpen()
        return .result()
    }
}

@available(iOS 18.0, *)
struct OpenTranscriptionRecordIntent: OpenIntent {
    static var title: LocalizedStringResource = "Open Transcription"

    @Parameter(title: "Transcription")
    var target: TranscriptionEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        WhisperAppDestination.history.requestOpen(transcriptionID: target.id)
        return .result()
    }
}

@available(iOS 18.0, *)
struct FavoriteTranscriptionIntent: AppIntent {
    static var title: LocalizedStringResource = "Favorite Transcription"
    static var description = IntentDescription("Adds a saved transcription to favorites")

    @Parameter(title: "Transcription")
    var transcription: TranscriptionEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Favorite \(\.$transcription)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<TranscriptionEntity> {
        let updated = try TranscriptionEntityRecordStore.markAsFavorite(transcription)
        return .result(value: updated)
    }
}

@available(iOS 18.0, *)
struct TagTranscriptionIntent: AppIntent {
    static var title: LocalizedStringResource = "Tag Transcription"
    static var description = IntentDescription("Adds one or more tags to a saved transcription")

    @Parameter(title: "Transcription")
    var transcription: TranscriptionEntity

    @Parameter(title: "Tag")
    var tag: String

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$tag) to \(\.$transcription)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<TranscriptionEntity> {
        let updated = try TranscriptionEntityRecordStore.addTag(tag, to: transcription)
        return .result(value: updated)
    }
}

@available(iOS 18.0, *)
struct StartBackgroundRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Recording"
    static var description = IntentDescription("Opens the app and starts an audio recording")
    static var openAppWhenRun = true

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @MainActor
    func perform() async throws -> some IntentResult {
        WhisperAppDestination.transcribe.requestOpen(recordingAction: .start)
        return .result()
    }
}

@available(iOS 18.0, *)
struct OpenLiveRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Live Recording"
    static var description = IntentDescription("Opens the app and starts recording with live transcription selected")
    static var openAppWhenRun = true

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @MainActor
    func perform() async throws -> some IntentResult {
        WhisperAppDestination.transcribe.requestOpen(recordingAction: .startLiveTranscription)
        return .result()
    }
}

@available(iOS 18.0, *)
struct StopRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Recording"
    static var description = IntentDescription("Stops the active recording, saves it, and starts transcription")
    static var openAppWhenRun = true

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard RecordingService.shared.isRecording else {
            throw IntentError.noActiveRecording
        }

        WhisperAppDestination.transcribe.requestOpen(recordingAction: .stopAndTranscribe)
        return .result()
    }
}

@available(iOS 18.0, *)
struct TranscribeAudioIntent: AppIntent {
    static var title: LocalizedStringResource = "Transcribe Media"
    static var description = IntentDescription("Transcribes an audio or video file")
    
    @Parameter(title: "Audio or Video File", description: "Audio or video file to transcribe")
    var audioFile: IntentFile?
    
    @Parameter(title: "Language", description: "Language for transcription")
    var language: String?
    
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let modelManager = ModelManager.shared
        let settings = AppSettings.shared

        guard let audioFile else {
            throw IntentError.noAudioFile
        }

        modelManager.beginTranscriptionOperation()
        defer { modelManager.endTranscriptionOperation() }
        let transcriptionText = try await audioFile.withFile(contentType: .audiovisualContent, allowOpenInPlace: true) { audioURL, _ in
            switch settings.selectedTranscriptionModel.backend {
            case .whisper:
                return try await transcribeWithWhisperIntent(
                    audioURL: audioURL,
                    modelManager: modelManager,
                    settings: settings,
                    languageOverride: language
                )
            case .appleSpeech(let locale):
                return try await transcribeWithAppleSpeechIntent(
                    inputURL: audioURL,
                    locale: locale,
                    languageOverride: language
                )
            }
        }

        return .result(value: transcriptionText)
    }
}

@available(iOS 16.0, *)
struct GetTranscriptionHistoryIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Transcription History"
    static var description = IntentDescription("Retrieves recent transcription history")
    
    @Parameter(title: "Count", description: "Number of history records to retrieve", default: 5)
    var limit: Int
    
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try HistoryIntentLimit.validate(limit)

        let modelContainer = try ModelContainer(for: TranscriptionRecord.self)
        let modelContext = ModelContext(modelContainer)
        
        let descriptor = FetchDescriptor<TranscriptionRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        
        let records = try modelContext.fetch(descriptor)
        let limitedRecords = Array(records.prefix(limit))
        
        let result = limitedRecords.map { record in
            "[\(record.formattedDate)] \(record.text.prefix(100))\(record.text.count > 100 ? "..." : "")"
        }.joined(separator: "\n\n")
        
        return .result(value: result)
    }
}

enum HistoryIntentLimit {
    static let validRange = 1...100

    static func validate(_ value: Int) throws {
        guard validRange.contains(value) else {
            throw IntentError.invalidHistoryLimit
        }
    }
}

@available(iOS 18.0, *)
struct WhisperShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartBackgroundRecordingIntent(),
            phrases: [
                "Start recording with \(.applicationName)",
                "Record audio with \(.applicationName)",
                "Begin recording with \(.applicationName)"
            ],
            shortTitle: "Start Recording",
            systemImageName: "record.circle"
        )
        AppShortcut(
            intent: OpenLiveRecordingIntent(),
            phrases: [
                "Open live recorder with \(.applicationName)",
                "Start live recording with \(.applicationName)",
                "Open live transcription with \(.applicationName)"
            ],
            shortTitle: "Live Recorder",
            systemImageName: "quote.bubble"
        )
        AppShortcut(
            intent: StopRecordingIntent(),
            phrases: [
                "Stop recording with \(.applicationName)",
                "End recording with \(.applicationName)"
            ],
            shortTitle: "Stop Recording",
            systemImageName: "stop.circle"
        )
        AppShortcut(
            intent: FavoriteTranscriptionIntent(),
            phrases: [
                "Favorite \(\.$transcription) in \(.applicationName)"
            ],
            shortTitle: "Favorite Transcription",
            systemImageName: "star"
        )
        AppShortcut(
            intent: TagTranscriptionIntent(),
            phrases: [
                "Tag \(\.$transcription) in \(.applicationName)"
            ],
            shortTitle: "Tag Transcription",
            systemImageName: "tag"
        )
        AppShortcut(
            intent: OpenTranscriptionIntent(),
            phrases: [
                "Open \(.applicationName)",
                "Start transcription with \(.applicationName)",
                "Open recorder with \(.applicationName)",
                "Open audio transcription with \(.applicationName)"
            ],
            shortTitle: "Open Transcriber",
            systemImageName: "mic.circle"
        )
        AppShortcut(
            intent: TranscribeAudioIntent(),
            phrases: [
                "Transcribe with \(.applicationName)",
                "Transcribe audio with \(.applicationName)",
                "Transcribe media with \(.applicationName)",
                "Transcribe file with \(.applicationName)"
            ],
            shortTitle: "Transcribe File",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: OpenTranscriptionHistoryIntent(),
            phrases: [
                "Open history in \(.applicationName)",
                "Show transcription history in \(.applicationName)",
                "Find transcripts in \(.applicationName)"
            ],
            shortTitle: "History",
            systemImageName: "clock.arrow.circlepath"
        )
    }
}

@MainActor
private func transcribeWithWhisperIntent(
    audioURL: URL,
    modelManager: ModelManager,
    settings: AppSettings,
    languageOverride: String?
) async throws -> String {
    guard modelManager.currentWhisperModelIsReady() else {
        throw IntentError.modelNotReady
    }

    do {
        try await WhisperModelService.shared.ensureModelLoaded(
            path: modelManager.modelPath,
            useFlashAttention: settings.useFlashAttention
        )
    } catch {
        throw IntentError.modelLoadFailed
    }

    let selectedLanguage = languageOverride ?? settings.selectedLanguage
    if settings.useVAD && !modelManager.isVADModelReady {
        throw IntentError.vadModelNotReady
    }

    do {
        let result = try await WhisperModelService.shared.transcribe(
            modelPath: modelManager.modelPath,
            useFlashAttention: settings.useFlashAttention,
            inputURL: audioURL,
            language: selectedLanguage == "auto" ? "" : selectedLanguage,
            translate: settings.translateToEnglish,
            prompt: settings.promptText,
            useVAD: settings.useVAD,
            vadModelPath: settings.useVAD ? modelManager.vadModelPath : nil,
            preprocessAudio: settings.useAudioPreprocessing,
            onChunkProgress: { _, _ in }
        )
        return result.text
    } catch is AudioConverter.AudioConverterError {
        throw IntentError.conversionFailed
    } catch is CancellationError {
        throw IntentError.transcriptionFailed
    } catch {
        throw IntentError.transcriptionFailed
    }
}

@MainActor
@available(iOS 18.0, *)
private func transcribeWithAppleSpeechIntent(inputURL: URL, locale: AppleSpeechLocale, languageOverride: String? = nil) async throws -> String {
    guard #available(iOS 26.0, *) else {
        throw IntentError.speechUnavailable
    }
    guard SpeechTranscriber.isAvailable else {
        throw IntentError.speechUnavailable
    }

    let effectiveLocale = try await IntentSpeechLanguage.resolve(
        override: languageOverride, selected: locale,
        normalize: { await SpeechTranscriber.supportedLocale(equivalentTo: $0) }
    )

    do {
        let result = try await AppleSpeechTranscriptionService().transcribe(
            inputURL: inputURL,
            locale: effectiveLocale,
            includeTimestamps: false
        ) { _ in }
        return result.text
    } catch AppleSpeechTranscriptionError.localeNotSupported {
        throw IntentError.speechLocaleNotSupported
    } catch AppleSpeechTranscriptionError.transcriptionUnavailable {
        throw IntentError.speechUnavailable
    } catch AppleSpeechTranscriptionError.assetsNotReady {
        throw IntentError.modelNotReady
    } catch is AudioConverter.AudioConverterError {
        throw IntentError.conversionFailed
    } catch {
        throw IntentError.transcriptionFailed
    }
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case modelNotReady
    case modelLoadFailed
    case noAudioFile
    case conversionFailed
    case transcriptionFailed
    case coreMLEncoderNotReady
    case vadModelNotReady
    case speechUnavailable
    case speechLocaleNotSupported
    case microphonePermissionRequired
    case recordingBusy
    case recordingStartFailed(String)
    case liveActivityRequired
    case foregroundRequiredToStartRecording
    case invalidHistoryLimit
    case noActiveRecording
    case transcriptionNotFound
    case emptyTag
    
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .modelNotReady:
            return "Model is not ready. Please open the app and download the model."
        case .modelLoadFailed:
            return "Failed to load model."
        case .noAudioFile:
            return "No audio or video file specified."
        case .conversionFailed:
            return "Failed to convert audio or video file."
        case .transcriptionFailed:
            return "Transcription failed."
        case .coreMLEncoderNotReady:
            return "Core ML encoder is required. Please open the app and download the additional encoder model."
        case .vadModelNotReady:
            return "VAD model is not ready. Please open the app and download the VAD model from settings."
        case .speechUnavailable:
            return "Speech transcription is not available on this device."
        case .speechLocaleNotSupported:
            return "This language is not supported by on-device speech recognition."
        case .microphonePermissionRequired:
            return "Microphone permission is required. Please allow microphone access in Settings."
        case .recordingBusy:
            return "Recording is already starting or stopping."
        case .recordingStartFailed(let detail):
            return "Failed to start recording: \(detail)"
        case .liveActivityRequired:
            return "Live Activities must be enabled to start recording from a shortcut."
        case .foregroundRequiredToStartRecording:
            return "iOS does not allow starting recording while the app is in the background. Open the app to start recording."
        case .invalidHistoryLimit:
            return "History count must be between 1 and 100."
        case .noActiveRecording:
            return "No recording is currently active."
        case .transcriptionNotFound:
            return "The requested transcription could not be found."
        case .emptyTag:
            return "Enter at least one tag."
        }
    }
}

enum IntentSpeechLanguage {
    static func resolve(
        override: String?, selected: AppleSpeechLocale,
        normalize: (Locale) async -> Locale?
    ) async throws -> AppleSpeechLocale {
        guard let override else { return selected }
        let identifier = override.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty, identifier.lowercased() != "auto",
              let normalized = await normalize(Locale(identifier: identifier)) else {
            throw IntentError.speechLocaleNotSupported
        }
        return AppleSpeechLocale(locale: normalized)
    }
}
