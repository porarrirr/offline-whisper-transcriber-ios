import CloudKit
import CryptoKit
import Foundation

/// The original zone remains the source of history, so existing record IDs and change tags stay valid.
enum HistoryCloudSchema {
    static let historyZone = CKRecordZone.ID(zoneName: "History")
    static let audioZone = CKRecordZone.ID(zoneName: "HistoryAudio")
    static let chunkSize = 8 * 1024 * 1024
    // Keep a conservative request bound below CloudKit's per-operation limit.
    static let batchSize = 100
    static let restoreInterval: TimeInterval = 30 * 24 * 60 * 60
    static let historyKeys = ["snapshot", "snapshotAsset", "snapshotBytes", "snapshotSHA256",
                              "formatVersion", "modifiedAt", "purgedAt", "cleanup",
                              "audioID", "index", "chunks"]
    static let manifestKeys = ["chunks", "allocatedChunks", "bytes", "sha256", "extension",
                               "owners", "ownerFormatVersion", "uploadComplete", "deleting"]

    static func historyID(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: historyZone)
    }

    static func audioID(_ name: String, zoneName: String?) throws -> CKRecord.ID {
        let zone = zoneName ?? historyZone.zoneName // Schema v1 stored audio in History.
        guard zone == historyZone.zoneName || zone == audioZone.zoneName else {
            throw HistorySyncError.invalidCloudRecord
        }
        return CKRecord.ID(recordName: name, zoneID: CKRecordZone.ID(zoneName: zone))
    }
}

struct HistoryAudioReference: Codable, Equatable, Hashable {
    var audioID: String
    var zoneName: String

    init(audioID: String, zoneName: String?) throws {
        let id = try HistoryCloudSchema.audioID(audioID, zoneName: zoneName)
        self.audioID = id.recordName
        self.zoneName = id.zoneID.zoneName
    }

    var recordID: CKRecord.ID {
        CKRecord.ID(recordName: audioID, zoneID: CKRecordZone.ID(zoneName: zoneName))
    }
}

struct HistoryCloudPurge: Codable, Equatable {
    var historyID: String
    var audio: [HistoryAudioReference]
}

enum HistoryCloudRecordCodec {
    static func snapshot(_ record: CKRecord) throws -> CloudHistorySnapshot {
        guard record["purgedAt"] == nil else { throw HistorySyncError.permanentlyDeleted }
        let version = record["formatVersion"] as? Int ?? 1
        let json: String
        switch version {
        case 1:
            guard let value = record["snapshot"] as? String else { throw HistorySyncError.invalidCloudRecord }
            json = value
        case 2:
            guard let asset = record["snapshotAsset"] as? CKAsset, let url = asset.fileURL,
                  let size = record["snapshotBytes"] as? Int64,
                  let digest = record["snapshotSHA256"] as? String else {
                throw HistorySyncError.invalidCloudRecord
            }
            let data = try Data(contentsOf: url)
            guard Int64(data.count) == size, sha256(data) == digest,
                  let value = String(data: data, encoding: .utf8) else {
                throw HistorySyncError.invalidCloudRecord
            }
            json = value
        default: throw HistorySyncError.invalidCloudRecord
        }
        guard let snapshot = CloudHistorySnapshot.decode(json),
              TranscriptionRecord.SourceType(rawValue: snapshot.sourceType) != nil,
              snapshot.duration.isFinite, snapshot.duration >= 0,
              snapshot.cloudAudioChunkCount >= 0, snapshot.cloudAudioByteCount >= 0 else {
            throw HistorySyncError.invalidCloudRecord
        }
        if let audioID = snapshot.cloudAudioID {
            _ = try HistoryCloudSchema.audioID(audioID, zoneName: snapshot.cloudAudioZoneName)
            guard snapshot.cloudAudioChunkCount > 0, snapshot.cloudAudioByteCount > 0,
                  snapshot.cloudAudioSHA256 != nil else { throw HistorySyncError.invalidCloudRecord }
        }
        return snapshot
    }

    /// Always use an asset for v2 snapshots; a large transcript never goes into a 1 MB string field.
    static func write(_ snapshot: CloudHistorySnapshot, to record: CKRecord,
                      modifiedAt: Date, directory: URL) throws -> URL {
        guard let json = snapshot.json else { throw HistorySyncError.invalidCloudRecord }
        let data = Data(json.utf8)
        guard data.count < 49 * 1024 * 1024 else { throw HistorySyncError.snapshotTooLarge }
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        try data.write(to: url, options: .atomic)
        record["formatVersion"] = 2 as CKRecordValue
        record["snapshot"] = nil
        record["snapshotAsset"] = CKAsset(fileURL: url)
        record["snapshotBytes"] = Int64(data.count) as CKRecordValue
        record["snapshotSHA256"] = sha256(data) as CKRecordValue
        record["modifiedAt"] = modifiedAt as CKRecordValue
        return url
    }

    static func purge(_ record: CKRecord) throws -> HistoryCloudPurge {
        guard record["purgedAt"] is Date, let json = record["cleanup"] as? String,
              let data = json.data(using: .utf8) else { throw HistorySyncError.invalidCloudRecord }
        let purge = try JSONDecoder().decode(HistoryCloudPurge.self, from: data)
        guard purge.historyID == record.recordID.recordName else { throw HistorySyncError.invalidCloudRecord }
        for reference in purge.audio {
            _ = try HistoryCloudSchema.audioID(reference.audioID, zoneName: reference.zoneName)
        }
        return purge
    }

    static func markPurged(_ record: CKRecord, cleanup: HistoryCloudPurge, at date: Date) throws {
        let data = try JSONEncoder().encode(cleanup)
        guard let json = String(data: data, encoding: .utf8) else { throw HistorySyncError.invalidCloudRecord }
        record["purgedAt"] = date as CKRecordValue
        record["cleanup"] = json as CKRecordValue
        record["snapshot"] = nil
        record["snapshotAsset"] = nil
        record["snapshotBytes"] = nil
        record["snapshotSHA256"] = nil
        record["modifiedAt"] = date as CKRecordValue
        record["formatVersion"] = 2 as CKRecordValue
    }

    static func systemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    static func restoreRecord(from data: Data) throws -> CKRecord {
        let coder = try NSKeyedUnarchiver(forReadingFrom: data)
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        guard let record = CKRecord(coder: coder) else { throw HistorySyncError.invalidCloudRecord }
        return record
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct HistoryCloudCheckpoint: Codable {
    var token: Data?
    var knownZones: Set<String> = []
    var pendingPurges: [HistoryCloudPurge] = []

    mutating func enqueue(_ purge: HistoryCloudPurge) {
        var merged = purge
        if let existing = pendingPurges.first(where: { $0.historyID == purge.historyID }) {
            merged.audio = Array(Set(existing.audio + purge.audio))
        }
        merged.audio.sort { ($0.zoneName, $0.audioID) < ($1.zoneName, $1.audioID) }
        pendingPurges.removeAll { $0.historyID == purge.historyID }
        pendingPurges.append(merged)
    }

    func changeToken() throws -> CKServerChangeToken? {
        guard let token else { return nil }
        guard let value = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: token) else {
            throw HistorySyncError.invalidCloudRecord
        }
        return value
    }

    mutating func setToken(_ value: CKServerChangeToken?) throws {
        token = try value.map { try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
    }
}

/// Data is saved first, then this atomic checkpoint. A crash between them replays the page safely.
@MainActor
final class HistoryCloudCheckpointStore {
    let url: URL

    init(url: URL) { self.url = url }

    func load() throws -> HistoryCloudCheckpoint {
        guard FileManager.default.fileExists(atPath: url.path) else { return HistoryCloudCheckpoint() }
        return try JSONDecoder().decode(HistoryCloudCheckpoint.self, from: Data(contentsOf: url))
    }

    func save(_ checkpoint: HistoryCloudCheckpoint) throws {
        let data = try JSONEncoder().encode(checkpoint)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
