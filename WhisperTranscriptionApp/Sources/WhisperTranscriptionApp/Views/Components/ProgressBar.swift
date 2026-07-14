import SwiftUI

/// 溝に沈んだトラックとアンバーの充填で構成する計器風プログレスバー。
struct ProgressBar: View {
    var progress: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.panelInset)
                    .overlay {
                        Capsule().strokeBorder(Theme.stroke, lineWidth: 1)
                    }

                Capsule()
                    .fill(Theme.amberFill)
                    .frame(width: max(geometry.size.height, geometry.size.width * CGFloat(min(max(progress, 0), 1))))
                    .animation(.easeInOut(duration: 0.2), value: progress)
            }
        }
    }
}
