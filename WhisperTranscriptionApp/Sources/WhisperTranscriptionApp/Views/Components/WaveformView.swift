import SwiftUI

struct WaveformView: View {
    var audioLevel: Float
    
    @State private var randomSeed: [CGFloat] = []
    let barCount = 30
    
    init(audioLevel: Float) {
        self.audioLevel = audioLevel
    }
    
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 4) {
                ForEach(0..<barCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [AppColors.accent, AppColors.accentSecondary]),
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(width: (geometry.size.width - CGFloat(barCount - 1) * 4) / CGFloat(barCount))
                        .frame(height: barHeight(for: index, in: geometry.size.height))
                        .animation(.easeInOut(duration: 0.1), value: audioLevel)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .onAppear {
            randomSeed = (0..<barCount).map { _ in CGFloat.random(in: 0.3...1.0) }
        }
    }
    
    private func barHeight(for index: Int, in maxHeight: CGFloat) -> CGFloat {
        guard index < randomSeed.count else { return 4 }
        let normalizedLevel = min(max((audioLevel + 60) / 60, 0), 1)
        let baseHeight = maxHeight * 0.2
        let dynamicHeight = maxHeight * 0.8 * CGFloat(normalizedLevel) * randomSeed[index]
        return baseHeight + dynamicHeight
    }
}
