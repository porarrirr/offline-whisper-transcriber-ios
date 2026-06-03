import Foundation
import Speech

enum WhisperModelSize: String, CaseIterable, Identifiable {
    case tiny = "tiny"
    case tinyQ5_1 = "tiny-q5_1"
    case base = "base"
    case baseQ5_1 = "base-q5_1"
    case small = "small"
    case smallQ5_1 = "small-q5_1"
    case medium = "medium"
    case mediumQ5_0 = "medium-q5_0"
    case largeV3TurboQ8_0 = "large-v3-turbo-q8_0"
    case largeV3TurboQ5_0 = "large-v3-turbo-q5_0"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tiny: return String(localized: "Whisper Tiny (Fast Basic)")
        case .tinyQ5_1: return String(localized: "Tiny Q5_1 (More Light)")
        case .base: return String(localized: "Base (Balanced)")
        case .baseQ5_1: return String(localized: "Base Q5_1 (Light & Balanced)")
        case .small: return String(localized: "Small (High Accuracy)")
        case .smallQ5_1: return String(localized: "Small Q5_1 (Light & High Accuracy)")
        case .medium: return String(localized: "Medium (Best Accuracy)")
        case .mediumQ5_0: return String(localized: "Medium Q5_0 (Light & Best Accuracy)")
        case .largeV3TurboQ8_0: return String(localized: "Large v3 Turbo Q8_0 (Fast & High Accuracy)")
        case .largeV3TurboQ5_0: return String(localized: "遅い・最高品質モデル")
        }
    }

    var fileName: String {
        "ggml-\(rawValue).bin"
    }

    var downloadURL: URL? {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")
    }

    var coreMLEncoderDirectoryName: String {
        "ggml-\(coreMLModelName)-encoder.mlmodelc"
    }

    var coreMLEncoderArchiveName: String {
        "\(coreMLEncoderDirectoryName).zip"
    }

    var coreMLEncoderDownloadURL: URL? {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(coreMLEncoderArchiveName)")
    }

    private var coreMLModelName: String {
        switch self {
        case .tiny, .tinyQ5_1:
            return "tiny"
        case .base, .baseQ5_1:
            return "base"
        case .small, .smallQ5_1:
            return "small"
        case .medium, .mediumQ5_0:
            return "medium"
        case .largeV3TurboQ8_0, .largeV3TurboQ5_0:
            return "large-v3-turbo"
        }
    }

    var coreMLMelBinCount: Int {
        switch self {
        case .largeV3TurboQ8_0, .largeV3TurboQ5_0:
            return 128
        default:
            return 80
        }
    }

    /// Headroom for URLSession temp files and filesystem metadata during download/install.
    static let downloadSafetyBufferBytes: Int64 = 64 * 1024 * 1024

    /// Published ggml model size on Hugging Face (bytes).
    var modelFileSizeBytes: Int64 {
        switch self {
        case .tiny: return 77_691_713
        case .tinyQ5_1: return 32_152_673
        case .base: return 147_951_465
        case .baseQ5_1: return 59_707_625
        case .small: return 487_601_967
        case .smallQ5_1: return 190_085_487
        case .medium: return 1_533_763_059
        case .mediumQ5_0: return 539_212_467
        case .largeV3TurboQ8_0: return 874_188_075
        case .largeV3TurboQ5_0: return 574_041_195
        }
    }

    func isValidModelFileSize(_ byteCount: Int64) -> Bool {
        byteCount == modelFileSizeBytes
    }

    /// Peak disk use while downloading and extracting the Core ML encoder zip (archive + extracted tree).
    var coreMLEncoderPeakBytes: Int64 {
        let zipBytes: Int64
        switch coreMLModelName {
        case "tiny":
            zipBytes = 15_037_446
        case "base":
            zipBytes = 37_922_638
        case "small":
            zipBytes = 163_083_239
        case "medium":
            zipBytes = 567_829_413
        case "large-v3-turbo":
            zipBytes = 1_173_393_014
        default:
            zipBytes = 0
        }
        return zipBytes * 2
    }

    func requiredDownloadBytes(modelExists: Bool, encoderExists: Bool) -> Int64 {
        var total = Self.downloadSafetyBufferBytes
        if !modelExists {
            total += modelFileSizeBytes
        }
        if !encoderExists {
            total += coreMLEncoderPeakBytes
        }
        return total
    }

    var approximateSize: String {
        switch self {
        case .tiny: return String(localized: "Approx. 39MB")
        case .tinyQ5_1: return String(localized: "Approx. 15MB")
        case .base: return String(localized: "Approx. 142MB")
        case .baseQ5_1: return String(localized: "Approx. 60MB")
        case .small: return String(localized: "Approx. 466MB")
        case .smallQ5_1: return String(localized: "Approx. 163MB")
        case .medium: return String(localized: "Approx. 1.5GB")
        case .mediumQ5_0: return String(localized: "Approx. 568MB")
        case .largeV3TurboQ8_0: return String(localized: "Approx. 874MB")
        case .largeV3TurboQ5_0: return String(localized: "Approx. 574MB")
        }
    }
}

struct AppleSpeechLocale: RawRepresentable, CaseIterable, Hashable, Identifiable {
    let rawValue: String

    static let jaJP = AppleSpeechLocale(localeIdentifier: "ja_JP")
    static let enUS = AppleSpeechLocale(localeIdentifier: "en_US")
    static let allCases: [AppleSpeechLocale] = [.jaJP, .enUS]

    init(rawValue: String) {
        self.rawValue = Locale(identifier: rawValue).identifier
    }

    init(localeIdentifier: String) {
        self.init(rawValue: localeIdentifier)
    }

    init(locale: Locale) {
        self.init(localeIdentifier: locale.identifier)
    }

    init?(storageIdentifier: String) {
        let trimmed = storageIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let locale = Locale(identifier: trimmed)
        guard let languageCode = locale.language.languageCode?.identifier,
              (2...3).contains(languageCode.count) else {
            return nil
        }

        self.init(localeIdentifier: trimmed)
    }

    var id: String { rawValue }

    var localeIdentifier: String { rawValue }

    var locale: Locale {
        Locale(identifier: localeIdentifier)
    }

    var displayName: String {
        switch (locale.language.languageCode?.identifier, locale.region?.identifier) {
        case ("ja", "JP"):
            return String(localized: "iOS SpeechTranscriber (Japanese)")
        case ("en", "US"):
            return String(localized: "iOS SpeechTranscriber (English)")
        default:
            let localeName = Locale.current.localizedString(forIdentifier: localeIdentifier) ?? localeIdentifier
            return "\(String(localized: "iOS SpeechTranscriber")) (\(localeName))"
        }
    }

    var approximateSize: String {
        String(localized: "System download")
    }

    /// Locales exposed in the model picker (filter with SpeechTranscriber when the SDK is available).
    static var pickerCases: [AppleSpeechLocale] {
        [.jaJP]
    }
}

enum TranscriptionModel: Hashable, Identifiable, Equatable {
    case whisper(WhisperModelSize)
    case appleSpeech(AppleSpeechLocale)

    var id: String { storageKey }

    var storageKey: String {
        switch self {
        case .whisper(let size):
            return "whisper:\(size.rawValue)"
        case .appleSpeech(let locale):
            return "apple-speech:\(locale.localeIdentifier)"
        }
    }

    var displayName: String {
        switch self {
        case .whisper(let size):
            return size.displayName
        case .appleSpeech(let locale):
            return locale.displayName
        }
    }

    var approximateSize: String {
        switch self {
        case .whisper(let size):
            return size.approximateSize
        case .appleSpeech(let locale):
            return locale.approximateSize
        }
    }

    var backend: TranscriptionBackend {
        switch self {
        case .whisper:
            return .whisper
        case .appleSpeech(let locale):
            return .appleSpeech(locale)
        }
    }

    var whisperModelSize: WhisperModelSize? {
        if case .whisper(let size) = self { return size }
        return nil
    }

    var appleSpeechLocale: AppleSpeechLocale? {
        if case .appleSpeech(let locale) = self { return locale }
        return nil
    }

    static var pickerOptions: [TranscriptionModel] {
        pickerOptions(selectedModel: nil)
    }

    static func pickerOptions(selectedModel: TranscriptionModel?) -> [TranscriptionModel] {
        if #available(iOS 26.0, *), SpeechTranscriber.isAvailable {
            return pickerOptions(supportsAppleSpeech: true, selectedModel: selectedModel)
        }
        return pickerOptions(supportsAppleSpeech: false, selectedModel: selectedModel)
    }

    static func pickerOptions(
        supportsAppleSpeech: Bool,
        selectedModel: TranscriptionModel? = nil
    ) -> [TranscriptionModel] {
        let smallWhisperOption = TranscriptionModel.whisper(.smallQ5_1)
        let qualityWhisperOption = TranscriptionModel.whisper(.largeV3TurboQ5_0)
        guard supportsAppleSpeech else {
            return [.whisper(.tiny), smallWhisperOption, qualityWhisperOption]
        }

        var appleSpeechOptions = AppleSpeechLocale.pickerCases.map { TranscriptionModel.appleSpeech($0) }
        if let selectedModel,
           case .appleSpeech = selectedModel,
           !appleSpeechOptions.contains(selectedModel) {
            appleSpeechOptions.append(selectedModel)
        }

        return appleSpeechOptions + [smallWhisperOption, qualityWhisperOption]
    }

    init?(storageKey: String) {
        if storageKey.hasPrefix("whisper:") {
            let raw = String(storageKey.dropFirst("whisper:".count))
            guard let size = WhisperModelSize(rawValue: raw) else { return nil }
            self = .whisper(size)
        } else if storageKey.hasPrefix("apple-speech:") {
            let raw = String(storageKey.dropFirst("apple-speech:".count))
            guard let locale = AppleSpeechLocale(storageIdentifier: raw) else { return nil }
            self = .appleSpeech(locale)
        } else if let legacy = WhisperModelSize(rawValue: storageKey) {
            self = .whisper(legacy)
        } else {
            return nil
        }
    }

    /// Legacy `ModelSize` raw value for migration.
    init?(legacyWhisperRawValue: String) {
        guard let size = WhisperModelSize(rawValue: legacyWhisperRawValue) else { return nil }
        self = .whisper(size)
    }
}

enum TranscriptionBackend: Hashable {
    case whisper
    case appleSpeech(AppleSpeechLocale)

    var isWhisper: Bool {
        if case .whisper = self { return true }
        return false
    }

    var isAppleSpeech: Bool {
        !isWhisper
    }
}
