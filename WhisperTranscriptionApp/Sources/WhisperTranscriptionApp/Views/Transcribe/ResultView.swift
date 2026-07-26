import SwiftUI
import UIKit

struct ResultView: View {
    let title: String
    let text: String
    let segments: [TranscriptionSegment]
    let duration: Double
    let language: String?
    let onDismiss: () -> Void

    @State private var showCopyConfirmation = false
    @State private var showExportSheet = false
    @State private var showTimestampView = false
    @State private var sharePayload: SharePayload?

    @MainActor
    init(
        title: String = String(localized: "Export"),
        text: String,
        segments: [TranscriptionSegment],
        duration: Double = 0,
        language: String?,
        onDismiss: @escaping () -> Void
    ) {
        self.title = title
        self.text = text
        self.segments = segments
        self.duration = duration
        self.language = language
        self.onDismiss = onDismiss
        _showTimestampView = State(initialValue: AppSettings.shared.includeTimestamps && !segments.isEmpty)
    }

    private func currentDisplayText() -> String {
        if showTimestampView && !segments.isEmpty {
            return TranscriptionSegment.timestampedText(from: segments)
        }
        return TranscriptionSegment.plainText(from: segments, fallback: text)
    }

    var body: some View {
        NavigationStack {
            // Keep dynamically sized, asynchronously chunked transcription content out
            // of List/Form. UICollectionView self-sizing can enter a feedback loop.
            ScrollView {
                VStack(spacing: 14) {
                    metaDisplay

                    TranscriptionCard(
                        text: text,
                        segments: segments,
                        showTimestamps: showTimestampView,
                        isLoading: false
                    )
                    .accessibilityIdentifier("resultTranscriptionCard")

                    actionsPanel

                    LegalDisclaimerFootnote()
                        .padding(.top, 4)

                    Spacer(minLength: 20)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .background(Theme.background)
            .navigationTitle("Result")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done", action: onDismiss)
                }
            }
            .alert("Copied!", isPresented: $showCopyConfirmation) {
                Button("OK", role: .cancel) {}
            }
            .sheet(item: $sharePayload) { payload in
                ShareSheet(activityItems: payload.activityItems)
            }
            .sheet(isPresented: $showExportSheet) {
                ExportSheetView(
                    title: title,
                    text: text,
                    segments: segments,
                    duration: duration,
                    language: language
                ) { url in
                    if let url = url {
                        sharePayload = .file(url)
                    }
                }
            }
        }
    }

    /// 結果メタ情報のLCD表示
    private var metaDisplay: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("LENGTH")
                    .font(Theme.mono(10, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(Theme.displayTextDim)

                Text(formatTimecode(duration))
                    .font(Theme.mono(24, weight: .medium))
                    .foregroundStyle(Theme.displayAmber)
            }

            Spacer()

            if let language {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("LANG")
                        .font(Theme.mono(10, weight: .semibold))
                        .tracking(1.5)
                        .foregroundStyle(Theme.displayTextDim)

                    Text(language.uppercased())
                        .font(Theme.mono(24, weight: .medium))
                        .foregroundStyle(Theme.displayText)
                }
            }
        }
        .displayPanel(padding: 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(language.map { Text("Detected Language: \($0)") } ?? Text(""))
    }

    private var actionsPanel: some View {
        VStack(spacing: 10) {
            if !segments.isEmpty {
                Button(action: { showTimestampView.toggle() }) {
                    Label(showTimestampView ? "Show Text Only" : "Show with Timestamps", systemImage: showTimestampView ? "text.alignleft" : "clock")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.recorderQuiet)
                .accessibilityIdentifier("resultTimestampToggle")
            }

            HStack(spacing: 10) {
                Button(action: {
                    UIPasteboard.general.string = currentDisplayText()
                    showCopyConfirmation = true
                }) {
                    Label("Copy", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.recorderQuiet)

                Button(action: {
                    sharePayload = .text(currentDisplayText())
                }) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.recorderQuiet)
            }

            Button(action: {
                showExportSheet = true
            }) {
                Label("Export", systemImage: "arrow.down.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.recorderQuiet)
        }
        .recorderPanel(padding: 14)
    }
}

enum ExportSelection: Hashable {
    case audio
    case transcription(ExportFormat)
}

/// 書き出す内容と形式を一度に選ぶ Result/History 共通部品。
struct ExportFormatList: View {
    let includesAudio: Bool
    let includesTranscription: Bool
    let hasTimestampedSegments: Bool
    let onExport: (ExportSelection, Bool) -> Void

    @State private var selection: ExportSelection
    @State private var includeTimestamps = true

    init(
        includesAudio: Bool = false,
        includesTranscription: Bool = true,
        hasTimestampedSegments: Bool,
        onExport: @escaping (ExportSelection, Bool) -> Void
    ) {
        self.includesAudio = includesAudio
        self.includesTranscription = includesTranscription
        self.hasTimestampedSegments = hasTimestampedSegments
        self.onExport = onExport
        _selection = State(
            initialValue: includesTranscription ? .transcription(.txt) : .audio
        )
    }

    private var choices: [ExportSelection] {
        var values: [ExportSelection] = []
        if includesAudio {
            values.append(.audio)
        }
        if includesTranscription {
            values.append(contentsOf: ExportFormat.allCases.map(ExportSelection.transcription))
        }
        return values
    }

    private var showsTimestampOption: Bool {
        selection == .transcription(.txt) && hasTimestampedSegments
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    TechLabel(text: "Select Export Format")
                        .padding(.horizontal, 4)

                    VStack(spacing: 0) {
                        ForEach(Array(choices.enumerated()), id: \.element) { index, choice in
                            if index > 0 {
                                Divider().overlay(Theme.stroke)
                                    .padding(.leading, 58)
                            }

                            Button {
                                selection = choice
                            } label: {
                                ExportOptionRow(
                                    icon: Self.icon(for: choice),
                                    title: Self.title(for: choice),
                                    isSelected: selection == choice
                                )
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                            }
                            .buttonStyle(.plain)
                        }

                        if showsTimestampOption {
                            Divider().overlay(Theme.stroke)
                                .padding(.leading, 58)

                            Toggle("Include Timestamps", isOn: $includeTimestamps)
                                .font(Theme.sans(14, weight: .medium))
                                .foregroundStyle(Theme.textPrimary)
                                .tint(Theme.amberFill)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .accessibilityIdentifier("exportIncludeTimestamps")
                        }
                    }
                    .background(Theme.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Theme.stroke, lineWidth: 1)
                    }
                }
                .padding(16)
            }

            Divider().overlay(Theme.stroke)

            Button {
                onExport(selection, includeTimestamps)
            } label: {
                Label("Export", systemImage: "arrow.down.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.recorderProminent)
            .padding(16)
        }
        .background(Theme.background)
    }

    static func icon(for selection: ExportSelection) -> String {
        switch selection {
        case .audio: return "waveform"
        case .transcription(.txt): return "doc.text"
        case .transcription(.json): return "curlybraces"
        case .transcription(.csv): return "tablecells"
        case .transcription(.srt): return "captions.bubble"
        }
    }

    static func title(for selection: ExportSelection) -> Text {
        switch selection {
        case .audio:
            return Text("Audio File")
        case .transcription(let format):
            return Text(format.displayName)
        }
    }

}

private struct ExportOptionRow: View {
    let icon: String
    let title: Text
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(isSelected ? Theme.amber : Theme.textSecondary)
                .frame(width: 28)

            title
                .font(Theme.sans(15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            Spacer()

            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 19))
                .foregroundStyle(isSelected ? Theme.amber : Theme.textSecondary.opacity(0.5))
        }
        .contentShape(Rectangle())
    }
}

struct ExportSheetView: View {
    let title: String
    let text: String
    let segments: [TranscriptionSegment]
    let duration: Double
    let language: String?
    let onExport: (URL?) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ExportFormatList(
                hasTimestampedSegments: !segments.isEmpty
            ) { selection, includeTimestamps in
                guard case .transcription(let format) = selection else { return }
                let url = TranscriptionExporter.export(
                    title: title.isEmpty ? String(localized: "Export") : title,
                    text: text,
                    duration: duration,
                    segments: segments,
                    language: language,
                    format: format,
                    includeTimestamps: includeTimestamps
                )
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

struct SharePayload: Identifiable {
    enum ActivityItem {
        case text(String)
        case file(URL)
    }

    let id = UUID()
    let item: ActivityItem

    static func text(_ text: String) -> SharePayload {
        SharePayload(item: .text(text))
    }

    static func file(_ url: URL) -> SharePayload {
        SharePayload(item: .file(url))
    }

    var activityItems: [Any] {
        switch item {
        case .text(let text):
            return [text]
        case .file(let url):
            return [url]
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
