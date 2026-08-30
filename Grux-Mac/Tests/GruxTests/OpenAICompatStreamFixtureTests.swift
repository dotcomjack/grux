import XCTest
@testable import Grux

/// Executed coverage for `OpenAICompatBackend.streamCompleteWithTools`, the SSE
/// parser every bring-your-own-key turn runs through.
///
/// ## Why this file exists
///
/// Before it, that parser had NO executed coverage on any machine, ever.
/// `OllamaLiveTests` skips unless `GRUX_OLLAMA_LIVE=1` and a local server is
/// serving a model, `LiveVerificationTests` skips unless `GRUX_LIVE=1`, and CI
/// sets neither. A skipped test reports green, so the suite said the offline
/// chat path was covered while every assertion in it was being stepped over.
/// The tool-call accumulator, the double-close guard, the usage chunk and the
/// thinking-budget diagnosis were all shipping unexecuted.
///
/// ## Why a loopback socket and not URLProtocol
///
/// The obvious move is a `URLProtocol` subclass registered with
/// `URLProtocol.registerClass`, which needs no socket and no server. It does
/// not work here, and that was MEASURED rather than assumed before this file
/// was written: a probe registering a stub protocol class, then issuing
/// `session.bytes(for:)` on a `URLSession(configuration: .default)` built
/// exactly the way the backend builds its own, went straight past the stub to
/// real DNS and failed with `NSURLErrorDomain Code=-1003 "A server with the
/// specified hostname could not be found"`. `registerClass` populates a global
/// registry that `URLSession` does not consult; a session only honours custom
/// protocol classes set on `configuration.protocolClasses`, and the backend
/// builds its `URLSession` privately inside `init(baseURL:)` with no seam to
/// pass one in.
///
/// Reimplementing the parser in the test was the other option on the table and
/// is worse than no test at all, because it reports coverage of production code
/// that is still never executed. So the fixture goes on the wire instead: a
/// throwaway HTTP server bound to `127.0.0.1` on an ephemeral port, inside the
/// test process, serving canned SSE bytes. No external server, no external
/// network, no model, deterministic, and the bytes travel through the real
/// `URLSession`, the real `bytes.lines` splitting and the real event mapping.
/// The measured cost of the whole mechanism in a standalone probe was under a
/// second including compile.
///
/// The one thing this still cannot reach without a production change is the
/// backend's own `URLSession` configuration (timeouts, headers as the server
/// never echoes them back). Adding `init(baseURL:session: URLSession =
/// <the current one>)` would make that injectable, and would also let these
/// fixtures run with no socket at all.
final class OpenAICompatStreamFixtureTests: XCTestCase {

    // MARK: - Fixture wire format

    /// Wraps one JSON payload in the frame shape a compat server actually puts
    /// on the wire: a `data: ` prefix and a blank line terminating the event.
    /// Written as a helper so every fixture below is readable JSON rather than
    /// a wall of escaped quotes.
    private static func frame(_ json: String) -> String { "data: \(json)\n\n" }

    private static let doneSentinel = "data: [DONE]\n\n"

    // MARK: - Draining

    /// One flattened record of everything a stream emitted, in order.
    ///
    /// `ClaudeStreamEvent` is not `Equatable` and carries `[String: Any]`, so
    /// order is asserted against a string rendering (which gives a readable
    /// diff on failure) and the parsed tool input is captured separately for
    /// the assertions that care about the object rather than the sequence.
    private struct Drained {
        var order: [String] = []
        var text = ""
        var toolInputs: [(id: String, input: [String: Any])] = []
    }

    private static func label(_ event: ClaudeStreamEvent) -> String {
        switch event {
        case .textBlockStart:                  return "textBlockStart"
        case .textDelta(let t):                return "textDelta(\(t))"
        case .textBlockStop:                   return "textBlockStop"
        case .toolUseStart(let id, let name):  return "toolUseStart(\(id),\(name))"
        case .toolUseInputDelta(let partial):  return "toolUseInputDelta(\(partial))"
        case .toolUseStop(let id, let name, _): return "toolUseStop(\(id),\(name))"
        case .messageStop(let reason):         return "messageStop(\(reason ?? "nil"))"
        }
    }

    /// Serves `frames`, runs one streamed turn against them, and returns
    /// everything the backend yielded.
    ///
    /// The drain runs to completion rather than under a watchdog, because the
    /// fixture cannot leave the parser waiting: the response carries an exact
    /// `Content-Length` and the connection is closed after the last frame, so
    /// `bytes.lines` always terminates. Draining fully also matters for a
    /// second reason. `streamCompleteWithTools` holds `LocalModelGate` for the
    /// life of the stream and releases it in a `defer`, so abandoning a stream
    /// half read would leave the gate held and hang every later streaming test
    /// at `acquire()`.
    private func runStream(frames: [String],
                           tools: [ClaudeTool] = []) async throws
        -> (Drained, OpenAICompatBackend, SSEFixtureServer) {
        let server = SSEFixtureServer(frames: frames)
        try server.start()
        let backend = OpenAICompatBackend(baseURL: server.baseURL)
        let stream = await backend.streamCompleteWithTools(
            apiKey: "fixture", model: "fixture-model", systemBlocks: [],
            messages: [["role": "user", "content": "fixture"]],
            tools: tools, maxTokens: 64, temperature: 0,
            spanName: "test.stream", feature: "test")

        var out = Drained()
        for try await event in stream {
            out.order.append(Self.label(event))
            if case .textDelta(let t) = event { out.text += t }
            if case .toolUseStop(let id, _, let input) = event {
                out.toolInputs.append((id: id, input: input))
            }
        }
        return (out, backend, server)
    }

    // MARK: - Plain text

    /// Text arriving across several `data:` frames maps to exactly one text
    /// block, one delta per frame, and a `messageStop` carrying the server's
    /// `finish_reason`.
    ///
    /// The leading role frame with `content: ""` is what a compat server really
    /// sends first, and it must NOT open a text block: the production guard is
    /// `!txt.isEmpty`, and without it every turn would start with an empty
    /// `textBlockStart`/`textDelta` pair that `ChatService` would record as a
    /// blank assistant block.
    func test_plainTextStreamYieldsExactEventOrder() async throws {
        let frames = [
            Self.frame(#"{"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}"#),
            Self.frame(#"{"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"Pin"},"finish_reason":null}]}"#),
            Self.frame(#"{"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"g "},"finish_reason":null}]}"#),
            Self.frame(#"{"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"back."},"finish_reason":null}]}"#),
            Self.frame(#"{"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#),
            Self.doneSentinel,
        ]
        let (out, _, server) = try await runStream(frames: frames)
        defer { server.stop() }

        XCTAssertEqual(out.order, [
            "textBlockStart",
            "textDelta(Pin)",
            "textDelta(g )",
            "textDelta(back.)",
            "textBlockStop",
            "messageStop(stop)",
        ])
        XCTAssertEqual(out.text, "Ping back.")
        // Proves the fixture really served THIS backend's request rather than
        // the test accidentally asserting on something it built itself.
        XCTAssertEqual(server.requestLine, "POST /v1/chat/completions HTTP/1.1")
    }

    // MARK: - Tool calls

    /// `function.arguments` split across frames reassembles into one parsed
    /// input object, with one `toolUseStart` and one `toolUseStop`.
    ///
    /// This also proves the double-close guard. `finish_reason: "tool_calls"`
    /// closes every open tool block inside the loop, and then the stream-end
    /// path closes them AGAIN a few lines later. The only thing standing
    /// between that and a duplicated tool dispatch is `acc.started` being
    /// cleared by `finishToolCall`, so the assertion that matters here is that
    /// exactly one `toolUseStop` came out, not just that one came out.
    func test_toolCallArgumentsReassembleAcrossFragments() async throws {
        let frames = [
            Self.frame(#"{"choices":[{"index":0,"delta":{"role":"assistant","content":null,"tool_calls":[{"index":0,"id":"call_wx1","type":"function","function":{"name":"get_weather","arguments":""}}]}}]}"#),
            Self.frame(#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"ci"}}]}}]}"#),
            Self.frame(#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ty\": \"Li"}}]}}]}"#),
            Self.frame(#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"sbon\"}"}}]}}]}"#),
            Self.frame(#"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#),
            Self.doneSentinel,
        ]
        let (out, _, server) = try await runStream(frames: frames)
        defer { server.stop() }

        XCTAssertEqual(out.order, [
            "toolUseStart(call_wx1,get_weather)",
            #"toolUseInputDelta({"ci)"#,
            #"toolUseInputDelta(ty": "Li)"#,
            #"toolUseInputDelta(sbon"})"#,
            "toolUseStop(call_wx1,get_weather)",
            "messageStop(tool_calls)",
        ])
        XCTAssertEqual(out.order.filter { $0.hasPrefix("toolUseStop") }.count, 1,
                       "the stream-end close ran a second time and the acc.started guard did not hold")
        XCTAssertEqual(out.toolInputs.count, 1)
        XCTAssertEqual(out.toolInputs.first?.input["city"] as? String, "Lisbon",
                       "the fragments did not reassemble into parseable JSON")
        XCTAssertEqual(server.requestLine, "POST /v1/chat/completions HTTP/1.1")
    }

    /// Two tool calls streaming at once, at different `index` values, with
    /// their argument fragments interleaved.
    ///
    /// The accumulator is keyed by index precisely so interleaving cannot
    /// splice one call's arguments into the other, which would produce two
    /// unparseable inputs and a silently dropped tool dispatch. The stops come
    /// out in index order because `finishToolCall` walks `keys.sorted()`.
    ///
    /// Note the deltas: `toolUseInputDelta` carries no index or id, so a
    /// consumer cannot attribute a fragment to a call. That is harmless today
    /// because `ChatService` ignores those deltas entirely and builds its input
    /// from `toolUseStop`, and the assertion below pins the wire order rather
    /// than pretending the events are attributable.
    func test_twoConcurrentToolCallsAtDifferentIndexes() async throws {
        let frames = [
            Self.frame(#"{"choices":[{"index":0,"delta":{"role":"assistant","content":null,"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"read_file","arguments":""}},{"index":1,"id":"call_b","type":"function","function":{"name":"list_dir","arguments":""}}]}}]}"#),
            Self.frame(#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"path\":"}}]}}]}"#),
            Self.frame(#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"function":{"arguments":"{\"dir\":"}}]}}]}"#),
            Self.frame(#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":" \"notes.txt\"}"}}]}}]}"#),
            Self.frame(#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"function":{"arguments":" \"src\"}"}}]}}]}"#),
            Self.frame(#"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#),
            Self.doneSentinel,
        ]
        let (out, _, server) = try await runStream(frames: frames)
        defer { server.stop() }

        XCTAssertEqual(out.order, [
            "toolUseStart(call_a,read_file)",
            "toolUseStart(call_b,list_dir)",
            #"toolUseInputDelta({"path":)"#,
            #"toolUseInputDelta({"dir":)"#,
            #"toolUseInputDelta( "notes.txt"})"#,
            #"toolUseInputDelta( "src"})"#,
            "toolUseStop(call_a,read_file)",
            "toolUseStop(call_b,list_dir)",
            "messageStop(tool_calls)",
        ])
        XCTAssertEqual(out.toolInputs.count, 2)
        XCTAssertEqual(out.toolInputs.first(where: { $0.id == "call_a" })?.input["path"] as? String, "notes.txt",
                       "index 0 picked up index 1's fragments")
        XCTAssertEqual(out.toolInputs.first(where: { $0.id == "call_b" })?.input["dir"] as? String, "src",
                       "index 1 picked up index 0's fragments")
    }

    /// The other half of the double-close guard: a server that never sends
    /// `finish_reason` at all.
    ///
    /// Local servers do end this way, and if only the in-loop close existed the
    /// tool block would never be emitted and the turn would end having decided
    /// to call a tool without ever telling `ChatService` about it. Here the
    /// stream-end path is the ONLY thing that can produce the stop, so a
    /// missing `toolUseStop` means that path is dead. `stopReason` is `nil` for
    /// the same reason, which is the value `ChatService` sees when a compat
    /// server truncates.
    func test_streamEndClosesToolBlockWhenNoFinishReasonArrives() async throws {
        let frames = [
            Self.frame(#"{"choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_z","type":"function","function":{"name":"scan_tree","arguments":"{\"depth\": 2}"}}]}}]}"#),
            Self.doneSentinel,
        ]
        let (out, _, server) = try await runStream(frames: frames)
        defer { server.stop() }

        XCTAssertEqual(out.order, [
            "toolUseStart(call_z,scan_tree)",
            #"toolUseInputDelta({"depth": 2})"#,
            "toolUseStop(call_z,scan_tree)",
            "messageStop(nil)",
        ])
        XCTAssertEqual(out.toolInputs.first?.input["depth"] as? Int, 2)
    }

    // MARK: - Usage

    /// A final chunk carrying `usage` and an EMPTY `choices` array lands in the
    /// usage snapshot.
    ///
    /// This is the shape a server sends when `stream_options.include_usage` is
    /// set, which the backend always sets. The parser reads `usage` BEFORE it
    /// guards on `choices.first`, and that ordering is the whole test: move the
    /// usage read below the guard and every offline turn silently reports zero
    /// tokens, because the only chunk that carries usage is the only chunk with
    /// no choices in it. Local servers report no cache tokens, so those stay 0.
    func test_usageOnlyFinalChunkLandsTokenCounts() async throws {
        let frames = [
            Self.frame(#"{"choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":null}]}"#),
            Self.frame(#"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#),
            Self.frame(#"{"id":"c9","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":137,"completion_tokens":9,"total_tokens":146}}"#),
            Self.doneSentinel,
        ]
        let (out, backend, server) = try await runStream(frames: frames)
        defer { server.stop() }

        XCTAssertEqual(out.text, "ok")
        let usage = await backend.usageSnapshot()
        XCTAssertEqual(usage.input, 137)
        XCTAssertEqual(usage.output, 9)
        XCTAssertEqual(usage.cacheCreate, 0)
        XCTAssertEqual(usage.cacheRead, 0)
    }

    // MARK: - The sentinel

    /// `data: [DONE]` ends parsing, and anything after it is not read.
    ///
    /// Asserted by planting two frames AFTER the sentinel that would both be
    /// visible if it were ignored: another text delta, and a `finish_reason`.
    /// A parser that treated `[DONE]` as just another unparseable payload and
    /// carried on would append the extra text and report a stop reason of
    /// "stop" instead of nil, so both assertions fail loudly rather than the
    /// test quietly passing for the wrong reason.
    func test_doneSentinelStopsParsing() async throws {
        let frames = [
            Self.frame(#"{"choices":[{"index":0,"delta":{"content":"first"},"finish_reason":null}]}"#),
            Self.doneSentinel,
            Self.frame(#"{"choices":[{"index":0,"delta":{"content":"AFTER-THE-SENTINEL"},"finish_reason":null}]}"#),
            Self.frame(#"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#),
        ]
        let (out, _, server) = try await runStream(frames: frames)
        defer { server.stop() }

        XCTAssertEqual(out.text, "first")
        XCTAssertFalse(out.text.contains("AFTER-THE-SENTINEL"),
                       "parsing continued past the [DONE] sentinel")
        XCTAssertEqual(out.order, [
            "textBlockStart",
            "textDelta(first)",
            "textBlockStop",
            "messageStop(nil)",
        ])
    }

    // MARK: - Thinking budget

    /// A reasoning model that spent its whole budget thinking returns empty
    /// `content` beside a full `reasoning` field, and that must surface as the
    /// shared diagnosis rather than as an empty answer.
    ///
    /// The production comment records the measurement this defends: qwen3.5:4b
    /// through this exact endpoint, 14.3 seconds, 2,433 characters of reasoning
    /// and `content` empty, twice in a row, at a budget that had answered fine
    /// minutes earlier. Without the check the user waits and then gets nothing
    /// at all, with no way to tell whether the app broke or the model did.
    ///
    /// Asserted against `OpenAICompatBackend.thinkingBudgetMessage` itself
    /// rather than a copy of the sentence, because the point of that constant
    /// is that the two call sites cannot drift, and a test holding its own copy
    /// would let all three drift together.
    func test_thinkingBudgetErrorCarriesTheSharedMessage() async throws {
        let body = #"""
        {"id":"cmpl-1","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"","reasoning":"The user wants a short answer. Let me consider the options carefully before I commit to one, weighing each in turn, and then reconsider all of them again from the start."},"finish_reason":"stop"}],"usage":{"prompt_tokens":42,"completion_tokens":800}}
        """#
        let server = SSEFixtureServer(frames: [body], contentType: "application/json")
        try server.start()
        defer { server.stop() }

        let backend = OpenAICompatBackend(baseURL: server.baseURL)
        do {
            let answer = try await backend.complete(
                apiKey: "fixture", model: "fixture-model", system: nil,
                messages: [ClaudeMessage(role: "user", content: "hi")])
            XCTFail("expected the thinking budget diagnosis, got \(answer.debugDescription)")
        } catch let error as ClaudeError {
            guard case .http(let code, let text) = error else {
                return XCTFail("expected ClaudeError.http, got \(error)")
            }
            // 200 on purpose: the server answered fine, the MODEL returned
            // nothing, and pretending it was a transport failure would send the
            // caller down a retry path that cannot help.
            XCTAssertEqual(code, 200)
            XCTAssertEqual(text, OpenAICompatBackend.thinkingBudgetMessage)
        }
    }

    // MARK: - Vision error classification

    /// Serves one canned non-2xx body to `completeVision` and hands back the
    /// error it threw.
    ///
    /// Returns an optional and fails the test itself on the two ways this can
    /// go wrong that would otherwise make every assertion below vacuous: the
    /// fixture never starting, and the call RETURNING instead of throwing. A
    /// helper that quietly handed back `nil` in those cases would let this
    /// whole section report green while asserting on nothing.
    private func visionError(status: Int, body: String,
                             file: StaticString = #filePath, line: UInt = #line) async -> Error? {
        let server = SSEFixtureServer(frames: [body], statusCode: status,
                                      contentType: "application/json")
        do {
            try server.start()
        } catch {
            XCTFail("the fixture server did not start: \(error)", file: file, line: line)
            return nil
        }
        defer { server.stop() }

        let backend = OpenAICompatBackend(baseURL: server.baseURL)
        do {
            // A two-marker JPEG: SOI then EOI. The backend only base64 encodes
            // it, so the smallest thing that is honestly a JPEG will do.
            let answer = try await backend.completeVision(
                apiKey: "fixture", model: "fixture-model", system: nil,
                userText: "what is on this screen",
                imageJPEG: Data([0xFF, 0xD8, 0xFF, 0xD9]))
            XCTFail("HTTP \(status) returned \(answer.debugDescription) instead of throwing",
                    file: file, line: line)
            return nil
        } catch {
            return error
        }
    }

    /// The status codes that are about THE CALL keep their own status and the
    /// provider's own sentence, and must not read as a missing feature.
    ///
    /// This is the regression this section exists for. `completeVision` used to
    /// answer every non-2xx with `http(400, "vision unsupported by local
    /// backend")`, so a rejected key, a key without access, a rate limit and a
    /// provider outage were four different problems wearing one sentence, and
    /// the sentence named none of them. Someone whose key had expired was told
    /// their model cannot see images, went and changed models, and arrived at
    /// the same failure with one more wrong belief about the product.
    ///
    /// 503 is in the table because a provider outage was one of the three
    /// mislabels by name, and because a five-hundred passing through is what
    /// proves the guard is a small allowlist rather than a slightly larger one.
    ///
    /// The second half of each case is the sentence a PERSON reads, not the
    /// enum: an error that classifies correctly and still renders as the wrong
    /// advice has fixed nothing.
    func test_visionCallFailuresKeepTheirStatusInsteadOfReadingAsUnsupportedVision() async {
        // The error envelope every OpenAI-compatible server sends, and the same
        // shape `ChatService.providerMessage` already reads on the chat path.
        // One reader serves both surfaces so the two cannot drift apart.
        let cases: [(status: Int, sentence: String)] = [
            (401, "Incorrect API key provided. Check the key and try again."),
            (403, "Your key does not have access to this model."),
            (429, "Rate limit reached for requests. Try again in 20 seconds."),
            (503, "The server is overloaded right now. Please retry shortly."),
        ]

        for c in cases {
            let body = #"{"error":{"message":"\#(c.sentence)","type":"invalid_request_error","code":null}}"#
            guard let error = await visionError(status: c.status, body: body) else { continue }
            guard case ClaudeError.http(let code, let text) = error else {
                XCTFail("HTTP \(c.status) threw \(error) instead of ClaudeError.http")
                continue
            }
            XCTAssertEqual(code, c.status,
                           "HTTP \(c.status) was rewritten to \(code), so the caller cannot tell it apart")
            XCTAssertEqual(text, c.sentence,
                           "the provider wrote a sentence for the user and HTTP \(c.status) discarded it")
            XCTAssertNotEqual(text, OpenAICompatBackend.visionUnsupportedMessage,
                              "HTTP \(c.status) still degrades to the vision message")

            // The stranger's surface. Asserted through the same function the
            // chat bubble renders with, so this cannot pass while the delivered
            // line still says the model cannot see.
            let shown = ChatService.humanMessage(for: error)
            XCTAssertTrue(shown.contains("HTTP \(c.status)"),
                          "the shown sentence does not name the status: \(shown)")
            XCTAssertFalse(shown.lowercased().contains("vision"),
                           "HTTP \(c.status) reads to the user as a vision problem: \(shown)")
        }
    }

    /// 400 and 422 keep the degrade, because those two really do mean the model
    /// read the request and rejected its shape.
    ///
    /// 422 normalizes to 400 on purpose: `VisionTool` and `FocusWatcher` both
    /// document `http(400, ...)` as the contract they degrade on, so which of
    /// the two codes a given server picked must not change what the caller
    /// sees. The contract is the STATUS; the MESSAGE keeps the provider's own
    /// sentence. Both cases carry a provider sentence that names the picture,
    /// which is what CHOOSES the degrade rather than the status doing it
    /// alone (see the context-length case below).
    ///
    /// Asserted against `OpenAICompatBackend.visionUnsupportedMessage` rather
    /// than a copy of the sentence, for the reason the thinking-budget test
    /// gives above: a test holding its own copy lets both drift together.
    func test_visionShapeRejectionsKeepTheDegrade() async {
        for status in [400, 422] {
            let sentence = "This model does not support image input."
            let body = #"{"error":{"message":"\#(sentence)","type":"invalid_request_error"}}"#
            guard let error = await visionError(status: status, body: body) else { continue }
            guard case ClaudeError.http(let code, let text) = error else {
                XCTFail("HTTP \(status) threw \(error) instead of ClaudeError.http")
                continue
            }
            XCTAssertEqual(code, 400,
                           "HTTP \(status) must reach the caller as the 400 contract they degrade on")
            XCTAssertTrue(text.hasPrefix(OpenAICompatBackend.visionUnsupportedMessage),
                          "HTTP \(status) lost the degrade the callers depend on: \(text)")
            XCTAssertTrue(text.contains(sentence),
                          "HTTP \(status) discarded the provider's own sentence, which is "
                          + "the one actionable line for a 400 that is really a context "
                          + "or payload rejection: \(text)")
        }
    }

    /// A 400 that is really a CONTEXT-LENGTH rejection must not wear the
    /// vision degrade, and this is the wrong-cause shape that survived the
    /// first fix. Compat servers use 400 for a blown context window and for
    /// an oversized payload, so keying the degrade on the status alone
    /// composed "vision unsupported by local backend. The provider said: This
    /// model's maximum context length is 4096 tokens", which tells the reader
    /// to change models in its first clause and to shorten the prompt in its
    /// second. Only one of those is true, and the sentence the SERVER wrote
    /// is the one that is.
    ///
    /// 422 is in the table for the same reason it is in the degrade's: which
    /// of the two codes a server picked must not decide what the reader is
    /// told. Here the status passes through unchanged, because there is no
    /// degrade to normalize toward.
    func test_aContextLengthRejectionKeepsItsOwnSentenceAndNotTheVisionDegrade() async {
        let sentence = "This model's maximum context length is 4096 tokens, "
            + "however you requested 8192 tokens."
        for status in [400, 422] {
            let body = #"{"error":{"message":"\#(sentence)","type":"invalid_request_error"}}"#
            guard let error = await visionError(status: status, body: body) else { continue }
            guard case ClaudeError.http(let code, let text) = error else {
                XCTFail("HTTP \(status) threw \(error) instead of ClaudeError.http")
                continue
            }
            XCTAssertEqual(code, status,
                           "HTTP \(status) was rewritten to \(code); with no degrade applied "
                           + "there is nothing to normalize toward the 400 contract")
            XCTAssertEqual(text, sentence,
                           "the one actionable line was replaced or padded: \(text)")
            XCTAssertFalse(text.contains(OpenAICompatBackend.visionUnsupportedMessage),
                           "a context-length rejection still reads as a missing capability, "
                           + "which sends the reader to change models when the fix is to "
                           + "shorten the prompt: \(text)")

            // The stranger's surface: the sentence a person actually reads.
            let shown = ChatService.humanMessage(for: error)
            XCTAssertFalse(shown.lowercased().contains("vision"),
                           "HTTP \(status) reads to the user as a vision problem: \(shown)")
        }
    }

    /// The degrade with NOTHING quotable in the body stays byte-identical to
    /// the constant: with no provider sentence there is nothing to append,
    /// and inventing one would be the backfilled guess this section bans. It
    /// is also the case the keyword heuristic cannot judge, so the status is
    /// the only evidence there is and the degrade stands on it.
    func test_visionShapeRejectionWithNoProviderSentenceIsExactlyTheConstant() async {
        guard let error = await visionError(status: 400, body: "Bad Request") else { return }
        guard case ClaudeError.http(let code, let text) = error else {
            return XCTFail("expected ClaudeError.http, got \(error)")
        }
        XCTAssertEqual(code, 400)
        XCTAssertEqual(text, OpenAICompatBackend.visionUnsupportedMessage,
                       "with no provider sentence the degrade must be the bare constant")
    }

    /// A failure whose body has no sentence to quote still keeps its status.
    ///
    /// Plenty of proxies answer with plain text, or with nothing at all, and
    /// this is the branch that runs when `ChatService.providerMessage` finds no
    /// `error.message` to lift. Nothing is invented to fill the gap, because a
    /// backfilled guess is the defect this whole section is about, and the
    /// status alone is already enough for `humanMessage` to say something true.
    func test_visionFailureWithNoProviderSentenceStillKeepsItsStatus() async {
        guard let error = await visionError(status: 401, body: "Unauthorized") else { return }
        guard case ClaudeError.http(let code, let text) = error else {
            return XCTFail("expected ClaudeError.http, got \(error)")
        }
        XCTAssertEqual(code, 401)
        XCTAssertEqual(text, "Unauthorized",
                       "the body was replaced rather than passed through")
        XCTAssertTrue(ChatService.humanMessage(for: error).contains("HTTP 401"),
                      "a bodyless rejection lost the one fact it had")
    }

    /// A proxy that answers the vision POST with 200 and an HTML error page.
    ///
    /// The dictionary-cast guard cannot catch this one: JSONSerialization
    /// throws its own NSError on a non-JSON body before the cast ever runs,
    /// and with the old catch-all gone that raw error reached the user as "The
    /// data couldn't be read because it isn't in the correct format", with no
    /// status and no action in it. The backend must name the condition itself.
    func test_visionOkStatusWithNonJSONBodyThrowsDecoding() async {
        let server = SSEFixtureServer(
            frames: ["<html><body><h1>502 Bad Gateway</h1></body></html>"],
            contentType: "text/html")
        do {
            try server.start()
        } catch {
            return XCTFail("the fixture server did not start: \(error)")
        }
        defer { server.stop() }

        let backend = OpenAICompatBackend(baseURL: server.baseURL)
        do {
            let answer = try await backend.completeVision(
                apiKey: "fixture", model: "fixture-model", system: nil,
                userText: "what is on this screen",
                imageJPEG: Data([0xFF, 0xD8, 0xFF, 0xD9]))
            XCTFail("a 200 with an HTML body returned \(answer.debugDescription) instead of throwing")
        } catch let error as ClaudeError {
            guard case .decoding(let text) = error else {
                return XCTFail("expected ClaudeError.decoding, got \(error)")
            }
            XCTAssertEqual(text, "openai: vision 2xx body not JSON")
        } catch {
            XCTFail("the raw parse error escaped instead of ClaudeError.decoding: \(error)")
        }
    }
}

// MARK: - The fixture server

/// A single-purpose HTTP server that serves one canned response, in process,
/// on an ephemeral loopback port.
///
/// Deliberately not a general server: it takes a fixed list of byte frames, and
/// every connection gets the same ones. That is enough for a captured SSE
/// stream or a captured JSON completion, and keeps the thing small enough to
/// read in one sitting.
///
/// Three details are load bearing and each was chosen for a reason:
///
///  - Bound to `127.0.0.1` explicitly rather than to all interfaces. A loopback
///    bind does not trip the macOS application firewall, so a developer running
///    the suite locally never sees an "accept incoming connections" prompt, and
///    the fixture is unreachable from off the machine even for the moment it is
///    up.
///  - `SO_NOSIGPIPE` on the accepted connection. The parser breaks out of its
///    read loop the instant it sees `[DONE]`, which tears the connection down
///    under a server that may still be writing. Without this, that write raises
///    SIGPIPE and takes the whole test process with it, which would read as a
///    crash in an unrelated test rather than as anything to do with the socket.
///  - `TCP_NODELAY`, so each frame leaves as its own segment instead of being
///    coalesced. The parser is line based and would pass either way, but a
///    fixture that claims to stream in several chunks should actually do it.
///
/// `@unchecked Sendable` is accurate rather than a shortcut: the frames are
/// immutable after init, the port is written before the accept thread starts,
/// and the only field the accept thread mutates is guarded by `lock`.
///
/// File scoped on purpose. It is a fixture for one test file, and a helper this
/// generically named sitting at target scope is how two test files end up
/// fighting over the name.
private final class SSEFixtureServer: @unchecked Sendable {

    private let statusCode: Int
    private let contentType: String
    private let frames: [Data]
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var storedRequestLine = ""

    private(set) var port: UInt16 = 0

    /// The request line the last connection sent, for asserting that the code
    /// under test is what reached the fixture.
    var requestLine: String {
        lock.lock(); defer { lock.unlock() }
        return storedRequestLine
    }

    /// Shaped for `OpenAICompatBackend(baseURL:)`, which appends
    /// `/v1/chat/completions` itself.
    var baseURL: String { "http://127.0.0.1:\(port)" }

    init(frames: [String], statusCode: Int = 200, contentType: String = "text/event-stream") {
        self.frames = frames.map { Data($0.utf8) }
        self.statusCode = statusCode
        self.contentType = contentType
    }

    enum FixtureError: Error { case socketUnavailable, bindFailed }

    func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw FixtureError.socketUnavailable }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0                        // let the kernel pick a free port
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw FixtureError.bindFailed
        }

        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        port = UInt16(bigEndian: actual.sin_port)
        listenFD = fd
        Thread.detachNewThread { self.acceptLoop(fd) }
    }

    /// Closing the listening descriptor is also how the accept thread is told
    /// to exit: the blocked `accept` returns an error, the loop returns, and
    /// the last strong reference to this object goes with it.
    func stop() {
        let fd = listenFD
        listenFD = -1
        if fd >= 0 { close(fd) }
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let conn = accept(fd, nil, nil)
            if conn < 0 { return }
            var yes: Int32 = 1
            setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(conn, Int32(IPPROTO_TCP), TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
            serve(conn)
            close(conn)
        }
    }

    private func serve(_ conn: Int32) {
        var request = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        var headEnd: Range<Data.Index>? = nil
        while headEnd == nil {
            let n = read(conn, &buf, buf.count)
            if n <= 0 { return }
            request.append(contentsOf: buf[0..<n])
            headEnd = request.range(of: Data("\r\n\r\n".utf8))
        }
        guard let headEnd else { return }
        let head = String(decoding: request[..<headEnd.lowerBound], as: UTF8.self)
        lock.lock()
        storedRequestLine = head.split(separator: "\r\n").first.map(String.init) ?? ""
        lock.unlock()

        // Drain the request body. Nothing here reads it, but leaving it in the
        // socket can stall the client mid-send on a body larger than the kernel
        // buffer, and a compiled system prompt is exactly that large.
        var contentLength = 0
        for header in head.split(separator: "\r\n") where header.lowercased().hasPrefix("content-length:") {
            contentLength = Int(header.dropFirst("content-length:".count)
                .trimmingCharacters(in: .whitespaces)) ?? 0
        }
        var bodyRead = request.count - headEnd.upperBound
        while bodyRead < contentLength {
            let n = read(conn, &buf, buf.count)
            if n <= 0 { break }
            bodyRead += n
        }

        var response = "HTTP/1.1 \(statusCode) OK\r\n"
        response += "Content-Type: \(contentType)\r\n"
        response += "Content-Length: \(frames.reduce(0) { $0 + $1.count })\r\n"
        response += "Connection: close\r\n\r\n"
        guard writeAll(conn, Data(response.utf8)) else { return }
        for frame in frames where !writeAll(conn, frame) { return }
    }

    private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var sent = 0
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return true }
            while sent < data.count {
                let n = write(fd, base.advanced(by: sent), data.count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }
}
