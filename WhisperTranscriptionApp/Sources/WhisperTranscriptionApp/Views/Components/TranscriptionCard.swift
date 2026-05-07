import SwiftUI

struct TranscriptionCard: View {
    let text: String
    let segments: [TranscriptionSegment]
    let showTimestamps: Bool
    let isLoading: Bool
    @State private var textChunks: [TranscriptionTextChunk]

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
        _textChunks = State(initialValue: TranscriptionTextChunk.chunks(from: text))
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "text.quote")
                    .foregroundColor(AppColors.accent)
                
                Text("文字起こし結果")
                    .font(AppFonts.headline)
                    .foregroundColor(AppColors.textPrimary)
                
                Spacer()
                
                if isLoading {
                    ProgressView()
                        .tint(AppColors.accent)
                }
            }
            
            if isLoading && text.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(AppColors.surface)
                        .frame(height: 16)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(AppColors.surface)
                        .frame(height: 16)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(AppColors.surface)
                        .frame(width: 200, height: 16)
                }
                .shimmer()
            } else {
                if showTimestamps && !segments.isEmpty {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(segments) { segment in
                            TranscriptionSegmentRow(segment: segment)
                        }
                    }
                } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(textChunks) { chunk in
                            Text(chunk.text)
                                .font(AppFonts.body)
                                .foregroundColor(AppColors.textPrimary)
                                .lineSpacing(6)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
        .onChange(of: text) { _, newValue in
            textChunks = TranscriptionTextChunk.chunks(from: newValue)
        }
        .padding()
        .background(AppColors.cardBackground)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(AppColors.accent.opacity(0.2), lineWidth: 1)
        )
    }
}

private struct TranscriptionSegmentRow: View {
    let segment: TranscriptionSegment

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(segment.formattedTimestamp)
                .font(AppFonts.caption)
                .foregroundColor(AppColors.accent)
                .monospacedDigit()

            Text(segment.text)
                .font(AppFonts.body)
                .foregroundColor(AppColors.textPrimary)
                .lineSpacing(6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct TranscriptionTextChunk: Identifiable {
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
                            .init(color: AppColors.accent.opacity(0.2), location: 0.5),
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
