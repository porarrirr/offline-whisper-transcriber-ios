import SwiftUI
import UIKit

struct ResultView: View {
    let title: String
    let text: String
    let segments: [TranscriptionSegment]
    let duration: Double
    let language: String?
    let onDismiss: () -> Void
    
    @State private var showShareSheet = false
    @State private var showCopyConfirmation = false
    @State private var showExportSheet = false
    @State private var showTimestampView = false
    @State private var shareItems: [Any] = []
    
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
            return segments.map { "\($0.formattedTimestamp) \($0.text)" }.joined(separator: "\n")
        }
        return text
    }
    
    var body: some View {
        NavigationStack {
            List {
                if let language = language {
                    Section {
                        HStack {
                            Image(systemName: "globe")
                                .foregroundColor(.accentColor)
                            Text("Detected Language: \(language)")
                        }
                    }
                }
                
                Section {
                    TranscriptionCard(
                        text: text,
                        segments: segments,
                        showTimestamps: showTimestampView,
                        isLoading: false
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                
                Section {
                    if !segments.isEmpty {
                        Button(action: { showTimestampView.toggle() }) {
                            Label(showTimestampView ? "Show Text Only" : "Show with Timestamps", systemImage: showTimestampView ? "text.alignleft" : "clock")
                        }
                    }
                    
                    Button(action: {
                        UIPasteboard.general.string = currentDisplayText()
                        showCopyConfirmation = true
                    }) {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    
                    Button(action: {
                        shareItems = [currentDisplayText()]
                        showShareSheet = true
                    }) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    
                    Button(action: {
                        showExportSheet = true
                    }) {
                        Label("Export", systemImage: "arrow.down.doc")
                    }
                }
                
                Section {
                    LegalDisclaimerFootnote()
                        .listRowBackground(Color.clear)
                }
            }
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
            .sheet(isPresented: $showShareSheet) {
                ShareSheet(activityItems: shareItems)
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
                        shareItems = [url]
                        showShareSheet = true
                    }
                }
            }
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
            List {
                Section(header: Text("Select Export Format")) {
                    ForEach(ExportFormat.allCases) { format in
                        Button(action: {
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

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
