import SwiftUI

struct TranscriptionCard: View {
    let text: String
    let segments: [TranscriptionSegment]
    let showTimestamps: Bool
    let isLoading: Bool
    @State private var textChunks: [TranscriptionTextChunk] = []

    init(
        text: String,
        segments: [TranscriptionSegment] = [],
        showTimestamps: Bool = false,
        isLoading: Bool
    ) {
        self.text = text
        self.segments = segments
        self.showTimestamps = showTimestamps
        self.isLoading = isLoading
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
                if showTimestamps && !segments.isEmpty {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(segments) { segment in
                            TranscriptionSegmentRow(segment: segment)
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
        .task(id: textOnlyDisplayText) {
            await updateTextChunks(for: textOnlyDisplayText)
        }
        .recorderPanel()
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

private struct TranscriptionSegmentRow: View {
    let segment: TranscriptionSegment

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(segment.formattedTimestamp)
                .font(Theme.mono(12, weight: .semibold))
                .foregroundColor(Theme.amber)

            Text(segment.text)
                .font(Theme.sans(16))
                .foregroundColor(Theme.textPrimary)
                .lineSpacing(7)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
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
