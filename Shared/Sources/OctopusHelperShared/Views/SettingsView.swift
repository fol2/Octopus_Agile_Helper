import Foundation
import SwiftUI

// MARK: - Bundle Access
private extension Bundle {
    static var moduleBundle: Bundle? {
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
fileprivate struct GDPRData: Codable {
    let title: String
    let sections: [GDPRSection]
    let `tldr`: String
    let introduction: String
}

fileprivate struct GDPRSection: Codable {
    let heading: String
    let body: [String]
}

// MARK: - GDPR Declaration ViewModel
fileprivate class GDPRViewModel: ObservableObject {
    @Published var gdprData: GDPRData?

    init() {
        loadGDPRJSON()
    }

    private func loadGDPRJSON() {
        guard let bundle = Bundle.moduleBundle,
              let url = bundle.url(forResource: "GDPR", withExtension: "json") else {
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

fileprivate struct SupplyPointsResponse: Codable {
    let count: Int
    let results: [SupplyPoint]
}

fileprivate struct SupplyPoint: Codable {
    let group_id: String
}

// MARK: - Guide Data Model
fileprivate struct GuideData: Codable {
    let title: String
    let tldr: String
    let heading: String
    let steps: [String]
}

// MARK: - Guide ViewModel
fileprivate class GuideViewModel: ObservableObject {
    @Published var guideData: GuideData?

    init() {
        loadGuideJSON()
    }

    private func loadGuideJSON() {
        guard let bundle = Bundle.moduleBundle,
              let url = bundle.url(forResource: "Guide", withExtension: "json") else {
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

struct APIConfigurationView: View {
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @Environment(\.dismiss) var dismiss
    @State private var showGDPRConsent = false
    @State private var gdprAccepted = false
    @State private var showDeleteAPIKeyWarning = false
    @State private var showDeleteMPANWarning = false
    @State private var showDeleteSerialWarning = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 0) {
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
                        
                        if !globalSettings.settings.apiKey.isEmpty {
                            Button(action: {
                                showDeleteAPIKeyWarning = true
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical)
                    .background(
                        Theme.secondaryBackground
                            .padding(.horizontal, 20)
                    )
                }
                
                VStack(alignment: .leading, spacing: 0) {
                    Text(LocalizedStringKey("Electricity Meter Details"))
                        .font(Theme.subFont())
                        .foregroundColor(Theme.secondaryTextColor)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                    
                    VStack(spacing: 0) {
                        HStack {
                            TextField(
                                LocalizedStringKey("Electricity MPAN"),
                                text: Binding(
                                    get: { globalSettings.settings.electricityMPAN ?? "" },
                                    set: { globalSettings.settings.electricityMPAN = $0.isEmpty ? nil : $0 }
                                ),
                                prompt: Text(LocalizedStringKey("Enter electricity MPAN (13 digits)"))
                                    .foregroundColor(Theme.secondaryTextColor)
                            )
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 16)
                            .font(Theme.secondaryFont())
                            .foregroundColor(Theme.mainTextColor)
                            .keyboardType(.numberPad)
                            
                            if !(globalSettings.settings.electricityMPAN ?? "").isEmpty {
                                Button(action: {
                                    showDeleteMPANWarning = true
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.red)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical)
                        .background(
                            Theme.secondaryBackground
                                .padding(.horizontal, 20)
                        )
                        
                        Divider()
                            .background(Theme.mainBackground)
                            .padding(.horizontal, 20)
                        
                        HStack {
                            TextField(
                                LocalizedStringKey("Electricity Meter Serial Number"),
                                text: Binding(
                                    get: { globalSettings.settings.electricityMeterSerialNumber ?? "" },
                                    set: { globalSettings.settings.electricityMeterSerialNumber = $0.isEmpty ? nil : $0 }
                                ),
                                prompt: Text(LocalizedStringKey("Enter electricity meter serial number"))
                                    .foregroundColor(Theme.secondaryTextColor)
                            )
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 16)
                            .font(Theme.secondaryFont())
                            .foregroundColor(Theme.mainTextColor)
                            
                            if !(globalSettings.settings.electricityMeterSerialNumber ?? "").isEmpty {
                                Button(action: {
                                    showDeleteSerialWarning = true
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.red)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical)
                        .background(
                            Theme.secondaryBackground
                                .padding(.horizontal, 20)
                        )
                        
                        Link(destination: URL(string: "https://octopus.energy/dashboard/new/accounts/personal-details/api-access")!) {
                            HStack(spacing: 4) {
                                Text(LocalizedStringKey("Get API Key, MPAN and Serial Number (Login Required)"))
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
                            .padding(.vertical)
                        }
                        .background(Theme.mainBackground)
                        .padding(.horizontal, 20)
                    }
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
                .padding(.bottom, 20)
                
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
        .background(Theme.mainBackground)
        .navigationTitle(LocalizedStringKey("API Configuration"))
        .alert(LocalizedStringKey("Delete API Key?"), isPresented: $showDeleteAPIKeyWarning) {
            Button(LocalizedStringKey("Cancel"), role: .cancel) {}
            Button(LocalizedStringKey("Delete"), role: .destructive) {
                globalSettings.settings.apiKey = ""
            }
        } message: {
            Text(LocalizedStringKey("Are you sure you want to delete your API key? This will prevent access to your personal energy data."))
        }
        .alert(LocalizedStringKey("Delete MPAN?"), isPresented: $showDeleteMPANWarning) {
            Button(LocalizedStringKey("Cancel"), role: .cancel) {}
            Button(LocalizedStringKey("Delete"), role: .destructive) {
                globalSettings.settings.electricityMPAN = nil
            }
        } message: {
            Text(LocalizedStringKey("Are you sure you want to delete your MPAN? This will prevent access to your meter-specific data."))
        }
        .alert(LocalizedStringKey("Delete Serial Number?"), isPresented: $showDeleteSerialWarning) {
            Button(LocalizedStringKey("Cancel"), role: .cancel) {}
            Button(LocalizedStringKey("Delete"), role: .destructive) {
                globalSettings.settings.electricityMeterSerialNumber = nil
            }
        } message: {
            Text(LocalizedStringKey("Are you sure you want to delete your meter serial number? This will prevent access to your meter-specific data."))
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
            } else if let region = region {
                Text("Using Region \(region)")
                    .font(Theme.subFont())
                    .foregroundColor(Theme.secondaryTextColor)
            } else {
                Text("Using Region H")
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
            let cleanedPostcode = postcode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
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
        
        let encoded = cleanedPostcode.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        guard let encodedPostcode = encoded,
              let url = URL(string: "https://api.octopus.energy/v1/industry/grid-supply-points/?postcode=\(encodedPostcode)")
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
            return (nil, true) // Indicates invalid postcode
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

struct SettingsView: View {
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @State private var lookupRegionManually = false
    @State private var lookupError: String?

    // new states for account approach
    @State private var accountNumberInput: String = ""
    @State private var isFetchingAccount = false
    @State private var fetchError: String?

    var body: some View {
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
                            "Customise your dashboard by managing your cards:\n\n• Enable/disable cards to show only what matters to you\n• Reorder cards by dragging to arrange your perfect layout\n• Each card offers unique insights into your energy usage and rates\n\nStay tuned for new card modules - we're constantly developing new features to help you better understand and manage your energy usage."
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
                    TextField(
                        LocalizedStringKey("Postcode or Region Code"),
                        text: $globalSettings.settings.regionInput,
                        prompt: Text(LocalizedStringKey("e.g., SW1A 1AA, SW1A or H"))
                            .foregroundColor(Theme.secondaryTextColor)
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .font(Theme.secondaryFont())
                    .foregroundColor(Theme.mainTextColor)
                    .padding(.trailing, 35)
                    
                    HStack(spacing: 4) {
                        let input = globalSettings.settings.regionInput.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
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
                
                let input = globalSettings.settings.regionInput.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                if input.count == 1 && input >= "A" && input <= "P" {
                    Text("Using Region \(input)")
                        .font(Theme.subFont())
                        .foregroundColor(Theme.secondaryTextColor)
                        .customListRow()
                } else {
                    RegionLookupView(postcode: input, triggerLookup: $lookupRegionManually, lookupError: $lookupError)
                }
            }

            // Account Number Fetch section
            Section(
                header: Text("Account Number Fetch")
                    .font(Theme.subFont())
                    .foregroundColor(Theme.secondaryTextColor)) {
                // Account Number Fetch section above is unchanged
                // except we removed the if-let block referencing an unknown method
                TextField("Enter Account Number", text: $accountNumberInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .font(Theme.secondaryFont())
                    .foregroundColor(Theme.mainTextColor)
                
                if isFetchingAccount {
                    ProgressView("Fetching Account Data...")
                } else {
                    Button("Confirm") {
                        Task {
                            await confirmAccountNumber()
                        }
                    }
                    .disabled(accountNumberInput.isEmpty || globalSettings.settings.apiKey.isEmpty)
                }
                if let fetchError = fetchError {
                    Text(fetchError).foregroundColor(.red)
                }
            }

            Section(
                header: HStack {
                    Text(LocalizedStringKey("Electricity Meter Details"))
                        .font(Theme.subFont())
                        .foregroundColor(Theme.secondaryTextColor)
                    InfoButton(
                        message: LocalizedStringKey(
                            "Enter your electricity meter details to access personal consumption data..."
                        ),
                        title: LocalizedStringKey("Electricity Meter Details"),
                        mediaItems: []
                    )
                }
            ) { 
                // Removed the placeholder block to prevent compile-time errors 
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
    }
    
    private func confirmAccountNumber() async {
        isFetchingAccount = true
        fetchError = nil
        do {
            try await AccountRepository.shared.fetchAndStoreAccount(
                accountNumber: accountNumberInput,
                apiKey: globalSettings.settings.apiKey
            )
            // on success, the repository has updated globalSettings with MPAN + Serial.
            // so we might read them here if we want to show a success message:
            if let mpan = globalSettings.settings.electricityMPAN {
                print("Auto-filled MPAN: \(mpan)")
            }
        } catch {
            fetchError = error.localizedDescription
        }
        isFetchingAccount = false
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

struct SettingsView_Previews: PreviewProvider {
    static let globalSettings = GlobalSettingsManager()

    static var previews: some View {
        NavigationStack {
            SettingsView()
                .environmentObject(globalSettings)
        }
    }
}
