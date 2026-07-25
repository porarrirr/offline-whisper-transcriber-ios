@preconcurrency import AVFoundation
import Foundation

enum ImportedAudioStoreError: LocalizedError {
    case documentsDirectoryUnavailable
    case missingAudioTrack
    case exportSessionUnavailable
    case exportFailed(String)
    case exportCancelled
    case outputMissing

    var errorDescription: String? {
        switch self {
        case .documentsDirectoryUnavailable:
            return String(localized: "The app's recordings directory is unavailable.")
        case .missingAudioTrack:
            return String(localized: "The selected file does not contain an audio track.")
        case .exportSessionUnavailable:
            return String(localized: "The selected audio cannot be saved as M4A.")
        case .exportFailed(let detail):
            return String(localized: "Failed to save imported audio") + ": \(detail)"
        case .exportCancelled:
            return String(localized: "Saving imported audio was cancelled.")
        case .outputMissing:
            return String(localized: "Imported audio was not saved correctly.")
        }
    }
}

actor ImportedAudioStore {
    static let shared = ImportedAudioStore()

    func persistAudio(from sourceURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw ImportedAudioStoreError.missingAudioTrack
        }

        let outputURL = try makeOutputURL()
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw ImportedAudioStoreError.exportSessionUnavailable
        }
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        exportSession.shouldOptimizeForNetworkUse = false

        do {
            try await export(exportSession)
            guard FileManager.default.fileExists(atPath: outputURL.path),
                  let size = try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber,
                  size.int64Value > 0 else {
                throw ImportedAudioStoreError.outputMissing
            }
            return outputURL
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    func removePersistedAudio(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            AppLogger.error(
                "Failed to remove persisted imported audio",
                context: "ImportedAudioStore",
                error: error
            )
        }
    }

    private func makeOutputURL() throws -> URL {
        guard let documentsDirectory = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            throw ImportedAudioStoreError.documentsDirectoryUnavailable
        }
        let recordingsDirectory = documentsDirectory.appendingPathComponent(
            "Recordings",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: recordingsDirectory,
            withIntermediateDirectories: true
        )
        return recordingsDirectory
            .appendingPathComponent("imported_\(UUID().uuidString)")
            .appendingPathExtension("m4a")
    }

    private func export(_ exportSession: AVAssetExportSession) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                exportSession.exportAsynchronously {
                    switch exportSession.status {
                    case .completed:
                        continuation.resume()
                    case .cancelled:
                        continuation.resume(throwing: ImportedAudioStoreError.exportCancelled)
                    case .failed:
                        continuation.resume(
                            throwing: ImportedAudioStoreError.exportFailed(
                                exportSession.error?.localizedDescription
                                    ?? String(localized: "Unknown export error")
                            )
                        )
                    default:
                        continuation.resume(
                            throwing: ImportedAudioStoreError.exportFailed(
                                String(localized: "Audio export ended unexpectedly.")
                            )
                        )
                    }
                }
            }
        } onCancel: {
            exportSession.cancelExport()
        }
    }
}
