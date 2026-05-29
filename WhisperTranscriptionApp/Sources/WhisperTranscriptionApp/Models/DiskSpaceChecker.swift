import Foundation

enum DiskSpaceError: LocalizedError {
    case unavailable
    case insufficient(required: Int64, available: Int64)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return String(localized: "Unable to check available storage. Please try again later.")
        case .insufficient(let required, let available):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            let requiredText = formatter.string(fromByteCount: required)
            let availableText = formatter.string(fromByteCount: available)
            return String(
                format: String(
                    localized: "Not enough storage. About %@ is required but only %@ is available. Free up space and try again."
                ),
                requiredText,
                availableText
            )
        }
    }
}

enum DiskSpaceChecker {
    private static let resourceKeys: Set<URLResourceKey> = [
        .volumeAvailableCapacityForImportantUsageKey
    ]

    static func availableBytes(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: resourceKeys)
        guard let available = values.volumeAvailableCapacityForImportantUsage else {
            throw DiskSpaceError.unavailable
        }
        return available
    }

    static func ensureAvailable(at url: URL, requiredBytes: Int64) throws {
        let available = try availableBytes(at: url)
        guard available >= requiredBytes else {
            throw DiskSpaceError.insufficient(required: requiredBytes, available: available)
        }
    }
}
