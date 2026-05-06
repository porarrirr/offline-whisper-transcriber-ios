import SwiftUI
import UIKit

struct ResultView: View {
    let text: String
    let segments: [TranscriptionSegment]
    let language: String?
    let onDismiss: () -> Void
    
    @State private var showShareSheet = false
    @State private var showCopyConfirmation = false
    @State private var showExportSheet = false
    @State private var showTimestampView = false
    @State private var shareItems: [Any] = []
    
    @MainActor
    init(text: String, segments: [TranscriptionSegment], language: String?, onDismiss: @escaping () -> Void) {
        self.text = text
        self.segments = segments
        self.language = language
        self.onDismiss = onDismiss
        _showTimestampView = State(initialValue: AppSettings.shared.includeTimestamps && !segments.isEmpty)
    }
    
    private var displayText: String {
        if showTimestampView && !segments.isEmpty {
            return segments.map { "\($0.formattedTimestamp) \($0.text)" }.joined(separator: "\n")
        }
        return text
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                AppColors.background.ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 20) {
                        if let language = language {
                            HStack {
                                Image(systemName: "globe")
                                    .foregroundColor(AppColors.accent)
                                Text("検出言語: \(language)")
                                    .font(AppFonts.callout)
                                    .foregroundColor(AppColors.textSecondary)
                                Spacer()
                            }
                            .padding(.horizontal)
                        }
                        
                        TranscriptionCard(text: displayText, isLoading: false)
                            .padding(.horizontal)
                        
                        if !segments.isEmpty {
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
                                title: "コピー",
                                color: AppColors.accent
                            ) {
                                UIPasteboard.general.string = displayText
                                showCopyConfirmation = true
                            }
                            
                            ActionButton(
                                icon: "square.and.arrow.up.fill",
                                title: "共有",
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
                        }
                        .padding(.horizontal)
                        
                        Spacer(minLength: 40)
                    }
                    .padding(.vertical)
                }
            }
            .navigationTitle("結果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完了") {
                        onDismiss()
                    }
                    .foregroundColor(AppColors.accent)
                }
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
                ExportSheetView(text: text, segments: segments) { url in
                    if let url = url {
                        shareItems = [url]
                        showShareSheet = true
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

struct ExportSheetView: View {
    let text: String
    let segments: [TranscriptionSegment]
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
                            let url = TranscriptionExporter.export(
                                title: "エクスポート",
                                text: text,
                                duration: 0,
                                segments: segments,
                                language: nil,
                                format: format
                            )
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

struct ActionButton: View {
    let icon: String
    let title: String
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 24))
                Text(title)
                    .font(AppFonts.callout)
            }
            .foregroundColor(color == AppColors.accent ? AppColors.textOnAccent : AppColors.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(color)
            .cornerRadius(16)
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
