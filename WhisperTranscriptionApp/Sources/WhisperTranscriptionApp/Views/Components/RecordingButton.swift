import SwiftUI

/// ホーム画面の主操作として使う、フラットな録音/停止ボタン。
struct RecordingButton: View {
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if isRecording {
                    Image(systemName: "stop.fill")
                } else {
                    Image(systemName: "mic.fill")
                }

                Text(isRecording ? LocalizedStringKey("Stop Recording") : LocalizedStringKey("Start Recording"))
            }
            .font(Theme.sans(18, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(Theme.rec)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isRecording ? Text("Tap to Stop") : Text("Tap to Start Recording"))
    }
}
