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
    @State private var showEditTags = false
    @State private var editableTitle = ""
    @State private var shareItems: [Any] = []
    @State private var showExportAudioError = false
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
                if record.tags.isEmpty {
                    Label("No tags", systemImage: "tag")
                        .font(AppFonts.callout)
                        .foregroundColor(AppColors.textSecondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(record.tags, id: \.self) { tag in
                                TagPillLabel(tag: tag, isSelected: false)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 0))
                }

                Button {
                    showEditTags = true
                } label: {
                    Label(record.tags.isEmpty ? "Add Tags" : "Edit Tags", systemImage: "tag")
                }
            } header: {
                Text("Tags")
            } footer: {
                Text("Enter tags separated by commas.")
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
                            if transcribeViewModel.usesDeterminateProgress {
                                ProgressView(value: transcribeViewModel.transcriptionProgress)
                            } else {
                                ProgressView()
                            }
                            Text(transcribeViewModel.processingStatusText.isEmpty ? LocalizedStringKey("Preparing audio") : LocalizedStringKey(transcribeViewModel.processingStatusText))
                                .font(AppFonts.caption)
                                .foregroundColor(AppColors.textSecondary)
                        }

                        if let error = transcribeViewModel.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(AppFonts.caption)
                                .foregroundColor(AppColors.warning)
                        }

                        Button {
                            if let url = viewModel.exportRecordingAudio(record) {
                                shareItems = [url]
                                showShareSheet = true
                            } else {
                                showExportAudioError = true
                            }
                        } label: {
                            Label("Export Audio", systemImage: "square.and.arrow.up")
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
        .alert(
            String(localized: "The audio file for this history item could not be found."),
            isPresented: $showExportAudioError
        ) {
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
        .sheet(isPresented: $showEditTags) {
            TagEditorSheetView(
                title: record.tags.isEmpty ? "Add Tags" : "Edit Tags",
                initialTags: record.tags,
                availableTags: viewModel.availableTags
            ) { tags in
                viewModel.updateTags(record, tags: tags)
            }
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
                title: transcribeViewModel.transcriptionTitle,
                text: transcribeViewModel.transcriptionResult,
                segments: transcribeViewModel.transcriptionSegments,
                duration: transcribeViewModel.transcriptionDuration,
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

private struct TagEditorSheetView: View {
    let title: LocalizedStringKey
    let availableTags: [String]
    let onSave: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTags: [String]
    @State private var newTagText = ""

    private let tagColumns = [
        GridItem(.adaptive(minimum: 92), spacing: 8, alignment: .leading)
    ]

    init(
        title: LocalizedStringKey,
        initialTags: [String],
        availableTags: [String],
        onSave: @escaping ([String]) -> Void
    ) {
        self.title = title
        self.availableTags = availableTags
        self.onSave = onSave
        let normalizedTags = TranscriptionRecord.normalizedTags(from: initialTags.joined(separator: ","))
        _selectedTags = State(initialValue: normalizedTags)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if selectedTags.isEmpty {
                        Label("No tags", systemImage: "tag")
                            .font(AppFonts.callout)
                            .foregroundColor(AppColors.textSecondary)
                    } else {
                        tagGrid(tags: selectedTags) { tag in
                            removeTag(tag)
                        }
                    }
                } header: {
                    Text("Tags")
                }

                if !reusableTags.isEmpty {
                    Section {
                        tagGrid(tags: reusableTags) { tag in
                            addTags([tag])
                        }
                    } header: {
                        Text("Add Tags")
                    }
                }

                Section {
                    HStack(spacing: 12) {
                        TextField("Tags", text: $newTagText, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .onSubmit(addTypedTags)

                        Button(action: addTypedTags) {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                        }
                        .disabled(newTagText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel(Text("Add Tags"))
                    }
                } footer: {
                    Text("Enter tags separated by commas.")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(tagsForSaving())
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func tagGrid(tags: [String], action: @escaping (String) -> Void) -> some View {
        LazyVGrid(columns: tagColumns, alignment: .leading, spacing: 8) {
            ForEach(tags, id: \.self) { tag in
                Button {
                    action(tag)
                } label: {
                    TagPillLabel(
                        tag: tag,
                        isSelected: selectedTags.contains { tagsAreEqual($0, tag) }
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }

    private func addTypedTags() {
        addTags(TranscriptionRecord.normalizedTags(from: newTagText))
        newTagText = ""
    }

    private func addTags(_ tags: [String]) {
        for tag in tags where !selectedTags.contains(where: { tagsAreEqual($0, tag) }) {
            selectedTags.append(tag)
        }
    }

    private var reusableTags: [String] {
        availableTags.filter { tag in
            !selectedTags.contains { tagsAreEqual($0, tag) }
        }
    }

    private func tagsForSaving() -> [String] {
        let typedTags = TranscriptionRecord.normalizedTags(from: newTagText)
        var tags = selectedTags
        for tag in typedTags where !tags.contains(where: { tagsAreEqual($0, tag) }) {
            tags.append(tag)
        }
        return tags
    }

    private func removeTag(_ tag: String) {
        selectedTags.removeAll { tagsAreEqual($0, tag) }
    }

    private func tagsAreEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
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
