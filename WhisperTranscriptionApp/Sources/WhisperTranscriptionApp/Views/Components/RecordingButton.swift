import SwiftUI

struct RecordingButton: View {
    @Binding var isRecording: Bool
    let action: () -> Void
    
    @State private var animationScale: CGFloat = 1.0
    
    var body: some View {
        Button(action: action) {
            ZStack {
                // Outer pulse ring
                if isRecording {
                    Circle()
                        .stroke(AppColors.recordingPulse.opacity(0.3), lineWidth: 4)
                        .frame(width: 100, height: 100)
                        .scaleEffect(animationScale)
                        .opacity(2 - animationScale)
                }
                
                // Main button
                Circle()
                    .fill(isRecording ? AppColors.recordingPulse : AppColors.accent)
                    .frame(width: 80, height: 80)
                    .shadow(color: (isRecording ? AppColors.recordingPulse : AppColors.accent).opacity(0.4), radius: 10, x: 0, y: 5)
                
                // Icon
                Group {
                    if isRecording {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(AppColors.textPrimary)
                            .frame(width: 24, height: 24)
                    } else {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundColor(AppColors.textOnAccent)
                    }
                }
            }
        }
        .onAppear {
            if isRecording {
                startPulseAnimation()
            }
        }
        .onChange(of: isRecording) { _, newValue in
            if newValue {
                startPulseAnimation()
            } else {
                stopPulseAnimation()
            }
        }
    }
    
    private func startPulseAnimation() {
        withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
            animationScale = 1.3
        }
    }
    
    private func stopPulseAnimation() {
        withAnimation(.easeInOut(duration: 0.2)) {
            animationScale = 1.0
        }
    }
}
