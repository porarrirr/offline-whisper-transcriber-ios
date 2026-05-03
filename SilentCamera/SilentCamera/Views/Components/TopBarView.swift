import SwiftUI

struct TopBarView: View {

    @Bindable var viewModel: CameraViewModel
    @Binding var showSettings: Bool

    var body: some View {
        HStack {
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }

            Spacer()

            if viewModel.settings.cameraMode == .photo {
                ProcessingModeButton(viewModel: viewModel)
            }

            Spacer()

            if viewModel.settings.cameraMode == .photo {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.settings.showGrid.toggle()
                    }
                } label: {
                    Image(systemName: viewModel.settings.showGrid ? "grid.circle.fill" : "grid.circle")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                }
            } else {
                Button {
                    viewModel.toggleTorch()
                } label: {
                    Image(systemName: viewModel.settings.torchEnabled ? "flashlight.on.fill" : "flashlight.off.fill")
                        .font(.title2)
                        .foregroundStyle(viewModel.settings.torchEnabled ? .yellow : .white)
                        .frame(width: 44, height: 44)
                }
            }

            Spacer()

            Button {
                cycleFlashMode()
            } label: {
                Image(systemName: viewModel.settings.flashMode.icon)
                    .font(.title2)
                    .foregroundStyle(viewModel.settings.flashMode == .on ? .yellow : .white)
                    .frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func cycleFlashMode() {
        let allModes = FlashMode.allCases
        guard let currentIndex = allModes.firstIndex(of: viewModel.settings.flashMode) else { return }
        let nextIndex = (currentIndex + 1) % allModes.count
        viewModel.settings.flashMode = allModes[nextIndex]
    }
}

struct ProcessingModeButton: View {

    @Bindable var viewModel: CameraViewModel

    var body: some View {
        Menu {
            ForEach(ProcessingMode.allCases) { mode in
                Button {
                    viewModel.settings.processingMode = mode
                } label: {
                    Label {
                        Text(mode.label)
                    } icon: {
                        Image(systemName: mode.icon)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: viewModel.settings.processingMode.icon)
                    .font(.caption)
                Text(viewModel.settings.processingMode.label)
                    .font(.caption2)
            }
            .foregroundStyle(.yellow)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.5))
            .clipShape(Capsule())
        }
    }
}
