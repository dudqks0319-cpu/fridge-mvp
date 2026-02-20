import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var viewModel: PantryViewModel

    private var missingEssential: [String] {
        let fridgeNames = viewModel.fridgeItems.map { $0.name.lowercased() }
        return viewModel.essentialItems.filter { essential in
            !fridgeNames.contains(where: { $0.contains(essential.lowercased()) })
        }
    }

    private var urgentItems: [FridgeItem] {
        viewModel.fridgeItems.filter { item in
            let diff = item.expiryDate.daysFromToday
            return diff <= 3
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("상태") {
                    LabeledContent("냉장고 재료") {
                        Text("\(viewModel.fridgeItems.count)개")
                    }
                    LabeledContent("장보기 항목") {
                        Text("\(viewModel.shoppingItems.filter { !$0.checked }.count)개")
                    }
                }

                if !missingEssential.isEmpty {
                    Section("필수 재료 부족") {
                        Text(missingEssential.joined(separator: ", "))
                            .foregroundStyle(.blue)
                    }
                }

                if !urgentItems.isEmpty {
                    Section("유통기한 임박") {
                        ForEach(urgentItems) { item in
                            HStack {
                                Text(item.name)
                                Spacer()
                                Text(item.expiryDate.dDayText)
                                    .font(.caption.bold())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.orange.opacity(0.15), in: Capsule())
                            }
                        }
                    }
                }

                Section {
                    Button("새로고침") {
                        Task { await viewModel.refreshAll() }
                    }
                }
            }
            .navigationTitle("우리집 냉장고")
        }
    }
}

private extension String {
    var daysFromToday: Int {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let target = formatter.date(from: self) else { return 999 }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let end = calendar.startOfDay(for: target)
        return calendar.dateComponents([.day], from: today, to: end).day ?? 999
    }

    var dDayText: String {
        let diff = daysFromToday
        if diff < 0 { return "D+\(abs(diff))" }
        return "D-\(diff)"
    }
}
