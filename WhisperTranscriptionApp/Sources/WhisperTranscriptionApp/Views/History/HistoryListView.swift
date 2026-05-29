import SwiftUI
import SwiftData

struct HistoryListView: View {
    @StateObject private var viewModel = HistoryViewModel()
    @Environment(\.modelContext) private var modelContext
    
    var body: some View {
        List {
            if let error = viewModel.errorMessage {
                Section {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(AppColors.warning)
                        Text(error)
                            .font(AppFonts.callout)
                            .foregroundColor(AppColors.warning)
                    }
                }
            }

            if !viewModel.availableTags.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(viewModel.availableTags, id: \.self) { tag in
                                Button {
                                    viewModel.toggleTagFilter(tag)
                                } label: {
                                    TagPillLabel(
                                        tag: tag,
                                        isSelected: viewModel.selectedTag == tag
                                    )
                                }
                                .buttonStyle(.plain)
                            }

                            if viewModel.selectedTag != nil {
                                Button {
                                    viewModel.clearTagFilter()
                                } label: {
                                    Label("Clear Tag Filter", systemImage: "xmark.circle.fill")
                                        .font(AppFonts.caption)
                                        .foregroundColor(AppColors.textSecondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 0))
                } header: {
                    Text("Tags")
                }
            }
            
            if viewModel.records.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 60))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundColor(AppColors.textSecondary.opacity(0.5))
                    
                    Text(viewModel.searchText.isEmpty ? LocalizedStringKey("No transcriptions yet") : LocalizedStringKey("No search results"))
                        .font(AppFonts.headline)
                        .foregroundColor(AppColors.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
                .listRowBackground(Color.clear)
            } else {
                ForEach(viewModel.records) { record in
                    NavigationLink(destination: HistoryDetailView(record: record, viewModel: viewModel)) {
                        HistoryRow(record: record)
                    }
                }
                .onDelete { indexSet in
                    let recordsToDelete = indexSet.map { viewModel.records[$0] }
                    viewModel.deleteRecords(recordsToDelete)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("History")
        .searchable(text: $viewModel.searchText, prompt: "Search title, text, or tags")
        .onChange(of: viewModel.searchText) { _, _ in
            viewModel.scheduleFetchRecords()
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    viewModel.filterFavorite.toggle()
                    viewModel.fetchRecords()
                }) {
                    Image(systemName: viewModel.filterFavorite ? "star.fill" : "star")
                        .foregroundColor(viewModel.filterFavorite ? AppColors.accent : AppColors.textSecondary)
                }
            }
            ToolbarItem(placement: .navigationBarLeading) {
                Text("\(viewModel.records.count) Records")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .onAppear {
            viewModel.setModelContext(modelContext)
        }
    }
}

struct HistoryRow: View {
    let record: TranscriptionRecord
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(record.displayTitle)
                    .font(AppFonts.headline)
                    .foregroundColor(AppColors.textPrimary)
                    .lineLimit(1)
                
                Spacer()
                
                if record.isFavorite {
                    Image(systemName: "star.fill")
                        .foregroundColor(AppColors.accent)
                        .font(.caption)
                }
            }
            
            HStack {
                Image(systemName: record.sourceTypeEnum == .recording ? "mic.fill" : "doc.fill")
                    .font(.caption2)
                    .foregroundColor(AppColors.textSecondary)
                
                Text(record.formattedDate)
                    .font(AppFonts.caption)
                    .foregroundColor(AppColors.textSecondary)
                
                Spacer()
                
                Text("\(record.text.count) characters")
                    .font(AppFonts.caption)
                    .foregroundColor(AppColors.accent)
            }
            
            Text(previewText)
                .font(AppFonts.callout)
                .foregroundColor(AppColors.textSecondary)
                .lineLimit(2)

            if !record.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(record.tags.prefix(3)), id: \.self) { tag in
                        TagPillLabel(tag: tag, isSelected: false)
                    }

                    if record.tags.count > 3 {
                        Text("+\(record.tags.count - 3)")
                            .font(AppFonts.caption)
                            .foregroundColor(AppColors.textSecondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var previewText: String {
        let prefix = record.text.prefix(160)
        return String(prefix) + (prefix.endIndex == record.text.endIndex ? "" : "...")
    }
}

struct TagPillLabel: View {
    let tag: String
    let isSelected: Bool

    var body: some View {
        Label(tag, systemImage: "tag.fill")
            .font(AppFonts.caption)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundColor(isSelected ? AppColors.textOnAccent : AppColors.textSecondary)
            .background(isSelected ? AppColors.accent : AppColors.surface, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(AppColors.textSecondary.opacity(isSelected ? 0 : 0.25), lineWidth: 1)
            }
    }
}
