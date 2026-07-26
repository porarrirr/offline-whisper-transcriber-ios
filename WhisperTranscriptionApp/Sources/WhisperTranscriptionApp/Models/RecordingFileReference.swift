import Foundation

enum RecordingFileReferenceError: LocalizedError {
    case documentsDirectoryUnavailable
    case fileOutsideRecordingsDirectory
    case invalidStoredPath

    var errorDescription: String? {
        switch self {
        case .documentsDirectoryUnavailable:
            return String(localized: "Could not retrieve document directory for saved recordings.")
        case .fileOutsideRecordingsDirectory:
            return "The audio file is outside the app's recordings directory."
        case .invalidStoredPath:
            return "The stored audio file reference is invalid."
        }
    }
}

struct RecordingFileReference {
    static let directoryName = "Recordings"

    static func storedPath(
        for fileURL: URL,
        recordingsDirectory: URL? = nil
    ) throws -> String {
        let directoryURL = try resolvedRecordingsDirectory(recordingsDirectory)
            .standardizedFileURL
        let standardizedFileURL = fileURL.standardizedFileURL

        guard standardizedFileURL.deletingLastPathComponent().path == directoryURL.path,
              isValidFileName(standardizedFileURL.lastPathComponent) else {
            throw RecordingFileReferenceError.fileOutsideRecordingsDirectory
        }

        return "\(directoryName)/\(standardizedFileURL.lastPathComponent)"
    }

    static func fileURL(
        for storedPath: String,
        recordingsDirectory: URL? = nil
    ) throws -> URL {
        if storedPath.hasPrefix("/") {
            return URL(fileURLWithPath: storedPath).standardizedFileURL
        }

        let components = storedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2,
              components[0] == Substring(directoryName),
              isValidFileName(String(components[1])) else {
            throw RecordingFileReferenceError.invalidStoredPath
        }

        return try resolvedRecordingsDirectory(recordingsDirectory)
            .appendingPathComponent(String(components[1]), isDirectory: false)
            .standardizedFileURL
    }

    static func migratedStoredPath(
        from legacyPath: String,
        recordingsDirectory: URL? = nil
    ) throws -> String? {
        guard legacyPath.hasPrefix("/") else { return nil }

        let legacyURL = URL(fileURLWithPath: legacyPath).standardizedFileURL
        guard legacyURL.deletingLastPathComponent().lastPathComponent == directoryName,
              isValidFileName(legacyURL.lastPathComponent) else {
            return nil
        }

        let currentURL = try resolvedRecordingsDirectory(recordingsDirectory)
            .appendingPathComponent(legacyURL.lastPathComponent, isDirectory: false)
        return try storedPath(for: currentURL, recordingsDirectory: recordingsDirectory)
    }

    private static func resolvedRecordingsDirectory(_ override: URL?) throws -> URL {
        if let override {
            return override
        }
        guard let documentsDirectory = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            throw RecordingFileReferenceError.documentsDirectoryUnavailable
        }
        return documentsDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    private static func isValidFileName(_ fileName: String) -> Bool {
        !fileName.isEmpty
            && fileName != "."
            && fileName != ".."
            && !fileName.contains("/")
            && !fileName.contains("\\")
    }
}
