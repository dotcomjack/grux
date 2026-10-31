import XCTest
@testable import Grux

/// Grux Local v3 is trained on Resources/GruxLocal/trained-tools-v3.json, and
/// a v3 turn sends those bytes (TrainedTools). These hold the file, the table
/// and the app's own tools to one another, so the model never meets a tool it
/// was not trained on as a signature.
///
/// To regenerate after a deliberate change: set GRUX_WRITE_TRAINED_TOOLS to a
/// directory and run this class, or run a debug build with
/// `--trained-tools-contract <dir>`; copy both files into place.
@MainActor
final class TrainedToolsContractTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private let contractURL = root.appendingPathComponent("Resources/GruxLocal/trained-tools-v3.json")
    private let tableURL = root.appendingPathComponent("Sources/Grux/Chat/TrainedToolsV3.swift")

    override func setUp() async throws {
        if let dir = ProcessInfo.processInfo.environment["GRUX_WRITE_TRAINED_TOOLS"] {
            let out = URL(fileURLWithPath: dir, isDirectory: true)
            try TrainedTools.contractData(ChatService.allTools()).write(to: out.appendingPathComponent("trained-tools-v3.json"))
            try Data(TrainedTools.tableSource(ChatService.allTools()).utf8)
                .write(to: out.appendingPathComponent("TrainedToolsV3.swift"))
        }
    }

    /// THE GUARD. A trained tool whose name, description or parameters changed
    /// goes out with its full description again, which is not what v3 learned.
    func test_noTrainedToolChangedSinceTraining() {
        XCTAssertFalse(TrainedTools.v3.isEmpty, "the table is empty, so this guards nothing")
        let drifted = TrainedTools.drifted(ChatService.allTools())
        XCTAssertEqual(drifted, [], "These tools changed since Grux Local \(TrainedTools.tagSuffix) was trained on them: "
            + "\(drifted.joined(separator: ", ")). Revert the change, or remove them from the contract and the table "
            + "(they then keep their full description), or bump TrainedTools.version, regenerate and retrain.")
    }

    /// The table each contract version was trained on, as one digest. A
    /// regenerated table under the same version fails here: a v3 model never
    /// saw the new bytes, so a change is a new version and a new training run
    /// (add its row), or a removal from the table, which is also a new row.
    static let trainedTableDigests: [Int: String] = [
        3: "4e6e62e955d958a477d346db718fe6bc570f50746079363109dff9a691ae28ba",
    ]

    static func tableDigest(_ table: [String: String]) -> String {
        let lines = table.keys.sorted().map { "\($0) \(table[$0] ?? "")\n" }.joined()
        return TrainedTools.schemaHashOfText(lines)
    }

    func test_theTableIsTheOneThisVersionWasTrainedOn() {
        XCTAssertEqual(Self.tableDigest(TrainedTools.v3), Self.trainedTableDigests[TrainedTools.version],
                       "TrainedToolsV3.swift changed under version \(TrainedTools.version). A v3 model was trained on "
                       + "the old table: bump TrainedTools.version and the tag suffix, retrain, and add a row here.")
    }

    func test_theContractFileIsTheAppsOwnBytes() throws {
        let committed = try Data(contentsOf: contractURL)
        let generated = TrainedTools.contractData(ChatService.allTools())
        XCTAssertEqual(String(decoding: committed, as: UTF8.self), String(decoding: generated, as: UTF8.self),
                       "trained-tools-v3.json is not what this build sends; regenerate it (see the class comment)")
    }

    func test_theTableIsTheContractsHashes() throws {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: contractURL)) as? [String: Any]
        let entries = object?["tools"] as? [[String: Any]] ?? []
        let hashes = Dictionary(uniqueKeysWithValues: entries.map {
            ($0["name"] as? String ?? "", $0["schema_sha256"] as? String ?? "")
        })
        XCTAssertFalse(hashes.isEmpty)
        XCTAssertEqual(TrainedTools.v3, hashes)
        XCTAssertEqual(object?["version"] as? Int, TrainedTools.version)
        XCTAssertEqual(object?["model_tag_suffix"] as? String, TrainedTools.tagSuffix)
        XCTAssertEqual(try String(contentsOf: tableURL, encoding: .utf8), TrainedTools.tableSource(ChatService.allTools()))
    }

    func test_onlyAV3GruxLocalTagIsTrained() {
        for id in ["grux-local:4b-v3", "gruxai.com/grux/grux-local:2b-v3", "GRUX-LOCAL:9b-v3"] {
            XCTAssertTrue(TrainedTools.isTrainedModel(id), id)
        }
        for id in ["grux-local:4b", "gruxai.com/grux/grux-local:4b", "grux-local:4b-v2", "qwen3.5:4b-v3",
                   "grux-local-v3", "grux-local", "", "my-grux-local:4b-v3", "grux-local:4b-v3x"] {
            XCTAssertFalse(TrainedTools.isTrainedModel(id), id)
        }
    }

    func test_aV3TurnCompactsOnlyTrainedUnchangedTools() {
        let all = ChatService.allTools()
        guard let trained = all.first(where: { TrainedTools.v3[$0.name] != nil }) else {
            return XCTFail("no trained tool among the app's tools")
        }
        let changed = ClaudeTool(name: trained.name, description: trained.description + " Changed.",
                                 inputSchema: trained.inputSchema)
        let mcp = ClaudeTool(name: "mcp_files_read", description: "Read a file. Long text.", inputSchema: ["type": "object"])
        let out = TrainedTools.forModel("grux-local:4b-v3", [trained, changed, mcp])
        XCTAssertEqual(out.map(\.name), [trained.name, trained.name, mcp.name], "order and membership hold")
        XCTAssertEqual(out[0].description, TrainedTools.signature(trained))
        XCTAssertNotEqual(out[0].description, trained.description, "control: the signature is not the description")
        XCTAssertEqual(TrainedTools.wire(out[0].inputSchema), TrainedTools.wire(trained.inputSchema), "parameters unchanged")
        XCTAssertEqual(out[1].description, changed.description, "a changed tool keeps its full description")
        XCTAssertEqual(out[2].description, mcp.description, "an untrained tool keeps its full description")
        for model in ["grux-local:4b", "qwen3.5:4b", "claude-sonnet-5-5"] {
            XCTAssertEqual(TrainedTools.forModel(model, [trained]).map(\.description), [trained.description], model)
        }
    }

    /// The contract's per-tool bytes are what the backend puts on the wire:
    /// the same builder a streamed turn uses, the same encoder.
    func test_contractBytesAreTheWireBytes() throws {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: contractURL)) as? [String: Any]
        let entries = try XCTUnwrap(object?["tools"] as? [[String: Any]])
        XCTAssertGreaterThan(entries.count, 20)
        let all = ChatService.allTools()
        for entry in entries {
            let name = try XCTUnwrap(entry["name"] as? String)
            let tool = try XCTUnwrap(all.first { $0.name == name }, name)
            let sent = try OpenAICompatBackend.wireData(OpenAICompatBackend.openAITools([TrainedTools.compacted(tool)]))
            XCTAssertEqual(String(decoding: sent, as: UTF8.self), "[\(entry["compact_wire"] as? String ?? "")]", name)
        }
    }

    /// Only built-in tools that ride ordinary turns: the core group and the
    /// ones that open another app. MCP and the heavy groups stay full.
    func test_theContractHoldsCoreAndOpenAnotherAppToolsOnly() {
        let names = Set(TrainedTools.v3.keys)
        XCTAssertTrue(names.contains("add_task"))
        XCTAssertTrue(names.contains("open_app"), "the tools that open another app are trained too")
        for name in names {
            XCTAssertTrue([.core, .otherApps].contains(ToolRelevance.group(for: name)), name)
            XCTAssertFalse(name.hasPrefix("mcp_"), name)
        }
    }

    /// The warm-up and the turn must send the same tool bytes, or Ollama's
    /// cache breaks inside the first tool. Both build their model id from
    /// resolvedRouting and pass it through the same call.
    func test_theTurnAndItsWarmUpBothSendSignatures() throws {
        let src = try String(contentsOf: Self.root.appendingPathComponent("Sources/Grux/ChatService.swift"), encoding: .utf8)
        XCTAssertEqual(src.components(separatedBy: "TrainedTools.forModel(").count - 1, 2)
        for fn in ["func assemblePendingContext(", "func localPrefix("] {
            let start = try XCTUnwrap(src.range(of: fn), fn)
            let rest = src[start.upperBound...]
            let end = rest.range(of: "\n    func ")?.lowerBound ?? rest.endIndex
            XCTAssertTrue(rest[..<end].contains("TrainedTools.forModel("), "\(fn) sends tools without the signatures")
        }
    }

    func test_signaturesAreOneLineAndPlain() {
        for t in ChatService.allTools() where TrainedTools.v3[t.name] != nil {
            let s = TrainedTools.signature(t)
            XCTAssertFalse(s.contains("\n"), t.name)
            XCTAssertFalse(s.contains("\u{2014}") || s.contains("\u{2013}"), t.name)
            XCTAssertTrue(s.hasPrefix("\(t.name)("), t.name)
            XCTAssertLessThan(s.count, t.description.count + 200, t.name)
        }
        XCTAssertEqual(TrainedTools.firstSentence("Open it, e.g. Safari. Then more."), "Open it, e.g. Safari.")
    }
}

/// The samples file is two real request bodies from the app's own path
/// (TrainedTools.samples, written under a clean HOME). It carries the minute,
/// so it is not byte-compared; what must hold is that every tool it sends as
/// a signature is, byte for byte, the contract's.
final class TrainedToolsSamplesTests: XCTestCase {
    func test_everySignatureInTheSamplesIsTheContractsBytes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/GruxLocal")
        let contract = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("trained-tools-v3.json"))) as? [String: Any]
        let samples = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("trained-tools-v3-samples.json"))) as? [String: Any]
        let wires = Dictionary(uniqueKeysWithValues: (contract?["tools"] as? [[String: Any]] ?? []).map {
            ($0["name"] as? String ?? "", $0["compact_wire"] as? String ?? "")
        })
        let requests = try XCTUnwrap(samples?["requests"] as? [[String: Any]])
        XCTAssertEqual(requests.map { $0["turn"] as? String }, ["stable", "ranked"])
        var found = 0
        for r in requests {
            let body = try XCTUnwrap(r["body"] as? String)
            for name in r["tools"] as? [String] ?? [] {
                guard let wire = wires[name] else { continue }
                XCTAssertTrue(body.contains(wire), "\(name) went out other than the contract says")
                found += 1
            }
        }
        XCTAssertGreaterThan(found, 5, "the samples hold no trained tool, so this checks nothing")
    }
}
