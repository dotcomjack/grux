import XCTest
@testable import Grux

/// Settings shows the memory counts once the files are read, whether or not
/// the sentence model loaded. A Mac whose model fails to load still has
/// entries on disk, and the counts used to wait on the model forever.
@MainActor
final class SemanticMemoryBootTests: XCTestCase {

    func test_countsArriveWithoutTheSentenceModel() async {
        let memory = SemanticMemory(bootedWith: [
            SemanticEntry(kind: .chatUser, text: "hello there", vector: []),
            SemanticEntry(kind: .ambient, text: "call the dentist", vector: []),
            SemanticEntry(kind: .ambient, text: "send the invoice", vector: []),
        ], model: nil)
        XCTAssertFalse(memory.isReady, "control: no sentence model")
        let counts = await memory.countsWhenLoaded(seconds: 0.5)
        XCTAssertEqual(counts?[.chatUser], 1)
        XCTAssertEqual(counts?[.ambient], 2)
    }
}
