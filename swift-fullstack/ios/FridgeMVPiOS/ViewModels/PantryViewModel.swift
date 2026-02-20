import Foundation

@MainActor
final class PantryViewModel: ObservableObject {
    @Published var fridgeItems: [FridgeItem] = []
    @Published var shoppingItems: [ShoppingItem] = []
    @Published var recipeRecommendations: [RecipeRecommendation] = []
    @Published var essentialItems: [String] = []

    @Published var isLoading = false
    @Published var errorMessage: String?

    @Published var backendURL = UserDefaults.standard.string(forKey: "backendURL") ?? "http://127.0.0.1:8080/"

    func saveBackendURL() {
        UserDefaults.standard.set(backendURL, forKey: "backendURL")
    }

    func refreshAll() async {
        do {
            isLoading = true
            let client = try APIClient(baseURLString: backendURL)

            async let items = client.fetchItems()
            async let shopping = client.fetchShopping()
            async let recipes = client.fetchRecommendations()
            async let essentials = client.fetchEssentialItems()

            fridgeItems = try await items
            shoppingItems = try await shopping
            recipeRecommendations = try await recipes
            essentialItems = try await essentials
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func addFridgeItem(name: String, category: String, expiryDate: String) async {
        do {
            let client = try APIClient(baseURLString: backendURL)
            _ = try await client.addItem(.init(name: name, category: category, expiryDate: expiryDate))
            await refreshAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeFridgeItem(_ item: FridgeItem) async {
        do {
            let client = try APIClient(baseURLString: backendURL)
            try await client.removeItem(id: item.id)
            await refreshAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addShoppingItem(name: String, reason: String, recipeName: String? = nil) async {
        do {
            let client = try APIClient(baseURLString: backendURL)
            _ = try await client.addShopping(.init(name: name, reason: reason, recipeName: recipeName))
            await refreshAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleShoppingItem(_ item: ShoppingItem) async {
        do {
            let client = try APIClient(baseURLString: backendURL)
            _ = try await client.toggleShopping(id: item.id)
            await refreshAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeShoppingItem(_ item: ShoppingItem) async {
        do {
            let client = try APIClient(baseURLString: backendURL)
            try await client.removeShopping(id: item.id)
            await refreshAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addEssential(name: String) async {
        do {
            let client = try APIClient(baseURLString: backendURL)
            try await client.addEssentialItem(name: name)
            await refreshAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeEssential(name: String) async {
        do {
            let client = try APIClient(baseURLString: backendURL)
            try await client.removeEssentialItem(name: name)
            await refreshAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
