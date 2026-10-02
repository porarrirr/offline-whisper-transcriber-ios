import CloudKit
import SwiftData
import XCTest
@testable import WhisperTranscriptionApp

@MainActor
final class HistoryCloudSyncTests: XCTestCase {
    private enum Fault: Error { case diskFull, disconnected }

    private final class Preferences: HistoryCloudSyncPreferences {
        var iCloudSyncEnabled = true
        var allowCellularSync = false
        var audioRetentionDays = 1
    }

    private final class SaveFault {
        var failNextSave = false
        func save(_ context: ModelContext) throws {
            if failNextSave { failNextSave = false; throw Fault.diskFull }
            try context.save()
        }
    }

    /// Models server durability and fault timing without accessing an Apple Account.
    private final class Database: HistoryCloudDatabase {
        var allowCellular = false
        var account = "test-account"
        var zones: Set<CKRecordZone.ID> = [HistoryCloudSchema.historyZone, HistoryCloudSchema.audioZone]
        var records: [CKRecord.ID: CKRecord] = [:]
        var changeRequests: [(zone: CKRecordZone.ID, keys: [String])] = []
        var fetchRequests: [(id: CKRecord.ID, keys: [String]?)] = []
        var saveBatches: [[CKRecord.ID]] = []
        var deletedIDs: [CKRecord.ID] = []
        var policies: [CKModifyRecordsOperation.RecordSavePolicy] = []
        var operations: [String] = []
        var cancellationCount = 0
        var onChanges: (() throws -> Void)?
        var onSave: ((CKRecord) throws -> Error?)?
        var onFetch: ((CKRecord.ID) throws -> Void)?
        let directory: URL

        init(directory: URL) { self.directory = directory }
        func accountRecordName() async throws -> String { account }
        func zoneIDs() async throws -> Set<CKRecordZone.ID> { zones }
        func createZones(_ ids: Set<CKRecordZone.ID>) async throws { zones.formUnion(ids) }
        func cancelOperations() { cancellationCount += 1 }

        func copy(_ record: CKRecord, keys: [String]? = nil) throws -> CKRecord {
            let output = CKRecord(recordType: record.recordType, recordID: record.recordID)
            for key in record.allKeys() where keys == nil || keys!.contains(key) {
                if let asset = record[key] as? CKAsset, let source = asset.fileURL {
                    let destination = directory.appendingPathComponent(UUID().uuidString)
                    try FileManager.default.copyItem(at: source, to: destination)
                    output[key] = CKAsset(fileURL: destination)
                } else { output[key] = record[key] }
            }
            return output
        }

        func changes(in zone: CKRecordZone.ID, since token: CKServerChangeToken?, desiredKeys: [String]) async throws -> HistoryCloudPage {
            changeRequests.append((zone, desiredKeys))
            try onChanges?()
            guard zones.contains(zone) else { throw CKError(.zoneNotFound) }
            let values = try records.values.filter { $0.recordID.zoneID == zone }
                .sorted { $0.recordID.recordName < $1.recordID.recordName }
                .map { try copy($0, keys: desiredKeys) }
            return HistoryCloudPage(records: values, deletedRecords: [], token: nil, moreComing: false)
        }

        func fetch(_ id: CKRecord.ID, desiredKeys: [String]?, allowCellular: Bool) async throws -> CKRecord {
            fetchRequests.append((id, desiredKeys))
            try onFetch?(id)
            guard zones.contains(id.zoneID) else { throw CKError(.zoneNotFound) }
            guard let record = records[id] else { throw CKError(.unknownItem) }
            return try copy(record, keys: desiredKeys)
        }

        func modify(saving values: [CKRecord], deleting ids: [CKRecord.ID],
                    savePolicy: CKModifyRecordsOperation.RecordSavePolicy, allowCellular: Bool) async throws -> HistoryCloudModifyResult {
            policies.append(savePolicy)
            if !values.isEmpty { saveBatches.append(values.map(\.recordID)) }
            var result = HistoryCloudModifyResult()
            for record in values {
                if let error = try onSave?(record) { result.errors[record.recordID] = error; continue }
                let durable = try copy(record)
                records[record.recordID] = durable
                result.savedRecords.append(try copy(durable))
                operations.append(record["purgedAt"] == nil ? "save:\(record.recordID.recordName)" : "purge:\(record.recordID.recordName)")
            }
            for id in ids {
                operations.append("delete:\(id.recordName)")
                deletedIDs.append(id)
                if records.removeValue(forKey: id) != nil { result.deletedRecordIDs.append(id) }
                else { result.errors[id] = CKError(.unknownItem) }
            }
            return result
        }
    }

    @MainActor
    private final class Environment {
        let directory: URL
        let database: Database
        let preferences = Preferences()
        let fault = SaveFault()
        let container: ModelContainer
        let context: ModelContext
        let store: HistoryCloudCheckpointStore
        let sync: HistoryCloudSync
        let defaults: UserDefaults
        let suite: String

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryCloudSyncTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            database = Database(directory: directory)
            store = HistoryCloudCheckpointStore(url: directory.appendingPathComponent("checkpoint.json"))
            suite = "HistoryCloudSyncTests.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            defaults.set(true, forKey: "historyCloudIDMigrationCompleted")
            let configuration = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            container = try ModelContainer(for: TranscriptionRecord.self, configurations: configuration)
            context = ModelContext(container)
            context.autosaveEnabled = false
            let fault = fault
            sync = HistoryCloudSync(database: database, preferences: preferences, checkpointStore: store,
                                    defaults: defaults, networkCheck: { true }, saveChanges: { try fault.save($0) })
            sync.configure(container: container, startSync: false)
        }

        func close() throws {
            preferences.iCloudSyncEnabled = false
            sync.settingChanged()
            defaults.removePersistentDomain(forName: suite)
            try FileManager.default.removeItem(at: directory)
        }

        func localRecords() throws -> [TranscriptionRecord] {
            try ModelContext(container).fetch(FetchDescriptor<TranscriptionRecord>())
        }

        func record(title: String = "Original", deleted: Bool = false, audio: String? = nil) throws -> TranscriptionRecord {
            let record = TranscriptionRecord(title: title, text: "Saved body", sourceType: .recording,
                duration: 10, createdAt: Date().addingTimeInterval(-40 * 86400))
            if deleted { record.deletedAt = Date().addingTimeInterval(-31 * 86400) }
            if let audio {
                record.cloudAudioID = audio
                record.cloudAudioZoneName = HistoryCloudSchema.audioZone.zoneName
                record.cloudAudioChunkCount = 1
                record.cloudAudioByteCount = 100
                record.cloudAudioSHA256 = "digest"
                record.audioUploadedAt = Date()
            }
            context.insert(record)
            let cloud = CKRecord(recordType: "HistoryItem", recordID: HistoryCloudSchema.historyID(record.cloudID))
            cloud["snapshot"] = CloudHistorySnapshot(record).json as CKRecordValue?
            record.lastSyncedSnapshotJSON = CloudHistorySnapshot(record).json
            record.cloudRecordSystemFields = HistoryCloudRecordCodec.systemFields(of: cloud)
            database.records[cloud.recordID] = cloud
            try context.save()
            return record
        }

        func audio(_ audioID: String, owners: [String], count: Int = 1, complete: Bool = true) {
            let id = CKRecord.ID(recordName: audioID, zoneID: HistoryCloudSchema.audioZone)
            let manifest = CKRecord(recordType: "AudioManifest", recordID: id)
            manifest["allocatedChunks"] = count as CKRecordValue
            manifest["chunks"] = count as CKRecordValue
            manifest["bytes"] = 100 as CKRecordValue
            manifest["sha256"] = "digest" as CKRecordValue
            manifest["extension"] = "m4a" as CKRecordValue
            manifest["owners"] = owners as CKRecordValue
            manifest["ownerFormatVersion"] = 1 as CKRecordValue
            manifest["uploadComplete"] = (complete ? 1 : 0) as CKRecordValue
            database.records[id] = manifest
            for index in 0..<count {
                let chunkID = CKRecord.ID(recordName: "\(audioID)-\(index)", zoneID: HistoryCloudSchema.audioZone)
                let chunk = CKRecord(recordType: "AudioChunk", recordID: chunkID)
                chunk["audioID"] = audioID as CKRecordValue
                chunk["index"] = index as CKRecordValue
                database.records[chunkID] = chunk
            }
        }
    }

    private func environment() throws -> Environment {
        let value = try Environment()
        addTeardownBlock { @MainActor in try value.close() }
        return value
    }

    func testReceiveSaveFailureRollsBackAndReplaysWithoutSendingOrDeleting() async throws {
        let env = try environment()
        let remote = CKRecord(recordType: "HistoryItem", recordID: HistoryCloudSchema.historyID("remote"))
        let record = TranscriptionRecord(title: "Remote", text: "Remote text", sourceType: .file, duration: 12)
        remote["snapshot"] = CloudHistorySnapshot(record).json as CKRecordValue?
        env.database.records[remote.recordID] = remote
        env.fault.failNextSave = true

        await env.sync.syncOnce()

        XCTAssertTrue(try env.localRecords().isEmpty)
        XCTAssertTrue(env.database.saveBatches.isEmpty)
        XCTAssertTrue(env.database.deletedIDs.isEmpty)
        XCTAssertNil(try env.store.load().token)
        XCTAssertNotEqual(env.sync.status, "Synced")

        await env.sync.syncOnce()

        XCTAssertEqual(try env.localRecords().map(\.text), ["Remote text"])
        XCTAssertEqual(env.database.changeRequests.count, 2)
        XCTAssertEqual(env.sync.status, "Synced")
    }

    func testMalformedReceiveDoesNotAcknowledgeEarlierValidRecordInSamePage() async throws {
        let env = try environment()
        let valid = CKRecord(recordType: "HistoryItem", recordID: HistoryCloudSchema.historyID("a-valid"))
        let record = TranscriptionRecord(title: "Valid", text: "Body", sourceType: .file, duration: 10)
        valid["snapshot"] = CloudHistorySnapshot(record).json as CKRecordValue?
        let invalid = CKRecord(recordType: "HistoryItem", recordID: HistoryCloudSchema.historyID("z-invalid"))
        invalid["snapshot"] = "corrupted JSON" as CKRecordValue
        env.database.records = [valid.recordID: valid, invalid.recordID: invalid]

        await env.sync.syncOnce()

        XCTAssertTrue(try env.localRecords().isEmpty)
        XCTAssertTrue(env.database.saveBatches.isEmpty)
        XCTAssertTrue(env.database.deletedIDs.isEmpty)
        XCTAssertNotEqual(env.sync.status, "Synced")
    }

    func testCheckpointWriteFailureLeavesFetchedHistoryDurableAndReplayable() throws {
        let env = try environment()
        let remote = CKRecord(recordType: "HistoryItem", recordID: HistoryCloudSchema.historyID("remote"))
        let record = TranscriptionRecord(title: "Remote", text: "Body", sourceType: .file, duration: 12)
        remote["snapshot"] = CloudHistorySnapshot(record).json as CKRecordValue?
        // A directory at the checkpoint filename makes the atomic write fail deterministically.
        try FileManager.default.createDirectory(at: env.store.url, withIntermediateDirectories: false)
        let page = HistoryCloudPage(records: [remote], deletedRecords: [], token: nil, moreComing: false)

        XCTAssertThrowsError(try env.sync.applyPage(page))
        XCTAssertEqual(try env.localRecords().count, 1)
        try FileManager.default.removeItem(at: env.store.url)
        try env.sync.applyPage(page)
        XCTAssertEqual(try env.localRecords().count, 1)
    }

    func testDisableCancelsActualOperationsAndIgnoresReturningPage() async throws {
        let env = try environment()
        let remote = CKRecord(recordType: "HistoryItem", recordID: HistoryCloudSchema.historyID("remote"))
        remote["snapshot"] = CloudHistorySnapshot(TranscriptionRecord(title: "Remote", text: "Body", sourceType: .file, duration: 12)).json as CKRecordValue?
        env.database.records[remote.recordID] = remote
        env.database.onChanges = {
            env.preferences.iCloudSyncEnabled = false
            env.sync.settingChanged()
        }

        await env.sync.syncOnce()

        XCTAssertEqual(env.database.cancellationCount, 1)
        XCTAssertTrue(try env.localRecords().isEmpty)
        XCTAssertTrue(env.database.saveBatches.isEmpty)
        XCTAssertEqual(env.sync.status, "iCloud sync is off")
    }

    func testDeletedHistoryZoneStopsSyncAndKeepsOldLocalAudio() async throws {
        let env = try environment()
        let record = try env.record(audio: "audio")
        let file = try localAudio(record)
        try env.context.save()
        env.database.zones.remove(HistoryCloudSchema.historyZone)

        await env.sync.syncOnce()

        XCTAssertFalse(env.preferences.iCloudSyncEnabled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try env.localRecords().first?.cloudAudioID, "audio")
        XCTAssertNil(try env.localRecords().first?.lastSyncedSnapshotJSON)
        XCTAssertNil(try env.localRecords().first?.cloudRecordSystemFields)
        XCTAssertTrue(env.database.saveBatches.isEmpty)
        XCTAssertTrue(env.database.deletedIDs.isEmpty)
    }

    func testDeletedAudioZoneStopsSyncBeforeEvictingOnlyLocalCopy() async throws {
        let env = try environment()
        let record = try env.record(audio: "audio")
        let file = try localAudio(record)
        try env.context.save()
        env.database.zones.remove(HistoryCloudSchema.audioZone)

        await env.sync.syncOnce()

        XCTAssertFalse(env.preferences.iCloudSyncEnabled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(env.database.deletedIDs.isEmpty)
    }

    func testPurgeLosesChangeTagRaceToRemoteRestoreWithoutDeletingAudio() async throws {
        let env = try environment()
        let record = try env.record(deleted: true, audio: "audio")
        env.audio("audio", owners: [record.cloudID])
        var restored = CloudHistorySnapshot(record)
        restored.deletedAt = nil
        env.database.onSave = { cloud in
            guard cloud["purgedAt"] != nil else { return nil }
            let remote = CKRecord(recordType: "HistoryItem", recordID: cloud.recordID)
            remote["snapshot"] = restored.json as CKRecordValue?
            env.database.records[remote.recordID] = remote
            return CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: remote])
        }

        await env.sync.syncOnce()

        XCTAssertTrue(env.database.deletedIDs.isEmpty)
        XCTAssertNotNil(env.database.records[try HistoryCloudSchema.audioID("audio", zoneName: HistoryCloudSchema.audioZone.zoneName)])
        XCTAssertNotEqual(env.sync.status, "Synced")
        XCTAssertTrue(env.database.policies.allSatisfy { $0 == .ifServerRecordUnchanged })

        env.database.onSave = nil
        await env.sync.syncOnce()
        XCTAssertNil(try env.localRecords().first?.deletedAt)
        XCTAssertTrue(env.database.deletedIDs.isEmpty)
    }

    func testSyncedActiveRestoreSurvivesIncomingPermanentTombstone() async throws {
        let env = try environment()
        let record = try env.record(audio: "audio")
        let originalID = record.cloudID
        env.audio("audio", owners: [originalID])
        let cloud = CKRecord(recordType: "HistoryItem", recordID: HistoryCloudSchema.historyID(originalID))
        try HistoryCloudRecordCodec.markPurged(cloud, cleanup: HistoryCloudPurge(historyID: originalID,
            audio: [try HistoryAudioReference(audioID: "audio", zoneName: HistoryCloudSchema.audioZone.zoneName)]), at: Date())
        env.database.records[cloud.recordID] = cloud

        await env.sync.syncOnce()

        let preserved = try XCTUnwrap(env.localRecords().first)
        XCTAssertNotEqual(preserved.cloudID, originalID)
        XCTAssertNil(preserved.deletedAt)
        XCTAssertEqual(preserved.text, "Saved body")
        XCTAssertEqual(preserved.cloudAudioID, "audio")
        XCTAssertTrue(env.database.deletedIDs.isEmpty)
        let manifest = try XCTUnwrap(env.database.records[try HistoryCloudSchema.audioID("audio", zoneName: HistoryCloudSchema.audioZone.zoneName)])
        XCTAssertEqual(manifest["owners"] as? [String], [preserved.cloudID])
    }

    func testPurgePreservesAudioReferencedByAnotherHistory() async throws {
        let env = try environment()
        let expired = try env.record(deleted: true, audio: "shared")
        let active = try env.record(title: "Conflict copy", audio: "shared")
        env.audio("shared", owners: [expired.cloudID, active.cloudID])

        await env.sync.syncOnce()

        XCTAssertEqual(try env.localRecords().map(\.cloudID), [active.cloudID])
        XCTAssertTrue(env.database.deletedIDs.isEmpty)
        let manifest = try XCTUnwrap(env.database.records[try HistoryCloudSchema.audioID("shared", zoneName: HistoryCloudSchema.audioZone.zoneName)])
        XCTAssertEqual(manifest["owners"] as? [String], [active.cloudID])
    }

    func testPendingUploadIsDeletedOnlyAfterConditionalHistoryPurgeCommits() async throws {
        let env = try environment()
        let record = try env.record(deleted: true)
        let originalID = record.cloudID
        record.pendingAudioID = "pending"
        record.pendingAudioZoneName = HistoryCloudSchema.audioZone.zoneName
        try env.context.save()
        env.audio("pending", owners: [record.cloudID], count: 3, complete: false)
        // A reserved chunk might never have reached the server.
        env.database.records.removeValue(forKey: try HistoryCloudSchema.audioID("pending-2", zoneName: HistoryCloudSchema.audioZone.zoneName))

        await env.sync.syncOnce()

        XCTAssertTrue(try env.localRecords().isEmpty)
        XCTAssertNil(env.database.records[try HistoryCloudSchema.audioID("pending", zoneName: HistoryCloudSchema.audioZone.zoneName)])
        XCTAssertEqual(env.database.deletedIDs.count, 4)
        let commit = try XCTUnwrap(env.database.operations.firstIndex(of: "purge:\(originalID)"))
        let firstDelete = try XCTUnwrap(env.database.operations.firstIndex(where: { $0.hasPrefix("delete:") }))
        XCTAssertLessThan(commit, firstDelete)
    }

    func testLegacyInterruptedUploadWithoutManifestIsCleanedUsingMetadataOnly() async throws {
        let env = try environment()
        let record = try env.record(deleted: true)
        record.pendingAudioID = "legacy-pending"
        try env.context.save()
        for index in [0, 7] {
            let id = HistoryCloudSchema.historyID("legacy-pending-\(index)")
            let chunk = CKRecord(recordType: "AudioChunk", recordID: id)
            chunk["audioID"] = "legacy-pending" as CKRecordValue
            chunk["index"] = index as CKRecordValue
            env.database.records[id] = chunk
        }

        await env.sync.syncOnce()

        XCTAssertTrue(try env.localRecords().isEmpty)
        XCTAssertEqual(Set(env.database.deletedIDs.map(\.recordName)), ["legacy-pending-0", "legacy-pending-7"])
        XCTAssertTrue(env.database.changeRequests.allSatisfy { !$0.keys.contains("file") })
    }

    func testFiveHundredOneHistoriesAreSentInBoundedBatches() async throws {
        let env = try environment()
        for index in 0..<501 {
            env.context.insert(TranscriptionRecord(title: "History \(index)", text: "Body", sourceType: .file, duration: 1))
        }
        try env.context.save()

        await env.sync.syncOnce()

        XCTAssertEqual(env.database.saveBatches.count, 6)
        XCTAssertTrue(env.database.saveBatches.allSatisfy { $0.count <= HistoryCloudSchema.batchSize })
        XCTAssertEqual(env.database.records.values.filter { $0.recordType == "HistoryItem" }.count, 501)
        XCTAssertEqual(env.sync.status, "Synced")
    }

    func testSnapshotLargerThanOneMegabyteRoundTripsAsVerifiedAsset() async throws {
        let env = try environment()
        let text = String(repeating: "長文文字起こしのテストです。", count: 26000)
        let record = TranscriptionRecord(title: "Long", text: text, sourceType: .file, duration: 3600)
        env.context.insert(record)
        try env.context.save()
        XCTAssertGreaterThan(try XCTUnwrap(CloudHistorySnapshot(record).json).utf8.count, 1_048_576)

        await env.sync.syncOnce()

        let cloud = try XCTUnwrap(env.database.records[HistoryCloudSchema.historyID(record.cloudID)])
        XCTAssertNil(cloud["snapshot"])
        XCTAssertNotNil(cloud["snapshotAsset"] as? CKAsset)
        XCTAssertEqual(try HistoryCloudRecordCodec.snapshot(cloud).text, text)
        XCTAssertEqual(env.sync.status, "Synced")
    }

    func testCorruptedSnapshotAssetStopsReceiveWithoutSending() async throws {
        let env = try environment()
        let snapshot = CloudHistorySnapshot(TranscriptionRecord(title: "Cloud", text: "Body", sourceType: .file, duration: 1))
        let record = CKRecord(recordType: "HistoryItem", recordID: HistoryCloudSchema.historyID("corrupt"))
        let url = try HistoryCloudRecordCodec.write(snapshot, to: record, modifiedAt: Date(), directory: env.directory)
        try Data("damaged".utf8).write(to: url)
        env.database.records[record.recordID] = record

        await env.sync.syncOnce()

        XCTAssertTrue(try env.localRecords().isEmpty)
        XCTAssertTrue(env.database.saveBatches.isEmpty)
        XCTAssertTrue(env.database.deletedIDs.isEmpty)
    }

    func testOrdinaryHistorySyncNeverFetchesAudioAssetField() async throws {
        let env = try environment()
        let record = try env.record(audio: "audio")
        env.audio("audio", owners: [record.cloudID])
        // Legacy chunks live in the history zone but their file field must be excluded.
        let legacy = CKRecord(recordType: "AudioChunk", recordID: HistoryCloudSchema.historyID("legacy-0"))
        legacy["audioID"] = "legacy" as CKRecordValue
        let url = env.directory.appendingPathComponent("legacy-audio")
        try Data("audio".utf8).write(to: url)
        legacy["file"] = CKAsset(fileURL: url)
        env.database.records[legacy.recordID] = legacy

        await env.sync.syncOnce()

        XCTAssertEqual(env.sync.status, "Synced")
        XCTAssertTrue(env.database.changeRequests.allSatisfy { $0.zone == HistoryCloudSchema.historyZone && !$0.keys.contains("file") })
    }

    func testMissingManifestPreventsEvictionOfOnlyLocalRecording() async throws {
        let env = try environment()
        let record = try env.record(audio: "missing")
        let url = try localAudio(record)
        try env.context.save()

        await env.sync.syncOnce()

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNotNil(try env.localRecords().first?.audioFilePath)
        XCTAssertNotEqual(env.sync.status, "Synced")
    }


    func testUploadInterruptionKeepsFileAndReservesChunksForLaterPurge() async throws {
        let env = try environment()
        let record = try env.record()
        let file = try localAudio(record)
        let historyID = record.cloudID
        try env.context.save()
        env.database.onSave = { cloud in
            if cloud.recordType == "AudioManifest", cloud["uploadComplete"] as? Int == 1 {
                return Fault.disconnected
            }
            return nil
        }

        await env.sync.syncOnce()

        let interrupted = try XCTUnwrap(env.localRecords().first)
        let pending = try XCTUnwrap(interrupted.pendingAudioID)
        XCTAssertNil(interrupted.cloudAudioID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let manifestID = try HistoryCloudSchema.audioID(pending, zoneName: HistoryCloudSchema.audioZone.zoneName)
        let manifest = try XCTUnwrap(env.database.records[manifestID])
        XCTAssertEqual(manifest["allocatedChunks"] as? Int, 1)
        XCTAssertEqual(manifest["uploadComplete"] as? Int, 0)
        XCTAssertNotNil(env.database.records[try HistoryCloudSchema.audioID("\(pending)-0", zoneName: HistoryCloudSchema.audioZone.zoneName)])

        env.database.onSave = nil
        let editContext = ModelContext(env.container)
        let deleted = try XCTUnwrap(editContext.fetch(FetchDescriptor<TranscriptionRecord>()).first)
        deleted.deletedAt = Date().addingTimeInterval(-31 * 86400)
        try editContext.save()
        await env.sync.syncOnce()

        XCTAssertTrue(try env.localRecords().isEmpty)
        XCTAssertNil(env.database.records[manifestID])
        XCTAssertNil(env.database.records[try HistoryCloudSchema.audioID("\(pending)-0", zoneName: HistoryCloudSchema.audioZone.zoneName)])
        XCTAssertNotNil(env.database.records[HistoryCloudSchema.historyID(historyID)]?["purgedAt"])
    }

    func testIncomingPurgeAlsoCleansThisDevicesUnpublishedUpload() async throws {
        let env = try environment()
        let record = try env.record(deleted: true)
        let historyID = record.cloudID
        record.pendingAudioID = "device-upload"
        record.pendingAudioZoneName = HistoryCloudSchema.audioZone.zoneName
        try env.context.save()
        env.audio("device-upload", owners: [historyID], complete: false)
        let remote = CKRecord(recordType: "HistoryItem", recordID: HistoryCloudSchema.historyID(historyID))
        // The other device knows no audio reference for this interrupted upload.
        try HistoryCloudRecordCodec.markPurged(remote, cleanup: HistoryCloudPurge(historyID: historyID, audio: []), at: Date())
        env.database.records[remote.recordID] = remote

        await env.sync.syncOnce()

        XCTAssertTrue(try env.localRecords().isEmpty)
        XCTAssertNil(env.database.records[try HistoryCloudSchema.audioID("device-upload", zoneName: HistoryCloudSchema.audioZone.zoneName)])
        XCTAssertTrue(try env.store.load().pendingPurges.isEmpty)
    }

    func testInterruptedGarbageCollectionResumesFromDurableTombstone() async throws {
        let env = try environment()
        let record = try env.record(deleted: true, audio: "audio")
        let historyID = record.cloudID
        env.audio("audio", owners: [historyID])
        var fail = true
        env.database.onSave = { cloud in
            if cloud.recordType == "AudioManifest", cloud["deleting"] as? Int == 1, fail {
                fail = false
                return Fault.disconnected
            }
            return nil
        }

        await env.sync.syncOnce()

        XCTAssertNotNil(env.database.records[HistoryCloudSchema.historyID(historyID)]?["purgedAt"])
        XCTAssertTrue(env.database.deletedIDs.isEmpty)
        XCTAssertEqual(try env.store.load().pendingPurges.count, 1)
        XCTAssertEqual(try env.localRecords().count, 1)

        await env.sync.syncOnce()

        XCTAssertTrue(try env.localRecords().isEmpty)
        XCTAssertTrue(try env.store.load().pendingPurges.isEmpty)
        XCTAssertNil(env.database.records[try HistoryCloudSchema.audioID("audio", zoneName: HistoryCloudSchema.audioZone.zoneName)])
    }

    func testDifferentAccountStopsBeforeReadingOrWritingCloudHistory() async throws {
        let env = try environment()
        env.defaults.set("previous-account", forKey: "historyCloudAccountRecordName")
        env.database.account = "new-account"

        await env.sync.syncOnce()

        XCTAssertFalse(env.preferences.iCloudSyncEnabled)
        XCTAssertEqual(env.database.cancellationCount, 1)
        XCTAssertTrue(env.database.changeRequests.isEmpty)
        XCTAssertTrue(env.database.saveBatches.isEmpty)
    }

    func testLegacyManifestOwnershipMigrationKeepsCompletedAudioReadable() async throws {
        let env = try environment()
        let record = try env.record(audio: "audio")
        env.audio("audio", owners: [record.cloudID])
        let manifestID = try HistoryCloudSchema.audioID("audio", zoneName: HistoryCloudSchema.audioZone.zoneName)
        let manifest = try XCTUnwrap(env.database.records[manifestID])
        manifest["owners"] = nil
        manifest["ownerFormatVersion"] = nil
        manifest["uploadComplete"] = nil
        manifest["allocatedChunks"] = nil

        await env.sync.syncOnce()

        let migrated = try XCTUnwrap(env.database.records[manifestID])
        XCTAssertEqual(migrated["owners"] as? [String], [record.cloudID])
        XCTAssertEqual(migrated["uploadComplete"] as? Int, 1)
        XCTAssertEqual(env.sync.status, "Synced")
    }

    func testReplayedPurgeKeepsUnpublishedCleanupReferences() throws {
        let reference = try HistoryAudioReference(audioID: "unpublished", zoneName: HistoryCloudSchema.audioZone.zoneName)
        var checkpoint = HistoryCloudCheckpoint()
        checkpoint.enqueue(HistoryCloudPurge(historyID: "history", audio: [reference]))
        checkpoint.enqueue(HistoryCloudPurge(historyID: "history", audio: []))

        XCTAssertEqual(checkpoint.pendingPurges, [HistoryCloudPurge(historyID: "history", audio: [reference])])
    }

    func testPurgeCleanupIsDurableBeforePreservedRecordChangesID() throws {
        let env = try environment()
        let local = try env.record()
        let oldID = local.cloudID
        local.pendingAudioID = "unpublished"
        local.pendingAudioZoneName = HistoryCloudSchema.audioZone.zoneName
        try env.context.save()
        let remote = CKRecord(recordType: "HistoryItem", recordID: HistoryCloudSchema.historyID(oldID))
        try HistoryCloudRecordCodec.markPurged(remote, cleanup: HistoryCloudPurge(historyID: oldID, audio: []), at: Date())
        let page = HistoryCloudPage(records: [remote], deletedRecords: [], token: nil, moreComing: false)
        env.fault.failNextSave = true

        XCTAssertThrowsError(try env.sync.applyPage(page))

        XCTAssertEqual(try env.localRecords().first?.cloudID, oldID)
        let reference = try HistoryAudioReference(audioID: "unpublished", zoneName: HistoryCloudSchema.audioZone.zoneName)
        XCTAssertEqual(try env.store.load().pendingPurges.first?.audio, [reference])
        try env.sync.applyPage(page)
        XCTAssertNotEqual(try env.localRecords().first?.cloudID, oldID)
        // A full feed replay must not replace the job with the other device's empty cleanup list.
        try env.sync.applyPage(page)
        XCTAssertEqual(try env.store.load().pendingPurges.first?.audio, [reference])
    }

    func testLastOwnerDeletionLosesRaceToNewAudioOwnerWithoutDeletingChunks() async throws {
        let env = try environment()
        let expired = try env.record(deleted: true, audio: "shared")
        env.audio("shared", owners: [expired.cloudID])
        let manifestID = try HistoryCloudSchema.audioID("shared", zoneName: HistoryCloudSchema.audioZone.zoneName)
        var raced = false
        env.database.onSave = { cloud in
            guard cloud.recordID == manifestID, cloud["deleting"] as? Int == 1, !raced else { return nil }
            raced = true
            let manifest = try env.database.copy(try XCTUnwrap(env.database.records[manifestID]))
            manifest["owners"] = [expired.cloudID, "new-owner"] as CKRecordValue
            env.database.records[manifestID] = manifest
            var snapshot = CloudHistorySnapshot(expired)
            snapshot.deletedAt = nil
            let active = CKRecord(recordType: "HistoryItem", recordID: HistoryCloudSchema.historyID("new-owner"))
            active["snapshot"] = snapshot.json as CKRecordValue?
            env.database.records[active.recordID] = active
            return CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: manifest])
        }

        await env.sync.syncOnce()

        XCTAssertTrue(raced)
        XCTAssertTrue(env.database.deletedIDs.isEmpty)
        XCTAssertEqual(try env.store.load().pendingPurges.count, 1)
        await env.sync.syncOnce()
        XCTAssertEqual(try env.localRecords().map(\.cloudID), ["new-owner"])
        XCTAssertEqual(env.database.records[manifestID]?["owners"] as? [String], ["new-owner"])
        XCTAssertTrue(env.database.deletedIDs.isEmpty)
    }

    func testLocalRestoreDuringCleanupKeepsHistoryAndAcquiresNewAudioOwner() async throws {
        let env = try environment()
        let expired = try env.record(deleted: true, audio: "audio")
        let oldID = expired.cloudID
        env.audio("audio", owners: [oldID])
        let manifestID = try HistoryCloudSchema.audioID("audio", zoneName: HistoryCloudSchema.audioZone.zoneName)
        var restored = false
        env.database.onFetch = { id in
            guard id == manifestID, !restored,
                  env.database.records[HistoryCloudSchema.historyID(oldID)]?["purgedAt"] != nil else { return }
            restored = true
            let context = ModelContext(env.container)
            let local = try XCTUnwrap(context.fetch(FetchDescriptor<TranscriptionRecord>()).first)
            local.deletedAt = nil
            try context.save()
        }

        await env.sync.syncOnce()

        XCTAssertTrue(restored)
        let preserved = try XCTUnwrap(env.localRecords().first)
        XCTAssertNotEqual(preserved.cloudID, oldID)
        XCTAssertNil(preserved.deletedAt)
        XCTAssertEqual(preserved.text, "Saved body")
        XCTAssertTrue((env.database.records[manifestID]?["owners"] as? [String] ?? []).contains(preserved.cloudID))
        XCTAssertTrue(env.database.deletedIDs.isEmpty)
    }

    func testDeletedLegacyZoneInvalidatesAudioReferenceButRetainsLocalFile() async throws {
        let env = try environment()
        let record = try env.record(audio: "legacy")
        record.cloudAudioZoneName = nil
        let file = try localAudio(record)
        try env.context.save()
        env.database.zones.remove(HistoryCloudSchema.historyZone)

        await env.sync.syncOnce()

        XCTAssertFalse(env.preferences.iCloudSyncEnabled)
        XCTAssertNil(try env.localRecords().first?.cloudAudioID)
        XCTAssertEqual(try env.localRecords().first?.audioFilePath, record.audioFilePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testExplicitDownloadVerifiesLegacyAudioAndRequestsOnlyChunkAssets() async throws {
        let env = try environment()
        let record = try env.record(audio: "legacy")
        record.cloudAudioZoneName = nil
        let data = Data("verified legacy audio".utf8)
        record.cloudAudioByteCount = Int64(data.count)
        record.cloudAudioSHA256 = HistoryCloudRecordCodec.sha256(data)
        try env.context.save()
        let manifest = CKRecord(recordType: "AudioManifest", recordID: HistoryCloudSchema.historyID("legacy"))
        manifest["chunks"] = 1 as CKRecordValue
        manifest["bytes"] = record.cloudAudioByteCount as CKRecordValue
        manifest["sha256"] = record.cloudAudioSHA256 as CKRecordValue?
        manifest["extension"] = "m4a" as CKRecordValue
        env.database.records[manifest.recordID] = manifest
        let chunk = CKRecord(recordType: "AudioChunk", recordID: HistoryCloudSchema.historyID("legacy-0"))
        let assetURL = env.directory.appendingPathComponent("download-asset")
        try data.write(to: assetURL)
        chunk["file"] = CKAsset(fileURL: assetURL)
        env.database.records[chunk.recordID] = chunk

        try await env.sync.downloadAudio(for: record)

        let path = try XCTUnwrap(record.audioFilePath)
        let file = try RecordingFileReference.fileURL(for: path)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try Data(contentsOf: file), data)
        XCTAssertEqual(try env.localRecords().first?.audioFilePath, path)
        let assetRequests = env.database.fetchRequests.filter { $0.keys?.contains("file") == true }
        XCTAssertEqual(assetRequests.map(\.id), [chunk.recordID])
    }

    func testCorruptedAudioDownloadDoesNotPublishLocalFile() async throws {
        let env = try environment()
        let record = try env.record(audio: "audio")
        env.audio("audio", owners: [record.cloudID])
        let chunkID = try HistoryCloudSchema.audioID("audio-0", zoneName: HistoryCloudSchema.audioZone.zoneName)
        let assetURL = env.directory.appendingPathComponent("corrupt-audio")
        try Data("wrong bytes".utf8).write(to: assetURL)
        env.database.records[chunkID]?["file"] = CKAsset(fileURL: assetURL)

        do {
            try await env.sync.downloadAudio(for: record)
            XCTFail("Corrupted audio must not be published")
        } catch HistorySyncError.audioVerificationFailed { }

        XCTAssertNil(record.audioFilePath)
        XCTAssertNil(try env.localRecords().first?.audioFilePath)
    }

    private func localAudio(_ record: TranscriptionRecord) throws -> URL {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(RecordingFileReference.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("icloud-test-\(UUID().uuidString).m4a")
        try Data("local audio".utf8).write(to: url)
        record.audioFilePath = try RecordingFileReference.storedPath(for: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
