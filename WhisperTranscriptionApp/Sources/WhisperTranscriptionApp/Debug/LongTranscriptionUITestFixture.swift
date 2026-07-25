import SwiftUI
import SwiftData

struct LongTranscriptionUITestFixture: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var historyViewModel = HistoryViewModel()
    @State private var didConfigureHistory = false

    private let text: String
    private let segments: [TranscriptionSegment]
    private let record: TranscriptionRecord

    init() {
        let shortSegmentText = "長文文字起こしの操作を確認します。"
        let repetitionCount = ProcessInfo.processInfo.arguments.contains("--ui-test-inline-edit")
            ? 2
            : 50
        let longSegmentText = String(
            repeating: "長文文字起こしのレイアウト安定性を確認します。",
            count: repetitionCount
        )
        let fixtureSegments = (0..<100).map { index in
            let segmentText = index < 3 ? shortSegmentText : longSegmentText
            return TranscriptionSegment(
                id: index,
                start: Double(index * 10),
                end: Double((index + 1) * 10),
                text: segmentText,
                alternatives: index == 0
                    ? [segmentText, "修正した文字起こし"]
                    : nil
            )
        }
        segments = fixtureSegments
        text = TranscriptionSegment.plainText(from: fixtureSegments)
        record = TranscriptionRecord(
            title: "Long transcription fixture",
            text: text,
            sourceType: .file,
            duration: 1_000,
            segments: fixtureSegments,
            language: "ja"
        )
    }

    var body: some View {
        if ProcessInfo.processInfo.arguments.contains("--ui-test-history-detail") {
            NavigationStack {
                HistoryDetailView(
                    record: record,
                    viewModel: historyViewModel
                )
            }
            .onAppear {
                guard !didConfigureHistory else { return }
                modelContext.insert(record)
                historyViewModel.setModelContext(modelContext)
                didConfigureHistory = true
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
