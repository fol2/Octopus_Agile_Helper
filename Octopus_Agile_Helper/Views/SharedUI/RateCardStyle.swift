import SwiftUI

struct RateCardStyle: ViewModifier {
    @Environment(\.colorScheme) var colorScheme
    
    func body(content: Content) -> some View {
        content
            .padding()
            .background(colorScheme == .dark ? Color.black : Color.white)
            .cornerRadius(12)
            .shadow(radius: 4)
            .padding(.horizontal)
            .padding(.vertical, 4)
    }
}

extension View {
    func rateCardStyle() -> some View {
        modifier(RateCardStyle())
    }
} 