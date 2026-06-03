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

    func testDynamicAppleSpeechStorageKeyRoundTrip() {
        let locale = AppleSpeechLocale(localeIdentifier: "fr_FR")
        let model = TranscriptionModel.appleSpeech(locale)

        XCTAssertEqual(model.storageKey, "apple-speech:fr_FR")
        XCTAssertEqual(TranscriptionModel(storageKey: model.storageKey), model)
    }

    func testInvalidStorageKeysReturnNil() {
        XCTAssertNil(TranscriptionModel(storageKey: ""))
        XCTAssertNil(TranscriptionModel(storageKey: "whisper:missing"))
        XCTAssertNil(TranscriptionModel(storageKey: "apple-speech:missing"))
        XCTAssertNil(TranscriptionModel(legacyWhisperRawValue: "missing"))
    }

    func testPrimaryModelDisplayNamesIdentifyBackend() {
        XCTAssertTrue(WhisperModelSize.tiny.displayName.contains("Whisper"))
        XCTAssertTrue(AppleSpeechLocale.jaJP.displayName.contains("SpeechTranscriber"))
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

    func testModelFileSizeValidationRequiresExactPublishedSize() {
        let size = WhisperModelSize.tiny

        XCTAssertTrue(size.isValidModelFileSize(size.modelFileSizeBytes))
        XCTAssertFalse(size.isValidModelFileSize(size.modelFileSizeBytes - 1))
        XCTAssertFalse(size.isValidModelFileSize(size.modelFileSizeBytes + 1))
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

    func testPickerOptionsIncludeSmallQ5WhisperModel() {
        XCTAssertTrue(TranscriptionModel.pickerOptions.contains(.whisper(.smallQ5_1)))
    }

    func testPreferredDefaultsUseSupportedSpeechLocale() {
        let defaults = TranscriptionDefaultResolver.preferredDefaults(
            preferredLanguages: ["en-US"],
            supportedSpeechLocale: Locale(identifier: "en_US")
        )

        XCTAssertEqual(defaults.model, .appleSpeech(AppleSpeechLocale(localeIdentifier: "en_US")))
        XCTAssertEqual(defaults.whisperLanguage, "en")
    }

    func testPreferredDefaultsUseSmallQ5WhenSpeechLocaleIsUnsupported() {
        let defaults = TranscriptionDefaultResolver.preferredDefaults(
            preferredLanguages: ["fr-FR"],
            supportedSpeechLocale: nil
        )

        XCTAssertEqual(defaults.model, .whisper(.smallQ5_1))
        XCTAssertEqual(defaults.whisperLanguage, "fr")
    }

    func testDefaultWhisperLanguageUsesDeviceLanguageWhenSupported() {
        XCTAssertEqual(
            TranscriptionDefaultResolver.defaultWhisperLanguage(preferredLanguages: ["ja-JP"]),
            "ja"
        )
        XCTAssertEqual(
            TranscriptionDefaultResolver.defaultWhisperLanguage(preferredLanguages: ["en-US"]),
            "en"
        )
    }

    func testDefaultWhisperLanguageUsesAutoWhenUnsupported() {
        XCTAssertEqual(
            TranscriptionDefaultResolver.defaultWhisperLanguage(preferredLanguages: ["sv-SE"]),
            "auto"
        )
    }

    func testPickerOptionsIncludeSelectedDynamicAppleSpeechLocale() {
        let selectedModel = TranscriptionModel.appleSpeech(AppleSpeechLocale(localeIdentifier: "fr_FR"))
        let options = TranscriptionModel.pickerOptions(
            supportsAppleSpeech: true,
            selectedModel: selectedModel
        )

        XCTAssertTrue(options.contains(selectedModel))
    }

    func testLocaleDefaultResolutionKeepsExistingTinySelection() {
        XCTAssertFalse(
            TranscriptionDefaultResolver.shouldResolveLocaleDefaultModel(
                hadModelSelection: true,
                selectedModelStorageKey: TranscriptionModel.whisper(.tiny).storageKey
            )
        )
    }

    func testLocaleDefaultResolutionAppliesToMissingOrOldAppleSpeechDefault() {
        XCTAssertTrue(
            TranscriptionDefaultResolver.shouldResolveLocaleDefaultModel(
                hadModelSelection: false,
                selectedModelStorageKey: nil
            )
        )
        XCTAssertTrue(
            TranscriptionDefaultResolver.shouldResolveLocaleDefaultModel(
                hadModelSelection: true,
                selectedModelStorageKey: TranscriptionModel.appleSpeech(.jaJP).storageKey
            )
        )
    }
}
