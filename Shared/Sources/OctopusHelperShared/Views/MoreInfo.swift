import CoreData
import SwiftUI

public struct MoreInfo: View {
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.openURL) private var openURL

    // Alert States
    @State private var showingClearDataAlert = false
    @State private var showingResetAllAlert = false
    @State private var isProcessing = false
    @State private var operationError: String?
    @State private var showingGDPR = false
    @State private var showingTerms = false

    // Animation States
    @State private var isAnimating = false
    @State private var rotationAngle: Double = 0
    @State private var cornerRadius: CGFloat = 12
    @State private var shineOffset: CGFloat = -100
    @State private var tiltAngle: CGFloat = 0
    @State private var timer: Timer?

    // Animation Configuration
    private let animationConfig = AnimationConfig(
        enableShine: true,
        enablePulse: true,
        enable3DTilt: true,
        enableMorphingCorners: true
    )

    // Animation Types
    private enum AnimationType: CaseIterable {
        case shine
        case pulse
        case tilt
        case morphCorners
    }

    public init() {}

    private struct AnimationConfig {
        let enableShine: Bool
        let enablePulse: Bool
        let enable3DTilt: Bool
        let enableMorphingCorners: Bool

        func isEnabled(_ type: AnimationType) -> Bool {
            switch type {
            case .shine: return enableShine
            case .pulse: return enablePulse
            case .tilt: return enable3DTilt
            case .morphCorners: return enableMorphingCorners
            }
        }
    }

    private func createShineEffect() -> some View {
        Rectangle()
            .fill(
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color.white.opacity(0),
                        Color.white.opacity(0.2),
                        Color.white.opacity(0),
                    ]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: 50)
            .offset(x: shineOffset)
            .blur(radius: 5)
            .mask(Image("loadingIcon").resizable())
    }

    private func startRandomAnimation() {
        // Cancel existing timer if any
        timer?.invalidate()

        // Start the animation sequence
        triggerNextAnimation()
    }

    private func triggerNextAnimation() {
        // Get available animation types
        let availableTypes = AnimationType.allCases.filter { animationConfig.isEnabled($0) }
        guard !availableTypes.isEmpty else { return }

        // Pick a random animation type
        let randomType = availableTypes.randomElement()!

        // Trigger the selected animation
        triggerAnimation(type: randomType)

        // Schedule next animation with random delay
        let randomDelay = Double.random(in: 10...20)
        DispatchQueue.main.asyncAfter(deadline: .now() + randomDelay) {
            self.triggerNextAnimation()
        }
    }

    private func triggerAnimation(type: AnimationType) {
        // Reset all animations first
        withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
            isAnimating = false
            rotationAngle = 0
            cornerRadius = 12
            tiltAngle = 0
        }
        shineOffset = -100

        // Trigger the specific animation
        switch type {
        case .shine:
            withAnimation(.linear(duration: 1.0)) {
                shineOffset = 160
            }

        case .pulse:
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                isAnimating = true
            }
            // Reset after animation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                    isAnimating = false
                }
            }

        case .tilt:
            let randomTilt = CGFloat.random(in: -10...10)
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                tiltAngle = randomTilt
            }
            // Reset after animation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                    tiltAngle = 0
                }
            }

        case .morphCorners:
            let randomCornerRadius = CGFloat.random(in: 8...16)
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                cornerRadius = randomCornerRadius
            }
            // Reset after animation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                    cornerRadius = 12
                }
            }
        }
    }

    public var body: some View {
        Form {
            // App Information Section
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    // App Icon and Name
                    HStack(spacing: 16) {
                        ZStack {
                            Image("loadingIcon")
                                .resizable()
                                .frame(width: 60, height: 60)
                                .cornerRadius(
                                    animationConfig.enableMorphingCorners ? cornerRadius : 12
                                )
                                .scaleEffect(animationConfig.enablePulse && isAnimating ? 1.1 : 1.0)
                                .rotationEffect(.degrees(rotationAngle))
                                .rotation3DEffect(
                                    .degrees(animationConfig.enable3DTilt ? Double(tiltAngle) : 0),
                                    axis: (x: 0.5, y: 1.0, z: 0.0)
                                )

                            if animationConfig.enableShine {
                                createShineEffect()
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Octomiser")
                                .font(.system(.title2, design: .rounded, weight: .bold))
                            Text(
                                "Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")"
                            )
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 8)

                    // Copyright
                    Text("© Eugnel 2025")
                        .font(.system(.footnote, design: .rounded))
                        .foregroundColor(.secondary)
                }
                .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
                .listRowBackground(Color.clear)
            }

            // Support Section
            Section {
                // Email Support
                Button(action: {
                    openURL(URL(string: "mailto:octomiser@eugnel.com")!)
                }) {
                    HStack {
                        Label {
                            Text("Contact Support")
                                .foregroundColor(Theme.mainTextColor)
                        } icon: {
                            Image(systemName: "envelope.fill")
                                .foregroundColor(.blue)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(.footnote))
                            .foregroundColor(.secondary)
                    }
                }
                .listRowBackground(Theme.secondaryBackground)

                // Support Development
                Button(action: {
                    openURL(URL(string: "https://octomiser.com/support")!)
                }) {
                    HStack {
                        Label {
                            Text("Support Development")
                                .foregroundColor(Theme.mainTextColor)
                        } icon: {
                            Image(systemName: "heart.fill")
                                .foregroundColor(.pink)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(.footnote))
                            .foregroundColor(.secondary)
                    }
                }
                .listRowBackground(Theme.secondaryBackground)
            }

            // Legal Section
            Section {
                // Privacy Policy
                Button(action: { showingGDPR = true }) {
                    HStack {
                        Label {
                            Text("Privacy Policy")
                                .foregroundColor(Theme.mainTextColor)
                        } icon: {
                            Image(systemName: "hand.raised.fill")
                                .foregroundColor(.blue)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(.footnote))
                            .foregroundColor(.secondary)
                    }
                }
                .listRowBackground(Theme.secondaryBackground)

                // Terms of Use
                Button(action: { showingTerms = true }) {
                    HStack {
                        Label {
                            Text("Terms of Use")
                                .foregroundColor(Theme.mainTextColor)
                        } icon: {
                            Image(systemName: "doc.text.fill")
                                .foregroundColor(.blue)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(.footnote))
                            .foregroundColor(.secondary)
                    }
                }
                .listRowBackground(Theme.secondaryBackground)
            }

            // Data Management Section
            Section {
                HStack(spacing: 16) {
                    Button(action: { showingClearDataAlert = true }) {
                        Text("Clear Data")
                            .font(.system(.body, design: .rounded, weight: .medium))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color("IconColor"))
                            )
                            .contentShape(Rectangle())
                    }

                    Button(action: { showingResetAllAlert = true }) {
                        Text("Reset All")
                            .font(.system(.body, design: .rounded, weight: .medium))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.red)
                            )
                            .contentShape(Rectangle())
                    }
                }
                .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
                .listRowBackground(Color.clear)
            } header: {
                HStack {
                    Text("Data Management")
                        .textCase(.none)
                    Spacer()
                    InfoButton(
                        message: LocalizedStringKey(
                            "⚠️ WARNING ⚠️\n\n'Clear Data' will remove all stored data except product list and settings.\n\n'Reset All' will remove ALL data including settings and product list.\n\nThese actions cannot be undone."
                        ),
                        title: LocalizedStringKey("Data Management"),
                        mediaItems: []
                    )
                }
            }

            // Social Media Icons Section
            Section {
                HStack(spacing: 60) {
                    // Website
                    Button(action: {
                        openURL(URL(string: "https://octomiser.eugnel.com")!)
                    }) {
                        Image(systemName: "safari")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 32, height: 32)
                            .foregroundStyle(.white)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    // X/Twitter
                    Button(action: {
                        openURL(URL(string: "https://twitter.com/octomiser")!)
                    }) {
                        Image("x.logo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    // Instagram
                    Button(action: {
                        openURL(URL(string: "https://instagram.com/octomiser")!)
                    }) {
                        Image("ig.logo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.mainBackground)
        .navigationTitle("More Info")
        .sheet(isPresented: $showingGDPR) {
            NavigationView {
                PrivacyPolicyView()
            }
        }
        .sheet(isPresented: $showingTerms) {
            NavigationView {
                TermsAndConditionsView()
            }
        }
        .confirmationDialog(
            "Clear Data",
            isPresented: $showingClearDataAlert,
            titleVisibility: .visible
        ) {
            Button("Clear All Data", role: .destructive) {
                Task {
                    await clearData()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This will delete:\n• Consumption History\n• Tariff Calculations\n• Rate Information\n\nProduct List and Settings will be preserved.\nThis action cannot be undone."
            )
        }
        .confirmationDialog(
            "Reset All",
            isPresented: $showingResetAllAlert,
            titleVisibility: .visible
        ) {
            Button("Reset Everything", role: .destructive) {
                Task {
                    await resetAll()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This will delete ALL data including:\n• All Settings\n• API Configuration\n• Product Information\n• Consumption History\n• Tariff Calculations\n• Rate Information\n\nThe app will return to its initial state.\nThis action cannot be undone."
            )
        }
        .alert(
            "Error",
            isPresented: .init(
                get: { operationError != nil },
                set: { if !$0 { operationError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                operationError = nil
            }
        } message: {
            if let error = operationError {
                Text(error)
            }
        }
        .overlay {
            if isProcessing {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .tint(.white)
                    .scaleEffect(1.5)
            }
        }
        .onAppear {
            startRandomAnimation()
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    private func clearData() async {
        isProcessing = true
        operationError = nil

        do {
            // Entities to clear (excluding ProductEntity)
            let entitiesToDelete = [
                "TariffCalculationEntity",
                "EConsumAgile",
                "StandingChargeEntity",
                "RateEntity",
                "ProductDetailEntity",
            ]

            for entityName in entitiesToDelete {
                let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
                let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
                try await viewContext.perform {
                    try viewContext.execute(deleteRequest)
                }
            }

            // Save context after deletions
            try await viewContext.perform {
                try viewContext.save()
            }

            // Clear specific settings but keep product-related ones
            await MainActor.run {
                globalSettings.settings.accountData = nil
                globalSettings.settings.accountNumber = nil
                globalSettings.settings.electricityMPAN = nil
                globalSettings.settings.electricityMeterSerialNumber = nil
            }

        } catch {
            print("❌ Error clearing data: \(error)")
            await MainActor.run {
                operationError = error.localizedDescription
            }
        }

        await MainActor.run {
            isProcessing = false
        }
    }

    private func resetAll() async {
        isProcessing = true
        operationError = nil

        do {
            // Get all entity names from the model
            let entityNames =
                viewContext.persistentStoreCoordinator?.managedObjectModel.entities
                .compactMap { $0.name } ?? []

            // Delete all entities
            for entityName in entityNames {
                let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
                let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
                try await viewContext.perform {
                    try viewContext.execute(deleteRequest)
                }
            }

            // Save context after deletions
            try await viewContext.perform {
                try viewContext.save()
            }

            // Reset all settings to default
            await MainActor.run {
                globalSettings.resetToDefaults()
            }

        } catch {
            print("❌ Error resetting all data: \(error)")
            await MainActor.run {
                operationError = error.localizedDescription
            }
        }

        await MainActor.run {
            isProcessing = false
        }
    }
}
