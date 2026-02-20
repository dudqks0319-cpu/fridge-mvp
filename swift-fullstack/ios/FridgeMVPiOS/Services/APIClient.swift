import Foundation

enum APIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case statusCode(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "API 주소가 올바르지 않습니다."
        case .invalidResponse: return "응답을 해석하지 못했습니다."
        case let .statusCode(code): return "서버 오류가 발생했습니다. (\(code))"
        }
    }
}

struct APIClient {
    var baseURL: URL

    init(baseURLString: String) throws {
        guard let url = URL(string: baseURLString) else {
            throw APIError.invalidURL
        }
        self.baseURL = url
    }

    func health() async throws -> HealthResponse {
        try await request(path: "health", method: "GET")
    }

    func fetchItems() async throws -> [FridgeItem] {
        try await request(path: "items", method: "GET")
    }

    func addItem(_ payload: CreateFridgeItemRequest) async throws -> FridgeItem {
        try await request(path: "items", method: "POST", body: payload)
    }

    func removeItem(id: UUID) async throws {
        _ = try await rawRequest(path: "items/\(id.uuidString)", method: "DELETE")
    }

    func fetchShopping() async throws -> [ShoppingItem] {
        try await request(path: "shopping", method: "GET")
    }

    func addShopping(_ payload: CreateShoppingItemRequest) async throws -> ShoppingItem {
        try await request(path: "shopping", method: "POST", body: payload)
    }

    func toggleShopping(id: UUID) async throws -> ShoppingItem {
        try await request(path: "shopping/\(id.uuidString)/toggle", method: "PATCH")
    }

    func removeShopping(id: UUID) async throws {
        _ = try await rawRequest(path: "shopping/\(id.uuidString)", method: "DELETE")
    }

    func fetchRecommendations() async throws -> [RecipeRecommendation] {
        try await request(path: "recipes/recommendations", method: "GET")
    }

    func fetchEssentialItems() async throws -> [String] {
        try await request(path: "essential", method: "GET")
    }

    func addEssentialItem(name: String) async throws {
        _ = try await rawRequest(path: "essential", method: "POST", body: AddEssentialItemRequest(name: name))
    }

    func removeEssentialItem(name: String) async throws {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        _ = try await rawRequest(path: "essential/\(encoded)", method: "DELETE")
    }

    private func request<T: Decodable>(path: String, method: String) async throws -> T {
        let data = try await rawRequest(path: path, method: method)
        let decoder = JSONDecoder()
        return try decoder.decode(T.self, from: data)
    }

    private func request<T: Decodable, B: Encodable>(path: String, method: String, body: B) async throws -> T {
        let data = try await rawRequest(path: path, method: method, body: body)
        let decoder = JSONDecoder()
        return try decoder.decode(T.self, from: data)
    }

    @discardableResult
    private func rawRequest(path: String, method: String) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw APIError.statusCode(httpResponse.statusCode)
        }

        return data
    }

    @discardableResult
    private func rawRequest<B: Encodable>(path: String, method: String, body: B) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw APIError.statusCode(httpResponse.statusCode)
        }

        return data
    }
}
