import SwiftUI
import UIKit

struct HistoryDetailView: View {
    let record: TranscriptionRecord
    @ObservedObject var viewModel: HistoryViewModel
    
    @State private var showShareSheet = false
    @State private var showCopyConfirmation = false
    @State private var showDeleteConfirmation = false
    @State private var showExportSheet = false
    @State private var showTimestampView = false
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
            
            Section {
                if !cachedSegments.isEmpty {
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
                
                Button(action: {
                    shareItems = [currentDisplayText()]
                    showShareSheet = true
                }) {
                    Label("Share Text", systemImage: "square.and.arrow.up")
                }
                
                Button(action: {
                    showExportSheet = true
                }) {
                    Label("Export", systemImage: "arrow.down.doc")
                }
                
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
