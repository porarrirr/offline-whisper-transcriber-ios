import SwiftUI

struct TranscriptionCard: View {
    let text: String
    let isLoading: Bool
    
    @State private var displayedText = ""
    @State private var currentIndex = 0
    
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
                Text(displayedText)
                    .font(AppFonts.body)
                    .foregroundColor(AppColors.textPrimary)
                    .lineSpacing(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onAppear {
                        if !isLoading {
                            animateText()
                        }
                    }
                    .onChange(of: text) { _, newValue in
                        if !isLoading {
                            displayedText = ""
                            currentIndex = 0
                            animateText()
                        }
                    }
            }
        }
        .padding()
        .background(AppColors.cardBackground)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(AppColors.accent.opacity(0.2), lineWidth: 1)
        )
    }
    
    private func animateText() {
        guard currentIndex < text.count else { return }
        
        let index = text.index(text.startIndex, offsetBy: currentIndex)
        displayedText += String(text[index])
        currentIndex += 1
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            animateText()
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
