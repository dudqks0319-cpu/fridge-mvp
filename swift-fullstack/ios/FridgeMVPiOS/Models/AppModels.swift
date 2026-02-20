import Foundation

struct FridgeItem: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var category: String
    var addedDate: String
    var expiryDate: String
}

struct CreateFridgeItemRequest: Codable {
    var name: String
    var category: String
    var expiryDate: String
}

struct ShoppingItem: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var reason: String
    var recipeName: String?
    var checked: Bool
}

struct CreateShoppingItemRequest: Codable {
    var name: String
    var reason: String
    var recipeName: String?
}

struct RecipeRecommendation: Codable, Identifiable, Hashable {
    var id: String { name }
    var name: String
    var matchRate: Int
    var missingIngredients: [String]
}

struct AddEssentialItemRequest: Codable {
    var name: String
}

struct HealthResponse: Codable {
    var status: String
}
