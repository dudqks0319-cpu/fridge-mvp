import Vapor

struct PantryStoreKey: StorageKey {
    typealias Value = PantryStore
}

extension Application {
    var pantryStore: PantryStore {
        guard let store = storage[PantryStoreKey.self] else {
            fatalError("PantryStore has not been configured")
        }
        return store
    }
}

public func configure(_ app: Application) throws {
    app.storage[PantryStoreKey.self] = PantryStore()

    let cors = CORSMiddleware.Configuration(
        allowedOrigin: .all,
        allowedMethods: [.GET, .POST, .PUT, .PATCH, .DELETE, .OPTIONS],
        allowedHeaders: [.accept, .authorization, .contentType, .origin, .xRequestedWith]
    )

    app.middleware.use(CORSMiddleware(configuration: cors))

    try routes(app)
}
