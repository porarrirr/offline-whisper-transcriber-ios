import SwiftUI
import SwiftData
import UIKit

struct HistoryDetailView: View {
    let record: TranscriptionRecord
    @ObservedObject var viewModel: HistoryViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @StateObject private var audioPlayer = AudioPlayer()
    @StateObject private var transcribeViewModel = TranscribeViewModel()
    @State private var showCopyConfirmation = false
    @State private var showDeleteConfirmation = false
    @State private var showExportSheet = false
    @State private var showTimestampView = false
    @State private var showEditTitle = false
    @State private var showEditTags = false
    @State private var editableTitle = ""
    @State private var sharePayload: SharePayload?
    @State private var showExportAudioError = false
    @State private var cachedSegments: [TranscriptionSegment] = []

    private func currentDisplayText() -> String {
        if showTimestampView && !cachedSegments.isEmpty {
            return TranscriptionSegment.timestampedText(from: cachedSegments)
        }
        return TranscriptionSegment.plainText(from: cachedSegments, fallback: record.text)
    }

    var body: some View {
        // This screen intentionally uses ScrollView: TranscriptionCard changes height
        // asynchronously and must not participate in List/Form cell self-sizing.
        ScrollView {
            VStack(spacing: 14) {
                headerPanel

                tagsPanel

                if let audioURL {
                    audioPanel(audioURL: audioURL)
                }

                if record.hasTranscriptionText {
                    TranscriptionCard(
                        text: record.text,
                        segments: cachedSegments,
                        showTimestamps: showTimestampView,
                        isLoading: false
                    )
                    .accessibilityIdentifier("historyTranscriptionCard")
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "text.quote")
                            .foregroundColor(Theme.textSecondary)
                        Text("No transcription yet")
                            .font(Theme.sans(14))
                            .foregroundColor(Theme.textSecondary)
                        Spacer()
                    }
                    .recorderPanel(padding: 14)
                }

                actionsPanel

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .background(Theme.background)
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
                        .foregroundColor(record.isFavorite ? Theme.amber : Theme.textSecondary)
                }
            }
        }
        .alert("Confirm Deletion", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                audioPlayer.stop()
                if viewModel.deleteRecord(record) {
                    dismiss()
                }
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
        .sheet(item: $sharePayload) { payload in
            ShareSheet(activityItems: payload.activityItems)
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
                    sharePayload = .file(url)
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

    // MARK: - Panels

    private var headerPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Text(record.displayTitle)
                    .font(Theme.sans(19, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    editableTitle = record.displayTitle
                    showEditTitle = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.amber)
                        .frame(width: 30, height: 30)
                        .background(Theme.panelInset)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Theme.stroke, lineWidth: 1)
                        }
                }
                .accessibilityLabel(Text("Edit Title"))
            }

            HStack(spacing: 8) {
                metaChip(icon: record.sourceTypeEnum == .recording ? "mic.fill" : "doc.fill", text: record.formattedDate)
                metaChip(icon: "clock", text: formatTime(record.duration))
                if let language = record.language {
                    metaChip(icon: "globe", text: language)
                }
            }
        }
        .recorderPanel(padding: 14)
    }

    private func metaChip(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundColor(Theme.amber)
            Text(text)
                .font(Theme.mono(11, weight: .medium))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Theme.panelInset)
        .clipShape(Capsule())
        .overlay {
            Capsule().strokeBorder(Theme.stroke, lineWidth: 1)
        }
    }

    private var tagsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TechLabel(text: "Tags")

                Spacer()

                Button {
                    showEditTags = true
                } label: {
                    Label(record.tags.isEmpty ? "Add Tags" : "Edit Tags", systemImage: "tag")
                        .font(Theme.sans(12, weight: .medium))
                        .foregroundColor(Theme.amber)
                }
                .buttonStyle(.plain)
            }

            if record.tags.isEmpty {
                Text("No tags")
                    .font(Theme.sans(13))
                    .foregroundColor(Theme.textSecondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(record.tags, id: \.self) { tag in
                            TagPillLabel(tag: tag, isSelected: false)
                        }
                    }
                }
            }
        }
        .recorderPanel(padding: 14)
    }

    private func audioPanel(audioURL: URL) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            TechLabel(text: "Audio")

            HStack(spacing: 28) {
                Spacer()

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

                Spacer()
            }

            if audioPlayer.duration > 0 {
                VStack(spacing: 4) {
                    Slider(value: Binding(
                        get: { audioPlayer.currentTime },
                        set: { audioPlayer.seek(to: $0) }
                    ), in: 0...audioPlayer.duration)
                    .tint(Theme.amberFill)

                    HStack {
                        Text(formatTime(audioPlayer.currentTime))
                        Spacer()
                        Text(formatTime(audioPlayer.duration))
                    }
                    .font(Theme.mono(11, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                }
            }

            if let error = audioPlayer.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.sans(12))
                    .foregroundColor(Theme.rec)
            }

            Divider().overlay(Theme.stroke)

            Button {
                transcribeViewModel.transcribeRecord(record, modelContext: modelContext)
            } label: {
                Label(record.hasTranscriptionText ? "Transcribe Again" : "Transcribe from Audio", systemImage: "waveform.badge.magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.recorderQuiet)
            .disabled(transcribeViewModel.isProcessing)

            if transcribeViewModel.isProcessing {
                if transcribeViewModel.usesDeterminateProgress {
                    ProgressBar(progress: transcribeViewModel.transcriptionProgress)
                        .frame(height: 6)
                } else {
                    ProgressView()
                        .tint(Theme.amber)
                }
                Text(transcribeViewModel.processingStatusText.isEmpty ? LocalizedStringKey("Preparing audio") : LocalizedStringKey(transcribeViewModel.processingStatusText))
                    .font(Theme.sans(12))
                    .foregroundColor(Theme.textSecondary)
            }

            if let error = transcribeViewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.sans(12))
                    .foregroundColor(Theme.rec)
            }

            Button {
                if let url = viewModel.exportRecordingAudio(record) {
                    sharePayload = .file(url)
                } else {
                    showExportAudioError = true
                }
            } label: {
                Label("Export Audio", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.recorderQuiet)
        }
        .recorderPanel(padding: 14)
        .onAppear {
            audioPlayer.prepare(url: audioURL)
        }
    }

    private var actionsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            TechLabel(text: "Export")

            if record.hasTranscriptionText && !cachedSegments.isEmpty {
                Button(action: { showTimestampView.toggle() }) {
                    Label(showTimestampView ? "Show Text Only" : "Show with Timestamps", systemImage: showTimestampView ? "text.alignleft" : "clock")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.recorderQuiet)
                .accessibilityIdentifier("historyTimestampToggle")
            }

            HStack(spacing: 10) {
                Button(action: {
                    UIPasteboard.general.string = currentDisplayText()
                    showCopyConfirmation = true
                }) {
                    Label("Copy Text", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.recorderQuiet)
                .disabled(!record.hasTranscriptionText)

                Button(action: {
                    sharePayload = .text(currentDisplayText())
                }) {
                    Label("Share Text", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.recorderQuiet)
                .disabled(!record.hasTranscriptionText)
            }

            Button(action: {
                showExportSheet = true
            }) {
                Label("Export", systemImage: "arrow.down.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.recorderQuiet)
            .disabled(!record.hasTranscriptionText)

            Button(action: {
                viewModel.toggleFavorite(record)
            }) {
                Label(record.isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: record.isFavorite ? "star.slash" : "star")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.recorderQuiet)

            Button(action: {
                showDeleteConfirmation = true
            }) {
                Label("Delete", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.recorderQuietDestructive)
        }
        .recorderPanel(padding: 14)
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
            ScrollView {
                VStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        TechLabel(text: "Tags")

                        if selectedTags.isEmpty {
                            Text("No tags")
                                .font(Theme.sans(13))
                                .foregroundColor(Theme.textSecondary)
                        } else {
                            tagGrid(tags: selectedTags) { tag in
                                removeTag(tag)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .recorderPanel(padding: 14)

                    if !reusableTags.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            TechLabel(text: "Add Tags")

                            tagGrid(tags: reusableTags) { tag in
                                addTags([tag])
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .recorderPanel(padding: 14)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            TextField("Tags", text: $newTagText, axis: .vertical)
                                .font(Theme.sans(15))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .submitLabel(.done)
                                .onSubmit(addTypedTags)

                            Button(action: addTypedTags) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.title3)
                                    .foregroundColor(Theme.amber)
                            }
                            .disabled(newTagText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityLabel(Text("Add Tags"))
                        }

                        Text("Enter tags separated by commas.")
                            .font(Theme.sans(11))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .recorderPanel(padding: 14)
                }
                .padding(16)
            }
            .background(Theme.background)
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
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(isPrimary ? Theme.onAmber : Theme.textPrimary)
                .frame(width: 52, height: 52)
                .background(isPrimary ? Theme.amberFill : Theme.panelInset, in: Circle())
                .overlay {
                    Circle().strokeBorder(isPrimary ? Color.clear : Theme.stroke, lineWidth: 1)
                }
                .opacity(isEnabled ? 1 : 0.4)

            Text(title)
                .font(Theme.mono(10, weight: .medium))
                .foregroundColor(isEnabled ? Theme.textSecondary : Theme.textSecondary.opacity(0.5))
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
            ExportFormatList { format in
                let url = viewModel.exportRecord(record, format: format)
                dismiss()
                onExport(url)
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
}
