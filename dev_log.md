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

## 2024-12-27: Major Updates & Improvements

### 1. Architecture & Code Organization
- **Repository Pattern Implementation**
  - Created `RatesRepository.swift` combining API and Core Data operations
  - Removed redundant `RatesManager` and `RatesPersistence`
  - Simplified data flow with single source of truth
  - Better separation of concerns

- **Settings Management**
  - Unified global settings under `GlobalSettingsManager`
  - Replaced `@AppStorage` with JSON-based UserDefaults storage
  - Restructured card settings to be self-contained
  - Each card now manages its own local settings

### 2. UI/UX Improvements
- **Navigation & Layout**
  - Removed bottom tab bar for cleaner interface
  - Added settings gear icon to navigation bar
  - Made current rate card tappable to show all rates
  - Improved modal presentation and dismissal

- **Rate Display**
  - Added new Current Rate card at the top
  - Enhanced rate formatting:
    - Pounds format: "£0.2228 /kWh"
    - Pence format: "22.28p /kWh"
    - Consistent spacing and alignment
  - Added global toggle for pounds/pence display

### 3. Feature Enhancements
- **Postcode-Based Region Lookup**
  - Added postcode field to settings
  - Implemented region lookup functionality
  - Removed API key requirement
  - Added proper error handling

- **Rate Calculations**
  - Redesigned average rate card to show next 10 lowest rates
  - Added "All Rates List" view with current rate highlighting
  - Improved time display formatting
  - Added local settings for rate counts

### 4. Technical Improvements
- **Data Refresh Logic**
  - Moved 1-minute timer to `AppMain` via `GlobalTimer`
  - Implemented smart refresh at 4 PM
  - Added pull-to-refresh functionality
  - Automatic rate recalculation every minute

- **SwiftUI Integration**
  - Fixed environment object handling
  - Improved preview support
  - Better modal presentation
  - Proper dark mode support

### 5. Bug Fixes
- Fixed environment object crash in `RatesViewModel`
- Resolved preview provider issues
- Fixed modal presentation color scheme
- Corrected navigation hierarchy issues

### Benefits
- More maintainable and organized codebase
- Better user experience with cleaner UI
- More reliable data handling
- Improved performance and stability
- Consistent visual design across the app 

## 2024-12-27: Card Management System Implementation

### Added Features
1. **Card Configuration System**
   - Added `CardType` enum for different card types
   - Added `CardConfig` struct for card settings (enabled/disabled, purchase status, sort order)
   - Integrated with `GlobalSettings` for persistence

2. **Card Management UI**
   - Created new `CardManagementView` with drag-to-reorder functionality
   - Added card-specific icons for better visual identification:
     - Current Rate: clock.fill
     - Lowest Upcoming: arrow.down.circle.fill
     - Highest Upcoming: arrow.up.circle.fill
     - Average Upcoming: chart.bar.fill
   - Implemented toggle switches for enabling/disabling cards
   - Added "Unlock" buttons for premium features (preparation for future in-app purchases)

3. **UX Improvements**
   - Smooth drag-and-drop reordering with haptic feedback
   - Visual indicators for draggable areas
   - Top and bottom bleeding areas for easier card manipulation
   - Responsive touch targets (44pt minimum)
   - Clear visual hierarchy with secondary colors for drag indicators

### Technical Details
- Cards use SwiftUI's native list reordering system
- Card configurations are stored in UserDefaults via GlobalSettings
- Each card maintains its sort order for consistent display
- Implemented proper state management for drag gestures
- Added brief edit mode reset after moves to maintain responsiveness

### Future Improvements
- [ ] Implement StoreKit integration for premium card features
- [ ] Add card usage analytics
- [ ] Consider adding custom card creation
- [ ] Add card preview in management view 

## 2024-12-27: Card Registry and Management System Improvements

### Added Features
1. **Card Registry System**
   - Added `CardRegistry` singleton to centralize card definitions
   - Each card now has metadata (display name, description, premium status)
   - Cards can be created without modifying `ContentView`
   - Improved extensibility for future card types

2. **Enhanced Card Management**
   - Fixed reordering glitch by removing forced edit mode toggling
   - Added info button to view card details
   - Added premium card UI with lock indicator
   - Improved visual feedback during reordering

3. **Card Info Sheet**
   - New modal view showing card details
   - Displays card name, description, and premium status
   - Consistent UI for viewing card information

### Benefits
- More maintainable card system
- Better user experience with smooth reordering
- Easier to add new cards in the future
- Cleaner separation of concerns
- Foundation for premium features 

## 2024-12-27: Localization Implementation

### Added Features
1. **Complete App Localization**
   - Added Traditional Chinese (zh-Hant) localization
   - Created `Localizable.xcstrings` for centralized string management
   - Implemented proper date formatting for different locales
   - Added language selection in settings

2. **Localization Infrastructure**
   - Updated all views to use `LocalizedStringKey`
   - Implemented locale-aware date formatting
   - Added proper locale propagation through environment
   - Fixed Chinese date format to show "MM月dd日"

3. **UI/UX Improvements**
   - All UI elements now respond to language changes
   - Consistent date/time formatting across cards
   - Proper text alignment for different languages
   - Immediate UI updates when changing language

### Technical Details
- Used SwiftUI's native localization system
- Implemented proper locale environment propagation
- Added locale-specific date formatters
- Fixed "Until" text localization in rate displays

### Benefits
- Full multilingual support
- Consistent user experience across languages
- Foundation for adding more languages
- Proper handling of locale-specific formatting 

## 2024-12-27: OAuth Integration Branch Creation

### Initial Setup
- Created new feature branch `OctopusOAuth` for implementing OAuth authentication
- Planning to replace API key-based authentication with proper OAuth flow
- Will implement secure token storage and refresh mechanisms
- Preparing for improved user authentication experience 

## Latest Changes

### Region Input Enhancement
- Modified region lookup to accept both postcodes and direct region codes
- Added immediate region feedback in the UI:
  - Shows "Using Region X" for direct region codes
  - Shows loading state while looking up postcode
  - Displays error messages for invalid postcodes
  - Updates automatically when input changes
- Updated GlobalSettings to use regionInput instead of postcode
- Added clear examples and guidance in the UI
- Updated widget support for the new input format
- Improved region code validation (A-P)

### API Configuration Enhancement
- Created a dedicated API Configuration view with detailed instructions
- Added support for storing electricity MPAN and meter serial number
- Improved user guidance with step-by-step instructions
- Added data usage and privacy information
- Updated GlobalSettings model to include new meter details
- Updated widget support for new settings 