import ActivityKit
import Foundation

@MainActor
final class RecordingLiveActivityManager {
    static let shared = RecordingLiveActivityManager()

    private var activity: Activity<RecordingActivityAttributes>?

    private init() {}

    func startRecordingActivity(startedAt: Date = Date()) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            AppLogger.info("Live Activities are disabled for this device or app", context: "RecordingLiveActivity")
            return
        }

        await endRecordingActivity(dismissalPolicy: .immediate)

        let attributes = RecordingActivityAttributes(title: String(localized: "Recording"))
        let state = RecordingActivityAttributes.ContentState(
            startedAt: startedAt,
            status: String(localized: "Recording")
        )

        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
        } catch {
            AppLogger.error("Failed to start recording Live Activity", context: "RecordingLiveActivity", error: error)
        }
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
