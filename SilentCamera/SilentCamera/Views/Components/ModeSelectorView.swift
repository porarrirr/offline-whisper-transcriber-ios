import SwiftUI

struct ModeSelectorView: View {

    @Bindable var viewModel: CameraViewModel

    var body: some View {
        HStack(spacing: 24) {
            ForEach(CameraMode.allCases) { mode in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.switchCameraMode(mode)
                    }
                } label: {
                    Text(mode.label)
                        .font(.subheadline)
                        .fontWeight(viewModel.settings.cameraMode == mode ? .bold : .regular)
                        .foregroundStyle(viewModel.settings.cameraMode == mode ? .yellow : .white.opacity(0.7))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(
                            viewModel.settings.cameraMode == mode
                                ? Capsule().fill(.white.opacity(0.15))
                                : nil
                        )
                }
            }
        }
        .padding(.bottom, 8)
    }
}
