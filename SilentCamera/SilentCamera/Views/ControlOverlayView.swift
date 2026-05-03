import SwiftUI

struct ControlOverlayView: View {

    @Bindable var viewModel: CameraViewModel

    @State private var showSettings = false
    @State private var showGallery = false

    var body: some View {
        ZStack {
            VStack {
                TopBarView(viewModel: viewModel, showSettings: $showSettings)
                Spacer()
                ModeSelectorView(viewModel: viewModel)
                BottomControlsView(viewModel: viewModel, showGallery: $showGallery)
            }

            if viewModel.settings.showGrid {
                GridView()
            }

            if viewModel.isRecording {
                RecordingIndicatorView(viewModel: viewModel)
            }

            if viewModel.isCapturing && viewModel.settings.processingMode != .none {
                CaptureProgressOverlayView(viewModel: viewModel)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(viewModel: viewModel)
        }
        .fullScreenCover(isPresented: $showGallery) {
            GalleryView()
        }
    }
}
