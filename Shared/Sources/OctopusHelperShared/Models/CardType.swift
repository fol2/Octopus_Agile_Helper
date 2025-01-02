import Foundation

public enum CardType: String, Codable, CaseIterable {
    case currentRate
    case lowestUpcoming
    case highestUpcoming
    case averageUpcoming
    case interactiveChart
}
