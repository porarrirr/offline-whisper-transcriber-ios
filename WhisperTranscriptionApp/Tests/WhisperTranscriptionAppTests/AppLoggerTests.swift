import XCTest
@testable import WhisperTranscriptionApp

final class AppLoggerTests: XCTestCase {
    func testLaunchRecordsCurrentVersionAndVersionTransitionAcrossInstances() {
        let suiteName = "AppLoggerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstLaunch = AppLogger(defaults: defaults)
        firstLaunch.recordAppLaunch(version: "1.0", build: "10")

        let updatedLaunch = AppLogger(defaults: defaults)
        updatedLaunch.recordAppLaunch(version: "1.1", build: "11")
        updatedLaunch.recordAppLaunch(version: "1.1", build: "11")

        XCTAssertEqual(updatedLaunch.entries.count, 3)
        XCTAssertEqual(updatedLaunch.entries[0].message, "App launched: 1.0 (build 10) (prior version unknown)")
        XCTAssertEqual(updatedLaunch.entries[1].message, "App updated: 1.0 (build 10) -> 1.1 (build 11)")
        XCTAssertEqual(updatedLaunch.entries[2].message, "App launched: 1.1 (build 11)")
    }

    func testExportCreatesUTF8TextFileWithCompleteLog() throws {
        let suiteName = "AppLoggerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let logger = AppLogger(defaults: defaults)
        logger.recordAppLaunch(version: "1.0", build: "10")
        logger.recordAppLaunch(version: "1.1", build: "11")

        let url = try logger.exportFile()
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(url.pathExtension, "txt")
        let exportedText = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(exportedText, logger.exportText)
        XCTAssertTrue(exportedText.contains("App updated: 1.0 (build 10) -> 1.1 (build 11)"))
    }
}
