import Foundation
import AVFoundation

class AudioPlayer: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var errorMessage: String?
    
    private var player: AVAudioPlayer?
    private var timer: Timer?
    
    func prepare(url: URL) {
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            duration = player?.duration ?? 0
            errorMessage = nil
        } catch {
            errorMessage = String(localized: "Failed to prepare audio playback") + ": \(error.localizedDescription)"
            AppLogger.error(errorMessage ?? "Failed to prepare audio playback", context: "AudioPlayer")
        }
    }
    
    func play() {
        guard let player = player else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            let message = String(localized: "Failed to start audio playback") + ": \(error.localizedDescription)"
            errorMessage = message
            AppLogger.error(message, context: "AudioPlayer", error: error)
            return
        }

        guard player.play() else {
            let message = String(localized: "Failed to start audio playback")
            errorMessage = message
            AppLogger.error(message, context: "AudioPlayer")
            return
        }

        errorMessage = nil
        isPlaying = true
        
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.currentTime = player.currentTime
            if !player.isPlaying {
                self?.stop()
            }
        }
    }

    func play(from time: TimeInterval) {
        guard player != nil else { return }
        let upperBound = max(0, duration)
        seek(to: min(max(0, time), upperBound))
        play()
    }
    
    func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
    }
    
    func stop() {
        player?.stop()
        player?.currentTime = 0
        isPlaying = false
        timer?.invalidate()
        currentTime = 0
    }
    
    func seek(to time: TimeInterval) {
        let clampedTime = min(max(0, time), max(0, duration))
        player?.currentTime = clampedTime
        currentTime = clampedTime
    }
}
