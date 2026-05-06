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
        case base = "base"
        case small = "small"
        case medium = "medium"
        
        var id: String { rawValue }
        
        var displayName: String {
            switch self {
            case .tiny: return "Tiny（高速・軽量）"
            case .base: return "Base（バランス）"
            case .small: return "Small（高精度）"
            case .medium: return "Medium（最高精度）"
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
            case .base: return "約142MB"
            case .small: return "約466MB"
            case .medium: return "約1.5GB"
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
