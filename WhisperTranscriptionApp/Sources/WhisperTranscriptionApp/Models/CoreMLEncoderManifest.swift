import CryptoKit
import Foundation

struct CoreMLEncoderArtifact: Codable, Equatable, Sendable {
    let modelID: String
    let url: URL
    let sha256: String
    let archiveBytes: Int64
    let installedBytes: Int64
    let aotHeadroomBytes: Int64

    var requiredInstallationBytes: Int64 {
        archiveBytes + installedBytes + aotHeadroomBytes
    }
}

struct CoreMLEncoderManifest: Codable, Sendable {
    let version: String
    let releaseTag: String
    let toolchain: [String: String]
    let models: [CoreMLEncoderArtifact]

    static let current: CoreMLEncoderManifest = {
        guard let url = Bundle.main.url(forResource: "CoreMLEncoderManifest", withExtension: "json") else {
            AppLogger.error("Core ML encoder manifest is missing", context: "CoreMLEncoderManifest")
            return CoreMLEncoderManifest(version: "unavailable", releaseTag: "", toolchain: [:], models: [])
        }
        do {
            return try JSONDecoder().decode(CoreMLEncoderManifest.self, from: Data(contentsOf: url))
        } catch {
            AppLogger.error("Core ML encoder manifest is invalid", context: "CoreMLEncoderManifest", error: error)
            return CoreMLEncoderManifest(version: "unavailable", releaseTag: "", toolchain: [:], models: [])
        }
    }()

    func artifact(for modelID: String) -> CoreMLEncoderArtifact? {
        models.first { $0.modelID == modelID && $0.sha256.count == 64 }
    }
}

enum CoreMLEncoderVerifier {
    enum VerificationError: LocalizedError {
        case checksumMismatch
        case sizeMismatch(expected: Int64, actual: Int64)
        case incompleteModel

        var errorDescription: String? {
            switch self {
            case .checksumMismatch:
                return String(localized: "The Core ML encoder checksum does not match the release manifest.")
            case .sizeMismatch(let expected, let actual):
                return String(localized: "The Core ML encoder size is invalid (expected \(expected) bytes, received \(actual) bytes).")
            case .incompleteModel:
                return String(localized: "The Core ML encoder package is incomplete.")
            }
        }
    }

    static func verifyArchive(at url: URL, expectedSHA256: String, expectedBytes: Int64) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        let actualBytes = Int64(values.fileSize ?? -1)
        guard actualBytes == expectedBytes else {
            throw VerificationError.sizeMismatch(expected: expectedBytes, actual: actualBytes)
        }
        guard try sha256(of: url).caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
            throw VerificationError.checksumMismatch
        }
    }

    static func verifyInstalledModel(at url: URL, expectedSHA256: String) -> Bool {
        let fileManager = FileManager.default
        let markerURL = url.appendingPathComponent("artifact.sha256")
        guard let marker = try? String(contentsOf: markerURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              marker.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
            return false
        }

        let metadataExists = fileManager.fileExists(atPath: url.appendingPathComponent("metadata.json").path)
        let modelExists = fileManager.fileExists(atPath: url.appendingPathComponent("model.mil").path)
            || fileManager.fileExists(atPath: url.appendingPathComponent("model.espresso.net").path)
        let weightsExists = fileManager.fileExists(atPath: url.appendingPathComponent("weights").path)
            || fileManager.fileExists(atPath: url.appendingPathComponent("model.espresso.weights").path)
        return metadataExists && modelExists && weightsExists
    }

    static func markInstalledModel(at url: URL, sha256: String, expectedBytes: Int64) throws {
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("metadata.json").path) else {
            throw VerificationError.incompleteModel
        }
        let actualBytes = try installedByteCount(at: url)
        guard actualBytes == expectedBytes else {
            throw VerificationError.sizeMismatch(expected: expectedBytes, actual: actualBytes)
        }
        try (sha256 + "\n").write(
            to: url.appendingPathComponent("artifact.sha256"),
            atomically: true,
            encoding: .utf8
        )
        guard verifyInstalledModel(at: url, expectedSHA256: sha256) else {
            throw VerificationError.incompleteModel
        }
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func installedByteCount(at rootURL: URL) throws -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else {
            throw VerificationError.incompleteModel
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }
}
