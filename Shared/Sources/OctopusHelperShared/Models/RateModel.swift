import Foundation

public struct OctopusRatesResponse: Codable {
    public let results: [OctopusRate]
}

public struct OctopusRate: Codable, Identifiable {
    public let id = UUID()
    public let valid_from: Date
    public let valid_to: Date
    public let value_exc_vat: Double
    public let value_inc_vat: Double

    enum CodingKeys: String, CodingKey {
        case valid_from
        case valid_to
        case value_exc_vat
        case value_inc_vat
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let dateFormatter = ISO8601DateFormatter()

        let validFromString = try container.decode(String.self, forKey: .valid_from)
        guard let validFrom = dateFormatter.date(from: validFromString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .valid_from, in: container, debugDescription: "Invalid date format")
        }
        self.valid_from = validFrom

        let validToString = try container.decode(String.self, forKey: .valid_to)
        guard let validTo = dateFormatter.date(from: validToString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .valid_to, in: container, debugDescription: "Invalid date format")
        }
        self.valid_to = validTo

        self.value_exc_vat = try container.decode(Double.self, forKey: .value_exc_vat)
        self.value_inc_vat = try container.decode(Double.self, forKey: .value_inc_vat)
    }
}
