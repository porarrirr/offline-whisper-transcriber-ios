import SwiftUI

struct CameraView: View {

    @State private var viewModel = CameraViewModel()
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var showOnboarding = false

    var body: some View {
        ZStack {
            switch viewModel.authorizationStatus {
            case .authorized:
                cameraContent

            case .denied, .restricted:
                permissionDeniedView

            default:
                Color.black.ignoresSafeArea()
                    .onAppear {
                        Task {
                            await viewModel.requestAuthorization()
                        }
                    }
            }
        }
        .alert("エラー", isPresented: $viewModel.showError) {
            Button("OK") {}
        } message: {
            VStack {
                Text(viewModel.errorMessage)
                if let suggestion = viewModel.errorRecoverySuggestion {
                    Text(suggestion)
                        .font(.caption)
                }
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(viewModel.isRecording)
        .onAppear {
            if !hasSeenOnboarding {
                showOnboarding = true
            }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(hasSeenOnboarding: $hasSeenOnboarding)
        }
    }

    private var cameraContent: some View {
        ZStack {
            CameraPreviewView(session: viewModel.session)
                .ignoresSafeArea()
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            let newFactor = viewModel.zoomFactor * value.magnification
                            viewModel.setZoom(newFactor)
                        }
                )

            ControlOverlayView(viewModel: viewModel)
        }
    }

    private var permissionDeniedView: some View {
        VStack(spacing: 24) {
            Image(systemName: "camera.fill")
                .font(.system(size: 60))
                .foregroundStyle(.gray)

            Text("カメラへのアクセスが必要です")
                .font(.title2)
                .fontWeight(.semibold)

            Text("設定からカメラへのアクセスを許可してください")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("設定を開く")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.blue)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 40)
        }
        .padding()
        .background(.black)
        .ignoresSafeArea()
    }
}

struct OnboardingView: View {
    @Binding var hasSeenOnboarding: Bool
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 30) {
            Spacer()
            
            Image(systemName: "camera.fill")
                .font(.system(size: 80))
                .foregroundStyle(.yellow)
            
            Text("無音カメラへようこそ")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            VStack(spacing: 16) {
                OnboardingRow(icon: "speaker.slash.fill", title: "無音撮影", description: "シャッター音なしで写真・動画を撮影")
                OnboardingRow(icon: "wand.and.stars", title: "高度な画像処理", description: "スタック合成・HDR・ノイズ除去")
                OnboardingRow(icon: "photo.on.rectangle", title: "ギャラリー", description: "撮影した写真・動画を管理")
            }
            .padding(.horizontal, 40)
            
            Spacer()
            
            Button {
                hasSeenOnboarding = true
                dismiss()
            } label: {
                Text("始める")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.yellow)
                    .foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 40)
        }
        .background(.black)
        .preferredColorScheme(.dark)
    }
}

struct OnboardingRow: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.yellow)
                .frame(width: 30)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
