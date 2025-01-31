# Octopus Agile Helper

An iOS application to help Octopus Energy Agile tariff customers monitor and optimize their energy usage.

## Features

### Rate Monitoring
- **Current Rate Card**: Shows the current electricity rate with color-coded pricing
- **Lowest Upcoming Rate**: Displays the lowest upcoming rates with configurable number of additional rates
- **Highest Upcoming Rate**: Alerts you to peak pricing periods with configurable additional rates
- **Average Upcoming Rate**: Helps you understand typical costs with customizable averaging periods
- **Interactive Rate Chart**: Visual representation of rates with interactive tooltips and best-time highlighting

### Smart Refresh System
- Automatic content updates at o'clock and half o'clock (XX:00:00 and XX:30:00)
- Pull-to-refresh for manual updates
- Intelligent fetch status indicator showing:
  - Fetching status
  - Success/failure notifications
  - Pending state for scheduled updates
- Smart error handling with automatic retry system

### Card Management
The app features a flexible card management system that allows you to:
- Reorder cards by dragging
- Enable/disable specific cards
- Access premium features
- Configure card-specific settings:
  - Number of additional rates to show
  - Custom averaging periods
  - Chart display preferences

### Interactive Chart Features
- Visual rate timeline with dynamic scaling
- Highlighted best-time windows
- Interactive tooltips with precise rate information
- Real-time "Now" indicator
- Haptic feedback for time selection
- Customizable settings for time windows and display options

### Localization Support
The app is fully localized and supports:
- English (UK)
- Traditional Chinese (zh-Hant)

All UI elements, including:
- Rate displays
- Date and time formats
- Settings menus
- Card descriptions
are properly localized and follow system conventions for each language.

## Installation

### Requirements
- iOS 17.0 or later
- Octopus Energy Agile tariff account (optional)
- API key from Octopus Energy (optional)

### Setup
1. Download the latest release
2. Install the application
3. Launch and enter your postcode
4. (Optional) Add your Octopus Energy API key in Settings

## Configuration

### Settings
- **Language**: Choose your preferred display language
- **Postcode**: Set your region for accurate rates
- **API Key**: Enable personal data access
- **Display Options**: Configure rate display in pounds/pence
- **Card Management**: Customize your dashboard layout
- **Card-Specific Settings**: Configure individual card behaviors

### Card Settings
Each card can be customized with its own settings:
- **Current Rate**: Basic display options
- **Lowest/Highest Rate**: Number of additional rates to show
- **Average Rate**: Custom averaging period and display count
- **Interactive Chart**: Time window and display preferences

## Development

### Building from Source
1. Clone the repository
2. Open in Xcode 15 or later
3. Build and run

### Contributing
Contributions are welcome! Please read our contributing guidelines before submitting pull requests.

#### Adding New Languages
To add support for a new language:
1. Open the `Localizable.xcstrings` file
2. Add the new language in Xcode's localization editor
3. Provide translations for all strings
4. Test the UI in the new language

## Support

For issues and feature requests, please use the GitHub issue tracker.

## License

This project is licensed under the MIT License - see the LICENSE file for details.

### Tariff Comparison
- **Tariff Comparison**: Offers a visual and detailed analysis of different energy tariffs, enabling you to compare and choose the most cost-effective plan based on current and historical data.

### Widget Support
- **Widget Support**: Provides a home screen widget for quick access to real-time rate information, alerts, and energy usage summaries, enhancing user engagement and convenience.

### Historical Rate Analysis
- **Historical Rate Analysis**: Analyzes past energy consumption and rate trends to offer insights and forecasting, helping users understand their energy usage over time. 