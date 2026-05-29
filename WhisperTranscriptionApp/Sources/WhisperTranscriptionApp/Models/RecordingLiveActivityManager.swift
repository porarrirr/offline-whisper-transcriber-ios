import ActivityKit
import Foundation

@MainActor
final class RecordingLiveActivityManager {
    static let shared = RecordingLiveActivityManager()

    private var activity: Activity<RecordingActivityAttributes>?

    private init() {}

    func startRecordingActivity(startedAt: Date = Date()) async {
        do {
            try await startRequiredRecordingActivity(startedAt: startedAt)
        } catch {
            AppLogger.error("Failed to start recording Live Activity", context: "RecordingLiveActivity", error: error)
        }
    }

    func startRequiredRecordingActivity(startedAt: Date = Date()) async throws {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            throw RecordingLiveActivityError.activitiesDisabled
        }

        await endRecordingActivity(dismissalPolicy: .immediate)

        let attributes = RecordingActivityAttributes(title: String(localized: "Recording"))
        let state = RecordingActivityAttributes.ContentState(
            startedAt: startedAt,
            status: String(localized: "Recording")
        )

        activity = try Activity.request(
            attributes: attributes,
            content: ActivityContent(state: state, staleDate: nil),
            pushType: nil
        )
    }

    func endRecordingActivity(dismissalPolicy: ActivityUIDismissalPolicy = .immediate) async {
        let activities = Activity<RecordingActivityAttributes>.activities
        guard !activities.isEmpty || activity != nil else { return }

        let state = RecordingActivityAttributes.ContentState(
            startedAt: activity?.content.state.startedAt ?? Date(),
            status: String(localized: "Recording stopped")
        )
        let content = ActivityContent(state: state, staleDate: nil)

        for activeActivity in activities {
            await activeActivity.end(content, dismissalPolicy: dismissalPolicy)
        }
        activity = nil
    }
}

enum RecordingLiveActivityError: LocalizedError {
    case activitiesDisabled

    var errorDescription: String? {
        switch self {
        case .activitiesDisabled:
            return String(localized: "Live Activities must be enabled to start recording from a shortcut.")
        }
    }
}
