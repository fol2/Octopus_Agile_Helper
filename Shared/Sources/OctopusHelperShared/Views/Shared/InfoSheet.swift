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

private struct PremiumSparkleView: View {
    @State private var starAngle = Angle.degrees(0)
    @State private var starScale: CGFloat = 1.0
    @State private var sparkleTrigger = false

    var body: some View {
        ZStack {
            // Background glow
            Image(systemName: "sparkles")
                .symbolRenderingMode(.palette)
                .foregroundStyle(
                    AngularGradient(
                        gradient: Gradient(colors: [
                            Theme.secondaryColor,
                            Theme.mainColor,
                            Theme.secondaryColor,
                        ]),
                        center: .center
                    )
                )
                .blur(radius: 1.5)
                .scaleEffect(sparkleTrigger ? 1.3 : 0.8)
                .opacity(sparkleTrigger ? 0.4 : 0.8)
                .animation(
                    .easeInOut(duration: 1.8).repeatForever(autoreverses: true),
                    value: sparkleTrigger
                )

            // Main sparkle
            Image(systemName: "sparkle")
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 14))
                .rotationEffect(starAngle)
                .scaleEffect(starScale)
                .animation(
                    .spring(response: 0.3, dampingFraction: 0.2),
                    value: starScale
                )
                .onAppear {
                    withAnimation(
                        .easeInOut(duration: 2.8).repeatForever(autoreverses: true)
                    ) {
                        starAngle = .degrees(360)
                    }
                    sparkleTrigger = true
                }
        }
        .task {
            // Random sparkle bursts
            while true {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                withAnimation(
                    .interactiveSpring(response: 0.3, dampingFraction: 0.5)
                ) {
                    starScale = 1.5
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
                withAnimation(.easeOut(duration: 0.4)) {
                    starScale = 1.0
                }
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
                            PremiumSparkleView()
                            Text(LocalizedStringKey("Premium Feature"))
                                .font(Theme.titleFont())
                                .foregroundColor(Theme.mainTextColor)
                                .textCase(.none)
                        }
                        .padding(.bottom, 8)
                        .padding(.horizontal, 20)
                    }

                    if viewModel.isCard {
                        PlanBadgesView(supportedPlans: viewModel.supportedPlans)
                            .padding(.bottom, 8)
                            .padding(.horizontal, 20)
                    }

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
