import Foundation
import AVFoundation

class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var currentTime: TimeInterval = 0
    @Published var audioLevel: Float = 0.0
    
    private var audioRecorder: AVAudioRecorder?
    private var timer: Timer?
    private var recordingURL: URL?
    
    var currentRecordingURL: URL? {
        recordingURL
    }
    
    private func setupSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)
    }
    
    func startRecording() throws {
        try setupSession()
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw AudioRecorderError.documentsDirectoryUnavailable
        }
        let audioFilename = documentsPath.appendingPathComponent("recording_\(Date().timeIntervalSince1970).m4a")
        
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
        audioRecorder?.delegate = self
        audioRecorder?.isMeteringEnabled = true
        guard audioRecorder?.record() == true else {
            throw AudioRecorderError.recordingStartFailed
        }
        
        recordingURL = audioFilename
        isRecording = true
        currentTime = 0
        
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.updateRecordingState()
        }
    }
    
    func stopRecording() -> URL? {
        audioRecorder?.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        timer?.invalidate()
        timer = nil
        isRecording = false
        audioLevel = 0
        
        return recordingURL
    }
    
    private func updateRecordingState() {
        guard let recorder = audioRecorder else { return }
        currentTime = recorder.currentTime
        recorder.updateMeters()
        audioLevel = recorder.averagePower(forChannel: 0)
    }
    
    func requestPermission(completion: @escaping (Bool) -> Void) {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }
}

extension AudioRecorder: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            isRecording = false
            audioLevel = 0
        }
    }
}

enum AudioRecorderError: LocalizedError {
    case documentsDirectoryUnavailable
    case recordingStartFailed
    
    var errorDescription: String? {
        switch self {
        case .documentsDirectoryUnavailable:
            return "録音ファイルの保存先を取得できませんでした"
        case .recordingStartFailed:
            return "録音を開始できませんでした"
        }
    }
}
