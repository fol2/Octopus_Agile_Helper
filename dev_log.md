## Consolidated Dev Log (as of 12 January 2025)

### 1. Project Setup & Initial Structure
- **Initial SwiftUI Project**: Set up a basic folder structure (Models, ViewModels, Views, Services) with iOS 16+ deployment target.  
- **Basic Settings**: Introduced SettingsView for API key input, language selection, and average hours configuration.  

### 2. Data Model & Persistence
- **RateModel & API**: Created `RateModel.swift` to parse Octopus API responses with Codable.  
- **Core Data**: Set up persistence for storing rates, using `RatesRepository`/`RatesPersistence` (later consolidated).  
- **Error Handling & Date Formatting**: Implemented ISO8601 date handling for consistent API requests.  

### 3. Card-Based UI
- **RatesViewModel**: Central place for fetching, calculating, and managing rate data.  
- **Card Views**: Introduced separate views for Lowest, Highest, Average, and Current rate cards.  
- **Pull-to-Refresh & Loading States**: Added user-friendly data refresh and status indicators.  

### 4. Architectural & Code Organization Overhaul
- **Repository Pattern**: Merged API requests and persistence into a single `RatesRepository` and later added a separate `ProductDetailRepository`.  
- **GlobalSettingsManager**: Moved away from scattered `@AppStorage` usage; created a JSON-backed storage system for unified settings.  
- **Refined Navigation**: Removed bottom tab bar in favour of a cleaner top-level experience, plus a gear icon for settings.  

### 5. UI/UX Improvements & Localization
- **Better Layout & Theming**: Cleaner interface; SwiftUI environment objects now properly handle previews and dark mode.  
- **Multiple Language Support**: Added Traditional Chinese (zh-Hant) and general locale-aware date formatting.  
- **Region Input Enhancement**: Postcode or region code can be used; real-time validation with user feedback.  

### 6. Card Management System
- **Draggable Card Management**: Implemented a dedicated `CardManagementView` for enabling/disabling and reordering cards.  
- **Card Registry**: Central metadata store (`CardRegistry`) that defines card display names, icons, and premium status.  
- **Premium Features (Placeholder)**: Basic framework for locked/premium cards, prepared for future in-app purchases.  

### 7. OAuth Integration (Planned)
- **OctopusOAuth Branch**: Created a feature branch to replace API-key authentication with a proper OAuth flow.  
- **Token Storage & Refresh**: Plan to securely handle tokens once OAuth goes live.  

### 8. Major Updates Through 12 January 2025

#### 8.1 Data Flow & Shared Dependency
- **Unified Data Flow**: Moved all fetching and storage logic into the `RatesViewModel` (and new repositories).  
- **NSManagedObject Usage**: Transitioned from using custom `RateEntity` classes to `NSManagedObject` and Key-Value Coding (KVC).  
- **Simplified Repositories**:  
  - `ProductsRepository`: Syncs all product metadata from the API.  
  - `ProductDetailRepository`: Stores/fetches detailed product info (tariff definitions, region codes).  
  - `RatesRepository`: Fetches and stores actual rate data, now identified by `tariff_code` instead of region strings.

#### 8.2 Updated ViewModel & Testing
- **RatesViewModel**:  
  - New `initializeProducts` replaces old `loadRates`, handling product sync and initial data load.  
  - `refreshRatesForProduct` uses product detail links for more accurate API calls.  
  - Reduced duplication by consolidating refresh logic and error handling.  

- **TestView**:  
  - Removed direct Core Data fetches; now references `RatesViewModel` as the single source of truth.  
  - Uses a new `IdentifiableProduct` wrapper for safer SwiftUI sheet presentation with NSManagedObject.  

#### 8.3 Widget & Rate Calculations
- **Widget Integration**:  
  - Rebuilt around new repository methods (e.g. `fetchAndStoreRates`).  
  - Improved timeline logic, fallback for missing agile codes, and support for multiple product tariffs.  
  - Better error handling for partial data or invalid region codes.

- **Rate Formatting & Colour Logic**:  
  - Centralised rate formatting for pounds/pence with consistent decimal places.  
  - Enhanced colour interpolation for negative or extremely high rates.  
  - More robust time window calculations for average or best-time displays.

#### 8.4 Chart & List Views
- **Interactive Charts**:  
  - Switched to NSManagedObject and KVC for data.  
  - Improved time range calculations, smoothing out overlapping or merged windows.  
  - Enhanced highlight for the best or worst rate periods.  

- **All Rates List**:  
  - Safe optional handling via KVC with fallback checks.  
  - More detailed error messages for missing or invalid data fields.  
  - Showcases rate changes, including `maxChange` calculations with safer division checks.

#### 8.5 Final Polishing
- **Error Handling**: Standardised approach across all repositories and views.  
- **Refresh Logic**: Intelligent scheduling at specific times (e.g. 4 PM), plus manual pull-to-refresh.  
- **Type Safety Improvements**: Carefully cast values from `Double` to `Int` (and vice versa) only where necessary.  
- **Accessibility & Localisation**: Confirmed UI updates instantly on language change; improved date/time localising for zh-Hant.  

### 9. Product Management Enhancements (13 January 2025)
- **Product Code Handling**: Added robust support for handling product codes and tariff codes:
  - New `ensureProductExists()` method to fetch and store product details
  - Added `ensureProductsForTariffCodes()` for batch processing
  - Smart tariff code parsing (e.g. "E-1R-AGILE-24-04-03-H" → "AGILE-24-04-03")
- **API Client Improvements**:
  - Enhanced `OctopusSingleProductDetail` to include all product attributes
  - Direct mapping between API response and product entities
  - Removed synthetic attribute generation in favor of actual API data
- **Default Product Support**: Added automatic handling of default "SILVER-24-12-31" product
  - Using complete product attributes from API response
  - Maintains consistency with API-returned product data structure
- **Repository Improvements**: 
  - Renamed `fetchLocalProducts()` to `fetchAllLocalProductDetails()` for clarity
  - Updated all references to use new method name in `RatesViewModel` and tests
  - Added case-sensitive product code lookup functionality
  - Enhanced error logging and status messages in both English and Chinese
  - Made `upsertProductDetail` public to support cross-repository product management
  - Added comprehensive documentation for public methods

---

### Summary of Benefits
- **Maintainable Architecture**: Repository pattern and unified `RatesViewModel` reduce complexity.  
- **Cleaner UI/UX**: Card-based interface with drag-to-reorder, streamlined navigation, and advanced localisation.  
- **Consistent Data Handling**: Full switch to NSManagedObject & KVC for easy shared dependency across frameworks.  
- **Robust Refresh**: Automatic data sync at sensible intervals, plus manual overrides.  
- **Future-Ready**: OAuth support in progress, premium card toggles in place, and flexible region code system.