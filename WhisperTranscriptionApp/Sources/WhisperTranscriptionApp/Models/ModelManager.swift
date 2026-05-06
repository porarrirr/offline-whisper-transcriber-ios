import Foundation

@MainActor
class ModelManager: NSObject, ObservableObject {
    static let shared = ModelManager()
    
    @Published var isModelReady = false
    @Published var downloadProgress: Double = 0
    @Published var isDownloading = false
    @Published var downloadError: String?
    @Published var currentModelSize: AppSettings.ModelSize = .base
    
    private var downloadTask: URLSessionDownloadTask?
    
    var modelPath: String {
        modelURL.path
    }
    
    private var modelURL: URL {
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            preconditionFailure("Documents directory is unavailable")
        }
        return documentsPath.appendingPathComponent(currentModelSize.fileName)
    }
    
    private override init() {
        currentModelSize = AppSettings.shared.selectedModelSize
        super.init()
        checkModelAvailability()
    }
    
    func checkModelAvailability() {
        let exists = FileManager.default.fileExists(atPath: modelPath)
        DispatchQueue.main.async {
            self.isModelReady = exists
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
            downloadError = "ダウンロードURLが無効です"
            return
        }
        
        isDownloading = true
        downloadProgress = 0
        downloadError = nil
        
        let configuration = URLSessionConfiguration.default
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        
        downloadTask = session.downloadTask(with: url)
        downloadTask?.resume()
    }
    
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        downloadProgress = 0
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
            downloadError = "モデルサイズの取得に失敗しました: \(error.localizedDescription)"
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
                downloadError = "モデル削除エラー: \(error.localizedDescription)"
            }
        }
    }
    
    func deleteAllModels() {
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            downloadError = "モデル保存先を取得できませんでした"
            return
        }
        for size in AppSettings.ModelSize.allCases {
            let path = documentsPath.appendingPathComponent(size.fileName).path
            if FileManager.default.fileExists(atPath: path) {
                do {
                    try FileManager.default.removeItem(atPath: path)
                } catch {
                    downloadError = "モデル削除エラー: \(error.localizedDescription)"
                    return
                }
            }
        }
        isModelReady = false
    }
}

extension ModelManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        downloadProgress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            let destinationURL = URL(fileURLWithPath: modelPath)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: location, to: destinationURL)
            isModelReady = true
            isDownloading = false
            downloadProgress = 1.0
        } catch {
            downloadError = "ファイル保存エラー: \(error.localizedDescription)"
            isDownloading = false
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            downloadError = "ダウンロードエラー: \(error.localizedDescription)"
            isDownloading = false
        }
    }
}
