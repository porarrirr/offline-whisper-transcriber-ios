import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers

struct TranscribeView: View {
    @StateObject private var viewModel = TranscribeViewModel()
    @StateObject private var modelManager = ModelManager.shared
    @State private var showFileImporter = false
    @State private var selectedFileURL: URL?
    @State private var selectedVideoItem: PhotosPickerItem?
    @State private var liveTranscriptionRequested = false
    @AppStorage(WhisperAppDestination.pendingStartRecordingKey) private var pendingStartRecording = false
    @AppStorage(WhisperAppDestination.pendingLiveRecordingKey) private var pendingLiveRecording = false
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var recordingService: RecordingService

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 14) {
                    statusHeader

                    lcdDisplay

                    if viewModel.isProcessing {
                        TranscriptionProgressPanel(
                            progress: viewModel.transcriptionProgress,
                            statusText: viewModel.processingStatusText,
                            usesDeterminateProgress: viewModel.usesDeterminateProgress,
                            onCancel: {
                                viewModel.cancelTranscription()
                            }
                        )
                    }

                    if let readinessError = modelReadinessError {
                        WarningStrip(
                            message: readinessError,
                            actionTitle: modelReadinessActionTitle,
                            action: modelReadinessAction
                        )
                    } else if let accelerationWarning = modelAccelerationWarning {
                        WarningStrip(
                            message: accelerationWarning,
                            actionTitle: modelAccelerationActionTitle,
                            action: modelAccelerationAction
                        )
                    }

                    LiveTranscriptionToggle(
                        isOn: liveTranscriptionBinding,
                        isAvailable: recordingService.canStartLiveTranscription,
                        unavailableMessage: recordingService.liveUnavailableMessage,
                        isRecording: recordingService.isRecording
                    )

                    if shouldShowLivePanel {
                        LiveTranscriptionPanel(
                            finalizedText: recordingService.liveFinalizedText,
                            volatileText: recordingService.liveVolatileText,
                            state: recordingService.liveState
                        )
                    }

                    transport
                        .opacity(viewModel.isProcessing ? 0.35 : 1)

                    inputSection

                    if let error = displayedError {
                        WarningStrip(message: error)
                    }

                    if viewModel.isProcessing {
                        Text("Processing will continue while this screen is open.")
                            .font(Theme.sans(12))
                            .foregroundColor(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                            .accessibilityHidden(true)
                    }

                    LegalDisclaimerFootnote()
                        .padding(.top, 8)

                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $viewModel.showResult) {
            ResultView(
                title: viewModel.transcriptionTitle,
                text: viewModel.transcriptionResult,
                segments: viewModel.transcriptionSegments,
                duration: viewModel.transcriptionDuration,
                language: viewModel.transcriptionLanguage
            ) {
                viewModel.reset()
            }
        }
        .sheet(isPresented: $showFileImporter) {
            FileImporter(selectedURL: $selectedFileURL, isPresented: $showFileImporter) { result in
                switch result {
                case .success(let url):
                    viewModel.transcribeFile(
                        url: url,
                        modelContext: modelContext,
                        cleanupAfterProcessing: true
                    )
                case .failure(let error):
                    viewModel.setError(String(localized: "File selection error") + ": \(error.localizedDescription)")
                }
            }
        }
        .onChange(of: selectedVideoItem) { _, newItem in
            Task {
                await handlePickedVideo(newItem)
            }
        }
        .onAppear {
            consumePendingIntentRequest()
        }
        .onChange(of: pendingStartRecording) { _, _ in
            consumePendingIntentRequest()
        }
        .onChange(of: pendingLiveRecording) { _, _ in
            consumePendingIntentRequest()
        }
        .onChange(of: recordingService.isRecording) { _, isRecording in
            if isRecording, liveTranscriptionRequested {
                viewModel.startLiveTranscription(recordingService: recordingService)
            }
        }
        .onChange(of: recordingService.liveState) { _, state in
            if recordingService.isRecording, state == .idle, recordingService.liveMessage != nil {
                liveTranscriptionRequested = false
            }
        }
    }

    // MARK: - Sections

    /// 上部ステータス列: 状態LED + 状態トークン / モデル名チップ
    private var statusHeader: some View {
        HStack(spacing: 8) {
            LEDDot(isOn: recordingService.isRecording || viewModel.isProcessing,
                   onColor: recordingService.isRecording ? Theme.rec : Theme.amber)

            Text(statusToken)
                .font(Theme.mono(12, weight: .semibold))
                .tracking(2.0)
                .foregroundStyle(recordingService.isRecording ? Theme.rec : Theme.textSecondary)
                .contentTransition(.identity)

            Spacer()

            Text(modelManager.currentTranscriptionModel.displayName)
                .font(Theme.mono(11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.panelInset)
                .clipShape(Capsule())
                .overlay {
                    Capsule().strokeBorder(Theme.stroke, lineWidth: 1)
                }
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
    }

    private var statusToken: String {
        if recordingService.isRecording { return "REC" }
        if viewModel.isProcessing { return "BUSY" }
        return "STANDBY"
    }

    /// LCDディスプレイ: 波形 + タイムコード
    private var lcdDisplay: some View {
        VStack(spacing: 10) {
            WaveformView(
                audioLevel: recordingService.audioLevel,
                isActive: recordingService.isRecording
            )
            .frame(height: 64)

            Text(formatTimecode(recordingService.isRecording ? recordingService.currentTime : 0))
                .font(Theme.mono(46, weight: .medium))
                .foregroundStyle(recordingService.isRecording ? Theme.displayAmber : Theme.displayDim)
                .monospacedDigit()
                .contentTransition(.numericText())
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            HStack {
                Text("MIC")
                    .font(Theme.mono(10, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(Theme.displayTextDim)

                Spacer()

                if recordingService.isLiveTranscriptionActive {
                    Text("LIVE")
                        .font(Theme.mono(10, weight: .bold))
                        .tracking(1.5)
                        .foregroundStyle(Theme.display)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.displayAmber)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                } else {
                    Text("OFFLINE")
                        .font(Theme.mono(10, weight: .medium))
                        .tracking(1.5)
                        .foregroundStyle(Theme.displayTextDim)
                }
            }
        }
        .displayPanel(padding: 18)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(recordingService.isRecording ? "Tap to Stop" : "Tap to Start Recording"))
    }

    /// 録音トランスポート
    private var transport: some View {
        VStack(spacing: 6) {
            RecordingButton(isRecording: recordingService.isRecording) {
                if recordingService.isRecording {
                    viewModel.stopRecordingAndTranscribe(recordingService: recordingService, modelContext: modelContext)
                } else {
                    viewModel.startRecording(recordingService: recordingService)
                }
            }
            .disabled(recordingButtonDisabled)
            .opacity(recordingButtonDisabled ? 0.45 : 1)

            Text(recordingService.isRecording ? LocalizedStringKey("Tap to Stop") : LocalizedStringKey("Tap to Start Recording"))
                .font(Theme.mono(12, weight: .medium))
                .foregroundColor(Theme.textSecondary)
        }
        .padding(.vertical, 6)
    }

    /// ファイル入力ソース
    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            TechLabel(text: "Input")
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                Button {
                    if let modelReadinessError {
                        viewModel.setError(modelReadinessError)
                    } else {
                        showFileImporter = true
                    }
                } label: {
                    RecorderActionRow(
                        icon: "doc.text",
                        title: "Select File",
                        subtitle: "Supported: audio and video files"
                    )
                    .padding(14)
                }
                .buttonStyle(.plain)
                .disabled(inputSelectionDisabled)
                .opacity(inputSelectionDisabled ? 0.45 : 1)

                Divider().overlay(Theme.stroke)
                    .padding(.leading, 62)

                PhotosPicker(
                    selection: $selectedVideoItem,
                    matching: .videos,
                    photoLibrary: .shared()
                ) {
                    RecorderActionRow(
                        icon: "photo.on.rectangle.angled",
                        title: "Select Video from Photos",
                        subtitle: "Only the selected video's audio is transcribed"
                    )
                    .padding(14)
                }
                .buttonStyle(.plain)
                .disabled(inputSelectionDisabled)
                .opacity(inputSelectionDisabled ? 0.45 : 1)

                if recordingService.hasInterruptedRecording {
                    Divider().overlay(Theme.stroke)
                        .padding(.leading, 62)

                    Button {
                        viewModel.transcribeInterruptedRecording(recordingService: recordingService, modelContext: modelContext)
                    } label: {
                        RecorderActionRow(
                            icon: "waveform.badge.magnifyingglass",
                            title: "Transcribe Interrupted Recording",
                            subtitle: "Transcribe the part that was saved before interruption"
                        )
                        .padding(14)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isProcessing || modelReadinessError != nil)
                    .opacity(viewModel.isProcessing || modelReadinessError != nil ? 0.45 : 1)
                }
            }
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1)
            }
        }
    }

    // MARK: - State helpers

    private var displayedError: String? {
        viewModel.errorMessage ?? recordingService.liveMessage ?? recordingService.interruptionMessage ?? recordingService.errorMessage
    }

    private var modelReadinessError: String? {
        modelManager.currentTranscriptionReadinessError()
    }

    private var modelAccelerationWarning: String? {
        modelManager.whisperAccelerationWarningMessage()
    }

    private var modelReadinessActionTitle: LocalizedStringKey? {
        guard !modelManager.isDownloading else { return nil }
        if modelManager.usesWhisperBackend {
            return "Download Model"
        }
        if modelManager.usesAppleSpeechBackend {
            return "Prepare Speech Model"
        }
        return nil
    }

    private var modelReadinessAction: (() -> Void)? {
        guard modelReadinessActionTitle != nil else { return nil }
        return {
            modelManager.downloadModel()
        }
    }

    private var modelAccelerationActionTitle: LocalizedStringKey? {
        guard !modelManager.isDownloading else { return nil }
        return "Download Core ML Encoder"
    }

    private var modelAccelerationAction: (() -> Void)? {
        guard modelAccelerationActionTitle != nil else { return nil }
        return {
            modelManager.downloadModel()
        }
    }

    private var recordingButtonDisabled: Bool {
        viewModel.isProcessing
            || recordingService.isChangingRecordingState
            || recordingService.liveState == .preparing
            || recordingService.liveState == .finalizing
            || (!recordingService.isRecording && modelReadinessError != nil)
    }

    private var inputSelectionDisabled: Bool {
        recordingService.isRecording
            || viewModel.isProcessing
            || recordingService.isChangingRecordingState
            || modelReadinessError != nil
    }

    private var shouldShowLivePanel: Bool {
        recordingService.isLiveTranscriptionActive
            || !recordingService.liveFinalizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !recordingService.liveVolatileText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var liveTranscriptionBinding: Binding<Bool> {
        Binding(
            get: { liveTranscriptionRequested },
            set: { newValue in
                liveTranscriptionRequested = newValue
                if recordingService.isRecording {
                    if newValue {
                        viewModel.startLiveTranscription(recordingService: recordingService)
                    } else {
                        viewModel.stopLiveTranscription(recordingService: recordingService)
                    }
                }
            }
        )
    }

    private func consumePendingIntentRequest() {
        let shouldStartRecording = pendingStartRecording
        let shouldStartLiveTranscription = pendingLiveRecording

        guard shouldStartRecording || shouldStartLiveTranscription else { return }

        pendingStartRecording = false
        pendingLiveRecording = false

        if shouldStartLiveTranscription {
            liveTranscriptionRequested = true
        }

        Task { @MainActor in
            if shouldStartRecording, !recordingService.isRecording {
                let startResult = await viewModel.startRecordingAsync(
                    recordingService: recordingService,
                    requiresTranscriptionReadiness: false
                )
                guard startResult != nil else {
                    if shouldStartLiveTranscription {
                        liveTranscriptionRequested = false
                    }
                    return
                }
            }

            if shouldStartLiveTranscription {
                guard recordingService.canStartLiveTranscription else {
                    liveTranscriptionRequested = false
                    if let message = recordingService.liveUnavailableMessage {
                        viewModel.setError(message)
                    }
                    return
                }

                if recordingService.isRecording {
                    viewModel.startLiveTranscription(recordingService: recordingService)
                }
            }
        }
    }

    @MainActor
    private func handlePickedVideo(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        defer {
            selectedVideoItem = nil
        }

        do {
            if let modelReadinessError {
                viewModel.setError(modelReadinessError)
                return
            }
            guard let pickedVideo = try await item.loadTransferable(type: PickedVideoFile.self) else {
                viewModel.setError(String(localized: "Video selection error") + ": " + String(localized: "No video file was selected."))
                return
            }
            viewModel.transcribeFile(
                url: pickedVideo.url,
                modelContext: modelContext,
                cleanupAfterProcessing: true
            )
        } catch {
            viewModel.setError(String(localized: "Video selection error") + ": \(error.localizedDescription)")
        }
    }
}

// MARK: - Live transcription

private struct LiveTranscriptionToggle: View {
    @Binding var isOn: Bool
    let isAvailable: Bool
    let unavailableMessage: String?
    let isRecording: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $isOn) {
                HStack(spacing: 10) {
                    Image(systemName: "quote.bubble")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.amber)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Live Transcribe")
                            .font(Theme.sans(15, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                        Text(isRecording ? "Toggle live transcription while recording" : "Start recording with live transcription")
                            .font(Theme.sans(12))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
            }
            .toggleStyle(.switch)
            .tint(Theme.amberFill)
            .disabled(!isAvailable)
            .opacity(isAvailable ? 1 : 0.5)

            if let unavailableMessage {
                Text(LocalizedStringKey(unavailableMessage))
                    .font(Theme.sans(12))
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .recorderPanel(padding: 14)
    }
}

private struct LiveTranscriptionPanel: View {
    let finalizedText: String
    let volatileText: String
    let state: LiveTranscriptionState

    private var visibleFinalText: String {
        let trimmed = finalizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "Listening...") : trimmed
    }

    private var statusText: LocalizedStringKey {
        switch state {
        case .preparing:
            return "Preparing live transcription..."
        case .recording:
            return "Live Transcribe"
        case .finalizing:
            return "Finalizing live transcription..."
        case .saving:
            return "Saving live transcription..."
        case .failed:
            return "Live transcription failed"
        case .idle:
            return "Live Transcribe"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(state == .recording ? Theme.displayAmber : Theme.displayDim)
                    .frame(width: 6, height: 6)

                Text(statusText)
                    .font(Theme.mono(11, weight: .semibold))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundColor(Theme.displayTextDim)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(visibleFinalText)
                        .font(Theme.sans(18))
                        .foregroundColor(finalizedText.isEmpty ? Theme.displayTextDim : Theme.displayText)
                        .lineSpacing(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)

                    if !volatileText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(volatileText)
                            .font(Theme.sans(17))
                            .foregroundColor(Theme.displayTextDim)
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 84, maxHeight: 180)
        }
        .displayPanel(padding: 14)
    }
}

// MARK: - Processing

private struct TranscriptionProgressPanel: View {
    let progress: Double
    let statusText: String
    let usesDeterminateProgress: Bool
    let onCancel: () -> Void

    private var clampedProgress: Double {
        min(max(progress, 0), 1)
    }

    private var percentText: String {
        "\(Int((clampedProgress * 100).rounded()))%"
    }

    private var visibleStatusText: LocalizedStringKey {
        statusText.isEmpty ? "Preparing audio" : LocalizedStringKey(statusText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    TechLabel(text: "Transcription in progress", color: Theme.amber)

                    Text(visibleStatusText)
                        .font(Theme.sans(13))
                        .foregroundColor(Theme.textSecondary)
                }

                Spacer(minLength: 8)

                if usesDeterminateProgress {
                    Text(percentText)
                        .font(Theme.mono(30, weight: .semibold))
                        .foregroundColor(Theme.amber)
                        .accessibilityLabel(Text("Transcription progress"))
                        .accessibilityValue(Text(percentText))
                } else {
                    ProgressView()
                        .tint(Theme.amber)
                        .accessibilityLabel(Text("Transcription in progress"))
                }
            }

            if usesDeterminateProgress {
                ProgressBar(progress: clampedProgress)
                    .frame(height: 6)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "cpu")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.amber)
                    Text("On-device speech recognition is processing.")
                        .font(Theme.sans(12))
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Text("Please keep the app open until this finishes.")
                    .font(Theme.sans(12))
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Button(role: .cancel, action: onCancel) {
                    Text("Cancel")
                }
                .buttonStyle(.recorderQuiet)
            }
        }
        .recorderPanel()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Photos picker payload

private struct PickedVideoFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .video) { receivedFile in
            try Self.copyReceivedVideo(receivedFile)
        }

        FileRepresentation(importedContentType: .movie) { receivedFile in
            try Self.copyReceivedVideo(receivedFile)
        }
    }

    private static func copyReceivedVideo(_ receivedFile: ReceivedTransferredFile) throws -> PickedVideoFile {
        let sourceURL = receivedFile.file
        let fileExtension = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("picked-video-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)

        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return PickedVideoFile(url: destinationURL)
    }
}
