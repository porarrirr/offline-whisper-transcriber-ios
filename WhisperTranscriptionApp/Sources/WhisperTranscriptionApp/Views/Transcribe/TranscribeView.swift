import SwiftUI
import SwiftData

struct TranscribeView: View {
    @StateObject private var viewModel = TranscribeViewModel()
    @State private var showFileImporter = false
    @State private var selectedFileURL: URL?
    @Environment(\.modelContext) private var modelContext
    
    var body: some View {
        ZStack {
            AppColors.background.ignoresSafeArea()
            
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("文字起こし")
                            .font(AppFonts.largeTitle)
                            .foregroundColor(AppColors.textPrimary)
                        
                        Text("録音またはファイルを選択")
                            .font(AppFonts.body)
                            .foregroundColor(AppColors.textSecondary)
                    }
                    
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 20)
                
                ScrollView {
                    VStack(spacing: 24) {
                        VStack(spacing: 20) {
                            if viewModel.isRecording {
                                WaveformView(audioLevel: viewModel.audioLevel)
                                    .frame(height: 100)
                                    .padding(.horizontal)
                                
                                Text(formatTime(viewModel.recordingDuration))
                                    .font(AppFonts.title2)
                                    .foregroundColor(AppColors.accent)
                                    .monospacedDigit()
                            } else {
                                Image(systemName: "mic.circle.fill")
                                    .font(.system(size: 80))
                                    .foregroundColor(AppColors.accent.opacity(0.3))
                            }
                            
                            RecordingButton(isRecording: $viewModel.isRecording) {
                                if viewModel.isRecording {
                                    viewModel.stopRecordingAndTranscribe(modelContext: modelContext)
                                } else {
                                    viewModel.startRecording()
                                }
                            }
                            .disabled(viewModel.isProcessing)
                            
                            Text(viewModel.isRecording ? "タップして停止" : "タップして録音開始")
                                .font(AppFonts.callout)
                                .foregroundColor(AppColors.textSecondary)
                        }
                        .padding(.vertical, 20)
                        
                        Divider()
                            .background(AppColors.surface)
                            .padding(.horizontal)
                        
                        Button(action: {
                            showFileImporter = true
                        }) {
                            HStack {
                                Image(systemName: "doc.text.fill")
                                    .font(.title2)
                                    .foregroundColor(AppColors.accent)
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("ファイルを選択")
                                        .font(AppFonts.headline)
                                        .foregroundColor(AppColors.textPrimary)
                                    
                                    Text("m4a, wav, mp3, mp4, mov 対応")
                                        .font(AppFonts.caption)
                                        .foregroundColor(AppColors.textSecondary)
                                }
                                
                                Spacer()
                                
                                Image(systemName: "chevron.right")
                                    .foregroundColor(AppColors.textSecondary)
                            }
                            .padding()
                            .background(AppColors.cardBackground)
                            .cornerRadius(16)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(AppColors.accent.opacity(0.2), lineWidth: 1)
                            )
                        }
                        .padding(.horizontal)
                        .disabled(viewModel.isRecording || viewModel.isProcessing)
                        .opacity(viewModel.isRecording || viewModel.isProcessing ? 0.5 : 1)
                        
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
                        }
                        
                        if viewModel.isProcessing {
                            VStack(spacing: 12) {
                                ProgressView(value: viewModel.transcriptionProgress)
                                    .tint(AppColors.accent)
                                    .scaleEffect(x: 1, y: 2)
                                    .padding(.horizontal, 40)
                                
                                Text("文字起こし処理中... \(Int(viewModel.transcriptionProgress * 100))%")
                                    .font(AppFonts.callout)
                                    .foregroundColor(AppColors.textSecondary)
                            }
                            .padding(.vertical, 40)
                        }
                        
                        Spacer(minLength: 40)
                    }
                }
            }
        }
        .sheet(isPresented: $viewModel.showResult) {
            ResultView(
                text: viewModel.transcriptionResult,
                segments: viewModel.transcriptionSegments,
                language: viewModel.transcriptionLanguage
            ) {
                viewModel.reset()
            }
        }
        .sheet(isPresented: $showFileImporter) {
            FileImporter(selectedURL: $selectedFileURL, isPresented: $showFileImporter) { result in
                switch result {
                case .success(let url):
                    viewModel.transcribeFile(url: url, modelContext: modelContext)
                case .failure(let error):
                    viewModel.errorMessage = "ファイル選択エラー: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
