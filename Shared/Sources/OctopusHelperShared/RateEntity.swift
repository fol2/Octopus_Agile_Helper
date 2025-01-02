import CoreData
import Foundation

@objc(OctopusHelperSharedRateEntity)
public class RateEntity: NSManagedObject {
    @NSManaged public var id: String
    @NSManaged public var validFrom: Date?
    @NSManaged public var validTo: Date?
    @NSManaged public var valueExcludingVAT: Double
    @NSManaged public var valueIncludingVAT: Double

    @nonobjc public class func fetchRequest() -> NSFetchRequest<RateEntity> {
        return NSFetchRequest<RateEntity>(entityName: "RateEntity")
    }
}
