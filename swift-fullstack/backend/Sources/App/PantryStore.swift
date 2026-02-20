import Foundation

actor PantryStore {
    private var fridgeItems: [FridgeItem] = []
    private var shoppingItems: [ShoppingItem] = []
    private var essentialItems: [String] = ["계란", "우유", "대파"]

    private let recipes: [String: [String]] = [
        "돼지고기 김치찌개": ["돼지고기 삼겹살", "김치", "양파", "대파"],
        "계란말이": ["계란", "대파"],
        "스팸 볶음밥": ["밥", "스팸", "계란", "양파"]
    ]

    func snapshot() -> AppSnapshot {
        AppSnapshot(
            fridgeItems: fridgeItems,
            shoppingItems: shoppingItems,
            essentialItems: essentialItems
        )
    }

    func allFridgeItems() -> [FridgeItem] {
        fridgeItems.sorted { lhs, rhs in
            lhs.expiryDate < rhs.expiryDate
        }
    }

    func addFridgeItem(_ input: CreateFridgeItemRequest) -> FridgeItem {
        let item = FridgeItem(
            id: UUID(),
            name: input.name.trimmingCharacters(in: .whitespacesAndNewlines),
            category: input.category,
            addedDate: Self.todayString(),
            expiryDate: input.expiryDate
        )
        fridgeItems.append(item)
        return item
    }

    func removeFridgeItem(id: UUID) -> FridgeItem? {
        guard let index = fridgeItems.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        return fridgeItems.remove(at: index)
    }

    func allShoppingItems() -> [ShoppingItem] {
        shoppingItems
    }

    func addShoppingItem(_ input: CreateShoppingItemRequest) -> ShoppingItem? {
        let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        if shoppingItems.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return nil
        }

        let item = ShoppingItem(
            id: UUID(),
            name: name,
            reason: input.reason,
            recipeName: input.recipeName,
            checked: false
        )
        shoppingItems.append(item)
        return item
    }

    func toggleShoppingItem(id: UUID) -> ShoppingItem? {
        guard let index = shoppingItems.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        shoppingItems[index].checked.toggle()
        return shoppingItems[index]
    }

    func removeShoppingItem(id: UUID) -> ShoppingItem? {
        guard let index = shoppingItems.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        return shoppingItems.remove(at: index)
    }

    func addEssentialItem(name: String) {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        guard !essentialItems.contains(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) else { return }
        essentialItems.append(normalized)
    }

    func removeEssentialItem(name: String) {
        essentialItems.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    func recommendations() -> [RecipeRecommendation] {
        let fridgeNames = fridgeItems.map(\.name)

        return recipes.map { (name, requiredIngredients) in
            let hasCount = requiredIngredients.filter { required in
                fridgeNames.contains { owned in
                    required.localizedCaseInsensitiveContains(owned) || owned.localizedCaseInsensitiveContains(required)
                }
            }.count

            let missing = requiredIngredients.filter { required in
                !fridgeNames.contains { owned in
                    required.localizedCaseInsensitiveContains(owned) || owned.localizedCaseInsensitiveContains(required)
                }
            }

            let matchRate = Int((Double(hasCount) / Double(max(requiredIngredients.count, 1))) * 100)

            return RecipeRecommendation(
                name: name,
                matchRate: matchRate,
                missingIngredients: missing
            )
        }
        .sorted { $0.matchRate > $1.matchRate }
    }

    private static func todayString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "ko_KR")
        return formatter.string(from: Date())
    }
}
