import SwiftUI
import SwiftData

struct HistoryListView: View {
    @StateObject private var viewModel = HistoryViewModel()
    @Environment(\.modelContext) private var modelContext
    
    var body: some View {
        ZStack {
            AppColors.background.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("履歴")
                            .font(AppFonts.largeTitle)
                            .foregroundColor(AppColors.textPrimary)
                        
                        Text("\(viewModel.records.count)件の文字起こし")
                            .font(AppFonts.body)
                            .foregroundColor(AppColors.textSecondary)
                    }
                    
                    Spacer()
                    
                    Button(action: {
                        viewModel.filterFavorite.toggle()
                        viewModel.fetchRecords()
                    }) {
                        Image(systemName: viewModel.filterFavorite ? "star.fill" : "star")
                            .font(.title3)
                            .foregroundColor(viewModel.filterFavorite ? AppColors.accent : AppColors.textSecondary)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 20)
                
                // Search Bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(AppColors.textSecondary)
                    
                    TextField("検索", text: $viewModel.searchText)
                        .foregroundColor(AppColors.textPrimary)
                        .onChange(of: viewModel.searchText) { _, _ in
                            viewModel.scheduleFetchRecords()
                        }
                    
                    if !viewModel.searchText.isEmpty {
                        Button(action: {
                            viewModel.searchText = ""
                            viewModel.fetchRecords()
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(AppColors.textSecondary)
                        }
                    }
                }
                .padding()
                .background(AppColors.cardBackground)
                .cornerRadius(12)
                .padding(.horizontal)
                .padding(.top, 16)
                
                if let error = viewModel.errorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(AppColors.warning)
                        Text(error)
                            .font(AppFonts.callout)
                            .foregroundColor(AppColors.warning)
                    }
                    .padding()
                    .background(AppColors.warning.opacity(0.1))
                    .cornerRadius(12)
                    .padding(.horizontal)
                    .padding(.top, 12)
                }
                
                if viewModel.records.isEmpty {
                    Spacer()
                    
                    VStack(spacing: 16) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 60))
                            .foregroundColor(AppColors.textSecondary.opacity(0.5))
                        
                        Text(viewModel.searchText.isEmpty ? "まだ文字起こしがありません" : "検索結果がありません")
                            .font(AppFonts.headline)
                            .foregroundColor(AppColors.textSecondary)
                    }
                    
                    Spacer()
                } else {
                    List {
                        ForEach(viewModel.records) { record in
                            NavigationLink(destination: HistoryDetailView(record: record, viewModel: viewModel)) {
                                HistoryRow(record: record)
                            }
                            .listRowBackground(AppColors.cardBackground)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                viewModel.deleteRecord(viewModel.records[index])
                            }
                        }
                    }
                    .listStyle(.plain)
                    .background(AppColors.background)
                    .scrollContentBackground(.hidden)
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
                
                Text("\(record.text.count)文字")
                    .font(AppFonts.caption)
                    .foregroundColor(AppColors.accent)
            }
            
            Text(previewText)
                .font(AppFonts.callout)
                .foregroundColor(AppColors.textSecondary)
                .lineLimit(2)
        }
        .padding()
        .background(AppColors.cardBackground)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(AppColors.accent.opacity(0.1), lineWidth: 1)
        )
    }

    private var previewText: String {
        let prefix = record.text.prefix(160)
        return String(prefix) + (prefix.endIndex == record.text.endIndex ? "" : "...")
    }
}
