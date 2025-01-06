import SwiftUI

public struct SplashScreenView: View {
    @Binding var isLoading: Bool
    
    public init(isLoading: Binding<Bool>) {
        self._isLoading = isLoading
    }
    
    public var body: some View {
        ZStack {
            Color(Theme.mainBackground)
                .ignoresSafeArea()
            
            VStack {
                Image("loadingIcon")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 120, height: 120)
                    .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
                
                Text("Octomiser")
                    .font(.title)
                    .fontWeight(.medium)
                    .foregroundColor(Color(Theme.secondaryTextColor))
                    .padding(.top, 20)
            }
        }
    }
}

#Preview {
    SplashScreenView(isLoading: .constant(true))
}
