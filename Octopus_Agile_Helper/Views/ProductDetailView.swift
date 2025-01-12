import SwiftUI
import OctopusHelperShared
import CoreData

struct ProductDetailView: View {
    let product: NSManagedObject
    @State private var productDetails: [NSManagedObject] = []
    
    var body: some View {
        List {
            if let productEntity = product as? ProductEntity {
                Section("基本信息") {
                    DetailRow(title: "名称", value: productEntity.display_name ?? "")
                    DetailRow(title: "完整名称", value: productEntity.full_name ?? "")
                    DetailRow(title: "代码", value: productEntity.code ?? "")
                    DetailRow(title: "品牌", value: productEntity.brand ?? "")
                    DetailRow(title: "描述", value: productEntity.desc ?? "")
                }
                
                Section("产品特性") {
                    DetailRow(title: "方向", value: productEntity.direction ?? "")
                    DetailRow(title: "是否可变", value: productEntity.is_variable ? "是" : "否")
                    DetailRow(title: "是否环保", value: productEntity.is_green ? "是" : "否")
                    DetailRow(title: "是否追踪", value: productEntity.is_tracker ? "是" : "否")
                    DetailRow(title: "是否预付", value: productEntity.is_prepay ? "是" : "否")
                    DetailRow(title: "是否商用", value: productEntity.is_business == "true" ? "是" : "否")
                }
                
                Section("有效期") {
                    if let availableFrom = productEntity.available_from,
                       availableFrom != Date.distantPast {
                        DetailRow(title: "开始时间", value: availableFrom.formatted())
                    } else {
                        DetailRow(title: "开始时间", value: "无限制")
                    }
                    
                    if let availableTo = productEntity.available_to,
                       availableTo != Date.distantFuture {
                        DetailRow(title: "结束时间", value: availableTo.formatted())
                    } else {
                        DetailRow(title: "结束时间", value: "无限制")
                    }
                }
            }
            
            Section("费率详情") {
                if productDetails.isEmpty {
                    Text("无费率详情")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(productDetails, id: \.self) { detail in
                        if let detailEntity = detail as? ProductDetailEntity {
                            NavigationLink {
                                TariffDetailView(detail: detailEntity)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text("\(detailEntity.region ?? "") - \(detailEntity.payment ?? "")")
                                        .font(.headline)
                                    Text(detailEntity.tariff_code ?? "")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("产品详情")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadProductDetails()
        }
    }
    
    private func loadProductDetails() {
        Task {
            if let productEntity = product as? ProductEntity,
               let code = productEntity.code {
                do {
                    let details = try await ProductDetailRepository.shared.loadLocalProductDetail(code: code)
                    await MainActor.run {
                        self.productDetails = details
                    }
                } catch {
                    print("Error loading product details: \(error)")
                }
            }
        }
    }
}

struct TariffDetailView: View {
    let detail: ProductDetailEntity
    
    var body: some View {
        List {
            Section("基本信息") {
                DetailRow(title: "费率代码", value: detail.tariff_code ?? "")
                DetailRow(title: "费率类型", value: detail.tariff_type ?? "")
                DetailRow(title: "地区", value: detail.region ?? "")
                DetailRow(title: "支付方式", value: detail.payment ?? "")
                
                if let activeAt = detail.tariffs_active_at {
                    DetailRow(title: "生效时间", value: activeAt.formatted())
                }
            }
            
            Section("折扣信息") {
                if detail.online_discount_inc_vat > 0 {
                    DetailRow(title: "在线折扣(含税)", value: String(format: "£%.2f", detail.online_discount_inc_vat))
                    DetailRow(title: "在线折扣(不含税)", value: String(format: "£%.2f", detail.online_discount_exc_vat))
                }
                
                if detail.dual_fuel_discount_inc_vat > 0 {
                    DetailRow(title: "双燃料折扣(含税)", value: String(format: "£%.2f", detail.dual_fuel_discount_inc_vat))
                    DetailRow(title: "双燃料折扣(不含税)", value: String(format: "£%.2f", detail.dual_fuel_discount_exc_vat))
                }
            }
            
            Section("退出费用") {
                if detail.exit_fees_inc_vat > 0 {
                    DetailRow(title: "退出费用(含税)", value: String(format: "£%.2f", detail.exit_fees_inc_vat))
                    DetailRow(title: "退出费用(不含税)", value: String(format: "£%.2f", detail.exit_fees_exc_vat))
                    DetailRow(title: "退出费用类型", value: detail.exit_fees_type ?? "")
                } else {
                    Text("无退出费用")
                        .foregroundStyle(.secondary)
                }
            }
            
            Section("API链接") {
                if let standingLink = detail.link_standing_charge,
                   !standingLink.isEmpty {
                    DetailRow(title: "固定费率链接", value: standingLink)
                }
                if let rateLink = detail.link_rate,
                   !rateLink.isEmpty {
                    DetailRow(title: "单位费率链接", value: rateLink)
                }
            }
        }
        .navigationTitle("费率详情")
        .navigationBarTitleDisplayMode(.inline)
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
