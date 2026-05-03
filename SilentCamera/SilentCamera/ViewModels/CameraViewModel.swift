import AVFoundation
import CoreVideo
import Photos
import SwiftUI
import UIKit

@Observable
final class CameraViewModel: NSObject {

    let settings = CameraSettings()
    let imageProcessor = ImageProcessor()

    var session: AVCaptureSession { sessionManager.session }
    var isSessionRunning = false
    var currentPosition: AVCaptureDevice.Position { sessionManager.currentPosition }
    var zoomFactor: CGFloat { sessionManager.zoomFactor }
    var isCapturing: Bool { captureManager.isCapturing }
    var lastCaptureImage: UIImage? { captureManager.lastCaptureImage }
    var authorizationStatus: AVAuthorizationStatus = .notDetermined
    var showError = false
    var errorMessage = ""
    var errorRecoverySuggestion: String?

    var isRecording = false
    var recordingDuration: TimeInterval = 0
    var captureProgress: Float { captureManager.captureProgress }
    var photoLibraryAuthorizationStatus: PHAuthorizationStatus = .notDetermined

    private var sessionManager: CameraSessionManager!
    private var captureManager: CaptureManager!
    private var recordingTimer: Timer?

    override init() {
        super.init()
        authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        photoLibraryAuthorizationStatus = PHPhotoLibrary.authorizationStatus()
        setupManagers()
    }

    private func setupManagers() {
        sessionManager = CameraSessionManager(videoOutputDelegate: self)
        captureManager = CaptureManager(imageProcessor: imageProcessor, movieOutput: AVCaptureMovieFileOutput())
    }

    func requestAuthorization() async {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        authorizationStatus = granted ? .authorized : .denied
        if granted {
            await setupSession()
        }
        let photoStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        photoLibraryAuthorizationStatus = photoStatus
    }

    func setupSession() async {
        await withCheckedContinuation { (continuation: @Sendable () -> Void) in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    continuation()
                    return
                }
                do {
                    try self.sessionManager.configureSession(for: .back)
                    Task { @MainActor in self.isSessionRunning = true }
                } catch {
                    Task { @MainActor in self.presentError(error) }
                }
                continuation()
            }
        }
    }

    func switchCamera() {
        guard !isRecording else { return }
        do {
            try sessionManager.switchCamera()
        } catch {
            presentError(error)
        }
    }

    func setZoom(_ factor: CGFloat) {
        do {
            try sessionManager.setZoom(factor)
        } catch {
            presentError(error)
        }
    }

    func capturePhoto() {
        guard !isCapturing else { return }

        Task {
            do {
                // フラッシュモードに応じてトーチを制御
                var torchWasTurnedOn = false
                if settings.flashMode == .on || settings.flashMode == .auto {
                    if sessionManager.isTorchAvailable {
                        try? sessionManager.setTorch(enabled: true)
                        torchWasTurnedOn = true
                    }
                }
                
                let image = try await captureManager.capturePhoto(
                    mode: settings.processingMode,
                    intensity: settings.processingIntensity,
                    frameCount: settings.frameCount
                )
                
                // トーチを消灯
                if torchWasTurnedOn {
                    try? sessionManager.setTorch(enabled: false)
                }
                
                await MainActor.run {
                    lastCaptureImage = image
                }
            } catch {
                await MainActor.run {
                    presentError(error)
                }
            }
        }
    }

    func toggleTorch() {
        guard sessionManager.isTorchAvailable else { return }
        do {
            try sessionManager.setTorch(enabled: !settings.torchEnabled)
            settings.torchEnabled.toggle()
        } catch {
            presentError(error)
        }
    }

    func startRecording() {
        guard !isRecording else { return }

        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "video_\(Date().timeIntervalSince1970).mp4"
        let outputURL = tempDir.appendingPathComponent(fileName)

        if settings.torchEnabled {
            do {
                try sessionManager.setTorch(enabled: true)
            } catch {}
        }

        do {
            captureManager.recordingCompletion = { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    switch result {
                    case .success(let url):
                        do {
                            try await PhotoLibraryService.shared.saveVideo(from: url)
                        } catch {
                            self.presentError(CameraError.saveFailed)
                        }
                    case .failure(let error):
                        self.presentError(error)
                    }
                }
            }
            try captureManager.startRecording(
                to: outputURL,
                orientation: .portrait,
                mirrored: currentPosition == .front
            )
            isRecording = true
            recordingDuration = 0

            recordingTimer = Timer.scheduledTimer(withTimeInterval: Constants.Timing.recordingTimerInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.recordingDuration += 1
                }
            }
        } catch {
            presentError(error)
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        captureManager.stopRecording()
        recordingTimer?.invalidate()
        recordingTimer = nil

        if settings.torchEnabled {
            do {
                try sessionManager.setTorch(enabled: false)
            } catch {}
        }
    }

    func switchCameraMode(_ mode: CameraMode) {
        guard !isRecording else { return }
        settings.cameraMode = mode

        if mode == .photo {
            settings.torchEnabled = false
            do {
                try sessionManager.setTorch(enabled: false)
            } catch {}
        }
    }

    func updateCaptureQuality(_ quality: CaptureQuality) {
        settings.captureQuality = quality
        sessionManager.updateCaptureQuality(quality)
    }

    var recordingDurationText: String {
        let minutes = Int(recordingDuration) / 60
        let seconds = Int(recordingDuration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func presentError(_ error: Error) {
        if let cameraError = error as? CameraError {
            errorMessage = cameraError.errorDescription ?? "不明なエラーが発生しました"
            errorRecoverySuggestion = cameraError.recoverySuggestion
        } else {
            errorMessage = error.localizedDescription
            errorRecoverySuggestion = nil
        }
        showError = true
    }
}

extension CameraViewModel: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        captureManager.addFrame(pixelBuffer)
    }
}
