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

## 2024-12-27: Timed Refresh & 4PM Fetch
- Moved the 1-minute timer to `AppMain` via GlobalTimer
- RatesViewModel re-filters upcoming data each minute
- Only fetch from Octopus:
  - If 4pm & next day's data is missing
  - If no data on app open
  - If user force refreshes
- All cards now re-calculate every minute automatically 

## 2024-12-27: Local vs. Global Settings

- Created `CardSettings` model and `CardSettingsManager` for managing local card settings (e.g. average hours, list size).
- Added local settings support to `AverageUpcomingRateCardView` with a gear icon for accessing card-specific settings.
- Added `getLowestAverages` method to `RatesViewModel` to support custom hours and max count per card.
- Global settings (postcode, API key, language) remain in `SettingsView`.
- Local card settings are stored in `UserDefaults` with card-specific keys. 