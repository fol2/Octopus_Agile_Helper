import SwiftUI
import CoreData
import OctopusHelperShared

struct EntityTestView: View {
    @Environment(\.managedObjectContext) private var viewContext
    
    // Get entity descriptions
    private var productEntityDescription: NSEntityDescription? {
        NSEntityDescription.entity(forEntityName: "ProductEntity", in: viewContext)
    }
    
    private var standingChargeEntityDescription: NSEntityDescription? {
        NSEntityDescription.entity(forEntityName: "StandingChargeEntity", in: viewContext)
    }
    
    private var rateEntityDescription: NSEntityDescription? {
        NSEntityDescription.entity(forEntityName: "RateEntity", in: viewContext)
    }
    
    private func getAttributeTypeString(_ type: NSAttributeType) -> String {
        switch type {
        case .integer16AttributeType: return "Int16"
        case .integer32AttributeType: return "Int32"
        case .integer64AttributeType: return "Int64"
        case .decimalAttributeType: return "Decimal"
        case .doubleAttributeType: return "Double"
        case .floatAttributeType: return "Float"
        case .stringAttributeType: return "String"
        case .booleanAttributeType: return "Boolean"
        case .dateAttributeType: return "Date"
        case .binaryDataAttributeType: return "Binary Data"
        case .UUIDAttributeType: return "UUID"
        case .URIAttributeType: return "URI"
        case .transformableAttributeType: return "Transformable"
        case .objectIDAttributeType: return "ObjectID"
        case .compositeAttributeType: return "Composite"
        case .undefinedAttributeType: return "Undefined"
        @unknown default: return "Unknown"
        }
    }
    
    private var productAttributes: [(String, String)] {
        guard let attributes = productEntityDescription?.attributesByName else { return [] }
        return attributes.map { key, value in
            (key, getAttributeTypeString(value.attributeType))
        }.sorted { $0.0 < $1.0 }
    }
    
    private var standingChargeAttributes: [(String, String)] {
        guard let attributes = standingChargeEntityDescription?.attributesByName else { return [] }
        return attributes.map { key, value in
            (key, getAttributeTypeString(value.attributeType))
        }.sorted { $0.0 < $1.0 }
    }
    
    private var rateAttributes: [(String, String)] {
        guard let attributes = rateEntityDescription?.attributesByName else { return [] }
        return attributes.map { key, value in
            (key, getAttributeTypeString(value.attributeType))
        }.sorted { $0.0 < $1.0 }
    }
    
    @FetchRequest(
        entity: RateEntity.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \RateEntity.validFrom, ascending: true)]
    ) private var rates: FetchedResults<RateEntity>
    
    var body: some View {
        List {
            Section("Rates") {
                ForEach(rates, id: \.id) { rate in
                    VStack(alignment: .leading) {
                        Text("Rate: \(rate.valueIncludingVAT, specifier: "%.2f")p/kWh")
                        if let from = rate.validFrom {
                            Text("Valid from: \(from)")
                                .font(.caption)
                        }
                    }
                }
            }
            
            Section("Product Entity Columns") {
                if productAttributes.isEmpty {
                    Text("ProductEntity not found")
                        .foregroundColor(.red)
                } else {
                    ForEach(productAttributes, id: \.0) { key, type in
                        Text("\(key): \(type)")
                    }
                }
            }
            
            Section("Standing Charge Entity Columns") {
                if standingChargeAttributes.isEmpty {
                    Text("StandingChargeEntity not found")
                        .foregroundColor(.red)
                } else {
                    ForEach(standingChargeAttributes, id: \.0) { key, type in
                        Text("\(key): \(type)")
                    }
                }
            }
            
            Section("Rate Entity Columns") {
                if rateAttributes.isEmpty {
                    Text("RateEntity not found")
                        .foregroundColor(.red)
                } else {
                    ForEach(rateAttributes, id: \.0) { key, type in
                        Text("\(key): \(type)")
                    }
                }
            }
        }
        .navigationTitle("Entity Test")
    }
}

#Preview {
    EntityTestView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
