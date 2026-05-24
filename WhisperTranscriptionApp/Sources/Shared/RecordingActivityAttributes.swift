import ActivityKit
import Foundation

struct RecordingActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        let startedAt: Date
        let status: String
    }

    let title: String
}
