import SwiftUI

struct FridgeView: View {
    @EnvironmentObject private var viewModel: PantryViewModel

    @State private var name = ""
    @State private var category = "기타"
    @State private var expiryDate = Date()

    private let categories = ["육류", "채소", "유제품", "양념", "가공식품", "기타"]

    var body: some View {
        NavigationStack {
            List {
                Section("재료 추가") {
                    TextField("재료명", text: $name)
                    Picker("카테고리", selection: $category) {
                        ForEach(categories, id: \.self) { c in
                            Text(c).tag(c)
                        }
                    }
                    DatePicker("유통기한", selection: $expiryDate, displayedComponents: .date)

                    Button("추가") {
                        let formatter = DateFormatter()
                        formatter.dateFormat = "yyyy-MM-dd"
                        let expiryText = formatter.string(from: expiryDate)

                        Task {
                            await viewModel.addFridgeItem(name: name, category: category, expiryDate: expiryText)
                            name = ""
                            expiryDate = Date()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section("냉장고 재료") {
                    if viewModel.fridgeItems.isEmpty {
                        Text("등록된 재료가 없습니다.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.fridgeItems) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.name)
                                        .font(.headline)
                                    Text("\(item.category) · \(item.expiryDate)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    Task { await viewModel.removeFridgeItem(item) }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
            .navigationTitle("냉장고")
        }
    }
}
