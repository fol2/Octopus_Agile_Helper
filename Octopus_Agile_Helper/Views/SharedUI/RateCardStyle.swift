import SwiftUI

struct RateCardStyle: ViewModifier {
    @Environment(\.colorScheme) var colorScheme
    
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Theme.secondaryBackground)
            .cornerRadius(12)
            .padding(.bottom, 12)
            .padding(.horizontal, 8)
    }
}

struct InfoCardStyle: ViewModifier {
    @Environment(\.colorScheme) var colorScheme
    
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Theme.secondaryBackground)
            .cornerRadius(12)
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
