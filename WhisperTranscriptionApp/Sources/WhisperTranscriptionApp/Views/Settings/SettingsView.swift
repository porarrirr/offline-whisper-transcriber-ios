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
    @State private var showSpeechLocalePicker = false
    @State private var showLogCopiedConfirmation = false
    @State private var speechLocaleOptions: [AppleSpeechLocale] = []
    @State private var didLoadSpeechLocaleOptions = false
    @State private var isLoadingSpeechLocaleOptions = false
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

                if modelManager.isDownloading {
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
                } else if !modelManager.isModelReady && settings.usesAppleSpeechBackend {
                    Button(action: { modelManager.downloadModel() }) {
                        Label("Prepare Speech Model", systemImage: "arrow.down.circle.fill")
                            .foregroundColor(Theme.amber)
                    }
                }

                if let error = modelManager.downloadError {
                    if settings.usesAppleSpeechBackend {
                        WarningStrip(message: error, actionTitle: "Retry") {
                            modelManager.downloadModel()
                        }
                    } else {
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
                }

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
                } else if settings.usesAppleSpeechBackend {
                    Button(action: { showSpeechLocalePicker = true }) {
                        HStack {
                            Text("SpeechTranscriber Language")
                                .foregroundColor(Theme.textPrimary)
                            Spacer()
                            Text(selectedSpeechLocaleName)
                                .foregroundColor(Theme.textSecondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    .disabled(modelManager.isTranscriptionInProgress || speechLocaleOptions.isEmpty)

                    if isLoadingSpeechLocaleOptions {
                        HStack {
                            ProgressView()
                                .tint(Theme.amber)
                            Text("Loading SpeechTranscriber languages...")
                                .foregroundColor(Theme.textSecondary)
                        }
                    } else if speechLocaleOptions.isEmpty {
                        Text("No SpeechTranscriber languages are available on this device.")
                            .font(Theme.sans(12))
                            .foregroundColor(Theme.textSecondary)
                    }
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
        .task(id: settings.selectedTranscriptionModel.storageKey) {
            await refreshSpeechLocaleOptions()
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
        .sheet(isPresented: $showSpeechLocalePicker) {
            SpeechTranscriberLanguagePickerView(
                locales: speechLocaleOptions,
                selectedLocale: settings.selectedTranscriptionModel.appleSpeechLocale,
                isLoading: isLoadingSpeechLocaleOptions,
                isPresented: $showSpeechLocalePicker
            ) { locale in
                selectSpeechLocale(locale)
            }
        }
    }

    private var modelSelectionMenu: some View {
        Menu {
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
        let appleSpeechLocales = didLoadSpeechLocaleOptions ? speechLocaleOptions : AppleSpeechLocale.pickerCases
        return TranscriptionModel.pickerOptions(
            selectedModel: settings.selectedTranscriptionModel,
            appleSpeechLocales: appleSpeechLocales
        )
    }

    private var modelStatusText: LocalizedStringKey {
        if settings.usesWhisperBackend {
            return LocalizedStringKey(modelManager.whisperReadinessMessage())
        }
        if modelManager.isModelReady {
            return LocalizedStringKey("Model Ready")
        }
        if settings.usesAppleSpeechBackend {
            return LocalizedStringKey("Preparing speech model...")
        }
        return LocalizedStringKey("Please download model")
    }

    private var selectedSpeechLocaleName: String {
        settings.selectedTranscriptionModel.appleSpeechLocale?.localizedLocaleName ?? String(localized: "Unknown")
    }

    @MainActor
    private func refreshSpeechLocaleOptions() async {
        isLoadingSpeechLocaleOptions = true
        let locales = await AppleSpeechLocale.speechTranscriberSupportedCases()
        speechLocaleOptions = locales
        didLoadSpeechLocaleOptions = true
        isLoadingSpeechLocaleOptions = false
    }

    private func selectSpeechLocale(_ locale: AppleSpeechLocale) {
        let model = TranscriptionModel.appleSpeech(locale)
        settings.selectedTranscriptionModel = model
        modelManager.switchModel(model: model)
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

struct SpeechTranscriberLanguagePickerView: View {
    let locales: [AppleSpeechLocale]
    let selectedLocale: AppleSpeechLocale?
    let isLoading: Bool
    @Binding var isPresented: Bool
    let onSelect: (AppleSpeechLocale) -> Void

    var body: some View {
        NavigationStack {
            List {
                if isLoading && locales.isEmpty {
                    HStack {
                        ProgressView()
                            .tint(Theme.amber)
                        Text("Loading SpeechTranscriber languages...")
                            .foregroundColor(Theme.textSecondary)
                    }
                    .listRowBackground(Theme.panel)
                } else if locales.isEmpty {
                    Text("No SpeechTranscriber languages are available on this device.")
                        .foregroundColor(Theme.textSecondary)
                        .listRowBackground(Theme.panel)
                } else {
                    ForEach(locales) { locale in
                        Button(action: {
                            onSelect(locale)
                            isPresented = false
                        }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(locale.localizedLocaleName)
                                        .foregroundColor(Theme.textPrimary)
                                    Text(locale.localeIdentifier.replacingOccurrences(of: "_", with: "-"))
                                        .font(Theme.mono(11))
                                        .foregroundColor(Theme.textSecondary)
                                }
                                Spacer()
                                if selectedLocale == locale {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(Theme.amber)
                                }
                            }
                        }
                        .listRowBackground(Theme.panel)
                    }
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
