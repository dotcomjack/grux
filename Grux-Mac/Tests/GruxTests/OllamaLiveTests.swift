import XCTest
@testable import Grux

// Live integration smoke test for the Phase 1 offline path. SKIPPED unless
// GRUX_OLLAMA_LIVE=1 and a local Ollama is serving the model (default
// llama3.2:3b), so the normal `swift test` / CI run is unaffected. Exercises the
// real OpenAICompatBackend SSE -> ClaudeStreamEvent mapping, including the
// tool_calls accumulation path the offline chat loop depends on.
final class OllamaLiveTests: XCTestCase {

    private func makeBackend() -> OpenAICompatBackend {
        let url = ProcessInfo.processInfo.environment["GRUX_OLLAMA_URL"] ?? "http://localhost:11434"
        return OpenAICompatBackend(baseURL: url)
    }
    private var model: String {
        ProcessInfo.processInfo.environment["GRUX_OLLAMA_MODEL"] ?? "llama3.2:3b"
    }
    private func skipUnlessLive() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GRUX_OLLAMA_LIVE"] == "1",
                          "set GRUX_OLLAMA_LIVE=1 with a local Ollama to run")
    }

    // Plain streaming: server -> textDelta* -> messageStop.
    func test_liveStreamText() async throws {
        try skipUnlessLive()
        let stream = await makeBackend().streamCompleteWithTools(
            apiKey: "ollama", model: model, systemBlocks: [],
            messages: [["role": "user", "content": "Reply with exactly: pong"]],
            tools: [], maxTokens: 64, temperature: 0,
            spanName: "test.stream", feature: "test")
        var text = ""; var sawStop = false
        for try await ev in stream {
            switch ev {
            case .textDelta(let t): text += t
            case .messageStop: sawStop = true
            default: break
            }
        }
        print("[OllamaLive] text=\(text.debugDescription) sawStop=\(sawStop)")
        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "expected streamed text from the local model")
        XCTAssertTrue(sawStop, "expected a messageStop event")
    }

    // Tool-call mapping: tool_calls deltas -> toolUseStart -> InputDelta* ->
    // toolUseStop with the accumulated arguments parsed to a [String: Any].
    func test_liveToolCallMapping() async throws {
        try skipUnlessLive()
        let weather = ClaudeTool(
            name: "get_weather",
            description: "Get the current weather for a given city.",
            inputSchema: [
                "type": "object",
                "properties": ["city": ["type": "string", "description": "City name"]],
                "required": ["city"]
            ])
        let stream = await makeBackend().streamCompleteWithTools(
            apiKey: "ollama", model: model, systemBlocks: [],
            messages: [["role": "user",
                        "content": "What is the weather in Lisbon? Call the get_weather tool with city set to Lisbon."]],
            tools: [weather], maxTokens: 256, temperature: 0,
            spanName: "test.tool", feature: "test")
        var sawToolStart = false, sawToolStop = false
        var toolName = "", partialArgs = "", text = ""
        var finalInput: [String: Any] = [:]
        for try await ev in stream {
            switch ev {
            case .toolUseStart(_, let name): sawToolStart = true; toolName = name
            case .toolUseInputDelta(let p): partialArgs += p
            case .toolUseStop(_, let name, let input): sawToolStop = true; toolName = name; finalInput = input
            case .textDelta(let t): text += t
            default: break
            }
        }
        print("[OllamaLive] toolStart=\(sawToolStart) toolStop=\(sawToolStop) name=\(toolName) input=\(finalInput) partialArgs=\(partialArgs.debugDescription) text=\(text.debugDescription)")
        XCTAssertTrue(sawToolStart, "expected a tool_call delta to map to toolUseStart")
        XCTAssertEqual(toolName, "get_weather")
        XCTAssertTrue(sawToolStop, "expected a toolUseStop closing the tool call")
        let city = (finalInput["city"] as? String) ?? ""
        XCTAssertFalse(city.isEmpty, "accumulated tool arguments should parse to a non-empty city")
    }
}
