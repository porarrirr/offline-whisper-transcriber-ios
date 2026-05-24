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
        self.selectedLanguage = defaults.string(forKey: "selectedLanguage") ?? "auto"
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
             case .tiny: return String(localized: "Tiny (Fast & Light)")
             case .tinyQ5_1: return String(localized: "Tiny Q5_1 (More Light)")
             case .base: return String(localized: "Base (Balanced)")
             case .baseQ5_1: return String(localized: "Base Q5_1 (Light & Balanced)")
             case .small: return String(localized: "Small (High Accuracy)")
             case .smallQ5_1: return String(localized: "Small Q5_1 (Light & High Accuracy)")
             case .medium: return String(localized: "Medium (Best Accuracy)")
             case .mediumQ5_0: return String(localized: "Medium Q5_0 (Light & Best Accuracy)")
             case .largeV3TurboQ8_0: return String(localized: "Large v3 Turbo Q8_0 (Fast & High Accuracy)")
             case .largeV3TurboQ5_0: return String(localized: "Large v3 Turbo Q5_0 (Light & Fast/High Accuracy)")
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
     
     static let supportedLanguages: [(code: String, name: String)] = [
         ("auto", "Auto-Detect"),
         ("ja", "Japanese"),
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
