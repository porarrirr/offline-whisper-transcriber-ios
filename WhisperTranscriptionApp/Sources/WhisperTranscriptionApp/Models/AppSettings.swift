import Foundation

@MainActor
class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var selectedTranscriptionModel: TranscriptionModel {
        didSet {
            UserDefaults.standard.set(selectedTranscriptionModel.storageKey, forKey: Self.selectedTranscriptionModelKey)
        }
    }

    @Published var selectedLanguage: String {
        didSet { UserDefaults.standard.set(selectedLanguage, forKey: "selectedLanguage") }
    }

    @Published var translateToEnglish: Bool {
        didSet { UserDefaults.standard.set(translateToEnglish, forKey: "translateToEnglish") }
    }

    @Published var promptText: String {
        didSet { UserDefaults.standard.set(promptText, forKey: "promptText") }
    }

    @Published var useFlashAttention: Bool {
        didSet { UserDefaults.standard.set(useFlashAttention, forKey: "useFlashAttention") }
    }

    @Published var useVAD: Bool {
        didSet { UserDefaults.standard.set(useVAD, forKey: "useVAD") }
    }

    @Published var keepScreenOn: Bool {
        didSet { UserDefaults.standard.set(keepScreenOn, forKey: "keepScreenOn") }
    }

    @Published var autoDeleteRecordings: Bool {
        didSet { UserDefaults.standard.set(autoDeleteRecordings, forKey: "autoDeleteRecordings") }
    }

    @Published var includeTimestamps: Bool {
        didSet { UserDefaults.standard.set(includeTimestamps, forKey: "includeTimestamps") }
    }

    var selectedModelBackend: TranscriptionBackend {
        selectedTranscriptionModel.backend
    }

    var usesWhisperBackend: Bool {
        selectedTranscriptionModel.backend.isWhisper
    }

    var usesAppleSpeechBackend: Bool {
        selectedTranscriptionModel.backend.isAppleSpeech
    }

    private static let selectedTranscriptionModelKey = "selectedTranscriptionModel"
    private static let legacySelectedModelSizeKey = "selectedModelSize"
    private static let defaultsMigrationVersionKey = "appSettingsDefaultsMigrationVersion"
    private static let currentDefaultsMigrationVersion = 5

    private init() {
        Self.migrateDefaultsIfNeeded()

        let defaults = UserDefaults.standard
        if let key = defaults.string(forKey: Self.selectedTranscriptionModelKey),
           let model = TranscriptionModel(storageKey: key),
           TranscriptionModel.pickerOptions.contains(model) {
            self.selectedTranscriptionModel = model
        } else {
            self.selectedTranscriptionModel = Self.preferredDefaultTranscriptionModel
        }

        self.selectedLanguage = defaults.string(forKey: "selectedLanguage") ?? Self.defaultTranscriptionLanguage
        self.translateToEnglish = defaults.bool(forKey: "translateToEnglish")
        self.promptText = defaults.string(forKey: "promptText") ?? ""
        self.useFlashAttention = defaults.bool(forKey: "useFlashAttention")
        self.useVAD = defaults.bool(forKey: "useVAD")
        self.keepScreenOn = defaults.object(forKey: "keepScreenOn") == nil
            ? true
            : defaults.bool(forKey: "keepScreenOn")
        self.autoDeleteRecordings = defaults.bool(forKey: "autoDeleteRecordings")
        self.includeTimestamps = defaults.bool(forKey: "includeTimestamps")
    }

    private static func migrateDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        let appliedVersion = defaults.integer(forKey: defaultsMigrationVersionKey)
        guard appliedVersion < currentDefaultsMigrationVersion else { return }
        let hadModelSelection = defaults.string(forKey: selectedTranscriptionModelKey) != nil
            || defaults.string(forKey: legacySelectedModelSizeKey) != nil
        let hadLanguageSelection = defaults.string(forKey: "selectedLanguage") != nil

        if appliedVersion < 1 {
            migrateDefaultsToVersion1(defaults: defaults)
        }
        if appliedVersion < 2 {
            migrateDefaultsToVersion2(defaults: defaults)
        }
        if appliedVersion < 3 {
            migrateDefaultsToVersion3(defaults: defaults)
        }
        if appliedVersion < 4 {
            migrateDefaultsToVersion4(
                defaults: defaults,
                hadModelSelection: hadModelSelection,
                hadLanguageSelection: hadLanguageSelection
            )
        }
        if appliedVersion < 5 {
            migrateDefaultsToVersion5(
                defaults: defaults,
                hadModelSelection: hadModelSelection,
                hadLanguageSelection: hadLanguageSelection
            )
        }

        defaults.set(currentDefaultsMigrationVersion, forKey: defaultsMigrationVersionKey)
    }

    private static func migrateDefaultsToVersion1(defaults: UserDefaults) {
        if defaults.object(forKey: "keepScreenOn") == nil {
            defaults.set(true, forKey: "keepScreenOn")
        }
    }

    private static func migrateDefaultsToVersion2(defaults: UserDefaults) {
        guard defaults.object(forKey: legacySelectedModelSizeKey) == nil else { return }

        if whisperModelFileExists(for: .base) {
            defaults.set(WhisperModelSize.base.rawValue, forKey: legacySelectedModelSizeKey)
        } else {
            defaults.set(WhisperModelSize.largeV3TurboQ5_0.rawValue, forKey: legacySelectedModelSizeKey)
        }
    }

    private static func migrateDefaultsToVersion3(defaults: UserDefaults) {
        guard defaults.string(forKey: selectedTranscriptionModelKey) == nil else { return }

        if let legacyRaw = defaults.string(forKey: legacySelectedModelSizeKey),
           let model = TranscriptionModel(legacyWhisperRawValue: legacyRaw) {
            defaults.set(model.storageKey, forKey: selectedTranscriptionModelKey)
        } else {
            defaults.set(TranscriptionModel.whisper(.largeV3TurboQ5_0).storageKey, forKey: selectedTranscriptionModelKey)
        }
    }

    private static func migrateDefaultsToVersion4(
        defaults: UserDefaults,
        hadModelSelection: Bool,
        hadLanguageSelection: Bool
    ) {
        applyDefaultModelIfMissing(defaults: defaults, hadModelSelection: hadModelSelection)
        applyDefaultLanguageIfMissing(defaults: defaults, hadLanguageSelection: hadLanguageSelection)
    }

    private static func migrateDefaultsToVersion5(
        defaults: UserDefaults,
        hadModelSelection: Bool,
        hadLanguageSelection: Bool
    ) {
        applyDefaultModelIfMissing(defaults: defaults, hadModelSelection: hadModelSelection)
        applyDefaultLanguageIfMissing(defaults: defaults, hadLanguageSelection: hadLanguageSelection)
    }

    private static func applyDefaultModelIfMissing(defaults: UserDefaults, hadModelSelection: Bool) {
        guard !hadModelSelection else { return }
        defaults.set(preferredDefaultTranscriptionModel.storageKey, forKey: selectedTranscriptionModelKey)
    }

    private static func applyDefaultLanguageIfMissing(defaults: UserDefaults, hadLanguageSelection: Bool) {
        guard !hadLanguageSelection else { return }
        defaults.set(defaultTranscriptionLanguage, forKey: "selectedLanguage")
    }

    private static func whisperModelFileExists(for size: WhisperModelSize) -> Bool {
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return false
        }
        let modelURL = documentsPath.appendingPathComponent(size.fileName)
        return FileManager.default.fileExists(atPath: modelURL.path)
    }

    private static var defaultTranscriptionLanguage: String {
        "ja"
    }

    static var preferredDefaultTranscriptionModel: TranscriptionModel {
        if #available(iOS 26.0, *) {
            return .appleSpeech(.jaJP)
        }
        return .whisper(.tiny)
    }

    static let supportedLanguages: [(code: String, name: String)] = [
        ("ja", "Japanese"),
        ("auto", "Auto-Detect"),
        ("en", "English"),
        ("zh", "Chinese"),
        ("ko", "Korean"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("ru", "Russian"),
        ("ar", "Arabic"),
        ("hi", "Hindi"),
        ("nl", "Dutch"),
        ("pl", "Polish"),
        ("tr", "Turkish"),
        ("vi", "Vietnamese"),
        ("th", "Thai"),
        ("id", "Indonesian"),
    ]
}
