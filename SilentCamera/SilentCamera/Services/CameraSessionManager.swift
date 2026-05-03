import AVFoundation
import Combine

protocol CameraSessionManagerProtocol: AnyObject {
    var session: AVCaptureSession { get }
    var currentPosition: AVCaptureDevice.Position { get }
    var zoomFactor: CGFloat { get }
    var maxZoomFactor: CGFloat { get }

    func configureSession(for position: AVCaptureDevice.Position) throws
    func switchCamera() throws
    func setZoom(_ factor: CGFloat) throws
    func updateCaptureQuality(_ quality: CaptureQuality)
}

final class CameraSessionManager: NSObject, CameraSessionManagerProtocol {

    let session = AVCaptureSession()
    private(set) var currentPosition: AVCaptureDevice.Position = .back
    private(set) var zoomFactor: CGFloat = 1.0
    private(set) var maxZoomFactor: CGFloat = 1.0

    private var currentDevice: AVCaptureDevice?
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var videoOutputDelegate: AVCaptureVideoDataOutputSampleBufferDelegate?

    init(videoOutputDelegate: AVCaptureVideoDataOutputSampleBufferDelegate) {
        self.videoOutputDelegate = videoOutputDelegate
        super.init()
        configureOutputs()
    }

    private func configureOutputs() {
        videoDataOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoDataOutput.setSampleBufferDelegate(videoOutputDelegate, queue: DispatchQueue(label: "videoFrameQueue"))
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
    }

    func configureSession(for position: AVCaptureDevice.Position) throws {
        session.beginConfiguration()

        for input in session.inputs {
            session.removeInput(input)
        }
        for output in session.outputs {
            session.removeOutput(output)
        }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            session.commitConfiguration()
            throw CameraError.cameraNotFound
        }

        currentDevice = device
        maxZoomFactor = min(device.activeFormat.videoMaxZoomFactor, Constants.Camera.maxZoomFactor)

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
            } else {
                session.commitConfiguration()
                throw CameraError.inputConfigurationFailed
            }
        } catch {
            session.commitConfiguration()
            throw CameraError.inputConfigurationFailed
        }

        if session.canAddOutput(videoDataOutput) {
            session.addOutput(videoDataOutput)
        } else {
            session.commitConfiguration()
            throw CameraError.outputConfigurationFailed
        }

        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
            if let connection = movieOutput.connection(with: .video) {
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .auto
                }
            }
        } else {
            session.commitConfiguration()
            throw CameraError.outputConfigurationFailed
        }

        session.commitConfiguration()
        currentPosition = position

        if !session.isRunning {
            session.startRunning()
        }
    }

    func switchCamera() throws {
        let newPosition: AVCaptureDevice.Position = currentPosition == .back ? .front : .back
        try configureSession(for: newPosition)
        zoomFactor = Constants.Camera.defaultZoomFactor
    }

    func setZoom(_ factor: CGFloat) throws {
        guard let device = currentDevice else {
            throw CameraError.cameraNotFound
        }

        let clampedFactor = max(Constants.Camera.defaultZoomFactor, min(factor, maxZoomFactor))
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = clampedFactor
            device.unlockForConfiguration()
            zoomFactor = clampedFactor
        } catch {
            throw CameraError.inputConfigurationFailed
        }
    }

    func updateCaptureQuality(_ quality: CaptureQuality) {
        session.beginConfiguration()
        session.sessionPreset = quality.sessionPreset
        session.commitConfiguration()
    }

    func configureVideoOrientation(_ orientation: AVCaptureVideoOrientation) {
        if let connection = movieOutput.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = orientation
            }
        }
    }

    func configureVideoMirroring(_ mirrored: Bool) {
        if let connection = movieOutput.connection(with: .video) {
            if connection.isVideoMirroringSupported {
                connection.isVideoMirrored = mirrored
            }
        }
    }

    var isTorchAvailable: Bool {
        currentDevice?.hasTorch ?? false
    }
    
    var isFlashAvailable: Bool {
        currentDevice?.hasFlash ?? false
    }

    func setTorch(enabled: Bool) throws {
        guard let device = currentDevice, device.hasTorch else {
            return
        }

        do {
            try device.lockForConfiguration()
            if enabled {
                try device.setTorchModeOn(level: Constants.Camera.torchLevel)
            } else {
                device.torchMode = .off
            }
            device.unlockForConfiguration()
        } catch {
            throw CameraError.inputConfigurationFailed
        }
    }
}
