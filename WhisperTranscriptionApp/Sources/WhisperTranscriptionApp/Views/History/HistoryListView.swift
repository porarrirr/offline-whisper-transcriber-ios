import SwiftUI
import SwiftData

struct HistoryListView: View {
    @StateObject private var viewModel = HistoryViewModel()
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        List {
            if let error = viewModel.errorMessage {
                WarningStrip(message: error)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if !viewModel.records.isEmpty {
                Text("\(viewModel.records.count) Records")
                    .font(Theme.mono(11, weight: .semibold))
                    .tracking(1.2)
                    .foregroundColor(Theme.textSecondary)
                    .listRowInsets(EdgeInsets(top: 2, leading: 20, bottom: 2, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if !viewModel.availableTags.isEmpty {
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
                                    .font(Theme.sans(12))
                                    .foregroundColor(Theme.textSecondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 2)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if viewModel.records.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "waveform.slash")
                        .font(.system(size: 44, weight: .light))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundColor(Theme.textSecondary.opacity(0.6))

                    Text(viewModel.searchText.isEmpty ? LocalizedStringKey("No transcriptions yet") : LocalizedStringKey("No search results"))
                        .font(Theme.mono(13, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 70)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(viewModel.records) { record in
                    ZStack {
                        NavigationLink(destination: HistoryDetailView(record: record, viewModel: viewModel)) {
                            EmptyView()
                        }
                        .opacity(0)

                        HistoryRow(record: record)
                    }
                    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                .onDelete { indexSet in
                    let recordsToDelete = indexSet.map { viewModel.records[$0] }
                    viewModel.deleteRecords(recordsToDelete)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
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
                        .foregroundColor(viewModel.filterFavorite ? Theme.amber : Theme.textSecondary)
                }
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
        let tags = record.tags
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(record.displayTitle)
                    .font(Theme.sans(15, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if record.isFavorite {
                    Image(systemName: "star.fill")
                        .foregroundColor(Theme.amber)
                        .font(.system(size: 11))
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textSecondary.opacity(0.5))
            }

            HStack(spacing: 6) {
                Image(systemName: record.sourceTypeEnum == .recording ? "mic.fill" : "doc.fill")
                    .font(.system(size: 9))
                    .foregroundColor(Theme.amber)

                Text(record.formattedDate)
                    .font(Theme.mono(11, weight: .medium))
                    .foregroundColor(Theme.textSecondary)

                Spacer()

                Text("\(record.text.count) characters")
                    .font(Theme.mono(11, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
            }

            if !previewText.isEmpty {
                Text(previewText)
                    .font(Theme.sans(13))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(2)
                    .lineSpacing(3)
            }

            if !tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(tags.prefix(3)), id: \.self) { tag in
                        TagPillLabel(tag: tag, isSelected: false)
                    }

                    if tags.count > 3 {
                        Text("+\(tags.count - 3)")
                            .font(Theme.mono(11))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
            }
        }
        .recorderPanel(padding: 14)
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
            .font(Theme.mono(11, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundColor(isSelected ? Theme.onAmber : Theme.textSecondary)
            .background(isSelected ? Theme.amberFill : Theme.panelInset, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(isSelected ? Color.clear : Theme.stroke, lineWidth: 1)
            }
    }
}
