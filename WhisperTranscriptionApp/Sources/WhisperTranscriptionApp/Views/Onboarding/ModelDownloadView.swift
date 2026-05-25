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
                VStack(spacing: 22) {
                    header
                    stateContent
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 32)

                LegalDisclaimerFootnote(text: AppDisclaimer.onboardingFootnote)
                    .padding(.horizontal, 4)
            }
            .scrollIndicators(.hidden)
        }
        .onAppear {
            viewModel.checkAvailability()
        }
    }

    private var header: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(AppColors.accent.opacity(0.2))
                    .frame(width: 104, height: 104)

                Image(systemName: "waveform.circle.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)
                    .foregroundColor(AppColors.accent)
            }

            VStack(spacing: 12) {
                Text("Whisper Transcriber")
                    .font(AppFonts.title)
                    .foregroundColor(AppColors.textPrimary)

                Text("High-Accuracy Offline AI Transcription")
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

                Text("Ready!")
                    .font(AppFonts.headline)
                    .foregroundColor(AppColors.textPrimary)

                if isPresentedAsSheet {
                    Button(action: {
                        dismiss()
                    }) {
                        Text("Close")
                            .font(AppFonts.button)
                            .foregroundColor(AppColors.textOnAccent)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(AppColors.accent)
                            .cornerRadius(16)
                    }
                }
            }
        } else if viewModel.isDownloading {
            VStack(spacing: 20) {
                ProgressBar(progress: viewModel.progress)
                    .frame(height: 8)

                HStack {
                    Text(LocalizedStringKey(viewModel.statusText))
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
                    Text("Cancel")
                        .font(AppFonts.callout)
                        .foregroundColor(AppColors.warning)
                }
            }
        } else {
            VStack(spacing: 16) {
                if !viewModel.isModelAvailable && settings.usesWhisperBackend {
                    VStack(spacing: 12) {
                        Text("Select Model")
                            .font(AppFonts.headline)
                            .foregroundColor(AppColors.textPrimary)

                        Picker("Model", selection: $settings.selectedTranscriptionModel) {
                            ForEach(TranscriptionModel.pickerOptions) { model in
                                Text(model.displayName).tag(model)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: settings.selectedTranscriptionModel) { _, newValue in
                            ModelManager.shared.switchModel(model: newValue)
                            viewModel.checkAvailability()
                        }

                        HStack {
                            Image(systemName: "info.circle.fill")
                                .foregroundColor(AppColors.accent)
                            Text(settings.selectedTranscriptionModel.approximateSize)
                                .font(AppFonts.caption)
                                .foregroundColor(AppColors.textSecondary)
                            Spacer()
                        }
                    }
                    .padding()
                    .background(AppColors.cardBackground)
                    .cornerRadius(16)
                } else if settings.usesAppleSpeechBackend {
                    VStack(spacing: 12) {
                        Text("超高速な基本モデル")
                            .font(AppFonts.headline)
                            .foregroundColor(AppColors.textPrimary)

                        ProgressView()
                            .tint(AppColors.accent)

                        Text("Preparing speech model...")
                            .font(AppFonts.caption)
                            .foregroundColor(AppColors.textSecondary)
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

                if settings.usesWhisperBackend {
                    Button(action: {
                        viewModel.startDownload()
                    }) {
                        HStack {
                            Image(systemName: "arrow.down.circle.fill")
                            Text(viewModel.isModelAvailable ? LocalizedStringKey("Update Model") : LocalizedStringKey("Download Model"))
                        }
                        .font(AppFonts.button)
                        .foregroundColor(AppColors.textOnAccent)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(AppColors.accent)
                        .cornerRadius(16)
                    }
                    .padding(.top, 8)
                }

                if settings.usesWhisperBackend {
                    Text("Will download \(settings.selectedTranscriptionModel.approximateSize) for the first time.\nWi-Fi connection is recommended.")
                        .font(AppFonts.caption)
                        .foregroundColor(AppColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
