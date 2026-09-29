import XCTest
@testable import Grux

@MainActor
final class CustomEndpointModelIdTests: XCTestCase {
    private func tempStore() -> CustomEndpointStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-endpoints-\(UUID().uuidString).json")
        return CustomEndpointStore(fileURL: url)
    }

    func test_modelId_roundTripsAndClearsWhenBlank() {
        let store = tempStore()
        let ep = store.add(name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", apiKey: nil)!
        XCTAssertNil(store.endpoint(id: ep.id)?.modelId)
        store.setModelId("deepseek/deepseek-v4-flash-0731", for: ep.id)
        XCTAssertEqual(store.endpoint(id: ep.id)?.modelId, "deepseek/deepseek-v4-flash-0731")
        store.setModelId("   ", for: ep.id)
        XCTAssertNil(store.endpoint(id: ep.id)?.modelId)
    }

    func test_openRouterShape_onlyForOpenRouterAndDeepSeek() {
        let body: [String: Any] = ["model": "deepseek/deepseek-v4-flash-0731", "messages": []]
        let shaped = OpenAICompatBackend.shaped(body, baseURL: "https://openrouter.ai/api/v1")
        XCTAssertNotNil(shaped["provider"])
        XCTAssertEqual((shaped["reasoning"] as? [String: Bool])?["enabled"], false)
        let local = OpenAICompatBackend.shaped(body, baseURL: "http://localhost:11434")
        XCTAssertNil(local["provider"])
        let other: [String: Any] = ["model": "openai/gpt-5-mini", "messages": []]
        XCTAssertNil(OpenAICompatBackend.shaped(other, baseURL: "https://openrouter.ai/api/v1")["provider"])
    }
}
