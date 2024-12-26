import Foundation
import CoreData

extension RateEntity {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<RateEntity> {
        return NSFetchRequest<RateEntity>(entityName: "RateEntity")
    }

    @NSManaged public var id: String
    @NSManaged public var validFrom: Date
    @NSManaged public var validTo: Date
    @NSManaged public var valueExcludingVAT: Double
    @NSManaged public var valueIncludingVAT: Double
} 