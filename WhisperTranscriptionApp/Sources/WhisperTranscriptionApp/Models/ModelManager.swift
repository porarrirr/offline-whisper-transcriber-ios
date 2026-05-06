import Foundation
import SwiftData
import UIKit

@MainActor
class ModelManager: NSObject, ObservableObject {
    static let shared = ModelManager()
    
    @Published var isModelReady = false
    @Published var downloadProgress: Double = 0
    @Published var isDownloading = false
    @Published var downloadError: String?
    @Published var currentModelSize: AppSettings.ModelSize = .base
    @Published var isVADModelReady = false
    @Published var vadDownloadProgress: Double = 0
    @Published var isVADDownloading = false
    @Published var vadDownloadError: String?
    
    private var downloadTask: URLSessionDownloadTask?
    private var vadDownloadTask: URLSessionDownloadTask?
    private var modelDownloadSession: URLSession?
    private var vadDownloadSession: URLSession?
    private let vadModelFileName = "ggml-silero-v6.2.0.bin"
    private let vadModelURL = URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin")!
    
    var modelPath: String {
        modelURL.path
    }

    var vadModelPath: String {
        vadModelFileURL.path
    }
    
    private var modelURL: URL {
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            preconditionFailure("Documents directory is unavailable")
        }
        return documentsPath.appendingPathComponent(currentModelSize.fileName)
    }

    private var vadModelFileURL: URL {
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            preconditionFailure("Documents directory is unavailable")
        }
        return documentsPath.appendingPathComponent(vadModelFileName)
    }
    
    private override init() {
        currentModelSize = AppSettings.shared.selectedModelSize
        super.init()
        checkModelAvailability()
        checkVADModelAvailability()
    }
    
    func checkModelAvailability() {
        let exists = FileManager.default.fileExists(atPath: modelPath)
        DispatchQueue.main.async {
            self.isModelReady = exists
        }
    }

    func checkVADModelAvailability() {
        let exists = FileManager.default.fileExists(atPath: vadModelPath)
        DispatchQueue.main.async {
            self.isVADModelReady = exists
        }
    }
    
    func switchModel(size: AppSettings.ModelSize) {
        currentModelSize = size
        AppSettings.shared.selectedModelSize = size
        checkModelAvailability()
    }
    
    func downloadModel(size: AppSettings.ModelSize? = nil) {
        let targetSize = size ?? currentModelSize
        if let size = size, size != currentModelSize {
            currentModelSize = size
            AppSettings.shared.selectedModelSize = size
        }
        
        guard !isDownloading else { return }
        guard let url = targetSize.downloadURL else {
            setDownloadError("ダウンロードURLが無効です")
            return
        }
        
        isDownloading = true
        downloadProgress = 0
        downloadError = nil
        
        let configuration = URLSessionConfiguration.default
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        modelDownloadSession = session
        
        downloadTask = session.downloadTask(with: url)
        downloadTask?.taskDescription = "mainModel"
        downloadTask?.resume()
    }

    func downloadVADModel() {
        guard !isVADDownloading else { return }

        isVADDownloading = true
        vadDownloadProgress = 0
        vadDownloadError = nil

        let configuration = URLSessionConfiguration.default
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        vadDownloadSession = session

        vadDownloadTask = session.downloadTask(with: vadModelURL)
        vadDownloadTask?.taskDescription = "vadModel"
        vadDownloadTask?.resume()
    }
    
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        downloadProgress = 0
    }

    func cancelVADDownload() {
        vadDownloadTask?.cancel()
        vadDownloadTask = nil
        isVADDownloading = false
        vadDownloadProgress = 0
    }
    
    func getModelSize() -> String? {
        guard FileManager.default.fileExists(atPath: modelPath) else { return nil }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: modelPath)
            if let size = attributes[.size] as? Int64 {
                let formatter = ByteCountFormatter()
                formatter.countStyle = .file
                return formatter.string(fromByteCount: size)
            }
        } catch {
            setDownloadError("モデルサイズの取得に失敗しました: \(error.localizedDescription)")
        }
        return nil
    }
    
    func deleteCurrentModel() {
        if FileManager.default.fileExists(atPath: modelPath) {
            do {
                try FileManager.default.removeItem(atPath: modelPath)
                isModelReady = false
                downloadError = nil
            } catch {
                setDownloadError("モデル削除エラー: \(error.localizedDescription)")
            }
        }
    }

    func deleteVADModel() {
        if FileManager.default.fileExists(atPath: vadModelPath) {
            do {
                try FileManager.default.removeItem(atPath: vadModelPath)
                isVADModelReady = false
                vadDownloadError = nil
            } catch {
                setVADDownloadError("VADモデル削除エラー: \(error.localizedDescription)")
            }
        }
    }
    
    func deleteAllModels() {
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            setDownloadError("モデル保存先を取得できませんでした")
            return
        }
        for size in AppSettings.ModelSize.allCases {
            let path = documentsPath.appendingPathComponent(size.fileName).path
            if FileManager.default.fileExists(atPath: path) {
                do {
                    try FileManager.default.removeItem(atPath: path)
                } catch {
                    setDownloadError("モデル削除エラー: \(error.localizedDescription)")
                    return
                }
            }
        }
        isModelReady = false
    }

    private func setDownloadError(_ message: String) {
        downloadError = message
        AppLogger.error(message, context: "ModelManager")
    }

    private func setVADDownloadError(_ message: String) {
        vadDownloadError = message
        AppLogger.error(message, context: "ModelManager")
    }
}

extension ModelManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        if downloadTask.taskDescription == "vadModel" {
            vadDownloadProgress = progress
        } else {
            downloadProgress = progress
        }
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            let isVADModelDownload = downloadTask.taskDescription == "vadModel"
            let destinationURL = isVADModelDownload ? vadModelFileURL : URL(fileURLWithPath: modelPath)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: location, to: destinationURL)
            if isVADModelDownload {
                isVADModelReady = true
                isVADDownloading = false
                vadDownloadProgress = 1.0
                vadDownloadTask = nil
            } else {
                isModelReady = true
                isDownloading = false
                downloadProgress = 1.0
                self.downloadTask = nil
            }
        } catch {
            if downloadTask.taskDescription == "vadModel" {
                setVADDownloadError("VADモデル保存エラー: \(error.localizedDescription)")
                isVADDownloading = false
            } else {
                setDownloadError("ファイル保存エラー: \(error.localizedDescription)")
                isDownloading = false
            }
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            if task.taskDescription == "vadModel" {
                setVADDownloadError("VADモデルダウンロードエラー: \(error.localizedDescription)")
                isVADDownloading = false
                vadDownloadTask = nil
            } else {
                setDownloadError("ダウンロードエラー: \(error.localizedDescription)")
                isDownloading = false
                downloadTask = nil
            }
        }
    }
}
