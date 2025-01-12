import SwiftUI
import OctopusHelperShared
import CoreData

struct ProductDetailView: View {
    let product: NSManagedObject
    @Binding var isPresented: Bool
    
    var body: some View {
        List {
            Section("基本信息") {
                DetailRow(title: "名称", value: product.value(forKey: "display_name") as? String ?? "")
                DetailRow(title: "完整名称", value: product.value(forKey: "full_name") as? String ?? "")
                DetailRow(title: "代码", value: product.value(forKey: "code") as? String ?? "")
                DetailRow(title: "品牌", value: product.value(forKey: "brand") as? String ?? "")
                DetailRow(title: "描述", value: product.value(forKey: "desc") as? String ?? "")
            }
            
            Section("产品特性") {
                DetailRow(title: "方向", value: product.value(forKey: "direction") as? String ?? "")
                DetailRow(title: "是否可变", value: (product.value(forKey: "is_variable") as? Bool ?? false) ? "是" : "否")
                DetailRow(title: "是否环保", value: (product.value(forKey: "is_green") as? Bool ?? false) ? "是" : "否")
                DetailRow(title: "是否追踪", value: (product.value(forKey: "is_tracker") as? Bool ?? false) ? "是" : "否")
                DetailRow(title: "是否预付", value: (product.value(forKey: "is_prepay") as? Bool ?? false) ? "是" : "否")
                DetailRow(title: "是否商用", value: (product.value(forKey: "is_business") as? String ?? "") == "true" ? "是" : "否")
            }
            
            Section("有效期") {
                if let availableFrom = product.value(forKey: "available_from") as? Date {
                    DetailRow(title: "开始时间", value: availableFrom.formatted())
                }
                if let availableTo = product.value(forKey: "available_to") as? Date {
                    DetailRow(title: "结束时间", value: availableTo.formatted())
                }
            }
        }
        .navigationTitle("产品详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("关闭") {
                    print("👆 点击关闭按钮")
                    isPresented = false
                }
            }
        }
        .onAppear {
            print("🎯 ProductDetailView appeared for: \(product.value(forKey: "display_name") as? String ?? "Unknown")")
        }
        .onDisappear {
            print("🎯 ProductDetailView disappeared for: \(product.value(forKey: "display_name") as? String ?? "Unknown")")
        }
    }
}

struct DetailRow: View {
    let title: String
    let value: String
    
    var body: some View {
        HStack {
            Text(title)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }
}
