import ActivityKit
import Foundation

@MainActor
final class RecordingLiveActivityManager {
    static let shared = RecordingLiveActivityManager()

    private var activity: Activity<RecordingActivityAttributes>?
    private var lastActivityRequestedAt: Date?

    private init() {}

    func startRecordingActivity(startedAt: Date = Date()) async {
        do {
            try await startRequiredRecordingActivity(startedAt: startedAt)
        } catch {
            AppLogger.error("Failed to start recording Live Activity", context: "RecordingLiveActivity", error: error)
        }
    }

    func ensureRecordingActivity(startedAt: Date = Date()) async {
        do {
            try await ensureRequiredRecordingActivity(startedAt: startedAt)
        } catch {
            AppLogger.error("Failed to ensure recording Live Activity", context: "RecordingLiveActivity", error: error)
        }
    }

    func ensureRequiredRecordingActivity(startedAt: Date = Date()) async throws {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            throw RecordingLiveActivityError.activitiesDisabled
        }

        if let activeActivity = Activity<RecordingActivityAttributes>.activities.first {
            activity = activeActivity
            return
        }

        try await startRequiredRecordingActivity(startedAt: startedAt)
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

        lastActivityRequestedAt = Date()
        let requestedActivity = try Activity.request(
            attributes: attributes,
            content: ActivityContent(state: state, staleDate: nil),
            pushType: nil
        )
        activity = requestedActivity
        AppLogger.info(
            "Recording Live Activity requested: id=\(requestedActivity.id), state=\(requestedActivity.activityState)",
            context: "RecordingLiveActivity"
        )
    }

    func activityDiagnosticsDescription() -> String {
        let trackedState = activity.map {
            "\($0.id):\($0.activityState)"
        } ?? "none"
        let systemStates = Activity<RecordingActivityAttributes>.activities.map {
            "\($0.id):\($0.activityState)"
        }.joined(separator: ",")
        let elapsed = lastActivityRequestedAt.map {
            Int(Date().timeIntervalSince($0) * 1_000)
        }
        return "activityState=\(trackedState), systemActivities=[\(systemStates)], msSinceRequest=\(elapsed.map(String.init) ?? "none")"
    }

    func endRecordingActivity(dismissalPolicy: ActivityUIDismissalPolicy = .immediate) async {
        // Always include the tracked activity. Right after `Activity.request`,
        // `Activity.activities` may not yet reflect the new activity, and if we
        // only iterated that array we would drop our reference without ending it,
        // leaving the Live Activity stuck on screen after recording stops.
        var activitiesToEnd = Activity<RecordingActivityAttributes>.activities
        if let activity, !activitiesToEnd.contains(where: { $0.id == activity.id }) {
            activitiesToEnd.append(activity)
        }

        guard !activitiesToEnd.isEmpty else {
            activity = nil
            return
        }

        let state = RecordingActivityAttributes.ContentState(
            startedAt: activity?.content.state.startedAt ?? Date(),
            status: String(localized: "Recording stopped")
        )
        let content = ActivityContent(state: state, staleDate: nil)
        let activityIDsToEnd = Set(activitiesToEnd.map(\.id))

        for activeActivity in activitiesToEnd {
            await activeActivity.end(content, dismissalPolicy: dismissalPolicy)
        }
        if Self.shouldClearTrackedActivity(
            currentID: activity?.id,
            endedIDs: activityIDsToEnd
        ) {
            activity = nil
        }
    }

    static func shouldClearTrackedActivity(
        currentID: String?,
        endedIDs: Set<String>
    ) -> Bool {
        guard let currentID else { return false }
        return endedIDs.contains(currentID)
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
