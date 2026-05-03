import SwiftUI

struct GridView: View {

    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            let h = geometry.size.height
            let thirdW = w / 3
            let thirdH = h / 3

            Path { path in
                path.move(to: CGPoint(x: thirdW, y: 0))
                path.addLine(to: CGPoint(x: thirdW, y: h))
                path.move(to: CGPoint(x: thirdW * 2, y: 0))
                path.addLine(to: CGPoint(x: thirdW * 2, y: h))
                path.move(to: CGPoint(x: 0, y: thirdH))
                path.addLine(to: CGPoint(x: w, y: thirdH))
                path.move(to: CGPoint(x: 0, y: thirdH * 2))
                path.addLine(to: CGPoint(x: w, y: thirdH * 2))
            }
            .stroke(.white.opacity(0.4), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}
