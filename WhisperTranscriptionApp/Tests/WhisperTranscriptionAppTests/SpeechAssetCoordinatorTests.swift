import Foundation
import XCTest
@testable import WhisperTranscriptionApp

final class SpeechAssetStateReducerTests: XCTestCase {
    private let online = SpeechAssetNetworkSnapshot(
        status: .satisfied,
        interfaces: ["wifi"],
        isConstrained: false,
        isExpensive: false
    )

    func testZeroOrIndeterminateProgressUsesSystemManagedPendingWithoutZeroPercent() {
        for progress in [
            SpeechAssetProgressSnapshot(fractionCompleted: 0),
            SpeechAssetProgressSnapshot(fractionCompleted: 0, isIndeterminate: true),
        ] {
            let state = SpeechAssetStateReducer.reduce(
                evidence(status: .downloading, progress: progress, hasActiveRequest: true)
            )
            XCTAssertEqual(state, .systemManagedPending)
        }
    }

    func testMeasuredProgressTakesPriorityOverNetworkContext() {
        let offline = SpeechAssetNetworkSnapshot(
            status: .unsatisfied,
            interfaces: [],
            isConstrained: true,
            isExpensive: false
        )
        let state = SpeechAssetStateReducer.reduce(
            SpeechAssetStateEvidence(
                inventoryStatus: .downloading,
                progress: SpeechAssetProgressSnapshot(fractionCompleted: 0.34),
                network: offline,
                blockingIssue: nil,
                userCancelled: false,
                hasActiveRequest: true,
                initialAttemptReturnedSuccessfully: false
            )
        )
        XCTAssertEqual(state, .downloading(progress: 0.34))
    }

    func testInitialAttemptErrorCanRemainSystemManagedPending() {
        let failure = SpeechAssetFailure(domain: "test", code: 1, message: "initial attempt failed")
        let state = SpeechAssetStateReducer.reduce(
            evidence(status: .downloading, hasActiveRequest: true, blockingIssue: nil)
        )
        XCTAssertEqual(state, .systemManagedPending)
        XCTAssertNotEqual(state, .failed(failure))
    }

    func testFinishedProgressVerifiesUntilInventoryIsInstalled() {
        let state = SpeechAssetStateReducer.reduce(
            evidence(
                status: .downloading,
                progress: SpeechAssetProgressSnapshot(fractionCompleted: 1, isFinished: true),
                hasActiveRequest: true
            )
        )
        XCTAssertEqual(state, .verifying)
    }

    func testInstalledAndUnsupportedInventoryStatusesHavePriority() {
        let failure = SpeechAssetFailure(domain: "test", code: 1, message: "failure")
        XCTAssertEqual(
            SpeechAssetStateReducer.reduce(
                evidence(status: .installed, blockingIssue: .failed(failure))
            ),
            .installed
        )
        XCTAssertEqual(
            SpeechAssetStateReducer.reduce(
                evidence(status: .unsupported, progress: SpeechAssetProgressSnapshot(fractionCompleted: 0.5))
            ),
            .unsupported
        )
    }

    func testOfflineAndConstrainedAreObservationsNotFailureReasons() {
        let offline = SpeechAssetNetworkSnapshot(
            status: .unsatisfied,
            interfaces: [],
            isConstrained: false,
            isExpensive: false
        )
        let constrained = SpeechAssetNetworkSnapshot(
            status: .satisfied,
            interfaces: ["cellular"],
            isConstrained: true,
            isExpensive: true
        )
        XCTAssertEqual(
            SpeechAssetStateReducer.reduce(
                SpeechAssetStateEvidence(
                    inventoryStatus: .downloading,
                    progress: nil,
                    network: offline,
                    blockingIssue: nil,
                    userCancelled: false,
                    hasActiveRequest: true,
                    initialAttemptReturnedSuccessfully: false
                )
            ),
            .offline
        )
        XCTAssertEqual(
            SpeechAssetStateReducer.reduce(
                SpeechAssetStateEvidence(
                    inventoryStatus: .downloading,
                    progress: nil,
                    network: constrained,
                    blockingIssue: nil,
                    userCancelled: false,
                    hasActiveRequest: true,
                    initialAttemptReturnedSuccessfully: false
                )
            ),
            .constrainedNetwork
        )
    }

    func testCancellationIsExplicitAndDoesNotBecomeFailure() {
        XCTAssertEqual(
            SpeechAssetStateReducer.reduce(
                evidence(status: .downloading, userCancelled: true, hasActiveRequest: true)
            ),
            .cancelled
        )
    }

    private func evidence(
        status: SpeechAssetInventoryStatus?,
        progress: SpeechAssetProgressSnapshot? = nil,
        userCancelled: Bool = false,
        hasActiveRequest: Bool = false,
        blockingIssue: SpeechAssetBlockingIssue? = nil
    ) -> SpeechAssetStateEvidence {
        SpeechAssetStateEvidence(
            inventoryStatus: status,
            progress: progress,
            network: online,
            blockingIssue: blockingIssue,
            userCancelled: userCancelled,
            hasActiveRequest: hasActiveRequest,
            initialAttemptReturnedSuccessfully: false
        )
    }
}

@MainActor
final class SpeechAssetCoordinatorTests: XCTestCase {
    func testPrepareRetainsExistingLocalesInsteadOfAutomaticallyReleasingThem() async {
        let client = FakeSpeechAssetClient(maximumReservedLocales: 2)
        client.reserved = [Locale(identifier: "en_US")]
        client.statuses["ja-jp"] = .supported
        let coordinator = makeCoordinator(client: client)

        coordinator.prepare(locale: .jaJP)
        await waitUntil { coordinator.snapshot.state == .installed }

        XCTAssertEqual(
            Set(client.reserved.map(SpeechAssetLocaleIdentifier.canonical)),
            ["en-us", "ja-jp"]
        )
        XCTAssertTrue(client.released.isEmpty)
    }

    func testReservationLimitDoesNotChooseALocaleToRelease() async {
        let client = FakeSpeechAssetClient(maximumReservedLocales: 1)
        client.reserved = [Locale(identifier: "en_US")]
        client.statuses["ja-jp"] = .supported
        let coordinator = makeCoordinator(client: client)

        coordinator.prepare(locale: .jaJP)
        await waitUntil {
            if case .reservationLimitReached = coordinator.snapshot.state { return true }
            return false
        }

        XCTAssertEqual(client.reserved.map(SpeechAssetLocaleIdentifier.canonical), ["en-us"])
        XCTAssertTrue(client.released.isEmpty)
    }

    func testCancelDisablesPersistedAutomaticResume() {
        let suiteName = "SpeechAssetCoordinatorTests.cancel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeSpeechAssetClient(maximumReservedLocales: 2)
        let coordinator = SpeechAssetCoordinator(client: client, defaults: defaults, monitorsNetwork: false)

        coordinator.prepare(locale: .jaJP)
        XCTAssertTrue(defaults.bool(forKey: "SpeechAssetCoordinator.automaticallyResume"))
        coordinator.cancel()
        XCTAssertFalse(defaults.bool(forKey: "SpeechAssetCoordinator.automaticallyResume"))
    }

    func testCancelledPersistedRequestIsRecheckedWithoutStartingAnotherInstallation() async {
        let suiteName = "SpeechAssetCoordinatorTests.restoreCancelled.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("ja_JP", forKey: "SpeechAssetCoordinator.requestedLocale")
        defaults.set(false, forKey: "SpeechAssetCoordinator.automaticallyResume")
        let client = FakeSpeechAssetClient(maximumReservedLocales: 2)
        client.statuses["ja-jp"] = .downloading
        let coordinator = SpeechAssetCoordinator(client: client, defaults: defaults, monitorsNetwork: false)

        coordinator.restorePersistedState(selectedLocale: .jaJP)
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(client.installationRequestCount, 0)
        XCTAssertFalse(coordinator.snapshot.isOperationActive)
        XCTAssertEqual(coordinator.snapshot.inventoryStatus, .downloading)
    }

    func testUserActionsMatchStateTableAndNeverIncludeManualRecheck() {
        let failure = SpeechAssetFailure(domain: "test", code: 1, message: "failure")
        let cases: [(SpeechAssetSnapshot, Bool, [SpeechAssetUserAction])] = [
            (snapshot(state: .checking, inventoryStatus: .supported), false, [.prepare]),
            (snapshot(state: .checking), false, []),
            (snapshot(state: .reserving), false, [.cancel]),
            (snapshot(state: .downloading(progress: 0.4)), false, [.cancel]),
            (snapshot(state: .systemManagedPending, isOperationActive: true), false, [.cancel]),
            (
                snapshot(state: .systemManagedPending, hasExtendedWait: true, isOperationActive: true),
                false,
                [.startOver, .cancel]
            ),
            (snapshot(state: .verifying, isOperationActive: true), false, [.cancel]),
            (snapshot(state: .verifying), false, []),
            (snapshot(state: .offline, isOperationActive: true), false, [.retry, .cancel]),
            (snapshot(state: .offline), false, [.retry]),
            (snapshot(state: .constrainedNetwork, isOperationActive: true), false, [.retry, .cancel]),
            (snapshot(state: .constrainedNetwork), false, [.retry]),
            (
                snapshot(state: .reservationLimitReached(maximum: 2, failure: failure)),
                false,
                [.replaceLanguage]
            ),
            (snapshot(state: .insufficientStorage(failure)), false, [.retry]),
            (snapshot(state: .failed(failure)), false, [.retry]),
            (snapshot(state: .cancelled), false, [.resume]),
            (snapshot(state: .installed, inventoryStatus: .installed), true, []),
            (snapshot(state: .installed, inventoryStatus: .installed), false, [.prepare]),
            (snapshot(state: .unsupported), false, []),
        ]

        for (snapshot, isModelReady, expected) in cases {
            let actions = snapshot.userActions(isModelReady: isModelReady)
            XCTAssertEqual(actions, expected, "state: \(snapshot.state)")

            let primaryActions = actions.filter {
                [.prepare, .retry, .resume, .replaceLanguage].contains($0)
            }
            XCTAssertLessThanOrEqual(
                primaryActions.count, 1,
                "state \(snapshot.state) must offer at most one primary action"
            )
        }
    }

    func testRefreshStatusDoesNotDisturbActiveOperation() async {
        let client = FakeSpeechAssetClient(maximumReservedLocales: 2)
        client.statuses["ja-jp"] = .supported
        let gate = FakeGate()
        client.pendingInstallationGate = gate
        let coordinator = makeCoordinator(client: client)

        coordinator.prepare(locale: .jaJP)
        await waitUntil { coordinator.snapshot.isOperationActive && coordinator.snapshot.progress != nil }
        let statusCallCount = client.statusCallCount
        let stateBefore = coordinator.snapshot.state

        coordinator.refreshStatus()
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(coordinator.snapshot.isOperationActive)
        XCTAssertEqual(coordinator.snapshot.state, stateBefore)
        XCTAssertEqual(client.statusCallCount, statusCallCount)

        gate.open()
        await waitUntil { coordinator.snapshot.state == .installed }
    }

    func testRefreshStatusSelfHealsWhenModelBecameInstalled() async {
        let client = FakeSpeechAssetClient(maximumReservedLocales: 2)
        client.statuses["ja-jp"] = .supported
        client.installationError = NSError(domain: "test", code: 1)
        let coordinator = makeCoordinator(client: client)

        coordinator.prepare(locale: .jaJP)
        await waitUntil {
            if case .failed = coordinator.snapshot.state { return true }
            return false
        }

        client.installationError = nil
        client.statuses["ja-jp"] = .installed
        client.installed = [Locale(identifier: "ja_JP")]
        coordinator.refreshStatus()
        await waitUntil { coordinator.snapshot.state == .installed }
        XCTAssertEqual(client.installationRequestCount, 1)
    }

    func testRefreshStatusPreservesUserCancellation() async {
        let client = FakeSpeechAssetClient(maximumReservedLocales: 2)
        client.statuses["ja-jp"] = .supported
        let gate = FakeGate()
        client.pendingInstallationGate = gate
        let coordinator = makeCoordinator(client: client)

        coordinator.prepare(locale: .jaJP)
        await waitUntil { coordinator.snapshot.isOperationActive }
        coordinator.cancel()
        gate.open()
        XCTAssertEqual(coordinator.snapshot.state, .cancelled)

        coordinator.refreshStatus()
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(coordinator.snapshot.state, .cancelled)
        XCTAssertFalse(coordinator.snapshot.isOperationActive)
    }

    func testPrepareAndWaitUsesActiveInstallationAndReturnsWhenReady() async throws {
        let client = FakeSpeechAssetClient(maximumReservedLocales: 2)
        client.statuses["ja-jp"] = .supported
        let gate = FakeGate()
        client.pendingInstallationGate = gate
        let coordinator = makeCoordinator(client: client)

        coordinator.prepare(locale: .jaJP)
        await waitUntil {
            coordinator.snapshot.isOperationActive
                && client.installationRequestCount == 1
        }

        let waitTask = Task {
            try await coordinator.prepareAndWaitUntilReady(locale: .jaJP)
        }
        await Task.yield()
        XCTAssertEqual(client.installationRequestCount, 1)

        gate.open()
        try await waitTask.value

        XCTAssertEqual(client.installationRequestCount, 1)
        let isReady = await coordinator.isReady(locale: .jaJP)
        XCTAssertTrue(isReady)
    }

    func testPrepareAndWaitStartsInstallationWhenNoneIsActive() async throws {
        let client = FakeSpeechAssetClient(maximumReservedLocales: 2)
        client.statuses["ja-jp"] = .supported
        let coordinator = makeCoordinator(client: client)

        try await coordinator.prepareAndWaitUntilReady(locale: .jaJP)

        XCTAssertEqual(client.installationRequestCount, 1)
        let isReady = await coordinator.isReady(locale: .jaJP)
        XCTAssertTrue(isReady)
    }

    func testNetworkRestorationTriggersInventoryRefresh() async {
        let offline = SpeechAssetNetworkSnapshot(
            status: .unsatisfied,
            interfaces: [],
            isConstrained: false,
            isExpensive: false
        )
        let online = SpeechAssetNetworkSnapshot(
            status: .satisfied,
            interfaces: ["wifi"],
            isConstrained: false,
            isExpensive: false
        )
        let client = FakeSpeechAssetClient(maximumReservedLocales: 2)
        let coordinator = makeCoordinator(client: client)
        coordinator.restorePersistedState(selectedLocale: .jaJP)
        try? await Task.sleep(for: .milliseconds(100))

        coordinator.applyNetworkSnapshot(offline)
        XCTAssertEqual(coordinator.snapshot.state, .offline)
        let statusCallCount = client.statusCallCount

        coordinator.applyNetworkSnapshot(online)
        await waitUntil { client.statusCallCount > statusCallCount }
    }

    func testRetryWhileInstalledDoesNotRequestInstallation() async {
        let client = FakeSpeechAssetClient(maximumReservedLocales: 2)
        client.statuses["ja-jp"] = .installed
        client.installed = [Locale(identifier: "ja_JP")]
        let coordinator = makeCoordinator(client: client)
        coordinator.restorePersistedState(selectedLocale: .jaJP)
        try? await Task.sleep(for: .milliseconds(100))

        coordinator.retry()
        await waitUntil { coordinator.snapshot.state == .installed }
        XCTAssertEqual(client.installationRequestCount, 0)
    }

    func testFailureSanitizationDoesNotExposeURLsOrBinaryData() {
        let error = NSError(
            domain: "test",
            code: 1,
            userInfo: [
                "url": URL(fileURLWithPath: "/private/secret/audio.m4a"),
                "data": Data([1, 2, 3]),
                "pathString": "/private/secret/audio.m4a",
                NSLocalizedDescriptionKey: "safe message",
            ]
        )
        let failure = SpeechAssetFailure(error: error)

        XCTAssertEqual(failure.userInfo["url"], "<URL>")
        XCTAssertEqual(failure.userInfo["data"], "<Data>")
        XCTAssertEqual(failure.userInfo["pathString"], "<redacted-path>")
        XCTAssertFalse(String(describing: failure.userInfo).contains("audio.m4a"))
    }

    private func snapshot(
        state: SpeechAssetPresentationState,
        inventoryStatus: SpeechAssetInventoryStatus? = nil,
        hasExtendedWait: Bool = false,
        isOperationActive: Bool = false
    ) -> SpeechAssetSnapshot {
        var snapshot = SpeechAssetSnapshot()
        snapshot.state = state
        snapshot.inventoryStatus = inventoryStatus
        snapshot.hasExtendedWait = hasExtendedWait
        snapshot.isOperationActive = isOperationActive
        return snapshot
    }

    private func makeCoordinator(client: FakeSpeechAssetClient) -> SpeechAssetCoordinator {
        let suiteName = "SpeechAssetCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return SpeechAssetCoordinator(client: client, defaults: defaults, monitorsNetwork: false)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition())
    }
}

private final class FakeSpeechAssetInstallation: SpeechAssetInstalling {
    let progress = Progress(totalUnitCount: 100)
    private let action: () async throws -> Void

    init(action: @escaping () async throws -> Void) {
        self.action = action
    }

    func downloadAndInstall() async throws {
        progress.completedUnitCount = 50
        try await action()
        progress.completedUnitCount = 100
    }
}

private final class FakeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
                return
            }
            continuations.append(continuation)
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let waiting = continuations
        continuations.removeAll()
        lock.unlock()
        waiting.forEach { $0.resume() }
    }
}

private final class FakeSpeechAssetClient: SpeechAssetClient {
    let maximumReservedLocales: Int
    var isSpeechTranscriberAvailable = true
    var supported = [Locale(identifier: "en_US"), Locale(identifier: "ja_JP")]
    var installed: [Locale] = []
    var reserved: [Locale] = []
    var released: [Locale] = []
    var statuses: [String: SpeechAssetInventoryStatus] = [:]
    var installationRequestCount = 0
    var statusCallCount = 0
    var installationError: Error?
    var pendingInstallationGate: FakeGate?

    init(maximumReservedLocales: Int) {
        self.maximumReservedLocales = maximumReservedLocales
    }

    func supportedLocales() async -> [Locale] { supported }
    func installedLocales() async -> [Locale] { installed }
    func reservedLocales() async -> [Locale] { reserved }

    func normalizedLocale(equivalentTo locale: Locale) async -> Locale? {
        let language = locale.language.languageCode?.identifier
        return supported.first { $0.language.languageCode?.identifier == language }
    }

    func status(for locale: Locale) async -> SpeechAssetInventoryStatus {
        statusCallCount += 1
        return statuses[SpeechAssetLocaleIdentifier.canonical(locale)] ?? .supported
    }

    func reserve(locale: Locale) async throws -> Bool {
        guard reserved.count < maximumReservedLocales else {
            throw NSError(
                domain: "FakeSpeechAssetClient",
                code: 0
            )
        }
        reserved.append(locale)
        return true
    }

    func release(reservedLocale: Locale) async -> Bool {
        guard let index = reserved.firstIndex(where: {
            SpeechAssetLocaleIdentifier.canonical($0) == SpeechAssetLocaleIdentifier.canonical(reservedLocale)
        }) else { return false }
        released.append(reserved[index])
        reserved.remove(at: index)
        return true
    }

    func installationRequest(for locale: Locale) async throws -> SpeechAssetInstalling? {
        installationRequestCount += 1
        if let installationError { throw installationError }
        let key = SpeechAssetLocaleIdentifier.canonical(locale)
        if statuses[key] == .installed { return nil }
        statuses[key] = .downloading
        let gate = pendingInstallationGate
        return FakeSpeechAssetInstallation { [weak self] in
            if let gate { await gate.wait() }
            self?.statuses[key] = .installed
            self?.installed.append(locale)
        }
    }
}
