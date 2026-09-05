import XCTest
@testable import WhisperTranscriptionApp

@MainActor
final class WhisperAppIntentsTests: XCTestCase {
    private var userDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        userDefaults = UserDefaults(suiteName: #fileID)
        userDefaults.removePersistentDomain(forName: #fileID)
    }

    override func tearDown() {
        userDefaults.removePersistentDomain(forName: #fileID)
        userDefaults = nil
        super.tearDown()
    }

    func testStartRecordingRequestUsesSinglePendingAction() {
        WhisperAppDestination.transcribe.requestOpen(
            recordingAction: .start,
            userDefaults: userDefaults
        )

        XCTAssertEqual(
            userDefaults.string(forKey: WhisperAppDestination.pendingDestinationKey),
            WhisperAppDestination.transcribe.rawValue
        )
        XCTAssertEqual(
            userDefaults.string(forKey: WhisperAppDestination.pendingRecordingActionKey),
            WhisperRecordingIntentAction.start.rawValue
        )
    }

    func testLiveRecordingRequestCannotLeaveContradictoryStartFlags() {
        WhisperAppDestination.transcribe.requestOpen(
            recordingAction: .start,
            userDefaults: userDefaults
        )
        WhisperAppDestination.transcribe.requestOpen(
            recordingAction: .startLiveTranscription,
            userDefaults: userDefaults
        )

        XCTAssertEqual(
            userDefaults.string(forKey: WhisperAppDestination.pendingRecordingActionKey),
            WhisperRecordingIntentAction.startLiveTranscription.rawValue
        )
    }

    func testStopRequestRoutesToTranscribeWithStopAndTranscribeAction() {
        WhisperAppDestination.transcribe.requestOpen(
            recordingAction: .stopAndTranscribe,
            userDefaults: userDefaults
        )

        XCTAssertEqual(
            userDefaults.string(forKey: WhisperAppDestination.pendingDestinationKey),
            WhisperAppDestination.transcribe.rawValue
        )
        XCTAssertEqual(
            userDefaults.string(forKey: WhisperAppDestination.pendingRecordingActionKey),
            WhisperRecordingIntentAction.stopAndTranscribe.rawValue
        )
    }

    func testOpenTranscriptionRequestStoresIdentifierBeforeRoutingToHistory() {
        let id = UUID()

        WhisperAppDestination.history.requestOpen(
            transcriptionID: id,
            userDefaults: userDefaults
        )

        XCTAssertEqual(
            userDefaults.string(forKey: WhisperAppDestination.pendingTranscriptionIDKey),
            id.uuidString
        )
        XCTAssertEqual(
            userDefaults.string(forKey: WhisperAppDestination.pendingDestinationKey),
            WhisperAppDestination.history.rawValue
        )
    }

    func testOpeningRootDestinationClearsStalePendingAction() {
        userDefaults.set(
            WhisperRecordingIntentAction.stopAndTranscribe.rawValue,
            forKey: WhisperAppDestination.pendingRecordingActionKey
        )

        WhisperAppDestination.transcribe.requestOpen(userDefaults: userDefaults)

        XCTAssertNil(
            userDefaults.string(forKey: WhisperAppDestination.pendingRecordingActionKey)
        )
    }

    func testOpeningHistoryRootClearsStaleTranscriptionIdentifier() {
        userDefaults.set(
            UUID().uuidString,
            forKey: WhisperAppDestination.pendingTranscriptionIDKey
        )

        WhisperAppDestination.history.requestOpen(userDefaults: userDefaults)

        XCTAssertNil(
            userDefaults.string(forKey: WhisperAppDestination.pendingTranscriptionIDKey)
        )
    }

    @available(iOS 18.0, *)
    func testTranscriptionEntityMapsSearchableRecordContent() {
        let id = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_000)
        let record = TranscriptionRecord(
            id: id,
            title: "Planning meeting",
            text: "Discuss the launch budget and schedule.",
            sourceType: .recording,
            duration: 125,
            createdAt: createdAt,
            isFavorite: true,
            language: "en",
            tags: ["Work", "Launch"]
        )

        let entity = TranscriptionEntity(record: record)

        XCTAssertEqual(entity.id, id)
        XCTAssertEqual(entity.title, "Planning meeting")
        XCTAssertEqual(entity.text, "Discuss the launch budget and schedule.")
        XCTAssertEqual(entity.createdAt, createdAt)
        XCTAssertEqual(entity.tags, ["Work", "Launch"])
        XCTAssertEqual(entity.duration, 125)
        XCTAssertEqual(entity.language, "en")
        XCTAssertTrue(entity.isFavorite)
        XCTAssertEqual(entity.attributeSet.title, "Planning meeting")
        XCTAssertEqual(entity.attributeSet.textContent, "Discuss the launch budget and schedule.")
        XCTAssertEqual(entity.attributeSet.keywords, ["Work", "Launch"])
        XCTAssertEqual(entity.attributeSet.userCurated, NSNumber(value: true))
    }

    @available(iOS 18.0, *)
    func testTagMergeNormalizesAndDeduplicatesExistingTags() throws {
        let tags = try TranscriptionEntityRecordStore.mergedTags(
            existing: ["Work"],
            input: " work、Follow-up, Client "
        )

        XCTAssertEqual(tags, ["Work", "Follow-up", "Client"])
    }

    @available(iOS 18.0, *)
    func testTagMergeRejectsEmptyInput() {
        XCTAssertThrowsError(
            try TranscriptionEntityRecordStore.mergedTags(existing: ["Work"], input: "  , 、 ")
        ) { error in
            guard case IntentError.emptyTag = error else {
                return XCTFail("Expected emptyTag, got \(error)")
            }
        }
    }
}
