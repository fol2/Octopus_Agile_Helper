import SwiftUI

struct RateCardStyle: ViewModifier {
    @Environment(\.colorScheme) var colorScheme
    
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(colorScheme == .dark ? Color(.systemBackground) : Color(.systemBackground))
            .cornerRadius(12)
            .shadow(radius: 4)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
    }
}

extension View {
    func rateCardStyle() -> some View {
        modifier(RateCardStyle())
    }
} 