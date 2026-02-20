import Vapor

public func routes(_ app: Application) throws {
    app.get("health") { _ in
        ["status": "ok"]
    }

    app.get("snapshot") { req async throws -> AppSnapshot in
        await req.application.pantryStore.snapshot()
    }

    // Fridge items
    app.get("items") { req async throws -> [FridgeItem] in
        await req.application.pantryStore.allFridgeItems()
    }

    app.post("items") { req async throws -> FridgeItem in
        let input = try req.content.decode(CreateFridgeItemRequest.self)
        guard !input.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Abort(.badRequest, reason: "name is required")
        }
        return await req.application.pantryStore.addFridgeItem(input)
    }

    app.delete("items", ":id") { req async throws -> HTTPStatus in
        guard let id = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid id")
        }

        guard let removed = await req.application.pantryStore.removeFridgeItem(id: id) else {
            throw Abort(.notFound)
        }

        _ = await req.application.pantryStore.addShoppingItem(
            .init(name: removed.name, reason: "재료 소진", recipeName: nil)
        )

        return .ok
    }

    // Shopping
    app.get("shopping") { req async throws -> [ShoppingItem] in
        await req.application.pantryStore.allShoppingItems()
    }

    app.post("shopping") { req async throws -> ShoppingItem in
        let input = try req.content.decode(CreateShoppingItemRequest.self)

        guard let item = await req.application.pantryStore.addShoppingItem(input) else {
            throw Abort(.badRequest, reason: "Invalid item or duplicate")
        }

        return item
    }

    app.patch("shopping", ":id", "toggle") { req async throws -> ShoppingItem in
        guard let id = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid id")
        }

        guard let item = await req.application.pantryStore.toggleShoppingItem(id: id) else {
            throw Abort(.notFound)
        }

        return item
    }

    app.delete("shopping", ":id") { req async throws -> HTTPStatus in
        guard let id = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid id")
        }

        guard await req.application.pantryStore.removeShoppingItem(id: id) != nil else {
            throw Abort(.notFound)
        }

        return .ok
    }

    // Recommendations
    app.get("recipes", "recommendations") { req async throws -> [RecipeRecommendation] in
        await req.application.pantryStore.recommendations()
    }

    // Essential ingredients
    app.get("essential") { req async throws -> [String] in
        await req.application.pantryStore.snapshot().essentialItems
    }

    app.post("essential") { req async throws -> HTTPStatus in
        let input = try req.content.decode(AddEssentialItemRequest.self)
        await req.application.pantryStore.addEssentialItem(name: input.name)
        return .ok
    }

    app.delete("essential", ":name") { req async throws -> HTTPStatus in
        guard let name = req.parameters.get("name") else {
            throw Abort(.badRequest, reason: "name is required")
        }
        await req.application.pantryStore.removeEssentialItem(name: name)
        return .ok
    }
}
