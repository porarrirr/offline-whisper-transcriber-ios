import SwiftUI

struct SettingsView: View {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var modelManager = ModelManager.shared
    
    @State private var showModelDownload = false
    @State private var showDeleteConfirmation = false
    @State private var showLanguagePicker = false
    
    var body: some View {
        ZStack {
            AppColors.background.ignoresSafeArea()
            
            ScrollView {
                VStack(spacing: 24) {
                    // Model Settings
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeader(title: "モデル設定", icon: "cpu")
                        
                        VStack(spacing: 12) {
                            HStack {
                                Text("モデルサイズ")
                                    .font(AppFonts.body)
                                    .foregroundColor(AppColors.textPrimary)
                                Spacer()
                                Text(settings.selectedModelSize.displayName)
                                    .font(AppFonts.callout)
                                    .foregroundColor(AppColors.accent)
                            }
                            
                            Picker("モデルサイズ", selection: $settings.selectedModelSize) {
                                ForEach(AppSettings.ModelSize.allCases) { size in
                                    Text(size.displayName).tag(size)
                                }
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: settings.selectedModelSize) { _, newValue in
                                modelManager.switchModel(size: newValue)
                            }
                            
                            HStack {
                                Image(systemName: modelManager.isModelReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                    .foregroundColor(modelManager.isModelReady ? AppColors.accent : AppColors.warning)
                                Text(modelManager.isModelReady ? "モデル準備完了" : "モデルをダウンロードしてください")
                                    .font(AppFonts.callout)
                                    .foregroundColor(AppColors.textSecondary)
                                Spacer()
                                if let size = modelManager.getModelSize() {
                                    Text(size)
                                        .font(AppFonts.caption)
                                        .foregroundColor(AppColors.textSecondary)
                                }
                            }
                            
                            if !modelManager.isModelReady {
                                Button(action: {
                                    showModelDownload = true
                                }) {
                                    HStack {
                                        Image(systemName: "arrow.down.circle.fill")
                                        Text("\(settings.selectedModelSize.approximateSize) をダウンロード")
                                    }
                                    .font(AppFonts.callout)
                                    .foregroundColor(AppColors.textOnAccent)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(AppColors.accent)
                                    .cornerRadius(12)
                                }
                            }
                            
                            Button(action: {
                                showDeleteConfirmation = true
                            }) {
                                HStack {
                                    Image(systemName: "trash.fill")
                                    Text("モデルを削除")
                                }
                                .font(AppFonts.callout)
                                .foregroundColor(AppColors.warning)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(AppColors.warning.opacity(0.1))
                                .cornerRadius(12)
                            }
                        }
                        .padding()
                        .background(AppColors.cardBackground)
                        .cornerRadius(16)
                    }
                    .padding(.horizontal)
                    
                    // Language Settings
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeader(title: "言語設定", icon: "globe")
                        
                        VStack(spacing: 12) {
                            Button(action: {
                                showLanguagePicker = true
                            }) {
                                HStack {
                                    Text("文字起こし言語")
                                        .font(AppFonts.body)
                                        .foregroundColor(AppColors.textPrimary)
                                    Spacer()
                                    if let language = AppSettings.supportedLanguages.first(where: { $0.code == settings.selectedLanguage }) {
                                        Text(language.name)
                                            .font(AppFonts.callout)
                                            .foregroundColor(AppColors.accent)
                                    }
                                    Image(systemName: "chevron.right")
                                        .foregroundColor(AppColors.textSecondary)
                                }
                            }
                            
                            Toggle(isOn: $settings.translateToEnglish) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("英語に翻訳")
                                        .font(AppFonts.body)
                                        .foregroundColor(AppColors.textPrimary)
                                    Text("文字起こし結果を英語に翻訳します")
                                        .font(AppFonts.caption)
                                        .foregroundColor(AppColors.textSecondary)
                                }
                            }
                            .tint(AppColors.accent)
                        }
                        .padding()
                        .background(AppColors.cardBackground)
                        .cornerRadius(16)
                    }
                    .padding(.horizontal)
                    
                    // Prompt
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeader(title: "プロンプト", icon: "text.bubble")
                        
                        VStack(spacing: 12) {
                            TextEditor(text: $settings.promptText)
                                .font(AppFonts.body)
                                .foregroundColor(AppColors.textPrimary)
                                .frame(minHeight: 80)
                                .padding(8)
                                .background(AppColors.background)
                                .cornerRadius(8)
                            
                            Text("例: 「こんにちは。今日はテクノロジーについて話します。」")
                                .font(AppFonts.caption)
                                .foregroundColor(AppColors.textSecondary)
                        }
                        .padding()
                        .background(AppColors.cardBackground)
                        .cornerRadius(16)
                    }
                    .padding(.horizontal)
                    
                    // Advanced Settings
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeader(title: "詳細設定", icon: "gearshape.2")
                        
                        VStack(spacing: 12) {
                            Toggle(isOn: $settings.useFlashAttention) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Flash Attention")
                                        .font(AppFonts.body)
                                        .foregroundColor(AppColors.textPrimary)
                                    Text("処理速度とメモリ使用量を最適化します")
                                        .font(AppFonts.caption)
                                        .foregroundColor(AppColors.textSecondary)
                                }
                            }
                            .tint(AppColors.accent)
                            
                            Divider().background(AppColors.surface)
                            
                            Toggle(isOn: $settings.useVAD) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("無音部分をスキップ（VAD）")
                                        .font(AppFonts.body)
                                        .foregroundColor(AppColors.textPrimary)
                                    Text("音声がない部分を自動的にスキップします")
                                        .font(AppFonts.caption)
                                        .foregroundColor(AppColors.textSecondary)
                                }
                            }
                            .tint(AppColors.accent)
                            
                            Divider().background(AppColors.surface)
                            
                            Toggle(isOn: $settings.includeTimestamps) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("タイムスタンプを含める")
                                        .font(AppFonts.body)
                                        .foregroundColor(AppColors.textPrimary)
                                    Text("結果にタイムスタンプを含めます")
                                        .font(AppFonts.caption)
                                        .foregroundColor(AppColors.textSecondary)
                                }
                            }
                            .tint(AppColors.accent)
                            
                            Divider().background(AppColors.surface)
                            
                            Toggle(isOn: $settings.keepScreenOn) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("画面をスリープしない")
                                        .font(AppFonts.body)
                                        .foregroundColor(AppColors.textPrimary)
                                    Text("文字起こし中に画面をONに保ちます")
                                        .font(AppFonts.caption)
                                        .foregroundColor(AppColors.textSecondary)
                                }
                            }
                            .tint(AppColors.accent)
                            
                            Divider().background(AppColors.surface)
                            
                            Toggle(isOn: $settings.autoDeleteRecordings) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("録音を自動削除")
                                        .font(AppFonts.body)
                                        .foregroundColor(AppColors.textPrimary)
                                    Text("7日後に録音ファイルを自動削除します")
                                        .font(AppFonts.caption)
                                        .foregroundColor(AppColors.textSecondary)
                                }
                            }
                            .tint(AppColors.accent)
                        }
                        .padding()
                        .background(AppColors.cardBackground)
                        .cornerRadius(16)
                    }
                    .padding(.horizontal)
                    
                    Spacer(minLength: 40)
                }
                .padding(.vertical)
            }
        }
        .navigationTitle("設定")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showModelDownload) {
            ModelDownloadView(isPresentedAsSheet: true)
        }
        .alert("モデルを削除", isPresented: $showDeleteConfirmation) {
            Button("キャンセル", role: .cancel) {}
            Button("削除", role: .destructive) {
                modelManager.deleteCurrentModel()
            }
        } message: {
            Text("現在のモデルを削除しますか？")
        }
        .sheet(isPresented: $showLanguagePicker) {
            LanguagePickerView(selectedLanguage: $settings.selectedLanguage, isPresented: $showLanguagePicker)
        }
    }
}

struct SectionHeader: View {
    let title: String
    let icon: String
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(AppColors.accent)
            Text(title)
                .font(AppFonts.headline)
                .foregroundColor(AppColors.textPrimary)
        }
    }
}

struct LanguagePickerView: View {
    @Binding var selectedLanguage: String
    @Binding var isPresented: Bool
    
    var body: some View {
        NavigationView {
            ZStack {
                AppColors.background.ignoresSafeArea()
                
                List {
                    ForEach(AppSettings.supportedLanguages, id: \.code) { language in
                        Button(action: {
                            selectedLanguage = language.code
                            isPresented = false
                        }) {
                            HStack {
                                Text(language.name)
                                    .font(AppFonts.body)
                                    .foregroundColor(AppColors.textPrimary)
                                Spacer()
                                if selectedLanguage == language.code {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(AppColors.accent)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .background(AppColors.background)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("言語を選択")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完了") {
                        isPresented = false
                    }
                    .foregroundColor(AppColors.accent)
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}
