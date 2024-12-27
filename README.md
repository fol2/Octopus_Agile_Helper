# Octopus Agile Helper

A SwiftUI-based iOS application designed to help users manage and optimize their energy usage with the Octopus Agile tariff. This app provides insights and tools to make the most of variable rate electricity pricing.

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

#### Global vs Local Settings

- **Global Settings**: Configure app-wide settings like postcode, API key, and language in the main Settings view.
- **Local Card Settings**: Each card can have its own configuration:
  - Click the gear icon on a card to access its local settings
  - Customize settings like average hours and number of items to display
  - Settings are saved per-card and persist between app launches

## License
TBD 