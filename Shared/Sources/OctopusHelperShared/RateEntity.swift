import CoreData
import Foundation

/// Represents a single Octopus Agile electricity rate within a specific half-hour window.
/// All values are stored in pence/kWh, and timestamps describe when the rate is active.
@objc(OctopusHelperSharedRateEntity)
public final class RateEntity: NSManagedObject {
    
    // MARK: - Properties
    
    /// Unique identifier (often a UUID string).
    @NSManaged public var id: String
    
    /// Starting timestamp for this rate (inclusive).
    @NSManaged public var validFrom: Date?
    
    /// Ending timestamp for this rate (exclusive).
    @NSManaged public var validTo: Date?
    
    /// The rate excluding VAT, in pence/kWh.
    @NSManaged public var valueExcludingVAT: Double
    
    /// The rate including VAT, in pence/kWh.
    @NSManaged public var valueIncludingVAT: Double
    
    // MARK: - Fetch Request
    
    /// Provides a basic `NSFetchRequest` for fetching `RateEntity` objects.
    @nonobjc public class func fetchRequest() -> NSFetchRequest<RateEntity> {
        NSFetchRequest<RateEntity>(entityName: "RateEntity")
    }
}
