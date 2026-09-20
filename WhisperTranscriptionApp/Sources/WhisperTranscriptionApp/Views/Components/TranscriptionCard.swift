import SwiftUI

struct TranscriptionCard: View, Equatable {
    let text: String
    let segments: [TranscriptionSegment]
    let showTimestamps: Bool
    let isLoading: Bool
    let showsHeader: Bool
    let showsTimelineMarkers: Bool
    let displayStyle: TranscriptDisplayStyle
    let showsDisplayStyleControl: Bool
    let displayStyleControlAccessibilityIdentifier: String
    let onDisplayStyleToggle: (() -> Void)?
    let onSegmentLongPress: ((TranscriptionSegment) -> Void)?
    let audioPlayer: AudioPlayer?
    @State private var paragraphs: [TranscriptParagraph] = []
    @State private var textChunks: [TranscriptionTextChunk] = []

    init(
        text: String,
        segments: [TranscriptionSegment] = [],
        showTimestamps: Bool = false,
        isLoading: Bool,
        showsHeader: Bool = true,
        showsTimelineMarkers: Bool = false,
        displayStyle: TranscriptDisplayStyle = .timeline,
        showsDisplayStyleControl: Bool = false,
        displayStyleControlAccessibilityIdentifier: String = "historyTranscriptDisplayToggle",
        onDisplayStyleToggle: (() -> Void)? = nil,
        onSegmentLongPress: ((TranscriptionSegment) -> Void)? = nil,
        audioPlayer: AudioPlayer? = nil
    ) {
        self.audioPlayer = audioPlayer
        self.text = text
        self.segments = segments
        self.showTimestamps = showTimestamps
        self.isLoading = isLoading
        self.showsHeader = showsHeader
        self.showsTimelineMarkers = showsTimelineMarkers
        self.displayStyle = displayStyle
        self.showsDisplayStyleControl = showsDisplayStyleControl
        self.displayStyleControlAccessibilityIdentifier = displayStyleControlAccessibilityIdentifier
        self.onDisplayStyleToggle = onDisplayStyleToggle
        self.onSegmentLongPress = onSegmentLongPress
    }

    /// 数百行のセグメントを親の更新ごとに再diffさせないための等価判定。
    /// 描画はクロージャのnil性に依存するため、クロージャの同一性は比較しない。
    /// 呼び出し側はこのクロージャに`@Environment`由来の値(`dismiss`等)を捕捉させないこと。
    /// 等価と判定されると古い構造体コピーが残るので、捕捉したEnvironmentが陳腐化する。
    /// 描画に影響するプロパティ(`displayStyle`を含む)を追加したらここにも必ず加えること。
    /// 漏れると表示スタイルを切り替えても再描画されない。
    static func == (lhs: TranscriptionCard, rhs: TranscriptionCard) -> Bool {
        lhs.audioPlayer === rhs.audioPlayer
            && lhs.showTimestamps == rhs.showTimestamps
            && lhs.isLoading == rhs.isLoading
            && lhs.showsHeader == rhs.showsHeader
            && lhs.showsTimelineMarkers == rhs.showsTimelineMarkers
            && lhs.displayStyle == rhs.displayStyle
            && lhs.showsDisplayStyleControl == rhs.showsDisplayStyleControl
            && lhs.displayStyleControlAccessibilityIdentifier == rhs.displayStyleControlAccessibilityIdentifier
            && (lhs.onDisplayStyleToggle == nil) == (rhs.onDisplayStyleToggle == nil)
            && (lhs.onSegmentLongPress == nil) == (rhs.onSegmentLongPress == nil)
            && lhs.text == rhs.text
            && lhs.segments == rhs.segments
    }

    private var textOnlyDisplayText: String {
        TranscriptionSegment.plainText(from: segments, fallback: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsHeader {
                HStack {
                    TechLabel(text: "Transcription Result")

                    Spacer()

                    if isLoading {
                        ProgressView()
                            .tint(Theme.amber)
                            .controlSize(.small)
                    }
                }
            }

            if showsDisplayStyleControl {
                transcriptDisplayStyleControl
            }

            if isLoading && text.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Theme.panelInset)
                        .frame(height: 15)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Theme.panelInset)
                        .frame(height: 15)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Theme.panelInset)
                        .frame(width: 200, height: 15)
                }
                .shimmer()
            } else {
                if !segments.isEmpty {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(paragraphs) { paragraph in
                            TranscriptParagraphRow(
                                paragraph: paragraph,
                                showsTimestamp: displayStyle == .timeline && (showTimestamps || showsTimelineMarkers),
                                player: audioPlayer,
                                onEdit: onSegmentLongPress
                            )
                        }
                    }
                } else if !textOnlyDisplayText.isEmpty && textChunks.isEmpty {
                    ProgressView()
                        .tint(Theme.amber)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(textChunks) { chunk in
                            Text(chunk.text)
                                .font(.body)
                                .foregroundColor(Theme.textPrimary)
                                .lineSpacing(7)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
        .onChange(of: segments, initial: true) { _, value in
            paragraphs = TranscriptParagraph.make(from: value)
        }
        .task(id: segments.isEmpty ? text : nil) {
            guard segments.isEmpty else {
                textChunks = []
                return
            }
            await updateTextChunks(for: textOnlyDisplayText)
        }
        .recorderPanel()
        .accessibilityElement(children: .contain)
    }

    /// ボタン名は切り替え先のモードを示し、キャプションは現在のモードの操作を説明する。
    private var transcriptDisplayStyleControl: some View {
        let isTimeline = displayStyle == .timeline

        return VStack(alignment: .leading, spacing: 6) {
            Button {
                onDisplayStyleToggle?()
            } label: {
                Label(
                    isTimeline ? "Switch to Reading View" : "Switch to Timeline View",
                    systemImage: isTimeline ? "text.alignleft" : "list.bullet.indent"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.recorderQuiet)
            .accessibilityIdentifier(displayStyleControlAccessibilityIdentifier)

            Text(
                displayStyleDescription(isTimeline: isTimeline)
            )
            .font(Theme.sans(11))
            .foregroundColor(Theme.textSecondary)
        }
    }

    private func displayStyleDescription(isTimeline: Bool) -> LocalizedStringKey {
        if isTimeline {
            return onSegmentLongPress != nil
                ? "Long-press a paragraph to choose text to edit."
                : "Paragraphs are shown with their starting time."
        }
        return audioPlayer != nil
            ? "Paragraphs follow playback. Tapping does not move playback."
            : "Text is arranged in paragraphs for easier reading."
    }

    @MainActor
    private func updateTextChunks(for text: String) async {
        guard !text.isEmpty else {
            textChunks = []
            return
        }
        let chunks = await Task.detached(priority: .userInitiated) {
            TranscriptionTextChunk.chunks(from: text)
        }.value
        guard !Task.isCancelled else { return }
        textChunks = chunks
    }
}

/// Only these visible paragraph rows observe playback ticks, not the history screen.
private struct TranscriptParagraphRow: View {
    let paragraph: TranscriptParagraph
    let showsTimestamp: Bool
    let player: AudioPlayer?
    let onEdit: ((TranscriptionSegment) -> Void)?

    var body: some View {
        let active = player.flatMap { player in
            player.isPlaying || player.currentTime > 0
                ? paragraph.activeSegment(at: player.currentTime) : nil
        }
        VStack(alignment: .leading, spacing: 8) {
            if showsTimestamp, let first = paragraph.segments.first {
                Text(TranscriptionTimelineItem.markerLabel(seconds: Int(max(0, first.start))))
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(Theme.amber)
            }
            Text(attributedText(active: active))
                .font(.body)
                .lineSpacing(7)
                .tint(Theme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

        }
        .padding(10)
        .background(active != nil ? Theme.amber.opacity(0.08) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .leading) {
            if active != nil {
                RoundedRectangle(cornerRadius: 2).fill(Theme.amber).frame(width: 3)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcriptParagraph-\(paragraph.id)")
        .accessibilityAddTraits(active != nil ? .isSelected : [])
        .contextMenu {
            if let onEdit {
                ForEach(paragraph.segments) { segment in
                    Button { onEdit(segment) } label: {
                        Text(segment.text)
                        Image(systemName: "pencil")
                    }
                    .accessibilityIdentifier("editTranscriptSegment-\(segment.id)")
                }
            }
        }
    }

    private func attributedText(active: Int?) -> AttributedString {
        var result = AttributedString()
        var previous = ""
        for index in paragraph.parts.indices {
            let text = paragraph.parts[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
            let joined = TranscriptionSegment.joinedPlainText(from: [previous, text])
            let separator = previous.isEmpty ? "" : String(joined.dropFirst(previous.count).dropLast(text.count))
            result.append(AttributedString(separator))
            var part = AttributedString(text)
            part.foregroundColor = active == index ? Theme.amber : Theme.textPrimary
            if active == index {
                part.backgroundColor = Theme.amber.opacity(0.16)
            }
            result.append(part)
            previous = text
        }
        return result
    }
}

struct TranscriptionDetailActionRow: View {
    let icon: String
    let title: Text
    var isDestructive = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isDestructive ? Theme.rec : Theme.amber)
                .frame(width: 24)

            title
                .font(Theme.sans(15, weight: .semibold))
                .foregroundStyle(isDestructive ? Theme.rec : Theme.textPrimary)

            Spacer()

            if !isDestructive {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary.opacity(0.55))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }
}

private struct TranscriptionTextChunk: Identifiable, Sendable {
    let id: Int
    let text: String

    static func chunks(from text: String, targetLength: Int = 180) -> [TranscriptionTextChunk] {
        TranscriptParagraph.readingChunks(text, targetLength: targetLength).enumerated().map {
            TranscriptionTextChunk(id: $0.offset, text: $0.element.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

}

struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geometry in
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: Theme.amber.opacity(0.25), location: 0.5),
                            .init(color: .clear, location: 1)
                        ]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geometry.size.width * 2)
                    .offset(x: -geometry.size.width + phase * geometry.size.width * 2)
                }
            )
            .mask(content)
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

extension View {
    func shimmer() -> some View {
        modifier(ShimmerModifier())
    }
}
