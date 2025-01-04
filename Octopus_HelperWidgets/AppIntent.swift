//
//  AppIntent.swift
//  Octopus_HelperWidgets
//
//  Created by James To on 31/12/2024.
//

// AppIntent.swift
import WidgetKit
import AppIntents

struct ConfigurationAppIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Configuration"
    static var description: IntentDescription = "Current rate widget configuration."
}
