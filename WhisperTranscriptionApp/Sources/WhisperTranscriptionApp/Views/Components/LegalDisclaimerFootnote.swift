import SwiftUI

struct LegalDisclaimerFootnote: View {
    var text: String = AppDisclaimer.shortFootnote

    var body: some View {
        Text(LocalizedStringKey(text))
            .font(AppFonts.caption)
            .foregroundColor(AppColors.textSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .fixedSize(horizontal: false, vertical: true)
    }
}
