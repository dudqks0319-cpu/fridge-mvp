import Vapor

struct FridgeItem: Content, Identifiable, Equatable {
    let id: UUID
    var name: String
    var category: String
    var addedDate: String
    var expiryDate: String
}

struct CreateFridgeItemRequest: Content {
    var name: String
    var category: String
    var expiryDate: String
}

struct ShoppingItem: Content, Identifiable, Equatable {
    let id: UUID
    var name: String
    var reason: String
    var recipeName: String?
    var checked: Bool
}

struct CreateShoppingItemRequest: Content {
    var name: String
    var reason: String
    var recipeName: String?
}

struct RecipeRecommendation: Content, Identifiable {
    var id: String { name }
    var name: String
    var matchRate: Int
    var missingIngredients: [String]
}

struct AddEssentialItemRequest: Content {
    var name: String
}

struct AppSnapshot: Content {
    var fridgeItems: [FridgeItem]
    var shoppingItems: [ShoppingItem]
    var essentialItems: [String]
}
