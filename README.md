# Octopus Agile Helper

A SwiftUI-based iOS application designed to help users manage and optimize their energy usage with the Octopus Agile tariff. This app provides insights and tools to make the most of variable rate electricity pricing.

## Current Status
Currently in development - Milestone 3: Cards for Lowest, Highest, and Average Rates

### Features
- API Key configuration for Octopus Energy integration
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
- Octopus Energy API key (for rate data)

## Project Structure
```
OctopusAgileHelper/
├── Models/
│   ├── RateModel.swift
│   ├── RateEntity+CoreDataClass.swift
│   └── RateEntity+CoreDataProperties.swift
├── ViewModels/
│   └── RatesViewModel.swift
├── Views/
│   ├── Cards/
│   │   ├── LowestUpcomingRateCardView.swift
│   │   ├── HighestUpcomingRateCardView.swift
│   │   └── AverageUpcomingRateCardView.swift
│   └── SharedUI/
│       └── RateCardStyle.swift
├── Services/
│   ├── OctopusAPIClient.swift
│   └── RatesManager.swift
├── Persistence/
│   └── RatesPersistence.swift
└── Resources/
```

## Development
Check `dev_log.md` for detailed development progress and updates.

## API Integration
The app integrates with the Octopus Energy API to fetch Agile tariff rates. Users need to provide their API key in the settings. The app handles:
- Secure API key storage
- Rate data fetching
- Local data persistence
- Offline access to previously fetched rates

## Rate Display
The app provides three main views for rate information:
1. **Lowest Rate**: Shows the lowest upcoming rate with its time slot
2. **Highest Rate**: Shows the highest upcoming rate with its time slot
3. **Average Rate**: Displays the average rate for a user-defined period

## License
TBD 