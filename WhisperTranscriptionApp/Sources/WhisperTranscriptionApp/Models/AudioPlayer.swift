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
    var playbackRate: Float = 1
    var errorMessage: String?

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var timer: Timer?

    func prepare(url: URL) {
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            player?.enableRate = true
            player?.rate = playbackRate
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
            try AudioSessionOwnership.shared.startPlayback(player)
        } catch {
            let message = String(localized: "Failed to start audio playback") + ": \(error.localizedDescription)"
            errorMessage = message
            AppLogger.error(message, context: "AudioPlayer", error: error)
            return
        }

        errorMessage = nil
        isPlaying = true

        invalidateProgressTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.currentTime = player.currentTime
            if !player.isPlaying {
                self?.isPlaying = false
                self?.invalidateProgressTimer()
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

    func skip(by interval: TimeInterval) {
        seek(to: currentTime + interval)
    }

    func cyclePlaybackRate() {
        switch playbackRate {
        case 1:
            playbackRate = 1.5
        case 1.5:
            playbackRate = 2
        default:
            playbackRate = 1
        }
        player?.rate = playbackRate
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        stop()
    }

    private func invalidateProgressTimer() {
        timer?.invalidate()
        timer = nil
    }
}

/// Serializes category changes and playback starts against recording ownership.
final class AudioSessionOwnership: @unchecked Sendable {
    static let shared = AudioSessionOwnership()
    private let lock = NSLock()
    private var recording = false
    private weak var playback: AVAudioPlayer?

    func beginRecording() {
        lock.lock()
        defer { lock.unlock() }
        recording = true
        playback?.stop()
        playback = nil
    }

    func endRecording(_ deactivate: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        deactivate()
        recording = false
    }

    func startPlayback(_ player: AVAudioPlayer) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !recording else {
            throw NSError(domain: "AudioSessionOwnership", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "Audio playback is unavailable while recording.")])
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
        playback = player
        guard player.play() else {
            throw NSError(domain: "AudioSessionOwnership", code: 2, userInfo: [NSLocalizedDescriptionKey: String(localized: "Failed to start audio playback")])
        }
    }
}
