import XCTest
@testable import WhisperTranscriptionApp

final class CoreMLEncoderManifestTests: XCTestCase {
    func testAOTStorageFormulaIncludesArchiveInstallAndAtLeast512MiBHeadroom() {
        let installed: Int64 = 300 * 1024 * 1024
        let artifact = CoreMLEncoderArtifact(
            modelID: "small",
            url: URL(string: "https://example.invalid/small.zip")!,
            sha256: String(repeating: "a", count: 64),
            archiveBytes: 100 * 1024 * 1024,
            installedBytes: installed,
            aotHeadroomBytes: max(512 * 1024 * 1024, installed * 2)
        )

        XCTAssertEqual(
            artifact.requiredInstallationBytes,
            artifact.archiveBytes + installed + installed * 2
        )
    }

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
