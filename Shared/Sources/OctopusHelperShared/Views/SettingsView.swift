import Foundation
import SwiftUI

// MARK: - Bundle Access
extension Bundle {
    fileprivate static var moduleBundle: Bundle? {
        // First, try to get the bundle by identifier
        if let bundle = Bundle(identifier: "com.jamesto.OctopusHelperShared") {
            return bundle
        }
        
        // If that fails, try to get the bundle by module name
        let bundleName = "OctopusHelperShared_OctopusHelperShared"
        let candidates = [
            // Bundle should be present here when the package is linked into an App
            Bundle.main.resourceURL,
            // Bundle should be present here when the package is linked into a framework
            Bundle(for: BundleToken.self).resourceURL,
            // For command-line tools
            Bundle.main.bundleURL,
        ]

        for candidate in candidates {
            let bundlePath = candidate?.appendingPathComponent(bundleName + ".bundle")
            if let bundle = bundlePath.flatMap(Bundle.init(url:)) {
                return bundle
            }
        }
        
        return Bundle.module
    }
}

private final class BundleToken {}

// MARK: - GDPR Data Model
private struct GDPRData: Codable {
    let title: String
    let sections: [GDPRSection]
    let `tldr`: String
    let introduction: String
}

private struct GDPRSection: Codable {
    let heading: String
    let body: [String]
}

// MARK: - GDPR Declaration ViewModel
private class GDPRViewModel: ObservableObject {
    @Published var gdprData: GDPRData?

    init() {
        loadGDPRJSON()
    }

    private func loadGDPRJSON() {
        guard let bundle = Bundle.moduleBundle,
            let url = bundle.url(forResource: "GDPR", withExtension: "json")
        else {
            print("GDPR.json not found in bundle.")
            return
        }
        
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(GDPRData.self, from: data)
            self.gdprData = decoded
        } catch {
            print("Error loading GDPR.json: \(error)")
            print("Detailed error: \(error.localizedDescription)")
        }
    }
}

// MARK: - GDPRDeclarationView
struct GDPRDeclarationView: View {
    @StateObject private var viewModel = GDPRViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let gdprData = viewModel.gdprData {
                // TL;DR section
                Text(LocalizedStringKey("TL;DR"))
                    .font(Theme.secondaryFont().bold())
                    .foregroundColor(Theme.mainTextColor)
                Text(LocalizedStringKey(gdprData.tldr))
                    .font(Theme.subFont())
                    .foregroundColor(Theme.secondaryTextColor)
                
                Divider()
                    .padding(.vertical, 8)
                
                // Introduction text
                Text(LocalizedStringKey(gdprData.introduction))
                    .font(Theme.secondaryFont())
                    .foregroundColor(Theme.mainTextColor)

                // Dynamically list each section
                ForEach(Array(gdprData.sections.enumerated()), id: \.offset) { index, section in
                    Text(LocalizedStringKey(section.heading))
                        .font(Theme.secondaryFont().bold())
                        .foregroundColor(Theme.mainTextColor)
                    
                    // Body text
                    ForEach(section.body, id: \.self) { bullet in
                        Text(LocalizedStringKey("• \(bullet)"))
                            .font(Theme.subFont())
                            .foregroundColor(Theme.secondaryTextColor)
                    }
                }
            } else {
                // If JSON failed to load or parse
                Text(LocalizedStringKey("Unable to load GDPR text."))
                    .font(Theme.secondaryFont())
                    .foregroundColor(.red)
            }
        }
    }
}

private struct SupplyPointsResponse: Codable {
    let count: Int
    let results: [SupplyPoint]
}

private struct SupplyPoint: Codable {
    let group_id: String
}

// MARK: - Guide Data Model
private struct GuideData: Codable {
    let title: String
    let tldr: String
    let heading: String
    let steps: [String]
}

// MARK: - Guide ViewModel
private class GuideViewModel: ObservableObject {
    @Published var guideData: GuideData?

    init() {
        loadGuideJSON()
    }

    private func loadGuideJSON() {
        guard let bundle = Bundle.moduleBundle,
            let url = bundle.url(forResource: "Guide", withExtension: "json")
        else {
            print("Guide.json not found in bundle.")
            return
        }
        
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(GuideData.self, from: data)
            self.guideData = decoded
        } catch {
            print("Error loading Guide.json: \(error)")
            print("Detailed error: \(error.localizedDescription)")
        }
    }
}

// MARK: - GuideView
struct GuideView: View {
    @StateObject private var viewModel = GuideViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let guideData = viewModel.guideData {
                // TL;DR section
                Text(LocalizedStringKey("TL;DR"))
                    .font(Theme.secondaryFont().bold())
                    .foregroundColor(Theme.mainTextColor)
                Text(LocalizedStringKey(guideData.tldr))
                    .font(Theme.subFont())
                    .foregroundColor(Theme.secondaryTextColor)
                
                Divider()
                    .padding(.vertical, 8)
                
                // Main content
                Text(LocalizedStringKey(guideData.heading))
                    .font(Theme.secondaryFont())
                    .foregroundColor(Theme.mainTextColor)
                
                ForEach(Array(guideData.steps.enumerated()), id: \.offset) { index, step in
                    Text(LocalizedStringKey("\(index + 1). \(step)"))
                        .font(Theme.subFont())
                        .foregroundColor(Theme.secondaryTextColor)
                }
            } else {
                Text(LocalizedStringKey("Unable to load guide text."))
                    .font(Theme.secondaryFont())
                    .foregroundColor(.red)
            }
        }
    }
}

private struct DetailRow: View {
    let title: String
    let value: String

    init(title: String, value: String) {
        self.title = title
        self.value = value
    }

    // Convenience initializer for dates
    init(title: String, date: String?) {
        self.title = title
        if let dateStr = date,
            let date = ISO8601DateFormatter().date(from: dateStr)
        {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none  // Remove time component
            self.value = formatter.string(from: date)
        } else {
            self.value = "Not specified"
        }
    }

    var body: some View {
        HStack {
            Text(LocalizedStringKey(title))
                .font(Theme.secondaryFont())
                .foregroundColor(Theme.secondaryTextColor)
            Spacer()
            Text(value)
                .font(Theme.secondaryFont())
                .foregroundColor(Theme.mainTextColor)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct APIConfigurationView: View {
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @Environment(\.dismiss) var dismiss
    @State private var showGDPRConsent = false
    @State private var gdprAccepted = false
    @State private var showDeleteAPIKeyWarning = false
    @State private var isFetchingAccount = false
    @State private var fetchError: String?
    @State private var accountNumberInput: String = ""
    @State private var hasAccountData: Bool = false
    @State private var accountNumberFieldError: String?
    @State private var apiKeyFieldError: String?

    private func validateInputs() -> Bool {
        var isValid = true

        withAnimation(.smooth) {
            // Validate API Key
            if globalSettings.settings.apiKey.isEmpty {
                apiKeyFieldError = "API Key is required"
                isValid = false
            } else if !globalSettings.settings.apiKey.hasPrefix("sk_live_") {
                apiKeyFieldError = "API Key should start with 'sk_live_'"
                isValid = false
            } else {
                apiKeyFieldError = nil
            }

            // Validate Account Number
            if accountNumberInput.isEmpty {
                accountNumberFieldError = "Account Number is required"
                isValid = false
            } else if !accountNumberInput.hasPrefix("A-") {
                accountNumberFieldError = "Account Number should start with 'A-'"
                isValid = false
            } else {
                accountNumberFieldError = nil
            }
        }

        return isValid
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 0) {
                    // Only show input fields if we don't have account data
                    if !hasAccountData {
                        withAnimation(.smooth) {
                            VStack(alignment: .leading, spacing: 0) {
                                // API Key Section
                    Text(LocalizedStringKey("API Key"))
                        .font(Theme.subFont())
                        .foregroundColor(Theme.secondaryTextColor)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                    
                    HStack {
                        SecureField(
                            LocalizedStringKey("API Key"),
                            text: $globalSettings.settings.apiKey,
                            prompt: Text(LocalizedStringKey("sk_live_..."))
                                .foregroundColor(Theme.secondaryTextColor)
                        )
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 16)
                        .font(Theme.secondaryFont())
                        .foregroundColor(Theme.mainTextColor)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .onChange(of: globalSettings.settings.apiKey) { _, _ in
                                        withAnimation(.smooth) {
                                            apiKeyFieldError = nil
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical)
                    .background(
                        Theme.secondaryBackground
                            .padding(.horizontal, 20)
                    )
                                .overlay(alignment: .trailing) {
                                    if let error = apiKeyFieldError {
                                        Label(error, systemImage: "exclamationmark.circle.fill")
                                            .foregroundColor(.red)
                                            .font(Theme.subFont())
                                            .padding(.trailing, 36)
                                            .transition(
                                                .move(edge: .trailing).combined(with: .opacity))
                                    }
                                }

                                // Account Number Section
                        Text(LocalizedStringKey("Account Number"))
                            .font(Theme.subFont())
                            .foregroundColor(Theme.secondaryTextColor)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 8)
                                    .padding(.top, 16)
                        
                            HStack {
                                TextField(
                                    LocalizedStringKey("Account Number"),
                                    text: $accountNumberInput,
                                    prompt: Text(LocalizedStringKey("A-XXXXX"))
                                        .foregroundColor(Theme.secondaryTextColor)
                                )
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 16)
                                .font(Theme.secondaryFont())
                                .foregroundColor(Theme.mainTextColor)
                                .disabled(isFetchingAccount)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .onChange(of: accountNumberInput) { _, newValue in
                                        withAnimation(.smooth) {
                                            accountNumberFieldError = nil
                                            fetchError = nil
                                        }
                                    }
                                
                                if isFetchingAccount {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle())
                                            .transition(.scale.combined(with: .opacity))
                                } else {
                                    Button(action: {
                                            if validateInputs() {
                                        Task {
                                            await confirmAccountNumber()
                                                }
                                        }
                                    }) {
                                        Image(systemName: "arrow.right.circle.fill")
                                            .foregroundColor(Theme.mainColor)
                                    }
                                        .disabled(
                                            accountNumberInput.isEmpty
                                                || globalSettings.settings.apiKey.isEmpty
                                        )
                                        .transition(.scale.combined(with: .opacity))
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical)
                            .background(
                                Theme.secondaryBackground
                                    .padding(.horizontal, 20)
                            )
                                .overlay(alignment: .trailing) {
                                    if let error = accountNumberFieldError {
                                        Label(error, systemImage: "exclamationmark.circle.fill")
                                    .foregroundColor(.red)
                                            .font(Theme.subFont())
                                            .padding(.trailing, 36)
                                            .transition(
                                                .move(edge: .trailing).combined(with: .opacity))
                                    }
                                }

                                if let error = fetchError {
                                    errorView(error)
                                }

                                // Links Section
                                VStack(spacing: 0) {
                                    Link(
                                        destination: URL(
                                            string:
                                                "https://octopus.energy/dashboard/new/accounts/personal-details/api-access"
                                        )!
                                    ) {
                                        HStack(spacing: 4) {
                                            Text(LocalizedStringKey("Get API Key (Login Required)"))
                                                .font(Theme.secondaryFont())
                                                .foregroundColor(Theme.mainColor)
                                                .textCase(.none)
                                                .multilineTextAlignment(.leading)

                                            Spacer()

                                            Image(systemName: "arrow.up.right")
                            .font(Theme.subFont())
                                                .foregroundColor(Theme.mainColor)
                                        }
                            .padding(.horizontal, 20)
                                        .padding(.vertical, 12)
                                    }
                                    .background(Theme.mainBackground)

                                    Link(
                                        destination: URL(
                                            string: "https://octopus.energy/dashboard/new/accounts")!
                                    ) {
                                        HStack(spacing: 4) {
                                            Text(
                                                LocalizedStringKey(
                                                    "Get Account Number (Login Required)")
                                            )
                                .font(Theme.secondaryFont())
                                            .foregroundColor(Theme.mainColor)
                                            .textCase(.none)
                                            .multilineTextAlignment(.leading)

                                            Spacer()

                                            Image(systemName: "arrow.up.right")
                                                .font(Theme.subFont())
                                                .foregroundColor(Theme.mainColor)
                                        }
                                        .padding(.horizontal, 20)
                                        .padding(.vertical, 12)
                                        .padding(.bottom, 30)
                                    }
                                    .background(Theme.mainBackground)
                            }
                            .padding(.horizontal, 20)
                                .padding(.top, 16)
                            }
                        }
                    }

                    // Display Account Information if available
                    if hasAccountData && !isFetchingAccount,
                        let accountData = globalSettings.settings.accountData,
                        let account = try? JSONDecoder().decode(
                            OctopusAccountResponse.self,
                            from: accountData
                        )
                    {
                        withAnimation(.smooth) {
                            VStack(alignment: .leading, spacing: 16) {
                                // Account Number
                                DetailRow(title: "Account Number", value: account.number)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 8)
                                    .background(Theme.secondaryBackground)

                                // Properties
                                ForEach(
                                    Array(account.properties.enumerated()), id: \.offset
                                ) { index, property in
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(LocalizedStringKey("Property \(index + 1)"))
                                            .font(Theme.secondaryFont().bold())
                                            .foregroundColor(Theme.mainTextColor)
                                            .padding(.horizontal, 20)

                                        // Electricity Meter Points
                                        if let electricityPoints = property
                                            .electricity_meter_points
                                        {
                                            ForEach(
                                                Array(electricityPoints.enumerated()),
                                                id: \.offset
                                            ) { mpIndex, point in
                                                VStack(alignment: .leading, spacing: 4) {
                                                    Text(
                                                        LocalizedStringKey(
                                                            "Electricity Supply")
                                                    )
                                                    .font(Theme.secondaryFont().bold())
                                                    .foregroundColor(Theme.mainTextColor)
                                                    .padding(.horizontal, 20)
                                                    .padding(.vertical, 8)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                                    .background(Theme.mainColor.opacity(0))

                                                    DetailRow(
                                                        title: "MPAN", value: point.mpan
                                                    )
                                .padding(.horizontal, 20)
                                                    .padding(.vertical, 4)

                                                    if let meters = point.meters {
                                                        ForEach(
                                                            Array(meters.enumerated()),
                                                            id: \.offset
                                                        ) { meterIndex, meter in
                                                            DetailRow(
                                                                title: "Meter Serial",
                                                                value: meter.serial_number
                                                            )
                                                            .padding(.horizontal, 20)
                                                            .padding(.vertical, 4)
                                                        }
                                                    }

                                                    if let agreements = point.agreements {
                                                        Text(
                                                            LocalizedStringKey("Agreements")
                                                        )
                                                        .font(Theme.subFont())
                                                        .foregroundColor(
                                                            Theme.secondaryTextColor
                                                        )
                                                        .padding(.horizontal, 20)
                                                        .padding(.top, 4)

                                                        let sortedAgreements = agreements.sorted {
                                                            a1, a2 in
                                                            // Convert dates for comparison
                                                            let date1 =
                                                                ISO8601DateFormatter().date(
                                                                    from: a1.valid_from ?? "")
                                                                ?? .distantPast
                                                            let date2 =
                                                                ISO8601DateFormatter().date(
                                                                    from: a2.valid_from ?? "")
                                                                ?? .distantPast
                                                            return date1 > date2  // Newer dates first
                                                        }

                                                        ForEach(
                                                            Array(sortedAgreements.enumerated()),
                                                            id: \.offset
                                                        ) { agIndex, agreement in
                                                            let isExpired =
                                                                agreement.valid_to.flatMap {
                                                                    validTo in
                                                                    ISO8601DateFormatter().date(
                                                                        from: validTo)
                                                                }.map { $0 < Date() } ?? false

                                                            VStack(alignment: .leading, spacing: 4)
                                                            {
                            HStack {
                                                                    DetailRow(
                                                                        title: "Tariff",
                                                                        value: agreement.tariff_code
                                                                    )

                                                                    Spacer()

                                                                    // Status indicator
                                                                    if isExpired {
                                                                        Text("Expired")
                                                                            .font(Theme.subFont())
                                                                            .foregroundColor(
                                                                                .red.opacity(0.8)
                                                                            )
                                                                            .padding(.horizontal, 8)
                                                                            .padding(.vertical, 4)
                                                                            .background(
                                                                                Capsule()
                                                                                    .fill(
                                                                                        .red
                                                                                            .opacity(
                                                                                                0.1)
                                                                                    )
                                                                            )
                                                                    } else {
                                                                        Text("Active")
                                                                            .font(Theme.subFont())
                                                                            .foregroundColor(.green)
                                                                            .padding(.horizontal, 8)
                                                                            .padding(.vertical, 4)
                                                                            .background(
                                                                                Capsule()
                                                                                    .fill(
                                                                                        .green
                                                                                            .opacity(
                                                                                                0.1)
                                                                                    )
                                                                            )
                                                                    }
                                                                }
                                                                .padding(.horizontal, 20)
                                                                .padding(.vertical, 4)

                                                                if let validFrom = agreement
                                                                    .valid_from
                                                                {
                                                                    DetailRow(
                                                                        title: "Valid From",
                                                                        date: validFrom
                                                                    )
                                                                    .padding(.horizontal, 20)
                                                                    .padding(.vertical, 4)
                                                                    .foregroundColor(
                                                                        isExpired
                                                                            ? Theme
                                                                                .secondaryTextColor
                                                                                .opacity(0.6) : nil)
                                                                }

                                                                if let validTo = agreement.valid_to
                                                                {
                                                                    DetailRow(
                                                                        title: "Valid To",
                                                                        date: validTo
                                                                    )
                            .padding(.horizontal, 20)
                                                                    .padding(.vertical, 4)
                                                                    .foregroundColor(
                                                                        isExpired
                                                                            ? Theme
                                                                                .secondaryTextColor
                                                                                .opacity(0.6) : nil)
                                                                }
                                                            }
                                                            .padding(.vertical, 8)
                            .background(
                                Theme.secondaryBackground
                                                                    .opacity(isExpired ? 0.5 : 1)
                                                            )
                                                            .clipShape(
                                                                RoundedRectangle(cornerRadius: 8))

                                                            // Add a divider between agreements, except for the last one
                                                            if agIndex < sortedAgreements.count - 1
                                                            {
                                                                Divider()
                                    .padding(.horizontal, 20)
                                                                    .padding(.vertical, 8)
                                                                    .opacity(0.3)
                                                            }
                                                        }
                                                    }
                                                }
                                                .padding(.vertical, 8)
                                                .background(Theme.secondaryBackground)
                                                .clipShape(
                                                    RoundedRectangle(cornerRadius: 10))
                                            }
                                        }

                                        // Gas Meter Points
                                        if let gasPoints = property.gas_meter_points {
                                            ForEach(
                                                Array(gasPoints.enumerated()), id: \.offset
                                            ) { mpIndex, point in
                                                VStack(alignment: .leading, spacing: 4) {
                                                    Text(LocalizedStringKey("Gas Supply"))
                                                        .font(Theme.secondaryFont().bold())
                                                        .foregroundColor(Theme.mainTextColor)
                                                        .padding(.horizontal, 20)
                                                        .padding(.vertical, 8)
                                                        .frame(
                                                            maxWidth: .infinity, alignment: .leading
                                                        )
                                                        .background(Theme.mainColor.opacity(0))

                                                    DetailRow(
                                                        title: "MPRN", value: point.mprn
                                                    )
                                                    .padding(.horizontal, 20)
                                                    .padding(.vertical, 4)

                                                    if let meters = point.meters {
                                                        ForEach(
                                                            Array(meters.enumerated()),
                                                            id: \.offset
                                                        ) { meterIndex, meter in
                                                            DetailRow(
                                                                title: "Meter Serial",
                                                                value: meter.serial_number
                                                            )
                                                            .padding(.horizontal, 20)
                                                            .padding(.vertical, 4)
                                                        }
                                                    }

                                                    if let agreements = point.agreements {
                                                        Text(
                                                            LocalizedStringKey("Agreements")
                                                        )
                                                        .font(Theme.subFont())
                                                        .foregroundColor(
                                                            Theme.secondaryTextColor
                                                        )
                                                        .padding(.horizontal, 20)
                                                        .padding(.top, 4)

                                                        let sortedAgreements = agreements.sorted {
                                                            a1, a2 in
                                                            // Convert dates for comparison
                                                            let date1 =
                                                                ISO8601DateFormatter().date(
                                                                    from: a1.valid_from ?? "")
                                                                ?? .distantPast
                                                            let date2 =
                                                                ISO8601DateFormatter().date(
                                                                    from: a2.valid_from ?? "")
                                                                ?? .distantPast
                                                            return date1 > date2  // Newer dates first
                                                        }

                                                        ForEach(
                                                            Array(sortedAgreements.enumerated()),
                                                            id: \.offset
                                                        ) { agIndex, agreement in
                                                            let isExpired =
                                                                agreement.valid_to.flatMap {
                                                                    validTo in
                                                                    ISO8601DateFormatter().date(
                                                                        from: validTo)
                                                                }.map { $0 < Date() } ?? false

                                                            VStack(alignment: .leading, spacing: 4)
                                                            {
                                                                HStack {
                                                                    DetailRow(
                                                                        title: "Tariff",
                                                                        value: agreement.tariff_code
                                                                    )
                                    
                                    Spacer()
                                    
                                                                    // Status indicator
                                                                    if isExpired {
                                                                        Text("Expired")
                                        .font(Theme.subFont())
                                                                            .foregroundColor(
                                                                                .red.opacity(0.8)
                                                                            )
                                                                            .padding(.horizontal, 8)
                                                                            .padding(.vertical, 4)
                                                                            .background(
                                                                                Capsule()
                                                                                    .fill(
                                                                                        .red
                                                                                            .opacity(
                                                                                                0.1)
                                                                                    )
                                                                            )
                                                                    } else {
                                                                        Text("Active")
                                                                            .font(Theme.subFont())
                                                                            .foregroundColor(.green)
                                                                            .padding(.horizontal, 8)
                                                                            .padding(.vertical, 4)
                                                                            .background(
                                                                                Capsule()
                                                                                    .fill(
                                                                                        .green
                                                                                            .opacity(
                                                                                                0.1)
                                                                                    )
                                                                            )
                                                                    }
                                }
                                .padding(.horizontal, 20)
                                                                .padding(.vertical, 4)

                                                                if let validFrom = agreement
                                                                    .valid_from
                                                                {
                                                                    DetailRow(
                                                                        title: "Valid From",
                                                                        date: validFrom
                                                                    )
                                                                    .padding(.horizontal, 20)
                                                                    .padding(.vertical, 4)
                                                                    .foregroundColor(
                                                                        isExpired
                                                                            ? Theme
                                                                                .secondaryTextColor
                                                                                .opacity(0.6) : nil)
                                                                }

                                                                if let validTo = agreement.valid_to
                                                                {
                                                                    DetailRow(
                                                                        title: "Valid To",
                                                                        date: validTo
                                                                    )
                            .padding(.horizontal, 20)
                                                                    .padding(.vertical, 4)
                                                                    .foregroundColor(
                                                                        isExpired
                                                                            ? Theme
                                                                                .secondaryTextColor
                                                                                .opacity(0.6) : nil)
                                                                }
                                                            }
                                                            .padding(.vertical, 8)
                                                            .background(
                                                                Theme.secondaryBackground
                                                                    .opacity(isExpired ? 0.5 : 1)
                                                            )
                                                            .clipShape(
                                                                RoundedRectangle(cornerRadius: 8))

                                                            // Add a divider between agreements, except for the last one
                                                            if agIndex < sortedAgreements.count - 1
                                                            {
                                                                Divider()
                                                                    .padding(.horizontal, 20)
                                                                    .padding(.vertical, 8)
                                                                    .opacity(0.3)
                                                            }
                                                        }
                                                    }
                                                }
                                                .padding(.vertical, 8)
                                                .background(Theme.secondaryBackground)
                                                .clipShape(
                                                    RoundedRectangle(cornerRadius: 10))
                                            }
                                        }
                                    }
                                    .padding(.vertical, 8)
                                }
                                .padding(.top, 16)
                                .padding(.bottom, 10)
                            }
                        }
                    }

                    // Remove Account Access button
                    if !globalSettings.settings.apiKey.isEmpty || !accountNumberInput.isEmpty {
                        Button(action: {
                            showDeleteAPIKeyWarning = true
                        }) {
                            Text(LocalizedStringKey("Remove Account Access"))
                                .font(Theme.secondaryFont())
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color("IconColor"))
                                )
                                .contentShape(Rectangle())
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                        .padding(.bottom, 30)
                    }
                    
                    VStack(alignment: .leading, spacing: 0) {
                        Text(LocalizedStringKey("Guide"))
                            .font(Theme.subFont())
                            .foregroundColor(Theme.secondaryTextColor)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 8)
                        
                        GuideView()
                            .padding()
                            .background(Theme.secondaryBackground)
                    }
                    .padding(.bottom, 30)
                    
                    VStack(alignment: .leading, spacing: 0) {
                        Text(LocalizedStringKey("GDPR (UK) and Data Usage Declaration"))
                            .font(Theme.subFont())
                            .foregroundColor(Theme.secondaryTextColor)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 8)
                        
                        GDPRDeclarationView()
                            .padding()
                            .background(Theme.secondaryBackground)
                    }
                }
                .padding(.vertical)
            }
            .padding(.vertical)
        }
        .background(Theme.mainBackground)
        .navigationTitle(LocalizedStringKey("API Configuration"))
        .onAppear {
            // Restore account number from settings when view appears
            accountNumberInput = globalSettings.settings.accountNumber ?? ""
            hasAccountData = globalSettings.settings.accountData != nil
        }
        .onChange(of: globalSettings.settings.accountData) { _, newValue in
            hasAccountData = newValue != nil
        }
        .alert(
            LocalizedStringKey("Delete Account Information?"), isPresented: $showDeleteAPIKeyWarning
        ) {
            Button(LocalizedStringKey("Cancel"), role: .cancel) {}
            Button(LocalizedStringKey("Delete"), role: .destructive) {
                // Clear all account-related data
                withAnimation {
                    globalSettings.settings.apiKey = ""
                    globalSettings.settings.accountNumber = nil
                    accountNumberInput = ""
                    globalSettings.settings.accountData = nil
                globalSettings.settings.electricityMPAN = nil
                globalSettings.settings.electricityMeterSerialNumber = nil
                    hasAccountData = false
                }
            }
        } message: {
            Text(
                LocalizedStringKey(
                    "This will delete your:\n• API Key\n• Account Number\n• Meter Information\n• Account Data\n\nYou will need to re-enter your account information to access your energy data."
                ))
        }
    }
    
    private func confirmAccountNumber() async {
        isFetchingAccount = true
        fetchError = nil
        do {
            print("🔄 Fetching account data...")
            try await AccountRepository.shared.fetchAndStoreAccount(
                accountNumber: accountNumberInput,
                apiKey: globalSettings.settings.apiKey,
                globalSettings: globalSettings
            )

            // Wrap state updates in withAnimation
            await MainActor.run {
                print("✅ Account data fetched successfully")
                withAnimation(.smooth) {
                    // Update all states on success
                    globalSettings.settings.accountNumber = accountNumberInput
                    hasAccountData = globalSettings.settings.accountData != nil
                    print("📊 hasAccountData: \(hasAccountData)")
                    print("📊 accountData exists: \(globalSettings.settings.accountData != nil)")
                    isFetchingAccount = false
                    fetchError = nil
                }
            }
        } catch {
            await MainActor.run {
                print("❌ Error fetching account: \(error.localizedDescription)")
                withAnimation(.smooth) {
            fetchError = error.localizedDescription
        isFetchingAccount = false
                    hasAccountData = false
                }
            }
        }
    }

    @ViewBuilder
    private func errorView(_ error: String) -> some View {
        Text(LocalizedStringKey(error))
            .font(Theme.subFont())
            .foregroundColor(.red)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var inputFieldsView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // API Key Section
            Text(LocalizedStringKey("API Key"))
                .font(Theme.subFont())
                .foregroundColor(Theme.secondaryTextColor)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

            HStack {
                SecureField(
                    LocalizedStringKey("API Key"),
                    text: $globalSettings.settings.apiKey,
                    prompt: Text(LocalizedStringKey("sk_live_..."))
                        .foregroundColor(Theme.secondaryTextColor)
                )
                .textFieldStyle(.plain)
                .padding(.horizontal, 16)
                .font(Theme.secondaryFont())
                .foregroundColor(Theme.mainTextColor)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }
            .padding(.horizontal, 20)
            .padding(.vertical)
            .background(
                Theme.secondaryBackground
                    .padding(.horizontal, 20)
            )
            .transition(.move(edge: .top).combined(with: .opacity))

            // Account Number Section
            Text(LocalizedStringKey("Account Number"))
                .font(Theme.subFont())
                .foregroundColor(Theme.secondaryTextColor)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .padding(.top, 16)

            HStack {
                TextField(
                    LocalizedStringKey("Account Number"),
                    text: $accountNumberInput,
                    prompt: Text(LocalizedStringKey("A-XXXXX"))
                        .foregroundColor(Theme.secondaryTextColor)
                )
                .textFieldStyle(.plain)
                .padding(.horizontal, 16)
                .font(Theme.secondaryFont())
                .foregroundColor(Theme.mainTextColor)
                .disabled(isFetchingAccount)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: accountNumberInput) { _, newValue in
                    // Clear error when user starts typing
                    if !newValue.isEmpty {
                        withAnimation(.smooth) {
                            fetchError = nil
                        }
                    }
                }

                if isFetchingAccount {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Button(action: {
                        Task {
                            await confirmAccountNumber()
                        }
                    }) {
                        Image(systemName: "arrow.right.circle.fill")
                            .foregroundColor(Theme.mainColor)
                    }
                    .disabled(
                        accountNumberInput.isEmpty
                            || globalSettings.settings.apiKey.isEmpty
                    )
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical)
            .background(
                Theme.secondaryBackground
                    .padding(.horizontal, 20)
            )
            .transition(.move(edge: .top).combined(with: .opacity))

            if let error = fetchError {
                errorView(error)
            }
        }
    }
}

struct RegionLookupView: View {
    let postcode: String
    @Binding var triggerLookup: Bool
    @State private var region: String?
    @State private var isLoading = false
    @State private var error: String?
    @Binding var lookupError: String?
    
    // Cache for postcode lookup results
    @AppStorage("postcode_region_cache") private var postcodeRegionCacheData: Data = Data()
    @AppStorage("invalid_postcodes") private var invalidPostcodesData: Data = Data()
    
    private var postcodeRegionCache: [String: String] {
        get {
            (try? JSONDecoder().decode([String: String].self, from: postcodeRegionCacheData)) ?? [:]
        }
        nonmutating set {
            postcodeRegionCacheData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }
    
    private var invalidPostcodes: Set<String> {
        get {
            (try? JSONDecoder().decode(Set<String>.self, from: invalidPostcodesData)) ?? []
        }
        nonmutating set {
            invalidPostcodesData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }
    
    var body: some View {
        HStack {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                Text("Looking up region...")
                    .font(Theme.subFont())
                    .foregroundColor(Theme.secondaryTextColor)
            } else if let region = region, !isLoading && triggerLookup == false {
                Text("Using Region \(region)")
                    .font(Theme.subFont())
                    .foregroundColor(Theme.secondaryTextColor)
            } else {
                Text("Tap the search icon to lookup your region")
                    .font(Theme.subFont())
                    .foregroundColor(Theme.secondaryTextColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .customListRow()
        .onChange(of: triggerLookup) { _, newValue in
            if newValue {
                Task {
                    await lookupRegion()
                    triggerLookup = false
                }
            }
        }
        .onAppear {
            // Check cache on appear
            let cleanedPostcode = postcode.trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            if !cleanedPostcode.isEmpty {
                if let cachedRegion = postcodeRegionCache[cleanedPostcode] {
                    region = cachedRegion
                } else if invalidPostcodes.contains(cleanedPostcode) {
                    lookupError = "Invalid postcode"
                }
            }
        }
    }
    
    private func lookupRegion() async {
        guard !postcode.isEmpty else { return }
        
        let cleanedPostcode = postcode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        
        // Check cache first
        if let cachedRegion = postcodeRegionCache[cleanedPostcode] {
            region = cachedRegion
            lookupError = nil
            return
        }
        
        // Check invalid postcodes
        if invalidPostcodes.contains(cleanedPostcode) {
            lookupError = "Invalid postcode"
            region = nil
            return
        }
        
        let loadingTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if !Task.isCancelled {
                isLoading = true
            }
        }
        
        error = nil
        region = nil
        lookupError = nil
        
        do {
            let (region, isInvalid) = try await lookupPostcodeRegion(postcode: cleanedPostcode)
            if isInvalid {
                lookupError = "Invalid postcode"
                self.region = nil
                var newInvalidPostcodes = invalidPostcodes
                newInvalidPostcodes.insert(cleanedPostcode)
                invalidPostcodes = newInvalidPostcodes
            } else if let region = region {
                self.region = region
                lookupError = nil
                var newCache = postcodeRegionCache
                newCache[cleanedPostcode] = region
                postcodeRegionCache = newCache
            }
        } catch {
            lookupError = error.localizedDescription
            self.region = nil
        }
        
        loadingTask.cancel()
        isLoading = false
    }
    
    private func lookupPostcodeRegion(postcode: String) async throws -> (String?, Bool) {
        let cleanedPostcode = postcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedPostcode.isEmpty else { return ("H", false) }
        
        // If it's a single letter between A and P, it's a valid region code
        if cleanedPostcode.count == 1,
           let firstChar = cleanedPostcode.first,
           firstChar >= "A" && firstChar <= "P" {
            return (cleanedPostcode, false)
        }
        
        let encoded = cleanedPostcode.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        guard let encodedPostcode = encoded,
            let url = URL(
                string:
                    "https://api.octopus.energy/v1/industry/grid-supply-points/?postcode=\(encodedPostcode)"
            )
        else { return ("H", false) }
        
        let urlSession = URLSession.shared
        let (data, response) = try await urlSession.data(for: URLRequest(url: url))
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode)
        else {
            return ("H", false)
        }
        
        let supplyPoints = try JSONDecoder().decode(SupplyPointsResponse.self, from: data)
        if supplyPoints.count == 0 {
            return (nil, true)  // Indicates invalid postcode
        }
        if let first = supplyPoints.results.first {
            let region = first.group_id.replacingOccurrences(of: "_", with: "")
            return (region, false)
        }
        return ("H", false)
    }
}

struct CustomListRowModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listRowBackground(Theme.secondaryBackground)
    }
}

extension View {
    func customListRow() -> some View {
        modifier(CustomListRowModifier())
    }
}

public struct SettingsView: View {
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @State private var lookupRegionManually = false
    @State private var lookupError: String?
    let didFinishEditing: (() -> Void)?

    public init(didFinishEditing: (() -> Void)? = nil) {
        self.didFinishEditing = didFinishEditing
    }

    public var body: some View {
        Form {
            Section(
                header: HStack {
                    Text("Cards")
                        .font(Theme.subFont())
                        .foregroundColor(Theme.secondaryTextColor)
                        .textCase(.none)
                    Spacer()
                    InfoButton(
                        message: LocalizedStringKey(
                            "Customise your dashboard by managing your cards:\n\n• Enable/disable cards to show only what matters to you\n• Reorder cards to arrange your perfect layout\n• Each card offers unique insights into your energy usage and rates\n\nStay tuned for new card modules - we're constantly developing new features to help you better understand and manage your energy usage."
                        ),
                        title: LocalizedStringKey("Cards"),
                        mediaItems: [
                            MediaItem(
                                localName: "imgCardManagementViewInfo",
                                caption: LocalizedStringKey("")
                            )
                        ]
                    )
                }
            ) {
                NavigationLink(destination: CardManagementView()) {
                    HStack {
                        Text(LocalizedStringKey("Manage Cards"))
                            .font(Theme.secondaryFont())
                            .foregroundColor(Theme.mainTextColor)
                            .textCase(.none)
                        Spacer()
                        Text(
                            LocalizedStringKey(
                                "\(globalSettings.settings.cardSettings.filter { $0.isEnabled }.count) Active"
                            )
                        )
                        .font(Theme.subFont())
                        .foregroundColor(Theme.secondaryTextColor)
                        .textCase(.none)
                    }
                }
                .customListRow()
            }

            Section(
                header: HStack {
                    Text("API Configuration")
                        .font(Theme.subFont())
                        .foregroundColor(Theme.secondaryTextColor)
                        .textCase(.none)
                    Spacer()
                    InfoButton(
                        message: LocalizedStringKey(
                            "Configure your API key and meter details to access personal consumption data and billing information."
                        ),
                        title: LocalizedStringKey("API Configuration"),
                        mediaItems: []
                    )
                }
            ) {
                NavigationLink(destination: APIConfigurationView()) {
                    HStack {
                        Text(LocalizedStringKey("Configure API Access"))
                            .font(Theme.secondaryFont())
                            .foregroundColor(Theme.mainTextColor)
                        Spacer()
                        if !globalSettings.settings.apiKey.isEmpty {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        }
                    }
                }
                .customListRow()
            }
            
            // Only show Region Lookup if we don't have account data
            if globalSettings.settings.accountData == nil {
                Section(
                    header: HStack {
                        Text(LocalizedStringKey("Region Lookup"))
                            .font(Theme.subFont())
                            .foregroundColor(Theme.secondaryTextColor)
                            .textCase(.none)
                        Spacer()
                        InfoButton(
                            message: LocalizedStringKey(
                                "Enter your postcode to determine your electricity region for accurate rates, or directly enter your region code (A-P) if you know it.\n\nExamples:\n• Postcode: SW1A 1AA or SW1A\n• Region Code: H\n\nIf empty or invalid, region 'H' (Southern England) will be used as default."
                            ),
                            title: LocalizedStringKey("Region Lookup"),
                            mediaItems: [
                                MediaItem(
                                    youtubeID: "2Gp68uXVGfo",
                                    caption: LocalizedStringKey(
                                        "Zonal pricing would make energy bills cheaper...")
                                )
                            ],
                            linkURL: URL(
                                string: "https://octopus.energy/blog/regional-pricing-explained/"),
                            linkText: LocalizedStringKey("How zonal pricing could make bills cheaper")
                        )
                    }
                ) {
                    ZStack(alignment: .trailing) {
                        let displayValue = Binding(
                            get: {
                                globalSettings.settings.regionInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            },
                            set: { newValue in
                                // Validate input: either a postcode or a single letter A-P
                                let cleaned = newValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                                if cleaned.isEmpty {
                                    globalSettings.settings.regionInput = cleaned
                                } else if cleaned.count == 1 && cleaned >= "A" && cleaned <= "P" {
                                    // Valid region code
                                    globalSettings.settings.regionInput = cleaned
                                } else if cleaned.count <= 8 {  // Max UK postcode length
                                    // Allow postcode input for lookup
                                    globalSettings.settings.regionInput = cleaned
                                }
                            }
                        )
                        
                        TextField(
                            LocalizedStringKey("Postcode or Region Code"),
                            text: displayValue,
                            prompt: Text(LocalizedStringKey("e.g., SW1A 1AA, SW1A or H"))
                                .foregroundColor(Theme.secondaryTextColor)
                        )
                        .onChange(of: globalSettings.settings.regionInput) { _, newValue in
                            print("📍 Region input changed to: \(newValue)")
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .font(Theme.secondaryFont())
                        .foregroundColor(Theme.mainTextColor)
                        .padding(.trailing, 35)
                        
                        HStack(spacing: 4) {
                            let input = globalSettings.settings.regionInput.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).uppercased()
                            if input.count > 1 {
                                Button {
                                    lookupError = nil
                                    lookupRegionManually = false
                                    DispatchQueue.main.async {
                                        lookupRegionManually = true
                                    }
                                } label: {
                                    Image(systemName: "magnifyingglass.circle.fill")
                                        .foregroundColor(Theme.secondaryColor)
                                        .font(.system(size: 20))
                                }
                                .buttonStyle(.plain)
                            }
                            if let error = lookupError {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundColor(.pink)
                                    .font(.system(size: 20))
                            }
                        }
                        .padding(.trailing, 8)
                    }
                    .customListRow()
                    
                    let input = globalSettings.settings.regionInput.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).uppercased()
                    if input.isEmpty {
                        Text("Default Region H")
                            .font(Theme.subFont())
                            .foregroundColor(Theme.secondaryTextColor)
                            .customListRow()
                    } else if input.count == 1 && input >= "A" && input <= "P" {
                        Text("Using Region \(input)")
                            .font(Theme.subFont())
                            .foregroundColor(Theme.secondaryTextColor)
                            .customListRow()
                    } else if input.count > 1 {
                        RegionLookupView(
                            postcode: input, triggerLookup: $lookupRegionManually,
                            lookupError: $lookupError)
                    }
                }
            }

            Section(
                header: HStack {
                    Text("Preferences")
                        .font(Theme.subFont())
                        .foregroundColor(Theme.secondaryTextColor)
                        .textCase(.none)
                    Spacer()
                    InfoButton(
                        message: LocalizedStringKey(
                            "Configure your preferred language and how rates are displayed. Language changes will be applied immediately across the app. Rate display changes affect how prices are shown (pence vs pounds)."
                        ),
                        title: LocalizedStringKey("Preferences"),
                        mediaItems: []
                    )
                }
            ) {
                Picker(
                    LocalizedStringKey("Language"),
                    selection: $globalSettings.settings.selectedLanguage
                ) {
                    ForEach(Language.allCases, id: \.self) { lang in
                        Text(lang.displayNameWithAutonym)
                            .font(Theme.secondaryFont())
                            .textCase(.none)
                            .foregroundColor(Theme.secondaryTextColor)
                    }
                }
                .pickerStyle(.menu)
                .accentColor(Theme.secondaryTextColor)
                .font(Theme.secondaryFont())
                .foregroundColor(Theme.mainTextColor)
                .customListRow()

                Toggle(
                    LocalizedStringKey("Display Rates in Pounds (£)"),
                    isOn: $globalSettings.settings.showRatesInPounds
                )
                .font(Theme.secondaryFont())
                .foregroundColor(Theme.mainTextColor)
                .tint(Theme.secondaryColor)
                .customListRow()
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.mainBackground)
        .environment(\.locale, globalSettings.locale)
        .navigationTitle(LocalizedStringKey("Settings"))
        .onDisappear {
            // Call the completion handler when view disappears
            didFinishEditing?()
        }
    }
}

struct InfoButton: View {
    let message: LocalizedStringKey
    let title: LocalizedStringKey
    let mediaItems: [MediaItem]
    let linkURL: URL?
    let linkText: LocalizedStringKey?

    @State private var showingInfo = false
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @State private var refreshID = UUID()
    @Environment(\.locale) private var locale

    init(
        message: LocalizedStringKey,
        title: LocalizedStringKey,
        mediaItems: [MediaItem] = [],
        linkURL: URL? = nil,
        linkText: LocalizedStringKey? = nil
    ) {
        self.message = message
        self.title = title
        self.mediaItems = mediaItems
        self.linkURL = linkURL
        self.linkText = linkText
    }

    var body: some View {
        Button(action: {
            showingInfo.toggle()
        }) {
            Image(systemName: "info.circle")
                .font(Theme.subFont())
                .foregroundColor(Theme.secondaryTextColor)
        }
        .sheet(isPresented: $showingInfo) {
            InfoSheet(
                viewModel: InfoSheetViewModel(
                    title: title,
                    message: message,
                    mediaItems: mediaItems,
                    linkURL: linkURL,
                    linkText: linkText
                )
            )
            .environmentObject(globalSettings)
            .environment(\.locale, locale)
            .presentationDragIndicator(.visible)
        }
        .onChange(of: globalSettings.locale) { _, _ in
            refreshID = UUID()
        }
    }
}