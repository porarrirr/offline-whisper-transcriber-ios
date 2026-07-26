import Foundation
import AVFoundation
import Observation

/// 再生位置は0.1秒間隔で更新されるため、`ObservableObject`ではなく`@Observable`を使う。
/// `ObservableObject`はビュー単位で購読されるので、再生位置を読まない画面まで毎秒10回無効化されてしまう。
@Observable
class AudioPlayer: NSObject, AVAudioPlayerDelegate {
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var errorMessage: String?

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var timer: Timer?

    func prepare(url: URL) {
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            player?.prepareToPlay()
            duration = player?.duration ?? 0
            currentTime = player?.currentTime ?? 0
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

        invalidateProgressTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.currentTime = player.currentTime
        }
    }

    func play(from time: TimeInterval) {
        guard player != nil else { return }
        let upperBound = max(0, duration)
        seek(to: min(max(0, time), upperBound))
        play()
    }
    
    func pause() {
        guard let player else { return }
        player.pause()
        currentTime = player.currentTime
        isPlaying = false
        invalidateProgressTimer()
    }
    
    func stop() {
        player?.stop()
        player?.currentTime = 0
        isPlaying = false
        invalidateProgressTimer()
        currentTime = 0
    }
    
    func seek(to time: TimeInterval) {
        let clampedTime = min(max(0, time), max(0, duration))
        player?.currentTime = clampedTime
        currentTime = clampedTime
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        stop()
    }

    private func invalidateProgressTimer() {
        timer?.invalidate()
        timer = nil
    }
}
