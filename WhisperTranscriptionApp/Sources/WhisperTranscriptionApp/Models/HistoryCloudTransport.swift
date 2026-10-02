import CloudKit
import Foundation

struct HistoryCloudPage {
    var records: [CKRecord]
    var deletedRecords: [(id: CKRecord.ID, type: String)]
    var token: CKServerChangeToken?
    var moreComing: Bool
}

struct HistoryCloudModifyResult {
    var savedRecords: [CKRecord] = []
    var deletedRecordIDs: [CKRecord.ID] = []
    var errors: [CKRecord.ID: Error] = [:]
}

/// One CloudKit route for all synchronization. Field selection prevents fetching audio assets.
@MainActor
protocol HistoryCloudDatabase: AnyObject {
    func accountRecordName() async throws -> String
    func zoneIDs() async throws -> Set<CKRecordZone.ID>
    func createZones(_ ids: Set<CKRecordZone.ID>) async throws
    func changes(in zone: CKRecordZone.ID, since token: CKServerChangeToken?,
                 desiredKeys: [String]) async throws -> HistoryCloudPage
    func fetch(_ id: CKRecord.ID, desiredKeys: [String]?, allowCellular: Bool) async throws -> CKRecord
    func modify(saving records: [CKRecord], deleting ids: [CKRecord.ID],
                savePolicy: CKModifyRecordsOperation.RecordSavePolicy,
                allowCellular: Bool) async throws -> HistoryCloudModifyResult
    func cancelOperations()
    var allowCellular: Bool { get set }
}

private final class HistoryCloudBuffer<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }
    func update(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&value)
    }
    func read() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@MainActor
final class CloudKitHistoryDatabase: HistoryCloudDatabase {
    private let containerIdentifier: String
    private lazy var container = CKContainer(identifier: containerIdentifier)
    var allowCellular = false
    private var operations: [UUID: CKDatabaseOperation] = [:]

    init(containerIdentifier: String) { self.containerIdentifier = containerIdentifier }

    func accountRecordName() async throws -> String {
        guard try await container.accountStatus() == .available else { throw HistorySyncError.noAccount }
        return try await container.userRecordID().recordName
    }

    func cancelOperations() {
        // Capture and cancel the actual operations synchronously, before a new session starts.
        for operation in operations.values { operation.cancel() }
    }

    private func run<Value>(_ operation: CKDatabaseOperation,
                            configure: (CheckedContinuation<Value, Error>) -> Void) async throws -> Value {
        try Task.checkCancellation()
        let operationID = UUID()
        operations[operationID] = operation
        defer { operations.removeValue(forKey: operationID) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                configure(continuation)
                container.privateCloudDatabase.add(operation)
            }
        } onCancel: {
            operation.cancel()
        }
    }

    func zoneIDs() async throws -> Set<CKRecordZone.ID> {
        let operation = CKFetchRecordZonesOperation.fetchAllRecordZonesOperation()
        operation.configuration.allowsCellularAccess = allowCellular
        let zones = HistoryCloudBuffer<Set<CKRecordZone.ID>>([])
        let failure = HistoryCloudBuffer<Error?>(nil)
        return try await run(operation) { continuation in
            operation.perRecordZoneResultBlock = { id, result in
                switch result {
                case .success: zones.update { $0.insert(id) }
                case .failure(let error): failure.update { $0 = error }
                }
            }
            operation.fetchRecordZonesResultBlock = { result in
                if let error = failure.read() { continuation.resume(throwing: error) }
                else {
                    switch result {
                    case .success: continuation.resume(returning: zones.read())
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    func createZones(_ ids: Set<CKRecordZone.ID>) async throws {
        guard !ids.isEmpty else { return }
        let operation = CKModifyRecordZonesOperation(recordZonesToSave: ids.map { CKRecordZone(zoneID: $0) })
        operation.configuration.allowsCellularAccess = allowCellular
        try await run(operation) { (continuation: CheckedContinuation<Void, Error>) in
            operation.modifyRecordZonesResultBlock = { result in continuation.resume(with: result) }
        }
    }

    func changes(in zone: CKRecordZone.ID, since token: CKServerChangeToken?,
                 desiredKeys: [String]) async throws -> HistoryCloudPage {
        let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        configuration.previousServerChangeToken = token
        configuration.desiredKeys = desiredKeys
        configuration.resultsLimit = 100
        let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zone],
            configurationsByRecordZoneID: [zone: configuration])
        operation.fetchAllChanges = false
        operation.configuration.allowsCellularAccess = allowCellular
        let page = HistoryCloudBuffer(HistoryCloudPage(records: [], deletedRecords: [],
                                                       token: nil, moreComing: false))
        let failure = HistoryCloudBuffer<Error?>(nil)
        return try await run(operation) { continuation in
            operation.recordWasChangedBlock = { _, result in
                switch result {
                case .success(let record): page.update { $0.records.append(record) }
                case .failure(let error): failure.update { $0 = error }
                }
            }
            operation.recordWithIDWasDeletedBlock = { id, type in
                page.update { $0.deletedRecords.append((id, type)) }
            }
            operation.recordZoneFetchResultBlock = { _, result in
                switch result {
                case .success(let result):
                    page.update { $0.token = result.serverChangeToken; $0.moreComing = result.moreComing }
                case .failure(let error): failure.update { $0 = error }
                }
            }
            // Wait for the operation to finish; per-record callbacks alone do not acknowledge a page.
            operation.fetchRecordZoneChangesResultBlock = { result in
                if let error = failure.read() { continuation.resume(throwing: error) }
                else {
                    switch result {
                    case .success: continuation.resume(returning: page.read())
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    func fetch(_ id: CKRecord.ID, desiredKeys: [String]?, allowCellular: Bool) async throws -> CKRecord {
        let operation = CKFetchRecordsOperation(recordIDs: [id])
        operation.desiredKeys = desiredKeys
        operation.configuration.allowsCellularAccess = allowCellular
        let item = HistoryCloudBuffer<Result<CKRecord, Error>?>(nil)
        return try await run(operation) { continuation in
            operation.perRecordResultBlock = { _, result in item.update { $0 = result } }
            operation.fetchRecordsResultBlock = { result in
                if let recordResult = item.read() { continuation.resume(with: recordResult) }
                else {
                    switch result {
                    case .failure(let error): continuation.resume(throwing: error)
                    case .success: continuation.resume(throwing: HistorySyncError.invalidCloudRecord)
                    }
                }
            }
        }
    }

    func modify(saving records: [CKRecord], deleting ids: [CKRecord.ID],
                savePolicy: CKModifyRecordsOperation.RecordSavePolicy,
                allowCellular: Bool) async throws -> HistoryCloudModifyResult {
        let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: ids)
        operation.savePolicy = savePolicy
        operation.isAtomic = false
        operation.configuration.allowsCellularAccess = allowCellular
        let items = HistoryCloudBuffer(HistoryCloudModifyResult())
        return try await run(operation) { continuation in
            operation.perRecordSaveBlock = { id, result in
                items.update {
                    switch result {
                    case .success(let record): $0.savedRecords.append(record)
                    case .failure(let error): $0.errors[id] = error
                    }
                }
            }
            operation.perRecordDeleteBlock = { id, result in
                items.update {
                    switch result {
                    case .success: $0.deletedRecordIDs.append(id)
                    case .failure(let error): $0.errors[id] = error
                    }
                }
            }
            operation.modifyRecordsResultBlock = { result in
                let response = items.read()
                switch result {
                case .failure(let error) where response.errors.isEmpty:
                    continuation.resume(throwing: error)
                default:
                    guard response.savedRecords.count + response.deletedRecordIDs.count + response.errors.count
                            == records.count + ids.count else {
                        continuation.resume(throwing: HistorySyncError.invalidCloudRecord)
                        return
                    }
                    continuation.resume(returning: response)
                }
            }
        }
    }
}
