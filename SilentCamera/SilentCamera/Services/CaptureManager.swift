import AVFoundation
import UIKit

protocol CaptureManagerProtocol: AnyObject {
    var isCapturing: Bool { get }
    var captureProgress: Float { get }
    var lastCaptureImage: UIImage? { get }

    func capturePhoto(mode: ProcessingMode, intensity: Float, frameCount: Int) async throws -> UIImage
    func startRecording(to url: URL, orientation: AVCaptureVideoOrientation, mirrored: Bool) throws
    func stopRecording()
}

final class CaptureManager: NSObject, CaptureManagerProtocol {

    private(set) var isCapturing = false
    private(set) var captureProgress: Float = 0
    private(set) var lastCaptureImage: UIImage?

    private let imageProcessor: ImageProcessorProtocol
    private let movieOutput: AVCaptureMovieFileOutput
    private var frameBuffer: [CVPixelBuffer] = []
    private let frameBufferLock = NSLock()
    private let maxFrameBuffer = Constants.Processing.maxFrameBuffer
    private var wantsCapture = false
    private var capturedFrame: UIImage?
    var recordingCompletion: ((Result<URL, Error>) -> Void)?

    init(imageProcessor: ImageProcessorProtocol = ImageProcessor(), movieOutput: AVCaptureMovieFileOutput) {
        self.imageProcessor = imageProcessor
        self.movieOutput = movieOutput
        super.init()
    }

    func addFrame(_ pixelBuffer: CVPixelBuffer) {
        frameBufferLock.lock()
        if frameBuffer.count < maxFrameBuffer {
            frameBuffer.append(pixelBuffer)
        } else {
            frameBuffer.removeFirst()
            frameBuffer.append(pixelBuffer)
        }
        frameBufferLock.unlock()

        if wantsCapture {
            wantsCapture = false
            capturedFrame = pixelBufferToUIImage(pixelBuffer)
        }
    }

    func capturePhoto(mode: ProcessingMode, intensity: Float, frameCount: Int) async throws -> UIImage {
        guard !isCapturing else {
            throw CameraError.captureFailed
        }

        isCapturing = true
        captureProgress = 0

        defer {
            Task { @MainActor in
                isCapturing = false
                captureProgress = 0
            }
        }

        if mode == .none {
            return try await captureSingleFrame()
        } else {
            return try await captureWithProcessing(mode: mode, intensity: intensity, frameCount: frameCount)
        }
    }

    private func captureSingleFrame() async throws -> UIImage {
        wantsCapture = true

        try await Task.sleep(nanoseconds: Constants.Timing.captureDelay)

        guard let image = capturedFrame else {
            throw CameraError.captureFailed
        }

        lastCaptureImage = image
        try await saveImage(image)
        return image
    }

    private func captureWithProcessing(mode: ProcessingMode, intensity: Float, frameCount: Int) async throws -> UIImage {
        let framesToCapture: Int

        switch mode {
        case .stack:
            framesToCapture = frameCount
        case .hdr:
            framesToCapture = 3
        case .denoise:
            framesToCapture = 5
        case .enhance, .none:
            framesToCapture = 1
        }

        await MainActor.run {
            captureProgress = 0.1
        }

        frameBufferLock.lock()
        frameBuffer.removeAll()
        frameBufferLock.unlock()

        try await Task.sleep(nanoseconds: UInt64(framesToCapture) * Constants.Timing.frameCaptureDelay)

        frameBufferLock.lock()
        let capturedFrames = Array(frameBuffer.prefix(framesToCapture))
        frameBufferLock.unlock()

        guard !capturedFrames.isEmpty else {
            throw CameraError.captureFailed
        }

        await MainActor.run {
            captureProgress = 0.3
        }

        guard let processedImage = await imageProcessor.processFrames(
            capturedFrames,
            mode: mode,
            intensity: intensity
        ) else {
            throw CameraError.processingFailed
        }

        await MainActor.run {
            captureProgress = 1.0
        }

        lastCaptureImage = processedImage
        try await saveImage(processedImage)
        return processedImage
    }

    private func saveImage(_ image: UIImage) async throws {
        guard let imageData = image.jpegData(compressionQuality: Constants.Camera.jpegCompressionQuality) else {
            throw CameraError.saveFailed
        }

        do {
            try await PhotoLibraryService.shared.saveImage(imageData)
        } catch {
            throw CameraError.saveFailed
        }
    }

    func startRecording(to url: URL, orientation: AVCaptureVideoOrientation, mirrored: Bool) throws {
        guard !movieOutput.isRecording else {
            throw CameraError.recordingFailed("既に録画中です")
        }

        if let connection = movieOutput.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = orientation
            }
            if mirrored && connection.isVideoMirroringSupported {
                connection.isVideoMirrored = true
            }
        }

        movieOutput.startRecording(to: url, recordingDelegate: self)
    }

    func stopRecording() {
        guard movieOutput.isRecording else { return }
        movieOutput.stopRecording()
    }

    private func pixelBufferToUIImage(_ pixelBuffer: CVPixelBuffer) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)
    }
}

extension CaptureManager: AVCaptureFileOutputRecordingDelegate {

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        if let error {
            recordingCompletion?(.failure(CameraError.recordingFailed(error.localizedDescription)))
        } else {
            recordingCompletion?(.success(outputFileURL))
        }
        recordingCompletion = nil
    }
}
