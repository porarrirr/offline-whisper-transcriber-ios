import XCTest
@testable import WhisperTranscriptionApp

final class TranscriptionModelTests: XCTestCase {
    func testWhisperModelStorageKeysRoundTripIncludingLegacyRawValues() {
        for size in WhisperModelSize.allCases {
            let model = TranscriptionModel.whisper(size)

            XCTAssertEqual(TranscriptionModel(storageKey: model.storageKey), model)
            XCTAssertEqual(TranscriptionModel(legacyWhisperRawValue: size.rawValue), model)
            XCTAssertEqual(size.downloadURL?.lastPathComponent, size.fileName)
        }
    }

    func testAppleSpeechStorageKeysRoundTrip() {
        for locale in AppleSpeechLocale.allCases {
            let model = TranscriptionModel.appleSpeech(locale)

            XCTAssertEqual(TranscriptionModel(storageKey: model.storageKey), model)
            XCTAssertEqual(locale.localeIdentifier, locale.rawValue)
        }
    }

    func testInvalidStorageKeysReturnNil() {
        XCTAssertNil(TranscriptionModel(storageKey: ""))
        XCTAssertNil(TranscriptionModel(storageKey: "whisper:missing"))
        XCTAssertNil(TranscriptionModel(storageKey: "apple-speech:missing"))
        XCTAssertNil(TranscriptionModel(legacyWhisperRawValue: "missing"))
    }

    func testRequiredDownloadBytesIncludesOnlyMissingArtifactsAndSafetyBuffer() {
        let size = WhisperModelSize.largeV3TurboQ5_0
        let buffer = WhisperModelSize.downloadSafetyBufferBytes

        XCTAssertEqual(
            size.requiredDownloadBytes(modelExists: false, encoderExists: false),
            buffer + size.modelFileSizeBytes + size.coreMLEncoderPeakBytes
        )
        XCTAssertEqual(
            size.requiredDownloadBytes(modelExists: true, encoderExists: false),
            buffer + size.coreMLEncoderPeakBytes
        )
        XCTAssertEqual(
            size.requiredDownloadBytes(modelExists: false, encoderExists: true),
            buffer + size.modelFileSizeBytes
        )
        XCTAssertEqual(
            size.requiredDownloadBytes(modelExists: true, encoderExists: true),
            buffer
        )
    }

    func testQuantizedWhisperVariantsUseBaseCoreMLEncoderName() {
        XCTAssertEqual(WhisperModelSize.tinyQ5_1.coreMLEncoderDirectoryName, WhisperModelSize.tiny.coreMLEncoderDirectoryName)
        XCTAssertEqual(WhisperModelSize.baseQ5_1.coreMLEncoderDirectoryName, WhisperModelSize.base.coreMLEncoderDirectoryName)
        XCTAssertEqual(WhisperModelSize.smallQ5_1.coreMLEncoderDirectoryName, WhisperModelSize.small.coreMLEncoderDirectoryName)
        XCTAssertEqual(WhisperModelSize.mediumQ5_0.coreMLEncoderDirectoryName, WhisperModelSize.medium.coreMLEncoderDirectoryName)
        XCTAssertEqual(
            WhisperModelSize.largeV3TurboQ5_0.coreMLEncoderDirectoryName,
            WhisperModelSize.largeV3TurboQ8_0.coreMLEncoderDirectoryName
        )
    }
}
