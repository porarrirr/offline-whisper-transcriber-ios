import SwiftUI

struct CaptureProgressOverlayView: View {

    @Bindable var viewModel: CameraViewModel

    var body: some View {
        VStack {
            Spacer()

            VStack(spacing: 12) {
                ProgressView(value: viewModel.captureProgress) {
                    HStack {
                        Image(systemName: viewModel.settings.processingMode.icon)
                        Text("\(viewModel.settings.processingMode.label)処理中...")
                            .font(.caption)
                    }
                    .foregroundStyle(.white)
                }
                .tint(.yellow)

                Text("\(Int(viewModel.captureProgress * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding()
            .background(.black.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 40)
            .padding(.bottom, 120)
        }
    }
}
