# Octopus Agile Helper

A SwiftUI app to help monitor and optimize usage of the Octopus Agile tariff.

## Features

### Rate Display
The app provides three main views for rate information:

1. **Lowest Rate Card**:
   - Shows the lowest upcoming rate prominently
   - Configurable number of next lowest rates (0-10)
   - Each rate shows value and time slot
   - Date prefix for next-day rates

2. **Highest Rate Card**:
   - Shows the highest upcoming rate prominently
   - Configurable number of next highest rates (0-10)
   - Each rate shows value and time slot
   - Date prefix for next-day rates

3. **Average Rate Card**:
   - Shows lowest periods for running longer appliances
   - Configurable period length (0.5 to 24 hours)
   - Configurable number of periods to show
   - Special handling for cross-day periods

### Rate Formatting
- Values shown as "21.83p/kWh"
- Main rate: Large value (34pt), smaller unit (17pt)
- Secondary rates: Medium value (17pt), smaller unit (13pt)
- Times shown as "22:30-23:00" or "27 Dec 22:30-23:00"

### Card Settings
Each card has its own local settings accessible via a gear icon:
- Settings persist independently in UserDefaults
- Individual control over display options
- Changes take effect immediately
- Settings specific to each card's purpose

### Auto-Refresh Logic
1. We run a 1-minute global timer. Each minute:
   - The app re-checks upcoming rates & hides expired slots.
2. At 4pm daily, if the next day's data is missing, we fetch from Octopus.
3. If you open the app and have no data, or you do a pull-to-refresh, we fetch from Octopus.

## Configuration

### Global Settings
We store global settings (postcode, API key, language, etc.) in `GlobalSettingsManager`, a single reference to which is created in `AppMain.swift`. This ensures we can easily synchronize changes across the app. Settings are saved in `UserDefaults` as JSON.

### Local Card Settings
Each card maintains its own settings:
- Lowest/Highest cards: Number of additional rates to show
- Average card: Period length and number of periods
- All settings persist independently
- Each card has its own settings UI

## Current Status
Currently in development - Milestone 3: Cards for Lowest, Highest, and Average Rates

### Features
- Automatic region detection using postcode
- Language selection support
- Customizable average hours for usage planning
- Octopus Agile rate data fetching and storage
- Offline support through Core Data persistence
- Error handling for API requests and data operations
- Real-time rate information display:
  - Lowest upcoming rate card
  - Highest upcoming rate card
  - Average rate for customizable time period
- Pull-to-refresh rate updates
- Dynamic UI with loading states

## Requirements
- iOS 16.0+
- Xcode 14.0+
- Swift 5.0+
- UK Postcode (for region detection)

## Project Structure
```
Octopus_Agile_Helper/
├── AppMain.swift                     # Main app entry point
├── Models/
│   └── RateModel.swift               # OctopusRate, OctopusRatesResponse
├── ViewModels/
│   └── RatesViewModel.swift
├── Views/
│   ├── ContentView.swift
│   ├── SettingsView.swift
│   ├── Cards/
│   │   ├── LowestUpcomingRateCardView.swift
│   │   ├── HighestUpcomingRateCardView.swift
│   │   └── AverageUpcomingRateCardView.swift
│   └── SharedUI/
│       └── RateCardStyle.swift
├── Services/
│   └── OctopusAPIClient.swift        # API integration
├── Persistence/
│   ├── PersistenceController.swift   # Core Data setup
│   └── RatesRepository.swift         # Rate data & region management
├── Resources/
│   └── Assets.xcassets/
└── Preview Content/
    └── Preview Assets.xcassets/
```

## Development
Check `dev_log.md` for detailed development progress and updates.

## Region & Rate Lookup
The app uses the Octopus Energy API to:
1. Determine your region from your postcode
2. Fetch the correct Agile tariff rates for your region
3. Store rates locally for offline access

## Rate Display
The app provides three main views for rate information:
1. **Lowest Rate**: Shows the lowest upcoming rate with its time slot
2. **Highest Rate**: Shows the highest upcoming rate with its time slot
3. **Average Rate**: Displays the average rate for a user-defined period

## Auto-Refresh Logic

1. We run a 1-minute global timer. Each minute:
   - The app re-checks upcoming rates & hides expired slots.
2. At 4pm daily, if the next day's data is missing, we fetch from Octopus.
3. If you open the app and have no data, or you do a pull-to-refresh, we fetch from Octopus.

## Configuration

### Global Settings
We store global settings (postcode, API key, language, etc.) in `GlobalSettingsManager`, a single reference to which is created in `AppMain.swift`. This ensures we can easily synchronize changes across the app. Settings are saved in `UserDefaults` as JSON.

### Local Card Settings
Each card manages its own settings internally:
- Settings are defined within each card's view file
- Each card has its own private settings types and manager
- Settings are accessed via a gear icon in the card's header
- Settings are saved per-card in `UserDefaults` and persist between app launches
- No global settings manager needed - each card is self-contained

## License
TBD 