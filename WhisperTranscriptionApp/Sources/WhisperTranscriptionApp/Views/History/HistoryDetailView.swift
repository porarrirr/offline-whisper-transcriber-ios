import SwiftUI

struct HistoryDetailView: View {
    let record: TranscriptionRecord
    @ObservedObject var viewModel: HistoryViewModel
    
    @State private var showShareSheet = false
    @State private var showCopyConfirmation = false
    @State private var showDeleteConfirmation = false
    @State private var showExportSheet = false
    @State private var showTimestampView = false
    @State private var shareItems: [Any] = []
    
    private var displayText: String {
        if showTimestampView && !record.segments.isEmpty {
            return record.segments.map { "\($0.formattedTimestamp) \($0.text)" }.joined(separator: "\n")
        }
        return record.text
    }
    
    var body: some View {
        ZStack {
            AppColors.background.ignoresSafeArea()
            
            ScrollView {
                VStack(spacing: 20) {
                    HStack {
                        Label(record.formattedDate, systemImage: "calendar")
                        Spacer()
                        Label("\(Int(record.duration))秒", systemImage: "clock")
                    }
                    .font(AppFonts.caption)
                    .foregroundColor(AppColors.textSecondary)
                    .padding(.horizontal)
                    
                    if let language = record.language {
                        HStack {
                            Image(systemName: "globe")
                                .foregroundColor(AppColors.accent)
                            Text("言語: \(language)")
                                .font(AppFonts.caption)
                                .foregroundColor(AppColors.textSecondary)
                            Spacer()
                        }
                        .padding(.horizontal)
                    }
                    
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "text.quote")
                                .foregroundColor(AppColors.accent)
                            
                            Text(record.displayTitle)
                                .font(AppFonts.headline)
                                .foregroundColor(AppColors.textPrimary)
                            
                            Spacer()
                        }
                        
                        Text(displayText)
                            .font(AppFonts.body)
                            .foregroundColor(AppColors.textPrimary)
                            .lineSpacing(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding()
                    .background(AppColors.cardBackground)
                    .cornerRadius(16)
                    .padding(.horizontal)
                    
                    if !record.segments.isEmpty {
                        Button(action: {
                            showTimestampView.toggle()
                        }) {
                            HStack {
                                Image(systemName: showTimestampView ? "text.alignleft" : "clock")
                                Text(showTimestampView ? "テキストのみ表示" : "タイムスタンプ付きで表示")
                            }
                            .font(AppFonts.callout)
                            .foregroundColor(AppColors.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(AppColors.accent.opacity(0.1))
                            .cornerRadius(12)
                        }
                        .padding(.horizontal)
                    }
                    
                    VStack(spacing: 12) {
                        ActionButton(
                            icon: "doc.on.doc.fill",
                            title: "テキストをコピー",
                            color: AppColors.accent
                        ) {
                            UIPasteboard.general.string = displayText
                            showCopyConfirmation = true
                        }
                        
                        ActionButton(
                            icon: "square.and.arrow.up.fill",
                            title: "テキストを共有",
                            color: AppColors.surface
                        ) {
                            shareItems = [displayText]
                            showShareSheet = true
                        }
                        
                        ActionButton(
                            icon: "arrow.down.doc.fill",
                            title: "エクスポート",
                            color: AppColors.surface
                        ) {
                            showExportSheet = true
                        }
                        
                        ActionButton(
                            icon: record.isFavorite ? "star.slash.fill" : "star.fill",
                            title: record.isFavorite ? "お気に入りから削除" : "お気に入りに追加",
                            color: AppColors.surface
                        ) {
                            viewModel.toggleFavorite(record)
                        }
                        
                        ActionButton(
                            icon: "trash.fill",
                            title: "削除",
                            color: AppColors.warning.opacity(0.2)
                        ) {
                            showDeleteConfirmation = true
                        }
                    }
                    .padding(.horizontal)
                    
                    Spacer(minLength: 40)
                }
                .padding(.vertical)
            }
        }
        .navigationTitle("詳細")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    viewModel.toggleFavorite(record)
                }) {
                    Image(systemName: record.isFavorite ? "star.fill" : "star")
                        .foregroundColor(record.isFavorite ? AppColors.accent : AppColors.textSecondary)
                }
            }
        }
        .alert("削除の確認", isPresented: $showDeleteConfirmation) {
            Button("キャンセル", role: .cancel) {}
            Button("削除", role: .destructive) {
                viewModel.deleteRecord(record)
            }
        } message: {
            Text("この文字起こしを削除してもよろしいですか？")
        }
        .overlay(
            Group {
                if showCopyConfirmation {
                    VStack {
                        Spacer()
                        Text("コピーしました！")
                            .font(AppFonts.callout)
                            .foregroundColor(AppColors.textPrimary)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(AppColors.accent)
                            .cornerRadius(24)
                            .padding(.bottom, 40)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    .animation(.easeInOut(duration: 0.3), value: showCopyConfirmation)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            showCopyConfirmation = false
                        }
                    }
                }
            }
        )
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
        NavigationView {
            ZStack {
                AppColors.background.ignoresSafeArea()
                
                VStack(spacing: 16) {
                    Text("エクスポート形式を選択")
                        .font(AppFonts.headline)
                        .foregroundColor(AppColors.textPrimary)
                        .padding(.top)
                    
                    ForEach(ExportFormat.allCases) { format in
                        Button(action: {
                            let url = viewModel.exportRecord(record, format: format)
                            dismiss()
                            onExport(url)
                        }) {
                            HStack {
                                Image(systemName: iconForFormat(format))
                                    .foregroundColor(AppColors.accent)
                                    .frame(width: 30)
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(format.displayName)
                                        .font(AppFonts.body)
                                        .foregroundColor(AppColors.textPrimary)
                                    Text(extensionForFormat(format))
                                        .font(AppFonts.caption)
                                        .foregroundColor(AppColors.textSecondary)
                                }
                                
                                Spacer()
                                
                                Image(systemName: "chevron.right")
                                    .foregroundColor(AppColors.textSecondary)
                            }
                            .padding()
                            .background(AppColors.cardBackground)
                            .cornerRadius(12)
                        }
                    }
                    
                    Spacer()
                }
                .padding(.horizontal)
            }
            .navigationTitle("エクスポート")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("キャンセル") {
                        dismiss()
                    }
                    .foregroundColor(AppColors.accent)
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
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
