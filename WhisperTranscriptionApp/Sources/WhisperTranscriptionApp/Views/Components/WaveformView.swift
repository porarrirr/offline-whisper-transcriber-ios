import SwiftUI

/// LCD上を右から左へ流れる実レベル波形。録音停止中は暗い中心線のみ表示する。
struct WaveformView: View {
    var audioLevel: Float
    var isActive: Bool

    @State private var history: [CGFloat] = []
    private let capacity = 96

    var body: some View {
        Canvas { context, size in
            let midY = size.height / 2
            let barWidth: CGFloat = 2.5
            let spacing: CGFloat = 1.5
            let step = barWidth + spacing
            let count = min(history.count, Int(size.width / step))

            // 中心線
            var centerLine = Path()
            centerLine.move(to: CGPoint(x: 0, y: midY))
            centerLine.addLine(to: CGPoint(x: size.width, y: midY))
            context.stroke(centerLine, with: .color(Theme.displayDim.opacity(0.5)), lineWidth: 1)

            guard isActive, count > 0 else { return }

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
                    with: .color(Theme.displayAmber)
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
}
