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
    @State private var videoImportTask: Task<Void, Never>?
    @State private var isImportingVideo = false
    @State private var liveTranscriptionRequested = false
    @AppStorage(WhisperAppDestination.pendingStartRecordingKey) private var pendingStartRecording = false
    @AppStorage(WhisperAppDestination.pendingLiveRecordingKey) private var pendingLiveRecording = false
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var recordingService: RecordingService

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    header

                    recorderDisplay

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

                    transport
                        .opacity(viewModel.isProcessing ? 0.35 : 1)

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
                        .padding(.horizontal, 8)
                        .padding(.top, 4)

                    Spacer(minLength: 12)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
            }
            .disabled(isImportingVideo)
            .accessibilityHidden(isImportingVideo)

            if isImportingVideo {
                VideoImportOverlay {
                    videoImportTask?.cancel()
                }
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isImportingVideo)
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
            beginPickedVideoImport(newItem)
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

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Transcribe")
                    .font(Theme.sans(34, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)

                Label("Processed Offline", systemImage: "checkmark.circle.fill")
                    .font(Theme.sans(13, weight: .semibold))
                    .foregroundStyle(Theme.amber)
            }

            Spacer(minLength: 8)

            NavigationLink {
                SettingsView()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(Theme.panelInset.opacity(0.7), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Settings"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 波形とタイムコードだけを主役にした、フラットな録音表示。
    private var recorderDisplay: some View {
        VStack(spacing: 18) {
            WaveformView(
                audioLevel: recordingService.audioLevel,
                isActive: recordingService.isRecording
            )
            .frame(height: 92)

            Text(formatTimecode(recordingService.isRecording ? recordingService.currentTime : 0))
                .font(.system(size: 58, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .monospacedDigit()
                .contentTransition(.numericText())
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(recordingService.isRecording ? "Tap to Stop" : "Tap to Start Recording"))
    }

    /// 録音トランスポート
    private var transport: some View {
        RecordingButton(isRecording: recordingService.isRecording) {
            if recordingService.isRecording {
                viewModel.stopRecordingAndTranscribe(recordingService: recordingService, modelContext: modelContext)
            } else {
                viewModel.startRecording(recordingService: recordingService)
            }
        }
        .disabled(recordingButtonDisabled)
        .opacity(recordingButtonDisabled ? 0.45 : 1)
    }

    /// ファイル入力ソース
    private var inputSection: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    if let modelReadinessError {
                        viewModel.setError(modelReadinessError)
                    } else {
                        showFileImporter = true
                    }
                } label: {
                    ImportActionTile(
                        icon: "doc.text",
                        title: "Select File",
                        subtitle: "Supported: audio and video files"
                    )
                }
                .buttonStyle(.plain)
                .disabled(inputSelectionDisabled)
                .opacity(inputSelectionDisabled ? 0.45 : 1)
                .frame(maxWidth: .infinity)

                PhotosPicker(
                    selection: $selectedVideoItem,
                    matching: .videos,
                    photoLibrary: .shared()
                ) {
                    ImportActionTile(
                        icon: "photo.on.rectangle.angled",
                        title: "Select Video from Photos",
                        subtitle: "Only the selected video's audio is transcribed"
                    )
                }
                .buttonStyle(.plain)
                .disabled(inputSelectionDisabled)
                .opacity(inputSelectionDisabled ? 0.45 : 1)
                .frame(maxWidth: .infinity)
            }

            if recordingService.hasInterruptedRecording {
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
                .background(Theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Theme.stroke, lineWidth: 1)
                }
                .disabled(viewModel.isProcessing || modelReadinessError != nil)
                .opacity(viewModel.isProcessing || modelReadinessError != nil ? 0.45 : 1)
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
        guard !modelManager.isDownloading, modelManager.canDownloadCoreMLEncoder else { return nil }
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
    private func beginPickedVideoImport(_ item: PhotosPickerItem?) {
        guard let item else { return }

        videoImportTask?.cancel()
        isImportingVideo = true
        videoImportTask = Task { @MainActor in
            await handlePickedVideo(item)
        }
    }

    @MainActor
    private func handlePickedVideo(_ item: PhotosPickerItem) async {
        var unclaimedTemporaryURL: URL?
        defer {
            if let unclaimedTemporaryURL {
                try? FileManager.default.removeItem(at: unclaimedTemporaryURL)
            }
            isImportingVideo = false
            videoImportTask = nil
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

            unclaimedTemporaryURL = pickedVideo.url
            try Task.checkCancellation()

            viewModel.transcribeFile(
                url: pickedVideo.url,
                modelContext: modelContext,
                cleanupAfterProcessing: true
            )
            unclaimedTemporaryURL = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
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

private struct ImportActionTile: View {
    let icon: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Theme.amber)
                .frame(height: 36)

            Text(title)
                .font(Theme.sans(15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            Text(subtitle)
                .font(Theme.sans(12))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, minHeight: 164, alignment: .top)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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

private struct VideoImportOverlay: View {
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.32)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Theme.amber)

                VStack(spacing: 6) {
                    Text("Importing video")
                        .font(Theme.sans(18, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)

                    Text("Loading the selected video from Photos...")
                        .font(Theme.sans(13))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }

                Button(role: .cancel, action: onCancel) {
                    Text("Cancel")
                }
                .buttonStyle(.recorderQuiet)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 320)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.2), radius: 24, y: 10)
            .padding(.horizontal, 24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

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

        do {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            return PickedVideoFile(url: destinationURL)
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }
}
