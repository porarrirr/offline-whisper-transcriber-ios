import SwiftUI

struct LongTranscriptionUITestFixture: View {
    private let text: String
    private let segments: [TranscriptionSegment]

    init() {
        let segmentText = String(repeating: "長文文字起こしのレイアウト安定性を確認します。", count: 50)
        segments = (0..<100).map { index in
            TranscriptionSegment(
                id: index,
                start: Double(index * 10),
                end: Double((index + 1) * 10),
                text: segmentText
            )
        }
        text = TranscriptionSegment.plainText(from: segments)
    }

    var body: some View {
        if ProcessInfo.processInfo.arguments.contains("--ui-test-history-detail") {
            NavigationStack {
                HistoryDetailView(
                    record: TranscriptionRecord(
                        title: "Long transcription fixture",
                        text: text,
                        sourceType: .file,
                        duration: 1_000,
                        segments: segments,
                        language: "ja"
                    ),
                    viewModel: HistoryViewModel()
                )
            }
        } else {
            ResultView(
                title: "Long transcription fixture",
                text: text,
                segments: segments,
                duration: 1_000,
                language: "ja",
                onDismiss: {}
            )
        }
    }
}
