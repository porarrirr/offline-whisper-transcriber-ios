import XCTest
@testable import WhisperTranscriptionApp

final class CoreMLEncoderManifestTests: XCTestCase {
    func testManifestRejectsEntriesWithoutCompleteChecksum() {
        let manifest = CoreMLEncoderManifest(
            version: "test",
            releaseTag: "test",
            toolchain: [:],
            models: [
                CoreMLEncoderArtifact(
                    modelID: "tiny",
                    url: URL(string: "https://example.invalid/tiny.zip")!,
                    sha256: "missing",
                    archiveBytes: 1,
                    installedBytes: 1,
                    aotHeadroomBytes: 1
                )
            ]
        )
        XCTAssertNil(manifest.artifact(for: "tiny"))
    }
}
