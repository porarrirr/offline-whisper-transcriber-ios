import Foundation

enum Constants {

    enum Camera {
        static let maxZoomFactor: CGFloat = 10.0
        static let defaultZoomFactor: CGFloat = 1.0
        static let jpegCompressionQuality: CGFloat = 0.95
        static let torchLevel: Float = 1.0
    }

    enum Processing {
        static let maxFrameBuffer = 15
        static let defaultProcessingIntensity: Float = 0.8
        static let defaultFrameCount = 5
        static let minFrameCount = 3
        static let maxFrameCount = 15
        static let frameCountStep = 2
        static let minProcessingIntensity: Float = 0.1
        static let maxProcessingIntensity: Float = 1.0
        static let processingIntensityStep: Float = 0.1
    }

    enum UI {
        static let touchTargetSize: CGFloat = 44
        static let captureButtonSize: CGFloat = 72
        static let captureButtonInnerSize: CGFloat = 60
        static let thumbnailSize: CGFloat = 50
        static let thumbnailCornerRadius: CGFloat = 8
        static let thumbnailBorderWidth: CGFloat = 2
        static let iconSize: CGFloat = 10
        static let recordingIndicatorPadding: CGFloat = 60
        static let progressOverlayPadding: CGFloat = 120
        static let gridLineWidth: CGFloat = 0.5
        static let gridLineOpacity: Double = 0.4
        static let backgroundOpacity: Double = 0.6
        static let overlayOpacity: Double = 0.7
    }

    enum Animation {
        static let modeSwitchDuration: Double = 0.2
        static let captureButtonDuration: Double = 0.15
        static let recordButtonDuration: Double = 0.2
        static let cameraSwitchDuration: Double = 0.3
        static let recordingIndicatorDuration: Double = 0.5
    }

    enum Timing {
        static let recordingTimerInterval: TimeInterval = 1.0
        static let captureDelay: UInt64 = 100_000_000
        static let frameCaptureDelay: UInt64 = 100_000_000
    }

    enum Grid {
        static let columns = 3
        static let rows = 3
    }

    enum ImageProcessing {
        static let motionEstimationScale: CGFloat = 512.0
        static let motionEstimationBlockSize = 32
        static let motionSearchRange = 8
        static let motionSearchStep = 2
        static let sharpenRadius: Float = 2.5
        static let denoiseNoiseLevel: Float = 0.02
        static let denoiseSharpness: Float = 0.4
        static let vibranceAmount: Float = 0.3
        static let contrastBoost: Float = 0.15
        static let brightnessBoost: Float = 0.02
        static let saturationBoost: Float = 0.2
    }
}
