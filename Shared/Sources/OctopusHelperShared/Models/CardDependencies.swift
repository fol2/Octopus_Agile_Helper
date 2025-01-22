import SwiftUI

/// A container for all dependencies that cards might need
public struct CardDependencies {
    public let ratesViewModel: RatesViewModel
    public let consumptionViewModel: ConsumptionViewModel
    public let globalTimer: GlobalTimer
    public let globalSettings: GlobalSettingsManager

    public init(
        ratesViewModel: RatesViewModel,
        consumptionViewModel: ConsumptionViewModel,
        globalTimer: GlobalTimer,
        globalSettings: GlobalSettingsManager
    ) {
        self.ratesViewModel = ratesViewModel
        self.consumptionViewModel = consumptionViewModel
        self.globalTimer = globalTimer
        self.globalSettings = globalSettings
    }
}
