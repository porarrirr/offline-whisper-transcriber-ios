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
            errorMessage = "音声の再生準備に失敗しました: \(error.localizedDescription)"
        }
    }
    
    func play() {
        guard let player = player else { return }
        player.play()
        isPlaying = true
        
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.currentTime = player.currentTime
            if !player.isPlaying {
                self?.stop()
            }
        }
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
        player?.currentTime = time
        currentTime = time
    }
}
