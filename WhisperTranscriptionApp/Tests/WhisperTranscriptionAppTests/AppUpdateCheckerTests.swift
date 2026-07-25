import XCTest
@testable import WhisperTranscriptionApp

final class AppUpdateCheckerTests: XCTestCase {
    func testSnoozeSuppressesReminderForSevenDays() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var currentDate = Date(timeIntervalSince1970: 1_000_000)
        let checker = AppUpdateChecker(
            session: .shared,
            bundle: .main,
            defaults: defaults,
            now: { currentDate }
        )

        checker.snoozeUpdateReminder()

        XCTAssertTrue(checker.isUpdateReminderSnoozed)

        currentDate.addTimeInterval(7 * 24 * 60 * 60 - 1)
        XCTAssertTrue(checker.isUpdateReminderSnoozed)

        currentDate.addTimeInterval(1)
        XCTAssertFalse(checker.isUpdateReminderSnoozed)
    }

    private let suiteName = "AppUpdateCheckerTests"

    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
