import SwiftUI

struct TranscriptionCard: View {
    let text: String
    let segments: [TranscriptionSegment]
    let showTimestamps: Bool
    let isLoading: Bool
    let showsTimelineMarkers: Bool
    let selectedSegmentID: Int?
    let onSegmentTap: ((TranscriptionSegment) -> Void)?
    let onSegmentLongPress: ((TranscriptionSegment) -> Void)?
    let onAlternativeSelect: ((TranscriptionSegment, String) -> Void)?
    @State private var textChunks: [TranscriptionTextChunk] = []

    init(
        text: String,
        segments: [TranscriptionSegment] = [],
        showTimestamps: Bool = false,
        isLoading: Bool,
        showsTimelineMarkers: Bool = false,
        selectedSegmentID: Int? = nil,
        onSegmentTap: ((TranscriptionSegment) -> Void)? = nil,
        onSegmentLongPress: ((TranscriptionSegment) -> Void)? = nil,
        onAlternativeSelect: ((TranscriptionSegment, String) -> Void)? = nil
    ) {
        self.text = text
        self.segments = segments
        self.showTimestamps = showTimestamps
        self.isLoading = isLoading
        self.showsTimelineMarkers = showsTimelineMarkers
        self.selectedSegmentID = selectedSegmentID
        self.onSegmentTap = onSegmentTap
        self.onSegmentLongPress = onSegmentLongPress
        self.onAlternativeSelect = onAlternativeSelect
    }

    private var textOnlyDisplayText: String {
        TranscriptionSegment.plainText(from: segments, fallback: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                TechLabel(text: "Transcription Result")

                Spacer()

                if isLoading {
                    ProgressView()
                        .tint(Theme.amber)
                        .controlSize(.small)
                }
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
                if shouldShowSegmentRows {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(timelineItems) { item in
                            switch item {
                            case .marker(let seconds):
                                TranscriptionTimelineMarker(seconds: seconds)
                            case .segment(let segment):
                                TranscriptionSegmentRow(
                                    segment: segment,
                                    showTimestamp: showTimestamps,
                                    isSelected: selectedSegmentID == segment.id,
                                    onTap: onSegmentTap,
                                    onLongPress: onSegmentLongPress,
                                    onAlternativeSelect: onAlternativeSelect
                                )
                            }
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
                                .font(Theme.sans(16))
                                .foregroundColor(Theme.textPrimary)
                                .lineSpacing(7)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
        .task(id: shouldShowSegmentRows ? nil : textOnlyDisplayText) {
            guard !shouldShowSegmentRows else {
                textChunks = []
                return
            }
            await updateTextChunks(for: textOnlyDisplayText)
        }
        .recorderPanel()
        .accessibilityElement(children: .contain)
    }

    private var shouldShowSegmentRows: Bool {
        !segments.isEmpty && (
            showTimestamps
                || showsTimelineMarkers
                || onSegmentTap != nil
                || onSegmentLongPress != nil
        )
    }

    private var timelineItems: [TranscriptionTimelineItem] {
        if showsTimelineMarkers {
            return TranscriptionTimelineItem.items(from: segments)
        }
        return segments.map(TranscriptionTimelineItem.segment)
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

private struct TranscriptionTimelineMarker: View {
    let seconds: Int

    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(Theme.stroke)
                .frame(height: 1)

            Text(TranscriptionTimelineItem.markerLabel(seconds: seconds))
                .font(Theme.mono(11, weight: .semibold))
                .foregroundColor(Theme.amber)
                .fixedSize()

            Rectangle()
                .fill(Theme.stroke)
                .frame(height: 1)
        }
        .accessibilityElement()
        .accessibilityIdentifier("timelineMarker-\(seconds)")
        .accessibilityLabel(
            Text("Timeline marker \(TranscriptionTimelineItem.markerLabel(seconds: seconds))")
        )
    }
}

private struct TranscriptionSegmentRow: View {
    let segment: TranscriptionSegment
    let showTimestamp: Bool
    let isSelected: Bool
    let onTap: ((TranscriptionSegment) -> Void)?
    let onLongPress: ((TranscriptionSegment) -> Void)?
    let onAlternativeSelect: ((TranscriptionSegment, String) -> Void)?

    private var isInteractive: Bool {
        onTap != nil || onLongPress != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isInteractive {
                primaryContent
                    .gesture(segmentGesture)
                    .accessibilityAction(named: Text("Play from here")) {
                        onTap?(segment)
                    }
                    .accessibilityAction(named: Text("Edit transcription segment")) {
                        onLongPress?(segment)
                    }
            } else {
                primaryContent
            }

            if isSelected, !segment.selectableAlternatives.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(
                            Array(segment.selectableAlternatives.enumerated()),
                            id: \.element
                        ) { index, alternative in
                            Button {
                                onAlternativeSelect?(segment, alternative)
                            } label: {
                                Text(alternative)
                                    .font(Theme.sans(13, weight: .medium))
                                    .foregroundColor(Theme.amber)
                                    .lineLimit(1)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(Theme.panelInset, in: Capsule())
                                    .overlay {
                                        Capsule().strokeBorder(Theme.stroke, lineWidth: 1)
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(
                                "transcriptionAlternative-\(segment.id)-\(index)"
                            )
                            .accessibilityLabel(Text("Replace with \(alternative)"))
                        }
                    }
                }
            }
        }
    }

    private var primaryContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showTimestamp {
                Text(segment.formattedTimestamp)
                    .font(Theme.mono(12, weight: .semibold))
                    .foregroundColor(Theme.amber)
            }

            segmentText
        }
        .padding(.vertical, isInteractive ? 6 : 0)
        .padding(.horizontal, isInteractive ? 8 : 0)
        .background(
            isSelected ? Theme.panelInset : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("transcriptionSegment-\(segment.id)")
    }

    @ViewBuilder
    private var segmentText: some View {
        if isInteractive {
            Text(segment.text)
                .font(Theme.sans(16))
                .foregroundColor(Theme.textPrimary)
                .lineSpacing(7)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(segment.text)
                .font(Theme.sans(16))
                .foregroundColor(Theme.textPrimary)
                .lineSpacing(7)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var segmentGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.5)
            .exclusively(before: TapGesture())
            .onEnded { value in
                switch value {
                case .first:
                    onLongPress?(segment)
                case .second:
                    onTap?(segment)
                }
            }
    }
}

private struct TranscriptionTextChunk: Identifiable, Sendable {
    let id: Int
    let text: String

    static func chunks(from text: String, targetLength: Int = 1_200) -> [TranscriptionTextChunk] {
        guard !text.isEmpty else { return [] }

        var chunks: [TranscriptionTextChunk] = []
        chunks.reserveCapacity(max(1, text.count / targetLength))

        var current = ""
        current.reserveCapacity(targetLength)

        func appendCurrentIfNeeded() {
            guard !current.isEmpty else { return }
            chunks.append(TranscriptionTextChunk(id: chunks.count, text: current))
            current = ""
            current.reserveCapacity(targetLength)
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let lineText = String(line)
            if current.count + lineText.count + 1 > targetLength {
                appendCurrentIfNeeded()
            }

            if lineText.count > targetLength {
                var start = lineText.startIndex
                while start < lineText.endIndex {
                    let end = lineText.index(start, offsetBy: targetLength, limitedBy: lineText.endIndex) ?? lineText.endIndex
                    chunks.append(TranscriptionTextChunk(id: chunks.count, text: String(lineText[start..<end])))
                    start = end
                }
            } else {
                if !current.isEmpty {
                    current.append("\n")
                }
                current.append(lineText)
            }
        }

        appendCurrentIfNeeded()
        return chunks
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
