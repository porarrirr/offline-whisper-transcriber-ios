import SwiftUI

struct RecordingIndicatorView: View {

    @Bindable var viewModel: CameraViewModel

    var body: some View {
        VStack {
            HStack(spacing: 8) {
                Circle()
                    .fill(.red)
                    .frame(width: 10, height: 10)
                    .opacity(1.0)
                    .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: viewModel.isRecording)

                Text(viewModel.recordingDurationText)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .monospacedDigit()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.black.opacity(0.6))
            .clipShape(Capsule())

            Spacer()
        }
        .padding(.top, 60)
    }
}
