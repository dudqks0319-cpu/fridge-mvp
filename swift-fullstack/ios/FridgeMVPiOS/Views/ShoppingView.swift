import SwiftUI

struct ShoppingView: View {
    @EnvironmentObject private var viewModel: PantryViewModel

    @State private var newItemName = ""

    var body: some View {
        NavigationStack {
            List {
                Section("항목 추가") {
                    HStack {
                        TextField("장볼 항목", text: $newItemName)
                        Button("추가") {
                            Task {
                                await viewModel.addShoppingItem(name: newItemName, reason: "직접 추가")
                                newItemName = ""
                            }
                        }
                        .disabled(newItemName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                Section("장보기 목록") {
                    if viewModel.shoppingItems.isEmpty {
                        Text("장보기 목록이 비어 있어요.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.shoppingItems) { item in
                            HStack {
                                Button {
                                    Task { await viewModel.toggleShoppingItem(item) }
                                } label: {
                                    Image(systemName: item.checked ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(item.checked ? .green : .secondary)
                                }
                                .buttonStyle(.plain)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name)
                                        .strikethrough(item.checked)
                                    Text(item.recipeName == nil ? item.reason : "\(item.reason) (\(item.recipeName!))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button {
                                    Task { await viewModel.removeShoppingItem(item) }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
            .navigationTitle("장보기")
        }
    }
}
