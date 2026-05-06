import SwiftUI

struct ModelDownloadView: View {
    @StateObject private var viewModel = DownloadViewModel()
    @StateObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss

    var isPresentedAsSheet: Bool

    init(isPresentedAsSheet: Bool = false) {
        self.isPresentedAsSheet = isPresentedAsSheet
    }

    var body: some View {
        ZStack {
            AppColors.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 28) {
                    header
                    stateContent
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, viewModel.isDownloading ? 32 : 150)
            }
            .scrollIndicators(.hidden)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !viewModel.isDownloading {
                bottomAction
            }
        }
        .onAppear {
            viewModel.checkAvailability()
        }
    }

    private var header: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(AppColors.accent.opacity(0.2))
                    .frame(width: 112, height: 112)

                Image(systemName: "waveform.circle.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 68, height: 68)
                    .foregroundColor(AppColors.accent)
            }

            VStack(spacing: 12) {
                Text("Whisper文字起こし")
                    .font(AppFonts.title)
                    .foregroundColor(AppColors.textPrimary)

                Text("AIによる高精度音声認識")
                    .font(AppFonts.body)
                    .foregroundColor(AppColors.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        if viewModel.isComplete {
            VStack(spacing: 20) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(AppColors.accent)

                Text("準備完了！")
                    .font(AppFonts.headline)
                    .foregroundColor(AppColors.textPrimary)
            }
        } else if viewModel.isDownloading {
            VStack(spacing: 20) {
                ProgressBar(progress: viewModel.progress)
                    .frame(height: 8)

                HStack {
                    Text(viewModel.statusText)
                        .font(AppFonts.callout)
                        .foregroundColor(AppColors.textSecondary)

                    Spacer()

                    Text("\(Int(viewModel.progress * 100))%")
                        .font(AppFonts.callout)
                        .foregroundColor(AppColors.accent)
                }

                Button(action: {
                    ModelManager.shared.cancelDownload()
                    viewModel.isDownloading = false
                }) {
                    Text("キャンセル")
                        .font(AppFonts.callout)
                        .foregroundColor(AppColors.warning)
                }
            }
        } else {
            VStack(spacing: 16) {
                if !viewModel.isModelAvailable {
                    VStack(spacing: 12) {
                        Text("モデルサイズを選択")
                            .font(AppFonts.headline)
                            .foregroundColor(AppColors.textPrimary)

                        Picker("モデルサイズ", selection: $settings.selectedModelSize) {
                            ForEach(AppSettings.ModelSize.allCases) { size in
                                Text(size.displayName).tag(size)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: settings.selectedModelSize) { _, newValue in
                            ModelManager.shared.switchModel(size: newValue)
                            viewModel.checkAvailability()
                        }

                        HStack {
                            Image(systemName: "info.circle.fill")
                                .foregroundColor(AppColors.accent)
                            Text(settings.selectedModelSize.approximateSize)
                                .font(AppFonts.caption)
                                .foregroundColor(AppColors.textSecondary)
                            Spacer()
                        }
                    }
                    .padding()
                    .background(AppColors.cardBackground)
                    .cornerRadius(16)
                }

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(AppFonts.callout)
                        .foregroundColor(AppColors.warning)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    @ViewBuilder
    private var bottomAction: some View {
        VStack(spacing: 10) {
            if viewModel.isComplete {
                if isPresentedAsSheet {
                    Button(action: {
                        dismiss()
                    }) {
                        Text("閉じる")
                            .font(AppFonts.button)
                            .foregroundColor(AppColors.textOnAccent)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(AppColors.accent)
                            .cornerRadius(16)
                    }
                }
            } else {
                Button(action: {
                    viewModel.startDownload()
                }) {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                        Text(viewModel.isModelAvailable ? "モデルを更新" : "モデルをダウンロード")
                    }
                    .font(AppFonts.button)
                    .foregroundColor(AppColors.textOnAccent)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(AppColors.accent)
                    .cornerRadius(16)
                }

                Text("初回のみ\(settings.selectedModelSize.approximateSize)のデータをダウンロードします\nWi-Fi環境での実行を推奨します")
                    .font(AppFonts.caption)
                    .foregroundColor(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(AppColors.background)
    }
}
