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

### December 26, 2023
- Created RateModel.swift with Codable structs for Octopus API response
- Implemented OctopusAPIClient for handling API requests
- Added RatesManager for coordinating between API and local storage
- Created RatesPersistence service for Core Data operations
- Added proper error handling for API requests and data persistence
- Implemented ISO8601 date formatting for API responses
- Set up basic authentication using API key from settings 