@testable import App
import XCTVapor

final class AppTests: XCTestCase {
    func testHealthRoute() async throws {
        let app = Application(.testing)
        defer { app.shutdown() }

        try configure(app)

        try app.test(.GET, "health") { res in
            XCTAssertEqual(res.status, .ok)
            XCTAssertTrue(res.body.string.contains("ok"))
        }
    }

    func testAddAndReadItem() async throws {
        let app = Application(.testing)
        defer { app.shutdown() }

        try configure(app)

        let payload = CreateFridgeItemRequest(name: "계란", category: "유제품", expiryDate: "2026-02-28")

        try app.test(.POST, "items", beforeRequest: { req in
            try req.content.encode(payload)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
        })

        try app.test(.GET, "items") { res in
            XCTAssertEqual(res.status, .ok)
            let items = try res.content.decode([FridgeItem].self)
            XCTAssertEqual(items.count, 1)
            XCTAssertEqual(items.first?.name, "계란")
        }
    }
}
