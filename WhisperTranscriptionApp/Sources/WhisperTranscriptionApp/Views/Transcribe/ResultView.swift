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
            ScrollView {
                VStack(spacing: 14) {
                    metaDisplay

                    TranscriptionCard(
                        text: text,
                        segments: segments,
                        showTimestamps: showTimestampView,
                        isLoading: false
                    )

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

/// エクスポート形式の選択リスト(Result/Historyの共通部品)
struct ExportFormatList: View {
    let onSelect: (ExportFormat) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                TechLabel(text: "Select Export Format")
                    .padding(.horizontal, 4)

                VStack(spacing: 0) {
                    ForEach(Array(ExportFormat.allCases.enumerated()), id: \.element) { index, format in
                        if index > 0 {
                            Divider().overlay(Theme.stroke)
                                .padding(.leading, 62)
                        }

                        Button {
                            onSelect(format)
                        } label: {
                            RecorderActionRow(
                                icon: Self.icon(for: format),
                                title: Text(format.displayName),
                                subtitle: Text(verbatim: ".\(format.fileExtension)")
                            )
                            .padding(14)
                        }
                        .buttonStyle(.plain)
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
        .background(Theme.background)
    }

    static func icon(for format: ExportFormat) -> String {
        switch format {
        case .txt: return "doc.text"
        case .json: return "curlybraces"
        case .csv: return "tablecells"
        case .srt: return "captions.bubble"
        }
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
            ExportFormatList { format in
                let url = TranscriptionExporter.export(
                    title: title.isEmpty ? String(localized: "Export") : title,
                    text: text,
                    duration: duration,
                    segments: segments,
                    language: language,
                    format: format
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
