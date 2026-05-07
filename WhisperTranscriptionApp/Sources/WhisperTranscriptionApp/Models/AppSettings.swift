import Foundation

@MainActor
class AppSettings: ObservableObject {
    static let shared = AppSettings()
    
    @Published var selectedModelSize: ModelSize {
        didSet { UserDefaults.standard.set(selectedModelSize.rawValue, forKey: "selectedModelSize") }
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
    
    private init() {
        let defaults = UserDefaults.standard
        self.selectedModelSize = ModelSize(rawValue: defaults.string(forKey: "selectedModelSize") ?? "") ?? .base
        self.selectedLanguage = defaults.string(forKey: "selectedLanguage") ?? "ja"
        self.translateToEnglish = defaults.bool(forKey: "translateToEnglish")
        self.promptText = defaults.string(forKey: "promptText") ?? ""
        self.useFlashAttention = defaults.bool(forKey: "useFlashAttention")
        self.useVAD = defaults.bool(forKey: "useVAD")
        self.keepScreenOn = defaults.bool(forKey: "keepScreenOn")
        self.autoDeleteRecordings = defaults.bool(forKey: "autoDeleteRecordings")
        self.includeTimestamps = defaults.bool(forKey: "includeTimestamps")
    }
    
    enum ModelSize: String, CaseIterable, Identifiable {
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
            case .tiny: return "Tiny（高速・軽量）"
            case .tinyQ5_1: return "Tiny Q5_1（さらに軽量）"
            case .base: return "Base（バランス）"
            case .baseQ5_1: return "Base Q5_1（軽量・バランス）"
            case .small: return "Small（高精度）"
            case .smallQ5_1: return "Small Q5_1（軽量・高精度）"
            case .medium: return "Medium（最高精度）"
            case .mediumQ5_0: return "Medium Q5_0（軽量・最高精度）"
            case .largeV3TurboQ8_0: return "Large v3 Turbo Q8_0（高速・高精度）"
            case .largeV3TurboQ5_0: return "Large v3 Turbo Q5_0（軽量・高速高精度）"
            }
        }
        
        var fileName: String {
            "ggml-\(rawValue).bin"
        }
        
        var downloadURL: URL? {
            URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")
        }
        
        var approximateSize: String {
            switch self {
            case .tiny: return "約39MB"
            case .tinyQ5_1: return "約15MB"
            case .base: return "約142MB"
            case .baseQ5_1: return "約60MB"
            case .small: return "約466MB"
            case .smallQ5_1: return "約163MB"
            case .medium: return "約1.5GB"
            case .mediumQ5_0: return "約568MB"
            case .largeV3TurboQ8_0: return "約874MB"
            case .largeV3TurboQ5_0: return "約574MB"
            }
        }
    }
    
    static let supportedLanguages: [(code: String, name: String)] = [
        ("auto", "自動検出"),
        ("ja", "日本語"),
        ("en", "英語"),
        ("zh", "中国語"),
        ("ko", "韓国語"),
        ("es", "スペイン語"),
        ("fr", "フランス語"),
        ("de", "ドイツ語"),
        ("it", "イタリア語"),
        ("pt", "ポルトガル語"),
        ("ru", "ロシア語"),
        ("ar", "アラビア語"),
        ("hi", "ヒンディー語"),
        ("nl", "オランダ語"),
        ("pl", "ポーランド語"),
        ("tr", "トルコ語"),
        ("vi", "ベトナム語"),
        ("th", "タイ語"),
        ("id", "インドネシア語"),
    ]
}
