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
            Theme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 18) {
                    header

                    stateContent

                    LegalDisclaimerFootnote(text: AppDisclaimer.onboardingFootnote)
                        .padding(.top, 10)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, 28)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
        }
        .onAppear {
            viewModel.checkAvailability()
        }
    }

    /// アプリ名を刻んだLCDヒーロー
    private var header: some View {
        VStack(spacing: 16) {
            WelcomeWaveformMark()
                .frame(height: 56)

            VStack(spacing: 8) {
                Text("Whisper Transcriber")
                    .font(Theme.mono(22, weight: .semibold))
                    .foregroundStyle(Theme.displayText)

                Text("High-Accuracy Offline AI Transcription")
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.displayTextDim)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(Theme.displayAmber)
                    .frame(width: 6, height: 6)
                Text("OFFLINE")
                    .font(Theme.mono(10, weight: .semibold))
                    .tracking(1.8)
                    .foregroundStyle(Theme.displayAmber)
            }
        }
        .displayPanel(padding: 24)
    }

    @ViewBuilder
    private var stateContent: some View {
        if viewModel.isComplete {
            VStack(spacing: 18) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundColor(Theme.amber)

                Text("Ready!")
                    .font(Theme.mono(16, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)

                if isPresentedAsSheet {
                    Button(action: {
                        dismiss()
                    }) {
                        Text("Close")
                    }
                    .buttonStyle(.recorderProminent)
                }
            }
            .recorderPanel(padding: 22)
        } else if viewModel.isDownloading {
            VStack(spacing: 16) {
                HStack {
                    TechLabel(text: "Download Model", color: Theme.amber)

                    Spacer()

                    Text("\(Int(viewModel.progress * 100))%")
                        .font(Theme.mono(24, weight: .semibold))
                        .foregroundColor(Theme.amber)
                }

                ProgressBar(progress: viewModel.progress)
                    .frame(height: 6)

                HStack {
                    Text(LocalizedStringKey(viewModel.statusText))
                        .font(Theme.sans(13))
                        .foregroundColor(Theme.textSecondary)

                    Spacer()

                    Button(action: {
                        ModelManager.shared.cancelDownload()
                        viewModel.isDownloading = false
                    }) {
                        Text("Cancel")
                    }
                    .buttonStyle(.recorderQuietDestructive)
                }
            }
            .recorderPanel()
        } else {
            VStack(spacing: 14) {
                if !viewModel.isModelAvailable {
                    modelPickerCard
                }

                if let error = viewModel.errorMessage {
                    WarningStrip(message: error)
                }

                if settings.usesWhisperBackend {
                    Button(action: {
                        viewModel.startDownload()
                    }) {
                        Label(viewModel.isModelAvailable ? LocalizedStringKey("Update Model") : LocalizedStringKey("Download Model"), systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.recorderProminent)
                } else if settings.usesAppleSpeechBackend {
                    Button(action: {
                        viewModel.startDownload()
                    }) {
                        Label("Prepare Speech Model", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.recorderProminent)
                }

                if settings.usesWhisperBackend {
                    Text("Will download \(settings.selectedTranscriptionModel.approximateSize) and the Core ML encoder.\nWi-Fi connection is recommended.")
                        .font(Theme.sans(12))
                        .foregroundColor(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var modelPickerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            TechLabel(text: "Select Model")

            Picker("Model", selection: $settings.selectedTranscriptionModel) {
                ForEach(TranscriptionModel.pickerOptions(selectedModel: settings.selectedTranscriptionModel)) { model in
                    Text(model.displayName).tag(model)
                }
            }
            .pickerStyle(.menu)
            .tint(Theme.amber)
            .onChange(of: settings.selectedTranscriptionModel) { _, newValue in
                ModelManager.shared.switchModel(model: newValue)
                viewModel.checkAvailability()
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.amber)
                Text(settings.selectedTranscriptionModel.approximateSize)
                    .font(Theme.sans(12))
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
        .recorderPanel(padding: 14)
    }
}

/// オンボーディング用の静的な波形マーク
private struct WelcomeWaveformMark: View {
    private let heights: [CGFloat] = [0.25, 0.5, 0.36, 0.72, 1.0, 0.62, 0.85, 0.44, 0.66, 0.3, 0.52, 0.22, 0.4, 0.14, 0.28]

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 4) {
                ForEach(heights.indices, id: \.self) { index in
                    Capsule()
                        .fill(Theme.displayAmber)
                        .frame(
                            width: (geometry.size.width - CGFloat(heights.count - 1) * 4) / CGFloat(heights.count),
                            height: geometry.size.height * heights[index]
                        )
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .accessibilityHidden(true)
    }
}
