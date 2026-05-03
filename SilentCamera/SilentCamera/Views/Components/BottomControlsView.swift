import SwiftUI

struct BottomControlsView: View {

    @Bindable var viewModel: CameraViewModel
    @Binding var showGallery: Bool

    var body: some View {
        VStack(spacing: 16) {
            ZoomIndicatorView(viewModel: viewModel)

            HStack(alignment: .center) {
                Button {
                    showGallery = true
                } label: {
                    if let image = viewModel.lastCaptureImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 50, height: 50)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(.white, lineWidth: 2)
                            )
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.white.opacity(0.2))
                            .frame(width: 50, height: 50)
                            .overlay(
                                Image(systemName: "photo.on.rectangle")
                                    .foregroundStyle(.white)
                            )
                    }
                }

                Spacer()

                if viewModel.settings.cameraMode == .photo {
                    PhotoCaptureButton(viewModel: viewModel)
                } else {
                    VideoRecordButton(viewModel: viewModel)
                }

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        viewModel.switchCamera()
                    }
                } label: {
                    Image(systemName: "camera.rotate.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 50, height: 50)
                }
                .disabled(viewModel.isRecording)
                .opacity(viewModel.isRecording ? 0.5 : 1.0)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 16)
        }
    }
}

struct ZoomIndicatorView: View {

    @Bindable var viewModel: CameraViewModel

    var body: some View {
        Group {
            if viewModel.zoomFactor > 1.0 {
                Text(String(format: "%.1fx", viewModel.zoomFactor))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.5))
                    .clipShape(Capsule())
            }
        }
    }
}

struct PhotoCaptureButton: View {

    @Bindable var viewModel: CameraViewModel

    var body: some View {
        Button {
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
            viewModel.capturePhoto()
        } label: {
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: 4)
                    .frame(width: 72, height: 72)

                if viewModel.settings.processingMode != .none && viewModel.isCapturing {
                    Circle()
                        .trim(from: 0, to: CGFloat(viewModel.captureProgress))
                        .stroke(.yellow, lineWidth: 4)
                        .frame(width: 72, height: 72)
                        .rotationEffect(.degrees(-90))
                }

                Circle()
                    .fill(viewModel.isCapturing ? .gray : .white)
                    .frame(width: 60, height: 60)
                    .scaleEffect(viewModel.isCapturing ? 0.85 : 1.0)
            }
        }
        .disabled(viewModel.isCapturing)
        .animation(.easeInOut(duration: 0.15), value: viewModel.isCapturing)
    }
}

struct VideoRecordButton: View {

    @Bindable var viewModel: CameraViewModel

    var body: some View {
        Button {
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
            if viewModel.isRecording {
                viewModel.stopRecording()
            } else {
                viewModel.startRecording()
            }
        } label: {
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: 4)
                    .frame(width: 72, height: 72)

                if viewModel.isRecording {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.red)
                        .frame(width: 28, height: 28)
                } else {
                    Circle()
                        .fill(.red)
                        .frame(width: 58, height: 58)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.isRecording)
    }
}
