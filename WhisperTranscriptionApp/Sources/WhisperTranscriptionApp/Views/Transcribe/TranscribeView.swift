import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers

struct TranscribeView: View {
    @StateObject private var viewModel = TranscribeViewModel()
    @State private var showFileImporter = false
    @State private var selectedFileURL: URL?
    @State private var selectedVideoItem: PhotosPickerItem?
    @State private var liveTranscriptionRequested = false
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var recordingService: RecordingService
    
    var body: some View {
        ZStack {
            AppColors.background.ignoresSafeArea()
            
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Transcribe")
                            .font(AppFonts.largeTitle)
                            .foregroundColor(AppColors.textPrimary)
                        
                        Text("Record or select a file")
                            .font(AppFonts.body)
                            .foregroundColor(AppColors.textSecondary)
                    }
                    
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 20)
                
                ScrollView {
                    VStack(spacing: 24) {
                        if viewModel.isProcessing {
                            TranscriptionProgressPanel(
                                progress: viewModel.transcriptionProgress,
                                statusText: viewModel.processingStatusText,
                                usesDeterminateProgress: viewModel.usesDeterminateProgress,
                                onCancel: {
                                    viewModel.cancelTranscription()
                                }
                            )
                            .padding(.horizontal)
                            .padding(.top, 8)
                        }

                        VStack(spacing: 20) {
                            if recordingService.isRecording {
                                WaveformView(audioLevel: recordingService.audioLevel)
                                    .frame(height: 100)
                                    .padding(.horizontal)
                                
                                Text(formatTime(recordingService.currentTime))
                                    .font(AppFonts.title2)
                                    .foregroundColor(AppColors.accent)
                                    .monospacedDigit()
                            }

                            LiveTranscriptionToggle(
                                isOn: liveTranscriptionBinding,
                                isAvailable: recordingService.canStartLiveTranscription,
                                unavailableMessage: recordingService.liveUnavailableMessage,
                                isRecording: recordingService.isRecording
                            )
                            .padding(.horizontal)

                            if shouldShowLivePanel {
                                LiveTranscriptionPanel(
                                    elapsedTime: recordingService.liveElapsedTime,
                                    audioLevel: recordingService.liveAudioLevel,
                                    finalizedText: recordingService.liveFinalizedText,
                                    volatileText: recordingService.liveVolatileText,
                                    state: recordingService.liveState,
                                    onStop: {
                                        liveTranscriptionRequested = false
                                        viewModel.stopLiveTranscription(recordingService: recordingService)
                                    },
                                    onCancel: {
                                        liveTranscriptionRequested = false
                                        viewModel.cancelLiveTranscription(recordingService: recordingService)
                                    }
                                )
                                .padding(.horizontal)
                            }
                            
                            RecordingButton(isRecording: $recordingService.isRecording) {
                                if recordingService.isRecording {
                                    viewModel.stopRecordingAndTranscribe(recordingService: recordingService, modelContext: modelContext)
                                } else {
                                    viewModel.startRecording(recordingService: recordingService)
                                }
                            }
                            .disabled(viewModel.isProcessing || recordingService.liveState == .preparing || recordingService.liveState == .finalizing)
                            
                            Text(recordingService.isRecording ? LocalizedStringKey("Tap to Stop") : LocalizedStringKey("Tap to Start Recording"))
                                .font(AppFonts.callout)
                                .foregroundColor(AppColors.textSecondary)
                        }
                        .padding(.vertical, 20)
                        .opacity(viewModel.isProcessing ? 0.28 : 1)
                        
                        Divider()
                            .background(AppColors.surface)
                            .padding(.horizontal)
                        
                        Button(action: {
                            showFileImporter = true
                        }) {
                            HStack {
                                Image(systemName: "doc.text.fill")
                                    .font(.title2)
                                    .foregroundColor(AppColors.accent)
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Select File")
                                        .font(AppFonts.headline)
                                        .foregroundColor(AppColors.textPrimary)
                                    
                                    Text("Supported: audio and video files")
                                        .font(AppFonts.caption)
                                        .foregroundColor(AppColors.textSecondary)
                                }
                                
                                Spacer()
                                
                                Image(systemName: "chevron.right")
                                    .foregroundColor(AppColors.textSecondary)
                            }
                            .padding()
                            .background(.regularMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 4)
                        }
                        .padding(.horizontal)
                        .disabled(recordingService.isRecording || viewModel.isProcessing)
                        .opacity(recordingService.isRecording || viewModel.isProcessing ? 0.5 : 1)

                        PhotosPicker(
                            selection: $selectedVideoItem,
                            matching: .videos,
                            photoLibrary: .shared()
                        ) {
                            HStack {
                                Image(systemName: "photo.on.rectangle.angled")
                                    .font(.title2)
                                    .foregroundColor(AppColors.accent)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Select Video from Photos")
                                        .font(AppFonts.headline)
                                        .foregroundColor(AppColors.textPrimary)

                                    Text("Only the selected video's audio is transcribed")
                                        .font(AppFonts.caption)
                                        .foregroundColor(AppColors.textSecondary)
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .foregroundColor(AppColors.textSecondary)
                            }
                            .padding()
                            .background(.regularMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 4)
                        }
                        .padding(.horizontal)
                        .disabled(recordingService.isRecording || viewModel.isProcessing)
                        .opacity(recordingService.isRecording || viewModel.isProcessing ? 0.5 : 1)
                        
                        if let error = displayedError {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(AppColors.warning)
                                Text(error)
                                    .font(AppFonts.callout)
                                    .foregroundColor(AppColors.warning)
                            }
                            .padding()
                            .background(AppColors.warning.opacity(0.1))
                            .cornerRadius(12)
                            .padding(.horizontal)
                        }

                        if recordingService.hasInterruptedRecording {
                            Button(action: {
                                viewModel.transcribeInterruptedRecording(recordingService: recordingService, modelContext: modelContext)
                            }) {
                                HStack {
                                    Image(systemName: "waveform.badge.magnifyingglass")
                                        .font(.title2)
                                        .foregroundColor(AppColors.accent)

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Transcribe Interrupted Recording")
                                            .font(AppFonts.headline)
                                            .foregroundColor(AppColors.textPrimary)

                                        Text("Use the saved partial recording")
                                            .font(AppFonts.caption)
                                            .foregroundColor(AppColors.textSecondary)
                                    }

                                    Spacer()

                                    Image(systemName: "chevron.right")
                                        .foregroundColor(AppColors.textSecondary)
                                }
                                .padding()
                                .background(.regularMaterial)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 4)
                            }
                            .padding(.horizontal)
                            .disabled(viewModel.isProcessing)
                            .opacity(viewModel.isProcessing ? 0.5 : 1)
                        }
                        
                        if viewModel.isProcessing {
                            Text("Processing will continue while this screen is open.")
                                .font(AppFonts.caption)
                                .foregroundColor(AppColors.textSecondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                                .accessibilityHidden(true)
                        }
                        
                        LegalDisclaimerFootnote()
                            .padding(.horizontal)

                        Spacer(minLength: 40)
                    }
                }
            }
        }
        .sheet(isPresented: $viewModel.showResult) {
            ResultView(
                text: viewModel.transcriptionResult,
                segments: viewModel.transcriptionSegments,
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
    
    private func formatTime(_ time: TimeInterval) -> String {
        let hours = Int(time) / 3600
        let minutes = (Int(time) % 3600) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    private var displayedError: String? {
        viewModel.errorMessage ?? recordingService.liveMessage ?? recordingService.interruptionMessage ?? recordingService.errorMessage
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

    @MainActor
    private func handlePickedVideo(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        defer {
            selectedVideoItem = nil
        }

        do {
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

private struct LiveTranscriptionToggle: View {
    @Binding var isOn: Bool
    let isAvailable: Bool
    let unavailableMessage: String?
    let isRecording: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $isOn) {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Live Transcribe")
                            .font(AppFonts.headline)
                            .foregroundColor(AppColors.textPrimary)
                        Text(isRecording ? "Toggle live transcription while recording" : "Start recording with live transcription")
                            .font(AppFonts.caption)
                            .foregroundColor(AppColors.textSecondary)
                    }
                } icon: {
                    Image(systemName: "quote.bubble.fill")
                        .foregroundColor(AppColors.accent)
                }
            }
            .toggleStyle(.switch)
            .disabled(!isAvailable)
            .opacity(isAvailable ? 1 : 0.55)

            if let unavailableMessage {
                Text(LocalizedStringKey(unavailableMessage))
                    .font(AppFonts.caption)
                    .foregroundColor(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct LiveTranscriptionPanel: View {
    let elapsedTime: TimeInterval
    let audioLevel: Float
    let finalizedText: String
    let volatileText: String
    let state: LiveTranscriptionState
    let onStop: () -> Void
    let onCancel: () -> Void

    private var visibleFinalText: String {
        let trimmed = finalizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "Listening...") : trimmed
    }

    private var formattedElapsedTime: String {
        let hours = Int(elapsedTime) / 3600
        let minutes = (Int(elapsedTime) % 3600) / 60
        let seconds = Int(elapsedTime) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
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
        VStack(spacing: 20) {
            HStack(spacing: 16) {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .foregroundColor(AppColors.accent)
                .accessibilityLabel(Text("Cancel"))

                Spacer()

                Text(statusText)
                    .font(AppFonts.title2)
                    .foregroundColor(AppColors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer()

                Image(systemName: "gearshape")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(AppColors.accent)
                    .frame(width: 40, height: 40)
                    .accessibilityHidden(true)
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 12, height: 12)
                Text(formattedElapsedTime)
                    .font(.title2.monospacedDigit())
                    .foregroundColor(AppColors.textPrimary)
            }

            WaveformView(audioLevel: audioLevel)
                .frame(height: 82)

            Divider()
                .background(AppColors.surface)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(visibleFinalText)
                        .font(.system(size: 27, weight: .regular, design: .default))
                        .foregroundColor(finalizedText.isEmpty ? AppColors.textSecondary : AppColors.textPrimary)
                        .lineSpacing(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)

                    if !volatileText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(volatileText)
                            .font(.system(size: 24, weight: .regular, design: .default))
                            .foregroundColor(AppColors.textSecondary.opacity(0.72))
                            .lineSpacing(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 260, maxHeight: 420)

            Button(action: onStop) {
                ZStack {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 82, height: 82)
                        .shadow(color: Color.red.opacity(0.26), radius: 16, x: 0, y: 8)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white)
                        .frame(width: 26, height: 26)
                }
            }
            .buttonStyle(.plain)
            .disabled(state == .finalizing || state == .saving || state == .preparing)
            .opacity(state == .finalizing || state == .saving || state == .preparing ? 0.55 : 1)
            .accessibilityLabel(Text("Stop"))
        }
        .padding(20)
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(AppColors.accent.opacity(0.24), lineWidth: 1)
        }
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
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(AppColors.accent.opacity(0.16))
                        .frame(width: 58, height: 58)

                    Image(systemName: "waveform.and.magnifyingglass")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundColor(AppColors.accent)
                        .symbolEffect(.pulse, options: .repeating, value: animationValue)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Transcription in progress")
                        .font(AppFonts.title2)
                        .foregroundColor(AppColors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(visibleStatusText)
                        .font(AppFonts.callout)
                        .foregroundColor(AppColors.textSecondary)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 8) {
                    if usesDeterminateProgress {
                        Text(percentText)
                            .font(.title2.weight(.bold).monospacedDigit())
                            .foregroundColor(AppColors.accent)
                            .accessibilityLabel(Text("Transcription progress"))
                            .accessibilityValue(Text(percentText))
                    } else {
                        ProgressView()
                            .tint(AppColors.accent)
                            .controlSize(.regular)
                            .accessibilityLabel(Text("Transcription in progress"))
                    }

                    Button(role: .cancel, action: onCancel) {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                    .font(AppFonts.callout)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if usesDeterminateProgress {
                ProgressView(value: clampedProgress)
                    .tint(AppColors.accent)
                    .scaleEffect(x: 1, y: 2.4)
                    .padding(.vertical, 4)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "cpu")
                        .foregroundColor(AppColors.accent)
                    Text("On-device speech recognition is processing.")
                        .font(AppFonts.callout)
                        .foregroundColor(AppColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }

            Text("Please keep the app open until this finishes.")
                .font(AppFonts.callout)
                .foregroundColor(AppColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(AppColors.accent.opacity(0.25), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var animationValue: String {
        usesDeterminateProgress ? percentText : statusText
    }
}

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
