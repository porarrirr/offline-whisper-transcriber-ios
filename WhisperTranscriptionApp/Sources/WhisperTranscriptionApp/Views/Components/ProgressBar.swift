import SwiftUI

struct ProgressBar: View {
    var progress: Double
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(AppColors.surface)
                    .frame(height: geometry.size.height)
                
                RoundedRectangle(cornerRadius: 4)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [AppColors.accent, AppColors.accentSecondary]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geometry.size.width * CGFloat(min(max(progress, 0), 1)), height: geometry.size.height)
                    .animation(.easeInOut(duration: 0.2), value: progress)
            }
        }
    }
}
