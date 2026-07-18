import Combine
import Foundation
import Network
import Speech
import UIKit

enum SpeechAssetInventoryStatus: String, Codable, Equatable, Sendable {
    case unsupported
    case supported
    case downloading
    case installed
}

enum SpeechAssetNetworkPathStatus: String, Codable, Equatable, Sendable {
    case unknown
    case satisfied
    case unsatisfied
    case requiresConnection
}

struct SpeechAssetNetworkSnapshot: Codable, Equatable, Sendable {
    var status: SpeechAssetNetworkPathStatus
    var interfaces: [String]
    var isConstrained: Bool
    var isExpensive: Bool

    static let unknown = SpeechAssetNetworkSnapshot(
        status: .unknown,
        interfaces: [],
        isConstrained: false,
        isExpensive: false
    )

    init(
        status: SpeechAssetNetworkPathStatus,
        interfaces: [String],
        isConstrained: Bool,
        isExpensive: Bool
    ) {
        self.status = status
        self.interfaces = interfaces
        self.isConstrained = isConstrained
        self.isExpensive = isExpensive
    }

    init(path: NWPath) {
        switch path.status {
        case .satisfied:
            status = .satisfied
        case .unsatisfied:
            status = .unsatisfied
        case .requiresConnection:
            status = .requiresConnection
        @unknown default:
            status = .unknown
        }

        var interfaces: [String] = []
        if path.usesInterfaceType(.wifi) { interfaces.append("wifi") }
        if path.usesInterfaceType(.cellular) { interfaces.append("cellular") }
        if path.usesInterfaceType(.wiredEthernet) { interfaces.append("wiredEthernet") }
        if path.usesInterfaceType(.loopback) { interfaces.append("loopback") }
        if path.usesInterfaceType(.other) { interfaces.append("other") }
        self.interfaces = interfaces
        isConstrained = path.isConstrained
        isExpensive = path.isExpensive
    }
}

struct SpeechAssetProgressSnapshot: Equatable, Sendable {
    let fractionCompleted: Double
    let totalUnitCount: Int64
    let completedUnitCount: Int64
    let isIndeterminate: Bool
    let isFinished: Bool
    let isCancelled: Bool
    let isCancellable: Bool
    let isPaused: Bool
    let isPausable: Bool
    let localizedDescription: String
    let localizedAdditionalDescription: String
    let estimatedTimeRemaining: TimeInterval?
    let throughput: Int?
    let userInfo: [String: String]

    init(_ progress: Progress) {
        fractionCompleted = min(max(progress.fractionCompleted, 0), 1)
        totalUnitCount = progress.totalUnitCount
        completedUnitCount = progress.completedUnitCount
        isIndeterminate = progress.isIndeterminate
        isFinished = progress.isFinished
        isCancelled = progress.isCancelled
        isCancellable = progress.isCancellable
        isPaused = progress.isPaused
        isPausable = progress.isPausable
        localizedDescription = SpeechAssetFailure.safeDescription(
            of: progress.localizedDescription ?? ""
        )
        localizedAdditionalDescription = SpeechAssetFailure.safeDescription(
            of: progress.localizedAdditionalDescription ?? ""
        )
        estimatedTimeRemaining = progress.estimatedTimeRemaining
        throughput = progress.throughput
        userInfo = Self.sanitize(progress.userInfo)
    }

    init(
        fractionCompleted: Double,
        isIndeterminate: Bool = false,
        isFinished: Bool = false,
        isCancelled: Bool = false
    ) {
        self.fractionCompleted = min(max(fractionCompleted, 0), 1)
        totalUnitCount = 0
        completedUnitCount = 0
        self.isIndeterminate = isIndeterminate
        self.isFinished = isFinished
        self.isCancelled = isCancelled
        isCancellable = false
        isPaused = false
        isPausable = false
        localizedDescription = ""
        localizedAdditionalDescription = ""
        estimatedTimeRemaining = nil
        throughput = nil
        userInfo = [:]
    }

    private static func sanitize(_ values: [ProgressUserInfoKey: Any]) -> [String: String] {
        var sanitized: [String: String] = [:]
        for (key, value) in values {
            sanitized[key.rawValue] = SpeechAssetFailure.safeDescription(of: value)
        }
        return sanitized
    }
}

struct SpeechAssetFailure: Equatable, Sendable {
    let domain: String
    let code: Int
    let message: String
    let failureReason: String?
    let recoverySuggestion: String?
    let userInfo: [String: String]

    init(error: Error, recoverySuggestion: String? = nil) {
        let error = error as NSError
        domain = error.domain
        code = error.code
        message = Self.safeString(error.localizedDescription)
        failureReason = error.localizedFailureReason.map(Self.safeString)
        self.recoverySuggestion = (recoverySuggestion ?? error.localizedRecoverySuggestion).map(Self.safeString)

        var sanitized: [String: String] = [:]
        for (key, value) in error.userInfo {
            sanitized[String(describing: key)] = Self.safeDescription(of: value)
        }
        userInfo = sanitized
    }

    init(domain: String, code: Int, message: String, recoverySuggestion: String? = nil) {
        self.domain = domain
        self.code = code
        self.message = message
        failureReason = nil
        self.recoverySuggestion = recoverySuggestion
        userInfo = [:]
    }

    static func safeDescription(of value: Any) -> String {
        switch value {
        case let value as String:
            return safeString(value)
        case let value as NSNumber:
            return value.stringValue
        case let value as Date:
            return ISO8601DateFormatter().string(from: value)
        default:
            return "<\(String(describing: type(of: value)))>"
        }
    }

    private static func safeString(_ value: String) -> String {
        let pathMarkers = ["file://", "/private/", "/var/", "/Users/", "/tmp/"]
        guard !pathMarkers.contains(where: value.contains) else { return "<redacted-path>" }
        return value
    }
}

enum SpeechAssetPresentationState: Equatable, Sendable {
    case checking
    case reserving
    case systemManagedPending
    case downloading(progress: Double)
    case verifying
    case installed
    case offline
    case constrainedNetwork
    case reservationLimitReached(maximum: Int, failure: SpeechAssetFailure?)
    case insufficientStorage(SpeechAssetFailure)
    case unsupported
    case cancelled
    case failed(SpeechAssetFailure)
}

struct SpeechLocaleRecord: Identifiable, Equatable, Sendable {
    let localeIdentifier: String
    let displayName: String
    let isSupported: Bool
    let isInstalled: Bool
    let reservedLocaleIdentifier: String?
    let isSelected: Bool
    let reservedAt: Date?
    let lastUsedAt: Date?

    var id: String { localeIdentifier }
    var locale: AppleSpeechLocale { AppleSpeechLocale(localeIdentifier: localeIdentifier) }
    var isReserved: Bool { reservedLocaleIdentifier != nil }
}

struct SpeechAssetSnapshot: Equatable, Sendable {
    var state: SpeechAssetPresentationState = .checking
    var inventoryStatus: SpeechAssetInventoryStatus?
    var progress: SpeechAssetProgressSnapshot?
    var network: SpeechAssetNetworkSnapshot = .unknown
    var localeRecords: [SpeechLocaleRecord] = []
    var maximumReservedLocales = 0
    var requestedLocaleIdentifier: String?
    var normalizedLocaleIdentifier: String?
    var operationID: UUID?
    var startedAt: Date?
    var lastAttemptError: SpeechAssetFailure?
    var lowPowerModeEnabled = false
    var availableCapacityForImportantUsage: Int64?
    var hasExtendedWait = false
    var isOperationActive = false

    var measuredProgress: Double? {
        guard case .downloading(let progress) = state else { return nil }
        return progress
    }

    var isInstalled: Bool {
        state == .installed
    }

    private var requestedLocaleRecord: SpeechLocaleRecord? {
        guard let identifier = normalizedLocaleIdentifier ?? requestedLocaleIdentifier else { return nil }
        let canonical = SpeechAssetLocaleIdentifier.canonical(identifier)
        return localeRecords.first {
            SpeechAssetLocaleIdentifier.canonical($0.localeIdentifier) == canonical
        }
    }

    var statusTitle: String {
        switch state {
        case .checking where inventoryStatus == .supported:
            return String(localized: "Speech model is not downloaded")
        case .checking:
            return String(localized: "Checking speech model")
        case .reserving:
            return String(localized: "Preparing language")
        case .systemManagedPending:
            return String(localized: "Waiting for iOS model processing")
        case .downloading(let progress):
            return String(format: String(localized: "Downloading speech model %lld%%"), Int64(progress * 100))
        case .verifying:
            return String(localized: "Checking installation completion")
        case .installed where requestedLocaleRecord?.isReserved == false:
            return String(localized: "Speech model downloaded but not retained")
        case .installed:
            return String(localized: "Speech model downloaded")
        case .offline:
            return String(localized: "No network connection")
        case .constrainedNetwork:
            return String(localized: "Network connection is constrained")
        case .reservationLimitReached:
            return String(localized: "Speech language limit reached")
        case .insufficientStorage:
            return String(localized: "Not enough storage")
        case .unsupported:
            return String(localized: "Speech language unavailable")
        case .cancelled:
            return String(localized: "App monitoring cancelled")
        case .failed:
            return String(localized: "Speech model could not be prepared")
        }
    }

    var statusDetail: String {
        switch state {
        case .checking where inventoryStatus == .supported:
            return String(localized: "This model can be downloaded but is not currently installed.")
        case .checking:
            return String(localized: "Checking the model status reported by iOS.")
        case .reserving:
            return String(localized: "Reserving this language for use in this app.")
        case .systemManagedPending:
            if hasExtendedWait {
                return String(localized: "iOS still reports this model as being processed, but no measurable progress is available. Use Recheck or copy diagnostics for more information.")
            }
            return String(localized: "iOS is managing the model request. The public API cannot distinguish active transfer, condition waiting, or automatic retry.")
        case .downloading:
            return String(localized: "This is the processing progress reported by iOS, not a guaranteed byte-transfer percentage.")
        case .verifying:
            return String(localized: "The initial request finished. Waiting for iOS to report that the model is usable.")
        case .installed where requestedLocaleRecord?.isReserved == false:
            return String(localized: "The model exists on this device, but this app has not retained the language. Prepare it before transcription.")
        case .installed:
            return String(localized: "This language can now be used for on-device transcription.")
        case .offline:
            return String(localized: "No network path is currently available. iOS does not reveal whether this is the model request's waiting reason.")
        case .constrainedNetwork:
            return String(localized: "The current path is constrained. iOS does not reveal whether this is delaying the model request.")
        case .reservationLimitReached(let maximum, _):
            return String(format: String(localized: "This device allows this app to retain up to %lld speech languages. Choose one to release."), Int64(maximum))
        case .insufficientStorage(let failure), .failed(let failure):
            return [failure.message, failure.recoverySuggestion].compactMap { $0 }.joined(separator: "\n")
        case .unsupported:
            return String(localized: "This device, language, or SpeechTranscriber configuration is not supported.")
        case .cancelled:
            return String(localized: "The app stopped monitoring this request. Shared processing managed by iOS may continue.")
        }
    }
}

enum SpeechAssetBlockingIssue: Equatable, Sendable {
    case reservationLimit(maximum: Int, failure: SpeechAssetFailure?)
    case insufficientStorage(SpeechAssetFailure)
    case unsupported
    case failed(SpeechAssetFailure)
}

struct SpeechAssetStateEvidence: Equatable, Sendable {
    var inventoryStatus: SpeechAssetInventoryStatus?
    var progress: SpeechAssetProgressSnapshot?
    var network: SpeechAssetNetworkSnapshot
    var blockingIssue: SpeechAssetBlockingIssue?
    var userCancelled: Bool
    var hasActiveRequest: Bool
    var initialAttemptReturnedSuccessfully: Bool
}

enum SpeechAssetStateReducer {
    static func reduce(_ evidence: SpeechAssetStateEvidence) -> SpeechAssetPresentationState {
        if evidence.inventoryStatus == .installed {
            return .installed
        }
        if evidence.inventoryStatus == .unsupported {
            return .unsupported
        }
        if let issue = evidence.blockingIssue {
            switch issue {
            case .reservationLimit(let maximum, let failure):
                return .reservationLimitReached(maximum: maximum, failure: failure)
            case .insufficientStorage(let failure):
                return .insufficientStorage(failure)
            case .unsupported:
                return .unsupported
            case .failed(let failure):
                return .failed(failure)
            }
        }
        if evidence.userCancelled || evidence.progress?.isCancelled == true {
            return .cancelled
        }
        if let progress = evidence.progress,
           !progress.isIndeterminate,
           progress.fractionCompleted > 0,
           progress.fractionCompleted < 1,
           !progress.isFinished {
            return .downloading(progress: progress.fractionCompleted)
        }
        if evidence.initialAttemptReturnedSuccessfully
            || evidence.progress?.isFinished == true
            || (evidence.progress?.fractionCompleted ?? 0) >= 1 {
            return .verifying
        }
        if evidence.network.status == .unsatisfied || evidence.network.status == .requiresConnection {
            return .offline
        }
        if evidence.network.isConstrained {
            return .constrainedNetwork
        }
        if evidence.hasActiveRequest || evidence.inventoryStatus == .downloading {
            return .systemManagedPending
        }
        return .checking
    }
}

protocol SpeechAssetInstalling: AnyObject {
    var progress: Progress { get }
    func downloadAndInstall() async throws
}

protocol SpeechAssetClient {
    var isSpeechTranscriberAvailable: Bool { get }
    var maximumReservedLocales: Int { get }
    func supportedLocales() async -> [Locale]
    func installedLocales() async -> [Locale]
    func reservedLocales() async -> [Locale]
    func normalizedLocale(equivalentTo locale: Locale) async -> Locale?
    func status(for locale: Locale) async -> SpeechAssetInventoryStatus
    func reserve(locale: Locale) async throws -> Bool
    func release(reservedLocale: Locale) async -> Bool
    func installationRequest(for locale: Locale) async throws -> SpeechAssetInstalling?
}

@available(iOS 26.0, *)
private final class SystemSpeechAssetInstallation: SpeechAssetInstalling {
    private let request: AssetInstallationRequest

    init(request: AssetInstallationRequest) {
        self.request = request
    }

    var progress: Progress { request.progress }

    func downloadAndInstall() async throws {
        try await request.downloadAndInstall()
    }
}

@available(iOS 26.0, *)
struct SystemSpeechAssetClient: SpeechAssetClient {
    var isSpeechTranscriberAvailable: Bool { SpeechTranscriber.isAvailable }
    var maximumReservedLocales: Int { AssetInventory.maximumReservedLocales }

    func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }

    func installedLocales() async -> [Locale] {
        await SpeechTranscriber.installedLocales
    }

    func reservedLocales() async -> [Locale] {
        await AssetInventory.reservedLocales
    }

    func normalizedLocale(equivalentTo locale: Locale) async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    }

    func status(for locale: Locale) async -> SpeechAssetInventoryStatus {
        switch await AssetInventory.status(forModules: modules(for: locale)) {
        case .unsupported: return .unsupported
        case .supported: return .supported
        case .downloading: return .downloading
        case .installed: return .installed
        @unknown default: return .unsupported
        }
    }

    func reserve(locale: Locale) async throws -> Bool {
        try await AssetInventory.reserve(locale: locale)
    }

    func release(reservedLocale: Locale) async -> Bool {
        await AssetInventory.release(reservedLocale: reservedLocale)
    }

    func installationRequest(for locale: Locale) async throws -> SpeechAssetInstalling? {
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules(for: locale)) else {
            return nil
        }
        return SystemSpeechAssetInstallation(request: request)
    }

    private func modules(for locale: Locale) -> [any SpeechModule] {
        [
            SpeechTranscriber(locale: locale, preset: .transcription),
            SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription),
        ]
    }
}

private struct SpeechReservationMetadata: Codable, Equatable {
    var reservedAt: Date
    var lastUsedAt: Date?
}

private struct SpeechReservationMetadataStore {
    private static let key = "SpeechAssetCoordinator.reservationMetadata"
    private let defaults: UserDefaults
    private var values: [String: SpeechReservationMetadata]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        values = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([String: SpeechReservationMetadata].self, from: $0) } ?? [:]
    }

    func value(for localeIdentifier: String) -> SpeechReservationMetadata? {
        values[SpeechAssetLocaleIdentifier.canonical(localeIdentifier)]
    }

    mutating func markReserved(_ localeIdentifier: String, at date: Date = Date()) {
        let key = SpeechAssetLocaleIdentifier.canonical(localeIdentifier)
        if values[key] == nil {
            values[key] = SpeechReservationMetadata(reservedAt: date, lastUsedAt: nil)
        }
        persist()
    }

    mutating func markUsed(_ localeIdentifier: String, at date: Date = Date()) {
        let key = SpeechAssetLocaleIdentifier.canonical(localeIdentifier)
        var value = values[key] ?? SpeechReservationMetadata(reservedAt: date, lastUsedAt: nil)
        value.lastUsedAt = date
        values[key] = value
        persist()
    }

    mutating func remove(_ localeIdentifier: String) {
        values.removeValue(forKey: SpeechAssetLocaleIdentifier.canonical(localeIdentifier))
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

enum SpeechAssetLocaleIdentifier {
    static func canonical(_ identifier: String) -> String {
        Locale(identifier: identifier).identifier(.bcp47).lowercased()
    }

    static func canonical(_ locale: Locale) -> String {
        canonical(locale.identifier)
    }
}

@MainActor
final class SpeechAssetCoordinator: ObservableObject {
    static let shared = SpeechAssetCoordinator(client: SpeechAssetCoordinator.makeSystemClient())

    @Published private(set) var snapshot = SpeechAssetSnapshot()

    private static let requestedLocaleKey = "SpeechAssetCoordinator.requestedLocale"
    private static let automaticallyResumeKey = "SpeechAssetCoordinator.automaticallyResume"
    private static let extendedWaitSeconds: TimeInterval = 30

    private let client: SpeechAssetClient?
    private let defaults: UserDefaults
    private var metadataStore: SpeechReservationMetadataStore
    private let pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(label: "SpeechAssetCoordinator.NWPathMonitor")

    private var installTask: Task<Void, Never>?
    private var statusPollingTask: Task<Void, Never>?
    private var extendedWaitTask: Task<Void, Never>?
    private var progressObservations: [NSKeyValueObservation] = []
    private var activeRequest: SpeechAssetInstalling?
    private var normalizedLocale: Locale?
    private var selectedLocaleIdentifier: String?
    private var generation: UInt = 0
    private var userCancelled = false
    private var initialAttemptReturnedSuccessfully = false
    private var blockingIssue: SpeechAssetBlockingIssue?
    private var stateTransitions: [String] = []
    private var didRestorePersistedState = false

    init(
        client: SpeechAssetClient?,
        defaults: UserDefaults = .standard,
        monitorsNetwork: Bool = true
    ) {
        self.client = client
        self.defaults = defaults
        metadataStore = SpeechReservationMetadataStore(defaults: defaults)
        pathMonitor = monitorsNetwork ? NWPathMonitor() : nil
        startNetworkMonitoring()
        refreshLocalSystemContext()
    }

    func restorePersistedState(selectedLocale: AppleSpeechLocale?) {
        guard !didRestorePersistedState else { return }
        didRestorePersistedState = true
        selectedLocaleIdentifier = selectedLocale?.localeIdentifier

        if defaults.bool(forKey: Self.automaticallyResumeKey),
           let identifier = defaults.string(forKey: Self.requestedLocaleKey) {
            prepare(locale: AppleSpeechLocale(localeIdentifier: identifier))
        } else {
            recheck(locale: selectedLocale, clearsCancellation: false, monitorsSystemWork: false)
        }
    }

    func configureSelectedLocale(_ locale: AppleSpeechLocale?) {
        selectedLocaleIdentifier = locale?.localeIdentifier
        recheck(locale: locale)
    }

    func prepare(locale: AppleSpeechLocale) {
        generation &+= 1
        let operationGeneration = generation
        stopLocalMonitoring(cancelReportedProgress: false)

        userCancelled = false
        initialAttemptReturnedSuccessfully = false
        blockingIssue = nil
        normalizedLocale = nil
        selectedLocaleIdentifier = selectedLocaleIdentifier ?? locale.localeIdentifier
        stateTransitions.removeAll(keepingCapacity: true)

        defaults.set(locale.localeIdentifier, forKey: Self.requestedLocaleKey)
        defaults.set(true, forKey: Self.automaticallyResumeKey)

        updateSnapshot { snapshot in
            snapshot = SpeechAssetSnapshot(
                state: .checking,
                network: snapshot.network,
                requestedLocaleIdentifier: locale.localeIdentifier,
                operationID: UUID(),
                startedAt: Date(),
                lowPowerModeEnabled: snapshot.lowPowerModeEnabled,
                availableCapacityForImportantUsage: snapshot.availableCapacityForImportantUsage,
                isOperationActive: true
            )
        }
        recordTransition(to: .checking)

        installTask = Task { [weak self] in
            await self?.performPrepare(locale: locale.locale, generation: operationGeneration)
        }
    }

    func retry() {
        guard let identifier = snapshot.requestedLocaleIdentifier ?? selectedLocaleIdentifier else { return }
        prepare(locale: AppleSpeechLocale(localeIdentifier: identifier))
    }

    func recheck(
        locale: AppleSpeechLocale? = nil,
        clearsCancellation: Bool = true,
        monitorsSystemWork: Bool = true
    ) {
        let targetIdentifier = locale?.localeIdentifier
            ?? snapshot.normalizedLocaleIdentifier
            ?? snapshot.requestedLocaleIdentifier
            ?? selectedLocaleIdentifier
        guard let targetIdentifier else {
            Task { [weak self] in await self?.refreshInventory(selectedLocaleIdentifier: nil) }
            return
        }

        selectedLocaleIdentifier = locale?.localeIdentifier ?? selectedLocaleIdentifier
        if activeRequest == nil, clearsCancellation {
            userCancelled = false
            blockingIssue = nil
            updateSnapshot {
                $0.progress = nil
                $0.hasExtendedWait = false
                $0.isOperationActive = true
                $0.state = .checking
            }
        }
        Task { [weak self] in
            await self?.performRecheck(
                locale: Locale(identifier: targetIdentifier),
                monitorsSystemWork: monitorsSystemWork
            )
        }
    }

    func cancel() {
        generation &+= 1
        userCancelled = true
        defaults.set(false, forKey: Self.automaticallyResumeKey)
        stopLocalMonitoring(cancelReportedProgress: true)
        updateSnapshot {
            $0.state = .cancelled
            $0.isOperationActive = false
        }
        recordTransition(to: .cancelled)
    }

    func release(reservedLocaleIdentifier: String) async -> Bool {
        guard let client else { return false }
        let reservedLocales = await client.reservedLocales()
        guard let actualLocale = reservedLocales.first(where: {
            SpeechAssetLocaleIdentifier.canonical($0) == SpeechAssetLocaleIdentifier.canonical(reservedLocaleIdentifier)
        }) else { return false }

        let normalizedActualLocale = await client.normalizedLocale(equivalentTo: actualLocale) ?? actualLocale
        if snapshot.normalizedLocaleIdentifier.map(SpeechAssetLocaleIdentifier.canonical)
            == SpeechAssetLocaleIdentifier.canonical(normalizedActualLocale) {
            cancel()
        }

        let released = await client.release(reservedLocale: actualLocale)
        if released {
            metadataStore.remove(actualLocale.identifier)
            AppLogger.info(
                "Speech asset reservation released: locale=\(actualLocale.identifier)",
                context: "SpeechAssetCoordinator"
            )
        }
        await refreshInventory(selectedLocaleIdentifier: selectedLocaleIdentifier)
        recheck()
        return released
    }

    func replaceReservation(releasing reservedLocaleIdentifier: String, with locale: AppleSpeechLocale) async -> Bool {
        guard await release(reservedLocaleIdentifier: reservedLocaleIdentifier) else { return false }
        prepare(locale: locale)
        return true
    }

    func isReady(locale: AppleSpeechLocale) async -> Bool {
        guard let client,
              client.isSpeechTranscriberAvailable,
              let normalized = await client.normalizedLocale(equivalentTo: locale.locale) else {
            return false
        }
        let reserved = await matchingReservedLocale(for: normalized, client: client) != nil
        let installed = await client.status(for: normalized) == .installed
        return reserved && installed
    }

    func markUsed(locale: AppleSpeechLocale) {
        metadataStore.markUsed(locale.localeIdentifier)
    }

    func handleBecameActive(selectedLocale: AppleSpeechLocale?) {
        refreshLocalSystemContext()
        if defaults.bool(forKey: Self.automaticallyResumeKey), !snapshot.isOperationActive,
           let identifier = defaults.string(forKey: Self.requestedLocaleKey) {
            prepare(locale: AppleSpeechLocale(localeIdentifier: identifier))
        } else {
            recheck(
                locale: selectedLocale,
                clearsCancellation: false,
                monitorsSystemWork: defaults.bool(forKey: Self.automaticallyResumeKey)
            )
        }
    }

    func diagnosticReport() -> String {
        let formatter = ISO8601DateFormatter()
        let now = Date()
        let elapsed = snapshot.startedAt.map { now.timeIntervalSince($0) }
        let appInfo = Bundle.main.infoDictionary ?? [:]
        let appVersion = appInfo["CFBundleShortVersionString"] as? String ?? "unknown"
        let appBuild = appInfo["CFBundleVersion"] as? String ?? "unknown"
        let sdk = appInfo["DTSDKName"] as? String ?? "unknown"
        let operationID = snapshot.operationID?.uuidString ?? "nil"
        let requestedLocale = snapshot.requestedLocaleIdentifier ?? "nil"
        let normalizedLocale = snapshot.normalizedLocaleIdentifier ?? "nil"
        let reservedLocales = snapshot.localeRecords.filter(\.isReserved)
            .map(\.localeIdentifier).sorted().joined(separator: ",")
        let installedLocales = snapshot.localeRecords.filter(\.isInstalled)
            .map(\.localeIdentifier).sorted().joined(separator: ",")
        let supportedLocales = snapshot.localeRecords.filter(\.isSupported)
            .map(\.localeIdentifier).sorted().joined(separator: ",")
        let inventoryStatus = snapshot.inventoryStatus?.rawValue ?? "nil"
        let networkInterfaces = snapshot.network.interfaces.joined(separator: ",")
        let capacity = snapshot.availableCapacityForImportantUsage.map { String($0) } ?? "nil"
        let elapsedSeconds = elapsed.map { String($0) } ?? "nil"
        let transitions = stateTransitions.joined(separator: " | ")

        var lines = [
            "timestamp=\(formatter.string(from: now))",
            "os=\(ProcessInfo.processInfo.operatingSystemVersionString)",
            "hardwareModel=\(Self.hardwareModelIdentifier())",
            "appVersion=\(appVersion)",
            "appBuild=\(appBuild)",
            "sdk=\(sdk)",
            "operationID=\(operationID)",
            "requestedLocale=\(requestedLocale)",
            "normalizedLocale=\(normalizedLocale)",
            "moduleConfig=transcription,timeIndexedProgressiveTranscription",
            "supportedLocales=\(supportedLocales)",
            "maximumReservedLocales=\(snapshot.maximumReservedLocales)",
            "reservedLocales=\(reservedLocales)",
            "installedLocales=\(installedLocales)",
            "inventoryStatus=\(inventoryStatus)",
            "presentationState=\(String(describing: snapshot.state))",
            "networkStatus=\(snapshot.network.status.rawValue)",
            "networkInterfaces=\(networkInterfaces)",
            "networkConstrained=\(snapshot.network.isConstrained)",
            "networkExpensive=\(snapshot.network.isExpensive)",
            "lowPowerMode=\(snapshot.lowPowerModeEnabled)",
            "applicationState=\(Self.applicationStateDescription())",
            "availableCapacityForImportantUsage=\(capacity)",
            "elapsedSeconds=\(elapsedSeconds)",
            "stateTransitions=\(transitions)",
        ]

        if let progress = snapshot.progress {
            let estimatedTimeRemaining = progress.estimatedTimeRemaining.map { String($0) } ?? "nil"
            let throughput = progress.throughput.map { String($0) } ?? "nil"
            lines += [
                "progress.fractionCompleted=\(progress.fractionCompleted)",
                "progress.totalUnitCount=\(progress.totalUnitCount)",
                "progress.completedUnitCount=\(progress.completedUnitCount)",
                "progress.isIndeterminate=\(progress.isIndeterminate)",
                "progress.isFinished=\(progress.isFinished)",
                "progress.isCancelled=\(progress.isCancelled)",
                "progress.isCancellable=\(progress.isCancellable)",
                "progress.isPaused=\(progress.isPaused)",
                "progress.isPausable=\(progress.isPausable)",
                "progress.estimatedTimeRemaining=\(estimatedTimeRemaining)",
                "progress.throughput=\(throughput)",
                "progress.localizedDescription=\(progress.localizedDescription)",
                "progress.localizedAdditionalDescription=\(progress.localizedAdditionalDescription)",
                "progress.userInfo=\(progress.userInfo)",
            ]
        }

        if let failure = snapshot.lastAttemptError {
            let failureReason = failure.failureReason ?? "nil"
            let recoverySuggestion = failure.recoverySuggestion ?? "nil"
            lines += [
                "error.domain=\(failure.domain)",
                "error.code=\(failure.code)",
                "error.message=\(failure.message)",
                "error.failureReason=\(failureReason)",
                "error.recoverySuggestion=\(recoverySuggestion)",
                "error.userInfo=\(failure.userInfo)",
            ]
        }
        return lines.joined(separator: "\n")
    }

    private func performPrepare(locale: Locale, generation operationGeneration: UInt) async {
        guard let client, client.isSpeechTranscriberAvailable else {
            blockingIssue = .unsupported
            deriveState()
            return
        }

        await refreshInventory(selectedLocaleIdentifier: selectedLocaleIdentifier)
        guard isCurrent(operationGeneration) else { return }

        guard let normalized = await client.normalizedLocale(equivalentTo: locale) else {
            blockingIssue = .unsupported
            deriveState()
            return
        }
        guard isCurrent(operationGeneration) else { return }

        normalizedLocale = normalized
        updateSnapshot { $0.normalizedLocaleIdentifier = normalized.identifier(.bcp47) }

        if await matchingReservedLocale(for: normalized, client: client) == nil {
            let reserved = await client.reservedLocales()
            guard reserved.count < client.maximumReservedLocales else {
                let failure = SpeechAssetFailure(
                    domain: SFSpeechErrorDomain,
                    code: 0,
                    message: String(localized: "The speech language reservation limit has been reached."),
                    recoverySuggestion: String(localized: "Choose a retained language to release, then try again.")
                )
                blockingIssue = .reservationLimit(maximum: client.maximumReservedLocales, failure: failure)
                updateSnapshot { $0.lastAttemptError = failure }
                deriveState()
                return
            }

            setState(.reserving)
            do {
                _ = try await client.reserve(locale: normalized)
                metadataStore.markReserved(normalized.identifier)
                AppLogger.info(
                    "Speech asset locale reserved: locale=\(normalized.identifier)",
                    context: "SpeechAssetCoordinator"
                )
            } catch {
                handleError(error)
                return
            }
            guard isCurrent(operationGeneration) else { return }
            await refreshInventory(selectedLocaleIdentifier: selectedLocaleIdentifier)
        }

        let status = await client.status(for: normalized)
        guard isCurrent(operationGeneration) else { return }
        updateSnapshot { $0.inventoryStatus = status }

        if status == .installed {
            await finishInstalled(locale: normalized)
            return
        }
        if status == .unsupported {
            blockingIssue = .unsupported
            deriveState()
            return
        }

        do {
            guard let request = try await client.installationRequest(for: normalized) else {
                let refreshed = await client.status(for: normalized)
                updateSnapshot { $0.inventoryStatus = refreshed }
                if refreshed == .installed {
                    await finishInstalled(locale: normalized)
                } else {
                    let failure = SpeechAssetFailure(
                        domain: "SpeechAssetCoordinator",
                        code: 1,
                        message: String(localized: "iOS returned no installation request, but the model is not installed."),
                        recoverySuggestion: String(localized: "Recheck the model state or copy diagnostics to report the inconsistency.")
                    )
                    blockingIssue = .failed(failure)
                    updateSnapshot {
                        $0.lastAttemptError = failure
                        $0.isOperationActive = false
                    }
                    deriveState()
                }
                return
            }
            guard isCurrent(operationGeneration) else { return }

            activeRequest = request
            updateSnapshot { $0.progress = SpeechAssetProgressSnapshot(request.progress) }
            observeProgress(request.progress, generation: operationGeneration)
            startStatusPolling(locale: normalized, generation: operationGeneration)
            startExtendedWaitTimer(generation: operationGeneration)
            deriveState()

            do {
                try await request.downloadAndInstall()
                guard isCurrent(operationGeneration) else { return }
                initialAttemptReturnedSuccessfully = true
                let refreshed = await client.status(for: normalized)
                guard isCurrent(operationGeneration) else { return }
                updateSnapshot {
                    $0.inventoryStatus = refreshed
                    $0.progress = SpeechAssetProgressSnapshot(request.progress)
                }
                if refreshed == .installed {
                    await finishInstalled(locale: normalized)
                } else {
                    deriveState()
                }
            } catch is CancellationError {
                return
            } catch {
                guard isCurrent(operationGeneration) else { return }
                let refreshed = await client.status(for: normalized)
                guard isCurrent(operationGeneration) else { return }
                let failure = SpeechAssetFailure(
                    error: error,
                    recoverySuggestion: String(localized: "The initial attempt failed. iOS may retry this request later.")
                )
                updateSnapshot {
                    $0.inventoryStatus = refreshed
                    $0.progress = SpeechAssetProgressSnapshot(request.progress)
                    $0.lastAttemptError = failure
                }
                if refreshed == .downloading {
                    blockingIssue = nil
                    deriveState()
                } else {
                    handleError(error, failure: failure)
                }
            }
        } catch {
            handleError(error)
        }
    }

    private func performRecheck(locale: Locale, monitorsSystemWork: Bool) async {
        guard let client, client.isSpeechTranscriberAvailable else {
            blockingIssue = .unsupported
            deriveState()
            return
        }
        await refreshInventory(selectedLocaleIdentifier: selectedLocaleIdentifier)
        guard let normalized = await client.normalizedLocale(equivalentTo: locale) else {
            blockingIssue = .unsupported
            deriveState()
            return
        }
        normalizedLocale = normalized
        let status = await client.status(for: normalized)
        updateSnapshot {
            $0.normalizedLocaleIdentifier = normalized.identifier(.bcp47)
            $0.inventoryStatus = status
            $0.isOperationActive = monitorsSystemWork && status == .downloading
        }
        if status == .installed {
            metadataStore.markUsed(normalized.identifier)
        }
        deriveState()
        if !monitorsSystemWork {
            updateSnapshot { $0.isOperationActive = false }
        }
        if status == .downloading, activeRequest == nil, monitorsSystemWork {
            startStatusPolling(locale: normalized, generation: generation)
            startExtendedWaitTimer(generation: generation)
        }
    }

    private func observeProgress(_ progress: Progress, generation operationGeneration: UInt) {
        progressObservations.forEach { $0.invalidate() }
        progressObservations = [
            progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] progress, _ in
                Task { @MainActor in self?.acceptProgress(progress, generation: operationGeneration) }
            },
            progress.observe(\.isFinished, options: [.initial, .new]) { [weak self] progress, _ in
                Task { @MainActor in self?.acceptProgress(progress, generation: operationGeneration) }
            },
            progress.observe(\.isCancelled, options: [.initial, .new]) { [weak self] progress, _ in
                Task { @MainActor in self?.acceptProgress(progress, generation: operationGeneration) }
            },
            progress.observe(\.isIndeterminate, options: [.initial, .new]) { [weak self] progress, _ in
                Task { @MainActor in self?.acceptProgress(progress, generation: operationGeneration) }
            },
        ]
    }

    private func acceptProgress(_ progress: Progress, generation operationGeneration: UInt) {
        guard isCurrent(operationGeneration) else { return }
        updateSnapshot { $0.progress = SpeechAssetProgressSnapshot(progress) }
        deriveState()
    }

    private func startStatusPolling(locale: Locale, generation operationGeneration: UInt) {
        statusPollingTask?.cancel()
        statusPollingTask = Task { [weak self] in
            guard let self, let client = self.client else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                guard self.isCurrent(operationGeneration) else { return }
                let status = await client.status(for: locale)
                guard self.isCurrent(operationGeneration) else { return }
                self.updateSnapshot {
                    $0.inventoryStatus = status
                    if let request = self.activeRequest {
                        $0.progress = SpeechAssetProgressSnapshot(request.progress)
                    }
                }
                self.refreshLocalSystemContext()
                self.deriveState()
                if status == .installed {
                    await self.finishInstalled(locale: locale)
                    return
                }
                if status == .unsupported { return }
            }
        }
    }

    private func startExtendedWaitTimer(generation operationGeneration: UInt) {
        extendedWaitTask?.cancel()
        extendedWaitTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.extendedWaitSeconds))
            guard let self, !Task.isCancelled, self.isCurrent(operationGeneration),
                  case .systemManagedPending = self.snapshot.state else { return }
            self.updateSnapshot { $0.hasExtendedWait = true }
        }
    }

    private func finishInstalled(locale: Locale) async {
        defaults.set(false, forKey: Self.automaticallyResumeKey)
        metadataStore.markUsed(locale.identifier)
        blockingIssue = nil
        updateSnapshot {
            $0.inventoryStatus = .installed
            $0.state = .installed
            $0.progress = $0.progress.map { _ in SpeechAssetProgressSnapshot(fractionCompleted: 1, isFinished: true) }
            $0.isOperationActive = false
            $0.hasExtendedWait = false
        }
        recordTransition(to: .installed)
        statusPollingTask?.cancel()
        extendedWaitTask?.cancel()
        await refreshInventory(selectedLocaleIdentifier: selectedLocaleIdentifier)
    }

    private func handleError(_ error: Error, failure: SpeechAssetFailure? = nil) {
        let failure = failure ?? SpeechAssetFailure(error: error)
        updateSnapshot { $0.lastAttemptError = failure }

        switch Self.classify(error) {
        case .reservationLimit:
            blockingIssue = .reservationLimit(maximum: client?.maximumReservedLocales ?? 0, failure: failure)
        case .unsupported:
            blockingIssue = .unsupported
        case .insufficientStorage:
            blockingIssue = .insufficientStorage(failure)
        case .cancelled:
            userCancelled = true
        case .other:
            blockingIssue = .failed(failure)
        }
        deriveState()
    }

    private enum ErrorClassification {
        case reservationLimit
        case unsupported
        case insufficientStorage
        case cancelled
        case other
    }

    private static func classify(_ error: Error) -> ErrorClassification {
        if error is CancellationError { return .cancelled }
        let error = error as NSError
        if error.domain == NSURLErrorDomain, error.code == URLError.cancelled.rawValue {
            return .cancelled
        }
        if #available(iOS 26.0, *),
           error.domain == SFSpeechErrorDomain,
           let code = SFSpeechError.Code(rawValue: error.code) {
            if code == .tooManyAssetLocalesAllocated { return .reservationLimit }
            if code == .cannotAllocateUnsupportedLocale || code == .noModel { return .unsupported }
        }
        if error.domain == NSCocoaErrorDomain,
           error.code == CocoaError.fileWriteOutOfSpace.rawValue {
            return .insufficientStorage
        }
        return .other
    }

    private func deriveState() {
        let next = SpeechAssetStateReducer.reduce(
            SpeechAssetStateEvidence(
                inventoryStatus: snapshot.inventoryStatus,
                progress: snapshot.progress,
                network: snapshot.network,
                blockingIssue: blockingIssue,
                userCancelled: userCancelled,
                hasActiveRequest: activeRequest != nil,
                initialAttemptReturnedSuccessfully: initialAttemptReturnedSuccessfully
            )
        )
        setState(next)
    }

    private func setState(_ state: SpeechAssetPresentationState) {
        guard snapshot.state != state else { return }
        let operationIsActive = isActive(state)
        updateSnapshot {
            $0.state = state
            $0.isOperationActive = operationIsActive
        }
        recordTransition(to: state)
    }

    private func isActive(_ state: SpeechAssetPresentationState) -> Bool {
        switch state {
        case .checking, .reserving, .systemManagedPending, .downloading, .verifying:
            return true
        case .offline, .constrainedNetwork:
            return activeRequest != nil || snapshot.inventoryStatus == .downloading
        case .installed, .reservationLimitReached, .insufficientStorage,
             .unsupported, .cancelled, .failed:
            return false
        }
    }

    private func refreshInventory(selectedLocaleIdentifier: String?) async {
        guard let client else {
            updateSnapshot {
                $0.maximumReservedLocales = 0
                $0.localeRecords = []
            }
            return
        }

        let supported = await client.supportedLocales()
        let installed = await client.installedLocales()
        let reserved = await client.reservedLocales()

        var normalizedReserved: [String: Locale] = [:]
        var normalizedReservedLocales: [String: Locale] = [:]
        for locale in reserved {
            let normalized = await client.normalizedLocale(equivalentTo: locale) ?? locale
            let canonical = SpeechAssetLocaleIdentifier.canonical(normalized)
            normalizedReserved[canonical] = locale
            normalizedReservedLocales[canonical] = normalized
            metadataStore.markReserved(normalized.identifier)
        }
        var installedIdentifiers = Set<String>()
        var normalizedInstalledLocales: [String: Locale] = [:]
        for locale in installed {
            let normalized = await client.normalizedLocale(equivalentTo: locale) ?? locale
            let canonical = SpeechAssetLocaleIdentifier.canonical(normalized)
            installedIdentifiers.insert(canonical)
            normalizedInstalledLocales[canonical] = normalized
        }

        let supportedLocales = AppleSpeechLocale.supportedCases(from: supported)
        let supportedIdentifiers = Set(supportedLocales.map {
            SpeechAssetLocaleIdentifier.canonical($0.localeIdentifier)
        })
        var allLocales: [String: AppleSpeechLocale] = [:]
        for locale in supportedLocales {
            allLocales[SpeechAssetLocaleIdentifier.canonical(locale.localeIdentifier)] = locale
        }
        for (canonical, locale) in normalizedInstalledLocales where allLocales[canonical] == nil {
            allLocales[canonical] = AppleSpeechLocale(locale: locale)
        }
        for (canonical, locale) in normalizedReservedLocales where allLocales[canonical] == nil {
            allLocales[canonical] = AppleSpeechLocale(locale: locale)
        }
        let selectedIdentifier = selectedLocaleIdentifier.map(SpeechAssetLocaleIdentifier.canonical)

        let records = allLocales.values.map { locale -> SpeechLocaleRecord in
            let canonical = SpeechAssetLocaleIdentifier.canonical(locale.localeIdentifier)
            let metadata = metadataStore.value(for: canonical)
            return SpeechLocaleRecord(
                localeIdentifier: locale.localeIdentifier,
                displayName: locale.localizedLocaleName,
                isSupported: supportedIdentifiers.contains(canonical),
                isInstalled: installedIdentifiers.contains(canonical),
                reservedLocaleIdentifier: normalizedReserved[canonical]?.identifier,
                isSelected: canonical == selectedIdentifier,
                reservedAt: metadata?.reservedAt,
                lastUsedAt: metadata?.lastUsedAt
            )
        }.sorted {
            let comparison = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            if comparison == .orderedSame { return $0.localeIdentifier < $1.localeIdentifier }
            return comparison == .orderedAscending
        }

        updateSnapshot {
            $0.maximumReservedLocales = client.maximumReservedLocales
            $0.localeRecords = records
        }
        refreshLocalSystemContext()
    }

    private func matchingReservedLocale(for locale: Locale, client: SpeechAssetClient) async -> Locale? {
        let target = SpeechAssetLocaleIdentifier.canonical(locale)
        for reserved in await client.reservedLocales() {
            let normalized = await client.normalizedLocale(equivalentTo: reserved) ?? reserved
            if SpeechAssetLocaleIdentifier.canonical(normalized) == target {
                return reserved
            }
        }
        return nil
    }

    private func startNetworkMonitoring() {
        guard let pathMonitor else { return }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let network = SpeechAssetNetworkSnapshot(path: path)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateSnapshot { $0.network = network }
                self.deriveState()
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    private func refreshLocalSystemContext() {
        let availableCapacity: Int64? = {
            guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
                return nil
            }
            return try? DiskSpaceChecker.availableBytes(at: documents)
        }()
        updateSnapshot {
            $0.lowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
            $0.availableCapacityForImportantUsage = availableCapacity
        }
    }

    private func stopLocalMonitoring(cancelReportedProgress: Bool) {
        installTask?.cancel()
        installTask = nil
        statusPollingTask?.cancel()
        statusPollingTask = nil
        extendedWaitTask?.cancel()
        extendedWaitTask = nil
        if cancelReportedProgress,
           let progress = activeRequest?.progress,
           progress.isCancellable {
            progress.cancel()
        }
        progressObservations.forEach { $0.invalidate() }
        progressObservations.removeAll()
        activeRequest = nil
        initialAttemptReturnedSuccessfully = false
    }

    private func updateSnapshot(_ update: (inout SpeechAssetSnapshot) -> Void) {
        var value = snapshot
        update(&value)
        snapshot = value
    }

    private func recordTransition(to state: SpeechAssetPresentationState) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = "\(timestamp) \(String(describing: state))"
        stateTransitions.append(entry)
        if stateTransitions.count > 50 {
            stateTransitions.removeFirst(stateTransitions.count - 50)
        }
        let operationID = snapshot.operationID?.uuidString ?? "none"
        let locale = snapshot.normalizedLocaleIdentifier ?? snapshot.requestedLocaleIdentifier ?? "none"
        AppLogger.info(
            "Speech asset state: operation=\(operationID), state=\(String(describing: state)), locale=\(locale)",
            context: "SpeechAssetCoordinator"
        )
    }

    private func isCurrent(_ operationGeneration: UInt) -> Bool {
        generation == operationGeneration
    }

    private static func makeSystemClient() -> SpeechAssetClient? {
        if #available(iOS 26.0, *) {
            return SystemSpeechAssetClient()
        }
        return nil
    }

    private static func hardwareModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }

    private static func applicationStateDescription() -> String {
        switch UIApplication.shared.applicationState {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }
}
