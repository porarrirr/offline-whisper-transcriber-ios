import SwiftUI

/// 録音中は実レベルを描画し、待機中は控えめな静止波形を表示する。
struct WaveformView: View {
    var audioLevel: Float
    var isActive: Bool

    @State private var history: [CGFloat] = []
    private let capacity = 96

    var body: some View {
        Canvas { context, size in
            let midY = size.height / 2
            let barWidth: CGFloat = 3
            let spacing: CGFloat = 4
            let step = barWidth + spacing
            let availableCount = Int(size.width / step)

            guard isActive else {
                let count = min(availableCount, idlePattern.count)
                let pattern = idlePattern.prefix(count)
                let startX = (size.width - CGFloat(count) * step) / 2

                for (index, level) in pattern.enumerated() {
                    let halfHeight = max(1.5, level * midY * 0.85)
                    let rect = CGRect(
                        x: startX + CGFloat(index) * step,
                        y: midY - halfHeight,
                        width: barWidth,
                        height: halfHeight * 2
                    )
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 1.5),
                        with: .color(Theme.textSecondary.opacity(0.24))
                    )
                }
                return
            }

            let count = min(history.count, availableCount)
            guard count > 0 else { return }

            let recent = history.suffix(count)
            for (index, level) in recent.enumerated() {
                let x = size.width - CGFloat(recent.count - index) * step
                let halfHeight = max(1.5, level * midY * 0.92)
                let rect = CGRect(
                    x: x,
                    y: midY - halfHeight,
                    width: barWidth,
                    height: halfHeight * 2
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 1),
                    with: .color(Theme.amber)
                )
            }
        }
        .onChange(of: audioLevel) { _, newLevel in
            guard isActive else { return }
            history.append(normalized(newLevel))
            if history.count > capacity {
                history.removeFirst(history.count - capacity)
            }
        }
        .onChange(of: isActive) { _, active in
            if !active {
                history = []
            }
        }
        .accessibilityHidden(true)
    }

    private func normalized(_ level: Float) -> CGFloat {
        CGFloat(min(max((level + 60) / 60, 0), 1))
    }

    private var idlePattern: [CGFloat] {
        [
            0.05, 0.06, 0.07, 0.12, 0.18, 0.10, 0.08, 0.15,
            0.28, 0.46, 0.26, 0.14, 0.09, 0.08, 0.12, 0.18,
            0.32, 0.58, 0.74, 0.52, 0.36, 0.22, 0.12, 0.08,
            0.06, 0.08, 0.11, 0.17, 0.24, 0.16, 0.10, 0.08,
            0.07, 0.10, 0.16, 0.25, 0.18, 0.11, 0.08, 0.06,
            0.05, 0.05, 0.05, 0.05
        ]
    }
}
