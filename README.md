# Octopus Agile Helper

A SwiftUI-based iOS application designed to help users manage and optimize their energy usage with the Octopus Agile tariff. This app provides insights and tools to make the most of variable rate electricity pricing.

## Current Status
Currently in development - Milestone 2: API Data Model & Local Storage Setup

### Features
- API Key configuration for Octopus Energy integration
- Language selection support
- Customizable average hours for usage planning
- Octopus Agile rate data fetching and storage
- Offline support through Core Data persistence
- Error handling for API requests and data operations

## Requirements
- iOS 16.0+
- Xcode 14.0+
- Swift 5.0+
- Octopus Energy API key (for rate data)

## Project Structure
```
OctopusAgileHelper/
├── Models/
│   └── RateModel.swift
├── ViewModels/
├── Views/
│   ├── Cards/
│   └── SharedUI/
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

## License
TBD 