import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers

struct TranscribeView: View {
    @StateObject private var viewModel = TranscribeViewModel()
    @State private var showFileImporter = false
    @State private var selectedFileURL: URL?
    @State private var selectedVideoItem: PhotosPickerItem?
    @Environment(\.modelContext) private var modelContext
    
    var body: some View {
        ZStack {
            AppColors.background.ignoresSafeArea()
            
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Transcribe")
                            .font(AppFonts.largeTitle)
                            .foregroundColor(AppColors.textPrimary)
                        
                        Text("Record or select a file")
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
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundColor(AppColors.accent.opacity(0.5))
                            }
                            
                            RecordingButton(isRecording: $viewModel.isRecording) {
                                if viewModel.isRecording {
                                    viewModel.stopRecordingAndTranscribe(modelContext: modelContext)
                                } else {
                                    viewModel.startRecording()
                                }
                            }
                            .disabled(viewModel.isProcessing)
                            
                            Text(viewModel.isRecording ? LocalizedStringKey("Tap to Stop") : LocalizedStringKey("Tap to Start Recording"))
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
                                    Text("Select File")
                                        .font(AppFonts.headline)
                                        .foregroundColor(AppColors.textPrimary)
                                    
                                    Text("Supported: audio and video files")
                                        .font(AppFonts.caption)
                                        .foregroundColor(AppColors.textSecondary)
                                }
                                
                                Spacer()
                                
                                Image(systemName: "chevron.right")
                                    .foregroundColor(AppColors.textSecondary)
                            }
                            .padding()
                            .background(.regularMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 4)
                        }
                        .padding(.horizontal)
                        .disabled(viewModel.isRecording || viewModel.isProcessing)
                        .opacity(viewModel.isRecording || viewModel.isProcessing ? 0.5 : 1)

                        PhotosPicker(
                            selection: $selectedVideoItem,
                            matching: .videos,
                            photoLibrary: .shared()
                        ) {
                            HStack {
                                Image(systemName: "photo.on.rectangle.angled")
                                    .font(.title2)
                                    .foregroundColor(AppColors.accent)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Select Video from Photos")
                                        .font(AppFonts.headline)
                                        .foregroundColor(AppColors.textPrimary)

                                    Text("Only the selected video's audio is transcribed")
                                        .font(AppFonts.caption)
                                        .foregroundColor(AppColors.textSecondary)
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .foregroundColor(AppColors.textSecondary)
                            }
                            .padding()
                            .background(.regularMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 4)
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
                                
                                Text("Transcribing... \(Int(viewModel.transcriptionProgress * 100))%")
                                    .font(AppFonts.callout)
                                    .foregroundColor(AppColors.textSecondary)
                            }
                            .padding(.vertical, 40)
                        }
                        
                        LegalDisclaimerFootnote()
                            .padding(.horizontal)

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
                    viewModel.setError(String(localized: "File selection error") + ": \(error.localizedDescription)")
                }
            }
        }
        .onChange(of: selectedVideoItem) { _, newItem in
            Task {
                await handlePickedVideo(newItem)
            }
        }
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    @MainActor
    private func handlePickedVideo(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        defer {
            selectedVideoItem = nil
        }

        do {
            guard let pickedVideo = try await item.loadTransferable(type: PickedVideoFile.self) else {
                viewModel.setError(String(localized: "Video selection error") + ": " + String(localized: "No video file was selected."))
                return
            }
            viewModel.transcribeFile(
                url: pickedVideo.url,
                modelContext: modelContext,
                cleanupAfterProcessing: true
            )
        } catch {
            viewModel.setError(String(localized: "Video selection error") + ": \(error.localizedDescription)")
        }
    }
}

private struct PickedVideoFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { receivedFile in
            let sourceURL = receivedFile.file
            let fileExtension = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
            let destinationURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("picked-video-\(UUID().uuidString)")
                .appendingPathExtension(fileExtension)

            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            return PickedVideoFile(url: destinationURL)
        }
    }
}
