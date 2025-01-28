import OctopusHelperShared
import SwiftUI

private struct PlanBadgesView: View {
    let supportedPlans: [SupportedPlan]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(supportedPlans, id: \.self) { plan in
                switch plan {
                case .agile:
                    BadgeView("Agile", color: .blue)
                case .flux:
                    BadgeView("Flux", color: .orange)
                case .any:
                    BadgeView("All Plans", color: .green)
                }
            }
        }
    }
}

private struct ShinyStarView: View {
    @State private var isAnimating = false

    var body: some View {
        Image(systemName: "star.fill")
            .foregroundColor(.yellow)
            .font(Theme.subFont())
            .overlay(
                GeometryReader { geometry in
                    Rectangle()
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [.clear, .white.opacity(0.5), .clear]),
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .rotationEffect(.degrees(45))
                        .offset(x: isAnimating ? geometry.size.width : -geometry.size.width)
                        .opacity(0.5)
                }
            )
            .clipShape(Rectangle())
            .onAppear {
                withAnimation(
                    Animation
                        .linear(duration: 1.5)
                        .repeatForever(autoreverses: false)
                ) {
                    isAnimating = true
                }
            }
    }
}

struct InfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @StateObject var viewModel: InfoSheetViewModel

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(viewModel.title)
                        .font(Theme.mainFont())
                        .foregroundColor(Theme.mainTextColor)
                        .textCase(.none)
                        .padding(.bottom, viewModel.isPremium ? 4 : 8)
                        .padding(.horizontal, 20)

                    if viewModel.isPremium {
                        HStack {
                            ShinyStarView()
                            Text(LocalizedStringKey("Premium Feature"))
                                .font(Theme.titleFont())
                                .foregroundColor(Theme.mainTextColor)
                                .textCase(.none)
                        }
                        .padding(.bottom, 8)
                        .padding(.horizontal, 20)
                    }

                    PlanBadgesView(supportedPlans: viewModel.supportedPlans)
                        .padding(.bottom, 8)
                        .padding(.horizontal, 20)

                    Text(viewModel.message)
                        .font(Theme.secondaryFont())
                        .foregroundColor(Theme.secondaryTextColor)
                        .textCase(.none)
                        .padding(.horizontal, 20)

                    if !viewModel.mediaItems.isEmpty {
                        VStack(alignment: .leading, spacing: 24) {
                            ForEach(viewModel.mediaItems.indices, id: \.self) { index in
                                MediaItemView(item: viewModel.mediaItems[index])
                            }
                        }
                        .padding(.vertical, 8)
                    }

                    if let linkURL = viewModel.linkURL, let linkText = viewModel.linkText {
                        Link(destination: linkURL) {
                            HStack {
                                Text(linkText)
                                    .font(Theme.secondaryFont())
                                    .foregroundColor(Theme.mainColor)
                                    .textCase(.none)
                                Image(systemName: "arrow.up.right")
                                    .font(Theme.subFont())
                                    .foregroundColor(Theme.mainColor)
                            }
                        }
                        .padding(.top, 8)
                        .padding(.horizontal, 20)
                    }
                }
                .padding(.vertical, 16)
            }
            .background(Theme.mainBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Text(LocalizedStringKey("Done"))
                            .font(Theme.secondaryFont())
                            .foregroundColor(Theme.mainColor)
                            .textCase(.none)
                    }
                }
            }
        }
        .environment(\.locale, locale)
    }
}
