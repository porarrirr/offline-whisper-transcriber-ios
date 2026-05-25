import SwiftUI
import UIKit

struct SettingsView: View {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var modelManager = ModelManager.shared
    @StateObject private var logger = AppLogger.shared

    @State private var showModelDownload = false
    @State private var showDeleteConfirmation = false
    @State private var showLanguagePicker = false
    @State private var showLogCopiedConfirmation = false
    @FocusState private var isPromptEditorFocused: Bool

    var body: some View {
        Form {
            Section(header: Text("Model Settings")) {
                Picker("Model", selection: $settings.selectedTranscriptionModel) {
                    ForEach(TranscriptionModel.pickerOptions) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .onChange(of: settings.selectedTranscriptionModel) { _, newValue in
                    modelManager.switchModel(model: newValue)
                }

                HStack {
                    Image(systemName: modelManager.isModelReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundColor(modelManager.isModelReady ? AppColors.accent : AppColors.warning)
                    Text(modelStatusText)
                    Spacer()
                    if let size = modelManager.getModelSize() {
                        Text(size)
                            .foregroundColor(.secondary)
                    }
                }

                if modelManager.isDownloading {
                    ProgressView(value: modelManager.downloadProgress)
                        .tint(AppColors.accent)
                    if settings.usesWhisperBackend {
                        Button(action: { modelManager.cancelDownload() }) {
                            Label("Cancel Download", systemImage: "xmark.circle.fill")
                                .foregroundColor(.red)
                        }
                    }
                } else if !modelManager.isModelReady && settings.usesWhisperBackend {
                    Button(action: { modelManager.downloadModel() }) {
                        Label(
                            "Download \(settings.selectedTranscriptionModel.approximateSize)",
                            systemImage: "arrow.down.circle.fill"
                        )
                    }
                }

                if let error = modelManager.downloadError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                if settings.usesWhisperBackend {
                    Button(action: { showDeleteConfirmation = true }) {
                        Label("Delete Model", systemImage: "trash.fill")
                            .foregroundColor(.red)
                    }
                }
            }

            if settings.usesWhisperBackend {
                Section(header: Text("Language Settings")) {
                    Button(action: { showLanguagePicker = true }) {
                        HStack {
                            Text("Transcription Language")
                                .foregroundColor(.primary)
                            Spacer()
                            if let language = AppSettings.supportedLanguages.first(where: { $0.code == settings.selectedLanguage }) {
                                Text(LocalizedStringKey(language.name))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    Toggle(isOn: $settings.translateToEnglish) {
                        VStack(alignment: .leading) {
                            Text("Translate to English")
                            Text("Translate transcription results to English")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .tint(AppColors.accent)
                }

                Section(header: Text("Prompt"), footer: Text("Example: \"Hello, today we will talk about technology.\"")) {
                    TextEditor(text: $settings.promptText)
                        .frame(minHeight: 80)
                        .focused($isPromptEditorFocused)
                }
            }

            Section(header: Text("Advanced Settings")) {
                if settings.usesWhisperBackend {
                    Toggle(isOn: $settings.useFlashAttention) {
                        VStack(alignment: .leading) {
                            Text("Flash Attention")
                            Text("Optimize processing speed and memory usage")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .tint(AppColors.accent)

                    Toggle(isOn: $settings.useVAD) {
                        VStack(alignment: .leading) {
                            Text("Skip Silence (VAD)")
                            Text("Automatically skip portions with no audio")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .tint(AppColors.accent)

                    if settings.useVAD {
                        HStack {
                            Image(systemName: modelManager.isVADModelReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .foregroundColor(modelManager.isVADModelReady ? AppColors.accent : AppColors.warning)
                            Text(modelManager.isVADModelReady ? LocalizedStringKey("VAD Model Ready") : LocalizedStringKey("Please download VAD model"))
                        }

                        if modelManager.isVADDownloading {
                            HStack {
                                ProgressView(value: modelManager.vadDownloadProgress)
                                    .tint(AppColors.accent)
                                Button(action: { modelManager.cancelVADDownload() }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.red)
                                }
                            }
                        } else if !modelManager.isVADModelReady {
                            Button(action: { modelManager.downloadVADModel() }) {
                                Label("Download VAD Model", systemImage: "arrow.down.circle.fill")
                            }
                        } else {
                            Button(action: { modelManager.deleteVADModel() }) {
                                Label("Delete VAD Model", systemImage: "trash")
                                    .foregroundColor(.red)
                            }
                        }

                        if let error = modelManager.vadDownloadError {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                }

                if settings.usesWhisperBackend {
                    Toggle(isOn: $settings.includeTimestamps) {
                        VStack(alignment: .leading) {
                            Text("Include Timestamps")
                            Text("Include timestamps in the transcription result")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .tint(AppColors.accent)
                }

                Toggle(isOn: $settings.keepScreenOn) {
                    VStack(alignment: .leading) {
                        Text("Keep Screen On")
                        Text("Keep the screen on during transcription")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .tint(AppColors.accent)

                Toggle(isOn: $settings.autoDeleteRecordings) {
                    VStack(alignment: .leading) {
                        Text("Auto-Delete Recordings")
                        Text("Automatically delete recording files after 7 days")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .tint(AppColors.accent)
            }

            Section(header: Text("Logs")) {
                if logger.entries.isEmpty {
                    Text("No logs yet")
                        .foregroundColor(.secondary)
                } else {
                    NavigationLink("View Logs") {
                        ScrollView {
                            Text(logger.latestPreview)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .textSelection(.enabled)
                        }
                        .navigationTitle("Logs")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarTrailing) {
                                Button("Copy") {
                                    UIPasteboard.general.string = logger.exportText
                                    showLogCopiedConfirmation = true
                                }
                            }
                            ToolbarItem(placement: .navigationBarTrailing) {
                                Button(role: .destructive, action: { logger.clear() }) {
                                    Image(systemName: "trash")
                                }
                            }
                        }
                    }
                }
            }

            Section(header: Text("Support & Policies"), footer: LegalDisclaimerFootnote()) {
                Link("About App", destination: AppLegalURLs.marketing)
                Link("Support", destination: AppLegalURLs.support)
                Link("Privacy Policy", destination: AppLegalURLs.privacyPolicy)
                Link("Disclaimer & Terms", destination: AppLegalURLs.disclaimer)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            modelManager.ensureModelAvailability()
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    isPromptEditorFocused = false
                }
            }
        }
        .sheet(isPresented: $showModelDownload) {
            ModelDownloadView(isPresentedAsSheet: true)
        }
        .alert("Delete Model", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                modelManager.deleteCurrentModel()
            }
        } message: {
            Text("Are you sure you want to delete the current model?")
        }
        .alert("Logs Copied", isPresented: $showLogCopiedConfirmation) {
            Button("OK", role: .cancel) {}
        }
        .sheet(isPresented: $showLanguagePicker) {
            LanguagePickerView(selectedLanguage: $settings.selectedLanguage, isPresented: $showLanguagePicker)
        }
    }

    private var modelStatusText: LocalizedStringKey {
        if modelManager.isModelReady {
            return LocalizedStringKey("Model Ready")
        }
        if settings.usesAppleSpeechBackend {
            return LocalizedStringKey("Preparing speech model...")
        }
        return LocalizedStringKey("Please download model")
    }
}

struct LanguagePickerView: View {
    @Binding var selectedLanguage: String
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            List {
                ForEach(AppSettings.supportedLanguages, id: \.code) { language in
                    Button(action: {
                        selectedLanguage = language.code
                        isPresented = false
                    }) {
                        HStack {
                            Text(LocalizedStringKey(language.name))
                                .foregroundColor(.primary)
                            Spacer()
                            if selectedLanguage == language.code {
                                Image(systemName: "checkmark")
                                    .foregroundColor(AppColors.accent)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Select Language")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        isPresented = false
                    }
                }
            }
        }
    }
}
