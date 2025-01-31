import CoreData
import SwiftUI

// MARK: - Animation Types
enum AnimationType: CaseIterable {
    case shine
    case pulse
    case tilt
    case morphCorners
}

// MARK: - AnimationConfig
struct AnimationConfig {
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

public struct MoreInfo: View {
    // MARK: - Environment & Context
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.openURL) private var openURL
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss

    // MARK: - Alert / Processing States
    @State private var showingClearDataAlert = false
    @State private var showingResetAllAlert = false
    @State private var isProcessing = false
    @State private var operationError: String?
    @State private var showingGDPR = false
    @State private var showingTerms = false
    @State private var showingRestartAlert = false
    @State private var pendingOperation: (() async -> Void)?  // New state for pending operation

    // MARK: - Animation States
    @State private var isAnimating = false
    @State private var rotationAngle: Double = 0
    @State private var cornerRadius: CGFloat = 12
    @State private var shineOffset: CGFloat = -100
    @State private var tiltAngle: CGFloat = 0
    @State private var timer: Timer?

    // MARK: - Animation Configuration
    private let animationConfig = AnimationConfig(
        enableShine: true,
        enablePulse: true,
        enable3DTilt: true,
        enableMorphingCorners: true
    )

    // MARK: - Init
    public init() {}

    // MARK: - Body
    public var body: some View {
        GeometryReader { proxy in
            Form {
                // 1. App Information
                AppInfoSectionView(
                    animationConfig: animationConfig,
                    isAnimating: isAnimating,
                    rotationAngle: rotationAngle,
                    cornerRadius: cornerRadius,
                    tiltAngle: tiltAngle,
                    shineOffset: shineOffset
                )

                // 2. Support
                SupportSectionView(openURL: { url in
                    openURL(url)
                })

                // 3. Legal
                LegalSectionView(showingGDPR: $showingGDPR, showingTerms: $showingTerms)

                // 4. Data Management
                DataManagementSectionView(
                    showingClearDataAlert: $showingClearDataAlert,
                    showingResetAllAlert: $showingResetAllAlert
                )

                // Add Social Media Section as the last section in the Form
                Section {
                    SocialMediaSectionView(openURL: { url in
                        openURL(url)
                    })
                    .padding()
                }
            }
            .frame(minHeight: proxy.size.height)  // Ensure Form expands to fill available vertical space
            .scrollContentBackground(.hidden)
            .background(Theme.mainBackground)
            .environment(\.locale, globalSettings.locale)
            .navigationTitle(
                forcedLocalizedString(key: "More Info", locale: globalSettings.locale)
            )
            .sheet(isPresented: $showingGDPR) {
                NavigationView {
                    PrivacyPolicyView()
                        .environment(\.locale, globalSettings.locale)
                }
            }
            .sheet(isPresented: $showingTerms) {
                NavigationView {
                    TermsAndConditionsView()
                        .environment(\.locale, globalSettings.locale)
                }
            }
            // Clear Data Confirmation Dialog
            .confirmationDialog(
                Text(forcedLocalizedString(key: "Clear Data", locale: globalSettings.locale)),
                isPresented: $showingClearDataAlert,
                titleVisibility: .visible
            ) {
                Button(role: .destructive) {
                    showingRestartAlert = true
                    pendingOperation = clearData
                } label: {
                    Text(
                        forcedLocalizedString(key: "Clear All Data", locale: globalSettings.locale))
                }
                Button(role: .cancel) {
                    showingClearDataAlert = false
                } label: {
                    Text(forcedLocalizedString(key: "Cancel", locale: globalSettings.locale))
                }
            } message: {
                Text(
                    forcedLocalizedString(
                        key:
                            "This will delete:\n• Consumption History\n• Tariff Calculations\n• Rate Information\n\nProduct List and Settings will be preserved.\nThis action cannot be undone.",
                        locale: globalSettings.locale
                    )
                )
            }
            // Reset All Confirmation Dialog
            .confirmationDialog(
                Text(forcedLocalizedString(key: "Reset All", locale: globalSettings.locale)),
                isPresented: $showingResetAllAlert,
                titleVisibility: .visible
            ) {
                Button(role: .destructive) {
                    showingRestartAlert = true
                    pendingOperation = resetAll
                } label: {
                    Text(
                        forcedLocalizedString(
                            key: "Reset Everything", locale: globalSettings.locale))
                }
                Button(role: .cancel) {
                    showingResetAllAlert = false
                } label: {
                    Text(forcedLocalizedString(key: "Cancel", locale: globalSettings.locale))
                }
            } message: {
                Text(
                    forcedLocalizedString(
                        key:
                            "This will delete ALL data including:\n• All Settings\n• API Configuration\n• Product Information\n• Consumption History\n• Tariff Calculations\n• Rate Information\n\nThe app will return to its initial state.\nThis action cannot be undone.",
                        locale: globalSettings.locale
                    )
                )
            }
            .alert(
                "Final Confirmation",
                isPresented: $showingRestartAlert
            ) {
                Button("Restart Now", role: .destructive) {
                    // Execute the pending operation and restart
                    if let operation = pendingOperation {
                        Task {
                            await operation()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                    exit(0)
                                }
                            }
                        }
                    }
                }
                Button("Cancel", role: .cancel) {
                    showingRestartAlert = false
                    pendingOperation = nil
                }
            } message: {
                Text(
                    "This will permanently remove the data and force restart the app. This action cannot be undone. Do you wish to continue?"
                )
            }
            .alert(
                Text(forcedLocalizedString(key: "Error", locale: globalSettings.locale)),
                isPresented: .init(
                    get: { operationError != nil },
                    set: { if !$0 { operationError = nil } }
                )
            ) {
                Button(role: .cancel) {
                    operationError = nil
                } label: {
                    Text(forcedLocalizedString(key: "OK", locale: globalSettings.locale))
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
    }

    // MARK: - Animation Helpers
    private func startRandomAnimation() {
        timer?.invalidate()
        triggerNextAnimation()
    }

    private func triggerNextAnimation() {
        let availableTypes = AnimationType.allCases.filter { animationConfig.isEnabled($0) }
        guard !availableTypes.isEmpty else { return }

        let randomType = availableTypes.randomElement()!
        triggerAnimation(type: randomType)

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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                    cornerRadius = 12
                }
            }
        }
    }

    // MARK: - Data Operations
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

            // Show restart alert on success
            await MainActor.run {
                isProcessing = false
            }
        } catch {
            print("❌ Error clearing data: \(error)")
            await MainActor.run {
                operationError =
                    (error.localizedDescription.isEmpty || error.localizedDescription == "nilError")
                    ? "An unknown error occurred while clearing data." : error.localizedDescription
                isProcessing = false
            }
        }
    }

    private func resetAll() async {
        isProcessing = true
        operationError = nil

        do {
            let entityNames =
                viewContext.persistentStoreCoordinator?
                .managedObjectModel.entities.compactMap { $0.name } ?? []

            for entityName in entityNames {
                let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
                let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
                try await viewContext.perform {
                    try viewContext.execute(deleteRequest)
                }
            }

            try await viewContext.perform {
                try viewContext.save()
            }

            // Reset all settings to default
            await MainActor.run {
                globalSettings.resetToDefaults()
            }

            // Show restart alert on success
            await MainActor.run {
                isProcessing = false
            }
        } catch {
            print("❌ Error resetting all data: \(error)")
            await MainActor.run {
                operationError =
                    (error.localizedDescription.isEmpty || error.localizedDescription == "nilError")
                    ? "An unknown error occurred while resetting data." : error.localizedDescription
                isProcessing = false
            }
        }
    }
}

// MARK: - Subviews

// 1) App Info Section
private struct AppInfoSectionView: View {
    let animationConfig: AnimationConfig
    let isAnimating: Bool
    let rotationAngle: Double
    let cornerRadius: CGFloat
    let tiltAngle: CGFloat
    let shineOffset: CGFloat

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 16) {
                // App Icon and Name
                HStack(spacing: 16) {
                    LoadingIconView(
                        animationConfig: animationConfig,
                        isAnimating: isAnimating,
                        rotationAngle: rotationAngle,
                        cornerRadius: cornerRadius,
                        tiltAngle: tiltAngle,
                        shineOffset: shineOffset
                    )

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
    }
}

// 1a) LoadingIconView with shine effect
private struct LoadingIconView: View {
    let animationConfig: AnimationConfig
    let isAnimating: Bool
    let rotationAngle: Double
    let cornerRadius: CGFloat
    let tiltAngle: CGFloat
    let shineOffset: CGFloat

    var body: some View {
        ZStack {
            Image("loadingIcon")
                .resizable()
                .frame(width: 60, height: 60)
                .cornerRadius(animationConfig.enableMorphingCorners ? cornerRadius : 12)
                .scaleEffect(animationConfig.enablePulse && isAnimating ? 1.1 : 1.0)
                .rotationEffect(.degrees(rotationAngle))
                .rotation3DEffect(
                    .degrees(animationConfig.enable3DTilt ? Double(tiltAngle) : 0),
                    axis: (x: 0.5, y: 1.0, z: 0.0)
                )

            if animationConfig.enableShine {
                createShineEffect(offsetX: shineOffset)
            }
        }
    }

    private func createShineEffect(offsetX: CGFloat) -> some View {
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
            .offset(x: offsetX)
            .blur(radius: 5)
            .mask(Image("loadingIcon").resizable())
    }
}

// 2) Support Section
private struct SupportSectionView: View {
    let openURL: (URL) -> Void

    var body: some View {
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
    }
}

// 3) Legal Section
private struct LegalSectionView: View {
    @Binding var showingGDPR: Bool
    @Binding var showingTerms: Bool

    var body: some View {
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
    }
}

// MARK: - Data Management Button Style
private struct DataManagementButtonStyle: ViewModifier {
    let backgroundColor: Color

    func body(content: Content) -> some View {
        content
            .font(.system(.body, design: .rounded, weight: .medium))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(backgroundColor)
            )
            .contentShape(Rectangle())
    }
}

// MARK: - Data Management Section
private struct DataManagementSectionView: View {
    @Binding var showingClearDataAlert: Bool
    @Binding var showingResetAllAlert: Bool

    var body: some View {
        Section {
            HStack(spacing: 16) {
                Button(action: {
                    showingClearDataAlert = true
                }) {
                    Text("Clear Data")
                        .modifier(DataManagementButtonStyle(backgroundColor: Color("IconColor")))
                }
                .buttonStyle(PlainButtonStyle())

                Button(action: {
                    showingResetAllAlert = true
                }) {
                    Text("Reset All")
                        .modifier(DataManagementButtonStyle(backgroundColor: .red))
                }
                .buttonStyle(PlainButtonStyle())
            }
            // Ensure that only the buttons handle taps by defining the tappable area
            .contentShape(Rectangle())
            .onTapGesture { /* Prevents tap events on empty areas from triggering the row */  }
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
    }
}

// 5) Social Media Section
private struct SocialMediaSectionView: View {
    let openURL: (URL) -> Void

    var body: some View {
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
}
