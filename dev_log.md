# Development Log

## Milestone 1: Project Skeleton & Basic Settings (Completed)

### 26 December 2024
- Created initial Xcode project structure using SwiftUI
- Project configured for iOS 16+ deployment target
- Implementing basic folder structure (Models, ViewModels, Views, Services, etc.)
- Adding basic SettingsView with placeholders for:
  - API Key input
  - Language selection
  - Average hours configuration
- Setting up basic navigation structure
- Initial project skeleton and configuration

## Milestone 2: API Data Model & Local Storage Setup (In Progress)

### 26 December 2024
- Created RateModel.swift with Codable structs for Octopus API response
- Implemented OctopusAPIClient for handling API requests
- Added RatesManager for coordinating between API and local storage
- Created RatesPersistence service for Core Data operations
- Added proper error handling for API requests and data persistence
- Implemented ISO8601 date formatting for API responses
- Set up basic authentication using API key from settings

## Milestone 3: Cards for Lowest, Highest, and Average Rates (In Progress)

### 26 December 2024
- Created RatesViewModel to handle rate calculations and data management
- Implemented shared card styling with RateCardStyle
- Added three card views for rate display:
  - LowestUpcomingRateCardView
  - HighestUpcomingRateCardView
  - AverageUpcomingRateCardView
- Updated ContentView with ScrollView and pull-to-refresh
- Integrated settings-driven average hours parameter
- Added loading states and error handling in cards

### 26 December 2024
- Restructured app entry point to fix top-level code conflicts:
  - Created AppMain.swift as the new entry point
  - Kept Octopus_Agile_HelperApp.swift as a placeholder
- Improved project organization:
  - Added Shared/SharedImports.swift for common imports
  - Reorganized Core Data setup with Persistence.swift
  - Updated preview providers to use older style syntax
  - Fixed module import issues across views
- Cleaned up Core Data implementation:
  - Removed default Item entity
  - Streamlined preview container setup
  - Improved error handling in persistence layer 

## 2024-12-27: Codebase Cleanup

### Changes Made
1. **Model Consolidation**
   - Removed duplicate model definitions from `OctopusAPIClient.swift`
   - All rate models are now defined in `RateModel.swift`

2. **Repository Pattern Implementation**
   - Created new `RatesRepository.swift` that combines functionality from:
     - `RatesManager` (API integration)
     - `RatesPersistence` (Core Data operations)
   - Removed redundant files:
     - Deleted `RatesManager.swift`
     - Deleted `RatesPersistence.swift`

3. **App Structure Cleanup**
   - Removed `Octopus_Agile_HelperApp.swift` (using `AppMain.swift` as entry point)
   - Removed `SharedImports.swift` (using direct imports)
   - Updated `RatesViewModel` to use the new `RatesRepository`

### Benefits
- Simplified data flow with single source of truth
- Removed code duplication
- Clearer project structure
- Better separation of concerns

### Next Steps
- Add comprehensive error handling
- Implement unit tests for the repository
- Add data refresh scheduling 

## [Cleanup] - 2024-12-27
### Removed
- Removed `RatesPersistence.swift` as its functionality was fully covered by `RatesRepository.swift`
- Removed `SharedImports.swift` as it was not essential and could cause confusion
- Removed `RatesManager` class from `OctopusAPIClient.swift` as its functionality was moved to `RatesRepository`
### Verified
- Confirmed `OctopusRate` and `OctopusRatesResponse` are only defined in `RateModel.swift`
- No duplicate model definitions found in the codebase
### Known Issues
- Import resolution needs to be fixed for `RatesViewModel` in card views
- Card styling needs to be standardized across views 

## [Feature] Postcode-Based Region Lookup - 2024-12-27
### Added
- Added postcode field to `SettingsView` with proper text input configuration
- Implemented region lookup functionality in `RatesRepository`:
  - New `fetchRegionID(for:)` method to get region from postcode
  - Added `SupplyPointsResponse` and `SupplyPoint` models
### Changed
- Modified `OctopusAPIClient` to use region-based URLs:
  - Removed API key requirement for rate fetching
  - Updated `fetchRates()` to accept regionID parameter
  - Simplified URL construction with dynamic region
### Benefits
- Simplified user experience by removing API key requirement
- More accurate rate data by using correct regional tariffs
- Better error handling for region lookup failures
### Known Issues
- Need to add validation for postcode format
- Could add caching for region lookups to reduce API calls 

## Latest Changes

### 2024-12-27
- Redesigned "Average Rate" card to show average of next 10 lowest rates instead of time-based average
- Added new "All Rates List" view accessible from home screen toolbar
  - Shows all rates in chronological order
  - Automatically scrolls to and highlights current active rate
  - Accessible via "All Rates" button in navigation bar 

## 2024-12-27: Card View Enhancements
- Enhanced rate display formatting:
  - Split rate into value and unit (e.g., "21.83p" and "/kWh")
  - Larger font for rate value (34pt for main, 17pt for secondary)
  - Smaller font for unit (17pt for main, 13pt for secondary)
- Improved time display:
  - Added date prefix for next-day rates (e.g., "27 Dec 22:30-23:00")
  - Special handling for cross-day ranges in average card
  - Aligned all times to the right
  - Changed to primary color for better visibility
- Added local settings to rate cards:
  - Configurable number of additional rates (0-10)
  - Persistent settings via UserDefaults
  - Settings gear icon in each card
  - Individual settings for lowest/highest rate cards

## 2024-12-27: Timed Refresh & 4PM Fetch
- Moved the 1-minute timer to `AppMain` via GlobalTimer
- RatesViewModel re-filters upcoming data each minute
- Only fetch from Octopus:
  - If 4pm & next day's data is missing
  - If no data on app open
  - If user force refreshes
- All cards now re-calculate every minute automatically

## 2024-12-27: Local vs. Global Settings
- Created separate settings managers for each card view
- Global settings remain in `GlobalSettingsManager`
- Each card now has its own local settings:
  - AverageCard: Custom hours and list count
  - LowestCard: Additional rates count
  - HighestCard: Additional rates count
- All settings persist independently in UserDefaults

## 2024-12-28: Unified GlobalSettingsManager
- Replaced old `@AppStorage` usage in `SettingsView` with a single `GlobalSettingsManager`
- Global settings are stored in `UserDefaults` as JSON
- Created clear separation between global and local card settings
- Added `GlobalSettingsManager` to app environment for consistent access
- Benefits:
  - Single source of truth for global settings
  - Type-safe settings access
  - Easier to extend with new settings
  - Consistent settings management across the app 

## 2024-12-27: Card Settings Restructuring
### Removed
- Deleted `CardSettings.swift` and its global `CardSettingsManager`
- Removed `AverageCardSettingsSheet.swift` (moved into card view)

### Changed
- Restructured card settings to be fully self-contained:
  - Each card now manages its own settings within its SwiftUI view file
  - Settings types are private to each card (e.g., `AverageCardLocalSettings`)
  - Settings manager is scoped to individual cards (e.g., `AverageCardLocalSettingsManager`)
  - Settings sheet is now defined alongside its parent card view

### Benefits
- Better encapsulation: Each card fully owns its settings
- Reduced coupling: No shared settings manager to coordinate
- Clearer ownership: Settings code lives with the view that uses it
- Easier maintenance: Changing one card's settings won't affect others

### Next Steps
- Apply same pattern to other cards if they need local settings
- Consider adding settings migration if needed for existing users 

## 2024-12-27: Added Current Rate Card
### Added
- Created new `CurrentRateCardView` to display the active rate
- Integrated into main screen at the top of the card stack
- Shows:
  - Current active rate in p/kWh
  - Valid until time
  - Loading and empty states
### Benefits
- Users can immediately see their current rate
- Clear indication of when the rate will change
- Consistent with existing card styling and layout 

## 2024-12-27: Global Settings Refactor

1. **Removed Global `averageHours`**
   - Removed the global `averageHours` setting as it's now managed locally by each card
   - Updated `RatesViewModel` to accept hours as a parameter in relevant functions
   - Cleaned up `SettingsView` UI

2. **Added Rate Display Toggle**
   - Added new global setting `showRatesInPounds` to toggle between pence (p/kWh) and pounds (£/kWh)
   - Enhanced `RatesViewModel.formatRate()` to handle both display formats
   - Added toggle in Settings UI for user preference
   - Rates are now displayed consistently across all cards based on user preference 