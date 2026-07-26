import Foundation
import Speech

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:
            return "System"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }
}

/// 履歴詳細画面の文字起こし表示スタイル。
/// `timeline`はセグメント単位の行(タップで頭出し・長押しで編集)、
/// `reading`は改行せず1つの文章として表示(タップでの頭出しは行わない)。
enum TranscriptDisplayStyle: String, CaseIterable, Identifiable {
    case timeline
    case reading

    var id: String { rawValue }
}

struct PreferredTranscriptionDefaults: Equatable {
    let model: TranscriptionModel
    let whisperLanguage: String
}

enum TranscriptionDefaultResolver {
    static let fallbackModel: TranscriptionModel = .whisper(.smallQ5_1)

    static func preferredDefaults(
        preferredLanguages: [String],
        supportedSpeechLocale: Locale?
    ) -> PreferredTranscriptionDefaults {
        let whisperLanguage = defaultWhisperLanguage(preferredLanguages: preferredLanguages)
        if let supportedSpeechLocale {
            return PreferredTranscriptionDefaults(
                model: .appleSpeech(AppleSpeechLocale(locale: supportedSpeechLocale)),
                whisperLanguage: whisperLanguage
            )
        }
        return PreferredTranscriptionDefaults(
            model: fallbackModel,
            whisperLanguage: whisperLanguage
        )
    }

    static func provisionalDefaults(preferredLanguages: [String]) -> PreferredTranscriptionDefaults {
        preferredDefaults(preferredLanguages: preferredLanguages, supportedSpeechLocale: nil)
    }

    static func defaultWhisperLanguage(preferredLanguages: [String]) -> String {
        guard let preferredLocale = preferredLocale(from: preferredLanguages),
              let languageCode = preferredLocale.language.languageCode?.identifier,
              supportedWhisperLanguageCodes.contains(languageCode) else {
            return "auto"
        }
        return languageCode
    }

    static func preferredLocale(from preferredLanguages: [String]) -> Locale? {
        guard let preferredLanguage = preferredLanguages.first,
              !preferredLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return Locale(identifier: preferredLanguage)
    }

    static func shouldResolveLocaleDefaultModel(
        hadModelSelection: Bool,
        selectedModelStorageKey: String?
    ) -> Bool {
        guard hadModelSelection else { return true }
        return selectedModelStorageKey == TranscriptionModel.appleSpeech(.jaJP).storageKey
    }

    static func shouldApplyResolvedLocaleDefault(
        expectedModelStorageKey: String,
        currentModelStorageKey: String
    ) -> Bool {
        expectedModelStorageKey == currentModelStorageKey
    }

    static func persistedModel(storageKey: String?) -> TranscriptionModel? {
        guard let storageKey else { return nil }
        return TranscriptionModel(storageKey: storageKey)
    }

    private static let supportedWhisperLanguageCodes: Set<String> = [
        "ja",
        "en",
        "zh",
        "ko",
        "es",
        "fr",
        "de",
        "it",
        "pt",
        "ru",
        "ar",
        "hi",
        "nl",
        "pl",
        "tr",
        "vi",
        "th",
        "id",
    ]
}

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

    @Published var appAppearance: AppAppearance {
        didSet { UserDefaults.standard.set(appAppearance.rawValue, forKey: Self.appAppearanceKey) }
    }

    @Published var transcriptDisplayStyle: TranscriptDisplayStyle {
        didSet { UserDefaults.standard.set(transcriptDisplayStyle.rawValue, forKey: Self.transcriptDisplayStyleKey) }
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
    private static let appAppearanceKey = "appAppearance"
    private static let transcriptDisplayStyleKey = "transcriptDisplayStyle"
    private static let defaultsMigrationVersionKey = "appSettingsDefaultsMigrationVersion"
    private static let localeDefaultResolutionPendingKey = "localeDefaultResolutionPending"
    private static let localeDefaultResolutionVersionKey = "localeDefaultResolutionVersion"
    private static let currentLocaleDefaultResolutionVersion = 1
    private static let currentDefaultsMigrationVersion = 6

    private init() {
        Self.migrateDefaultsIfNeeded()

        let defaults = UserDefaults.standard
        if let model = TranscriptionDefaultResolver.persistedModel(
            storageKey: defaults.string(forKey: Self.selectedTranscriptionModelKey)
        ) {
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
        if let storedAppearance = defaults.string(forKey: Self.appAppearanceKey),
           let appAppearance = AppAppearance(rawValue: storedAppearance) {
            self.appAppearance = appAppearance
        } else {
            self.appAppearance = .system
        }
        if let storedTranscriptDisplayStyle = defaults.string(forKey: Self.transcriptDisplayStyleKey),
           let transcriptDisplayStyle = TranscriptDisplayStyle(rawValue: storedTranscriptDisplayStyle) {
            self.transcriptDisplayStyle = transcriptDisplayStyle
        } else {
            self.transcriptDisplayStyle = .timeline
        }

        let localeResolutionExpectedModelKey = selectedTranscriptionModel.storageKey
        let localeResolutionExpectedLanguage = selectedLanguage
        Task { @MainActor [weak self] in
            await self?.resolvePendingLocaleDefaultIfNeeded(
                expectedModelKey: localeResolutionExpectedModelKey,
                expectedLanguage: localeResolutionExpectedLanguage
            )
        }
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
        if appliedVersion < 6 {
            migrateDefaultsToVersion6(
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

    private static func migrateDefaultsToVersion6(
        defaults: UserDefaults,
        hadModelSelection: Bool,
        hadLanguageSelection: Bool
    ) {
        let shouldResolveDefaultModel = TranscriptionDefaultResolver.shouldResolveLocaleDefaultModel(
            hadModelSelection: hadModelSelection,
            selectedModelStorageKey: defaults.string(forKey: selectedTranscriptionModelKey)
        )
        guard shouldResolveDefaultModel else { return }

        let provisionalDefaults = TranscriptionDefaultResolver.provisionalDefaults(
            preferredLanguages: Locale.preferredLanguages
        )
        defaults.set(provisionalDefaults.model.storageKey, forKey: selectedTranscriptionModelKey)

        if !hadLanguageSelection || languageSelectionIsOldDefaultEquivalent(defaults: defaults) {
            defaults.set(provisionalDefaults.whisperLanguage, forKey: "selectedLanguage")
        }

        defaults.set(true, forKey: localeDefaultResolutionPendingKey)
        defaults.set(0, forKey: localeDefaultResolutionVersionKey)
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

    private static func languageSelectionIsOldDefaultEquivalent(defaults: UserDefaults) -> Bool {
        defaults.string(forKey: "selectedLanguage") == "ja"
    }

    private static var defaultTranscriptionLanguage: String {
        TranscriptionDefaultResolver.defaultWhisperLanguage(preferredLanguages: Locale.preferredLanguages)
    }

    static var preferredDefaultTranscriptionModel: TranscriptionModel {
        TranscriptionDefaultResolver.fallbackModel
    }

    static func preferredAppleSpeechLocaleForDevice() async -> AppleSpeechLocale? {
        guard #available(iOS 26.0, *), SpeechTranscriber.isAvailable,
              let preferredLocale = TranscriptionDefaultResolver.preferredLocale(
                from: Locale.preferredLanguages
              ),
              let supportedLocale = await SpeechTranscriber.supportedLocale(
                equivalentTo: preferredLocale
              ) else {
            return nil
        }
        return AppleSpeechLocale(locale: supportedLocale)
    }

    private static func preferredDefaultsFromDevice() async -> PreferredTranscriptionDefaults {
        let preferredLanguages = Locale.preferredLanguages
        guard let preferredLocale = TranscriptionDefaultResolver.preferredLocale(from: preferredLanguages),
              #available(iOS 26.0, *),
              SpeechTranscriber.isAvailable else {
            return TranscriptionDefaultResolver.provisionalDefaults(preferredLanguages: preferredLanguages)
        }

        let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: preferredLocale)
        return TranscriptionDefaultResolver.preferredDefaults(
            preferredLanguages: preferredLanguages,
            supportedSpeechLocale: supportedLocale
        )
    }

    private func resolvePendingLocaleDefaultIfNeeded(
        expectedModelKey: String,
        expectedLanguage: String
    ) async {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.localeDefaultResolutionPendingKey),
              defaults.integer(forKey: Self.localeDefaultResolutionVersionKey) < Self.currentLocaleDefaultResolutionVersion else {
            return
        }

        guard TranscriptionDefaultResolver.shouldApplyResolvedLocaleDefault(
            expectedModelStorageKey: expectedModelKey,
            currentModelStorageKey: selectedTranscriptionModel.storageKey
        ) else {
            completePendingLocaleDefaultResolution(defaults: defaults)
            return
        }

        let resolvedDefaults = await Self.preferredDefaultsFromDevice()

        guard defaults.bool(forKey: Self.localeDefaultResolutionPendingKey) else { return }
        guard TranscriptionDefaultResolver.shouldApplyResolvedLocaleDefault(
            expectedModelStorageKey: expectedModelKey,
            currentModelStorageKey: selectedTranscriptionModel.storageKey
        ) else {
            completePendingLocaleDefaultResolution(defaults: defaults)
            return
        }

        if selectedLanguage == expectedLanguage {
            selectedLanguage = resolvedDefaults.whisperLanguage
        }
        selectedTranscriptionModel = resolvedDefaults.model
        completePendingLocaleDefaultResolution(defaults: defaults)

        if ModelManager.shared.currentTranscriptionModel != resolvedDefaults.model {
            ModelManager.shared.switchModel(model: resolvedDefaults.model)
        } else {
            ModelManager.shared.ensureModelAvailability()
        }
    }

    private func completePendingLocaleDefaultResolution(defaults: UserDefaults) {
        defaults.set(false, forKey: Self.localeDefaultResolutionPendingKey)
        defaults.set(Self.currentLocaleDefaultResolutionVersion, forKey: Self.localeDefaultResolutionVersionKey)
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
