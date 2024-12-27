import SwiftUI

struct RateCardStyle: ViewModifier {
    @Environment(\.colorScheme) var colorScheme
    
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(colorScheme == .dark ? Color(.secondarySystemBackground) : Color(.secondarySystemBackground))
            .cornerRadius(12)
            .shadow(radius: 4)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
    }
}

struct InfoCardStyle: ViewModifier {
    @Environment(\.colorScheme) var colorScheme
    
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(colorScheme == .dark ? Color(.secondarySystemBackground) : Color(.secondarySystemBackground))
            .cornerRadius(12)
            .shadow(radius: 4)
    }
}

extension View {
    func rateCardStyle() -> some View {
        modifier(RateCardStyle())
    }
    
    func infoCardStyle() -> some View {
        modifier(InfoCardStyle())
    }
} 