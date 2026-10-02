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
            local.cloudAudioByteCount != base.cloudAudioByteCount ||
            local.cloudAudioChunkCount != base.cloudAudioChunkCount ||
            local.cloudAudioSHA256 != base.cloudAudioSHA256
        let remoteAudioChanged = remote.cloudAudioID != base.cloudAudioID ||
            remote.cloudAudioByteCount != base.cloudAudioByteCount ||
            remote.cloudAudioChunkCount != base.cloudAudioChunkCount ||
            remote.cloudAudioSHA256 != base.cloudAudioSHA256
        if localAudioChanged && !remoteAudioChanged {
            value.cloudAudioID = local.cloudAudioID
            value.cloudAudioByteCount = local.cloudAudioByteCount
            value.cloudAudioChunkCount = local.cloudAudioChunkCount
            value.cloudAudioSHA256 = local.cloudAudioSHA256
        } else if localAudioChanged && remoteAudioChanged &&
                    (local.cloudAudioID != remote.cloudAudioID ||
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
        record.cloudAudioByteCount = cloudAudioByteCount
        record.cloudAudioChunkCount = cloudAudioChunkCount
        record.cloudAudioSHA256 = cloudAudioSHA256
    }
}

private enum HistorySyncError: LocalizedError {
    case differentAccount
    case noAccount
    case invalidCloudRecord
    case missingAudio
    case audioVerificationFailed
    case incompleteUpload
    case incompleteDeletion

    var errorDescription: String? {
        switch self {
        case .differentAccount: "The Apple Account changed. Sync is stopped to protect the previous account's history."
        case .noAccount: "Sign in to iCloud to sync history."
        case .invalidCloudRecord: "The iCloud history record is invalid."
        case .missingAudio: "The local recording file is missing."
        case .audioVerificationFailed: "The downloaded recording failed verification."
        case .incompleteUpload: "The recording upload did not finish. The local copy was kept."
        case .incompleteDeletion: "The iCloud history deletion did not finish. It will be retried."
        }
    }
}

private final class CloudOperationResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

@MainActor
final class HistoryCloudSync: ObservableObject, CKSyncEngineDelegate {
    static let shared = HistoryCloudSync()
    static let historyChanged = Notification.Name("HistoryCloudSync.historyChanged")
    static let containerID: String = {
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: "HistoryCloudKitContainerIdentifier") as? String,
              identifier.hasPrefix("iCloud.") else {
            fatalError("HistoryCloudKitContainerIdentifier is missing from Info.plist")
        }
        return identifier
    }()
    static let backgroundTaskID = "com.porarrirr.offlinewhispertranscriber.history-refresh"
    private static let zoneID = CKRecordZone.ID(zoneName: "History")
    private static let chunkSize = 8 * 1024 * 1024
    private static let accountKey = "historyCloudAccountRecordName"
    private static let engineStateKey = "historyCloudSyncEngineState"
    private static let legacyCloudIDMigrationKey = "historyCloudIDMigrationCompleted"

    @Published private(set) var status = "iCloud sync is off"
    @Published private(set) var isSyncing = false
    @Published private(set) var uploadingID: UUID?
    @Published private(set) var uploadProgress: Double = 0
    var isUsingCellular: Bool { path?.usesInterfaceType(.cellular) == true }

    private lazy var container = CKContainer(identifier: Self.containerID)
    private let settings = AppSettings.shared
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "HistoryCloudSync.network")
    private var path: NWPath?
    private var modelContext: ModelContext?
    private var engine: CKSyncEngine?
    private var syncTask: Task<Void, Never>?
    private var syncRequestedWhileRunning = false
    private var retryTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var playingRecordIDs: Set<UUID> = []

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.path = path
                self?.scheduleSync()
            }
        }
        monitor.start(queue: monitorQueue)
    }

    func configure(container modelContainer: ModelContainer) {
        modelContext = ModelContext(modelContainer)
        if settings.iCloudSyncEnabled {
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
            syncTask?.cancel()
            syncRequestedWhileRunning = false
            retryTask?.cancel()
            pollingTask?.cancel()
            pollingTask = nil
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundTaskID)
            Task { await engine?.cancelOperations() }
            engine = nil
            status = "iCloud sync is off"
        }
    }

    func performBackgroundRefresh(_ task: BGAppRefreshTask) {
        let work = Task { @MainActor in
            if let syncTask {
                await syncTask.value
            } else {
                await syncOnce()
            }
            task.setTaskCompleted(success: status == "Synced")
            scheduleBackgroundRefresh()
        }
        task.expirationHandler = { work.cancel() }
    }

    private func scheduleBackgroundRefresh() {
        guard settings.iCloudSyncEnabled else { return }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundTaskID)
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundTaskID)
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            AppLogger.error("Could not schedule history sync refresh", context: "HistoryCloudSync", error: error)
        }
    }

    private func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled else { break }
                self?.scheduleSync()
            }
        }
    }

    func syncStatus(for record: TranscriptionRecord) -> String? {
        guard settings.iCloudSyncEnabled else { return nil }
        if let error = record.syncError { return "Sync failed: \(error)" }
        if uploadingID == record.id { return "Uploading audio \(Int(uploadProgress * 100))%" }
        if let deletedAt = record.deletedAt,
           deletedAt.addingTimeInterval(30 * 24 * 60 * 60) <= Date() {
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
        if syncTask != nil {
            syncRequestedWhileRunning = true
            return
        }
        syncTask = Task { [weak self] in
            await self?.syncOnce()
            self?.syncTask = nil
            if self?.syncRequestedWhileRunning == true {
                self?.syncRequestedWhileRunning = false
                self?.scheduleSync()
            }
        }
    }

    private func syncOnce() async {
        guard settings.iCloudSyncEnabled, let modelContext else { return }
        guard path?.status == .satisfied,
              settings.allowCellularSync || path?.usesInterfaceType(.wifi) == true else {
            status = path?.status == .satisfied ? "Waiting for Wi-Fi" : "Waiting for network"
            return
        }
        isSyncing = true
        status = "Checking iCloud"
        defer { isSyncing = false }
        do {
            try await verifyAccount()
            let engine = try await prepareEngine()
            if !UserDefaults.standard.bool(forKey: Self.legacyCloudIDMigrationKey) {
                let preexisting = try modelContext.fetch(FetchDescriptor<TranscriptionRecord>())
                for item in preexisting where item.lastSyncedSnapshotJSON == nil && item.cloudRecordSystemFields == nil {
                    item.cloudID = item.id.uuidString
                }
                try modelContext.save()
                UserDefaults.standard.set(true, forKey: Self.legacyCloudIDMigrationKey)
            }
            try await engine.fetchChanges(fetchOptions())
            guard settings.iCloudSyncEnabled else { return }
            let records = try modelContext.fetch(FetchDescriptor<TranscriptionRecord>())
            for record in records {
                try Task.checkCancellation()
                if let deletedAt = record.deletedAt,
                   deletedAt <= Date().addingTimeInterval(-30 * 24 * 60 * 60) {
                    do {
                        try await purge(record, engine: engine)
                    } catch {
                        record.syncError = error.localizedDescription
                        try modelContext.save()
                        throw error
                    }
                    continue
                }
                if record.deletedAt == nil, !record.audioFinalizationPending,
                   record.cloudAudioID == nil, record.audioFilePath != nil {
                    do {
                        try await uploadAudio(for: record)
                    } catch {
                        record.syncError = error.localizedDescription
                        try modelContext.save()
                    }
                }
                if CloudHistorySnapshot(record).differs(fromEncodedSnapshot: record.lastSyncedSnapshotJSON) {
                    engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID(record.cloudID))])
                }
            }
            try await engine.sendChanges(sendOptions())
            removeExpiredLocalAudio()
            if records.contains(where: { $0.syncError != nil }) {
                status = "Some items failed to sync"
                scheduleRetry()
            } else {
                status = "Synced"
            }
        } catch is CancellationError {
            status = settings.iCloudSyncEnabled ? "Sync paused" : "iCloud sync is off"
        } catch {
            status = error.localizedDescription
            AppLogger.error("iCloud history sync failed", context: "HistoryCloudSync", error: error)
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        guard settings.iCloudSyncEnabled, retryTask == nil else { return }
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            self?.retryTask = nil
            self?.scheduleSync()
        }
    }

    private func verifyAccount() async throws {
        guard try await container.accountStatus() == .available else { throw HistorySyncError.noAccount }
        let current = try await container.userRecordID().recordName
        if let bound = UserDefaults.standard.string(forKey: Self.accountKey), bound != current {
            settings.iCloudSyncEnabled = false
            settingChanged()
            throw HistorySyncError.differentAccount
        }
        UserDefaults.standard.set(current, forKey: Self.accountKey)
    }

    private func prepareEngine() async throws -> CKSyncEngine {
        if let engine { return engine }
        let serialized = UserDefaults.standard.data(forKey: Self.engineStateKey)
            .flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        var configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: serialized,
            delegate: self
        )
        configuration.automaticallySync = false
        let engine = CKSyncEngine(configuration)
        self.engine = engine
        if serialized == nil {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
            try await engine.sendChanges(sendOptions())
        }
        return engine
    }

    private func fetchOptions() -> CKSyncEngine.FetchChangesOptions {
        let options = CKSyncEngine.FetchChangesOptions()
        options.operationGroup.defaultConfiguration.allowsCellularAccess = settings.allowCellularSync
        return options
    }

    private func sendOptions() -> CKSyncEngine.SendChangesOptions {
        let options = CKSyncEngine.SendChangesOptions()
        options.operationGroup.defaultConfiguration.allowsCellularAccess = settings.allowCellularSync
        return options
    }

    func nextFetchChangesOptions(
        _ context: CKSyncEngine.FetchChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.FetchChangesOptions {
        let options = context.options
        options.operationGroup.defaultConfiguration.allowsCellularAccess = settings.allowCellularSync
        return options
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard settings.iCloudSyncEnabled, let modelContext else { return nil }
        var records: [CKRecord] = []
        var deletions: [CKRecord.ID] = []
        for change in syncEngine.state.pendingRecordZoneChanges where context.options.scope.contains(change) {
            if case .deleteRecord(let id) = change {
                deletions.append(id)
                continue
            }
            guard case .saveRecord(let id) = change,
                  let local = try? modelContext.fetch(FetchDescriptor<TranscriptionRecord>()).first(where: { $0.cloudID == id.recordName }),
                  let json = CloudHistorySnapshot(local).json else { continue }
            let cloud: CKRecord
            if let fields = local.cloudRecordSystemFields {
                guard let restored = Self.restoreRecord(from: fields) else {
                    local.syncError = HistorySyncError.invalidCloudRecord.localizedDescription
                    continue
                }
                cloud = restored
            } else {
                cloud = CKRecord(recordType: "HistoryItem", recordID: id)
            }
            cloud["snapshot"] = json as CKRecordValue
            cloud["modifiedAt"] = local.modifiedAt as CKRecordValue
            records.append(cloud)
        }
        return records.isEmpty && deletions.isEmpty ? nil :
            CKSyncEngine.RecordZoneChangeBatch(recordsToSave: records, recordIDsToDelete: deletions)
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard let modelContext else { return }
        do {
            switch event {
            case .stateUpdate(let update):
                let data = try JSONEncoder().encode(update.stateSerialization)
                UserDefaults.standard.set(data, forKey: Self.engineStateKey)
            case .accountChange(let change):
                switch change.changeType {
                case .switchAccounts:
                    settings.iCloudSyncEnabled = false
                    settingChanged()
                    status = HistorySyncError.differentAccount.localizedDescription
                    await syncEngine.cancelOperations()
                    engine = nil
                case .signOut:
                    settings.iCloudSyncEnabled = false
                    settingChanged()
                    status = HistorySyncError.noAccount.localizedDescription
                    await syncEngine.cancelOperations()
                    engine = nil
                case .signIn: break
                @unknown default:
                    settings.iCloudSyncEnabled = false
                    settingChanged()
                    status = HistorySyncError.differentAccount.localizedDescription
                }
            case .fetchedRecordZoneChanges(let changes):
                var removedIDs: [UUID] = []
                var preservedRecords: [TranscriptionRecord] = []
                var filesToRemove: Set<URL> = []
                var createdFiles: [URL] = []
                var createdConflictCopies: [TranscriptionRecord] = []
                var obsoletePendingSaves: [CKRecord.ID] = []
                do {
                    for modification in changes.modifications where modification.record.recordType == "HistoryItem" {
                        try merge(modification.record, in: modelContext,
                                  filesToRemove: &filesToRemove, createdFiles: &createdFiles,
                                  createdConflictCopies: &createdConflictCopies)
                    }
                    for deletion in changes.deletions where deletion.recordType == "HistoryItem" {
                        guard let local = try modelContext.fetch(FetchDescriptor<TranscriptionRecord>())
                            .first(where: { $0.cloudID == deletion.recordID.recordName }) else { continue }
                        if CloudHistorySnapshot.needsPreservationAfterCloudDeletion(local) {
                            let oldID = recordID(local.cloudID)
                            Self.preserveLocalRecordAfterCloudDeletion(local)
                            preservedRecords.append(local)
                            obsoletePendingSaves.append(oldID)
                        } else {
                            if let path = local.audioFilePath {
                                filesToRemove.insert(try RecordingFileReference.fileURL(for: path))
                            }
                            removedIDs.append(local.id)
                            modelContext.delete(local)
                        }
                    }
                    try modelContext.save()
                } catch {
                    modelContext.rollback()
                    for url in createdFiles { try? FileManager.default.removeItem(at: url) }
                    throw error
                }
                syncEngine.state.remove(pendingRecordZoneChanges: obsoletePendingSaves.map { .saveRecord($0) })
                let stillReferencedFiles = Set(try modelContext.fetch(FetchDescriptor<TranscriptionRecord>())
                    .compactMap { $0.audioFilePath }
                    .compactMap { try? RecordingFileReference.fileURL(for: $0) })
                for url in filesToRemove.subtracting(stillReferencedFiles) where FileManager.default.fileExists(atPath: url.path) {
                    do {
                        try FileManager.default.removeItem(at: url)
                    } catch {
                        AppLogger.error("Could not remove obsolete recording", context: "HistoryCloudSync", error: error)
                    }
                }
                for record in preservedRecords { TranscriptionSpotlightSync.index(record) }
                for record in createdConflictCopies { TranscriptionSpotlightSync.index(record) }
                for modification in changes.modifications where modification.record.recordType == "HistoryItem" {
                    if let item = try modelContext.fetch(FetchDescriptor<TranscriptionRecord>())
                        .first(where: { $0.cloudID == modification.record.recordID.recordName }) {
                        if item.deletedAt == nil {
                            TranscriptionSpotlightSync.index(item)
                        } else {
                            removedIDs.append(item.id)
                        }
                    }
                }
                if !removedIDs.isEmpty { TranscriptionSpotlightSync.delete(identifiers: removedIDs) }
                NotificationCenter.default.post(name: Self.historyChanged, object: nil)
            case .sentRecordZoneChanges(let changes):
                for saved in changes.savedRecords where saved.recordType == "HistoryItem" {
                    if let local = try modelContext.fetch(FetchDescriptor<TranscriptionRecord>())
                        .first(where: { $0.cloudID == saved.recordID.recordName }) {
                        local.cloudRecordSystemFields = Self.systemFields(of: saved)
                        local.lastSyncedSnapshotJSON = saved["snapshot"] as? String
                        if local.audioFilePath == nil || local.cloudAudioID != nil {
                            local.syncError = nil
                        }
                    }
                }
                for failed in changes.failedRecordSaves {
                    if let local = try modelContext.fetch(FetchDescriptor<TranscriptionRecord>())
                        .first(where: { $0.cloudID == failed.record.recordID.recordName }) {
                        local.syncError = failed.error.localizedDescription
                    }
                }
                for deletedID in changes.deletedRecordIDs where deletedID.zoneID == Self.zoneID {
                    if let local = try modelContext.fetch(FetchDescriptor<TranscriptionRecord>())
                        .first(where: { $0.cloudID == deletedID.recordName }) {
                        local.cloudDeletionConfirmed = true
                    }
                }
                for (deletedID, error) in changes.failedRecordDeletes where deletedID.zoneID == Self.zoneID {
                    if let local = try modelContext.fetch(FetchDescriptor<TranscriptionRecord>())
                        .first(where: { $0.cloudID == deletedID.recordName }) {
                        if error.code == .unknownItem {
                            local.cloudDeletionConfirmed = true
                            syncEngine.state.remove(pendingRecordZoneChanges: [.deleteRecord(deletedID)])
                        } else {
                            local.syncError = error.localizedDescription
                        }
                    }
                }
                try modelContext.save()
                NotificationCenter.default.post(name: Self.historyChanged, object: nil)
            default: break
            }
        } catch {
            status = error.localizedDescription
            AppLogger.error("iCloud history event failed", context: "HistoryCloudSync", error: error)
        }
    }

    static func preserveLocalRecordAfterCloudDeletion(_ record: TranscriptionRecord) {
        record.cloudID = UUID().uuidString
        record.cloudRecordSystemFields = nil
        record.lastSyncedSnapshotJSON = nil
        record.cloudDeletionConfirmed = false
        record.cloudAudioID = nil
        record.cloudAudioByteCount = 0
        record.cloudAudioChunkCount = 0
        record.cloudAudioSHA256 = nil
        record.audioUploadedAt = nil
        record.title += " (Conflict Copy)"
        record.modifiedAt = Date()
        record.syncError = nil
    }

    private func merge(
        _ cloud: CKRecord,
        in context: ModelContext,
        filesToRemove: inout Set<URL>,
        createdFiles: inout [URL],
        createdConflictCopies: inout [TranscriptionRecord]
    ) throws {
        guard let json = cloud["snapshot"] as? String,
              let remote = CloudHistorySnapshot.decode(json) else { throw HistorySyncError.invalidCloudRecord }
        let local = try context.fetch(FetchDescriptor<TranscriptionRecord>())
            .first(where: { $0.cloudID == cloud.recordID.recordName })
        guard let local else {
            guard let sourceType = TranscriptionRecord.SourceType(rawValue: remote.sourceType) else {
                throw HistorySyncError.invalidCloudRecord
            }
            let item = TranscriptionRecord(title: remote.title, text: remote.text,
                sourceType: sourceType,
                duration: remote.duration, createdAt: remote.createdAt)
            item.cloudID = cloud.recordID.recordName
            remote.apply(to: item)
            if remote.cloudAudioID != nil { item.audioUploadedAt = Date() }
            item.lastSyncedSnapshotJSON = json
            item.cloudRecordSystemFields = Self.systemFields(of: cloud)
            context.insert(item)
            return
        }
        let current = CloudHistorySnapshot(local)
        let base = CloudHistorySnapshot.decode(local.lastSyncedSnapshotJSON)
        let merge = base.map { CloudHistorySnapshot.merged(base: $0, local: current, remote: remote) }
        if (base == nil && current != remote) || merge?.conflict == true {
            let preserved = CloudHistorySnapshot.versionToPreserveOnConflict(
                base: base, local: current, remote: remote, merged: merge?.value ?? remote)
            let matchingLocalAudio = preserved.cloudAudioID == current.cloudAudioID
            let copy = TranscriptionRecord(title: preserved.title, text: preserved.text,
                sourceType: local.sourceTypeEnum,
                duration: local.duration, createdAt: local.createdAt)
            preserved.apply(to: copy)
            copy.title += " (Conflict Copy)"
            if matchingLocalAudio, let path = local.audioFilePath,
               let original = try? RecordingFileReference.fileURL(for: path),
               FileManager.default.fileExists(atPath: original.path) {
                let duplicate = original.deletingLastPathComponent()
                    .appendingPathComponent("\(UUID().uuidString).\(original.pathExtension)")
                try FileManager.default.copyItem(at: original, to: duplicate)
                createdFiles.append(duplicate)
                copy.audioFilePath = try RecordingFileReference.storedPath(for: duplicate)
            }
            if preserved.cloudAudioID != nil { copy.audioUploadedAt = Date() }
            copy.keepAudioOnDevice = local.keepAudioOnDevice
            context.insert(copy)
            createdConflictCopies.append(copy)
        }
        let merged = merge?.value ?? remote
        var path = local.audioFilePath
        if merged.cloudAudioID != current.cloudAudioID, let oldPath = path {
            let oldURL = try RecordingFileReference.fileURL(for: oldPath)
            filesToRemove.insert(oldURL)
            path = nil
        }
        let keep = local.keepAudioOnDevice
        merged.apply(to: local)
        if remote.cloudAudioID != nil { local.audioUploadedAt = Date() }
        local.audioFilePath = path
        local.keepAudioOnDevice = keep
        local.lastSyncedSnapshotJSON = json
        local.cloudRecordSystemFields = Self.systemFields(of: cloud)
        local.syncError = nil
    }

    private func recordID(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: Self.zoneID)
    }

    private static func systemFields(of record: CKRecord) -> Data? {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    private static func restoreRecord(from data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }

    private func uploadAudio(for record: TranscriptionRecord) async throws {
        guard let path = record.audioFilePath else { return }
        let url = try RecordingFileReference.fileURL(for: path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw HistorySyncError.missingAudio }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let audioID = record.pendingAudioID ?? UUID().uuidString
        record.pendingAudioID = audioID
        try modelContext?.save()
        uploadingID = record.id
        uploadProgress = 0
        defer { uploadingID = nil; uploadProgress = 0 }
        let expectedSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        var hash = SHA256()
        var count = 0
        var total: Int64 = 0
        status = "Uploading audio: \(record.displayTitle)"
        while let data = try handle.read(upToCount: Self.chunkSize), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
            total += Int64(data.count)
            let chunkURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try data.write(to: chunkURL, options: .atomic)
            defer { try? FileManager.default.removeItem(at: chunkURL) }
            let chunk = CKRecord(recordType: "AudioChunk", recordID: recordID("\(audioID)-\(count)"))
            chunk["audioID"] = audioID as CKRecordValue
            chunk["index"] = count as CKRecordValue
            chunk["file"] = CKAsset(fileURL: chunkURL)
            _ = try await save(chunk)
            count += 1
            if expectedSize > 0 { uploadProgress = min(1, Double(total) / Double(expectedSize)) }
        }
        guard total > 0 else { throw HistorySyncError.incompleteUpload }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        let manifest = CKRecord(recordType: "AudioManifest", recordID: recordID(audioID))
        manifest["chunks"] = count as CKRecordValue
        manifest["bytes"] = total as CKRecordValue
        manifest["sha256"] = digest as CKRecordValue
        manifest["extension"] = url.pathExtension as CKRecordValue
        _ = try await save(manifest)
        record.cloudAudioID = audioID
        record.cloudAudioByteCount = total
        record.cloudAudioChunkCount = count
        record.cloudAudioSHA256 = digest
        record.audioUploadedAt = Date()
        record.pendingAudioID = nil
        record.modifiedAt = Date()
        record.syncError = nil
        try modelContext?.save()
    }

    private func save(_ record: CKRecord) async throws -> CKRecord {
        let operation = CKModifyRecordsOperation(recordsToSave: [record])
        operation.savePolicy = .allKeys
        operation.configuration.allowsCellularAccess = settings.allowCellularSync
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CKRecord, Error>) in
                let result = CloudOperationResult<CKRecord>(continuation)
                operation.perRecordSaveBlock = { _, item in result.finish(item) }
                operation.modifyRecordsResultBlock = { completion in
                    switch completion {
                    case .failure(let error): result.finish(.failure(error))
                    case .success: result.finish(.failure(HistorySyncError.invalidCloudRecord))
                    }
                }
                container.privateCloudDatabase.add(operation)
            }
        } onCancel: {
            operation.cancel()
        }
    }

    private func fetch(_ id: CKRecord.ID, allowCellular: Bool) async throws -> CKRecord {
        let operation = CKFetchRecordsOperation(recordIDs: [id])
        operation.configuration.allowsCellularAccess = allowCellular
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CKRecord, Error>) in
                let result = CloudOperationResult<CKRecord>(continuation)
                operation.perRecordResultBlock = { _, item in result.finish(item) }
                operation.fetchRecordsResultBlock = { completion in
                    switch completion {
                    case .failure(let error): result.finish(.failure(error))
                    case .success: result.finish(.failure(HistorySyncError.invalidCloudRecord))
                    }
                }
                container.privateCloudDatabase.add(operation)
            }
        } onCancel: {
            operation.cancel()
        }
    }

    func downloadAudio(for record: TranscriptionRecord, allowCellularOnce: Bool = false) async throws {
        try await verifyAccount()
        guard let audioID = record.cloudAudioID else { throw HistorySyncError.missingAudio }
        let allowCellular = settings.allowCellularSync || allowCellularOnce
        let manifest = try await fetch(recordID(audioID), allowCellular: allowCellular)
        guard let count = manifest["chunks"] as? Int,
              let expectedBytes = manifest["bytes"] as? Int64,
              let expectedHash = manifest["sha256"] as? String,
              count == record.cloudAudioChunkCount,
              expectedBytes == record.cloudAudioByteCount,
              expectedHash == record.cloudAudioSHA256,
              let fileExtension = manifest["extension"] as? String,
              !fileExtension.isEmpty,
              fileExtension.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) })
        else { throw HistorySyncError.invalidCloudRecord }
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(RecordingFileReference.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
        let partial = destination.appendingPathExtension("partial")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let output = try FileHandle(forWritingTo: partial)
        var hash = SHA256()
        var bytes: Int64 = 0
        do {
            for index in 0..<count {
                let chunk = try await fetch(recordID("\(audioID)-\(index)"), allowCellular: allowCellular)
                guard let asset = chunk["file"] as? CKAsset, let fileURL = asset.fileURL else {
                    throw HistorySyncError.invalidCloudRecord
                }
                let input = try FileHandle(forReadingFrom: fileURL)
                while let data = try input.read(upToCount: Self.chunkSize), !data.isEmpty {
                    hash.update(data: data)
                    bytes += Int64(data.count)
                    try output.write(contentsOf: data)
                }
                try input.close()
            }
            try output.close()
            let actualHash = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard bytes == expectedBytes, actualHash == expectedHash else {
                throw HistorySyncError.audioVerificationFailed
            }
            try FileManager.default.moveItem(at: partial, to: destination)
            record.audioFilePath = try RecordingFileReference.storedPath(for: destination)
            record.audioDownloadedAt = Date()
            record.audioLastUsedAt = Date()
            record.audioUploadedAt = Date()
            try record.modelContext?.save()
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    func markAudioUsed(_ record: TranscriptionRecord) {
        record.audioLastUsedAt = Date()
        do {
            try record.modelContext?.save()
        } catch {
            record.syncError = error.localizedDescription
            status = error.localizedDescription
        }
    }

    func setPlaying(_ playing: Bool, record: TranscriptionRecord) {
        if playing {
            playingRecordIDs.insert(record.id)
            markAudioUsed(record)
        } else {
            playingRecordIDs.remove(record.id)
            markAudioUsed(record)
        }
    }

    func removeExpiredLocalAudio(playingID: UUID? = nil) {
        guard settings.iCloudSyncEnabled, let modelContext,
              let records = try? modelContext.fetch(FetchDescriptor<TranscriptionRecord>()) else { return }
        let now = Date()
        for record in records {
            guard record.id != playingID, !playingRecordIDs.contains(record.id), !record.keepAudioOnDevice,
                  record.deletedAt == nil,
                  record.cloudAudioID != nil, record.audioUploadedAt != nil,
                  CloudHistorySnapshot.decode(record.lastSyncedSnapshotJSON)?.cloudAudioID == record.cloudAudioID,
                  let path = record.audioFilePath,
                  record.createdAt.addingTimeInterval(Double(settings.audioRetentionDays) * 86400) < now,
                  (record.audioDownloadedAt == nil ||
                    (record.audioLastUsedAt ?? record.audioDownloadedAt!).addingTimeInterval(86400) < now),
                  let url = try? RecordingFileReference.fileURL(for: path) else { continue }
            do {
                try FileManager.default.removeItem(at: url)
                record.audioFilePath = nil
            } catch {
                record.syncError = error.localizedDescription
            }
        }
        do {
            try modelContext.save()
        } catch {
            status = error.localizedDescription
        }
    }

    private func purge(_ record: TranscriptionRecord, engine: CKSyncEngine) async throws {
        guard let modelContext else { return }
        let allRecords = try modelContext.fetch(FetchDescriptor<TranscriptionRecord>())
        let localAudioURL = try record.audioFilePath.map { try RecordingFileReference.fileURL(for: $0) }
        let localAudioIsShared: Bool
        if let localAudioURL {
            localAudioIsShared = try allRecords.contains { other in
                guard other.id != record.id, let path = other.audioFilePath else { return false }
                return try RecordingFileReference.fileURL(for: path) == localAudioURL
            }
        } else {
            localAudioIsShared = false
        }
        let otherReferences = allRecords.contains {
            $0.id != record.id && $0.cloudAudioID == record.cloudAudioID
        }
        if let audioID = record.cloudAudioID, !otherReferences {
            guard record.cloudAudioChunkCount > 0 else { throw HistorySyncError.invalidCloudRecord }
            for index in 0..<record.cloudAudioChunkCount {
                try await delete(recordID("\(audioID)-\(index)"))
            }
            try await delete(recordID(audioID))
        }
        let historyRecordID = recordID(record.cloudID)
        engine.state.remove(pendingRecordZoneChanges: [.saveRecord(historyRecordID)])
        if !record.cloudDeletionConfirmed {
            let deletion = CKSyncEngine.PendingRecordZoneChange.deleteRecord(historyRecordID)
            engine.state.add(pendingRecordZoneChanges: [deletion])
            try await engine.sendChanges(sendOptions())
            guard record.cloudDeletionConfirmed else { throw HistorySyncError.incompleteDeletion }
        }
        var stagedAudio: URL?
        if let localAudioURL, !localAudioIsShared,
           FileManager.default.fileExists(atPath: localAudioURL.path) {
            let stagedURL = localAudioURL.deletingLastPathComponent()
                .appendingPathComponent(".deleting-\(UUID().uuidString)--\(localAudioURL.lastPathComponent)")
            try FileManager.default.moveItem(at: localAudioURL, to: stagedURL)
            stagedAudio = stagedURL
        }
        modelContext.delete(record)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            if let stagedAudio, let localAudioURL {
                do {
                    try FileManager.default.moveItem(at: stagedAudio, to: localAudioURL)
                } catch {
                    AppLogger.error("Could not restore recording after history deletion failed",
                        context: "HistoryCloudSync", error: error)
                    throw error
                }
            }
            throw error
        }
        if let stagedAudio {
            do {
                try FileManager.default.removeItem(at: stagedAudio)
            } catch {
                AppLogger.error("Could not remove deleted recording", context: "HistoryCloudSync", error: error)
            }
        }
    }

    private func delete(_ id: CKRecord.ID) async throws {
        let operation = CKModifyRecordsOperation(recordIDsToDelete: [id])
        operation.configuration.allowsCellularAccess = settings.allowCellularSync
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let result = CloudOperationResult<Void>(continuation)
                    operation.perRecordDeleteBlock = { _, item in result.finish(item) }
                    operation.modifyRecordsResultBlock = { completion in
                        switch completion {
                        case .failure(let error): result.finish(.failure(error))
                        case .success: result.finish(.failure(HistorySyncError.invalidCloudRecord))
                        }
                    }
                    container.privateCloudDatabase.add(operation)
                }
            } onCancel: {
                operation.cancel()
            }
        } catch let error as CKError where error.code == .unknownItem {
            // A previous purge may have removed this chunk before interruption.
            return
        }
    }
}
