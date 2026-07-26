import SwiftUI
import SwiftData
import UIKit

struct HistoryDetailView: View {
    let record: TranscriptionRecord
    @ObservedObject var viewModel: HistoryViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    // 再生位置は0.1秒ごとに更新される。この画面のbodyでは`audioPlayer`の観測対象プロパティを
    // 一切読まないこと(読むとその都度この長大なbody全体が無効化され、文字起こしリストの
    // 再レイアウトでスクロール位置が飛ぶ)。再生状態の参照は`AudioPlaybackPanel`内に閉じる。
    @State private var audioPlayer = AudioPlayer()
    @StateObject private var transcribeViewModel = TranscribeViewModel()
    // 表示スタイルはユーザー操作時しか更新されないので、bodyで観測しても再生位置のような
    // 高頻度更新は発生しない。
    @StateObject private var settings = AppSettings.shared
    @State private var showCopyConfirmation = false
    @State private var showDeleteConfirmation = false
    @State private var showExportSheet = false
    @State private var showEditTitle = false
    @State private var showEditTags = false
    @State private var editableTitle = ""
    @State private var sharePayload: SharePayload?
    @State private var showExportAudioError = false
    @State private var transcriptionExportErrorMessage: String?
    @State private var showPlaybackAudioError = false
    @State private var cachedSegments: [TranscriptionSegment] = []
    @State private var cachedAudioURL: URL?
    @State private var editingSegment: TranscriptionSegment?
    @State private var pendingUndo: SegmentEditUndo?
    @State private var undoDismissTask: Task<Void, Never>?

    var body: some View {
        // This screen intentionally uses ScrollView: TranscriptionCard changes height
        // asynchronously and must not participate in List/Form cell self-sizing.
        ScrollView {
            VStack(spacing: 14) {
                headerPanel

                if let error = viewModel.errorMessage {
                    WarningStrip(message: error)
                }

                operationsPanel(audioURL: cachedAudioURL)

                if record.hasTranscriptionText {
                    TranscriptionCard(
                        text: record.text,
                        segments: cachedSegments,
                        showTimestamps: false,
                        isLoading: false,
                        showsTimelineMarkers: true,
                        displayStyle: settings.transcriptDisplayStyle,
                        showsDisplayStyleControl: !cachedSegments.isEmpty,
                        onDisplayStyleToggle: {
                            settings.transcriptDisplayStyle =
                                settings.transcriptDisplayStyle == .timeline ? .reading : .timeline
                        },
                        onSegmentTap: handleSegmentTap,
                        onSegmentLongPress: { segment in
                            editingSegment = segment
                        }
                    )
                    .equatable()
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

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .background(Theme.background)
        .safeAreaInset(edge: .bottom) {
            if let pendingUndo {
                undoBanner(pendingUndo)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if cachedSegments.isEmpty {
                cachedSegments = record.segments
            }
            cachedAudioURL = Self.resolveAudioURL(for: record)
        }
        .onChange(of: record.segmentsJSON) { _, _ in
            cachedSegments = record.segments
        }
        .onChange(of: record.audioFilePath) { _, _ in
            cachedAudioURL = Self.resolveAudioURL(for: record)
        }
        .onDisappear {
            audioPlayer.stop()
            undoDismissTask?.cancel()
            undoDismissTask = nil
            pendingUndo = nil
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
        .alert(
            "Export",
            isPresented: Binding(
                get: { transcriptionExportErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        transcriptionExportErrorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(transcriptionExportErrorMessage ?? "")
        }
        .alert(
            String(localized: "Audio is unavailable for playback."),
            isPresented: $showPlaybackAudioError
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
        .sheet(item: $editingSegment) { segment in
            TranscriptionSegmentEditor(
                segment: segment,
                onSave: { replacement in
                    applySegmentReplacement(
                        segment: segment,
                        replacement: replacement,
                        offersUndo: true
                    )
                }
            )
        }
        .sheet(isPresented: $showExportSheet) {
            HistoryExportSheetView(record: record, viewModel: viewModel) { result in
                switch result {
                case .success(let url):
                    sharePayload = .file(url)
                case .failure(.audioUnavailable):
                    showExportAudioError = true
                case .failure(.transcription(let format)):
                    transcriptionExportErrorMessage = Self.exportFailureMessage(for: format)
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
        VStack(alignment: .leading, spacing: 14) {
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

            VStack(spacing: 9) {
                metadataLine(
                    icon: record.sourceTypeEnum == .recording ? "mic.fill" : "doc.fill",
                    text: record.formattedDate
                )

                HStack(spacing: 16) {
                    metadataLine(icon: "clock", text: formatTime(record.duration))

                    if let language = record.language {
                        Spacer(minLength: 4)
                        metadataLine(icon: "globe", text: language)
                    }
                }
            }
            .padding(12)
            .background(Theme.panelInset)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Divider().overlay(Theme.stroke)

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

    private func metadataLine(icon: String, text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.amber)
                .frame(width: 14)

            Text(text)
                .font(Theme.mono(11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
    }

    private func operationsPanel(audioURL: URL?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            TechLabel(text: "Actions")

            if let audioURL {
                AudioPlaybackPanel(audioURL: audioURL, player: audioPlayer)
            }

            Divider().overlay(Theme.stroke)

            VStack(spacing: 0) {
                if audioURL != nil {
                    Button {
                        transcribeViewModel.transcribeRecord(record, modelContext: modelContext)
                    } label: {
                        detailActionRow(
                            icon: "waveform.badge.magnifyingglass",
                            title: Text(record.hasTranscriptionText ? "Transcribe Again" : "Transcribe from Audio")
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(transcribeViewModel.isProcessing)

                    Divider().overlay(Theme.stroke)
                        .padding(.leading, 48)
                }

                if record.hasTranscriptionText {
                    Button {
                        UIPasteboard.general.string = TranscriptionSegment.plainText(
                            from: cachedSegments,
                            fallback: record.text
                        )
                        showCopyConfirmation = true
                    } label: {
                        detailActionRow(
                            icon: "doc.on.doc",
                            title: Text("Copy Text")
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("historyCopyText")

                    Divider().overlay(Theme.stroke)
                        .padding(.leading, 48)
                }

                Button {
                    showExportSheet = true
                } label: {
                    detailActionRow(
                        icon: "arrow.down.doc",
                        title: Text("Export")
                    )
                }
                .buttonStyle(.plain)
                .disabled(!record.hasTranscriptionText && audioURL == nil)

                Divider().overlay(Theme.stroke)
                    .padding(.leading, 48)

                Button {
                    showDeleteConfirmation = true
                } label: {
                    detailActionRow(
                        icon: "trash",
                        title: Text("Delete"),
                        isDestructive: true
                    )
                }
                .buttonStyle(.plain)
            }
            .background(Theme.panelInset)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

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
        }
        .recorderPanel(padding: 14)
    }

    private func detailActionRow(
        icon: String,
        title: Text,
        isDestructive: Bool = false
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isDestructive ? Theme.rec : Theme.amber)
                .frame(width: 24)

            title
                .font(Theme.sans(15, weight: .semibold))
                .foregroundStyle(isDestructive ? Theme.rec : Theme.textPrimary)

            Spacer()

            if !isDestructive {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary.opacity(0.55))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    private static func exportFailureMessage(for format: ExportFormat) -> String {
        switch format {
        case .txt:
            return String(localized: "Failed to export TXT")
        case .json:
            return String(localized: "Failed to export JSON")
        case .csv:
            return String(localized: "Failed to export CSV")
        case .srt:
            return String(localized: "Failed to export SRT")
        }
    }

    private func handleSegmentTap(_ segment: TranscriptionSegment) {
        guard cachedAudioURL != nil else {
            showPlaybackAudioError = true
            return
        }
        audioPlayer.play(from: max(0, segment.start - 2))
    }

    private func applySegmentReplacement(
        segment: TranscriptionSegment,
        replacement: String,
        offersUndo: Bool
    ) {
        let trimmedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReplacement.isEmpty, trimmedReplacement != segment.text else { return }

        guard viewModel.updateSegmentText(
            record,
            segmentID: segment.id,
            text: trimmedReplacement
        ) else {
            return
        }

        cachedSegments = record.segments
        if offersUndo {
            scheduleUndo(segmentID: segment.id, previousText: segment.text)
        }
    }

    private func scheduleUndo(segmentID: Int, previousText: String) {
        undoDismissTask?.cancel()
        withAnimation {
            pendingUndo = SegmentEditUndo(
                segmentID: segmentID,
                previousText: previousText
            )
        }
        undoDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation {
                pendingUndo = nil
            }
            undoDismissTask = nil
        }
    }

    private func performUndo(_ undo: SegmentEditUndo) {
        undoDismissTask?.cancel()
        undoDismissTask = nil
        guard let currentSegment = cachedSegments.first(where: { $0.id == undo.segmentID }) else {
            pendingUndo = nil
            return
        }
        applySegmentReplacement(
            segment: currentSegment,
            replacement: undo.previousText,
            offersUndo: false
        )
        withAnimation {
            pendingUndo = nil
        }
    }

    private func undoBanner(_ undo: SegmentEditUndo) -> some View {
        HStack(spacing: 12) {
            Text("Transcription updated")
                .font(Theme.sans(13, weight: .medium))
                .foregroundColor(Theme.textPrimary)

            Spacer()

            Button("Undo") {
                performUndo(undo)
            }
            .font(Theme.sans(13, weight: .semibold))
            .foregroundColor(Theme.amber)
            .accessibilityIdentifier("transcriptionEditUndo")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.18), radius: 8, y: 3)
    }

    /// 音声ファイルの実在確認は同期I/Oなので`body`から呼ばない。表示時と`audioFilePath`変更時だけ解決する。
    private static func resolveAudioURL(for record: TranscriptionRecord) -> URL? {
        guard let audioFilePath = record.audioFilePath else { return nil }
        guard let url = try? RecordingFileReference.fileURL(for: audioFilePath) else {
            return nil
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
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

/// 再生位置の更新(0.1秒間隔)で無効化される範囲をこのパネルだけに閉じ込めるための子ビュー。
/// `HistoryDetailView`側にこれらのプロパティ参照を戻さないこと。
private struct AudioPlaybackPanel: View {
    let audioURL: URL
    let player: AudioPlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 28) {
                Spacer()

                Button {
                    if player.isPlaying {
                        player.pause()
                    } else {
                        player.play()
                    }
                } label: {
                    AudioPlaybackControlLabel(
                        title: player.isPlaying ? "Pause Audio" : "Play Audio",
                        systemImage: player.isPlaying ? "pause.fill" : "play.fill",
                        isPrimary: true
                    )
                }
                .buttonStyle(.plain)

                Button {
                    player.stop()
                } label: {
                    AudioPlaybackControlLabel(
                        title: "Stop Audio",
                        systemImage: "stop.fill",
                        isPrimary: false
                    )
                }
                .buttonStyle(.plain)
                .disabled(player.currentTime == 0 && !player.isPlaying)

                Spacer()
            }

            if player.duration > 0 {
                VStack(spacing: 4) {
                    Slider(value: Binding(
                        get: { player.currentTime },
                        set: { player.seek(to: $0) }
                    ), in: 0...player.duration)
                    .tint(Theme.amberFill)

                    HStack {
                        Text(formatTime(player.currentTime))
                        Spacer()
                        Text(formatTime(player.duration))
                    }
                    .font(Theme.mono(11, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                }
            }

            if let error = player.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.sans(12))
                    .foregroundColor(Theme.rec)
            }
        }
        .onAppear {
            player.prepare(url: audioURL)
        }
    }
}

private struct SegmentEditUndo: Identifiable {
    let id = UUID()
    let segmentID: Int
    let previousText: String
}

private struct TranscriptionSegmentEditor: View {
    let segment: TranscriptionSegment
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(segment: TranscriptionSegment, onSave: @escaping (String) -> Void) {
        self.segment = segment
        self.onSave = onSave
        _text = State(initialValue: segment.text)
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .accessibilityIdentifier("transcriptionSegmentEditor")
                .font(Theme.sans(16))
                .foregroundColor(Theme.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(Theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.stroke, lineWidth: 1)
                }
                .padding(16)
                .background(Theme.background)
                .navigationTitle("Edit Transcription")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            dismiss()
                        }
                        .accessibilityIdentifier("transcriptionSegmentEditorCancel")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            onSave(text)
                            dismiss()
                        }
                        .accessibilityIdentifier("transcriptionSegmentEditorSave")
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
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

enum HistoryExportError: Error {
    case audioUnavailable
    case transcription(ExportFormat)
}

struct HistoryExportSheetView: View {
    let record: TranscriptionRecord
    let viewModel: HistoryViewModel
    let onExport: (Result<URL, HistoryExportError>) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ExportFormatList(
                includesAudio: RecordingAudioExporter.isAvailable(record: record),
                includesTranscription: record.hasTranscriptionText,
                hasTimestampedSegments: !record.segments.isEmpty
            ) { selection, includeTimestamps in
                let url: URL?
                switch selection {
                case .audio:
                    url = viewModel.exportRecordingAudio(record)
                case .transcription(let format):
                    url = viewModel.exportRecord(
                        record,
                        format: format,
                        includeTimestamps: includeTimestamps
                    )
                }
                dismiss()
                if let url {
                    onExport(.success(url))
                } else {
                    switch selection {
                    case .audio:
                        onExport(.failure(.audioUnavailable))
                    case .transcription(let format):
                        onExport(.failure(.transcription(format)))
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
}
