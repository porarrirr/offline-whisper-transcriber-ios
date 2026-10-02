import CloudKit
import BackgroundTasks
import CryptoKit
import Foundation
import Network
import SwiftData

struct CloudHistorySnapshot: Codable, Equatable {
    var title: String
    var text: String
    var sourceType: String
    var duration: Double
    var createdAt: Date
    var isFavorite: Bool
    var segmentsJSON: String?
    var language: String?
    var tagsJSON: String?
    var chatMessagesJSON: String?
    var deletedAt: Date?
    var cloudAudioID: String?
    var cloudAudioZoneName: String?
    var cloudAudioByteCount: Int64
    var cloudAudioChunkCount: Int
    var cloudAudioSHA256: String?

    init(_ record: TranscriptionRecord) {
        title = record.title
        text = record.text
        sourceType = record.sourceType
        duration = record.duration
        createdAt = record.createdAt
        isFavorite = record.isFavorite
        segmentsJSON = record.segmentsJSON
        language = record.language
        tagsJSON = record.tagsJSON
        chatMessagesJSON = record.chatMessagesJSON
        deletedAt = record.deletedAt
        cloudAudioID = record.cloudAudioID
        cloudAudioZoneName = record.cloudAudioZoneName
        cloudAudioByteCount = record.cloudAudioByteCount
        cloudAudioChunkCount = record.cloudAudioChunkCount
        cloudAudioSHA256 = record.cloudAudioSHA256
    }

    static func decode(_ text: String?) -> Self? {
        guard let text, let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    var json: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func differs(fromEncodedSnapshot json: String?) -> Bool {
        guard let previous = Self.decode(json) else { return true }
        return self != previous
    }

    static func needsPreservationAfterCloudDeletion(
        _ record: TranscriptionRecord, asOf now: Date = Date()
    ) -> Bool {
        if let deletedAt = record.deletedAt,
           deletedAt.addingTimeInterval(30 * 24 * 60 * 60) <= now { return false }
        return Self(record).differs(fromEncodedSnapshot: record.lastSyncedSnapshotJSON)
            || (record.audioFilePath != nil && record.cloudAudioID == nil)
            || record.pendingAudioID != nil
    }

    static func versionToPreserveOnConflict(
        base: Self?, local: Self, remote: Self, merged: Self
    ) -> Self {
        guard let base,
              local.deletedAt != base.deletedAt,
              remote.deletedAt == base.deletedAt,
              remote != base else { return local }
        var preserved = merged
        preserved.deletedAt = nil
        return preserved
    }

    static func merged(base: Self, local: Self, remote: Self) -> (value: Self, conflict: Bool) {
        var value = remote
        var conflict = false
        func choose<T: Equatable>(_ old: T, _ here: T, _ there: T) -> T {
            if here == old { return there }
            if there == old || here == there { return here }
            conflict = true
            return there
        }
        value.title = choose(base.title, local.title, remote.title)
        value.sourceType = choose(base.sourceType, local.sourceType, remote.sourceType)
        value.createdAt = choose(base.createdAt, local.createdAt, remote.createdAt)
        value.isFavorite = choose(base.isFavorite, local.isFavorite, remote.isFavorite)
        let localTranscriptChanged = local.text != base.text || local.duration != base.duration ||
            local.segmentsJSON != base.segmentsJSON || local.language != base.language
        let remoteTranscriptChanged = remote.text != base.text || remote.duration != base.duration ||
            remote.segmentsJSON != base.segmentsJSON || remote.language != base.language
        if localTranscriptChanged && !remoteTranscriptChanged {
            value.text = local.text
            value.duration = local.duration
            value.segmentsJSON = local.segmentsJSON
            value.language = local.language
        } else if localTranscriptChanged && remoteTranscriptChanged &&
                    (local.text != remote.text || local.duration != remote.duration ||
                     local.segmentsJSON != remote.segmentsJSON || local.language != remote.language) {
            conflict = true
        }
        value.tagsJSON = choose(base.tagsJSON, local.tagsJSON, remote.tagsJSON)
        value.chatMessagesJSON = choose(base.chatMessagesJSON, local.chatMessagesJSON, remote.chatMessagesJSON)
        value.deletedAt = choose(base.deletedAt, local.deletedAt, remote.deletedAt)
        let localAudioChanged = local.cloudAudioID != base.cloudAudioID ||
            local.cloudAudioZoneName != base.cloudAudioZoneName ||
            local.cloudAudioByteCount != base.cloudAudioByteCount ||
            local.cloudAudioChunkCount != base.cloudAudioChunkCount ||
            local.cloudAudioSHA256 != base.cloudAudioSHA256
        let remoteAudioChanged = remote.cloudAudioID != base.cloudAudioID ||
            remote.cloudAudioZoneName != base.cloudAudioZoneName ||
            remote.cloudAudioByteCount != base.cloudAudioByteCount ||
            remote.cloudAudioChunkCount != base.cloudAudioChunkCount ||
            remote.cloudAudioSHA256 != base.cloudAudioSHA256
        if localAudioChanged && !remoteAudioChanged {
            value.cloudAudioID = local.cloudAudioID
            value.cloudAudioZoneName = local.cloudAudioZoneName
            value.cloudAudioByteCount = local.cloudAudioByteCount
            value.cloudAudioChunkCount = local.cloudAudioChunkCount
            value.cloudAudioSHA256 = local.cloudAudioSHA256
        } else if localAudioChanged && remoteAudioChanged &&
                    (local.cloudAudioID != remote.cloudAudioID ||
                     local.cloudAudioZoneName != remote.cloudAudioZoneName ||
                     local.cloudAudioByteCount != remote.cloudAudioByteCount ||
                     local.cloudAudioChunkCount != remote.cloudAudioChunkCount ||
                     local.cloudAudioSHA256 != remote.cloudAudioSHA256) {
            conflict = true
        }
        if local.deletedAt != base.deletedAt && remote != base && remote.deletedAt == base.deletedAt {
            conflict = true
        }
        if remote.deletedAt != base.deletedAt && local != base && local.deletedAt == base.deletedAt {
            conflict = true
        }
        return (value, conflict)
    }

    func apply(to record: TranscriptionRecord) {
        record.title = title
        record.text = text
        record.sourceType = sourceType
        record.duration = duration
        record.createdAt = createdAt
        record.isFavorite = isFavorite
        record.segmentsJSON = segmentsJSON
        record.language = language
        record.tagsJSON = tagsJSON
        record.chatMessagesJSON = chatMessagesJSON
        record.deletedAt = deletedAt
        record.cloudAudioID = cloudAudioID
        record.cloudAudioZoneName = cloudAudioZoneName
        record.cloudAudioByteCount = cloudAudioByteCount
        record.cloudAudioChunkCount = cloudAudioChunkCount
        record.cloudAudioSHA256 = cloudAudioSHA256
    }
}

enum HistorySyncError: LocalizedError {
    case differentAccount, noAccount, invalidCloudRecord, missingAudio, audioVerificationFailed
    case incompleteUpload, incompleteDeletion, permanentlyDeleted, snapshotTooLarge
    case cloudStoreDeleted, audioBeingDeleted, editDuringTransfer

    var errorDescription: String? {
        switch self {
        case .differentAccount: "The Apple Account changed. Sync is stopped to protect the previous account's history."
        case .noAccount: "Sign in to iCloud to sync history."
        case .invalidCloudRecord: "The iCloud history record is invalid. Sync stopped and local files were kept."
        case .missingAudio: "The recording is unavailable. The local copy was kept."
        case .audioVerificationFailed: "The downloaded recording failed verification."
        case .incompleteUpload: "The recording upload did not finish. The local copy was kept."
        case .incompleteDeletion: "The iCloud history deletion did not finish. It will be retried."
        case .permanentlyDeleted: "This history was permanently deleted in iCloud."
        case .snapshotTooLarge: "This history exceeds CloudKit's asset size limit. The local history was kept."
        case .cloudStoreDeleted: "The iCloud storage was deleted. Sync stopped and local files were kept. Turn sync on again to upload the remaining local history."
        case .audioBeingDeleted: "This iCloud recording is being deleted. The local history was kept."
        case .editDuringTransfer: "This history changed during transfer. Your saved changes were kept."
        }
    }
}

@MainActor
protocol HistoryCloudSyncPreferences: AnyObject {
    var iCloudSyncEnabled: Bool { get set }
    var allowCellularSync: Bool { get }
    var audioRetentionDays: Int { get }
}

extension AppSettings: HistoryCloudSyncPreferences {}

@MainActor
final class HistoryCloudSync: ObservableObject {
    static let shared: HistoryCloudSync = {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HistoryCloudSync", isDirectory: true)
        return HistoryCloudSync(
            database: CloudKitHistoryDatabase(containerIdentifier: containerID),
            preferences: AppSettings.shared,
            checkpointStore: HistoryCloudCheckpointStore(url: directory.appendingPathComponent("\(containerID).json")))
    }()
    static let historyChanged = Notification.Name("HistoryCloudSync.historyChanged")
    static let containerID: String = {
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: "HistoryCloudKitContainerIdentifier") as? String,
              identifier.hasPrefix("iCloud.") else {
            fatalError("HistoryCloudKitContainerIdentifier is missing from Info.plist")
        }
        return identifier
    }()
    static let backgroundTaskID = "com.porarrirr.offlinewhispertranscriber.history-refresh"
    private static let accountKey = "historyCloudAccountRecordName"
    private static let legacyCloudIDMigrationKey = "historyCloudIDMigrationCompleted"

    @Published private(set) var status = "iCloud sync is off"
    @Published private(set) var isSyncing = false
    @Published private(set) var uploadingID: UUID?
    @Published private(set) var uploadProgress: Double = 0
    var isUsingCellular: Bool { path?.usesInterfaceType(.cellular) == true }

    private let database: any HistoryCloudDatabase
    private let settings: any HistoryCloudSyncPreferences
    private let defaults: UserDefaults
    private let checkpointStore: HistoryCloudCheckpointStore
    private let networkCheck: (() -> Bool)?
    private let saveChanges: (ModelContext) throws -> Void
    private let monitor: NWPathMonitor?
    private var accountObserver: NSObjectProtocol?
    private var path: NWPath?
    private var modelContext: ModelContext?
    private var syncTask: Task<Void, Never>?
    private var syncRequestedWhileRunning = false
    private var retryTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var playingRecordIDs: Set<UUID> = []
    private var generation = UUID()
    private var checkpoint = HistoryCloudCheckpoint()

    init(database: any HistoryCloudDatabase, preferences: any HistoryCloudSyncPreferences,
         checkpointStore: HistoryCloudCheckpointStore, defaults: UserDefaults = .standard,
         networkCheck: (() -> Bool)? = nil,
         saveChanges: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.database = database
        self.settings = preferences
        self.checkpointStore = checkpointStore
        self.defaults = defaults
        self.networkCheck = networkCheck
        self.saveChanges = saveChanges
        monitor = networkCheck == nil ? NWPathMonitor() : nil
        monitor?.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.path = path
                self?.scheduleSync()
            }
        }
        monitor?.start(queue: DispatchQueue(label: "HistoryCloudSync.network"))
        accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.settings.iCloudSyncEnabled,
                          self.defaults.string(forKey: Self.accountKey) != nil else { return }
                    self.settings.iCloudSyncEnabled = false
                    self.settingChanged()
                    self.status = HistorySyncError.differentAccount.localizedDescription
                }
            }
    }

    deinit {
        monitor?.cancel()
        if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) }
    }

    func configure(container: ModelContainer, startSync: Bool = true) {
        guard modelContext == nil else { return }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        modelContext = context
        if startSync && settings.iCloudSyncEnabled {
            startPolling()
            scheduleSync()
            scheduleBackgroundRefresh()
        }
    }

    func settingChanged() {
        if settings.iCloudSyncEnabled {
            startPolling()
            scheduleSync()
            scheduleBackgroundRefresh()
        } else {
            generation = UUID()
            syncTask?.cancel()
            syncRequestedWhileRunning = false
            retryTask?.cancel()
            retryTask = nil
            pollingTask?.cancel()
            pollingTask = nil
            database.cancelOperations()
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundTaskID)
            status = "iCloud sync is off"
        }
    }

    func performBackgroundRefresh(_ task: BGAppRefreshTask) {
        scheduleSync()
        let work = Task { @MainActor in
            await syncTask?.value
            task.setTaskCompleted(success: status == "Synced")
            scheduleBackgroundRefresh()
        }
        task.expirationHandler = { [weak self] in
            work.cancel()
            Task { @MainActor in
                self?.syncTask?.cancel()
                self?.database.cancelOperations()
            }
        }
    }

    private func scheduleBackgroundRefresh() {
        guard settings.iCloudSyncEnabled else { return }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundTaskID)
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundTaskID)
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        do { try BGTaskScheduler.shared.submit(request) }
        catch { AppLogger.error("Could not schedule history sync refresh", context: "HistoryCloudSync", error: error) }
    }

    private func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 60_000_000_000) }
                catch { break }
                self?.scheduleSync()
            }
        }
    }

    func syncStatus(for record: TranscriptionRecord) -> String? {
        guard settings.iCloudSyncEnabled else { return nil }
        if let error = record.syncError { return "Sync failed: \(error)" }
        if uploadingID == record.id { return "Uploading audio \(Int(uploadProgress * 100))%" }
        if let deletedAt = record.deletedAt,
           deletedAt.addingTimeInterval(HistoryCloudSchema.restoreInterval) <= Date() {
            return "Waiting for permanent deletion"
        }
        if record.audioFilePath != nil && record.cloudAudioID == nil { return "Audio waiting to upload" }
        if CloudHistorySnapshot(record).differs(fromEncodedSnapshot: record.lastSyncedSnapshotJSON) {
            return "Waiting to sync"
        }
        return "Synced"
    }

    func scheduleSync() {
        guard settings.iCloudSyncEnabled, modelContext != nil else { return }
        if syncTask != nil { syncRequestedWhileRunning = true; return }
        syncTask = Task { [weak self] in
            await self?.syncOnce()
            self?.syncTask = nil
            if self?.syncRequestedWhileRunning == true {
                self?.syncRequestedWhileRunning = false
                self?.scheduleSync()
            }
        }
    }

    private func checkSession(_ session: UUID) throws {
        try Task.checkCancellation()
        guard session == generation, settings.iCloudSyncEnabled else { throw CancellationError() }
    }

    /// Kept internal so fault-injection tests exercise the complete synchronization pipeline.
    func syncOnce() async {
        guard settings.iCloudSyncEnabled, let modelContext, !isSyncing else { return }
        guard networkCheck?() ?? (path?.status == .satisfied &&
            (settings.allowCellularSync || path?.usesInterfaceType(.wifi) == true)) else {
            status = path?.status == .satisfied ? "Waiting for Wi-Fi" : "Waiting for network"
            return
        }
        let session = generation
        isSyncing = true
        status = "Checking iCloud"
        defer { isSyncing = false }
        do {
            checkpoint = try checkpointStore.load()
            database.allowCellular = settings.allowCellularSync
            try await verifyAccount()
            try checkSession(session)
            try await prepareZones(session: session)
            if !defaults.bool(forKey: Self.legacyCloudIDMigrationKey) {
                for item in try allRecords() where item.lastSyncedSnapshotJSON == nil && item.cloudRecordSystemFields == nil {
                    item.cloudID = item.id.uuidString
                }
                try saveChanges(modelContext)
                defaults.set(true, forKey: Self.legacyCloudIDMigrationKey)
            }
            try await fetchHistory(session: session)
            // Acquire each audio reference before any garbage collection. The manifest's change tag
            // serializes acquiring references against removing the last reference.
            for record in try allRecords() where !record.cloudDeletionConfirmed {
                try checkSession(session)
                try await ensureAudioOwnership(record, session: session)
            }
            for record in try allRecords() {
                try checkSession(session)
                guard !record.isDeleted else { continue }
                if let deletedAt = record.deletedAt,
                   deletedAt.addingTimeInterval(HistoryCloudSchema.restoreInterval) <= Date() {
                    try await commitPurge(record, session: session)
                    continue
                }
                if record.deletedAt == nil, !record.audioFinalizationPending,
                   record.cloudAudioID == nil, record.audioFilePath != nil {
                    do { try await uploadAudio(for: record, session: session) }
                    catch {
                        try checkSession(session)
                        record.syncError = error.localizedDescription
                        try saveChanges(modelContext)
                    }
                }
            }
            let sendFailed = try await sendHistory(session: session)
            // A save conflict can create a preserved record with a new ID. Acquire its audio
            // before a previously fetched tombstone is allowed to release the old owner.
            for record in try allRecords() where !record.cloudDeletionConfirmed {
                try await ensureAudioOwnership(record, session: session)
            }
            for record in try allRecords() {
                if let deletedAt = record.deletedAt,
                   deletedAt.addingTimeInterval(HistoryCloudSchema.restoreInterval) <= Date() {
                    try await commitPurge(record, session: session)
                }
            }
            try await processPendingPurges(session: session)
            try await removeExpiredLocalAudio(session: session)
            let remaining = try allRecords()
            if sendFailed || remaining.contains(where: { $0.syncError != nil }) {
                status = "Some items failed to sync"
                scheduleRetry()
            } else { status = "Synced" }
        } catch is CancellationError {
            status = settings.iCloudSyncEnabled ? "Sync paused" : "iCloud sync is off"
        } catch {
            // No subsequent sends, cursor acknowledgements, or file cleanup after a failed receive/save.
            modelContext.rollback()
            status = error.localizedDescription
            AppLogger.error("iCloud history sync failed", context: "HistoryCloudSync", error: error)
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        guard settings.iCloudSyncEnabled, retryTask == nil else { return }
        retryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 60_000_000_000) }
            catch { return }
            self?.retryTask = nil
            self?.scheduleSync()
        }
    }

    private func allRecords() throws -> [TranscriptionRecord] {
        guard let modelContext else { throw HistorySyncError.invalidCloudRecord }
        return try modelContext.fetch(FetchDescriptor<TranscriptionRecord>())
    }

    private func verifyAccount() async throws {
        let current = try await database.accountRecordName()
        if let bound = defaults.string(forKey: Self.accountKey), bound != current {
            settings.iCloudSyncEnabled = false
            settingChanged()
            throw HistorySyncError.differentAccount
        }
        defaults.set(current, forKey: Self.accountKey)
    }

    private func prepareZones(session: UUID) async throws {
        let available = try await database.zoneIDs()
        try checkSession(session)
        let availableNames = Set(available.map(\.zoneName))
        var expected = checkpoint.knownZones
        // The first run of this version also protects history uploaded by the previous version.
        for record in try allRecords() {
            if record.cloudRecordSystemFields != nil || record.lastSyncedSnapshotJSON != nil {
                expected.insert(HistoryCloudSchema.historyZone.zoneName)
            }
            if record.cloudAudioID != nil {
                expected.insert(record.cloudAudioZoneName ?? HistoryCloudSchema.historyZone.zoneName)
            }
        }
        let missing = expected.subtracting(availableNames)
        if !missing.isEmpty {
            try stopAfterZoneDeletion(missing)
            throw HistorySyncError.cloudStoreDeleted
        }
        let required: Set<CKRecordZone.ID> = [HistoryCloudSchema.historyZone, HistoryCloudSchema.audioZone]
        try await database.createZones(required.subtracting(available))
        try checkSession(session)
        var updated = checkpoint
        updated.knownZones.formUnion(required.map(\.zoneName))
        try checkpointStore.save(updated)
        checkpoint = updated
    }

    private func stopAfterZoneDeletion(_ missing: Set<String>) throws {
        // Stop first, even when disk failure prevents persisting invalidated metadata.
        settings.iCloudSyncEnabled = false
        settingChanged()
        guard let modelContext else { throw HistorySyncError.invalidCloudRecord }
        for record in try allRecords() {
            if missing.contains(HistoryCloudSchema.historyZone.zoneName) {
                record.lastSyncedSnapshotJSON = nil
                record.cloudRecordSystemFields = nil
                record.cloudDeletionConfirmed = false
            }
            if record.cloudAudioID != nil,
               missing.contains(record.cloudAudioZoneName ?? HistoryCloudSchema.historyZone.zoneName) {
                Self.clearCloudAudio(record)
                record.syncError = HistorySyncError.missingAudio.localizedDescription
            }
            if record.pendingAudioID != nil,
               missing.contains(record.pendingAudioZoneName ?? HistoryCloudSchema.historyZone.zoneName) {
                record.pendingAudioID = nil
                record.pendingAudioZoneName = nil
            }
        }
        try saveChanges(modelContext)
        var updated = checkpoint
        updated.knownZones.subtract(missing)
        if missing.contains(HistoryCloudSchema.historyZone.zoneName) { updated.token = nil }
        try checkpointStore.save(updated)
        checkpoint = updated
        status = HistorySyncError.cloudStoreDeleted.localizedDescription
    }

    private func fetchHistory(session: UUID) async throws {
        var more = true
        while more {
            let page: HistoryCloudPage
            do {
                page = try await database.changes(in: HistoryCloudSchema.historyZone,
                    since: checkpoint.changeToken(), desiredKeys: HistoryCloudSchema.historyKeys)
            } catch let error as CKError where error.code == .changeTokenExpired {
                guard checkpoint.token != nil else { throw error }
                try checkSession(session)
                // Expired tokens are part of the change-feed protocol: repeat a full fetch using
                // the same API, preserving all local data. Never acknowledge an unread page.
                var reset = checkpoint
                reset.token = nil
                try checkpointStore.save(reset)
                checkpoint = reset
                continue
            } catch let error as CKError where error.code == .zoneNotFound {
                try stopAfterZoneDeletion([HistoryCloudSchema.historyZone.zoneName])
                throw HistorySyncError.cloudStoreDeleted
            }
            try checkSession(session)
            try applyPage(page)
            more = page.moreComing
        }
    }

    /// Saves fetched data before the cursor. Faults in either write leave the page replayable.
    func applyPage(_ page: HistoryCloudPage) throws {
        guard let modelContext else { throw HistorySyncError.invalidCloudRecord }
        var updated = checkpoint
        var filesToRemove: Set<URL> = []
        var createdFiles: [URL] = []
        var changedRecords: [TranscriptionRecord] = []
        var removedIDs: [UUID] = []
        do {
            for cloud in page.records where cloud.recordType == "HistoryItem" {
                guard cloud.recordID.zoneID == HistoryCloudSchema.historyZone else { throw HistorySyncError.invalidCloudRecord }
                if cloud["purgedAt"] != nil {
                    var purge = try HistoryCloudRecordCodec.purge(cloud)
                    if let local = try allRecords().first(where: { $0.cloudID == purge.historyID }) {
                        // This device may have an unpublished upload absent from the remote marker.
                        purge.audio = Array(Set(purge.audio + (try references(of: local))))
                        if Self.shouldPreserveAfterPurge(local) {
                            Self.detachAfterPurge(local, keepCloudAudio: true)
                            changedRecords.append(local)
                        } else { local.cloudDeletionConfirmed = true; removedIDs.append(local.id) }
                    }
                    updated.enqueue(purge)
                } else {
                    changedRecords.append(contentsOf: try merge(cloud, filesToRemove: &filesToRemove, createdFiles: &createdFiles))
                }
            }
            for deletion in page.deletedRecords where deletion.type == "HistoryItem" {
                guard let local = try allRecords().first(where: { $0.cloudID == deletion.id.recordName }) else { continue }
                if Self.shouldPreserveAfterPurge(local) {
                    Self.preserveLocalRecordAfterCloudDeletion(local)
                    changedRecords.append(local)
                } else { local.cloudDeletionConfirmed = true; removedIDs.append(local.id) }
            }
            // Persist cleanup references before an ID can change or disappear locally. This does
            // not advance the cursor; a failed database save must still replay the received page.
            if updated.pendingPurges != checkpoint.pendingPurges {
                try checkpointStore.save(updated)
                checkpoint = updated
            }
            try saveChanges(modelContext)
        } catch {
            modelContext.rollback()
            for url in createdFiles { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        try updated.setToken(page.token)
        try checkpointStore.save(updated)
        checkpoint = updated
        let retained = Set(try allRecords().compactMap { $0.audioFilePath }
            .map { try RecordingFileReference.fileURL(for: $0) })
        for url in filesToRemove.subtracting(retained) where FileManager.default.fileExists(atPath: url.path) {
            do { try FileManager.default.removeItem(at: url) }
            catch { AppLogger.error("Could not remove obsolete recording", context: "HistoryCloudSync", error: error) }
        }
        for record in changedRecords {
            if record.deletedAt == nil { TranscriptionSpotlightSync.index(record) }
            else { removedIDs.append(record.id) }
        }
        if !removedIDs.isEmpty { TranscriptionSpotlightSync.delete(identifiers: removedIDs) }
        NotificationCenter.default.post(name: Self.historyChanged, object: nil)
    }

    static func shouldPreserveAfterPurge(_ record: TranscriptionRecord, at now: Date = Date()) -> Bool {
        // Even an already-synced restore must survive an older device's permanent deletion.
        record.deletedAt == nil || CloudHistorySnapshot.needsPreservationAfterCloudDeletion(record, asOf: now)
    }

    private static func clearCloudAudio(_ record: TranscriptionRecord) {
        record.cloudAudioID = nil
        record.cloudAudioZoneName = nil
        record.cloudAudioByteCount = 0
        record.cloudAudioChunkCount = 0
        record.cloudAudioSHA256 = nil
        record.audioUploadedAt = nil
    }

    private static func detachAfterPurge(_ record: TranscriptionRecord, keepCloudAudio: Bool) {
        record.cloudID = UUID().uuidString
        record.cloudRecordSystemFields = nil
        record.lastSyncedSnapshotJSON = nil
        record.cloudDeletionConfirmed = false
        if !keepCloudAudio { clearCloudAudio(record) }
        record.title += " (Conflict Copy)"
        record.modifiedAt = Date()
        record.syncError = nil
    }

    static func preserveLocalRecordAfterCloudDeletion(_ record: TranscriptionRecord) {
        detachAfterPurge(record, keepCloudAudio: false)
    }

    private func merge(_ cloud: CKRecord, filesToRemove: inout Set<URL>, createdFiles: inout [URL]) throws -> [TranscriptionRecord] {
        guard let modelContext else { throw HistorySyncError.invalidCloudRecord }
        let remote = try HistoryCloudRecordCodec.snapshot(cloud)
        guard let json = remote.json else { throw HistorySyncError.invalidCloudRecord }
        guard let local = try allRecords().first(where: { $0.cloudID == cloud.recordID.recordName }) else {
            guard let source = TranscriptionRecord.SourceType(rawValue: remote.sourceType) else { throw HistorySyncError.invalidCloudRecord }
            let item = TranscriptionRecord(title: remote.title, text: remote.text, sourceType: source,
                                           duration: remote.duration, createdAt: remote.createdAt)
            item.cloudID = cloud.recordID.recordName
            remote.apply(to: item)
            item.lastSyncedSnapshotJSON = json
            item.cloudRecordSystemFields = HistoryCloudRecordCodec.systemFields(of: cloud)
            if remote.cloudAudioID != nil { item.audioUploadedAt = Date() }
            modelContext.insert(item)
            return [item]
        }
        var changed = [local]
        let current = CloudHistorySnapshot(local)
        let base = CloudHistorySnapshot.decode(local.lastSyncedSnapshotJSON)
        let result = base.map { CloudHistorySnapshot.merged(base: $0, local: current, remote: remote) }
        // A local audio file that has not uploaded is also an unsynced edit.
        let unpublishedAudio = current.cloudAudioID == nil && local.audioFilePath != nil && remote.cloudAudioID != nil
        if (base == nil && current != remote) || result?.conflict == true || unpublishedAudio {
            let preserved = CloudHistorySnapshot.versionToPreserveOnConflict(base: base, local: current,
                remote: remote, merged: result?.value ?? remote)
            let copy = TranscriptionRecord(title: preserved.title, text: preserved.text,
                sourceType: local.sourceTypeEnum, duration: preserved.duration, createdAt: preserved.createdAt)
            preserved.apply(to: copy)
            copy.title += " (Conflict Copy)"
            if preserved.cloudAudioID == current.cloudAudioID,
               preserved.cloudAudioZoneName == current.cloudAudioZoneName, let path = local.audioFilePath {
                let original = try RecordingFileReference.fileURL(for: path)
                guard FileManager.default.fileExists(atPath: original.path) else { throw HistorySyncError.missingAudio }
                let duplicate = original.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).\(original.pathExtension)")
                try FileManager.default.copyItem(at: original, to: duplicate)
                createdFiles.append(duplicate)
                copy.audioFilePath = try RecordingFileReference.storedPath(for: duplicate)
            }
            copy.keepAudioOnDevice = local.keepAudioOnDevice
            if preserved.cloudAudioID != nil { copy.audioUploadedAt = Date() }
            modelContext.insert(copy)
            changed.append(copy)
        }
        let merged = result?.value ?? remote
        var path = local.audioFilePath
        if merged.cloudAudioID != current.cloudAudioID || merged.cloudAudioZoneName != current.cloudAudioZoneName {
            if let oldPath = path { filesToRemove.insert(try RecordingFileReference.fileURL(for: oldPath)) }
            path = nil
        }
        let keep = local.keepAudioOnDevice
        merged.apply(to: local)
        local.audioFilePath = path
        local.keepAudioOnDevice = keep
        local.lastSyncedSnapshotJSON = json
        local.cloudRecordSystemFields = HistoryCloudRecordCodec.systemFields(of: cloud)
        local.cloudDeletionConfirmed = false
        local.syncError = nil
        if remote.cloudAudioID != nil { local.audioUploadedAt = Date() }
        return changed
    }

    private func sendHistory(session: UUID) async throws -> Bool {
        guard let modelContext else { throw HistorySyncError.invalidCloudRecord }
        let pending = try allRecords().filter {
            !$0.cloudDeletionConfirmed &&
            (CloudHistorySnapshot($0).differs(fromEncodedSnapshot: $0.lastSyncedSnapshotJSON) || $0.cloudRecordSystemFields == nil)
        }
        var failed = false
        for start in stride(from: 0, to: pending.count, by: HistoryCloudSchema.batchSize) {
            try checkSession(session)
            let batch = pending[start..<min(pending.count, start + HistoryCloudSchema.batchSize)]
            var cloudRecords: [CKRecord] = []
            var snapshots: [String: String] = [:]
            var payloadFiles: [URL] = []
            defer { for url in payloadFiles { try? FileManager.default.removeItem(at: url) } }
            for local in batch where !local.isDeleted && !local.cloudDeletionConfirmed {
                let cloud = try local.cloudRecordSystemFields.map { try HistoryCloudRecordCodec.restoreRecord(from: $0) }
                    ?? CKRecord(recordType: "HistoryItem", recordID: HistoryCloudSchema.historyID(local.cloudID))
                guard cloud.recordID == HistoryCloudSchema.historyID(local.cloudID) else { throw HistorySyncError.invalidCloudRecord }
                let snapshot = CloudHistorySnapshot(local)
                payloadFiles.append(try HistoryCloudRecordCodec.write(snapshot, to: cloud,
                    modifiedAt: local.modifiedAt, directory: FileManager.default.temporaryDirectory))
                snapshots[local.cloudID] = snapshot.json
                cloudRecords.append(cloud)
            }
            guard !cloudRecords.isEmpty else { continue }
            let response = try await database.modify(saving: cloudRecords, deleting: [],
                savePolicy: .ifServerRecordUnchanged, allowCellular: settings.allowCellularSync)
            try checkSession(session)
            do {
                for saved in response.savedRecords {
                    guard let local = try allRecords().first(where: { $0.cloudID == saved.recordID.recordName }),
                          let json = snapshots[saved.recordID.recordName] else { throw HistorySyncError.invalidCloudRecord }
                    local.cloudRecordSystemFields = HistoryCloudRecordCodec.systemFields(of: saved)
                    local.lastSyncedSnapshotJSON = json
                    if local.audioFilePath == nil || local.cloudAudioID != nil { local.syncError = nil }
                }
                try saveChanges(modelContext)
            } catch { modelContext.rollback(); throw error }
            for (id, error) in response.errors {
                failed = true
                if let conflict = error as? CKError, conflict.code == .serverRecordChanged,
                   let server = conflict.serverRecord {
                    // The record returned with a save conflict omits asset data. Fetch the complete
                    // current history using the same field-selected API before merging it.
                    let remote = try await database.fetch(server.recordID, desiredKeys: HistoryCloudSchema.historyKeys,
                                                         allowCellular: settings.allowCellularSync)
                    try checkSession(session)
                    try applyPage(HistoryCloudPage(records: [remote], deletedRecords: [],
                                                  token: checkpoint.changeToken(), moreComing: false))
                } else if let local = try allRecords().first(where: { $0.cloudID == id.recordName }) {
                    local.syncError = error.localizedDescription
                    try saveChanges(modelContext)
                }
            }
        }
        NotificationCenter.default.post(name: Self.historyChanged, object: nil)
        return failed
    }

    private func fetchIfPresent(_ id: CKRecord.ID, keys: [String]?) async throws -> CKRecord? {
        do { return try await database.fetch(id, desiredKeys: keys, allowCellular: settings.allowCellularSync) }
        catch let error as CKError where error.code == .unknownItem { return nil }
    }

    private func saveOne(_ record: CKRecord, policy: CKModifyRecordsOperation.RecordSavePolicy) async throws -> CKRecord {
        let result = try await database.modify(saving: [record], deleting: [], savePolicy: policy,
                                              allowCellular: settings.allowCellularSync)
        if let error = result.errors[record.recordID] { throw error }
        guard let saved = result.savedRecords.first, saved.recordID == record.recordID else { throw HistorySyncError.invalidCloudRecord }
        return saved
    }

    private func deleteRecords(_ ids: [CKRecord.ID], session: UUID) async throws {
        for start in stride(from: 0, to: ids.count, by: HistoryCloudSchema.batchSize) {
            try checkSession(session)
            let batch = Array(ids[start..<min(ids.count, start + HistoryCloudSchema.batchSize)])
            let response = try await database.modify(saving: [], deleting: batch, savePolicy: .ifServerRecordUnchanged,
                                                     allowCellular: settings.allowCellularSync)
            try checkSession(session)
            for error in response.errors.values {
                if let cloudError = error as? CKError, cloudError.code == .unknownItem { continue }
                throw error
            }
        }
    }

    private func references(of record: TranscriptionRecord) throws -> [HistoryAudioReference] {
        var values: Set<HistoryAudioReference> = []
        if let id = record.cloudAudioID { values.insert(try HistoryAudioReference(audioID: id, zoneName: record.cloudAudioZoneName)) }
        if let id = record.pendingAudioID { values.insert(try HistoryAudioReference(audioID: id, zoneName: record.pendingAudioZoneName)) }
        return values.sorted { ($0.zoneName, $0.audioID) < ($1.zoneName, $1.audioID) }
    }

    private func owners(of manifest: CKRecord, reference: HistoryAudioReference) throws -> Set<String> {
        if manifest["ownerFormatVersion"] as? Int == 1 {
            guard let list = manifest["owners"] as? [String] else { throw HistorySyncError.invalidCloudRecord }
            return Set(list)
        }
        // Explicit migration of v1 manifests: the full history feed was applied before this step.
        return Set(try allRecords().filter { !$0.cloudDeletionConfirmed }
            .filter { try references(of: $0).contains(reference) }.map(\.cloudID))
    }

    private func setOwners(_ values: Set<String>, on manifest: CKRecord) {
        manifest["ownerFormatVersion"] = 1 as CKRecordValue
        manifest["owners"] = Array(values).sorted() as CKRecordValue
    }

    private func ensureAudioOwnership(_ record: TranscriptionRecord, session: UUID) async throws {
        if record.cloudAudioID != nil { try await ensureAudioOwner(record, session: session) }
        if let pending = record.pendingAudioID {
            let reference = try HistoryAudioReference(audioID: pending, zoneName: record.pendingAudioZoneName)
            let pendingManifest = try await fetchIfPresent(reference.recordID, keys: HistoryCloudSchema.manifestKeys)
            try checkSession(session)
            if let manifest = pendingManifest {
                guard manifest["deleting"] as? Int != 1 else { throw HistorySyncError.audioBeingDeleted }
                var values = try owners(of: manifest, reference: reference)
                if !values.contains(record.cloudID) || manifest["ownerFormatVersion"] == nil {
                    values.insert(record.cloudID)
                    setOwners(values, on: manifest)
                    _ = try await saveOne(manifest, policy: .ifServerRecordUnchanged)
                    try checkSession(session)
                }
            }
        }
    }

    private func ensureAudioOwner(_ record: TranscriptionRecord, session: UUID) async throws {
        guard let audioID = record.cloudAudioID else { return }
        let reference = try HistoryAudioReference(audioID: audioID, zoneName: record.cloudAudioZoneName)
        let manifest = try await database.fetch(reference.recordID, desiredKeys: HistoryCloudSchema.manifestKeys,
                                                 allowCellular: settings.allowCellularSync)
        try checkSession(session)
        try validateManifest(manifest, for: record)
        guard manifest["deleting"] as? Int != 1 else { throw HistorySyncError.audioBeingDeleted }
        var values = try owners(of: manifest, reference: reference)
        if values.contains(record.cloudID), manifest["ownerFormatVersion"] as? Int == 1 { return }
        values.insert(record.cloudID)
        if manifest["ownerFormatVersion"] == nil { manifest["uploadComplete"] = 1 as CKRecordValue }
        setOwners(values, on: manifest)
        _ = try await saveOne(manifest, policy: .ifServerRecordUnchanged)
        try checkSession(session)
    }

    private func validateManifest(_ manifest: CKRecord, for record: TranscriptionRecord) throws {
        guard manifest["chunks"] as? Int == record.cloudAudioChunkCount,
              manifest["bytes"] as? Int64 == record.cloudAudioByteCount,
              manifest["sha256"] as? String == record.cloudAudioSHA256,
              record.cloudAudioChunkCount > 0, record.cloudAudioByteCount > 0,
              manifest["deleting"] as? Int != 1 else { throw HistorySyncError.missingAudio }
        if manifest["ownerFormatVersion"] != nil, manifest["uploadComplete"] as? Int != 1 {
            throw HistorySyncError.incompleteUpload
        }
    }

    private func uploadAudio(for record: TranscriptionRecord, session: UUID) async throws {
        guard let modelContext, let path = record.audioFilePath else { throw HistorySyncError.missingAudio }
        let url = try RecordingFileReference.fileURL(for: path)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        if record.pendingAudioID == nil {
            record.pendingAudioID = UUID().uuidString
            record.pendingAudioZoneName = HistoryCloudSchema.audioZone.zoneName
            try saveChanges(modelContext)
        }
        let reference = try HistoryAudioReference(audioID: record.pendingAudioID!, zoneName: record.pendingAudioZoneName)
        let previous = try await fetchIfPresent(reference.recordID, keys: HistoryCloudSchema.manifestKeys)
        try checkSession(session)
        var manifest = previous ?? CKRecord(recordType: "AudioManifest", recordID: reference.recordID)
        var allocated = manifest["allocatedChunks"] as? Int ?? 0
        if previous == nil && reference.zoneName == HistoryCloudSchema.historyZone.zoneName {
            let existing = try await legacyChunkIDs(reference, session: session)
            let indices = existing.compactMap { Int($0.recordName.dropFirst(reference.audioID.count + 1)) }
            guard indices.count == existing.count else { throw HistorySyncError.invalidCloudRecord }
            allocated = (indices.max() ?? -1) + 1
        }
        guard manifest["deleting"] as? Int != 1 else { throw HistorySyncError.audioBeingDeleted }
        let previousOwners = try owners(of: manifest, reference: reference)
        guard previousOwners.isSubset(of: [record.cloudID]) else { throw HistorySyncError.invalidCloudRecord }
        setOwners([record.cloudID], on: manifest)
        manifest["allocatedChunks"] = allocated as CKRecordValue
        manifest["uploadComplete"] = 0 as CKRecordValue
        manifest = try await saveOne(manifest, policy: .ifServerRecordUnchanged)
        try checkSession(session)
        uploadingID = record.id
        uploadProgress = 0
        defer { uploadingID = nil; uploadProgress = 0 }
        let expectedSize = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        var hash = SHA256()
        var count = 0
        var total: Int64 = 0
        while let data = try handle.read(upToCount: HistoryCloudSchema.chunkSize), !data.isEmpty {
            try checkSession(session)
            guard !record.isDeleted, record.deletedAt == nil, record.audioFilePath == path,
                  record.pendingAudioID == reference.audioID else { throw HistorySyncError.editDuringTransfer }
            // Reserve the chunk on the server before writing it, so interrupted uploads are enumerable.
            allocated = max(allocated, count + 1)
            manifest["allocatedChunks"] = allocated as CKRecordValue
            manifest = try await saveOne(manifest, policy: .ifServerRecordUnchanged)
            try checkSession(session)
            let chunkURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try data.write(to: chunkURL, options: .atomic)
            defer { try? FileManager.default.removeItem(at: chunkURL) }
            let chunkID = try HistoryCloudSchema.audioID("\(reference.audioID)-\(count)", zoneName: reference.zoneName)
            let chunk = CKRecord(recordType: "AudioChunk", recordID: chunkID)
            chunk["audioID"] = reference.audioID as CKRecordValue
            chunk["index"] = count as CKRecordValue
            chunk["file"] = CKAsset(fileURL: chunkURL)
            _ = try await saveOne(chunk, policy: .allKeys)
            try checkSession(session)
            hash.update(data: data)
            total += Int64(data.count)
            count += 1
            if expectedSize > 0 { uploadProgress = min(1, Double(total) / Double(expectedSize)) }
        }
        guard total > 0, total == expectedSize, !record.isDeleted, record.deletedAt == nil,
              record.audioFilePath == path, record.pendingAudioID == reference.audioID else {
            throw HistorySyncError.incompleteUpload
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        manifest["chunks"] = count as CKRecordValue
        manifest["bytes"] = total as CKRecordValue
        manifest["sha256"] = digest as CKRecordValue
        manifest["extension"] = url.pathExtension as CKRecordValue
        manifest["uploadComplete"] = 1 as CKRecordValue
        _ = try await saveOne(manifest, policy: .ifServerRecordUnchanged)
        try checkSession(session)
        guard !record.isDeleted, record.deletedAt == nil, record.audioFilePath == path else {
            throw HistorySyncError.editDuringTransfer
        }
        record.cloudAudioID = reference.audioID
        record.cloudAudioZoneName = reference.zoneName
        record.cloudAudioByteCount = total
        record.cloudAudioChunkCount = count
        record.cloudAudioSHA256 = digest
        record.audioUploadedAt = Date()
        record.pendingAudioID = nil
        record.pendingAudioZoneName = nil
        record.modifiedAt = Date()
        record.syncError = nil
        try saveChanges(modelContext)
    }

    private func commitPurge(_ record: TranscriptionRecord, session: UUID) async throws {
        guard let modelContext else { throw HistorySyncError.invalidCloudRecord }
        let id = HistoryCloudSchema.historyID(record.cloudID)
        let expected = CloudHistorySnapshot(record)
        let remote = try await fetchIfPresent(id, keys: HistoryCloudSchema.historyKeys)
        try checkSession(session)
        guard !record.isDeleted, CloudHistorySnapshot(record) == expected else { throw HistorySyncError.editDuringTransfer }
        var purge: HistoryCloudPurge
        if let remote, remote["purgedAt"] != nil {
            purge = try HistoryCloudRecordCodec.purge(remote)
        } else {
            if let remote {
                let snapshot = try HistoryCloudRecordCodec.snapshot(remote)
                guard snapshot == expected,
                      let deletedAt = snapshot.deletedAt,
                      deletedAt.addingTimeInterval(HistoryCloudSchema.restoreInterval) <= Date() else {
                    // A restore/edit won before deletion. Merge it, and never remove its audio.
                    try applyPage(HistoryCloudPage(records: [remote], deletedRecords: [],
                                                  token: checkpoint.changeToken(), moreComing: false))
                    return
                }
            }
            purge = HistoryCloudPurge(historyID: record.cloudID, audio: try references(of: record))
            let tombstone = remote ?? CKRecord(recordType: "HistoryItem", recordID: id)
            try HistoryCloudRecordCodec.markPurged(tombstone, cleanup: purge, at: Date())
            // This conditional save is the deletion commit. If another device restored the record
            // after our fetch, its change tag makes this fail before any audio is touched.
            _ = try await saveOne(tombstone, policy: .ifServerRecordUnchanged)
            try checkSession(session)
        }
        purge.audio = Array(Set(purge.audio + (try references(of: record))))
        var updated = checkpoint
        updated.enqueue(purge)
        try checkpointStore.save(updated)
        checkpoint = updated
        if CloudHistorySnapshot(record) != expected {
            Self.detachAfterPurge(record, keepCloudAudio: true)
            try await ensureAudioOwnership(record, session: session)
        } else { record.cloudDeletionConfirmed = true }
        try saveChanges(modelContext)
    }

    private func processPendingPurges(session: UUID) async throws {
        for purge in checkpoint.pendingPurges {
            try checkSession(session)
            for reference in purge.audio { try await releaseAudio(reference, owner: purge.historyID, session: session) }
            if let local = try allRecords().first(where: { $0.cloudID == purge.historyID }), local.cloudDeletionConfirmed {
                try removeLocalPurgedRecord(local)
            }
            var updated = checkpoint
            updated.pendingPurges.removeAll { $0.historyID == purge.historyID }
            try checkpointStore.save(updated)
            checkpoint = updated
        }
        NotificationCenter.default.post(name: Self.historyChanged, object: nil)
    }

    private func releaseAudio(_ reference: HistoryAudioReference, owner: String, session: UUID) async throws {
        let manifest: CKRecord?
        do { manifest = try await fetchIfPresent(reference.recordID, keys: HistoryCloudSchema.manifestKeys) }
        catch let error as CKError where error.code == .zoneNotFound { return } // Deleting an absent zone has no remaining assets.
        try checkSession(session)
        if let local = try allRecords().first(where: { $0.cloudID == owner }),
           local.cloudDeletionConfirmed, Self.shouldPreserveAfterPurge(local) {
            Self.detachAfterPurge(local, keepCloudAudio: true)
            guard let modelContext else { throw HistorySyncError.invalidCloudRecord }
            try saveChanges(modelContext)
            try await ensureAudioOwnership(local, session: session)
            throw HistorySyncError.editDuringTransfer
        }
        guard let manifest else {
            if reference.zoneName == HistoryCloudSchema.historyZone.zoneName {
                // v1 interrupted uploads had chunks but no manifest. Scan only metadata, never assets.
                try await deleteRecords(legacyChunkIDs(reference, session: session), session: session)
            }
            return
        }
        var values = try owners(of: manifest, reference: reference)
        values.remove(owner)
        guard manifest["deleting"] as? Int != 1 || values.isEmpty else { throw HistorySyncError.invalidCloudRecord }
        setOwners(values, on: manifest)
        if values.isEmpty { manifest["deleting"] = 1 as CKRecordValue }
        _ = try await saveOne(manifest, policy: .ifServerRecordUnchanged)
        try checkSession(session)
        guard values.isEmpty else { return }
        let count: Int
        if let allocated = manifest["allocatedChunks"] as? Int { count = allocated }
        else if let complete = manifest["chunks"] as? Int { count = complete }
        else { throw HistorySyncError.invalidCloudRecord }
        guard count >= 0 else { throw HistorySyncError.invalidCloudRecord }
        let chunks = try (0..<count).map {
            try HistoryCloudSchema.audioID("\(reference.audioID)-\($0)", zoneName: reference.zoneName)
        }
        try await deleteRecords(chunks, session: session)
        try await deleteRecords([reference.recordID], session: session)
    }

    private func legacyChunkIDs(_ reference: HistoryAudioReference, session: UUID) async throws -> [CKRecord.ID] {
        var token: CKServerChangeToken?
        var more = true
        var ids: [CKRecord.ID] = []
        while more {
            let page = try await database.changes(in: reference.recordID.zoneID, since: token,
                                                 desiredKeys: ["audioID", "index"])
            try checkSession(session)
            ids.append(contentsOf: page.records.filter {
                $0.recordType == "AudioChunk" && $0["audioID"] as? String == reference.audioID
            }.map(\.recordID))
            token = page.token
            more = page.moreComing
        }
        return ids
    }

    private func removeLocalPurgedRecord(_ record: TranscriptionRecord) throws {
        guard let modelContext else { throw HistorySyncError.invalidCloudRecord }
        guard !Self.shouldPreserveAfterPurge(record) else { throw HistorySyncError.editDuringTransfer }
        let url = try record.audioFilePath.map { try RecordingFileReference.fileURL(for: $0) }
        let shared = try allRecords().contains { other in
            guard other.id != record.id, let path = other.audioFilePath else { return false }
            return try RecordingFileReference.fileURL(for: path) == url
        }
        var staged: URL?
        if let url, !shared, FileManager.default.fileExists(atPath: url.path) {
            let destination = url.deletingLastPathComponent()
                .appendingPathComponent(".deleting-\(UUID().uuidString)--\(url.lastPathComponent)")
            try FileManager.default.moveItem(at: url, to: destination)
            staged = destination
        }
        let id = record.id
        modelContext.delete(record)
        do { try saveChanges(modelContext) }
        catch {
            modelContext.rollback()
            if let staged, let url { try FileManager.default.moveItem(at: staged, to: url) }
            throw error
        }
        if let staged {
            do { try FileManager.default.removeItem(at: staged) }
            catch { AppLogger.error("Could not remove deleted recording", context: "HistoryCloudSync", error: error) }
        }
        TranscriptionSpotlightSync.delete(identifiers: [id])
    }

    private func removeExpiredLocalAudio(session: UUID) async throws {
        guard let modelContext else { throw HistorySyncError.invalidCloudRecord }
        let now = Date()
        for record in try allRecords() {
            try checkSession(session)
            guard !playingRecordIDs.contains(record.id), !record.keepAudioOnDevice, record.deletedAt == nil,
                  !record.audioFinalizationPending, let audioID = record.cloudAudioID, record.audioUploadedAt != nil,
                  let last = CloudHistorySnapshot.decode(record.lastSyncedSnapshotJSON),
                  last.cloudAudioID == audioID, last.cloudAudioZoneName == record.cloudAudioZoneName,
                  let path = record.audioFilePath,
                  record.createdAt.addingTimeInterval(Double(settings.audioRetentionDays) * 86400) < now,
                  (record.audioDownloadedAt == nil ||
                    (record.audioLastUsedAt ?? record.audioDownloadedAt!).addingTimeInterval(86400) < now) else { continue }
            let id = try HistoryCloudSchema.audioID(audioID, zoneName: record.cloudAudioZoneName)
            let manifest = try await database.fetch(id, desiredKeys: HistoryCloudSchema.manifestKeys,
                                                     allowCellular: settings.allowCellularSync)
            try checkSession(session)
            try validateManifest(manifest, for: record)
            // Recheck after the await: playback, pinning, deletion and file replacement can change.
            guard !record.isDeleted, record.deletedAt == nil, record.audioFilePath == path,
                  record.cloudAudioID == audioID, !record.keepAudioOnDevice,
                  !playingRecordIDs.contains(record.id) else { continue }
            let url = try RecordingFileReference.fileURL(for: path)
            let shared = try allRecords().contains { other in
                guard other.id != record.id, let otherPath = other.audioFilePath else { return false }
                return try RecordingFileReference.fileURL(for: otherPath) == url
            }
            guard !shared else { continue }
            try FileManager.default.removeItem(at: url)
            record.audioFilePath = nil
            try saveChanges(modelContext)
        }
    }

    func downloadAudio(for record: TranscriptionRecord, allowCellularOnce: Bool = false) async throws {
        let session = generation
        let originalPath = record.audioFilePath
        if let originalPath {
            let url = try RecordingFileReference.fileURL(for: originalPath)
            guard !FileManager.default.fileExists(atPath: url.path) else { throw HistorySyncError.editDuringTransfer }
        }
        try await verifyAccount()
        guard let audioID = record.cloudAudioID else { throw HistorySyncError.missingAudio }
        let zoneName = record.cloudAudioZoneName
        let allowCellular = settings.allowCellularSync || allowCellularOnce
        let manifestID = try HistoryCloudSchema.audioID(audioID, zoneName: zoneName)
        let manifest = try await database.fetch(manifestID, desiredKeys: HistoryCloudSchema.manifestKeys,
                                                 allowCellular: allowCellular)
        try validateManifest(manifest, for: record)
        guard let count = manifest["chunks"] as? Int, count > 0,
              let expectedBytes = manifest["bytes"] as? Int64,
              let expectedHash = manifest["sha256"] as? String,
              let fileExtension = manifest["extension"] as? String, !fileExtension.isEmpty,
              fileExtension.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
            throw HistorySyncError.invalidCloudRecord
        }
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(RecordingFileReference.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
        let partial = destination.appendingPathExtension("partial")
        guard FileManager.default.createFile(atPath: partial.path, contents: nil) else { throw HistorySyncError.missingAudio }
        let output = try FileHandle(forWritingTo: partial)
        var hash = SHA256()
        var bytes: Int64 = 0
        do {
            for index in 0..<count {
                try Task.checkCancellation()
                guard generation == session, !record.isDeleted, record.cloudAudioID == audioID,
                      record.cloudAudioZoneName == zoneName else { throw HistorySyncError.editDuringTransfer }
                let id = try HistoryCloudSchema.audioID("\(audioID)-\(index)", zoneName: zoneName)
                let chunk = try await database.fetch(id, desiredKeys: ["file"], allowCellular: allowCellular)
                guard let asset = chunk["file"] as? CKAsset, let fileURL = asset.fileURL else { throw HistorySyncError.invalidCloudRecord }
                let input = try FileHandle(forReadingFrom: fileURL)
                defer { try? input.close() }
                while let data = try input.read(upToCount: HistoryCloudSchema.chunkSize), !data.isEmpty {
                    try Task.checkCancellation()
                    hash.update(data: data)
                    bytes += Int64(data.count)
                    try output.write(contentsOf: data)
                }
            }
            try output.close()
            let actualHash = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard bytes == expectedBytes, actualHash == expectedHash else { throw HistorySyncError.audioVerificationFailed }
            try await verifyAccount()
            guard generation == session, !record.isDeleted, record.cloudAudioID == audioID,
                  record.cloudAudioZoneName == zoneName, record.audioFilePath == originalPath else { throw HistorySyncError.editDuringTransfer }
            try FileManager.default.moveItem(at: partial, to: destination)
            record.audioFilePath = try RecordingFileReference.storedPath(for: destination)
            record.audioDownloadedAt = Date()
            record.audioLastUsedAt = Date()
            record.audioUploadedAt = Date()
            do { try record.modelContext?.save() }
            catch {
                record.modelContext?.rollback()
                try FileManager.default.removeItem(at: destination)
                throw error
            }
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    func markAudioUsed(_ record: TranscriptionRecord) {
        record.audioLastUsedAt = Date()
        do { try record.modelContext?.save() }
        catch { record.syncError = error.localizedDescription; status = error.localizedDescription }
    }

    func setPlaying(_ playing: Bool, record: TranscriptionRecord) {
        if playing { playingRecordIDs.insert(record.id) }
        else { playingRecordIDs.remove(record.id) }
        markAudioUsed(record)
    }
}
