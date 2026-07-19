import SwiftUI
import UIKit

struct SettingsView: View {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var modelManager = ModelManager.shared
    @StateObject private var logger = AppLogger.shared
    @StateObject private var runtimeStatus = WhisperRuntimeStatus.shared

    @State private var showModelDownload = false
    @State private var showDeleteConfirmation = false
    @State private var showLanguagePicker = false
    @State private var showLogCopiedConfirmation = false
    @FocusState private var isPromptEditorFocused: Bool

    var body: some View {
        Form {
            Section {
                modelSelectionMenu

                if modelManager.isTranscriptionInProgress {
                    Label("Model changes are disabled while transcription is running.", systemImage: "lock.fill")
                        .font(Theme.sans(12))
                        .foregroundColor(Theme.textSecondary)
                }

                HStack {
                    LEDDot(
                        isOn: true,
                        onColor: modelManager.isModelReady ? Theme.amber : Theme.rec
                    )
                    Text(modelStatusText)
                    Spacer()
                    if let size = modelManager.getModelSize() {
                        Text(size)
                            .font(Theme.mono(13))
                            .foregroundColor(Theme.textSecondary)
                    }
                }

                if let accelerationWarning = modelManager.whisperAccelerationWarningMessage() {
                    Label(accelerationWarning, systemImage: "speedometer")
                        .font(Theme.sans(12))
                        .foregroundColor(Theme.textSecondary)
                    if !modelManager.isDownloading && modelManager.canDownloadCoreMLEncoder {
                        Button(action: { modelManager.downloadModel() }) {
                            Label("Download Core ML Encoder", systemImage: "arrow.down.circle.fill")
                                .foregroundColor(Theme.amber)
                        }
                    }
                }

                if settings.usesWhisperBackend {
                    Label(runtimeStatus.accelerationMode.description, systemImage: "cpu")
                        .font(Theme.sans(12))
                        .foregroundColor(Theme.textSecondary)
                        .accessibilityIdentifier("whisperAccelerationStatus")
                }

                if settings.usesAppleSpeechBackend {
                    SpeechAssetStatusCard(modelManager: modelManager)
                } else if modelManager.isDownloading {
                    ProgressBar(progress: modelManager.downloadProgress)
                        .frame(height: 6)
                    Text(LocalizedStringKey(modelManager.downloadStatusText))
                        .font(Theme.sans(12))
                        .foregroundColor(Theme.textSecondary)
                    Button(action: { modelManager.cancelDownload() }) {
                        Label("Cancel Download", systemImage: "xmark.circle.fill")
                            .foregroundColor(Theme.rec)
                    }
                } else if !modelManager.isModelReady && settings.usesWhisperBackend {
                    Button(action: { modelManager.downloadModel() }) {
                        Label(
                            "Download \(settings.selectedTranscriptionModel.approximateSize)",
                            systemImage: "arrow.down.circle.fill"
                        )
                        .foregroundColor(Theme.amber)
                    }
                }

                if let error = modelManager.downloadError {
                    if !settings.usesAppleSpeechBackend {
                        Text(error)
                            .font(Theme.sans(12))
                            .foregroundColor(Theme.rec)
                    }
                }

                if settings.usesWhisperBackend {
                    Button(action: { showDeleteConfirmation = true }) {
                        Label("Delete Model", systemImage: "trash.fill")
                            .foregroundColor(Theme.rec)
                    }
                    .disabled(modelManager.isTranscriptionInProgress)

                    Button(action: { showModelDownload = true }) {
                        Label("Add or Manage Whisper Models", systemImage: "externaldrive.badge.plus")
                            .foregroundColor(Theme.amber)
                    }
                }

                NavigationLink {
                    SpeechAssetManagementView(modelManager: modelManager)
                } label: {
                    Label("Manage iOS SpeechTranscriber Models", systemImage: "externaldrive.badge.plus")
                        .foregroundColor(Theme.amber)
                }
                .disabled(modelManager.isTranscriptionInProgress)

                if settings.usesWhisperBackend {
                    Button(action: { showLanguagePicker = true }) {
                        HStack {
                            Text("Transcription Language")
                                .foregroundColor(Theme.textPrimary)
                            Spacer()
                            if let language = AppSettings.supportedLanguages.first(where: { $0.code == settings.selectedLanguage }) {
                                Text(LocalizedStringKey(language.name))
                                    .foregroundColor(Theme.textSecondary)
                            }
                        }
                    }

                    Toggle(isOn: $settings.translateToEnglish) {
                        VStack(alignment: .leading) {
                            Text("Translate to English")
                            Text("Translate transcription results to English")
                                .font(Theme.sans(12))
                                .foregroundColor(Theme.textSecondary)
                        }
                    }
                    .tint(Theme.amberFill)
                }
            } header: {
                TechLabel(text: "Transcription")
            }
            .listRowBackground(Theme.panel)

            if settings.usesWhisperBackend {
                Section {
                    TextEditor(text: $settings.promptText)
                        .frame(minHeight: 80)
                        .focused($isPromptEditorFocused)
                } header: {
                    TechLabel(text: "Prompt")
                } footer: {
                    Text("Example: \"Hello, today we will talk about technology.\"")
                }
                .listRowBackground(Theme.panel)
            }

            if settings.usesWhisperBackend {
                Section {
                    Toggle(isOn: $settings.useFlashAttention) {
                        VStack(alignment: .leading) {
                            Text("Flash Attention")
                            Text("Optimize processing speed and memory usage")
                                .font(Theme.sans(12))
                                .foregroundColor(Theme.textSecondary)
                        }
                    }
                    .tint(Theme.amberFill)
                    .disabled(modelManager.isTranscriptionInProgress)

                    Toggle(isOn: $settings.useVAD) {
                        VStack(alignment: .leading) {
                            Text("Skip Silence (VAD)")
                            Text("Automatically skip portions with no audio")
                                .font(Theme.sans(12))
                                .foregroundColor(Theme.textSecondary)
                        }
                    }
                    .tint(Theme.amberFill)
                    .disabled(modelManager.isTranscriptionInProgress)

                    if settings.useVAD {
                        HStack {
                            LEDDot(
                                isOn: true,
                                onColor: modelManager.isVADModelReady ? Theme.amber : Theme.rec
                            )
                            Text(modelManager.isVADModelReady ? LocalizedStringKey("VAD Model Ready") : LocalizedStringKey("Please download VAD model"))
                        }

                        if modelManager.isVADDownloading {
                            HStack {
                                ProgressBar(progress: modelManager.vadDownloadProgress)
                                    .frame(height: 6)
                                Button(action: { modelManager.cancelVADDownload() }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(Theme.rec)
                                }
                            }
                        } else if !modelManager.isVADModelReady {
                            Button(action: { modelManager.downloadVADModel() }) {
                                Label("Download VAD Model", systemImage: "arrow.down.circle.fill")
                                    .foregroundColor(Theme.amber)
                            }
                        } else {
                            Button(action: { modelManager.deleteVADModel() }) {
                                Label("Delete VAD Model", systemImage: "trash")
                                    .foregroundColor(Theme.rec)
                            }
                            .disabled(modelManager.isTranscriptionInProgress)
                        }

                        if let error = modelManager.vadDownloadError {
                            Text(error)
                                .font(Theme.sans(12))
                                .foregroundColor(Theme.rec)
                        }
                    }
                    Toggle(isOn: $settings.includeTimestamps) {
                        VStack(alignment: .leading) {
                            Text("Include Timestamps")
                            Text("Include timestamps in the transcription result")
                                .font(Theme.sans(12))
                                .foregroundColor(Theme.textSecondary)
                        }
                    }
                    .tint(Theme.amberFill)
                } header: {
                    TechLabel(text: "Processing")
                }
                .listRowBackground(Theme.panel)
            }

            Section {
                Toggle(isOn: $settings.keepScreenOn) {
                    VStack(alignment: .leading) {
                        Text("Keep Screen On")
                        Text("Keep the screen on during transcription")
                            .font(Theme.sans(12))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
                .tint(Theme.amberFill)

                Toggle(isOn: $settings.autoDeleteRecordings) {
                    VStack(alignment: .leading) {
                        Text("Auto-Delete Recordings")
                        Text("Automatically delete recording files after 7 days")
                            .font(Theme.sans(12))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
                .tint(Theme.amberFill)
            } header: {
                TechLabel(text: "Recording & Storage")
            }
            .listRowBackground(Theme.panel)

            Section {
                Picker("Theme", selection: $settings.appAppearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(LocalizedStringKey(appearance.displayName)).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                TechLabel(text: "Appearance")
            }
            .listRowBackground(Theme.panel)

            Section {
                Link("About App", destination: AppLegalURLs.marketing)
                Link("Support", destination: AppLegalURLs.support)
                Link("Privacy Policy", destination: AppLegalURLs.privacyPolicy)
                Link("Disclaimer & Terms", destination: AppLegalURLs.disclaimer)

                if !logger.entries.isEmpty {
                    NavigationLink("View Logs") {
                        ScrollView {
                            Text(logger.latestPreview)
                                .font(Theme.mono(11))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .textSelection(.enabled)
                        }
                        .background(Theme.background)
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
            } header: {
                TechLabel(text: "Support & Policies")
            } footer: {
                LegalDisclaimerFootnote()
            }
            .listRowBackground(Theme.panel)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .tint(Theme.amber)
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
            ModelDownloadView(isPresentedAsSheet: true, includesSpeechModels: false)
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

    private var modelSelectionMenu: some View {
        Menu {
            if modelPickerOptions.isEmpty {
                Text("No Prepared Models")
            } else {
                ForEach(modelPickerOptions) { model in
                    Button {
                        settings.selectedTranscriptionModel = model
                        modelManager.switchModel(model: model)
                    } label: {
                        if model == settings.selectedTranscriptionModel {
                            Label(model.displayName, systemImage: "checkmark")
                        } else {
                            Text(model.displayName)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 12) {
                Text("Model")
                    .foregroundColor(Theme.textPrimary)

                Spacer(minLength: 8)

                Text(settings.selectedTranscriptionModel.displayName)
                    .foregroundColor(Theme.amber)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.amber)
            }
            .contentShape(Rectangle())
        }
        .disabled(modelManager.isTranscriptionInProgress)
        .accessibilityLabel(Text("Model"))
        .accessibilityValue(Text(settings.selectedTranscriptionModel.displayName))
    }

    private var modelPickerOptions: [TranscriptionModel] {
        modelManager.availableTranscriptionModels()
    }

    private var modelStatusText: LocalizedStringKey {
        if settings.usesWhisperBackend {
            return LocalizedStringKey(modelManager.whisperReadinessMessage())
        }
        if modelManager.isModelReady {
            return LocalizedStringKey("Model Ready")
        }
        if settings.usesAppleSpeechBackend {
            return LocalizedStringKey(modelManager.speechAssetSnapshot.statusTitle)
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
                                .foregroundColor(Theme.textPrimary)
                            Spacer()
                            if selectedLanguage == language.code {
                                Image(systemName: "checkmark")
                                    .foregroundColor(Theme.amber)
                            }
                        }
                    }
                    .listRowBackground(Theme.panel)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
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
