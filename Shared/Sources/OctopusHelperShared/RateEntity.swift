import Foundation

public struct RateEntity: Identifiable {
    public let id: UUID
    public let validFrom: Date?
    public let validTo: Date?
    public let valueIncludingVAT: Double
    
    public init(id: UUID = UUID(), validFrom: Date? = nil, validTo: Date? = nil, valueIncludingVAT: Double = 0.0) {
        self.id = id
        self.validFrom = validFrom
        self.validTo = validTo
        self.valueIncludingVAT = valueIncludingVAT
    }
} 