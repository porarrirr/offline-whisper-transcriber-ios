import AVFoundation
import SwiftUI

enum CameraMode: String, CaseIterable, Identifiable {
    case photo
    case video

    var id: String { rawValue }

    var label: String {
        switch self {
        case .photo: return "写真"
        case .video: return "動画"
        }
    }

    var icon: String {
        switch self {
        case .photo: return "camera.fill"
        case .video: return "video.fill"
        }
    }
}

enum FlashMode: String, CaseIterable, Identifiable {
    case off
    case on
    case auto

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "OFF"
        case .on: return "ON"
        case .auto: return "AUTO"
        }
    }

    var icon: String {
        switch self {
        case .off: return "bolt.slash.fill"
        case .on: return "bolt.fill"
        case .auto: return "bolt.badge.a"
        }
    }

    var avCaptureFlashMode: AVCaptureDevice.FlashMode {
        switch self {
        case .off: return .off
        case .on: return .on
        case .auto: return .auto
        }
    }
}

enum CaptureQuality: String, CaseIterable, Identifiable {
    case hd4k
    case hd1080p
    case hd720p

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hd4k: return "4K"
        case .hd1080p: return "1080p"
        case .hd720p: return "720p"
        }
    }

    var sessionPreset: AVCaptureSession.Preset {
        switch self {
        case .hd4k: return .hd4K3840x2160
        case .hd1080p: return .hd1920x1080
        case .hd720p: return .hd1280x720
        }
    }
}

@Observable
final class CameraSettings {
    var cameraMode: CameraMode = .photo {
        didSet { save() }
    }
    var flashMode: FlashMode = .off {
        didSet { save() }
    }
    var captureQuality: CaptureQuality = .hd1080p {
        didSet { save() }
    }
    var showGrid: Bool = false {
        didSet { save() }
    }
    var torchEnabled: Bool = false {
        didSet { save() }
    }

    var processingMode: ProcessingMode = .stack {
        didSet { save() }
    }
    var processingIntensity: Float = Constants.Processing.defaultProcessingIntensity {
        didSet { save() }
    }
    var frameCount: Int = Constants.Processing.defaultFrameCount {
        didSet { save() }
    }
    
    init() {
        load()
    }
    
    private func load() {
        let defaults = UserDefaults.standard
        if let modeRaw = defaults.string(forKey: "cameraMode"),
           let mode = CameraMode(rawValue: modeRaw) {
            cameraMode = mode
        }
        if let flashRaw = defaults.string(forKey: "flashMode"),
           let flash = FlashMode(rawValue: flashRaw) {
            flashMode = flash
        }
        if let qualityRaw = defaults.string(forKey: "captureQuality"),
           let quality = CaptureQuality(rawValue: qualityRaw) {
            captureQuality = quality
        }
        showGrid = defaults.bool(forKey: "showGrid")
        torchEnabled = defaults.bool(forKey: "torchEnabled")
        
        if let processingRaw = defaults.string(forKey: "processingMode"),
           let processing = ProcessingMode(rawValue: processingRaw) {
            processingMode = processing
        }
        processingIntensity = defaults.float(forKey: "processingIntensity")
        if processingIntensity == 0 {
            processingIntensity = Constants.Processing.defaultProcessingIntensity
        }
        frameCount = defaults.integer(forKey: "frameCount")
        if frameCount == 0 {
            frameCount = Constants.Processing.defaultFrameCount
        }
    }
    
    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(cameraMode.rawValue, forKey: "cameraMode")
        defaults.set(flashMode.rawValue, forKey: "flashMode")
        defaults.set(captureQuality.rawValue, forKey: "captureQuality")
        defaults.set(showGrid, forKey: "showGrid")
        defaults.set(torchEnabled, forKey: "torchEnabled")
        defaults.set(processingMode.rawValue, forKey: "processingMode")
        defaults.set(processingIntensity, forKey: "processingIntensity")
        defaults.set(frameCount, forKey: "frameCount")
    }
}
