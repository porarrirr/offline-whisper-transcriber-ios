import SwiftUI
import UIKit

struct HistoryDetailView: View {
    let record: TranscriptionRecord
    @ObservedObject var viewModel: HistoryViewModel
    
    @Environment(\.modelContext) private var modelContext
    @StateObject private var audioPlayer = AudioPlayer()
    @StateObject private var transcribeViewModel = TranscribeViewModel()
    @State private var showShareSheet = false
    @State private var showCopyConfirmation = false
    @State private var showDeleteConfirmation = false
    @State private var showExportSheet = false
    @State private var showTimestampView = false
    @State private var showEditTitle = false
    @State private var editableTitle = ""
    @State private var shareItems: [Any] = []
    @State private var cachedSegments: [TranscriptionSegment] = []
    
    private func currentDisplayText() -> String {
        if showTimestampView && !cachedSegments.isEmpty {
            return cachedSegments.map { "\($0.formattedTimestamp) \($0.text)" }.joined(separator: "\n")
        }
        return record.text
    }
    
    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Title")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Text(record.displayTitle)
                            .font(AppFonts.headline)
                            .foregroundColor(AppColors.textPrimary)
                    }

                    Spacer()

                    Button {
                        editableTitle = record.displayTitle
                        showEditTitle = true
                    } label: {
                        Label("Edit Title", systemImage: "pencil")
                    }
                    .labelStyle(.iconOnly)
                }
            }

            Section {
                HStack {
                    Label(record.formattedDate, systemImage: "calendar")
                    Spacer()
                    Label("\(Int(record.duration))s", systemImage: "clock")
                }
                .font(.caption)
                .foregroundColor(.secondary)
                
                if let language = record.language {
                    HStack {
                        Image(systemName: "globe")
                            .foregroundColor(.accentColor)
                        Text("Language: \(language)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            if let audioURL {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 32) {
                            Button {
                                if audioPlayer.isPlaying {
                                    audioPlayer.pause()
                                } else {
                                    audioPlayer.play()
                                }
                            } label: {
                                AudioPlaybackControlLabel(
                                    title: audioPlayer.isPlaying ? "Pause Audio" : "Play Audio",
                                    systemImage: audioPlayer.isPlaying ? "pause.fill" : "play.fill",
                                    isPrimary: true
                                )
                            }
                            .buttonStyle(.plain)

                            Button {
                                audioPlayer.stop()
                            } label: {
                                AudioPlaybackControlLabel(
                                    title: "Stop Audio",
                                    systemImage: "stop.fill",
                                    isPrimary: false
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(audioPlayer.currentTime == 0 && !audioPlayer.isPlaying)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)

                        if audioPlayer.duration > 0 {
                            Slider(value: Binding(
                                get: { audioPlayer.currentTime },
                                set: { audioPlayer.seek(to: $0) }
                            ), in: 0...audioPlayer.duration)

                            HStack {
                                Text(formatTime(audioPlayer.currentTime))
                                Spacer()
                                Text(formatTime(audioPlayer.duration))
                            }
                            .font(AppFonts.caption)
                            .foregroundColor(AppColors.textSecondary)
                            .monospacedDigit()
                        }

                        if let error = audioPlayer.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(AppFonts.caption)
                                .foregroundColor(AppColors.warning)
                        }

                        Button {
                            transcribeViewModel.transcribeRecord(record, modelContext: modelContext)
                        } label: {
                            Label(record.hasTranscriptionText ? "Transcribe Again" : "Transcribe from Audio", systemImage: "waveform.badge.magnifyingglass")
                        }
                        .disabled(transcribeViewModel.isProcessing)

                        if transcribeViewModel.isProcessing {
                            ProgressView(value: transcribeViewModel.transcriptionProgress)
                            Text(transcribeViewModel.processingStatusText.isEmpty ? LocalizedStringKey("Preparing audio") : LocalizedStringKey(transcribeViewModel.processingStatusText))
                                .font(AppFonts.caption)
                                .foregroundColor(AppColors.textSecondary)
                        }

                        if let error = transcribeViewModel.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(AppFonts.caption)
                                .foregroundColor(AppColors.warning)
                        }
                    }
                    .onAppear {
                        audioPlayer.prepare(url: audioURL)
                    }
                }
            }
            
            if record.hasTranscriptionText {
                Section {
                    TranscriptionCard(
                        text: record.text,
                        segments: cachedSegments,
                        showTimestamps: showTimestampView,
                        isLoading: false
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    Label("No transcription yet", systemImage: "text.quote")
                        .font(AppFonts.callout)
                        .foregroundColor(AppColors.textSecondary)
                }
            }
            
            Section {
                if record.hasTranscriptionText && !cachedSegments.isEmpty {
                    Button(action: { showTimestampView.toggle() }) {
                        Label(showTimestampView ? "Show Text Only" : "Show with Timestamps", systemImage: showTimestampView ? "text.alignleft" : "clock")
                    }
                }
                
                Button(action: {
                    UIPasteboard.general.string = currentDisplayText()
                    showCopyConfirmation = true
                }) {
                    Label("Copy Text", systemImage: "doc.on.doc")
                }
                .disabled(!record.hasTranscriptionText)
                
                Button(action: {
                    shareItems = [currentDisplayText()]
                    showShareSheet = true
                }) {
                    Label("Share Text", systemImage: "square.and.arrow.up")
                }
                .disabled(!record.hasTranscriptionText)
                
                Button(action: {
                    showExportSheet = true
                }) {
                    Label("Export", systemImage: "arrow.down.doc")
                }
                .disabled(!record.hasTranscriptionText)
                
                Button(action: {
                    viewModel.toggleFavorite(record)
                }) {
                    Label(record.isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: record.isFavorite ? "star.slash" : "star")
                }
                
                Button(action: {
                    showDeleteConfirmation = true
                }) {
                    Label("Delete", systemImage: "trash")
                        .foregroundColor(.red)
                }
            }
        }
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if cachedSegments.isEmpty {
                cachedSegments = record.segments
            }
        }
        .onChange(of: record.segmentsJSON) { _, _ in
            cachedSegments = record.segments
        }
        .onDisappear {
            audioPlayer.stop()
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    viewModel.toggleFavorite(record)
                }) {
                    Image(systemName: record.isFavorite ? "star.fill" : "star")
                }
            }
        }
        .alert("Confirm Deletion", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                viewModel.deleteRecord(record)
            }
        } message: {
            Text("Are you sure you want to delete this transcription?")
        }
        .alert("Copied!", isPresented: $showCopyConfirmation) {
            Button("OK", role: .cancel) {}
        }
        .alert("Edit Title", isPresented: $showEditTitle) {
            TextField("Title", text: $editableTitle)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                viewModel.updateTitle(record, title: editableTitle)
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(activityItems: shareItems)
        }
        .sheet(isPresented: $showExportSheet) {
            HistoryExportSheetView(record: record, viewModel: viewModel) { url in
                if let url = url {
                    shareItems = [url]
                    showShareSheet = true
                }
            }
        }
        .sheet(isPresented: $transcribeViewModel.showResult) {
            ResultView(
                text: transcribeViewModel.transcriptionResult,
                segments: transcribeViewModel.transcriptionSegments,
                language: transcribeViewModel.transcriptionLanguage
            ) {
                transcribeViewModel.reset()
            }
        }
    }

    private var audioURL: URL? {
        guard let audioFilePath = record.audioFilePath else { return nil }
        let url = URL(fileURLWithPath: audioFilePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let hours = Int(time) / 3600
        let minutes = (Int(time) % 3600) / 60
        let seconds = Int(time) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private struct AudioPlaybackControlLabel: View {
    let title: LocalizedStringKey
    let systemImage: String
    let isPrimary: Bool

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(isPrimary ? AppColors.textOnAccent : AppColors.textPrimary)
                .frame(width: 52, height: 52)
                .background(isPrimary ? AppColors.accent : AppColors.surface, in: Circle())
                .opacity(isEnabled ? 1 : 0.4)

            Text(title)
                .font(AppFonts.caption)
                .foregroundColor(isEnabled ? AppColors.textSecondary : AppColors.textSecondary.opacity(0.5))
        }
        .accessibilityElement(children: .combine)
    }
}

struct HistoryExportSheetView: View {
    let record: TranscriptionRecord
    let viewModel: HistoryViewModel
    let onExport: (URL?) -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            List {
                Section(header: Text("Select Export Format")) {
                    ForEach(ExportFormat.allCases) { format in
                        Button(action: {
                            let url = viewModel.exportRecord(record, format: format)
                            dismiss()
                            onExport(url)
                        }) {
                            HStack {
                                Image(systemName: iconForFormat(format))
                                    .foregroundColor(.accentColor)
                                    .frame(width: 30)
                                
                                VStack(alignment: .leading) {
                                    Text(format.displayName)
                                        .foregroundColor(.primary)
                                    Text(extensionForFormat(format))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
    
    private func iconForFormat(_ format: ExportFormat) -> String {
        switch format {
        case .txt: return "doc.text"
        case .json: return "curlybraces"
        case .csv: return "tablecells"
        case .srt: return "captions.bubble"
        }
    }
    
    private func extensionForFormat(_ format: ExportFormat) -> String {
        ".\(format.fileExtension)"
    }
}
