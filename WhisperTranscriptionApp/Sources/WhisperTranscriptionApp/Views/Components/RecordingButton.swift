import SwiftUI

/// 物理的なトランスポートボタン風の録音/停止ボタン。
/// 待機中: 赤いRECドット、録音中: 停止スクエア + 呼吸するリング。
struct RecordingButton: View {
    let isRecording: Bool
    let action: () -> Void

    @State private var pulse = false

    var body: some View {
        Button(action: action) {
            ZStack {
                // 録音中の呼吸リング
                if isRecording {
                    Circle()
                        .stroke(Theme.rec.opacity(0.35), lineWidth: 3)
                        .frame(width: 104, height: 104)
                        .scaleEffect(pulse ? 1.16 : 1.0)
                        .opacity(pulse ? 0 : 1)
                }

                // 筐体の座金
                Circle()
                    .fill(Theme.panel)
                    .frame(width: 92, height: 92)
                    .overlay {
                        Circle().strokeBorder(Theme.stroke, lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 3)

                // ボタン本体
                Circle()
                    .fill(Theme.rec)
                    .frame(width: 72, height: 72)
                    .overlay {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [.white.opacity(0.22), .clear],
                                    startPoint: .top,
                                    endPoint: .center
                                )
                            )
                    }
                    .shadow(color: Theme.rec.opacity(isRecording ? 0.55 : 0.3), radius: isRecording ? 12 : 6)

                // グリフ
                if isRecording {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.white)
                        .frame(width: 24, height: 24)
                } else {
                    Circle()
                        .strokeBorder(.white.opacity(0.9), lineWidth: 2.5)
                        .frame(width: 30, height: 30)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: 110, height: 110)
        .onChange(of: isRecording) { _, recording in
            updatePulse(recording)
        }
        .onAppear {
            updatePulse(isRecording)
        }
        .accessibilityLabel(isRecording ? Text("Tap to Stop") : Text("Tap to Start Recording"))
    }

    private func updatePulse(_ recording: Bool) {
        if recording {
            pulse = false
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                pulse = true
            }
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                pulse = false
            }
        }
    }
}
