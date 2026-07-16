import Foundation

enum MetalAccelerationReason: Equatable, Sendable {
    case simulator
    case unvalidatedOperatingSystem(String)
    case encoderMissing
    case encoderInvalid
    case insufficientStorage
    case coreMLLoadFailed

    var description: String {
        switch self {
        case .simulator:
            return String(localized: "Simulator does not use Core ML; Metal acceleration is active.")
        case .unvalidatedOperatingSystem(let version):
            return String(localized: "Core ML is unavailable on iOS \(version); Metal acceleration is active.")
        case .encoderMissing:
            return String(localized: "A verified Core ML encoder is not installed; Metal acceleration is active.")
        case .encoderInvalid:
            return String(localized: "The Core ML encoder could not be verified; Metal acceleration is active.")
        case .insufficientStorage:
            return String(localized: "There is not enough storage for Core ML compilation; Metal acceleration is active.")
        case .coreMLLoadFailed:
            return String(localized: "Core ML model loading failed; this session is using Metal acceleration.")
        }
    }
}

enum WhisperAccelerationMode: Equatable, Sendable {
    case coreML
    case metal(reason: MetalAccelerationReason)

    var usesCoreML: Bool {
        if case .coreML = self { return true }
        return false
    }

    var description: String {
        switch self {
        case .coreML:
            return String(localized: "Core ML acceleration")
        case .metal(let reason):
            return reason.description
        }
    }
}

enum CoreMLCompatibilityPolicy {
    static func accelerationMode(
        operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        isSimulator: Bool = Self.isSimulator,
        hasVerifiedEncoder: Bool
    ) -> WhisperAccelerationMode {
        guard !isSimulator else {
            return .metal(reason: .simulator)
        }

        guard isValidatedOperatingSystem(operatingSystemVersion) else {
            return .metal(reason: .unvalidatedOperatingSystem(versionString(operatingSystemVersion)))
        }

        guard hasVerifiedEncoder else {
            return .metal(reason: .encoderMissing)
        }

        return .coreML
    }

    static func isValidatedOperatingSystem(_ version: OperatingSystemVersion) -> Bool {
        switch version.majorVersion {
        case 17...25:
            return true
        case 26:
            return version.minorVersion <= 3
        default:
            return false
        }
    }

    static var currentOperatingSystemAllowsCoreML: Bool {
        !isSimulator && isValidatedOperatingSystem(ProcessInfo.processInfo.operatingSystemVersion)
    }

    private static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    private static func versionString(_ version: OperatingSystemVersion) -> String {
        "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
